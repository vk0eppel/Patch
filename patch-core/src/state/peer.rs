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
    /// How we found this peer.
    pub discovery_mode: DiscoveryMode,
    /// IP address (v4 or v6).
    pub address: String,
    /// OSC UDP port.
    pub osc_port: u16,
    pub last_seen: DateTime<Utc>,
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
            discovery_mode: DiscoveryMode::OscBeacon,
            address: String::new(), // filled in by transport layer
            osc_port: 0,
            last_seen: p.timestamp,
        }
    }

    /// Returns true if this peer has a usable network address for unicast.
    pub fn has_address(&self) -> bool {
        !self.address.is_empty() && self.osc_port > 0
    }

    pub fn is_stale(&self, timeout_secs: i64) -> bool {
        let age = Utc::now().signed_duration_since(self.last_seen).num_seconds();
        age > timeout_secs
    }
}
