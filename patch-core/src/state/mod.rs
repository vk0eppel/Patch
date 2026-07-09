//! Shared application state — channels, peers, message buffer.
//! All access is through `Arc<AppState>`; interior mutation via `tokio::sync::RwLock`.

pub mod channel;
pub mod config;
pub(crate) mod export;
mod message;
mod network_policy;
pub mod peer;
pub mod show_file;

use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use tokio::sync::{broadcast, RwLock};
use uuid::Uuid;

use channel::ChannelRegistry;
use config::ConfigStore;
use message::MessageBuffer;
use network_policy::{MessageDedup, NetworkAdmission};
use peer::PeerRegistry;

use crate::osc::types::{ChannelFlash, PatchMessage, PeerPresence};
pub use config::{Config, ConfigPatch};
pub use peer::PeerSighting;

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
    /// A peer offered its global macros in reply to our request. Surfaced to
    /// the UI for a preview/merge prompt — never auto-applied.
    GlobalMacrosOffered {
        from_peer_id: Uuid,
        from_name: String,
        global_macros: Vec<channel::MacroMessage>,
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
    /// Config store — owns its own lock(s) internally.
    pub config: Arc<ConfigStore>,
    /// Channel/macro registry with auto-persist — owns its own lock internally.
    pub channels: ChannelRegistry,
    /// Peer registry — owns its own lock internally.
    pub peers: PeerRegistry,
    /// Recent messages (ring buffer with dedup) — owns its own lock internally.
    pub messages: MessageBuffer,
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
    /// Global receive-side dedup cache — message IDs seen in the last 10 s.
    seen_messages: MessageDedup,
    /// Pinned Network admission (ADR-0010) and its rate-limited drop log.
    network_admission: NetworkAdmission,
}

/// True when `id` is our own client_id — every event/discovery loop that
/// receives its own broadcast back must filter it out before treating it as
/// a peer. Naming the check gives the rule one place to grep for instead of
/// an inline `==`/`!=` that looks safe to drop in isolation (see ERRORS.md:
/// both self-discovery guards have been removed by accident before).
pub fn is_self(id: Uuid, client_id: Uuid) -> bool {
    id == client_id
}

impl AppState {
    pub fn new(config: Config) -> Self {
        let (tx, _) = broadcast::channel(256);
        let channel_data = config.default_channels.clone();
        let pinned_subnet = config
            .network_interface
            .as_deref()
            .and_then(crate::transport::pinned_ipv4_subnet);
        let config_arc = Arc::new(ConfigStore::new(config));
        let channels = ChannelRegistry::seeded(channel_data).attach_config(Arc::clone(&config_arc));

        Self(Arc::new(Inner {
            config: config_arc,
            channels,
            peers: PeerRegistry::default(),
            messages: MessageBuffer::default(),
            selected: RwLock::new(Vec::new()),
            dm_target: RwLock::new(None),
            events: tx,
            seen_messages: MessageDedup::new(),
            network_admission: NetworkAdmission::new(pinned_subnet),
        }))
    }

    /// Returns a snapshot clone of the current config.
    pub async fn config(&self) -> Config {
        self.0.config.snapshot().await
    }

    pub fn subscribe(&self) -> broadcast::Receiver<AppEvent> {
        self.0.events.subscribe()
    }

    pub async fn publish(&self, event: AppEvent) {
        let _ = self.0.events.send(event);
    }

    // ── Client name ───────────────────────────────────────────────────────────

    pub async fn set_client_name(&self, name: String) -> anyhow::Result<()> {
        self.0
            .config
            .mutate_and_persist(|c| c.client_name = name.clone())
            .await;
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
        self.0.config.mutate_and_persist(|c| c.role = role).await;
        Ok(())
    }

    /// Persist the discovery-beacon interface scope. Pinning is mandatory
    /// (ADR-0011) — None means unresolved, not "announce on all." Applies
    /// live — the heartbeat re-reads it each tick; the socket always binds
    /// 0.0.0.0, so there's nothing to rebind.
    ///
    /// Also clears all dynamically-discovered peers (OscBeacon/Mdns) so the
    /// peer list rebuilds via the new NIC's discovery. ManualIp/static peers
    /// are kept — their addresses don't depend on which NIC was used.
    pub async fn set_network_interface(&self, iface: Option<String>) -> anyhow::Result<()> {
        self.0
            .config
            .mutate_and_persist(|c| c.network_interface = iface.clone())
            .await;
        // Recompute the cached Pinned Network for the per-packet admission
        // check (ADR-0010) — the one place besides construction it changes.
        self.0.network_admission.set_pinned_subnet(
            iface
                .as_deref()
                .and_then(crate::transport::pinned_ipv4_subnet),
        );
        // Only clear dynamic peers when switching TO a pinned interface. The
        // per-address prune window handles dead paths without a full clear.
        if iface.is_some() {
            let removed = self.clear_dynamic_peers().await;
            for id in removed {
                self.publish(AppEvent::PeerExpired(id)).await;
            }
        }
        Ok(())
    }

    /// Remove all OscBeacon/Mdns peers from the registry immediately.
    /// ManualIp/static peers are never touched.
    /// Returns the IDs of removed peers so callers can emit PeerExpired events.
    async fn clear_dynamic_peers(&self) -> Vec<Uuid> {
        self.0.peers.clear_dynamic().await
    }

    /// Apply a partial update of the scalar behavior settings in one persisted
    /// mutation — the single entry point replacing the old per-field setters
    /// (issue #179). Ranged fields are clamped in `ConfigPatch::apply`; an
    /// empty patch is a no-op (nothing persisted).
    pub async fn patch_config(&self, patch: config::ConfigPatch) -> anyhow::Result<()> {
        if patch.is_empty() {
            return Ok(());
        }
        self.0
            .config
            .mutate_and_persist(move |c| patch.apply(c))
            .await;
        Ok(())
    }

    /// Persist the presence heartbeat interval (seconds). Validated 1–60: below
    /// floods the LAN, above makes peer detection uselessly slow. Applies live —
    /// the discovery heartbeat loop re-reads it at the end of each cycle, so the
    /// new cadence takes effect on the next beat with no restart.
    pub async fn set_heartbeat_interval(&self, secs: u64) -> anyhow::Result<()> {
        use config::{HEARTBEAT_MAX_SECS, HEARTBEAT_MIN_SECS};
        if !(HEARTBEAT_MIN_SECS..=HEARTBEAT_MAX_SECS).contains(&secs) {
            anyhow::bail!(
                "heartbeat interval must be {}–{} seconds (got {})",
                HEARTBEAT_MIN_SECS,
                HEARTBEAT_MAX_SECS,
                secs
            );
        }
        self.0
            .config
            .mutate_and_persist(|c| c.heartbeat_interval_secs = secs)
            .await;
        Ok(())
    }

