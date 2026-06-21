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
    /// The peer id of the DM thread currently open in the UI, if any. Pushed
    /// from Flutter via `set_dm_target` alongside `selected` (see
    /// `_syncSelection` in home_screen.dart). Read by the MIDI listener so a
    /// macro fired while a DM is open routes to that peer instead of a channel
    /// — mirroring `_fireMacro`'s DM-mode rule, which sends *every* macro
    /// (per-channel or global) as a DM when one is open.
    pub dm_target: RwLock<Option<Uuid>>,
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

/// True when `id` is our own client_id — every event/discovery loop that
/// receives its own broadcast back must filter it out before treating it as
/// a peer. Naming the check gives the rule one place to grep for instead of
/// an inline `==`/`!=` that looks safe to drop in isolation (see ERRORS.md:
/// both self-discovery guards have been removed by accident before).
pub fn is_self(id: Uuid, client_id: Uuid) -> bool {
    id == client_id
}

/// What kind of evidence a Peer sighting is — passed to
/// [`AppState::record_sighting`], which applies the matching liveness/
/// classification rule. Each call site reports the strongest evidence it
/// actually has; the union of "every received packet" and "an mDNS
/// resolution" is what builds up the peer registry.
pub enum PeerSighting {
    /// A full `/patch/presence` heartbeat — proves liveness and carries the
    /// peer's current name/channels/role.
    Presence(PeerPresence),
    /// Any other received OSC packet naming a sender (`Message`/`Flash`/
    /// `DirectMessage`/`DirectFlash`) — proves liveness, but carries nothing
    /// beyond the sender's id and name.
    Heartbeat { peer_id: Uuid, peer_name: String },
    /// An mDNS resolution — gives an address to unicast to, but does **not**
    /// prove current liveness: `mdns-sd` replays cached resolutions for
    /// ~1–2 min after a peer quits (see ERRORS.md).
    Mdns(PeerPresence),
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
            dm_target: RwLock::new(None),
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

    /// Set (or clear) the peer id of the DM thread currently open in the UI
    /// (runtime only — not persisted). Read by the MIDI listener so a macro
    /// fired while a DM is open routes to that peer instead of a channel.
    pub async fn set_dm_target(&self, peer_id: Option<Uuid>) {
        *self.0.dm_target.write().await = peer_id;
    }

