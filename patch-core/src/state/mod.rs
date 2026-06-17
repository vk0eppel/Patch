//! Shared application state — channels, peers, message buffer.
//! All access is through `Arc<AppState>`; interior mutation via `tokio::sync::RwLock`.

pub mod channel;
pub mod config;
pub mod peer;
pub mod show_file;

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::Arc;
use tokio::sync::{broadcast, Mutex, RwLock};
use uuid::Uuid;

use crate::osc::types::{ChannelFlash, PatchMessage, PeerPresence};
pub use config::Config;

/// Events broadcast to all internal subscribers (bridge, UI, etc.)
#[derive(Debug, Clone)]
pub enum AppEvent {
    MessageReceived(PatchMessage),
    MessageAcked {
        message_id: Uuid,
        peer_id: Uuid,
    },
    /// Delivery progress/result for a *critical* message we sent. `delivered` of
    /// `total` targets have ACKed; `failed` is set when retransmits were exhausted
    /// (or there were no peers to send to), with `failed_peers` naming the peers
    /// that never received it.
    MessageDelivery {
        message_id: Uuid,
        delivered: u32,
        total: u32,
        failed: bool,
        failed_peers: Vec<String>,
    },
    PeerUpdated(PeerPresence),
    PeerExpired(Uuid),
    ChannelFlash(ChannelFlash),
    ChannelListUpdated,
    /// A peer offered its channel layout in reply to our request. Surfaced to the
    /// UI for a preview/merge prompt — never auto-applied.
    ChannelsOffered {
        from_peer_id: Uuid,
        from_name: String,
        channels: Vec<channel::Channel>,
    },
    ClientNameChanged(String),
    /// Emitted when the OS denies network access (iOS/macOS Local Network permission).
    PermissionDenied {
        context: String,
    },
}

#[derive(Debug, Clone)]
pub struct AppState(Arc<Inner>);

#[derive(Debug)]
struct Inner {
    /// Full config — wrapped in RwLock so client_name and shortcuts can be
    /// mutated at runtime without restarting the engine.
    pub config: RwLock<Config>,
    /// channel_id → Channel
    pub channels: RwLock<HashMap<String, channel::Channel>>,
    /// peer_id → Peer
    pub peers: RwLock<HashMap<Uuid, peer::Peer>>,
    /// Recent messages (ring buffer — capped at MAX_BUFFER)
    pub messages: RwLock<MessageBuffer>,
    /// Channel ids the UI currently has selected (incl. `__all__` in ALL mode).
    /// Pushed from Flutter via `set_selected_channels`; read by the MIDI listener
    /// so a MIDI-triggered *global* macro fires on the same channel(s) a tap/F-key
    /// would. The engine has no other view of UI selection.
    pub selected: RwLock<Vec<String>>,
    /// Event bus — clone a receiver to subscribe
    pub events: broadcast::Sender<AppEvent>,
    /// Serializes config persistence so concurrent mutators can't write the
    /// `patch.toml` out of order (which would let an earlier change clobber a
    /// later one). Held only across the clone + offloaded write, never with the
    /// config `RwLock`, so it doesn't block readers on the hot send path.
    pub save_lock: Mutex<()>,
}

const MAX_BUFFER: usize = 500;

/// Bounded message ring buffer with O(1) dedup.
///
/// `queue` keeps insertion order (and is popped from the front on overflow);
/// `seen` mirrors the message IDs currently in `queue` so duplicates — our own
/// broadcast echoes back over UDP — are rejected without scanning the queue.
#[derive(Debug, Default)]
struct MessageBuffer {
    queue: VecDeque<PatchMessage>,
    seen: HashSet<Uuid>,
}

impl AppState {
    pub fn new(config: Config) -> Self {
        let (tx, _) = broadcast::channel(256);

        // Seed with default channels from config
        let mut channels = HashMap::new();
        for ch in &config.default_channels {
            channels.insert(ch.id.clone(), ch.clone());
        }

        Self(Arc::new(Inner {
            config: RwLock::new(config),
            channels: RwLock::new(channels),
            peers: RwLock::new(HashMap::new()),
            messages: RwLock::new(MessageBuffer::default()),
            selected: RwLock::new(Vec::new()),
            events: tx,
            save_lock: Mutex::new(()),
        }))
    }

    /// Returns a snapshot clone of the current config.
    pub async fn config(&self) -> Config {
        self.0.config.read().await.clone()
    }

    pub fn subscribe(&self) -> broadcast::Receiver<AppEvent> {
        self.0.events.subscribe()
    }

    pub async fn publish(&self, event: AppEvent) {
        let _ = self.0.events.send(event);
    }

    // ── Client name ───────────────────────────────────────────────────────────

    pub async fn set_client_name(&self, name: String) -> anyhow::Result<()> {
        self.0.config.write().await.client_name = name.clone();
        self.save_config().await?;
        self.publish(AppEvent::ClientNameChanged(name)).await;
        Ok(())
    }

    /// Replace the UI's current channel selection (runtime only — not persisted).
    /// Read by the MIDI listener for global-macro firing.
    pub async fn set_selected_channels(&self, ids: Vec<String>) {
        *self.0.selected.write().await = ids;
    }

    /// The UI's currently-selected channel ids (empty until Flutter first syncs).
    pub async fn selected_channels(&self) -> Vec<String> {
        self.0.selected.read().await.clone()
    }

    /// Persist the self-assigned role (None = unset). Broadcast in the next
    /// presence heartbeat (the loop re-reads config each tick, like client_name),
    /// so it propagates to other peers within one interval without a restart.
    pub async fn set_role(&self, role: Option<String>) -> anyhow::Result<()> {
        self.0.config.write().await.role = role;
        self.save_config().await
    }

    /// Persist the discovery-beacon interface scope (None = announce on all).
    /// Applies live — the heartbeat re-reads it each tick; the socket always
    /// binds 0.0.0.0, so there's nothing to rebind.
    ///
    /// Also clears all dynamically-discovered peers (OscBeacon/Mdns) so the
    /// peer list rebuilds via the new NIC's discovery. ManualIp/static peers
    /// are kept — their addresses don't depend on which NIC was used.
    pub async fn set_network_interface(&self, iface: Option<String>) -> anyhow::Result<()> {
        self.0.config.write().await.network_interface = iface;
        let removed = self.clear_dynamic_peers().await;
        for id in removed {
            self.publish(AppEvent::PeerExpired(id)).await;
        }
        self.save_config().await
    }

    /// Remove all OscBeacon/Mdns peers from the registry immediately.
    /// ManualIp/static peers are never touched.
    /// Returns the IDs of removed peers so callers can emit PeerExpired events.
    async fn clear_dynamic_peers(&self) -> Vec<Uuid> {
        let mut peers = self.0.peers.write().await;
        let mut removed = Vec::new();
        peers.retain(|id, p| {
            if matches!(p.discovery_mode, peer::DiscoveryMode::ManualIp) {
                true
            } else {
                removed.push(*id);
                false
            }
        });
        removed
    }