    /// Persist the OSC UDP port. Validated 1024–65535 (privileged ports < 1024
    /// need root and would fail to bind). The live socket rebind is driven by the
    /// caller (`api::set_osc_port`) after this persists.
    pub async fn set_osc_port(&self, port: u16) -> anyhow::Result<()> {
        if !(1024..=65535).contains(&port) {
            anyhow::bail!("OSC port must be 1024–65535 (got {})", port);
        }
        self.0
            .config
            .mutate_and_persist(|c| c.osc_port = port)
            .await;
        Ok(())
    }

    /// Restore every scalar behavior setting to its factory default
    /// (`ConfigPatch::behavior_defaults()`) in one persisted mutation.
    pub async fn reset_behavior_config(&self) -> anyhow::Result<()> {
        self.patch_config(config::ConfigPatch::behavior_defaults())
            .await
    }

    /// Update per-channel flash flags. `None` means "leave unchanged".
    pub async fn set_channel_flash(
        &self,
        channel_id: &str,
        flash_on_critical: Option<bool>,
        flash_on_message: Option<bool>,
        flash_count: Option<u8>,
    ) -> anyhow::Result<()> {
        self.0
            .channels
            .set_flash(channel_id, flash_on_critical, flash_on_message, flash_count)
            .await?;
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
        self.0
            .config
            .mutate_and_persist(|cfg| {
                if cfg
                    .static_peers
                    .iter()
                    .any(|p| p.address == peer.address && p.port == peer.port)
                {
                    anyhow::bail!("Peer {}:{} is already configured", peer.address, peer.port);
                }
                cfg.static_peers.push(peer);
                Ok(())
            })
            .await?;
        Ok(())
    }

    pub async fn remove_static_peer(&self, address: &str, port: u16) -> anyhow::Result<()> {
        self.0
            .config
            .mutate_and_persist(|cfg| {
                cfg.static_peers
                    .retain(|p| !(p.address == address && p.port == port))
            })
            .await;
        Ok(())
    }

    // ── Messages ──────────────────────────────────────────────────────────────

    pub async fn store_message(&self, msg: PatchMessage) {
        // Deduplicate — our own broadcast comes back over UDP, so the same
        // message_id can arrive twice (once on send, once on receive).
        if self.0.messages.store(msg.clone()).await {
            self.publish(AppEvent::MessageReceived(msg)).await;
        }
    }

    /// Clear messages for a specific channel, or all channels when `channel_id` is `None`.
    pub async fn clear_messages(&self, channel_id: Option<&str>) {
        self.0.messages.clear(channel_id).await;
    }

    pub async fn get_all_messages(&self) -> Vec<PatchMessage> {
        self.0.messages.get_all().await
    }

    pub async fn get_messages(&self, channel_id: &str, limit: usize) -> Vec<PatchMessage> {
        self.0.messages.get(channel_id, limit).await
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
        let presence = self.0.peers.record_sighting(sighting, address, port).await;
        self.publish(AppEvent::PeerUpdated(presence)).await;
    }

    /// Remove dynamic (OscBeacon / Mdns) peers not heard from within `max_age_secs`.
    /// ManualIp / static peers are never removed.
    /// Returns the IDs of removed peers so callers can emit PeerExpired events.
    pub async fn clear_stale_peers(&self, max_age_secs: u64) -> Vec<Uuid> {
        self.0.peers.clear_stale(max_age_secs).await
    }

    pub async fn has_peer(&self, peer_id: Uuid) -> bool {
        self.0.peers.has(peer_id).await
    }

    /// Fully remove a peer from the registry (emits `PeerExpired`). Graceful
    /// departures (`/patch/bye`, mDNS `ServiceRemoved`) deliberately use
    /// `mark_peer_offline` instead — a quitting peer stays visible (grey) rather
    /// than vanishing — and the manual "clear inactive peers" button removes via
    /// `clear_stale_peers`. Retained as a utility (no current caller).
    pub async fn expire_peer(&self, peer_id: Uuid) {
        self.0.peers.expire(peer_id).await;
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
        if let Some(presence) = self.0.peers.mark_offline(peer_id).await {
            self.publish(AppEvent::PeerUpdated(presence)).await;
        }
    }

    /// Like [`Self::mark_peer_offline`], but a no-op if the peer is still
    /// within the `Online` window. For evidence that only *suggests*
    /// departure (mDNS `ServiceRemoved`, which `mdns-sd` can fire spuriously
    /// — see #126) rather than proving it.
    pub async fn mark_peer_offline_unless_recent(&self, peer_id: Uuid, heartbeat_secs: u64) {
        if let Some(presence) = self
            .0
            .peers
            .mark_offline_unless_recent(peer_id, heartbeat_secs)
            .await
        {
            self.publish(AppEvent::PeerUpdated(presence)).await;
        }
    }

    /// Returns the production role string for a peer by their UUID, if known.
    /// Used when synthesizing Flash log entries.
    pub async fn peer_role(&self, peer_id: Uuid) -> Option<String> {
        self.0.peers.get_role(peer_id).await
    }

