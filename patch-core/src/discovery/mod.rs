//! Hybrid peer discovery:
//!   1. mDNS / Bonjour  — `_patch._udp.local.`
//!   2. OSC broadcast beacon — `/patch/presence`
//!   3. Static IP fallback — seeded from config, no active probing needed here

use anyhow::Result;
use chrono::Utc;
use mdns_sd::{ServiceDaemon, ServiceEvent, ServiceInfo};
use std::collections::HashMap;
use std::net::IpAddr;
use std::sync::Arc;
use tracing::{debug, info, warn};
use uuid::Uuid;

use std::net::Ipv4Addr;

use crate::osc::{codec::encode_presence, types::PeerPresence};
use crate::state::{is_self, AppState, Config, PeerSighting};
use crate::transport::{in_pinned_subnet, pinned_ipv4_subnet, Transport};

/// Returns all resolved mDNS addresses that match the configured interface pin.
/// With no pin, all addresses are returned. With a pin, only addresses on the
/// pinned subnet are returned — an empty Vec means "no matching address" and
/// callers should record the peer with an empty address (appears in the panel
/// but unreachable until an OSC presence provides a usable address).
fn pick_resolved_addresses(
    addrs: &std::collections::HashSet<IpAddr>,
    pin_configured: bool,
    pinned_subnet: Option<(Ipv4Addr, Ipv4Addr)>,
) -> Vec<String> {
    if pin_configured {
        let Some((iface_ip, mask)) = pinned_subnet else {
            return Vec::new();
        };
        return addrs
            .iter()
            .filter(|ip| matches!(ip, IpAddr::V4(v4) if in_pinned_subnet(*v4, iface_ip, mask)))
            .map(|ip| ip.to_string())
            .collect();
    }
    addrs.iter().map(|a| a.to_string()).collect()
}

pub struct Discovery {
    /// The mDNS daemon handle, held for the engine's lifetime. Dropping the last
    /// `ServiceDaemon` handle shuts the daemon thread down, so this must outlive
    /// `Discovery::new` — it's stored here and kept alive via `EngineHandle`.
    /// `None` when mDNS init failed and we fell back to OSC beacon only.
    _mdns: Option<ServiceDaemon>,
}