    /// Persist the flash-on-critical setting.
    pub async fn set_flash_on_critical(&self, enabled: bool) -> anyhow::Result<()> {
        self.0.config.write().await.flash_on_critical = enabled;
        self.save_config().await
    }

    /// Persist the flash-on-every-message setting.
    pub async fn set_flash_on_message(&self, enabled: bool) -> anyhow::Result<()> {
        self.0.config.write().await.flash_on_message = enabled;
        self.save_config().await
    }

    /// Persist the global flash pulse count (clamped to 3–7).
    pub async fn set_flash_count(&self, count: u8) -> anyhow::Result<()> {
        self.0.config.write().await.flash_count = count.clamp(3, 7);
        self.save_config().await
    }

    pub async fn set_macros_columns(&self, columns: u8) -> anyhow::Result<()> {
        self.0.config.write().await.macros_columns = columns.clamp(1, 3);
        self.save_config().await
    }

    pub async fn set_hide_keyboard(&self, enabled: bool) -> anyhow::Result<()> {
        self.0.config.write().await.hide_keyboard = enabled;
        self.save_config().await
    }

    pub async fn set_audible_alert(&self, enabled: bool) -> anyhow::Result<()> {
        self.0.config.write().await.audible_alert = enabled;
        self.save_config().await
    }

    /// Persist the presence heartbeat interval (seconds). Validated 1–60: below
    /// floods the LAN, above makes peer detection uselessly slow. Applies live —
    /// the discovery heartbeat loop re-reads it at the end of each cycle, so the
    /// new cadence takes effect on the next beat with no restart.
    pub async fn set_heartbeat_interval(&self, secs: u64) -> anyhow::Result<()> {
        if !(1..=60).contains(&secs) {
            anyhow::bail!("heartbeat interval must be 1–60 seconds (got {})", secs);
        }
        self.0.config.write().await.heartbeat_interval_secs = secs;
        self.save_config().await
    }

    /// Persist the OSC UDP port. Validated 1024–65535 (privileged ports < 1024
    /// need root and would fail to bind). The live socket rebind is driven by the
    /// caller (`api::set_osc_port`) after this persists.
    pub async fn set_osc_port(&self, port: u16) -> anyhow::Result<()> {
        if !(1024..=65535).contains(&port) {
            anyhow::bail!("OSC port must be 1024–65535 (got {})", port);
        }
        self.0.config.write().await.osc_port = port;
        self.save_config().await
    }

    /// Update per-channel flash flags. `None` means "leave unchanged".
    pub async fn set_channel_flash(
        &self,
        channel_id: &str,
        flash_on_critical: Option<bool>,
        flash_on_message: Option<bool>,
        flash_count: Option<u8>,
    ) -> anyhow::Result<()> {
        {
            let mut channels = self.0.channels.write().await;
            let ch = channels
                .get_mut(channel_id)
                .ok_or_else(|| anyhow::anyhow!("Channel '{}' not found", channel_id))?;
            if let Some(v) = flash_on_critical {
                ch.flash_on_critical = v;
            }
            if let Some(v) = flash_on_message {
                ch.flash_on_message = v;
            }
            // flash_count: None = leave unchanged, Some(0) = clear override (use global),
            // Some(n) = set per-channel override to n.
            if let Some(v) = flash_count {
                ch.flash_count = if v == 0 { None } else { Some(v.clamp(3, 7)) };
            }
        }
        self.persist_channels().await?;
        self.publish(AppEvent::ChannelListUpdated).await;
        Ok(())
    }

    // ── Static peers ─────────────────────────────────────────────────────────

    pub async fn add_static_peer(
        &self,
        address: String,
        port: u16,
        label: Option<String>,
    ) -> anyhow::Result<()> {
        // Validate the IP address before storing.
        address
            .parse::<std::net::IpAddr>()
            .map_err(|_| anyhow::anyhow!("Invalid IP address: '{}'", address))?;
        if port == 0 {
            anyhow::bail!("Port 0 is not valid for a static peer");
        }
        {
            let mut cfg = self.0.config.write().await;
            if cfg
                .static_peers
                .iter()
                .any(|p| p.address == address && p.port == port)
            {
                anyhow::bail!("Peer {}:{} is already configured", address, port);
            }
            cfg.static_peers.push(config::StaticPeer {
                address,
                port,
                label,
            });
        }
        self.save_config().await
    }

    pub async fn remove_static_peer(&self, address: &str, port: u16) -> anyhow::Result<()> {
        self.0
            .config
            .write()
            .await
            .static_peers
            .retain(|p| !(p.address == address && p.port == port));
        self.save_config().await
    }

    // ── Messages ──────────────────────────────────────────────────────────────

    pub async fn store_message(&self, msg: PatchMessage) {
        let mut buf = self.0.messages.write().await;
        // Deduplicate — our own broadcast comes back over UDP, so the same
        // message_id can arrive twice (once on send, once on receive).
        // `insert` returns false if the id was already present (O(1)).
        if !buf.seen.insert(msg.message_id) {
            return;
        }
        if buf.queue.len() >= MAX_BUFFER {
            if let Some(old) = buf.queue.pop_front() {
                buf.seen.remove(&old.message_id);
            }
        }
        buf.queue.push_back(msg.clone());
        drop(buf);
        self.publish(AppEvent::MessageReceived(msg)).await;
    }

    /// Clear messages for a specific channel, or all channels when `channel_id` is `None`.
    pub async fn clear_messages(&self, channel_id: Option<&str>) {
        let mut buf = self.0.messages.write().await;
        match channel_id {
            Some(id) => {
                buf.queue.retain(|m| m.channel_id != id);
                // Rebuild the dedup set so cleared IDs can be received again.
                buf.seen = buf.queue.iter().map(|m| m.message_id).collect();
            }
            None => {
                buf.queue.clear();
                buf.seen.clear();
            }
        }
    }

    pub async fn get_all_messages(&self) -> Vec<PatchMessage> {
        self.0.messages.read().await.queue.iter().cloned().collect()
    }

    pub async fn get_messages(&self, channel_id: &str, limit: usize) -> Vec<PatchMessage> {
        let buf = self.0.messages.read().await;
        buf.queue
            .iter()
            .filter(|m| m.channel_id == channel_id)
            .rev()
            .take(limit)
            .cloned()
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .collect()
    }

    // ── Peers ─────────────────────────────────────────────────────────────────

    /// Insert/update a peer discovered via the OSC presence beacon.
    pub async fn upsert_peer(&self, presence: PeerPresence) {
        self.upsert_peer_with_mode(presence, peer::DiscoveryMode::OscBeacon)
            .await;
    }