    /// Every known peer, including a synthetic entry per configured static
    /// peer that hasn't been heard from dynamically yet. The static-peer merge
    /// is cross-domain (it needs `Config`, not just the peer registry), so it
    /// lives here rather than in `PeerRegistry` — see ADR-0003.
    pub async fn get_peers(&self) -> Vec<peer::Peer> {
        let mut peers: Vec<_> = self.0.peers.list().await;

        // Merge in static peers that haven't been heard from yet.
        // Once a real packet arrives from the same address, the dynamic entry
        // takes over and the synthetic one is suppressed by the address check.
        let static_peers = self.0.config.read(|c| c.static_peers.clone()).await;
        // All SocketAddrs already known dynamically — static entries whose
        // address is already covered by a dynamic peer are suppressed.
        let known_addrs: std::collections::HashSet<std::net::SocketAddr> =
            peers.iter().flat_map(|p| p.all_addrs()).collect();

        for sp in &static_peers {
            let sp_addr: Option<std::net::SocketAddr> = sp
                .address
                .parse::<std::net::IpAddr>()
                .ok()
                .map(|ip| std::net::SocketAddr::new(ip, sp.port));
            if let Some(addr) = sp_addr {
                if known_addrs.contains(&addr) {
                    continue; // real entry already present for this address
                }
            }
            // Derive a stable UUID from the address:port so the ID doesn't
            // flicker on every getPeers() call.
            let key = format!("static:{}:{}", sp.address, sp.port);
            let synthetic_id = Uuid::new_v5(&Uuid::NAMESPACE_DNS, key.as_bytes());
            let mut synthetic = peer::Peer {
                peer_id: synthetic_id,
                peer_name: sp.label.clone().unwrap_or_else(|| sp.address.clone()),
                channels: Vec::new(),
                role: None,
                discovery_mode: peer::DiscoveryMode::ManualIp,
                addresses: HashMap::new(),
                last_seen: chrono::Utc::now(),
                departed: false,
            };
            if let Some(addr) = sp_addr {
                synthetic.add_address(addr, chrono::Utc::now());
            }
            peers.push(synthetic);
        }

        peers
    }

    /// Resolved addresses of peers a critical message shouldn't bother
    /// tracking for an ACK (see `Peer::looks_offline`) — used to skip
    /// retransmit/failure-warning noise for peers we already know are gone,
    /// without skipping the best-effort send itself (they might still be
    /// there despite a missed heartbeat).
    pub async fn offline_addresses(&self, heartbeat_secs: u64) -> HashSet<std::net::SocketAddr> {
        network_policy::offline_addresses(&self.get_peers().await, heartbeat_secs)
    }

    /// Resolved addresses of every known peer except ourselves, deduped by
    /// `SocketAddr` (a static peer also seen dynamically is contacted once).
    /// Shared by `Transport::send_to_peers` (direct socket send) and the
    /// `/patch/say` relay (queued via `send_tx`) — same target list, two
    /// different ways of actually sending to it.
    pub async fn reachable_peer_addrs(&self, client_id: Uuid) -> Vec<std::net::SocketAddr> {
        network_policy::reachable_peer_addrs(&self.get_peers().await, client_id)
    }

    /// Like `reachable_peer_addrs` but grouped by peer_id — used by `track_critical`
    /// so ACKs can be matched by peer identity rather than socket address.
    pub async fn reachable_peers_with_addrs(
        &self,
        client_id: Uuid,
    ) -> Vec<(Uuid, Vec<std::net::SocketAddr>)> {
        network_policy::reachable_peers_with_addrs(&self.get_peers().await, client_id)
    }

    // ── Per-address prune ────────────────────────────────────────────────────

    /// Drop per-peer addresses not seen within 3× the heartbeat interval.
    /// Called on each heartbeat tick to shed dead paths without expiring the
    /// whole peer — `last_seen` and Online/Stale/Offline are unaffected.
    pub async fn prune_peer_addresses(&self, heartbeat_secs: u64) {
        let threshold_secs = heartbeat_secs.saturating_mul(3) as i64;
        let threshold = chrono::Utc::now() - chrono::Duration::seconds(threshold_secs);
        self.0.peers.prune_addresses(threshold).await;
    }

    // ── Source admission (ADR-0010, Pinned Network) ──────────────────────────

    /// Whether an inbound packet from `source` may be processed at all. See
    /// `network_policy::NetworkAdmission::admits_source`.
    pub async fn admits_source(&self, source: std::net::IpAddr) -> bool {
        let config = self.config().await;
        self.0
            .network_admission
            .admits_source(source, &config)
            .await
    }

    /// Test override for the cached Pinned Network — CI has no real interface
    /// matching a pinned name, so tests inject the subnet directly (after
    /// `set_network_interface`, which recomputes the cache).
    #[cfg(test)]
    pub(crate) fn set_pinned_subnet_for_test(
        &self,
        subnet: Option<(std::net::Ipv4Addr, std::net::Ipv4Addr)>,
    ) {
        self.0.network_admission.set_pinned_subnet(subnet);
    }

    // ── Receive dedup ────────────────────────────────────────────────────────

    /// Returns `true` if `message_id` was already seen within the last 10 s
    /// (a duplicate from multi-path delivery). Inserts it on first call and
    /// prunes expired entries.
    pub async fn is_message_duplicate(&self, message_id: Uuid) -> bool {
        self.0.seen_messages.is_duplicate(message_id).await
    }

    // ── Channels & macros ────────────────────────────────────────────────────

    pub async fn get_channels(&self) -> Vec<channel::Channel> {
        self.0.channels.list().await
    }

    pub async fn upsert_channel(&self, ch: channel::Channel) {
        self.0.channels.upsert(ch).await;
        self.publish(AppEvent::ChannelListUpdated).await;
    }

    /// Delete a channel by ID.
    pub async fn delete_channel(&self, channel_id: &str) -> anyhow::Result<()> {
        self.0.channels.delete(channel_id).await;
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
        channel::validate_show_file_channels(&channels)?;
        let mut channels = channels;
        // Show files carry no global macros, so check the incoming channels'
        // bindings against this machine's existing globals (read-only here —
        // the local snapshot used for the check is discarded, never persisted).
        let mut global_macros = self.0.config.read(|c| c.global_macros.clone()).await;
        channel::sanitize_binding_collisions(&mut global_macros, &mut channels);
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

        self.0.channels.replace_all_silent(channels).await;
        // Replace static peers and sync default_channels into the config, then
        // persist once (rather than a write for channels + a write for peers).
        let channels_snapshot = self.0.channels.list().await;
        self.0
            .config
            .mutate_and_persist(|cfg| {
                cfg.default_channels = channels_snapshot;
                cfg.static_peers = validated_peers;
            })
            .await;
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
        let (flash_on_critical, flash_on_message) = self
            .0
            .config
            .read(|c| (c.flash_on_critical, c.flash_on_message))
            .await;
        let added = self
            .0
            .channels
            .merge(channels, flash_on_critical, flash_on_message)
            .await;
        if added > 0 {
            self.publish(AppEvent::ChannelListUpdated).await;
        }
        Ok(added)
    }

