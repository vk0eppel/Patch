//! Pinned-network admission (ADR-0010) and cross-peer reachability/dedup
//! rules — extracted from `AppState` so this logic has one home separate
//! from the surrounding one-line CRUD delegations. `AppState` still owns the
//! facade (ADR-0003); this module is what it delegates to.

use std::collections::{HashMap, HashSet};
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::time::Instant;

use tokio::sync::Mutex;
use uuid::Uuid;

use super::config::Config;
use super::peer::Peer;

// ── Reachability (pure — no lock, no I/O) ───────────────────────────────────

/// Resolved addresses of every known peer except ourselves, deduped by
/// `SocketAddr` (a static peer also seen dynamically is contacted once).
/// Shared by `Transport::send_to_peers` (direct socket send) and the
/// `/patch/say` relay (queued via `send_tx`) — same target list, two
/// different ways of actually sending to it.
pub(crate) fn reachable_peer_addrs(peers: &[Peer], client_id: Uuid) -> Vec<SocketAddr> {
    let mut seen = HashSet::new();
    peers
        .iter()
        .filter(|p| p.peer_id != client_id)
        .flat_map(|p| p.all_addrs())
        .filter(|addr| seen.insert(*addr))
        .collect()
}

/// Like `reachable_peer_addrs` but grouped by peer_id — used by `track_critical`
/// so ACKs can be matched by peer identity rather than socket address.
pub(crate) fn reachable_peers_with_addrs(
    peers: &[Peer],
    client_id: Uuid,
) -> Vec<(Uuid, Vec<SocketAddr>)> {
    peers
        .iter()
        .filter(|p| p.peer_id != client_id && p.has_address())
        .map(|p| (p.peer_id, p.all_addrs()))
        .collect()
}

/// Addresses of peers that look offline — used to skip retransmit/failure-
/// warning noise for peers we already know are gone, without skipping the
/// best-effort send itself (they might still be there despite a missed
/// heartbeat).
pub(crate) fn offline_addresses(peers: &[Peer], heartbeat_secs: u64) -> HashSet<SocketAddr> {
    peers
        .iter()
        .filter(|p| p.looks_offline(heartbeat_secs))
        .flat_map(|p| p.all_addrs())
        .collect()
}

// ── Source admission (ADR-0010, Pinned Network) ─────────────────────────────

/// Whether an inbound packet from `source` may be processed at all, plus the
/// rate-limited "dropped off-pin source" log. Owns the cached Pinned Network
/// subnet so the per-packet check never enumerates interfaces.
#[derive(Debug)]
pub(crate) struct NetworkAdmission {
    /// None when no pin is configured — or when the pinned interface has no
    /// usable IPv4 (then only Static Peers are admitted: fail-closed).
    /// Recomputed on construction and on `set_network_interface`.
    pinned_subnet: std::sync::Mutex<Option<(Ipv4Addr, Ipv4Addr)>>,
    /// Rate limit for the "dropped off-pin source" log — last warn per source.
    dropped_source_log: Mutex<HashMap<IpAddr, Instant>>,
}

impl NetworkAdmission {
    pub(crate) fn new(pinned_subnet: Option<(Ipv4Addr, Ipv4Addr)>) -> Self {
        Self {
            pinned_subnet: std::sync::Mutex::new(pinned_subnet),
            dropped_source_log: Mutex::new(HashMap::new()),
        }
    }

    pub(crate) fn set_pinned_subnet(&self, subnet: Option<(Ipv4Addr, Ipv4Addr)>) {
        *self.pinned_subnet.lock().unwrap() = subnet;
    }

    #[cfg(test)]
    pub(crate) fn pinned_subnet_for_test(&self) -> Option<(Ipv4Addr, Ipv4Addr)> {
        *self.pinned_subnet.lock().unwrap()
    }

