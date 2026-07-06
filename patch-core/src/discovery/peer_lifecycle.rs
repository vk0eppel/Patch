//! Peer resolve/remove tracking, extracted from the mDNS browse loop in
//! `discovery::mod` so it's testable without a live mDNS daemon or tokio
//! runtime. Takes mDNS resolve/remove events in, emits Peer online/offline
//! decisions out.

use std::collections::HashMap;
use std::collections::HashSet;
use std::net::{IpAddr, Ipv4Addr};

use uuid::Uuid;

use crate::state::is_self;
use crate::transport::in_pinned_subnet;

/// Returns resolved mDNS addresses on the pinned subnet — empty when
/// `pinned_subnet` is unknown (unresolved pin, or the pinned interface's own
/// IP couldn't be resolved this tick). Under mandatory pinning these are the
/// same condition: no known subnet to match against, so nothing qualifies.
fn pick_resolved_addresses(
    addrs: &HashSet<IpAddr>,
    pinned_subnet: Option<(Ipv4Addr, Ipv4Addr)>,
) -> Vec<String> {
    let Some((iface_ip, mask)) = pinned_subnet else {
        return Vec::new();
    };
    addrs
        .iter()
        .filter(|ip| matches!(ip, IpAddr::V4(v4) if in_pinned_subnet(*v4, iface_ip, mask)))
        .map(|ip| ip.to_string())
        .collect()
}

/// What an mDNS resolution should record. `None` = record nothing: a
/// resolution with no on-subnet address must not create a Peer at all —
/// ADR-0010 drops that peer's OSC presence at the protocol boundary, so the
/// addressless entry could never gain an address and would sit in the panel
/// unreachable forever (#152). This covers both an unresolved pin (mandatory
/// pinning means "pending choice," not "Auto") and a momentarily-unresolvable
/// pinned interface — both leave `pinned_subnet` as `None`.
fn mdns_addresses_to_record(
    addrs: &HashSet<IpAddr>,
    pinned_subnet: Option<(Ipv4Addr, Ipv4Addr)>,
) -> Option<Vec<String>> {
    let picked = pick_resolved_addresses(addrs, pinned_subnet);
    if picked.is_empty() {
        return None;
    }
    Some(picked)
}

/// What to do with an mDNS `ServiceResolved` event.
#[derive(Debug, PartialEq, Eq)]
pub enum ResolveOutcome {
    /// Our own service — mDNS resolves it too; ignore.
    SelfService,
    /// Pinned, but nothing resolved on the pinned subnet — ADR-0010 drops an
    /// addressless peer's OSC presence at the protocol boundary, so recording
    /// it would leave a permanent ghost (#152).
    NoAddressOnPinnedSubnet,
    /// Record this peer. `addrs` empty means no usable address yet — record
    /// without one and let OSC presence fill it in.
    Record {
        peer_id: Uuid,
        peer_name: String,
        addrs: Vec<String>,
        port: u16,
    },
}

/// A raw mDNS `ServiceResolved` event, reduced to the fields `on_resolved`
/// needs — decoupled from `mdns_sd::ServiceInfo` so it's constructible in a
/// test without a live mDNS daemon.
pub struct ResolvedService<'a> {
    pub fullname: &'a str,
    pub peer_id_prop: Option<&'a str>,
    pub peer_name_prop: Option<&'a str>,
    pub addresses: &'a HashSet<IpAddr>,
    pub port: u16,
}

/// Tracks mDNS full-name → peer_id across a resolve/remove pair, since a
/// `ServiceRemoved` event carries no TXT properties to identify the peer by.
#[derive(Default)]
pub struct PeerLifecycle {
    resolved_ids: HashMap<String, Uuid>,
}

impl PeerLifecycle {
    pub fn new() -> Self {
        Self::default()
    }