    /// Read-only classification of `offered` global macros against what this
    /// machine already has — for the import preview dialog. Does **not**
    /// mutate or persist anything; the same classification
    /// `merge_global_macros` performs when the user confirms.
    pub async fn preview_global_macros(
        &self,
        offered: Vec<channel::MacroMessage>,
    ) -> Vec<channel::MacroImportOutcome> {
        let (existing_globals, channels) = self
            .0
            .config
            .read(|c| (c.global_macros.clone(), c.default_channels.clone()))
            .await;
        let existing_channel_macros: Vec<channel::MacroMessage> =
            channels.into_iter().flat_map(|ch| ch.macros).collect();
        channel::classify_macro_import(&offered, &existing_globals, &existing_channel_macros)
    }

    /// Merge a peer's offered global macros into ours — the ADR-0002
    /// peer-trust tier. Each offered macro is classified independently (see
    /// `channel::classify_macro_import`): an exact duplicate is skipped, an
    /// invalid OSC target is dropped, and a binding collision is stripped
    /// (not excluded) before the macro is added. Persists and emits
    /// `ChannelListUpdated` only if at least one macro was actually added.
    /// Returns the classification so the caller (FFI/UI) can report what
    /// happened.
    pub async fn merge_global_macros(
        &self,
        offered: Vec<channel::MacroMessage>,
    ) -> anyhow::Result<Vec<channel::MacroImportOutcome>> {
        let outcomes = self.preview_global_macros(offered).await;
        let to_add: Vec<channel::MacroMessage> = outcomes
            .iter()
            .filter_map(|o| match o {
                channel::MacroImportOutcome::Added { msg }
                | channel::MacroImportOutcome::AddedBindingDropped { msg, .. } => Some(msg.clone()),
                _ => None,
            })
            .collect();
        if !to_add.is_empty() {
            self.0
                .config
                .mutate_and_persist(|cfg| cfg.global_macros.extend(to_add))
                .await;
            self.publish(AppEvent::ChannelListUpdated).await;
        }
        Ok(outcomes)
    }

    /// Replace all channels with those from a loaded show file.
    pub async fn apply_show_file(&self, channels: Vec<channel::Channel>) -> anyhow::Result<()> {
        // A show file is untrusted input (shared between machines, possibly
        // hand-edited). Validate every channel id and macro OSC target *before*
        // mutating anything — reject the whole show file atomically so a single
        // bad entry can't half-apply.
        channel::validate_show_file_channels(&channels)?;
        let mut channels = channels;
        // Show files carry no global macros — check against this machine's
        // existing globals (read-only; the snapshot used here is discarded).
        let mut global_macros = self.0.config.read(|c| c.global_macros.clone()).await;
        channel::sanitize_binding_collisions(&mut global_macros, &mut channels);
        self.0.channels.replace_all(channels).await;
        self.publish(AppEvent::ChannelListUpdated).await;
        Ok(())
    }

    /// Add or replace a macro on a channel. See
    /// [`channel::ChannelRegistry::upsert_macro`] for the `original_label`
    /// rename contract and the binding-collision check it runs against
    /// `global_macros` (read here, since that lives on `Config` — ADR-0003).
    pub async fn upsert_macro(
        &self,
        channel_id: &str,
        original_label: Option<&str>,
        macro_msg: channel::MacroMessage,
    ) -> anyhow::Result<()> {
        let global_macros = self.0.config.read(|c| c.global_macros.clone()).await;
        self.0
            .channels
            .upsert_macro(channel_id, original_label, macro_msg, &global_macros)
            .await?;
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
        self.0
            .channels
            .reorder_macros(channel_id, ordered_labels)
            .await?;
        self.publish(AppEvent::ChannelListUpdated).await;
        Ok(())
    }

    // ── Global macros ─────────────────────────────────────────────────────────
    //
    // Stored on the config (not in the channels map) since they aren't tied to a
    // channel. Persisted like any other config mutation; the UI refreshes via the
    // bridge's `config_updated` after the call (mirrors static-peer edits).

    /// Add or replace a global macro. Matched by `original_label` when given
    /// (an edit, possibly renaming it) so the entry is updated in place
    /// instead of appending a second one under the new label; matched by
    /// `macro_msg.label` otherwise (create, or no-op rename).
    ///
    /// Checked against every channel's macros as well as the other global
    /// macros via [`channel::validate_binding_unique`] — channels and config
    /// are separate locks (ADR-0003), so this read happens before the
    /// `mutate` below rather than inside it.
    pub async fn upsert_global_macro(
        &self,
        original_label: Option<&str>,
        macro_msg: channel::MacroMessage,
    ) -> anyhow::Result<()> {
        let global_macros = self.0.config.read(|c| c.global_macros.clone()).await;
        let all_channels = self.0.channels.list().await;
        let all_channel_macros = all_channels.iter().flat_map(|c| c.macros.iter());
        let match_label = channel::resolve_macro_rename(
            &global_macros,
            original_label,
            &macro_msg,
            all_channel_macros,
            "globally",
        )?;

        self.0
            .config
            .mutate_and_persist(|cfg| {
                if let Some(pos) = cfg
                    .global_macros
                    .iter()
                    .position(|m| m.label == match_label)
                {
                    cfg.global_macros[pos] = macro_msg;
                } else {
                    cfg.global_macros.push(macro_msg);
                }
            })
            .await;
        Ok(())
    }

    /// Replace all global macros with the factory defaults.
    pub async fn reset_global_macros(&self) -> anyhow::Result<()> {
        self.0
            .config
            .mutate_and_persist(|cfg| cfg.global_macros = config::default_global_macros())
            .await;
        Ok(())
    }

    /// Remove a global macro by label.
    pub async fn delete_global_macro(&self, label: &str) -> anyhow::Result<()> {
        self.0
            .config
            .mutate_and_persist(|cfg| cfg.global_macros.retain(|m| m.label != label))
            .await;
        Ok(())
    }

    /// Reorder global macros to match `ordered_labels` (drag-to-reorder); macros
    /// not named are kept at the end, unknown labels ignored — same contract as
    /// [`reorder_macros`].
    pub async fn reorder_global_macros(&self, ordered_labels: Vec<String>) -> anyhow::Result<()> {
        self.0
            .config
            .mutate_and_persist(|cfg| {
                let mut remaining = std::mem::take(&mut cfg.global_macros);
                let mut reordered = Vec::with_capacity(remaining.len());
                for label in &ordered_labels {
                    if let Some(pos) = remaining.iter().position(|m| &m.label == label) {
                        reordered.push(remaining.remove(pos));
                    }
                }
                reordered.append(&mut remaining);
                cfg.global_macros = reordered;
            })
            .await;
        Ok(())
    }