impl Discovery {
    pub async fn new(config: &Config, state: AppState, transport: Arc<Transport>) -> Result<Self> {
        let client_id = config.client_id;
        let client_name = config.client_name.clone();
        let osc_port = config.osc_port;

        // ── mDNS (best-effort — gracefully skipped if unavailable) ───────────
        let service_type = "_patch._udp.local.";
        // Returns the daemon handle on success so it can be held for the engine's
        // lifetime (dropping it would stop the daemon thread).
        let mdns_setup: anyhow::Result<ServiceDaemon> = async {
            let mdns = ServiceDaemon::new()?;

            // Register ourselves
            let instance_name = &client_name;
            let host_name = format!("{}.local.", gethostname());
            let mut props = HashMap::new();
            props.insert("peer_id".to_string(), client_id.to_string());
            props.insert("peer_name".to_string(), client_name.clone());
            props.insert("version".to_string(), "0.1.0".to_string());

            let service =
                ServiceInfo::new(service_type, instance_name, &host_name, "", osc_port, props)?;

            mdns.register(service)?;
            info!("mDNS service registered as '{}'", instance_name);

            // Browse for peers
            let browse_state = state.clone();
            let receiver = mdns.browse(service_type)?;
            tokio::spawn(async move {
                // Map a service's full mDNS name → its peer_id, so a later
                // ServiceRemoved (which carries no TXT props) can be matched back
                // to the peer and expired promptly.
                let mut resolved_ids: HashMap<String, Uuid> = HashMap::new();
                while let Ok(event) = receiver.recv_async().await {
                    match event {
                        ServiceEvent::ServiceResolved(info) => {
                            let peer_id = info
                                .get_properties()
                                .get("peer_id")
                                .and_then(|p| Uuid::parse_str(p.val_str()).ok())
                                .unwrap_or_else(Uuid::new_v4);

                            // Skip our own service — mDNS resolves it too.
                            if is_self(peer_id, client_id) {
                                continue;
                            }

                            let iface_pin = browse_state.config().await.network_interface.clone();
                            let pinned_subnet = iface_pin.as_deref().and_then(pinned_ipv4_subnet);
                            let addrs = pick_resolved_addresses(
                                info.get_addresses(),
                                iface_pin.is_some(),
                                pinned_subnet,
                            );
                            let port = info.get_port();

                            // Prefer the peer_name TXT record; fall back to stripping
                            // the service-type suffix from the full DNS name.
                            let peer_name = info
                                .get_properties()
                                .get("peer_name")
                                .map(|p| p.val_str().to_string())
                                .unwrap_or_else(|| {
                                    info.get_fullname()
                                        .split("._patch._udp")
                                        .next()
                                        .unwrap_or(info.get_fullname())
                                        .to_string()
                                });

                            debug!(
                                "mDNS resolved: {} ({}) @ {:?}:{}",
                                peer_name, peer_id, addrs, port
                            );
                            resolved_ids.insert(info.get_fullname().to_string(), peer_id);
                            // Record all resolved addresses for unicast, but do NOT
                            // refresh liveness — mDNS can replay from a stale cache
                            // long after a peer quits. `last_seen` is driven only by
                            // a `PeerSighting::Presence`/`Heartbeat` sighting.
                            if addrs.is_empty() {
                                // No usable address (e.g. pinned to a subnet with no
                                // match) — record without an address so the peer shows
                                // up in the panel; OSC presence will fill it in.
                                let presence = PeerPresence {
                                    peer_id,
                                    peer_name,
                                    channels: Vec::new(),
                                    role: None,
                                    timestamp: Utc::now(),
                                };
                                browse_state
                                    .record_sighting(
                                        PeerSighting::Mdns(presence),
                                        String::new(),
                                        port,
                                    )
                                    .await;
                            } else {
                                for addr in addrs {
                                    let presence = PeerPresence {
                                        peer_id,
                                        peer_name: peer_name.clone(),
                                        channels: Vec::new(),
                                        role: None,
                                        timestamp: Utc::now(),
                                    };
                                    browse_state
                                        .record_sighting(PeerSighting::Mdns(presence), addr, port)
                                        .await;
                                }
                            }
                        }
                        ServiceEvent::ServiceRemoved(_, fullname) => {
                            debug!("mDNS removed: {}", fullname);
                            // Mark offline (grey) now instead of waiting out the
                            // heartbeat timeout, but keep it in the list. If it was
                            // a transient mDNS blip and the peer is still up, its
                            // next OSC presence greens it again.
                            if let Some(peer_id) = resolved_ids.remove(&fullname) {
                                browse_state.mark_peer_offline(peer_id).await;
                            }
                        }
                        _ => {}
                    }
                }
            });
            Ok(mdns)
        }
        .await;

        // Keep the daemon handle alive (in `Discovery`) so the browse task and
        // service registration survive past `new()`; `None` means mDNS is
        // unavailable and we run on the OSC beacon alone.
        let mdns = match mdns_setup {
            Ok(daemon) => Some(daemon),
            Err(e) => {
                warn!("mDNS unavailable, falling back to OSC beacon only: {}", e);
                None
            }
        };

        // ── Heartbeat + beacon task ───────────────────────────────────────────
        let hb_state = state.clone();
        let hb_transport = transport.clone();
        tokio::spawn(async move {
            // First heartbeat fires immediately (like interval's first tick);
            // the cadence is re-read from config at the end of each iteration so
            // a Settings change to the interval applies on the next cycle with no
            // restart.
            loop {
                // Broadcast our presence so every peer on the LAN can discover us.
                let channels = hb_state
                    .get_channels()
                    .await
                    .iter()
                    .map(|c| c.id.clone())
                    .collect();
                // Re-read config every tick so a rename (or a NIC change)
                // propagates within one heartbeat without a restart.
                let cfg = hb_state.config().await;
                let presence = PeerPresence {
                    peer_id: client_id,
                    peer_name: cfg.client_name.clone(),
                    channels,
                    role: cfg.role.clone(), // re-read each tick → role changes propagate ≤1 interval
                    timestamp: Utc::now(),
                };
                match encode_presence(&presence) {
                    Ok(bytes) => {
                        debug!(
                            "Heartbeat — presence broadcast + unicast on port {}",
                            osc_port
                        );
                        // Broadcast so still-undiscovered peers can find us
                        // (subnet-directed + macOS per-NIC, see transport::broadcast_all_paths).
                        hb_transport
                            .broadcast_all_paths(&bytes, osc_port, cfg.network_interface.as_deref())
                            .await;
                        // Also unicast to peers we already know (dynamic + static):
                        // a peer we can see learns about us even when our broadcast
                        // can't reach them (asymmetric routing / AP isolation).
                        // Unicast routes per-subnet, ignoring a bad default route.
                        let _ = hb_transport.send_to_peers(bytes, &hb_state, &cfg).await;
                    }
                    Err(e) => warn!("Failed to encode presence: {}", e),
                }

                // Shed dead per-peer address paths at 3× heartbeat interval
                // without expiring the peer itself — liveness classification
                // is driven by last_seen, not by which addresses remain.
                hb_state
                    .prune_peer_addresses(cfg.heartbeat_interval_secs)
                    .await;

                // Peers are never auto-expired — they stay in the list for the
                // whole session. The Flutter side uses lastSeen to show green/gray.

                // Wait the *currently configured* interval before the next beat.
                // `api::set_heartbeat_interval` validates 1–60; clamp here too so
                // a hand-edited patch.toml can't busy-loop (0) or stall forever.
                let secs = cfg.heartbeat_interval_secs.clamp(1, 60);
                tokio::time::sleep(std::time::Duration::from_secs(secs)).await;
            }
        });

        Ok(Self { _mdns: mdns })
    }
}