    /// True when no pin is configured, when the source is on the Pinned
    /// Network, or when it matches a configured Static Peer address (the
    /// deliberate exemption for routed networks). Everything else is dropped
    /// whole at the protocol boundary — a denial logs the ignored source,
    /// rate-limited to one line per source per 5 minutes.
    pub(crate) async fn admits_source(&self, source: IpAddr, config: &Config) -> bool {
        if config.network_interface.is_none() {
            return config
                .static_peers
                .iter()
                .any(|p| p.address.parse::<IpAddr>() == Ok(source));
        }
        let on_pinned_network = match (*self.pinned_subnet.lock().unwrap(), source) {
            (Some((iface_ip, mask)), IpAddr::V4(v4)) => {
                crate::transport::in_pinned_subnet(v4, iface_ip, mask)
            }
            // Pinned but no usable IPv4 on the pinned interface (or an IPv6
            // source): fail closed — only Static Peers get through.
            _ => false,
        };
        if on_pinned_network
            || config
                .static_peers
                .iter()
                .any(|p| p.address.parse::<IpAddr>() == Ok(source))
        {
            return true;
        }
        const LOG_EVERY: std::time::Duration = std::time::Duration::from_secs(300);
        let mut log = self.dropped_source_log.lock().await;
        let now = Instant::now();
        log.retain(|_, t| now.duration_since(*t) < LOG_EVERY);
        if let std::collections::hash_map::Entry::Vacant(e) = log.entry(source) {
            e.insert(now);
            tracing::warn!(
                "packet from {} ignored — outside the pinned network (ADR-0010); \
                 add a static peer to reach hosts beyond it",
                source
            );
        }
        false
    }
}

// ── Receive dedup ────────────────────────────────────────────────────────────

/// Global receive-side dedup cache — message IDs seen in the last 10 s.
/// Prevents duplicate processing when a message arrives on multiple paths.
#[derive(Debug)]
pub(crate) struct MessageDedup {
    seen: Mutex<HashMap<Uuid, Instant>>,
}

impl MessageDedup {
    pub(crate) fn new() -> Self {
        Self {
            seen: Mutex::new(HashMap::new()),
        }
    }