    /// Insert/update a peer, classifying it with an explicit discovery mode.
    /// Used by mDNS resolution (`DiscoveryMode::Mdns`) so the 🔍 icon shows.
    pub async fn upsert_peer_with_mode(&self, presence: PeerPresence, mode: peer::DiscoveryMode) {
        let mut peers = self.0.peers.write().await;
        let mut new_peer = peer::Peer::from_presence(presence.clone());
        new_peer.discovery_mode = mode;
        // Preserve the transport-resolved address — touch_peer_address runs
        // before upsert_peer in handle_event, and from_presence() would
        // otherwise overwrite it with an empty string.
        if let Some(existing) = peers.get(&presence.peer_id) {
            if !existing.address.is_empty() {
                new_peer.address = existing.address.clone();
                new_peer.osc_port = existing.osc_port;
            }
            // Once a peer has been resolved via mDNS, keep that classification —
            // a subsequent OSC presence heartbeat shouldn't downgrade the icon.
            if matches!(existing.discovery_mode, peer::DiscoveryMode::Mdns) {
                new_peer.discovery_mode = peer::DiscoveryMode::Mdns;
            }
        }
        peers.insert(presence.peer_id, new_peer);
        drop(peers);
        self.publish(AppEvent::PeerUpdated(presence)).await;
    }

    /// Update the network address and `last_seen` of a known peer. Called from
    /// transport on **received OSC packets** only (real liveness) — NOT from mDNS
    /// resolution (see `resolve_peer_address`). Emits PeerUpdated so the Flutter
    /// side refreshes the dot. No-op if the peer isn't in the registry yet — it
    /// will be populated when their presence packet arrives.
    pub async fn touch_peer_address(&self, peer_id: Uuid, address: String, port: u16) {
        let presence = {
            let mut peers = self.0.peers.write().await;
            let Some(peer) = peers.get_mut(&peer_id) else {
                return;
            };
            peer.address = address;
            peer.osc_port = port;
            peer.last_seen = chrono::Utc::now();
            // A real OSC packet proves liveness — clear any prior departure.
            peer.departed = false;
            // Build a PeerPresence to carry through the event bus.
            PeerPresence {
                peer_id: peer.peer_id,
                peer_name: peer.peer_name.clone(),
                channels: peer.channels.clone(),
                role: peer.role.clone(),
                timestamp: peer.last_seen,
            }
        };
        self.publish(AppEvent::PeerUpdated(presence)).await;
    }

    /// Record a peer's mDNS-resolved address **without** refreshing liveness.
    ///
    /// mDNS resolution can be replayed from a stale cache long after a peer has
    /// quit, so it proves only that we have an address to unicast to — not that
    /// the peer is currently up. Liveness (`last_seen`) must come solely from
    /// real OSC traffic (`touch_peer_address`). So: a peer we already know keeps
    /// its existing `last_seen` and just gets its address + `Mdns` classification
    /// refreshed; a peer seen *only* via mDNS so far is inserted as already-stale
    /// (grey) until an OSC packet greens it (≤ one heartbeat on a normal LAN).
    /// Without this, repeated cached mDNS resolutions kept a departed peer green
    /// until the mDNS record's TTL finally expired.
    pub async fn resolve_peer_address(&self, presence: PeerPresence, address: String, port: u16) {
        {
            let mut peers = self.0.peers.write().await;
            match peers.get_mut(&presence.peer_id) {
                Some(peer) => {
                    if !address.is_empty() {
                        peer.address = address;
                        peer.osc_port = port;
                    }
                    peer.discovery_mode = peer::DiscoveryMode::Mdns;
                }
                None => {
                    let mut new_peer = peer::Peer::from_presence(presence.clone());
                    new_peer.discovery_mode = peer::DiscoveryMode::Mdns;
                    new_peer.address = address;
                    new_peer.osc_port = port;
                    // Backdate past the UI's stale threshold so the dot starts grey.
                    new_peer.last_seen = chrono::Utc::now() - chrono::Duration::seconds(60);
                    peers.insert(presence.peer_id, new_peer);
                }
            }
        }
        self.publish(AppEvent::PeerUpdated(presence)).await;
    }

    /// Remove dynamic (OscBeacon / Mdns) peers not heard from within `max_age_secs`.
    /// ManualIp / static peers are never removed.
    /// Returns the IDs of removed peers so callers can emit PeerExpired events.
    pub async fn clear_stale_peers(&self, max_age_secs: u64) -> Vec<Uuid> {
        let mut peers = self.0.peers.write().await;
        let mut removed = Vec::new();
        peers.retain(|id, p| {
            let is_manual = matches!(p.discovery_mode, peer::DiscoveryMode::ManualIp);
            let is_stale = p.is_stale(max_age_secs as i64);
            if !is_manual && is_stale {
                removed.push(*id);
                false
            } else {
                true
            }
        });
        removed
    }

    pub async fn has_peer(&self, peer_id: Uuid) -> bool {
        self.0.peers.read().await.contains_key(&peer_id)
    }

    /// Fully remove a peer from the registry (emits `PeerExpired`). Graceful
    /// departures (`/patch/bye`, mDNS `ServiceRemoved`) deliberately use
    /// `mark_peer_offline` instead — a quitting peer stays visible (grey) rather
    /// than vanishing — and the manual "clear inactive peers" button removes via
    /// `clear_stale_peers`. Retained as a utility (no current caller).
    pub async fn expire_peer(&self, peer_id: Uuid) {
        let mut peers = self.0.peers.write().await;
        peers.remove(&peer_id);
        drop(peers);
        self.publish(AppEvent::PeerExpired(peer_id)).await;
    }

    /// Mark a peer offline without removing it (e.g. on `/patch/bye` or mDNS
    /// `ServiceRemoved`). Sets the `departed` flag — which the UI renders as a
    /// distinct "left" treatment — while **keeping the real `last_seen`**, so a
    /// clean departure is told apart from a peer that merely went quiet. A
    /// reconnect (any received OSC packet) clears `departed` via
    /// `touch_peer_address`. No-op if the peer isn't currently known.
    pub async fn mark_peer_offline(&self, peer_id: Uuid) {
        let presence = {
            let mut peers = self.0.peers.write().await;
            let Some(peer) = peers.get_mut(&peer_id) else {
                return;
            };
            peer.departed = true;
            PeerPresence {
                peer_id: peer.peer_id,
                peer_name: peer.peer_name.clone(),
                channels: peer.channels.clone(),
                role: peer.role.clone(),
                timestamp: peer.last_seen,
            }
        };
        self.publish(AppEvent::PeerUpdated(presence)).await;
    }