/// Best-effort hostname for the mDNS host record. Looked up in-process rather
/// than by forking the `hostname` binary; falls back to a stable default.
fn gethostname() -> String {
    #[cfg(unix)]
    {
        let mut buf = [0u8; 256];
        let rc = unsafe { libc::gethostname(buf.as_mut_ptr() as *mut libc::c_char, buf.len()) };
        if rc == 0 {
            // The buffer may not be NUL-terminated if the name was truncated.
            let end = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
            if let Ok(s) = std::str::from_utf8(&buf[..end]) {
                if !s.is_empty() {
                    return s.to_string();
                }
            }
        }
    }
    #[cfg(windows)]
    {
        // Windows reliably sets COMPUTERNAME — no syscall needed.
        if let Ok(name) = std::env::var("COMPUTERNAME") {
            if !name.is_empty() {
                return name;
            }
        }
    }
    "patch-node".to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    fn addrs(ips: &[&str]) -> HashSet<IpAddr> {
        ips.iter().map(|s| s.parse().unwrap()).collect()
    }

    #[test]
    fn no_pin_returns_all_addresses() {
        let set = addrs(&["10.0.2.5", "192.168.1.1"]);
        let result = pick_resolved_addresses(&set, false, None);
        assert_eq!(result.len(), 2);
    }

    #[test]
    fn no_pin_single_address_returns_it() {
        let set = addrs(&["10.0.2.5"]);
        assert_eq!(
            pick_resolved_addresses(&set, false, None),
            vec!["10.0.2.5".to_string()]
        );
    }

    #[test]
    fn pin_returns_only_addresses_on_matching_subnet() {
        // M1 pinned to the wired Dante NIC (169.254.x.x/16); Intel's service
        // resolved with both its Dante address and an unrelated Wi-Fi one.
        let set = addrs(&["169.254.30.7", "10.0.2.9"]);
        let pinned_subnet = Some((
            "169.254.10.1".parse().unwrap(),
            "255.255.0.0".parse().unwrap(),
        ));
        assert_eq!(
            pick_resolved_addresses(&set, true, pinned_subnet),
            vec!["169.254.30.7".to_string()]
        );
    }

    #[test]
    fn pin_with_no_matching_address_returns_empty_rather_than_guessing() {
        let set = addrs(&["10.0.2.9"]); // only the unrelated Wi-Fi address resolved
        let pinned_subnet = Some((
            "169.254.10.1".parse().unwrap(),
            "255.255.0.0".parse().unwrap(),
        ));
        assert!(pick_resolved_addresses(&set, true, pinned_subnet).is_empty());
    }

    #[test]
    fn pin_configured_but_unresolvable_returns_empty_rather_than_first() {
        // The pinned interface itself couldn't be found/resolved this tick —
        // don't fall back to "first address", which could be the wrong NIC.
        let set = addrs(&["10.0.2.9"]);
        assert!(pick_resolved_addresses(&set, true, None).is_empty());
    }

    #[test]
    fn pin_returns_multiple_matching_addresses() {
        // Peer with two Dante addresses on the pinned subnet — both should be kept.
        let set = addrs(&["169.254.30.7", "169.254.31.2", "10.0.2.9"]);
        let pinned_subnet = Some((
            "169.254.10.1".parse().unwrap(),
            "255.255.0.0".parse().unwrap(),
        ));
        let result = pick_resolved_addresses(&set, true, pinned_subnet);
        assert_eq!(result.len(), 2);
        assert!(result.contains(&"169.254.30.7".to_string()));
        assert!(result.contains(&"169.254.31.2".to_string()));
    }
}