    /// Returns `true` if `message_id` was already seen within the last 10 s
    /// (a duplicate from multi-path delivery). Inserts it on first call and
    /// prunes expired entries.
    pub(crate) async fn is_duplicate(&self, message_id: Uuid) -> bool {
        use std::time::Duration;
        const TTL: Duration = Duration::from_secs(10);
        let now = Instant::now();
        let mut seen = self.seen.lock().await;
        seen.retain(|_, t| now.duration_since(*t) < TTL);
        if seen.contains_key(&message_id) {
            return true;
        }
        seen.insert(message_id, now);
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state::config::StaticPeer;
    use crate::state::peer::DiscoveryMode;
    use chrono::Utc;

    fn peer_at(id: Uuid, mode: DiscoveryMode, addrs: &[&str]) -> Peer {
        let mut p = Peer {
            peer_id: id,
            peer_name: "P".into(),
            channels: Vec::new(),
            role: None,
            discovery_mode: mode,
            addresses: HashMap::new(),
            last_seen: Utc::now(),
            departed: false,
        };
        for a in addrs {
            p.add_address(a.parse().unwrap(), Utc::now());
        }
        p
    }

    #[test]
    fn reachable_peer_addrs_excludes_self_and_dedups_shared_addresses() {
        let client_id = Uuid::new_v4();
        let a = peer_at(Uuid::new_v4(), DiscoveryMode::OscBeacon, &["10.0.0.5:9000"]);
        let b = peer_at(
            Uuid::new_v4(),
            DiscoveryMode::ManualIp,
            &["10.0.0.5:9000"], // same address as `a` — must be deduped
        );
        let me = peer_at(client_id, DiscoveryMode::OscBeacon, &["10.0.0.9:9000"]);

        let targets = reachable_peer_addrs(&[a, b, me], client_id);
        assert_eq!(targets, vec!["10.0.0.5:9000".parse().unwrap()]);
    }

    #[test]
    fn reachable_peers_with_addrs_excludes_self_and_addressless_peers() {
        let client_id = Uuid::new_v4();
        let addressed = peer_at(Uuid::new_v4(), DiscoveryMode::OscBeacon, &["10.0.0.5:9000"]);
        let addressed_id = addressed.peer_id;
        let addressless = peer_at(Uuid::new_v4(), DiscoveryMode::OscBeacon, &[]);
        let me = peer_at(client_id, DiscoveryMode::OscBeacon, &["10.0.0.9:9000"]);

        let grouped = reachable_peers_with_addrs(&[addressed, addressless, me], client_id);
        assert_eq!(grouped.len(), 1);
        assert_eq!(grouped[0].0, addressed_id);
    }

    #[test]
    fn offline_addresses_includes_looks_offline_peers_only() {
        let mut departed = peer_at(Uuid::new_v4(), DiscoveryMode::OscBeacon, &["10.0.0.1:9000"]);
        departed.departed = true;
        let online = peer_at(Uuid::new_v4(), DiscoveryMode::OscBeacon, &["10.0.0.2:9000"]);
        // ManualIp is exempt from looks_offline regardless of last_seen.
        let manual = peer_at(Uuid::new_v4(), DiscoveryMode::ManualIp, &["10.0.0.3:9000"]);

        let offline = offline_addresses(&[departed, online, manual], 7);
        assert!(offline.contains(&"10.0.0.1:9000".parse().unwrap()));
        assert!(!offline.contains(&"10.0.0.2:9000".parse().unwrap()));
        assert!(!offline.contains(&"10.0.0.3:9000".parse().unwrap()));
    }

    fn subnet() -> Option<(Ipv4Addr, Ipv4Addr)> {
        Some((
            "10.0.0.1".parse().unwrap(),
            "255.255.255.0".parse().unwrap(),
        ))
    }

    #[tokio::test]
    async fn admits_source_denies_arbitrary_source_when_unresolved() {
        let admission = NetworkAdmission::new(None);
        let config = Config {
            network_interface: None,
            ..Config::default()
        };
        assert!(
            !admission
                .admits_source("10.0.0.9".parse().unwrap(), &config)
                .await
        );
    }

    #[tokio::test]
    async fn admits_source_admits_static_peer_when_unresolved() {
        let admission = NetworkAdmission::new(None);
        let config = Config {
            network_interface: None,
            static_peers: vec![StaticPeer {
                address: "10.0.0.9".into(),
                port: 9000,
                label: None,
            }],
            ..Config::default()
        };
        assert!(
            admission
                .admits_source("10.0.0.9".parse().unwrap(), &config)
                .await
        );
    }

    #[tokio::test]
    async fn admits_source_admits_on_pinned_subnet_denies_off_subnet() {
        let admission = NetworkAdmission::new(subnet());
        let config = Config {
            network_interface: Some("en0".into()),
            ..Config::default()
        };
        assert!(
            admission
                .admits_source("10.0.0.42".parse().unwrap(), &config)
                .await
        );
        assert!(
            !admission
                .admits_source("192.168.1.1".parse().unwrap(), &config)
                .await
        );
    }

    #[test]
    fn set_pinned_subnet_replaces_the_cached_value() {
        let admission = NetworkAdmission::new(None);
        assert_eq!(admission.pinned_subnet_for_test(), None);
        admission.set_pinned_subnet(subnet());
        assert_eq!(admission.pinned_subnet_for_test(), subnet());
    }

    #[tokio::test]
    async fn message_dedup_returns_false_first_time_true_second() {
        let dedup = MessageDedup::new();
        let id = Uuid::new_v4();
        assert!(!dedup.is_duplicate(id).await);
        assert!(dedup.is_duplicate(id).await);
    }

    #[tokio::test]
    async fn message_dedup_different_ids_are_independent() {
        let dedup = MessageDedup::new();
        assert!(!dedup.is_duplicate(Uuid::new_v4()).await);
        assert!(!dedup.is_duplicate(Uuid::new_v4()).await);
    }
}
