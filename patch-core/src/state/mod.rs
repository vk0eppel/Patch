//! Shared application state — channels, peers, message buffer.
//! All access is through `Arc<AppState>`; interior mutation via `tokio::sync::RwLock`.

pub mod channel;
pub mod config;
pub mod peer;
pub mod session;

use std::collections::HashMap;
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
    pub messages: RwLock<Vec<PatchMessage>>,
    /// Event bus — clone a receiver to subscribe
    pub events: broadcast::Sender<AppEvent>,
}

const MAX_BUFFER: usize = 500;

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
            messages: RwLock::new(Vec::new()),
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

    /// Persist the global flash pulse count (clamped to 1–10).
    pub async fn set_flash_count(&self, count: u8) -> anyhow::Result<()> {
        let mut cfg = self.0.config.write().await;
        cfg.flash_count = count.clamp(1, 10);
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
                ch.flash_count = if v == 0 { None } else { Some(v.clamp(1, 10)) };
            }
        }
        self.persist_channels().await?;
        self.publish(AppEvent::ChannelListUpdated).await;
        Ok(())
    }

    // ── Messages ──────────────────────────────────────────────────────────────

    pub async fn store_message(&self, msg: PatchMessage) {
        let mut buf = self.0.messages.write().await;
        // Deduplicate — our own broadcast comes back over UDP, so the same
        // message_id can arrive twice (once on send, once on receive).
        if buf.iter().any(|m| m.message_id == msg.message_id) {
            return;
        }
        if buf.len() >= MAX_BUFFER {
            buf.remove(0);
        }
        buf.push(msg.clone());
        drop(buf);
        self.publish(AppEvent::MessageReceived(msg)).await;
    }

    pub async fn get_messages(&self, channel_id: &str, limit: usize) -> Vec<PatchMessage> {
        let buf = self.0.messages.read().await;
        buf.iter()
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

    pub async fn upsert_peer(&self, presence: PeerPresence) {
        let mut peers = self.0.peers.write().await;
        peers.insert(presence.peer_id, peer::Peer::from_presence(presence.clone()));
        drop(peers);
        self.publish(AppEvent::PeerUpdated(presence)).await;
    }

    /// Update the network address of a known peer (called from transport on receive,
    /// and from mDNS resolution). No-op if the peer isn't in the registry yet —
    /// it will be populated when their presence packet arrives.
    pub async fn touch_peer_address(&self, peer_id: Uuid, address: String, port: u16) {
        let mut peers = self.0.peers.write().await;
        if let Some(peer) = peers.get_mut(&peer_id) {
            peer.address = address;
            peer.osc_port = port;
        }
    }

    pub async fn expire_peer(&self, peer_id: Uuid) {
        let mut peers = self.0.peers.write().await;
        peers.remove(&peer_id);
        drop(peers);
        self.publish(AppEvent::PeerExpired(peer_id)).await;
    }

    pub async fn get_peers(&self) -> Vec<peer::Peer> {
        self.0.peers.read().await.values().cloned().collect()
    }

    // ── Channels & shortcuts ──────────────────────────────────────────────────

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

    /// Add or replace a shortcut on a channel (matched by label).
    pub async fn upsert_shortcut(
        &self,
        channel_id: &str,
        shortcut: channel::ShortcutMessage,
    ) -> anyhow::Result<()> {
        {
            let mut channels = self.0.channels.write().await;
            let ch = channels
                .get_mut(channel_id)
                .ok_or_else(|| anyhow::anyhow!("Channel '{}' not found", channel_id))?;
            // Replace existing shortcut with same label, or append.
            if let Some(pos) = ch.shortcuts.iter().position(|s| s.label == shortcut.label) {
                ch.shortcuts[pos] = shortcut;
            } else {
                ch.shortcuts.push(shortcut);
            }
        }
        self.persist_channels().await?;
        self.publish(AppEvent::ChannelListUpdated).await;
        Ok(())
    }

    /// Remove a shortcut from a channel by label.
    pub async fn delete_shortcut(
        &self,
        channel_id: &str,
        label: &str,
    ) -> anyhow::Result<()> {
        {
            let mut channels = self.0.channels.write().await;
            let ch = channels
                .get_mut(channel_id)
                .ok_or_else(|| anyhow::anyhow!("Channel '{}' not found", channel_id))?;
            ch.shortcuts.retain(|s| s.label != label);
        }
        self.persist_channels().await?;
        self.publish(AppEvent::ChannelListUpdated).await;
        Ok(())
    }

    /// Write current channel shortcuts back to patch.toml.
    async fn persist_channels(&self) -> anyhow::Result<()> {
        let channels: Vec<_> = self.0.channels.read().await.values().cloned().collect();
        let mut cfg = self.0.config.write().await;
        cfg.default_channels = channels;
        cfg.save()
    }
}