    /// Decide what a `ServiceResolved` event means, and — if it should be
    /// recorded — remember the fullname → peer_id mapping for a later
    /// `on_removed`.
    pub fn on_resolved(
        &mut self,
        service: ResolvedService<'_>,
        client_id: Uuid,
        pinned_subnet: Option<(Ipv4Addr, Ipv4Addr)>,
    ) -> ResolveOutcome {
        let ResolvedService {
            fullname,
            peer_id_prop,
            peer_name_prop,
            addresses,
            port,
        } = service;

        let peer_id = peer_id_prop
            .and_then(|p| Uuid::parse_str(p).ok())
            .unwrap_or_else(Uuid::new_v4);

        // Skip our own service — mDNS resolves it too.
        if is_self(peer_id, client_id) {
            return ResolveOutcome::SelfService;
        }

        let Some(addrs) = mdns_addresses_to_record(addresses, pinned_subnet) else {
            return ResolveOutcome::NoAddressOnPinnedSubnet;
        };

        // Prefer the peer_name TXT record; fall back to stripping the
        // service-type suffix from the full DNS name.
        let peer_name = peer_name_prop.map(str::to_string).unwrap_or_else(|| {
            fullname
                .split("._patch._udp")
                .next()
                .unwrap_or(fullname)
                .to_string()
        });

        // Record all resolved addresses for unicast, but do NOT refresh
        // liveness here — mDNS can replay from a stale cache long after a
        // peer quits. `last_seen` is driven only by a
        // `PeerSighting::Presence`/`Heartbeat` sighting.
        self.resolved_ids.insert(fullname.to_string(), peer_id);

        ResolveOutcome::Record {
            peer_id,
            peer_name,
            addrs,
            port,
        }
    }

