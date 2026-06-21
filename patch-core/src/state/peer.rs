use std::collections::HashMap;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use tokio::sync::RwLock;
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

    /// Three-way liveness classification for display (peers panel dot,
    /// DM-offline warning): `Online` (healthy, ≤2x heartbeat), `Stale`
    /// (heartbeat missed but not yet written off, ≤5x), or `Offline`
    /// (departed, quiet past 5x, or a `ManualIp` static peer — which never
    /// heartbeats, so it can't read as healthy even though `looks_offline`
    /// exempts it from the ACK-skip rule for a different reason: best-effort
    /// sends to it should never be skipped just because it's quiet).
    pub fn status(&self, heartbeat_secs: u64) -> PeerStatus {
        if self.departed || matches!(self.discovery_mode, DiscoveryMode::ManualIp) {
            return PeerStatus::Offline;
        }
        if self.is_stale(heartbeat_secs.saturating_mul(5) as i64) {
            PeerStatus::Offline
        } else if self.is_stale(heartbeat_secs.saturating_mul(2) as i64) {
            PeerStatus::Stale
        } else {
            PeerStatus::Online
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum PeerStatus {
    Online,
    Stale,
    Offline,
}

/// What kind of evidence a Peer sighting is — passed to
/// [`PeerRegistry::record_sighting`], which applies the matching liveness/
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

/// Pure peer-domain logic — no `AppEvent`/broadcast-channel dependency. Per
/// ADR-0003, `AppState` decides what (if anything) to publish based on what
/// these methods return, and owns any cross-domain orchestration (e.g. the
/// static-peer merge in `AppState::get_peers`, which needs `Config` data this
/// registry deliberately doesn't have).
#[derive(Debug, Default)]
pub(crate) struct PeerRegistry {
    peers: RwLock<HashMap<Uuid, Peer>>,
}

impl PeerRegistry {
    /// Records evidence that a [Peer] is out there. The single entry point for
    /// "a Peer was seen" — each call carries the address it was seen at and
    /// the kind of evidence it is, which determines the liveness/classification
    /// rule applied (see each variant's doc comment). Returns the resulting
    /// presence so the caller can publish `AppEvent::PeerUpdated`.
    pub(crate) async fn record_sighting(
        &self,
        sighting: PeerSighting,
        address: String,
        port: u16,
    ) -> PeerPresence {
        let mut peers = self.peers.write().await;
        match sighting {
            PeerSighting::Presence(presence) => {
                let mut new_peer = Peer::from_presence(presence.clone());
                // Once a peer has been resolved via mDNS, keep that
                // classification — a subsequent OSC presence heartbeat
                // shouldn't downgrade the icon.
                if let Some(existing) = peers.get(&presence.peer_id) {
                    if matches!(existing.discovery_mode, DiscoveryMode::Mdns) {
                        new_peer.discovery_mode = DiscoveryMode::Mdns;
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
                    let mut new_peer = Peer::from_presence(presence.clone());
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
                    peer.discovery_mode = DiscoveryMode::Mdns;
                    PeerPresence {
                        peer_id: peer.peer_id,
                        peer_name: peer.peer_name.clone(),
                        channels: peer.channels.clone(),
                        role: peer.role.clone(),
                        timestamp: peer.last_seen,
                    }
                }
                None => {
                    let mut new_peer = Peer::from_presence(presence.clone());
                    new_peer.discovery_mode = DiscoveryMode::Mdns;
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
    }

    /// Remove dynamic (OscBeacon / Mdns) peers not heard from within `max_age_secs`.
    /// ManualIp / static peers are never removed.
    /// Returns the IDs of removed peers so callers can emit PeerExpired events.
    pub(crate) async fn clear_stale(&self, max_age_secs: u64) -> Vec<Uuid> {
        let mut peers = self.peers.write().await;
        let mut removed = Vec::new();
        peers.retain(|id, p| {
            let is_manual = matches!(p.discovery_mode, DiscoveryMode::ManualIp);
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

    /// Remove all dynamic (OscBeacon/Mdns) peers immediately, regardless of
    /// staleness. ManualIp/static peers are never touched. Returns the IDs of
    /// removed peers so the caller can emit `PeerExpired` events.
    pub(crate) async fn clear_dynamic(&self) -> Vec<Uuid> {
        let mut peers = self.peers.write().await;
        let mut removed = Vec::new();
        peers.retain(|id, p| {
            if matches!(p.discovery_mode, DiscoveryMode::ManualIp) {
                true
            } else {
                removed.push(*id);
                false
            }
        });
        removed
    }

    pub(crate) async fn has(&self, peer_id: Uuid) -> bool {
        self.peers.read().await.contains_key(&peer_id)
    }

    /// Fully remove a peer from the registry. Caller publishes `PeerExpired`.
    pub(crate) async fn expire(&self, peer_id: Uuid) {
        self.peers.write().await.remove(&peer_id);
    }

    /// Mark a peer offline without removing it (e.g. on `/patch/bye` or mDNS
    /// `ServiceRemoved`). Sets the `departed` flag while **keeping the real
    /// `last_seen`**, so a clean departure is told apart from a peer that
    /// merely went quiet. Returns the resulting presence (for the caller to
    /// publish `PeerUpdated`) — `None` if the peer isn't currently known
    /// (no-op).
    pub(crate) async fn mark_offline(&self, peer_id: Uuid) -> Option<PeerPresence> {
        let mut peers = self.peers.write().await;
        let peer = peers.get_mut(&peer_id)?;
        peer.departed = true;
        Some(PeerPresence {
            peer_id: peer.peer_id,
            peer_name: peer.peer_name.clone(),
            channels: peer.channels.clone(),
            role: peer.role.clone(),
            timestamp: peer.last_seen,
        })
    }

    /// Test-only: insert a `Peer` directly, bypassing `record_sighting`'s
    /// rules — for fixtures that need a peer in a state `record_sighting`
    /// can't produce (e.g. a `ManualIp` peer, which in production only ever
    /// comes from the static-peer merge in `AppState::get_peers`, never from
    /// a sighting on the wire).
    #[cfg(test)]
    pub(crate) async fn insert_for_test(&self, id: Uuid, peer: Peer) {
        self.peers.write().await.insert(id, peer);
    }

    /// Raw dynamically-discovered peers — no static-peer merge (that's
    /// cross-domain orchestration owned by `AppState::get_peers`).
    pub(crate) async fn list(&self) -> Vec<Peer> {
        self.peers.read().await.values().cloned().collect()
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

    #[test]
    fn status_departed_is_offline_regardless_of_last_seen() {
        let mut p = peer_at(Utc::now(), DiscoveryMode::OscBeacon);
        p.departed = true;
        assert_eq!(p.status(7), PeerStatus::Offline);
    }

    #[test]
    fn status_manual_peer_is_always_offline() {
        // Manual peers never heartbeat, so they can't read as healthy even
        // though `looks_offline` exempts them from the ACK-skip rule.
        let p = peer_at(Utc::now(), DiscoveryMode::ManualIp);
        assert_eq!(p.status(7), PeerStatus::Offline);
    }

    #[test]
    fn status_recently_seen_is_online() {
        let p = peer_at(Utc::now(), DiscoveryMode::OscBeacon);
        assert_eq!(p.status(7), PeerStatus::Online);
    }

    #[test]
    fn status_quiet_past_2x_but_within_5x_is_stale() {
        let old = Utc::now() - chrono::Duration::seconds(20);
        let p = peer_at(old, DiscoveryMode::OscBeacon); // 2x=14s, 5x=35s
        assert_eq!(p.status(7), PeerStatus::Stale);
    }

    #[test]
    fn status_quiet_past_5x_is_offline() {
        let old = Utc::now() - chrono::Duration::seconds(36);
        let p = peer_at(old, DiscoveryMode::OscBeacon);
        assert_eq!(p.status(7), PeerStatus::Offline);
    }

    // ── PeerRegistry — direct, no AppState/event bus needed ─────────────────

    #[tokio::test]
    async fn record_sighting_heartbeat_registers_a_new_peer() {
        let reg = PeerRegistry::default();
        let id = Uuid::new_v4();
        let presence = reg
            .record_sighting(
                PeerSighting::Heartbeat {
                    peer_id: id,
                    peer_name: "p".into(),
                },
                "10.0.0.1".into(),
                9000,
            )
            .await;
        assert_eq!(presence.peer_id, id);
        let listed = reg.list().await;
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].address, "10.0.0.1");
    }

    #[tokio::test]
    async fn record_sighting_heartbeat_refreshes_an_existing_peer_and_clears_departed() {
        let reg = PeerRegistry::default();
        let id = Uuid::new_v4();
        reg.record_sighting(
            PeerSighting::Heartbeat {
                peer_id: id,
                peer_name: "p".into(),
            },
            "10.0.0.1".into(),
            9000,
        )
        .await;
        reg.mark_offline(id).await;
        assert!(reg.list().await[0].departed);

        reg.record_sighting(
            PeerSighting::Heartbeat {
                peer_id: id,
                peer_name: "p".into(),
            },
            "10.0.0.2".into(),
            9001,
        )
        .await;
        let p = &reg.list().await[0];
        assert_eq!(p.address, "10.0.0.2");
        assert!(!p.departed);
    }

    #[tokio::test]
    async fn record_sighting_mdns_after_presence_keeps_mdns_classification_sticky() {
        let reg = PeerRegistry::default();
        let id = Uuid::new_v4();
        reg.record_sighting(
            PeerSighting::Mdns(PeerPresence {
                peer_id: id,
                peer_name: "p".into(),
                channels: Vec::new(),
                role: None,
                timestamp: Utc::now(),
            }),
            "10.0.0.1".into(),
            9000,
        )
        .await;
        assert!(matches!(
            reg.list().await[0].discovery_mode,
            DiscoveryMode::Mdns
        ));

        // A later OSC presence heartbeat must not downgrade the classification.
        reg.record_sighting(
            PeerSighting::Presence(PeerPresence {
                peer_id: id,
                peer_name: "p".into(),
                channels: Vec::new(),
                role: None,
                timestamp: Utc::now(),
            }),
            "10.0.0.1".into(),
            9000,
        )
        .await;
        assert!(matches!(
            reg.list().await[0].discovery_mode,
            DiscoveryMode::Mdns
        ));
    }

    #[tokio::test]
    async fn record_sighting_mdns_new_peer_is_backdated_stale() {
        let reg = PeerRegistry::default();
        let id = Uuid::new_v4();
        reg.record_sighting(
            PeerSighting::Mdns(PeerPresence {
                peer_id: id,
                peer_name: "p".into(),
                channels: Vec::new(),
                role: None,
                timestamp: Utc::now(),
            }),
            "10.0.0.1".into(),
            9000,
        )
        .await;
        let p = &reg.list().await[0];
        // Backdated 60s — already past a typical (e.g. 7s) 5x-heartbeat window.
        assert!(p.is_stale(35));
    }

    #[tokio::test]
    async fn record_sighting_mdns_with_empty_address_leaves_peer_unaddressed() {
        let reg = PeerRegistry::default();
        let id = Uuid::new_v4();
        reg.record_sighting(
            PeerSighting::Mdns(PeerPresence {
                peer_id: id,
                peer_name: "p".into(),
                channels: Vec::new(),
                role: None,
                timestamp: Utc::now(),
            }),
            String::new(),
            0,
        )
        .await;
        assert!(!reg.list().await[0].has_address());
    }

    #[tokio::test]
    async fn mark_offline_is_a_noop_for_an_unknown_peer() {
        let reg = PeerRegistry::default();
        assert!(reg.mark_offline(Uuid::new_v4()).await.is_none());
    }

    #[tokio::test]
    async fn expire_removes_the_peer() {
        let reg = PeerRegistry::default();
        let id = Uuid::new_v4();
        reg.record_sighting(
            PeerSighting::Heartbeat {
                peer_id: id,
                peer_name: "p".into(),
            },
            "10.0.0.1".into(),
            9000,
        )
        .await;
        assert!(reg.has(id).await);
        reg.expire(id).await;
        assert!(!reg.has(id).await);
    }

    #[tokio::test]
    async fn clear_stale_keeps_manual_and_fresh_removes_only_stale_dynamic() {
        let reg = PeerRegistry::default();
        let fresh_id = Uuid::new_v4();
        reg.insert_for_test(fresh_id, peer_at(Utc::now(), DiscoveryMode::OscBeacon))
            .await;
        let stale_id = Uuid::new_v4();
        let old = Utc::now() - chrono::Duration::seconds(100);
        reg.insert_for_test(stale_id, peer_at(old, DiscoveryMode::OscBeacon))
            .await;
        let manual_id = Uuid::new_v4();
        reg.insert_for_test(manual_id, peer_at(old, DiscoveryMode::ManualIp))
            .await;

        let removed = reg.clear_stale(7).await;
        assert_eq!(removed, vec![stale_id]);
        assert!(reg.has(fresh_id).await);
        assert!(!reg.has(stale_id).await);
        assert!(reg.has(manual_id).await);
    }

    #[tokio::test]
    async fn clear_dynamic_removes_all_non_manual_regardless_of_staleness() {
        let reg = PeerRegistry::default();
        let fresh_id = Uuid::new_v4();
        reg.insert_for_test(fresh_id, peer_at(Utc::now(), DiscoveryMode::OscBeacon))
            .await;
        let manual_id = Uuid::new_v4();
        reg.insert_for_test(manual_id, peer_at(Utc::now(), DiscoveryMode::ManualIp))
            .await;

        let removed = reg.clear_dynamic().await;
        assert_eq!(removed, vec![fresh_id]);
        assert!(!reg.has(fresh_id).await);
        assert!(reg.has(manual_id).await);
    }
}
