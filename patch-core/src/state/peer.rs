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
    /// received again (`AppState::record_sighting`).
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

    /// Resolved unicast address for this peer, or `None` if it has no address
    /// yet or `address` isn't a parseable `IpAddr` (e.g. still empty, just
    /// like `has_address`). Single place that turns the raw `address`/`osc_port`
    /// fields into something actually sendable — every unicast send path should
    /// go through this instead of re-deriving the parse-and-check.
    pub fn socket_addr(&self) -> Option<std::net::SocketAddr> {
        if !self.has_address() {
            return None;
        }
        self.address
            .parse::<std::net::IpAddr>()
            .ok()
            .map(|ip| std::net::SocketAddr::new(ip, self.osc_port))
    }

    pub fn is_stale(&self, timeout_secs: i64) -> bool {
        let age = Utc::now()
            .signed_duration_since(self.last_seen)
            .num_seconds();
        age > timeout_secs
    }

    /// True when a critical message shouldn't bother tracking this peer for
    /// an ACK: it announced a clean departure, or it's gone quiet for more
    /// than 5x the heartbeat interval — the same "grey dot" threshold the
    /// peers panel and DM-offline warning already use in the Flutter UI.
    /// `ManualIp` (static) peers are exempt — they never heartbeat, so
    /// staleness can't tell us anything about them either way.
    pub fn looks_offline(&self, heartbeat_secs: u64) -> bool {
        if self.departed {
            return true;
        }
        if matches!(self.discovery_mode, DiscoveryMode::ManualIp) {
            return false;
        }
        self.is_stale(heartbeat_secs.saturating_mul(5) as i64)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::osc::types::PeerPresence;

    fn peer_at(last_seen: DateTime<Utc>, mode: DiscoveryMode) -> Peer {
        let mut p = Peer::from_presence(PeerPresence {
            peer_id: Uuid::new_v4(),
            peer_name: "p".into(),
            channels: Vec::new(),
            role: None,
            timestamp: last_seen,
        });
        p.discovery_mode = mode;
        p
    }

    #[test]
    fn departed_looks_offline_regardless_of_last_seen() {
        let mut p = peer_at(Utc::now(), DiscoveryMode::OscBeacon);
        p.departed = true;
        assert!(p.looks_offline(7));
    }

    #[test]
    fn quiet_past_5x_heartbeat_looks_offline() {
        let old = Utc::now() - chrono::Duration::seconds(36);
        let p = peer_at(old, DiscoveryMode::OscBeacon);
        assert!(p.looks_offline(7)); // threshold is 35s
    }

    #[test]
    fn recently_seen_does_not_look_offline() {
        let p = peer_at(Utc::now(), DiscoveryMode::OscBeacon);
        assert!(!p.looks_offline(7));
    }

    #[test]
    fn manual_peer_never_looks_offline_from_staleness() {
        let old = Utc::now() - chrono::Duration::seconds(36000);
        let p = peer_at(old, DiscoveryMode::ManualIp);
        assert!(!p.looks_offline(7));
    }
}