    /// Remove a macro from a channel by label.
    pub async fn delete_macro(&self, channel_id: &str, label: &str) -> anyhow::Result<()> {
        self.0.channels.delete_macro(channel_id, label).await?;
        self.publish(AppEvent::ChannelListUpdated).await;
        Ok(())
    }

    /// Flush the debounced config write immediately. Test-only — used by tests
    /// that need to confirm disk state right after a mutation.
    #[cfg(test)]
    async fn flush_config(&self) {
        self.0.config.flush().await;
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

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
        let mut p = peer::Peer::from_presence(presence(id, last_seen));
        p.discovery_mode = mode;
        if !address.is_empty() && port > 0 {
            if let Ok(ip) = address.parse::<std::net::IpAddr>() {
                p.add_address(std::net::SocketAddr::new(ip, port), last_seen);
            }
        }
        st.0.peers.insert_for_test(id, p).await;
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
        assert_eq!(a[0].best_addr(), Some("192.168.1.50:9000".parse().unwrap()));
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

        // Backdated via the test-only insert — a Presence sighting always
        // stamps last_seen with local receive time (#129), so a stale peer
        // can't be produced through record_sighting.
        let stale_dyn = Uuid::new_v4();
        insert_peer_for_test(&st, stale_dyn, old, peer::DiscoveryMode::OscBeacon, "", 0).await;
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

        // Quiet well past 5x the heartbeat — offline. Backdated via the
        // test-only insert: a Presence sighting always stamps last_seen with
        // local receive time (#129), so "heard from, with a resolved address,
        // a long time ago, and nothing since" can only be staged directly.
        let stale = Uuid::new_v4();
        let old = chrono::Utc::now() - chrono::Duration::seconds(3600);
        insert_peer_for_test(
            &st,
            stale,
            old,
            peer::DiscoveryMode::OscBeacon,
            "10.0.0.2",
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
    async fn reachable_peer_addrs_includes_static_peer_when_unresolved() {
        // send_to_peers (unicast) must keep reaching Static Peers even when
        // network_interface is unresolved — the Pinned Network admission
        // gate governs inbound sources, not this outbound path.
        let client_id = Uuid::new_v4();
        let st = AppState::new(Config {
            default_channels: Vec::new(),
            static_peers: vec![config::StaticPeer {
                address: "10.0.0.5".into(),
                port: 9000,
                label: None,
            }],
            client_id,
            network_interface: None,
            ..Config::default()
        });
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
        assert_eq!(peers[0].best_addr(), Some("10.0.0.2:9001".parse().unwrap()));
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
        assert_eq!(peers[0].best_addr(), Some("10.0.0.3:9002".parse().unwrap()));
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
        st.flush_config().await;
        assert_eq!(
            Config::load_or_default().unwrap().heartbeat_interval_secs,
            12
        );
        // Boundaries are accepted.
        st.set_heartbeat_interval(1).await.unwrap();
        st.set_heartbeat_interval(60).await.unwrap();
        st.flush_config().await;
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
        st.flush_config().await;
        assert_eq!(Config::load_or_default().unwrap().osc_port, 9100);
        // Boundaries are accepted.
        st.set_osc_port(1024).await.unwrap();
        st.set_osc_port(65535).await.unwrap();
        st.flush_config().await;
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

        st.upsert_global_macro(None, mk("A")).await.unwrap();
        st.upsert_global_macro(None, mk("B")).await.unwrap();
        st.upsert_global_macro(None, mk("C")).await.unwrap();
        // Re-upsert with an existing label replaces in place (no duplicate).
        st.upsert_global_macro(
            None,
            MacroMessage {
                label: "B".into(),
                payload: "B2".into(),
                key_binding: None,
                priority: 2,
                midi_note: None,
                midi_cc: None,
                osc: None,
            },
        )
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
        st.flush_config().await;
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
    async fn upsert_global_macro_with_original_label_renames_in_place() {
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

        st.upsert_global_macro(None, mk("A")).await.unwrap();
        st.upsert_global_macro(None, mk("B")).await.unwrap();
        st.upsert_global_macro(None, mk("C")).await.unwrap();

        // Rename "C" to "Z" via original_label — updates in place, no duplicate.
        st.upsert_global_macro(Some("C"), mk("Z")).await.unwrap();
        assert_eq!(labels(&st.config().await), vec!["A", "B", "Z"]);

        // Renaming to a label already in use errors and leaves state untouched.
        assert!(st.upsert_global_macro(Some("Z"), mk("B")).await.is_err());
        assert_eq!(labels(&st.config().await), vec!["A", "B", "Z"]);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn upsert_global_macro_rejects_binding_collision_with_another_global_macro() {
        use channel::MacroMessage;
        let _guard = config::test_data_dir_guard().await;
        let dir = std::env::temp_dir().join(format!("patch-test-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        config::set_data_dir(dir.clone());

        let st = test_state();
        let mut hold = MacroMessage {
            label: "HOLD".into(),
            payload: "hold".into(),
            key_binding: Some("F3".into()),
            priority: 1,
            midi_note: None,
            midi_cc: None,
            osc: None,
        };
        st.upsert_global_macro(None, hold.clone()).await.unwrap();
        hold.label = "STANDBY".into();
        let err = st.upsert_global_macro(None, hold).await.unwrap_err();
        assert!(err.to_string().contains("F3"));
        assert_eq!(st.config().await.global_macros.len(), 1);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn upsert_global_macro_rejects_binding_collision_with_a_channel_macro() {
        use channel::{Channel, MacroMessage};
        let _guard = config::test_data_dir_guard().await;
        let dir = std::env::temp_dir().join(format!("patch-test-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        config::set_data_dir(dir.clone());

        let st = test_state();
        let mut ch = Channel::new("rf", "RF", "#fff").unwrap();
        ch.macros = vec![MacroMessage {
            label: "GO".into(),
            payload: "go".into(),
            key_binding: None,
            priority: 1,
            midi_note: Some(60),
            midi_cc: None,
            osc: None,
        }];
        st.upsert_channel(ch).await;

        let global_hold = MacroMessage {
            label: "HOLD".into(),
            payload: "hold".into(),
            key_binding: None,
            priority: 1,
            midi_note: Some(60),
            midi_cc: None,
            osc: None,
        };
        let err = st.upsert_global_macro(None, global_hold).await.unwrap_err();
        assert!(err.to_string().contains("GO"));
        assert!(st.config().await.global_macros.is_empty());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn upsert_macro_rejects_binding_collision_with_a_global_macro() {
        use channel::{Channel, MacroMessage};
        let _guard = config::test_data_dir_guard().await;
        let dir = std::env::temp_dir().join(format!("patch-test-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        config::set_data_dir(dir.clone());

        let st = test_state();
        st.upsert_channel(Channel::new("rf", "RF", "#fff").unwrap())
            .await;
        st.upsert_global_macro(
            None,
            MacroMessage {
                label: "HOLD".into(),
                payload: "hold".into(),
                key_binding: Some("F3".into()),
                priority: 1,
                midi_note: None,
                midi_cc: None,
                osc: None,
            },
        )
        .await
        .unwrap();

        let channel_go = MacroMessage {
            label: "GO".into(),
            payload: "go".into(),
            key_binding: Some("F3".into()),
            priority: 1,
            midi_note: None,
            midi_cc: None,
            osc: None,
        };
        let err = st.upsert_macro("rf", None, channel_go).await.unwrap_err();
        assert!(err.to_string().contains("HOLD"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn reset_global_macros_restores_defaults() {
        let _guard = config::test_data_dir_guard().await;
        let dir = std::env::temp_dir().join(format!("patch-test-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        config::set_data_dir(dir.clone());

        let st = test_state(); // starts with no global macros
        st.upsert_global_macro(
            None,
            channel::MacroMessage {
                label: "CUSTOM".into(),
                payload: "x".into(),
                key_binding: None,
                priority: 1,
                midi_note: None,
                midi_cc: None,
                osc: None,
            },
        )
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
        st.flush_config().await;
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
        st.flush_config().await;

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

    /// A show file's channel macro whose binding collides with an existing
    /// global macro must keep the macro but lose just that binding (ADR-0006's
    /// drop-and-warn, not `validate_show_file_channels`'s atomic reject — that
    /// rejection is reserved for bad channel ids/OSC targets). Show files carry
    /// no global macros of their own, so the comparison is against whatever
    /// this machine already has.
    #[tokio::test]
    async fn apply_show_file_full_strips_channel_macro_binding_colliding_with_existing_global() {
        let _guard = config::test_data_dir_guard().await;
        let dir = std::env::temp_dir().join(format!("patch-test-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        config::set_data_dir(dir.clone());

        let existing_global = channel::MacroMessage {
            label: "GO".into(),
            payload: "go".into(),
            key_binding: Some("F3".into()),
            priority: 1,
            midi_note: None,
            midi_cc: None,
            osc: None,
        };
        let st = AppState::new(Config {
            default_channels: Vec::new(),
            static_peers: Vec::new(),
            global_macros: vec![existing_global.clone()],
            ..Config::default()
        });

        let mut ch = channel::Channel::new("rf", "RF", "#1E88E5").unwrap();
        ch.macros = vec![channel::MacroMessage {
            label: "STANDBY".into(),
            payload: "standby".into(),
            key_binding: Some("F3".into()),
            priority: 1,
            midi_note: None,
            midi_cc: None,
            osc: None,
        }];
        st.apply_show_file_full(vec![ch], Vec::new()).await.unwrap();

        let channels = st.get_channels().await;
        assert_eq!(channels.len(), 1);
        assert_eq!(channels[0].macros.len(), 1); // macro kept, not dropped
        assert_eq!(channels[0].macros[0].label, "STANDBY");
        assert_eq!(channels[0].macros[0].key_binding, None); // binding stripped

        // The pre-existing global macro is untouched.
        let globals = st.config().await.global_macros;
        assert_eq!(globals.len(), 1);
        assert_eq!(globals[0].key_binding.as_deref(), Some("F3"));

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

    fn plain_global_macro(label: &str) -> channel::MacroMessage {
        channel::MacroMessage {
            label: label.into(),
            payload: label.into(),
            key_binding: None,
            priority: 1,
            midi_note: None,
            midi_cc: None,
            osc: None,
        }
    }

    #[tokio::test]
    async fn preview_global_macros_does_not_mutate_or_persist() {
        let st = test_state();
        let outcomes = st
            .preview_global_macros(vec![plain_global_macro("GO")])
            .await;
        assert_eq!(outcomes.len(), 1);
        assert!(matches!(
            outcomes[0],
            channel::MacroImportOutcome::Added { .. }
        ));
        // Read-only — nothing actually added.
        assert!(st.config().await.global_macros.is_empty());
    }

    #[tokio::test]
    async fn merge_global_macros_adds_new_keeps_duplicate_strips_collision() {
        let _guard = config::test_data_dir_guard().await;
        let dir = std::env::temp_dir().join(format!("patch-test-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        config::set_data_dir(dir.clone());

        let mut existing = plain_global_macro("STANDBY");
        existing.key_binding = Some("F3".into());
        let st = AppState::new(Config {
            default_channels: Vec::new(),
            static_peers: Vec::new(),
            global_macros: vec![existing.clone()],
            ..Config::default()
        });

        let duplicate = existing.clone();
        let new_macro = plain_global_macro("GO");
        let mut colliding = plain_global_macro("CLEAR");
        colliding.key_binding = Some("F3".into());

        let outcomes = st
            .merge_global_macros(vec![duplicate, new_macro, colliding])
            .await
            .unwrap();

        assert_eq!(outcomes.len(), 3);
        assert!(matches!(
            outcomes[0],
            channel::MacroImportOutcome::AlreadyHave { .. }
        ));
        assert!(matches!(
            outcomes[1],
            channel::MacroImportOutcome::Added { .. }
        ));
        match &outcomes[2] {
            channel::MacroImportOutcome::AddedBindingDropped { msg, .. } => {
                assert_eq!(msg.key_binding, None)
            }
            other => panic!("expected AddedBindingDropped, got {other:?}"),
        }

        let globals = st.config().await.global_macros;
        assert_eq!(globals.len(), 3); // existing STANDBY + new GO + CLEAR (binding stripped)
        assert!(globals.iter().any(|m| m.label == "GO"));
        let clear = globals.iter().find(|m| m.label == "CLEAR").unwrap();
        assert_eq!(clear.key_binding, None);

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
        // Backdated via the test-only insert (#129: record_sighting stamps
        // last_seen with local receive time, never the wire timestamp).
        insert_peer_for_test(&st, pid, old, peer::DiscoveryMode::OscBeacon, "", 0).await;
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
        assert_eq!(p.best_addr(), Some("10.0.0.2:9000".parse().unwrap())); // address updated for unicast
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
        assert_eq!(p.best_addr(), Some("10.0.0.3:9000".parse().unwrap()));
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
    async fn mark_peer_offline_unless_recent_ignores_a_spurious_removal_of_a_live_peer() {
        // Regression for #126: a spurious mDNS ServiceRemoved (mdns-sd flaps
        // these on Windows) shouldn't flip a peer we just heard from offline.
        let st = test_state();
        let pid = Uuid::new_v4();
        st.record_sighting(
            PeerSighting::Presence(presence(pid, chrono::Utc::now())),
            "10.0.0.4".into(),
            9000,
        )
        .await;

        st.mark_peer_offline_unless_recent(pid, 7).await;

        let peers = st.get_peers().await;
        let p = peers.iter().find(|p| p.peer_id == pid).unwrap();
        assert!(!p.departed);
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

    /// One `patch_config` call applies any subset of the scalar behavior
    /// settings — table-driven over single-field patches, with the out-of-range
    /// fields clamped the same way the old per-field setters clamped.
    #[tokio::test]
    async fn patch_config_applies_each_scalar_behavior_field() {
        let st = test_state();

        type Check = fn(&Config) -> bool;
        let cases: Vec<(ConfigPatch, Check)> = vec![
            (
                ConfigPatch {
                    flash_on_critical: Some(false),
                    ..ConfigPatch::default()
                },
                |c| !c.flash_on_critical,
            ),
            (
                ConfigPatch {
                    flash_on_message: Some(true),
                    ..ConfigPatch::default()
                },
                |c| c.flash_on_message,
            ),
            (
                // 99 clamps to the 3–7 pulse range
                ConfigPatch {
                    flash_count: Some(99),
                    ..ConfigPatch::default()
                },
                |c| c.flash_count == 7,
            ),
            (
                // 0 clamps to the 1–3 column range
                ConfigPatch {
                    macros_columns: Some(0),
                    ..ConfigPatch::default()
                },
                |c| c.macros_columns == 1,
            ),
            (
                ConfigPatch {
                    hide_keyboard: Some(false),
                    ..ConfigPatch::default()
                },
                |c| !c.hide_keyboard,
            ),
            (
                ConfigPatch {
                    audible_alert: Some(true),
                    ..ConfigPatch::default()
                },
                |c| c.audible_alert,
            ),
            (
                ConfigPatch {
                    flash_whole_screen: Some(true),
                    ..ConfigPatch::default()
                },
                |c| c.flash_whole_screen,
            ),
        ];

        for (i, (patch, check)) in cases.into_iter().enumerate() {
            st.patch_config(patch).await.unwrap();
            let cfg = st.config().await;
            assert!(check(&cfg), "case {i} did not apply");
        }
    }

    /// Reset restores every scalar behavior field to the `Config::default()`
    /// values — derived, not restated, so a changed default can't drift.
    #[tokio::test]
    async fn reset_behavior_config_restores_config_defaults() {
        let st = test_state();
        // Drive every behavior field away from its default first.
        let d = Config::default();
        st.patch_config(ConfigPatch {
            flash_on_critical: Some(!d.flash_on_critical),
            flash_on_message: Some(!d.flash_on_message),
            flash_count: Some(if d.flash_count == 7 { 3 } else { 7 }),
            macros_columns: Some(if d.macros_columns == 3 { 1 } else { 3 }),
            hide_keyboard: Some(!d.hide_keyboard),
            audible_alert: Some(!d.audible_alert),
            flash_whole_screen: Some(!d.flash_whole_screen),
        })
        .await
        .unwrap();

        st.reset_behavior_config().await.unwrap();

        let cfg = st.config().await;
        assert_eq!(cfg.flash_on_critical, d.flash_on_critical);
        assert_eq!(cfg.flash_on_message, d.flash_on_message);
        assert_eq!(cfg.flash_count, d.flash_count);
        assert_eq!(cfg.macros_columns, d.macros_columns);
        assert_eq!(cfg.hide_keyboard, d.hide_keyboard);
        assert_eq!(cfg.audible_alert, d.audible_alert);
        assert_eq!(cfg.flash_whole_screen, d.flash_whole_screen);
    }

    /// An all-`None` patch is a no-op — nothing changes, nothing errors.
    #[tokio::test]
    async fn patch_config_empty_patch_is_a_noop() {
        let st = test_state();
        let before = st.config().await;
        st.patch_config(ConfigPatch::default()).await.unwrap();
        let after = st.config().await;
        assert_eq!(after.flash_on_critical, before.flash_on_critical);
        assert_eq!(after.flash_on_message, before.flash_on_message);
        assert_eq!(after.flash_count, before.flash_count);
        assert_eq!(after.macros_columns, before.macros_columns);
        assert_eq!(after.hide_keyboard, before.hide_keyboard);
        assert_eq!(after.audible_alert, before.audible_alert);
        assert_eq!(after.flash_whole_screen, before.flash_whole_screen);
    }

    /// A multi-field patch lands atomically; `None` fields stay untouched.
    #[tokio::test]
    async fn patch_config_multi_field_leaves_none_fields_alone() {
        let st = test_state();
        let before = st.config().await;

        st.patch_config(ConfigPatch {
            flash_count: Some(5),
            audible_alert: Some(true),
            ..ConfigPatch::default()
        })
        .await
        .unwrap();

        let cfg = st.config().await;
        assert_eq!(cfg.flash_count, 5);
        assert!(cfg.audible_alert);
        assert_eq!(cfg.flash_on_critical, before.flash_on_critical);
        assert_eq!(cfg.hide_keyboard, before.hide_keyboard);
        assert_eq!(cfg.macros_columns, before.macros_columns);
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
        st.patch_config(ConfigPatch {
            flash_count: Some(6),
            hide_keyboard: Some(false),
            audible_alert: Some(true),
            flash_whole_screen: Some(true),
            macros_columns: Some(2),
            ..ConfigPatch::default()
        })
        .await
        .unwrap();
        st.add_static_peer("10.0.0.5".into(), 9000, Some("Booth".into()))
            .await
            .unwrap();
        st.flush_config().await;

        let loaded = Config::load_or_default().unwrap();
        assert_eq!(loaded.flash_count, 6);
        assert!(!loaded.hide_keyboard);
        assert!(loaded.audible_alert);
        assert!(loaded.flash_whole_screen);
        assert_eq!(loaded.macros_columns, 2);
        assert_eq!(loaded.static_peers.len(), 1);
        assert_eq!(loaded.static_peers[0].address, "10.0.0.5");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn mdns_sighting_with_multiple_addrs_adds_all() {
        let st = test_state();
        let peer_id = Uuid::new_v4();

        // Two mDNS sightings for the same peer — different addresses (as would
        // happen when mDNS resolves on two interfaces).
        st.record_sighting(
            PeerSighting::Mdns(presence(peer_id, chrono::Utc::now())),
            "10.0.0.1".into(),
            9000,
        )
        .await;
        st.record_sighting(
            PeerSighting::Mdns(presence(peer_id, chrono::Utc::now())),
            "192.168.1.1".into(),
            9000,
        )
        .await;

        let peers = st.get_peers().await;
        let peer = peers.iter().find(|p| p.peer_id == peer_id).unwrap();
        assert_eq!(peer.all_addrs().len(), 2);
    }

    #[tokio::test]
    async fn prune_peer_addresses_removes_stale_addrs_keeps_fresh() {
        let st = AppState::new(Config {
            heartbeat_interval_secs: 7,
            ..Config::default()
        });
        let peer_id = Uuid::new_v4();
        let heartbeat_secs = 7u64;

        // Record a peer with a fresh address.
        st.record_sighting(
            PeerSighting::Presence(presence(peer_id, chrono::Utc::now())),
            "10.0.0.1".into(),
            9000,
        )
        .await;

        st.prune_peer_addresses(heartbeat_secs).await;

        let peers = st.get_peers().await;
        let peer = peers.iter().find(|p| p.peer_id == peer_id).unwrap();
        // Fresh address (just recorded) must survive a 3x-heartbeat prune.
        assert!(peer.has_address());
    }

    #[tokio::test]
    async fn is_message_duplicate_returns_false_first_time_true_second() {
        let st = test_state();
        let id = Uuid::new_v4();
        assert!(!st.is_message_duplicate(id).await);
        assert!(st.is_message_duplicate(id).await);
    }

    #[tokio::test]
    async fn is_message_duplicate_different_ids_are_independent() {
        let st = test_state();
        let id1 = Uuid::new_v4();
        let id2 = Uuid::new_v4();
        assert!(!st.is_message_duplicate(id1).await);
        assert!(!st.is_message_duplicate(id2).await);
    }

    #[tokio::test]
    async fn reachable_peer_addrs_returns_all_addresses_per_peer() {
        let st = test_state();
        let client_id = Uuid::new_v4();
        let peer_id = Uuid::new_v4();

        // Same peer seen on two different interfaces.
        st.record_sighting(
            PeerSighting::Presence(presence(peer_id, chrono::Utc::now())),
            "10.0.0.5".into(),
            9000,
        )
        .await;
        st.record_sighting(
            PeerSighting::Presence(presence(peer_id, chrono::Utc::now())),
            "192.168.1.5".into(),
            9000,
        )
        .await;

        let addrs = st.reachable_peer_addrs(client_id).await;
        assert_eq!(addrs.len(), 2);
        assert!(addrs.contains(&"10.0.0.5:9000".parse().unwrap()));
        assert!(addrs.contains(&"192.168.1.5:9000".parse().unwrap()));
    }

    #[tokio::test]
    async fn reachable_peers_with_addrs_groups_by_peer_id() {
        let st = test_state();
        let client_id = Uuid::new_v4();
        let peer_id = Uuid::new_v4();

        st.record_sighting(
            PeerSighting::Presence(presence(peer_id, chrono::Utc::now())),
            "10.0.0.5".into(),
            9000,
        )
        .await;
        st.record_sighting(
            PeerSighting::Presence(presence(peer_id, chrono::Utc::now())),
            "192.168.1.5".into(),
            9000,
        )
        .await;

        let targets = st.reachable_peers_with_addrs(client_id).await;
        assert_eq!(targets.len(), 1); // one peer
        assert_eq!(targets[0].0, peer_id);
        assert_eq!(targets[0].1.len(), 2); // two addresses
    }

    #[tokio::test]
    async fn set_network_interface_to_auto_does_not_clear_peers() {
        let _guard = config::test_data_dir_guard().await;
        let dir = std::env::temp_dir().join(format!("patch-test-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        config::set_data_dir(dir.clone());

        let st = test_state();
        let peer_id = Uuid::new_v4();
        st.record_sighting(
            PeerSighting::Presence(presence(peer_id, chrono::Utc::now())),
            "10.0.0.5".into(),
            9000,
        )
        .await;

        // Switching to auto (None) must not wipe discovered peers.
        st.set_network_interface(None).await.unwrap();
        assert!(!st.get_peers().await.is_empty());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn admits_source_denies_arbitrary_source_when_unresolved() {
        let st = test_state();
        let source: std::net::IpAddr = "203.0.113.7".parse().unwrap();
        assert!(!st.admits_source(source).await);
    }

    #[tokio::test]
    async fn admits_source_admits_static_peer_when_unresolved() {
        let st = AppState::new(Config {
            default_channels: Vec::new(),
            static_peers: vec![config::StaticPeer::new("203.0.113.7", 9000, None).unwrap()],
            global_macros: Vec::new(),
            ..Config::default()
        });
        let source: std::net::IpAddr = "203.0.113.7".parse().unwrap();
        assert!(st.admits_source(source).await);
    }

    #[tokio::test]
    async fn set_network_interface_to_pinned_clears_dynamic_peers() {
        let _guard = config::test_data_dir_guard().await;
        let dir = std::env::temp_dir().join(format!("patch-test-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        config::set_data_dir(dir.clone());

        let st = test_state();
        let peer_id = Uuid::new_v4();
        st.record_sighting(
            PeerSighting::Presence(presence(peer_id, chrono::Utc::now())),
            "10.0.0.5".into(),
            9000,
        )
        .await;

        // Switching to a pinned interface clears dynamic peers.
        st.set_network_interface(Some("en0".into())).await.unwrap();
        // Only ManualIp peers survive; dynamic ones are gone.
        let peers = st.get_peers().await;
        assert!(peers
            .iter()
            .all(|p| matches!(p.discovery_mode, peer::DiscoveryMode::ManualIp)));

        let _ = std::fs::remove_dir_all(&dir);
    }
}