    pub async fn get_peers(&self) -> Vec<peer::Peer> {
        let mut peers: Vec<_> = self.0.peers.read().await.values().cloned().collect();

        // Merge in static peers that haven't been heard from yet.
        // Once a real packet arrives from the same address, the dynamic entry
        // takes over and the synthetic one is suppressed by the address check.
        let static_peers = self.0.config.read().await.static_peers.clone();
        let known_by_addr: std::collections::HashSet<(String, u16)> = peers
            .iter()
            .map(|p| (p.address.clone(), p.osc_port))
            .collect();

        for sp in &static_peers {
            if known_by_addr.contains(&(sp.address.clone(), sp.port)) {
                continue; // real entry already present for this address
            }
            // Derive a stable UUID from the address:port so the ID doesn't
            // flicker on every getPeers() call.
            let key = format!("static:{}:{}", sp.address, sp.port);
            let synthetic_id = Uuid::new_v5(&Uuid::NAMESPACE_DNS, key.as_bytes());
            peers.push(peer::Peer {
                peer_id: synthetic_id,
                peer_name: sp.label.clone().unwrap_or_else(|| sp.address.clone()),
                channels: Vec::new(),
                role: None,
                discovery_mode: peer::DiscoveryMode::ManualIp,
                address: sp.address.clone(),
                osc_port: sp.port,
                last_seen: chrono::Utc::now(),
                departed: false,
            });
        }

        peers
    }

    // ── Channels & macros ────────────────────────────────────────────────────

    pub async fn get_channels(&self) -> Vec<channel::Channel> {
        let mut channels: Vec<_> = self.0.channels.read().await.values().cloned().collect();
        channels.sort_by(|a, b| a.display_name.cmp(&b.display_name));
        channels
    }

    pub async fn upsert_channel(&self, ch: channel::Channel) {
        self.0.channels.write().await.insert(ch.id.clone(), ch);
        self.persist_channels().await.ok();
        self.publish(AppEvent::ChannelListUpdated).await;
    }

    /// Delete a channel by ID.
    pub async fn delete_channel(&self, channel_id: &str) -> anyhow::Result<()> {
        self.0.channels.write().await.remove(channel_id);
        self.persist_channels().await?;
        self.publish(AppEvent::ChannelListUpdated).await;
        Ok(())
    }

    /// Replace all channels with the factory defaults.
    pub async fn reset_channels(&self) -> anyhow::Result<()> {
        self.apply_show_file(config::default_channels()).await
    }

    /// Apply a loaded/imported show file: replace channels **and** static peers.
    ///
    /// Like [`apply_show_file`] but also restores the static peers the show file
    /// captured (a show file is a full production layout — distributing one should
    /// bring the known device IPs with it). `reset_channels` deliberately uses
    /// `apply_show_file` (channels only) instead, so resetting channels to factory
    /// defaults never wipes the operator's configured peers.
    ///
    /// Both lists are untrusted file input: channel ids are validated up front
    /// (whole show file rejected atomically on a bad id, before any mutation);
    /// static peers with an unparseable address or port 0 are skipped with a
    /// warning (and de-duplicated by `address:port`) rather than failing the load.
    pub async fn apply_show_file_full(
        &self,
        channels: Vec<channel::Channel>,
        static_peers: Vec<config::StaticPeer>,
    ) -> anyhow::Result<()> {
        for ch in &channels {
            if !crate::osc::codec::valid_channel_id(&ch.id) {
                anyhow::bail!(
                    "show file contains invalid channel id {:?} — use only lowercase letters, digits, _ or - (≤64 chars)",
                    ch.id
                );
            }
        }
        let mut validated_peers: Vec<config::StaticPeer> = Vec::with_capacity(static_peers.len());
        let mut seen: HashSet<(String, u16)> = HashSet::new();
        for sp in static_peers {
            if sp.address.parse::<std::net::IpAddr>().is_err() {
                tracing::warn!(
                    "show_file: skipping static peer with invalid address {:?}",
                    sp.address
                );
                continue;
            }
            if sp.port == 0 {
                tracing::warn!("show_file: skipping static peer {} with port 0", sp.address);
                continue;
            }
            if seen.insert((sp.address.clone(), sp.port)) {
                validated_peers.push(sp);
            }
        }

        {
            let mut ch_map = self.0.channels.write().await;
            ch_map.clear();
            for ch in channels {
                ch_map.insert(ch.id.clone(), ch);
            }
        }
        // Replace static peers and sync default_channels into the config, then
        // persist once (rather than a write for channels + a write for peers).
        {
            let channels_snapshot: Vec<_> =
                self.0.channels.read().await.values().cloned().collect();
            let mut cfg = self.0.config.write().await;
            cfg.default_channels = channels_snapshot;
            cfg.static_peers = validated_peers;
        }
        self.save_config().await?;
        self.publish(AppEvent::ChannelListUpdated).await;
        Ok(())
    }

    /// Merge incoming channels into the registry, **adding only ids we don't
    /// already have** — never overwrites an existing channel's colour/macros and
    /// never deletes. Each id is validated against the OSC slug rule and the
    /// reserved `__all__` id is skipped (this is untrusted network input).
    /// Returns the number of channels actually added; persists + emits
    /// `ChannelListUpdated` only when something changed.
    ///
    /// Adopts **structure only** (id, display name, colour, macros). The
    /// per-channel flash/behavioural flags are LOCAL preferences, so they're
    /// reset to this machine's defaults (`config.flash_on_critical` /
    /// `flash_on_message`, and `flash_count = None`) rather than inheriting the
    /// source peer's — mirroring how `api::upsert_channel` creates a new channel.
    /// Without this, importing a layout could silently impose "flash on every
    /// message" from whoever you imported from.
    pub async fn merge_channels(&self, channels: Vec<channel::Channel>) -> anyhow::Result<usize> {
        let (flash_on_critical, flash_on_message) = {
            let cfg = self.0.config.read().await;
            (cfg.flash_on_critical, cfg.flash_on_message)
        };
        let mut added = 0usize;
        {
            let mut map = self.0.channels.write().await;
            for mut ch in channels {
                if ch.id == "__all__" || !crate::osc::codec::valid_channel_id(&ch.id) {
                    tracing::warn!("merge_channels: skipping invalid/reserved id {:?}", ch.id);
                    continue;
                }
                if map.contains_key(&ch.id) {
                    continue; // keep the existing channel untouched
                }
                // Reset behavioural flags to local defaults (structure-only adopt).
                ch.flash_on_critical = flash_on_critical;
                ch.flash_on_message = flash_on_message;
                ch.flash_count = None;
                map.insert(ch.id.clone(), ch);
                added += 1;
            }
        }
        if added > 0 {
            self.persist_channels().await?;
            self.publish(AppEvent::ChannelListUpdated).await;
        }
        Ok(added)
    }

    /// Replace all channels with those from a loaded show file.
    pub async fn apply_show_file(&self, channels: Vec<channel::Channel>) -> anyhow::Result<()> {
        // A show file is untrusted input (shared between machines, possibly
        // hand-edited). Validate every channel id against the OSC-path slug rule
        // *before* mutating anything — an invalid id would otherwise be embedded
        // verbatim in `/patch/channel/{id}/...` on the next send. Reject the whole
        // show file atomically so a single bad entry can't half-apply.
        for ch in &channels {
            if !crate::osc::codec::valid_channel_id(&ch.id) {
                anyhow::bail!(
                    "show file contains invalid channel id {:?} — use only lowercase letters, digits, _ or - (≤64 chars)",
                    ch.id
                );
            }
        }
        {
            let mut ch_map = self.0.channels.write().await;
            ch_map.clear();
            for ch in channels {
                ch_map.insert(ch.id.clone(), ch);
            }
        }
        self.persist_channels().await?;
        self.publish(AppEvent::ChannelListUpdated).await;
        Ok(())
    }

