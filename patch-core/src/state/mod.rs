//! Shared application state — channels, peers, message buffer.
//! All access is through `Arc<AppState>`; interior mutation via `tokio::sync::RwLock`.

pub mod channel;
pub mod config;
pub mod peer;
pub mod session;

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::Arc;
use tokio::sync::{broadcast, RwLock};
use uuid::Uuid;

use crate::osc::types::{ChannelFlash, PatchMessage, PeerPresence};
pub use config::Config;

/// Events broadcast to all internal subscribers (bridge, UI, etc.)
#[derive(Debug, Clone)]
pub enum AppEvent {
    MessageReceived(PatchMessage),
    MessageAcked { message_id: Uuid, peer_id: Uuid },
    PeerUpdated(PeerPresence),
    PeerExpired(Uuid),
    ChannelFlash(ChannelFlash),
    ChannelListUpdated,
    ClientNameChanged(String),
    /// Emitted when the OS denies network access (iOS/macOS Local Network permission).
    PermissionDenied { context: String },
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
    /// Event bus — clone a receiver to subscribe
    pub events: broadcast::Sender<AppEvent>,
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
            events: tx,
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
        {
            let mut cfg = self.0.config.write().await;
            cfg.client_name = name.clone();
            cfg.save()?;
        }
        self.publish(AppEvent::ClientNameChanged(name)).await;
        Ok(())
    }

    /// Persist a new network interface selection (None = bind all).
    /// Takes effect on next restart — transport is already bound.
    pub async fn set_network_interface(&self, iface: Option<String>) -> anyhow::Result<()> {
        let mut cfg = self.0.config.write().await;
        cfg.network_interface = iface;
        cfg.save()
    }

    /// Persist the flash-on-critical setting.
    pub async fn set_flash_on_critical(&self, enabled: bool) -> anyhow::Result<()> {
        let mut cfg = self.0.config.write().await;
        cfg.flash_on_critical = enabled;
        cfg.save()
    }

    /// Persist the flash-on-every-message setting.
    pub async fn set_flash_on_message(&self, enabled: bool) -> anyhow::Result<()> {
        let mut cfg = self.0.config.write().await;
        cfg.flash_on_message = enabled;
        cfg.save()
    }

    /// Persist the global flash pulse count (clamped to 3–7).
    pub async fn set_flash_count(&self, count: u8) -> anyhow::Result<()> {
        let mut cfg = self.0.config.write().await;
        cfg.flash_count = count.clamp(3, 7);
        cfg.save()
    }

    pub async fn set_macros_columns(&self, columns: u8) -> anyhow::Result<()> {
        let mut cfg = self.0.config.write().await;
        cfg.macros_columns = columns.clamp(1, 2);
        cfg.save()
    }

    pub async fn set_hide_keyboard(&self, enabled: bool) -> anyhow::Result<()> {
        let mut cfg = self.0.config.write().await;
        cfg.hide_keyboard = enabled;
        cfg.save()
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
            if let Some(v) = flash_on_critical { ch.flash_on_critical = v; }
            if let Some(v) = flash_on_message  { ch.flash_on_message  = v; }
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
        address.parse::<std::net::IpAddr>()
            .map_err(|_| anyhow::anyhow!("Invalid IP address: '{}'", address))?;
        if port == 0 {
            anyhow::bail!("Port 0 is not valid for a static peer");
        }
        let mut cfg = self.0.config.write().await;
        if cfg.static_peers.iter().any(|p| p.address == address && p.port == port) {
            anyhow::bail!("Peer {}:{} is already configured", address, port);
        }
        cfg.static_peers.push(config::StaticPeer { address, port, label });
        cfg.save()
    }

    pub async fn remove_static_peer(&self, address: &str, port: u16) -> anyhow::Result<()> {
        let mut cfg = self.0.config.write().await;
        cfg.static_peers.retain(|p| !(p.address == address && p.port == port));
        cfg.save()
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
        self.upsert_peer_with_mode(presence, peer::DiscoveryMode::OscBeacon).await;
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

    /// Update the network address and last_seen of a known peer (called from
    /// transport on receive and from mDNS resolution). Emits PeerUpdated so
    /// the Flutter side refreshes the dot colour. No-op if the peer isn't in
    /// the registry yet — it will be populated when their presence packet arrives.
    pub async fn touch_peer_address(&self, peer_id: Uuid, address: String, port: u16) {
        let presence = {
            let mut peers = self.0.peers.write().await;
            let Some(peer) = peers.get_mut(&peer_id) else { return };
            peer.address = address;
            peer.osc_port = port;
            peer.last_seen = chrono::Utc::now();
            // Build a PeerPresence to carry through the event bus.
            PeerPresence {
                peer_id: peer.peer_id,
                peer_name: peer.peer_name.clone(),
                channels: peer.channels.clone(),
                timestamp: peer.last_seen,
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

    pub async fn expire_peer(&self, peer_id: Uuid) {
        let mut peers = self.0.peers.write().await;
        peers.remove(&peer_id);
        drop(peers);
        self.publish(AppEvent::PeerExpired(peer_id)).await;
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
                discovery_mode: peer::DiscoveryMode::ManualIp,
                address: sp.address.clone(),
                osc_port: sp.port,
                last_seen: chrono::Utc::now(),
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
        self.apply_session(config::default_channels()).await
    }

    /// Replace all channels with those from a loaded session.
    pub async fn apply_session(&self, channels: Vec<channel::Channel>) -> anyhow::Result<()> {
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

    /// Remove a macro from a channel by label.
    pub async fn delete_macro(
        &self,
        channel_id: &str,
        label: &str,
    ) -> anyhow::Result<()> {
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
        let channels: Vec<_> = self.0.channels.read().await.values().cloned().collect();
        let mut cfg = self.0.config.write().await;
        cfg.default_channels = channels;
        cfg.save()
    }
}