    /// A `ServiceRemoved` event — returns the peer_id to consider marking
    /// offline, if we'd previously resolved this fullname.
    ///
    /// `mdns-sd` fires spurious `ServiceRemoved` events far more readily on
    /// Windows than macOS/Linux, which otherwise flapped a still-live peer
    /// offline every time one arrived — see #126. The caller is expected to
    /// only mark the returned peer offline if it isn't still within its
    /// Online window (`mark_peer_offline_unless_recent`); a peer we've
    /// genuinely stopped hearing from still gets marked offline promptly.
    pub fn on_removed(&mut self, fullname: &str) -> Option<Uuid> {
        self.resolved_ids.remove(fullname)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn addrs(ips: &[&str]) -> HashSet<IpAddr> {
        ips.iter().map(|s| s.parse().unwrap()).collect()
    }

    fn subnet() -> Option<(Ipv4Addr, Ipv4Addr)> {
        Some((
            "169.254.10.1".parse().unwrap(),
            "255.255.0.0".parse().unwrap(),
        ))
    }

    #[test]
    fn pin_returns_only_addresses_on_matching_subnet() {
        let set = addrs(&["169.254.30.7", "10.0.2.9"]);
        assert_eq!(
            pick_resolved_addresses(&set, subnet()),
            vec!["169.254.30.7".to_string()]
        );
    }

    #[test]
    fn pin_with_no_matching_address_returns_empty_rather_than_guessing() {
        let set = addrs(&["10.0.2.9"]);
        assert!(pick_resolved_addresses(&set, subnet()).is_empty());
    }

    #[test]
    fn pin_configured_but_unresolvable_returns_empty_rather_than_first() {
        let set = addrs(&["10.0.2.9"]);
        assert!(pick_resolved_addresses(&set, None).is_empty());
    }

    #[test]
    fn pinned_resolution_with_no_on_subnet_address_records_nothing() {
        let set = addrs(&["10.0.2.9"]);
        assert_eq!(mdns_addresses_to_record(&set, subnet()), None);
        assert_eq!(mdns_addresses_to_record(&set, None), None);
    }

    #[test]
    fn unresolved_records_nothing_even_with_addresses() {
        let set = addrs(&["10.0.2.9"]);
        assert_eq!(mdns_addresses_to_record(&set, None), None);
    }

    #[test]
    fn pin_returns_multiple_matching_addresses() {
        let set = addrs(&["169.254.30.7", "169.254.31.2", "10.0.2.9"]);
        let result = pick_resolved_addresses(&set, subnet());
        assert_eq!(result.len(), 2);
        assert!(result.contains(&"169.254.30.7".to_string()));
        assert!(result.contains(&"169.254.31.2".to_string()));
    }

    #[test]
    fn resolving_our_own_service_is_skipped() {
        let mut lifecycle = PeerLifecycle::new();
        let client_id = Uuid::new_v4();
        let outcome = lifecycle.on_resolved(
            ResolvedService {
                fullname: "self._patch._udp.local.",
                peer_id_prop: Some(&client_id.to_string()),
                peer_name_prop: Some("Me"),
                addresses: &addrs(&["169.254.30.7"]),
                port: 53000,
            },
            client_id,
            subnet(),
        );
        assert_eq!(outcome, ResolveOutcome::SelfService);
    }

    #[test]
    fn resolving_a_peer_with_no_address_on_pinned_subnet_is_skipped() {
        let mut lifecycle = PeerLifecycle::new();
        let peer_id = Uuid::new_v4();
        let outcome = lifecycle.on_resolved(
            ResolvedService {
                fullname: "peer._patch._udp.local.",
                peer_id_prop: Some(&peer_id.to_string()),
                peer_name_prop: Some("Peer"),
                addresses: &addrs(&["10.0.2.9"]), // off pinned subnet
                port: 53000,
            },
            Uuid::new_v4(),
            subnet(),
        );
        assert_eq!(outcome, ResolveOutcome::NoAddressOnPinnedSubnet);
    }

    #[test]
    fn resolving_a_peer_on_subnet_records_it_and_remembers_the_fullname() {
        let mut lifecycle = PeerLifecycle::new();
        let peer_id = Uuid::new_v4();
        let outcome = lifecycle.on_resolved(
            ResolvedService {
                fullname: "peer._patch._udp.local.",
                peer_id_prop: Some(&peer_id.to_string()),
                peer_name_prop: Some("FOH Audio"),
                addresses: &addrs(&["169.254.30.7"]),
                port: 53000,
            },
            Uuid::new_v4(),
            subnet(),
        );
        assert_eq!(
            outcome,
            ResolveOutcome::Record {
                peer_id,
                peer_name: "FOH Audio".to_string(),
                addrs: vec!["169.254.30.7".to_string()],
                port: 53000,
            }
        );

        // Now a matching ServiceRemoved resolves back to the same peer_id.
        assert_eq!(
            lifecycle.on_removed("peer._patch._udp.local."),
            Some(peer_id)
        );
    }

    #[test]
    fn missing_peer_name_prop_falls_back_to_stripping_the_service_suffix() {
        let mut lifecycle = PeerLifecycle::new();
        let peer_id = Uuid::new_v4();
        let outcome = lifecycle.on_resolved(
            ResolvedService {
                fullname: "Stage Manager._patch._udp.local.",
                peer_id_prop: Some(&peer_id.to_string()),
                peer_name_prop: None,
                addresses: &addrs(&["169.254.30.7"]),
                port: 53000,
            },
            Uuid::new_v4(),
            subnet(),
        );
        assert_eq!(
            outcome,
            ResolveOutcome::Record {
                peer_id,
                peer_name: "Stage Manager".to_string(),
                addrs: vec!["169.254.30.7".to_string()],
                port: 53000,
            }
        );
    }

    #[test]
    fn missing_peer_id_prop_falls_back_to_a_random_uuid() {
        let mut lifecycle = PeerLifecycle::new();
        let outcome = lifecycle.on_resolved(
            ResolvedService {
                fullname: "peer._patch._udp.local.",
                peer_id_prop: None,
                peer_name_prop: Some("Peer"),
                addresses: &addrs(&["169.254.30.7"]),
                port: 53000,
            },
            Uuid::new_v4(),
            subnet(),
        );
        assert!(matches!(outcome, ResolveOutcome::Record { .. }));
    }

    #[test]
    fn removing_an_unresolved_fullname_returns_none() {
        let mut lifecycle = PeerLifecycle::new();
        assert_eq!(lifecycle.on_removed("never-seen._patch._udp.local."), None);
    }

    #[test]
    fn removing_the_same_fullname_twice_only_matches_once() {
        let mut lifecycle = PeerLifecycle::new();
        let peer_id = Uuid::new_v4();
        lifecycle.on_resolved(
            ResolvedService {
                fullname: "peer._patch._udp.local.",
                peer_id_prop: Some(&peer_id.to_string()),
                peer_name_prop: Some("Peer"),
                addresses: &addrs(&["169.254.30.7"]),
                port: 53000,
            },
            Uuid::new_v4(),
            subnet(),
        );
        assert_eq!(
            lifecycle.on_removed("peer._patch._udp.local."),
            Some(peer_id)
        );
        assert_eq!(lifecycle.on_removed("peer._patch._udp.local."), None);
    }
}