    /// Add or replace a macro on a channel (matched by label).
    pub async fn upsert_macro(
        &self,
        channel_id: &str,
        macro_msg: channel::MacroMessage,
    ) -> anyhow::Result<()> {
        {
            let mut channels = self.0.channels.write().await;
            let ch = channels
                .get_mut(channel_id)
                .ok_or_else(|| anyhow::anyhow!("Channel '{}' not found", channel_id))?;
            // Replace existing macro with same label, or append.
            if let Some(pos) = ch.macros.iter().position(|s| s.label == macro_msg.label) {
                ch.macros[pos] = macro_msg;
            } else {
                ch.macros.push(macro_msg);
            }
        }
        self.persist_channels().await?;
        self.publish(AppEvent::ChannelListUpdated).await;
        Ok(())
    }

    /// Reorder a channel's macros to match `ordered_labels`.
    ///
    /// Macros are pulled out in the given label order; any macro whose label is
    /// not listed is appended at the end (never dropped), and labels that don't
    /// match a macro are ignored. Labels are unique per channel.
    pub async fn reorder_macros(
        &self,
        channel_id: &str,
        ordered_labels: Vec<String>,
    ) -> anyhow::Result<()> {
        {
            let mut channels = self.0.channels.write().await;
            let ch = channels
                .get_mut(channel_id)
                .ok_or_else(|| anyhow::anyhow!("Channel '{}' not found", channel_id))?;
            let mut remaining = std::mem::take(&mut ch.macros);
            let mut reordered = Vec::with_capacity(remaining.len());
            for label in &ordered_labels {
                if let Some(pos) = remaining.iter().position(|m| &m.label == label) {
                    reordered.push(remaining.remove(pos));
                }
            }
            // Preserve any macros that weren't named in `ordered_labels`.
            reordered.append(&mut remaining);
            ch.macros = reordered;
        }
        self.persist_channels().await?;
        self.publish(AppEvent::ChannelListUpdated).await;
        Ok(())
    }

    // ── Global macros ─────────────────────────────────────────────────────────
    //
    // Stored on the config (not in the channels map) since they aren't tied to a
    // channel. Persisted like any other config mutation; the UI refreshes via the
    // bridge's `config_updated` after the call (mirrors static-peer edits).

    /// Add or replace a global macro (matched by label).
    pub async fn upsert_global_macro(
        &self,
        macro_msg: channel::MacroMessage,
    ) -> anyhow::Result<()> {
        {
            let mut cfg = self.0.config.write().await;
            if let Some(pos) = cfg
                .global_macros
                .iter()
                .position(|m| m.label == macro_msg.label)
            {
                cfg.global_macros[pos] = macro_msg;
            } else {
                cfg.global_macros.push(macro_msg);
            }
        }
        self.save_config().await
    }

    /// Replace all global macros with the factory defaults.
    pub async fn reset_global_macros(&self) -> anyhow::Result<()> {
        self.0.config.write().await.global_macros = config::default_global_macros();
        self.save_config().await
    }

    /// Remove a global macro by label.
    pub async fn delete_global_macro(&self, label: &str) -> anyhow::Result<()> {
        self.0
            .config
            .write()
            .await
            .global_macros
            .retain(|m| m.label != label);
        self.save_config().await
    }

    /// Reorder global macros to match `ordered_labels` (drag-to-reorder); macros
    /// not named are kept at the end, unknown labels ignored — same contract as
    /// [`reorder_macros`].
    pub async fn reorder_global_macros(&self, ordered_labels: Vec<String>) -> anyhow::Result<()> {
        {
            let mut cfg = self.0.config.write().await;
            let mut remaining = std::mem::take(&mut cfg.global_macros);
            let mut reordered = Vec::with_capacity(remaining.len());
            for label in &ordered_labels {
                if let Some(pos) = remaining.iter().position(|m| &m.label == label) {
                    reordered.push(remaining.remove(pos));
                }
            }
            reordered.append(&mut remaining);
            cfg.global_macros = reordered;
        }
        self.save_config().await
    }

    /// Remove a macro from a channel by label.
    pub async fn delete_macro(&self, channel_id: &str, label: &str) -> anyhow::Result<()> {
        {
            let mut channels = self.0.channels.write().await;
            let ch = channels
                .get_mut(channel_id)
                .ok_or_else(|| anyhow::anyhow!("Channel '{}' not found", channel_id))?;
            ch.macros.retain(|s| s.label != label);
        }
        self.persist_channels().await?;
        self.publish(AppEvent::ChannelListUpdated).await;
        Ok(())
    }

    /// Write current channel macros back to patch.toml.
    async fn persist_channels(&self) -> anyhow::Result<()> {
        {
            let channels: Vec<_> = self.0.channels.read().await.values().cloned().collect();
            self.0.config.write().await.default_channels = channels;
        }
        self.save_config().await
    }

