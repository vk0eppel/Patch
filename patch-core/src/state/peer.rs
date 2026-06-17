use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::osc::types::PeerPresence;

/// A discovered or manually-added peer on the network.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Peer {
    pub peer_id: Uuid,
    pub peer_name: String,
    /// Channels this peer is currently subscribed to.
    pub channels: Vec<String>,
    /// Optional self-assigned production role (free text, e.g. "FOH", "PM").
    pub role: Option<String>,
    /// How we found this peer.
    pub discovery_mode: DiscoveryMode,
    /// IP address (v4 or v6).
    pub address: String,
    /// OSC UDP port.
    pub osc_port: u16,
    pub last_seen: DateTime<Utc>,
    /// True when the peer announced a clean departure (`/patch/bye` or mDNS
    /// `ServiceRemoved`) — drives a distinct "left" treatment in the UI while
    /// keeping the real `last_seen`. Cleared the moment a real OSC packet is
    /// received again (`touch_peer_address`).
    pub departed: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum DiscoveryMode {
    Mdns,
    OscBeacon,
    ManualIp,
}

impl Peer {
    pub fn from_presence(p: PeerPresence) -> Self {
        Self {
            peer_id: p.peer_id,
            peer_name: p.peer_name,
            channels: p.channels,
            role: p.role,
            discovery_mode: DiscoveryMode::OscBeacon,
            address: String::new(), // filled in by transport layer
            osc_port: 0,
            last_seen: p.timestamp,
            departed: false,
        }
    }

    /// Returns true if this peer has a usable network address for unicast.
    pub fn has_address(&self) -> bool {
        !self.address.is_empty() && self.osc_port > 0
    }

    pub fn is_stale(&self, timeout_secs: i64) -> bool {
        let age = Utc::now()
            .signed_duration_since(self.last_seen)
            .num_seconds();
        age > timeout_secs
    }
}