    /// The peer id of the open DM thread, or `None` when no DM is open.
    pub async fn dm_target(&self) -> Option<Uuid> {
        *self.0.dm_target.read().await
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
        let peer = config::StaticPeer::new(address, port, label)?;
        {
            let mut cfg = self.0.config.write().await;
            if cfg
                .static_peers
                .iter()
                .any(|p| p.address == peer.address && p.port == peer.port)
            {
                anyhow::bail!("Peer {}:{} is already configured", peer.address, peer.port);
            }
            cfg.static_peers.push(peer);
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

    /// Records evidence that a [Peer] is out there. The single entry point for
    /// "a Peer was seen" — each call carries the address it was seen at and
    /// the kind of evidence it is, which determines the liveness/classification
    /// rule applied (see each variant's doc comment). Replaces what used to be
    /// four separate functions (`upsert_peer`, `upsert_peer_with_mode`,
    /// `touch_peer_address`, `resolve_peer_address`), each covering a slice of
    /// this and leaving a caller to pick the right one.
    pub async fn record_sighting(&self, sighting: PeerSighting, address: String, port: u16) {
        let presence = {
            let mut peers = self.0.peers.write().await;
            match sighting {
                PeerSighting::Presence(presence) => {
                    let mut new_peer = peer::Peer::from_presence(presence.clone());
                    // Once a peer has been resolved via mDNS, keep that
                    // classification — a subsequent OSC presence heartbeat
                    // shouldn't downgrade the icon.
                    if let Some(existing) = peers.get(&presence.peer_id) {
                        if matches!(existing.discovery_mode, peer::DiscoveryMode::Mdns) {
                            new_peer.discovery_mode = peer::DiscoveryMode::Mdns;
                        }
                    }
                    new_peer.address = address;
                    new_peer.osc_port = port;
                    peers.insert(presence.peer_id, new_peer);
                    presence
                }
                PeerSighting::Heartbeat { peer_id, peer_name } => match peers.get_mut(&peer_id) {
                    Some(peer) => {
                        peer.address = address;
                        peer.osc_port = port;
                        peer.last_seen = chrono::Utc::now();
                        // A real OSC packet proves liveness — clear any prior departure.
                        peer.departed = false;
                        PeerPresence {
                            peer_id: peer.peer_id,
                            peer_name: peer.peer_name.clone(),
                            channels: peer.channels.clone(),
                            role: peer.role.clone(),
                            timestamp: peer.last_seen,
                        }
                    }
                    None => {
                        // Seen for the first time outside the presence heartbeat
                        // — e.g. a Message/Flash/DM arriving before any
                        // `/patch/presence` (AP isolation blocking broadcasts).
                        // Role/channels stay unknown until their presence
                        // heartbeat arrives.
                        let presence = PeerPresence {
                            peer_id,
                            peer_name,
                            channels: Vec::new(),
                            role: None,
                            timestamp: chrono::Utc::now(),
                        };
                        let mut new_peer = peer::Peer::from_presence(presence.clone());
                        new_peer.address = address;
                        new_peer.osc_port = port;
                        peers.insert(peer_id, new_peer);
                        presence
                    }
                },
                PeerSighting::Mdns(presence) => match peers.get_mut(&presence.peer_id) {
                    Some(peer) => {
                        // mDNS resolution can be replayed from a stale cache long
                        // after a peer has quit, so it proves only that we have an
                        // address to unicast to — not that the peer is currently
                        // up. Liveness (`last_seen`) comes solely from a
                        // `Heartbeat`/`Presence` sighting, never from here.
                        if !address.is_empty() {
                            peer.address = address;
                            peer.osc_port = port;
                        }
                        peer.discovery_mode = peer::DiscoveryMode::Mdns;
                        PeerPresence {
                            peer_id: peer.peer_id,
                            peer_name: peer.peer_name.clone(),
                            channels: peer.channels.clone(),
                            role: peer.role.clone(),
                            timestamp: peer.last_seen,
                        }
                    }
                    None => {
                        let mut new_peer = peer::Peer::from_presence(presence.clone());
                        new_peer.discovery_mode = peer::DiscoveryMode::Mdns;
                        // Same rule as the `Some` branch above: an unresolved pinned
                        // subnet means `address` is empty — leave the peer with no
                        // address (its `from_presence` default) rather than store an
                        // empty one, so `Peer::has_address`/`socket_addr` correctly
                        // read it as unreachable instead of address == "".
                        if !address.is_empty() {
                            new_peer.address = address;
                            new_peer.osc_port = port;
                        }
                        // Backdate past the UI's stale threshold so the dot starts grey.
                        new_peer.last_seen = chrono::Utc::now() - chrono::Duration::seconds(60);
                        peers.insert(presence.peer_id, new_peer);
                        presence
                    }
                },
            }
        };
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
    /// reconnect (any received OSC packet) clears `departed` via a
    /// `PeerSighting::Presence`/`Heartbeat` sighting. No-op if the peer isn't
    /// currently known.
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

    /// Resolved addresses of peers a critical message shouldn't bother
    /// tracking for an ACK (see `Peer::looks_offline`) — used to skip
    /// retransmit/failure-warning noise for peers we already know are gone,
    /// without skipping the best-effort send itself (they might still be
    /// there despite a missed heartbeat).
    pub async fn offline_addresses(&self, heartbeat_secs: u64) -> HashSet<std::net::SocketAddr> {
        self.get_peers()
            .await
            .iter()
            .filter(|p| p.looks_offline(heartbeat_secs))
            .filter_map(|p| p.socket_addr())
            .collect()
    }

    /// Resolved addresses of every known peer except ourselves, deduped by
    /// `SocketAddr` (a static peer also seen dynamically is contacted once).
    /// Shared by `Transport::send_to_peers` (direct socket send) and the
    /// `/patch/say` relay (queued via `send_tx`) — same target list, two
    /// different ways of actually sending to it.
    pub async fn reachable_peer_addrs(&self, client_id: Uuid) -> Vec<std::net::SocketAddr> {
        let mut seen = HashSet::new();
        self.get_peers()
            .await
            .into_iter()
            .filter(|p| p.peer_id != client_id)
            .filter_map(|p| p.socket_addr())
            .filter(|addr| seen.insert(*addr))
            .collect()
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
            channel::validate_channel_id(&ch.id).map_err(|e| {
                anyhow::anyhow!("show file contains invalid channel id {:?} — {}", ch.id, e)
            })?;
            for m in &ch.macros {
                if let Some(osc) = &m.osc {
                    channel::validate_osc_target(osc).map_err(|e| {
                        anyhow::anyhow!(
                            "show file macro {:?} on channel {:?} has an invalid OSC target — {}",
                            m.label,
                            ch.id,
                            e
                        )
                    })?;
                }
            }
        }
        let mut validated_peers: Vec<config::StaticPeer> = Vec::with_capacity(static_peers.len());
        let mut seen: HashSet<(String, u16)> = HashSet::new();
        for sp in static_peers {
            if let Err(e) = config::validate_static_peer(&sp.address, sp.port) {
                tracing::warn!(
                    "show_file: skipping static peer {:?}:{} — {}",
                    sp.address,
                    sp.port,
                    e
                );
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
                if let Err(e) = channel::validate_channel_id(&ch.id) {
                    tracing::warn!(
                        "merge_channels: skipping invalid/reserved id {:?}: {}",
                        ch.id,
                        e
                    );
                    continue;
                }
                if map.contains_key(&ch.id) {
                    continue; // keep the existing channel untouched
                }
                // Reset behavioural flags to local defaults (structure-only adopt).
                ch.flash_on_critical = flash_on_critical;
                ch.flash_on_message = flash_on_message;
                ch.flash_count = None;
                // Untrusted peer input (possibly a different/older Patch build) —
                // drop just the one macro with an invalid OSC target rather than
                // rejecting the whole channel; see ADR-0002.
                ch.macros.retain(|m| {
                    let Some(osc) = &m.osc else { return true };
                    match channel::validate_osc_target(osc) {
                        Ok(()) => true,
                        Err(e) => {
                            tracing::warn!(
                                "merge_channels: dropping macro {:?} on channel {:?} — invalid OSC target: {}",
                                m.label,
                                ch.id,
                                e
                            );
                            false
                        }
                    }
                });
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
            channel::validate_channel_id(&ch.id).map_err(|e| {
                anyhow::anyhow!("show file contains invalid channel id {:?} — {}", ch.id, e)
            })?;
            for m in &ch.macros {
                if let Some(osc) = &m.osc {
                    channel::validate_osc_target(osc).map_err(|e| {
                        anyhow::anyhow!(
                            "show file macro {:?} on channel {:?} has an invalid OSC target — {}",
                            m.label,
                            ch.id,
                            e
                        )
                    })?;
                }
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

    /// Test-only: directly inserts a peer with an explicit `DiscoveryMode`,
    /// bypassing `record_sighting`. There's no real `PeerSighting` for
    /// `ManualIp` — that classification is only ever synthesized by
    /// `get_peers()` from `config.static_peers`, never observed on the wire —
    /// so fixtures that need a `ManualIp` peer already in `self.0.peers` (to
    /// test the staleness-exemption rule itself, not how peers normally get
    /// there) go around `record_sighting` on purpose.
    async fn insert_peer_for_test(
        st: &AppState,
        id: Uuid,
        last_seen: chrono::DateTime<chrono::Utc>,
        mode: peer::DiscoveryMode,
        address: &str,
        port: u16,
    ) {
        let mut peers = st.0.peers.write().await;
        let mut p = peer::Peer::from_presence(presence(id, last_seen));
        p.discovery_mode = mode;
        p.address = address.to_string();
        p.osc_port = port;
        peers.insert(id, p);
    }

    /// Test-only: builds a `Channel` with a deliberately illegal id, bypassing
    /// `Channel::new`'s validation. Stands in for how an illegal id actually
    /// reaches this code in production — not via the constructor at all, but
    /// via `serde::Deserialize` on untrusted input (a show file, a peer's
    /// `channels_announce`) — which is exactly why `apply_show_file`/
    /// `apply_show_file_full`/`merge_channels` each still validate explicitly.
    fn invalid_channel(id: &str, display_name: &str, color: &str) -> channel::Channel {
        channel::Channel {
            id: id.to_string(),
            display_name: display_name.to_string(),
            color: color.to_string(),
            macros: Vec::new(),
            flash_on_critical: true,
            flash_on_message: false,
            flash_count: None,
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
        st.record_sighting(
            PeerSighting::Presence(presence(pid, chrono::Utc::now())),
            "192.168.1.50".into(),
            9000,
        )
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
        st.record_sighting(
            PeerSighting::Presence(presence(stale_dyn, old)),
            String::new(),
            0,
        )
        .await;
        let fresh_dyn = Uuid::new_v4();
        st.record_sighting(
            PeerSighting::Presence(presence(fresh_dyn, now)),
            String::new(),
            0,
        )
        .await;
        let stale_manual = Uuid::new_v4();
        insert_peer_for_test(&st, stale_manual, old, peer::DiscoveryMode::ManualIp, "", 0).await;

        let removed = st.clear_stale_peers(60).await;
        assert_eq!(removed, vec![stale_dyn]); // only the stale dynamic one

        let ids: Vec<_> = st.get_peers().await.iter().map(|p| p.peer_id).collect();
        assert!(ids.contains(&fresh_dyn));
        assert!(ids.contains(&stale_manual)); // ManualIp never removed
        assert!(!ids.contains(&stale_dyn));
    }

    #[tokio::test]
    async fn offline_addresses_includes_departed_and_stale_excludes_fresh_and_manual() {
        let st = test_state();
        let heartbeat_secs = 7u64; // offline threshold = 35s (5x)

        // Departed (clean bye) — offline regardless of last_seen recency.
        let departed = Uuid::new_v4();
        st.record_sighting(
            PeerSighting::Presence(presence(departed, chrono::Utc::now())),
            "10.0.0.1".into(),
            9000,
        )
        .await;
        st.mark_peer_offline(departed).await;

        // Quiet well past 5x the heartbeat — offline. A Presence sighting
        // honours the presence's own (old) timestamp rather than forcing
        // `now()`, so the address can be set in the same call without also
        // refreshing `last_seen` — true to how a peer that's gone quiet would
        // actually look: heard from, with a resolved address, a long time
        // ago, and nothing since.
        let stale = Uuid::new_v4();
        let old = chrono::Utc::now() - chrono::Duration::seconds(3600);
        st.record_sighting(
            PeerSighting::Presence(presence(stale, old)),
            "10.0.0.2".into(),
            9000,
        )
        .await;

        // Heard from recently — still online.
        let fresh = Uuid::new_v4();
        st.record_sighting(
            PeerSighting::Presence(presence(fresh, chrono::Utc::now())),
            "10.0.0.3".into(),
            9000,
        )
        .await;

        // Manual/static peer — never heartbeats, so staleness can't apply
        // even though its synthetic last_seen looks fresh.
        let manual = Uuid::new_v4();
        insert_peer_for_test(
            &st,
            manual,
            old,
            peer::DiscoveryMode::ManualIp,
            "10.0.0.4",
            9000,
        )
        .await;

        let offline = st.offline_addresses(heartbeat_secs).await;
        assert!(offline.contains(&"10.0.0.1:9000".parse().unwrap()));
        assert!(offline.contains(&"10.0.0.2:9000".parse().unwrap()));
        assert!(!offline.contains(&"10.0.0.3:9000".parse().unwrap()));
        assert!(!offline.contains(&"10.0.0.4:9000".parse().unwrap()));
    }

    #[tokio::test]
    async fn reachable_peer_addrs_excludes_self_and_unaddressed_dedups_static() {
        let client_id = Uuid::new_v4();

        let dynamic = Uuid::new_v4();
        let st = AppState::new(Config {
            default_channels: Vec::new(),
            // Same address+port as the dynamic peer below — should be merged,
            // not contacted a second time (send_to_peers' double-fire trap).
            static_peers: vec![config::StaticPeer {
                address: "10.0.0.5".into(),
                port: 9000,
                label: None,
            }],
            client_id,
            ..Config::default()
        });
        st.record_sighting(
            PeerSighting::Presence(presence(dynamic, chrono::Utc::now())),
            "10.0.0.5".into(),
            9000,
        )
        .await;

        // A peer with no address yet (presence not yet resolved) is excluded.
        let unaddressed = Uuid::new_v4();
        st.record_sighting(
            PeerSighting::Presence(presence(unaddressed, chrono::Utc::now())),
            String::new(),
            0,
        )
        .await;

        // Ourselves, if we somehow ended up in the registry, must be excluded.
        st.record_sighting(
            PeerSighting::Presence(presence(client_id, chrono::Utc::now())),
            "10.0.0.9".into(),
            9000,
        )
        .await;

        let targets = st.reachable_peer_addrs(client_id).await;
        assert_eq!(targets, vec!["10.0.0.5:9000".parse().unwrap()]);
    }

    #[tokio::test]
    async fn heartbeat_sighting_refreshes_address_for_a_known_peer() {
        let st = test_state();
        let id = Uuid::new_v4();
        st.record_sighting(
            PeerSighting::Presence(presence(id, chrono::Utc::now())),
            "10.0.0.1".into(),
            9000,
        )
        .await;

        // A later Heartbeat sighting (e.g. a Message arriving from a
        // different address — a reconnect over a different NIC/VPN) updates
        // the address. This single call now also covers what the deleted
        // generic per-packet `touch_peer_address` used to do for every event
        // in the protocol dispatch before this peer was registered.
        st.record_sighting(
            PeerSighting::Heartbeat {
                peer_id: id,
                peer_name: "someone-else".into(),
            },
            "10.0.0.2".into(),
            9001,
        )
        .await;

        let peers = st.get_peers().await;
        assert_eq!(peers.len(), 1);
        assert_eq!(peers[0].address, "10.0.0.2");
        assert_eq!(peers[0].osc_port, 9001);
    }

    #[tokio::test]
    async fn heartbeat_sighting_registers_a_new_peer() {
        let st = test_state();
        let id = Uuid::new_v4();
        st.record_sighting(
            PeerSighting::Heartbeat {
                peer_id: id,
                peer_name: "newcomer".into(),
            },
            "10.0.0.3".into(),
            9002,
        )
        .await;

        let peers = st.get_peers().await;
        assert_eq!(peers.len(), 1);
        assert_eq!(peers[0].peer_name, "newcomer");
        assert_eq!(peers[0].address, "10.0.0.3");
        assert_eq!(peers[0].osc_port, 9002);
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
        let mut ch = Channel::new("rf", "RF", "#1E88E5").unwrap();
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

        let channels = vec![channel::Channel::new("rf", "RF", "#1E88E5").unwrap()];
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

    /// A macro whose `arg_type`/`arg` pair doesn't parse (e.g. hand-edited
    /// `patch.toml`, or an imported show file from an older/buggier build)
    /// must reject the whole show file load atomically — mirroring how
    /// `apply_show_file_rejects_invalid_channel_id` treats a bad channel id.
    /// See ADR-0002: a local show file load is held to the strictest policy,
    /// unlike `merge_channels`' untrusted-peer skip (tested separately below).
    #[tokio::test]
    async fn apply_show_file_full_rejects_mismatched_macro_arg_type() {
        use crate::osc::types::OscArgKind;

        let st = test_state();

        let mut ch = channel::Channel::new("rf", "RF", "#1E88E5").unwrap();
        ch.macros = vec![channel::MacroMessage {
            label: "GO".into(),
            payload: "go".into(),
            key_binding: None,
            priority: 1,
            midi_note: None,
            midi_cc: None,
            osc: Some(channel::OscTarget {
                address: "10.0.0.10".into(),
                port: 53000,
                path: "/cue/1/start".into(),
                arg: Some("loud".into()),
                arg_type: OscArgKind::Float,
            }),
        }];

        assert!(st.apply_show_file_full(vec![ch], Vec::new()).await.is_err());
        assert!(st.get_channels().await.is_empty());
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
        let mut existing = Channel::new("rf", "RF", "#000000").unwrap();
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
        let mut hot = Channel::new("audio", "AUDIO", "#E53935").unwrap();
        hot.flash_on_message = true; // source had "flash on every message"
        hot.flash_on_critical = false;
        hot.flash_count = Some(7);

        let added = st
            .merge_channels(vec![
                // Same id as existing — must be skipped (colour/macros preserved).
                Channel::new("rf", "RF NEW", "#FFFFFF").unwrap(),
                // New — added (but with flash flags normalised, see below).
                hot,
                // Reserved id — skipped. `Channel::new` now rejects this id
                // outright, so the fixture is built by hand (a deserialized
                // show file / channels_announce Channel bypasses `new` the same
                // way — that's exactly the untrusted input this test stands in for).
                invalid_channel("__all__", "ALL", "#fff"),
                // OSC-unsafe id — skipped.
                invalid_channel("BAD/../x", "BAD", "#fff"),
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
            .merge_channels(vec![Channel::new("audio", "AUDIO", "#E53935").unwrap()])
            .await
            .unwrap();
        assert_eq!(again, 0);

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A peer's channel is untrusted network input (possibly a different/older
    /// Patch build) — one macro with an invalid OSC target must not block
    /// adopting the channel or its other macros, per ADR-0002. Contrast with
    /// `apply_show_file_full_rejects_mismatched_macro_arg_type` above, where the
    /// same kind of bad macro rejects the whole load instead.
    #[tokio::test]
    async fn merge_channels_drops_only_the_invalid_macro() {
        use crate::osc::types::OscArgKind;
        use channel::Channel;

        // merge_channels persists when it adds anything — pin a temp data dir.
        let _guard = config::test_data_dir_guard().await;
        let dir = std::env::temp_dir().join(format!("patch-test-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        config::set_data_dir(dir.clone());

        let st = test_state();

        let mut incoming = Channel::new("rf", "RF", "#1E88E5").unwrap();
        incoming.macros = vec![
            channel::MacroMessage {
                label: "GOOD".into(),
                payload: "go".into(),
                key_binding: None,
                priority: 1,
                midi_note: None,
                midi_cc: None,
                osc: None,
            },
            channel::MacroMessage {
                label: "BAD".into(),
                payload: "loud".into(),
                key_binding: None,
                priority: 1,
                midi_note: None,
                midi_cc: None,
                osc: Some(channel::OscTarget {
                    address: "10.0.0.10".into(),
                    port: 53000,
                    path: "/cue/1/start".into(),
                    arg: Some("loud".into()),
                    arg_type: OscArgKind::Float,
                }),
            },
        ];

        let added = st.merge_channels(vec![incoming]).await.unwrap();
        assert_eq!(added, 1);

        let rf = st
            .get_channels()
            .await
            .into_iter()
            .find(|c| c.id == "rf")
            .unwrap();
        let labels: Vec<_> = rf.macros.iter().map(|m| m.label.as_str()).collect();
        assert_eq!(labels, vec!["GOOD"]);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn apply_show_file_rejects_invalid_channel_id() {
        let st = test_state();
        // A crafted/hand-edited show file with an OSC-unsafe id must be rejected
        // wholesale — and must not partially apply (the valid channel alongside
        // it should not be inserted either).
        let bad = invalid_channel("RF/../x", "RF", "#1E88E5");
        let good = channel::Channel::new("audio", "AUDIO", "#E53935").unwrap();
        // Validation runs before any mutation, so the call errors and never
        // clears/persists — the good channel beside the bad one isn't applied.
        assert!(st.apply_show_file(vec![good, bad]).await.is_err());
        assert!(st.get_channels().await.is_empty());
    }

    #[tokio::test]
    async fn apply_show_file_rejects_reserved_all_id() {
        let st = test_state();
        // A show file is untrusted input — it could name a channel "__all__"
        // (the reserved broadcast id), which apply_show_file used to accept
        // because its loop only checked the OSC slug pattern, not reservation
        // (api::upsert_channel and merge_channels already checked both).
        let reserved = invalid_channel("__all__", "ALL", "#fff");
        assert!(st.apply_show_file(vec![reserved]).await.is_err());
        assert!(st.get_channels().await.is_empty());
    }

    #[tokio::test]
    async fn apply_show_file_full_rejects_reserved_all_id() {
        let st = test_state();
        // Same gap as apply_show_file, in the load/import path that also
        // restores static peers.
        let reserved = invalid_channel("__all__", "ALL", "#fff");
        assert!(st
            .apply_show_file_full(vec![reserved], Vec::new())
            .await
            .is_err());
        assert!(st.get_channels().await.is_empty());
    }

    #[tokio::test]
    async fn mdns_resolution_does_not_refresh_liveness() {
        let st = test_state();
        let pid = Uuid::new_v4();
        let old = chrono::Utc::now() - chrono::Duration::seconds(120);
        // Known peer, last actually heard (via OSC) 120 s ago — stale.
        st.record_sighting(PeerSighting::Presence(presence(pid, old)), String::new(), 0)
            .await;
        // A cached mDNS record re-resolves it with an address.
        st.record_sighting(
            PeerSighting::Mdns(presence(pid, chrono::Utc::now())),
            "10.0.0.2".into(),
            9000,
        )
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
        st.record_sighting(
            PeerSighting::Mdns(presence(pid, chrono::Utc::now())),
            "10.0.0.3".into(),
            9000,
        )
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
    async fn mdns_only_peer_with_unresolved_address_has_no_address() {
        // Mirrors `mdns_resolution_does_not_refresh_liveness`'s known-peer guard
        // (state/mod.rs's `Mdns` arm, `Some` branch): an empty address — e.g.
        // `pick_resolved_address` returning `None` for a pinned interface whose
        // subnet didn't resolve — must not be stored, for a brand-new peer too.
        let st = test_state();
        let pid = Uuid::new_v4();
        st.record_sighting(
            PeerSighting::Mdns(presence(pid, chrono::Utc::now())),
            String::new(),
            0,
        )
        .await;

        let p = st
            .get_peers()
            .await
            .into_iter()
            .find(|p| p.peer_id == pid)
            .unwrap();
        assert!(!p.has_address());
    }

    #[tokio::test]
    async fn mark_peer_offline_sets_departed_keeps_last_seen() {
        let st = test_state();
        let pid = Uuid::new_v4();
        // A live peer (heard just now, with an address).
        st.record_sighting(
            PeerSighting::Presence(presence(pid, chrono::Utc::now())),
            "10.0.0.4".into(),
            9000,
        )
        .await;
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
        st.record_sighting(
            PeerSighting::Presence(presence(pid, chrono::Utc::now())),
            "10.0.0.4".into(),
            9000,
        )
        .await;
        st.mark_peer_offline(pid).await;
        // The peer comes back — any real OSC packet clears the departure.
        st.record_sighting(
            PeerSighting::Heartbeat {
                peer_id: pid,
                peer_name: "p".into(),
            },
            "10.0.0.4".into(),
            9000,
        )
        .await;

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