    /// Persist the current config to disk, off the async runtime.
    ///
    /// `Config::save` does blocking file I/O (`std::fs::write` of the whole
    /// TOML); running it on a tokio worker would stall OSC send/receive, so it's
    /// offloaded to the blocking pool. The `save_lock` serializes writes so two
    /// concurrent mutators can't reorder their writes; the config snapshot is
    /// taken *after* acquiring the lock, so the last writer always persists the
    /// latest committed state. Callers must commit their mutation (drop the
    /// config write guard) before calling this.
    async fn save_config(&self) -> anyhow::Result<()> {
        let _guard = self.0.save_lock.lock().await;
        let cfg = self.0.config.read().await.clone();
        tokio::task::spawn_blocking(move || cfg.save()).await?
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::osc::types::Priority;

    /// An in-memory state with no channels, no static peers, and no global macros
    /// (a clean slate — `Config::default()` now seeds global macros on a fresh
    /// install, which the global-macro tests must start without). None of the
    /// methods exercised here touch disk, so no `set_data_dir` is needed.
    fn test_state() -> AppState {
        AppState::new(Config {
            default_channels: Vec::new(),
            static_peers: Vec::new(),
            global_macros: Vec::new(),
            ..Config::default()
        })
    }

    fn msg(channel: &str) -> PatchMessage {
        PatchMessage::new(Uuid::new_v4(), "tester", channel, Priority::Info, "hi")
    }

    fn presence(id: Uuid, when: chrono::DateTime<chrono::Utc>) -> PeerPresence {
        PeerPresence {
            peer_id: id,
            peer_name: "p".into(),
            channels: Vec::new(),
            role: None,
            timestamp: when,
        }
    }

    #[tokio::test]
    async fn store_message_dedups_by_id() {
        let st = test_state();
        let m = msg("rf");
        st.store_message(m.clone()).await;
        st.store_message(m.clone()).await; // same id again (our UDP echo)
        assert_eq!(st.get_all_messages().await.len(), 1);
    }

    #[tokio::test]
    async fn store_message_evicts_oldest_on_overflow() {
        let st = test_state();
        let first = msg("rf");
        st.store_message(first.clone()).await;
        for _ in 0..MAX_BUFFER {
            st.store_message(msg("rf")).await;
        }
        let all = st.get_all_messages().await;
        assert_eq!(all.len(), MAX_BUFFER);
        assert!(all.iter().all(|m| m.message_id != first.message_id)); // front evicted
                                                                       // Eviction also drops the id from the dedup set, so it can re-arrive.
        st.store_message(first.clone()).await;
        assert!(st
            .get_all_messages()
            .await
            .iter()
            .any(|m| m.message_id == first.message_id));
    }

    #[tokio::test]
    async fn clear_all_allows_re_receive() {
        let st = test_state();
        let m = msg("rf");
        st.store_message(m.clone()).await;
        st.clear_messages(None).await;
        assert_eq!(st.get_all_messages().await.len(), 0);
        st.store_message(m.clone()).await; // same id, accepted after clear
        assert_eq!(st.get_all_messages().await.len(), 1);
    }

    #[tokio::test]
    async fn clear_by_channel_rebuilds_dedup_set() {
        let st = test_state();
        let rf = msg("rf");
        let audio = msg("audio");
        st.store_message(rf.clone()).await;
        st.store_message(audio.clone()).await;
        st.clear_messages(Some("rf")).await;
        let remaining = st.get_all_messages().await;
        assert_eq!(remaining.len(), 1);
        assert_eq!(remaining[0].channel_id, "audio");
        st.store_message(rf.clone()).await; // rf id was cleared from `seen`
        assert_eq!(st.get_all_messages().await.len(), 2);
    }

    #[tokio::test]
    async fn get_peers_merges_static_with_stable_id() {
        let st = AppState::new(Config {
            default_channels: Vec::new(),
            static_peers: vec![config::StaticPeer {
                address: "192.168.1.50".into(),
                port: 9000,
                label: Some("Monitor World".into()),
            }],
            ..Config::default()
        });
        let a = st.get_peers().await;
        assert_eq!(a.len(), 1);
        assert!(matches!(a[0].discovery_mode, peer::DiscoveryMode::ManualIp));
        assert_eq!(a[0].address, "192.168.1.50");
        let b = st.get_peers().await;
        assert_eq!(a[0].peer_id, b[0].peer_id); // synthetic id stable across calls
    }

    #[tokio::test]
    async fn get_peers_suppresses_static_when_dynamic_present() {
        let st = AppState::new(Config {
            default_channels: Vec::new(),
            static_peers: vec![config::StaticPeer {
                address: "192.168.1.50".into(),
                port: 9000,
                label: None,
            }],
            ..Config::default()
        });
        let pid = Uuid::new_v4();
        st.upsert_peer(presence(pid, chrono::Utc::now())).await;
        st.touch_peer_address(pid, "192.168.1.50".into(), 9000)
            .await;
        let peers = st.get_peers().await;
        assert_eq!(peers.len(), 1); // no synthetic duplicate
        assert_eq!(peers[0].peer_id, pid);
    }

    #[tokio::test]
    async fn clear_stale_removes_dynamic_keeps_manual() {
        let st = test_state();
        let old = chrono::Utc::now() - chrono::Duration::seconds(3600);
        let now = chrono::Utc::now();

        let stale_dyn = Uuid::new_v4();
        st.upsert_peer(presence(stale_dyn, old)).await;
        let fresh_dyn = Uuid::new_v4();
        st.upsert_peer(presence(fresh_dyn, now)).await;
        let stale_manual = Uuid::new_v4();
        st.upsert_peer_with_mode(presence(stale_manual, old), peer::DiscoveryMode::ManualIp)
            .await;

        let removed = st.clear_stale_peers(60).await;
        assert_eq!(removed, vec![stale_dyn]); // only the stale dynamic one

        let ids: Vec<_> = st.get_peers().await.iter().map(|p| p.peer_id).collect();
        assert!(ids.contains(&fresh_dyn));
        assert!(ids.contains(&stale_manual)); // ManualIp never removed
        assert!(!ids.contains(&stale_dyn));
    }

    #[tokio::test]
    async fn reorder_macros_applies_order_and_preserves_unlisted() {
        use channel::{Channel, MacroMessage};
        // upsert_channel/reorder_macros persist — pin a temp data dir.
        let _guard = config::test_data_dir_guard().await;
        let dir = std::env::temp_dir().join(format!("patch-test-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        config::set_data_dir(dir.clone());

        let st = test_state();
        let mut ch = Channel::new("rf", "RF", "#1E88E5");
        ch.macros = ["a", "b", "c"]
            .iter()
            .map(|l| MacroMessage {
                label: l.to_string(),
                payload: l.to_string(),
                key_binding: None,
                priority: 1,
                midi_note: None,
                midi_cc: None,
                osc: None,
            })
            .collect();
        st.upsert_channel(ch).await;

        // Permute, omit "b" (should be appended), include an unknown label (ignored).
        st.reorder_macros("rf", vec!["c".into(), "a".into(), "ghost".into()])
            .await
            .unwrap();

        let labels: Vec<String> = st
            .get_channels()
            .await
            .into_iter()
            .find(|c| c.id == "rf")
            .unwrap()
            .macros
            .into_iter()
            .map(|m| m.label)
            .collect();
        assert_eq!(labels, vec!["c", "a", "b"]); // c,a listed; b preserved at end
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn reorder_macros_unknown_channel_errors() {
        let st = test_state();
        assert!(st.reorder_macros("nope", vec!["x".into()]).await.is_err());
    }

    #[tokio::test]
    async fn set_heartbeat_interval_validates_and_persists() {
        let _guard = config::test_data_dir_guard().await;
        let dir = std::env::temp_dir().join(format!("patch-test-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        config::set_data_dir(dir.clone());

        let st = test_state();
        // A valid value persists to disk.
        st.set_heartbeat_interval(12).await.unwrap();
        assert_eq!(
            Config::load_or_default().unwrap().heartbeat_interval_secs,
            12
        );
        // Boundaries are accepted.
        st.set_heartbeat_interval(1).await.unwrap();
        st.set_heartbeat_interval(60).await.unwrap();
        // Out-of-range values are rejected and leave the stored value untouched.
        assert!(st.set_heartbeat_interval(0).await.is_err());
        assert!(st.set_heartbeat_interval(61).await.is_err());
        assert_eq!(
            Config::load_or_default().unwrap().heartbeat_interval_secs,
            60
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn set_osc_port_validates_and_persists() {
        let _guard = config::test_data_dir_guard().await;
        let dir = std::env::temp_dir().join(format!("patch-test-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        config::set_data_dir(dir.clone());

        let st = test_state();
        // A valid port persists to disk.
        st.set_osc_port(9100).await.unwrap();
        assert_eq!(Config::load_or_default().unwrap().osc_port, 9100);
        // Boundaries are accepted.
        st.set_osc_port(1024).await.unwrap();
        st.set_osc_port(65535).await.unwrap();
        // Privileged / zero ports are rejected and leave the stored value untouched.
        assert!(st.set_osc_port(1023).await.is_err());
        assert!(st.set_osc_port(0).await.is_err());
        assert_eq!(Config::load_or_default().unwrap().osc_port, 65535);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn global_macros_upsert_delete_reorder_persist() {
        use channel::MacroMessage;
        let _guard = config::test_data_dir_guard().await;
        let dir = std::env::temp_dir().join(format!("patch-test-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        config::set_data_dir(dir.clone());

        let st = test_state();
        let mk = |l: &str| MacroMessage {
            label: l.into(),
            payload: l.into(),
            key_binding: None,
            priority: 1,
            midi_note: None,
            midi_cc: None,
            osc: None,
        };
        let labels = |c: &Config| {
            c.global_macros
                .iter()
                .map(|m| m.label.clone())
                .collect::<Vec<_>>()
        };

        st.upsert_global_macro(mk("A")).await.unwrap();
        st.upsert_global_macro(mk("B")).await.unwrap();
        st.upsert_global_macro(mk("C")).await.unwrap();
        // Re-upsert with an existing label replaces in place (no duplicate).
        st.upsert_global_macro(MacroMessage {
            label: "B".into(),
            payload: "B2".into(),
            key_binding: None,
            priority: 2,
            midi_note: None,
            midi_cc: None,
            osc: None,
        })
        .await
        .unwrap();
        let cfg = st.config().await;
        assert_eq!(labels(&cfg), vec!["A", "B", "C"]);
        assert_eq!(
            cfg.global_macros
                .iter()
                .find(|m| m.label == "B")
                .unwrap()
                .payload,
            "B2"
        );

        // Reorder: C,A first; B (unlisted) appended; unknown label ignored.
        st.reorder_global_macros(vec!["C".into(), "A".into(), "ghost".into()])
            .await
            .unwrap();
        assert_eq!(labels(&st.config().await), vec!["C", "A", "B"]);

        st.delete_global_macro("A").await.unwrap();
        assert_eq!(labels(&st.config().await), vec!["C", "B"]);

        // Persisted to disk.
        let loaded = Config::load_or_default().unwrap();
        assert_eq!(
            loaded
                .global_macros
                .iter()
                .map(|m| m.label.clone())
                .collect::<Vec<_>>(),
            vec!["C", "B"]
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn reset_global_macros_restores_defaults() {
        let _guard = config::test_data_dir_guard().await;
        let dir = std::env::temp_dir().join(format!("patch-test-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        config::set_data_dir(dir.clone());

        let st = test_state(); // starts with no global macros
        st.upsert_global_macro(channel::MacroMessage {
            label: "CUSTOM".into(),
            payload: "x".into(),
            key_binding: None,
            priority: 1,
            midi_note: None,
            midi_cc: None,
            osc: None,
        })
        .await
        .unwrap();
        assert_eq!(st.config().await.global_macros.len(), 1);

        st.reset_global_macros().await.unwrap();

        let want: Vec<String> = config::default_global_macros()
            .iter()
            .map(|m| m.label.clone())
            .collect();
        let got: Vec<String> = st
            .config()
            .await
            .global_macros
            .iter()
            .map(|m| m.label.clone())
            .collect();
        assert_eq!(got, want); // custom replaced by the factory set
                               // Persisted to disk.
        assert_eq!(
            Config::load_or_default().unwrap().global_macros.len(),
            want.len()
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn apply_show_file_full_restores_static_peers() {
        // Touches disk (persists config) — pin a temp data dir.
        let _guard = config::test_data_dir_guard().await;
        let dir = std::env::temp_dir().join(format!("patch-test-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        config::set_data_dir(dir.clone());

        // Start with a pre-existing static peer that the show file should replace.
        let st = AppState::new(Config {
            default_channels: Vec::new(),
            static_peers: vec![config::StaticPeer {
                address: "192.168.1.99".into(),
                port: 9000,
                label: Some("OLD".into()),
            }],
            ..Config::default()
        });

        let channels = vec![channel::Channel::new("rf", "RF", "#1E88E5")];
        let show_file_peers = vec![
            config::StaticPeer {
                address: "10.0.0.10".into(),
                port: 9000,
                label: Some("Booth".into()),
            },
            // Duplicate of the first — must be de-duplicated.
            config::StaticPeer {
                address: "10.0.0.10".into(),
                port: 9000,
                label: Some("Booth dup".into()),
            },
            // Invalid address — must be skipped, not stored.
            config::StaticPeer {
                address: "not-an-ip".into(),
                port: 9000,
                label: None,
            },
            // Port 0 — must be skipped.
            config::StaticPeer {
                address: "10.0.0.11".into(),
                port: 0,
                label: None,
            },
        ];
        st.apply_show_file_full(channels, show_file_peers)
            .await
            .unwrap();

        let cfg = st.config().await;
        // Old peer replaced; only the one valid, de-duped peer remains.
        assert_eq!(cfg.static_peers.len(), 1);
        assert_eq!(cfg.static_peers[0].address, "10.0.0.10");
        assert!(cfg.static_peers.iter().all(|p| p.address != "192.168.1.99"));
        // Channels replaced too, and the change persisted to disk.
        let loaded = Config::load_or_default().unwrap();
        assert_eq!(loaded.static_peers.len(), 1);
        assert_eq!(loaded.default_channels.len(), 1);
        assert_eq!(loaded.default_channels[0].id, "rf");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn merge_channels_adds_missing_keeps_existing_skips_invalid() {
        use channel::Channel;
        let _guard = config::test_data_dir_guard().await;
        let dir = std::env::temp_dir().join(format!("patch-test-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        config::set_data_dir(dir.clone());

        let st = test_state();
        // Pre-existing channel with a distinctive colour we must NOT overwrite.
        let mut existing = Channel::new("rf", "RF", "#000000");
        existing.macros = vec![channel::MacroMessage {
            label: "KEEP".into(),
            payload: "keep".into(),
            key_binding: None,
            priority: 1,
            midi_note: None,
            midi_cc: None,
            osc: None,
        }];
        st.upsert_channel(existing).await;

        // An incoming channel that carries the source's behavioural flags — these
        // must NOT be inherited (reset to this machine's defaults on adopt).
        let mut hot = Channel::new("audio", "AUDIO", "#E53935");
        hot.flash_on_message = true; // source had "flash on every message"
        hot.flash_on_critical = false;
        hot.flash_count = Some(7);

        let added = st
            .merge_channels(vec![
                // Same id as existing — must be skipped (colour/macros preserved).
                Channel::new("rf", "RF NEW", "#FFFFFF"),
                // New — added (but with flash flags normalised, see below).
                hot,
                // Reserved id — skipped.
                Channel::new("__all__", "ALL", "#fff"),
                // OSC-unsafe id — skipped.
                Channel::new("BAD/../x", "BAD", "#fff"),
            ])
            .await
            .unwrap();
        assert_eq!(added, 1); // only "audio"

        // Adopted "audio" keeps structure but NOT the source's flash prefs:
        // test_state's config defaults are flash_on_critical=true / flash_on_message=false.
        let audio = st
            .get_channels()
            .await
            .into_iter()
            .find(|c| c.id == "audio")
            .unwrap();
        assert!(
            !audio.flash_on_message,
            "must not inherit flash-on-every-message"
        );
        assert!(audio.flash_on_critical, "reset to local default (true)");
        assert_eq!(
            audio.flash_count, None,
            "per-channel pulse override cleared"
        );

        let chans = st.get_channels().await;
        let ids: Vec<_> = chans.iter().map(|c| c.id.as_str()).collect();
        assert!(ids.contains(&"rf"));
        assert!(ids.contains(&"audio"));
        assert!(!ids.contains(&"__all__"));
        assert!(!ids.contains(&"BAD/../x"));
        // Existing "rf" untouched.
        let rf = chans.iter().find(|c| c.id == "rf").unwrap();
        assert_eq!(rf.color, "#000000");
        assert_eq!(rf.display_name, "RF");
        assert_eq!(rf.macros.len(), 1);
        assert_eq!(rf.macros[0].label, "KEEP");

        // Merging the same set again adds nothing.
        let again = st
            .merge_channels(vec![Channel::new("audio", "AUDIO", "#E53935")])
            .await
            .unwrap();
        assert_eq!(again, 0);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn apply_show_file_rejects_invalid_channel_id() {
        let st = test_state();
        // A crafted/hand-edited show file with an OSC-unsafe id must be rejected
        // wholesale — and must not partially apply (the valid channel alongside
        // it should not be inserted either).
        let bad = channel::Channel::new("RF/../x", "RF", "#1E88E5");
        let good = channel::Channel::new("audio", "AUDIO", "#E53935");
        // Validation runs before any mutation, so the call errors and never
        // clears/persists — the good channel beside the bad one isn't applied.
        assert!(st.apply_show_file(vec![good, bad]).await.is_err());
        assert!(st.get_channels().await.is_empty());
    }

    #[tokio::test]
    async fn mdns_resolution_does_not_refresh_liveness() {
        let st = test_state();
        let pid = Uuid::new_v4();
        let old = chrono::Utc::now() - chrono::Duration::seconds(120);
        // Known peer, last actually heard (via OSC) 120 s ago — stale.
        st.upsert_peer_with_mode(presence(pid, old), peer::DiscoveryMode::OscBeacon)
            .await;
        // A cached mDNS record re-resolves it with an address.
        st.resolve_peer_address(presence(pid, chrono::Utc::now()), "10.0.0.2".into(), 9000)
            .await;

        let p = st
            .get_peers()
            .await
            .into_iter()
            .find(|p| p.peer_id == pid)
            .unwrap();
        assert_eq!(p.address, "10.0.0.2"); // address updated for unicast
        assert!(matches!(p.discovery_mode, peer::DiscoveryMode::Mdns)); // reclassified
        assert!(p.is_stale(35)); // last_seen NOT refreshed — still stale
    }

    #[tokio::test]
    async fn mdns_only_peer_starts_stale() {
        let st = test_state();
        let pid = Uuid::new_v4();
        // First (and only) contact is mDNS — no OSC liveness yet.
        st.resolve_peer_address(presence(pid, chrono::Utc::now()), "10.0.0.3".into(), 9000)
            .await;

        let p = st
            .get_peers()
            .await
            .into_iter()
            .find(|p| p.peer_id == pid)
            .unwrap();
        assert_eq!(p.address, "10.0.0.3");
        assert!(p.is_stale(35)); // grey until a real OSC packet arrives
    }

    #[tokio::test]
    async fn mark_peer_offline_sets_departed_keeps_last_seen() {
        let st = test_state();
        let pid = Uuid::new_v4();
        // A live peer (heard just now, with an address).
        st.upsert_peer(presence(pid, chrono::Utc::now())).await;
        st.touch_peer_address(pid, "10.0.0.4".into(), 9000).await;
        // Graceful departure (e.g. /patch/bye or mDNS ServiceRemoved).
        st.mark_peer_offline(pid).await;

        let peers = st.get_peers().await;
        let p = peers
            .iter()
            .find(|p| p.peer_id == pid)
            .expect("peer kept in the list");
        assert!(p.departed); // flagged as departed → UI shows "left"
        assert!(!p.is_stale(35)); // last_seen NOT backdated — real timestamp kept
        assert!(p.has_address()); // address retained for a possible reconnect
    }

    #[tokio::test]
    async fn received_packet_clears_departed() {
        let st = test_state();
        let pid = Uuid::new_v4();
        st.upsert_peer(presence(pid, chrono::Utc::now())).await;
        st.touch_peer_address(pid, "10.0.0.4".into(), 9000).await;
        st.mark_peer_offline(pid).await;
        // The peer comes back — any real OSC packet refreshes the address.
        st.touch_peer_address(pid, "10.0.0.4".into(), 9000).await;

        let peers = st.get_peers().await;
        let p = peers.iter().find(|p| p.peer_id == pid).unwrap();
        assert!(!p.departed); // reconnect cleared the flag
        assert!(!p.is_stale(35));
    }

    /// Exercises the real save path (`save_config` → `spawn_blocking`) end to end:
    /// mutations must land in the on-disk `patch.toml`. The sole disk-touching
    /// test, so the process-global `set_data_dir` override is unambiguous.
    #[tokio::test]
    async fn config_mutations_persist_to_disk() {
        let _guard = config::test_data_dir_guard().await;
        let dir = std::env::temp_dir().join(format!("patch-test-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        config::set_data_dir(dir.clone());

        let st = test_state();
        st.set_flash_count(6).await.unwrap();
        st.set_hide_keyboard(false).await.unwrap();
        st.set_audible_alert(true).await.unwrap();
        st.set_macros_columns(2).await.unwrap();
        st.add_static_peer("10.0.0.5".into(), 9000, Some("Booth".into()))
            .await
            .unwrap();

        let loaded = Config::load_or_default().unwrap();
        assert_eq!(loaded.flash_count, 6);
        assert!(!loaded.hide_keyboard);
        assert!(loaded.audible_alert);
        assert_eq!(loaded.macros_columns, 2);
        assert_eq!(loaded.static_peers.len(), 1);
        assert_eq!(loaded.static_peers[0].address, "10.0.0.5");

        let _ = std::fs::remove_dir_all(&dir);
    }
}
