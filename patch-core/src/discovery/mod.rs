//! Hybrid peer discovery:
//!   1. mDNS / Bonjour  — `_patch._udp.local.`
//!   2. OSC broadcast beacon — `/patch/presence`
//!   3. Static IP fallback — seeded from config, no active probing needed here

use anyhow::Result;
use chrono::Utc;
use mdns_sd::{ServiceDaemon, ServiceEvent, ServiceInfo};
use std::collections::HashMap;
use std::sync::Arc;
use tracing::{debug, info, warn};

use crate::osc::{codec::encode_presence, types::PeerPresence};
use crate::state::{AppState, Config, PeerSighting};
use crate::transport::{pinned_ipv4_subnet, Transport};

mod peer_lifecycle;
use peer_lifecycle::{PeerLifecycle, ResolveOutcome, ResolvedService};

pub struct Discovery {
    /// The mDNS daemon handle, held for the engine's lifetime. Dropping the last
    /// `ServiceDaemon` handle shuts the daemon thread down, so this must outlive
    /// `Discovery::new` — it's stored here and kept alive via `EngineHandle`.
    /// `None` when mDNS init failed and we fell back to OSC beacon only.
    mdns: Option<ServiceDaemon>,
    /// Fullname of the record currently registered on the daemon — what a
    /// re-advertisement (#192) unregisters before registering the fresh one.
    registered_fullname: std::sync::Mutex<Option<String>>,
}

/// The daemon operations a (re-)advertisement needs — a seam so #192's
/// re-register logic is drivable in a test without a live mDNS daemon.
pub(crate) trait MdnsRegistrar {
    fn register_service(&self, info: ServiceInfo) -> anyhow::Result<()>;
    fn unregister_service(&self, fullname: &str) -> anyhow::Result<()>;
}

impl MdnsRegistrar for ServiceDaemon {
    fn register_service(&self, info: ServiceInfo) -> anyhow::Result<()> {
        Ok(self.register(info)?)
    }
    fn unregister_service(&self, fullname: &str) -> anyhow::Result<()> {
        // Fire-and-forget: the returned status receiver isn't awaited — the
        // fresh registration is what matters, and shutdown doesn't come
        // through here (the daemon drops with the engine).
        self.unregister(fullname)?;
        Ok(())
    }
}

/// Our mDNS service record for `port` — the one builder used by both the
/// startup registration and a live re-advertisement (#192), so the advertised
/// port can't drift between the two paths.
fn build_service_info(
    client_id: uuid::Uuid,
    client_name: &str,
    port: u16,
) -> anyhow::Result<ServiceInfo> {
    let service_type = "_patch._udp.local.";
    let host_name = format!("{}.local.", gethostname());
    let mut props = HashMap::new();
    props.insert("peer_id".to_string(), client_id.to_string());
    props.insert("peer_name".to_string(), client_name.to_string());
    props.insert("version".to_string(), "0.1.0".to_string());
    Ok(ServiceInfo::new(
        service_type,
        client_name,
        &host_name,
        "",
        port,
        props,
    )?)
}

/// Replace the advertised record: best-effort unregister of `old_fullname`
/// (a failure is logged, never blocking — the fresh record is what matters),
/// then register a new record for `port`. Returns the new fullname for the
/// caller to remember for the next re-advertisement.
fn readvertise_service(
    registrar: &impl MdnsRegistrar,
    client_id: uuid::Uuid,
    client_name: &str,
    port: u16,
    old_fullname: &str,
) -> anyhow::Result<String> {
    if let Err(e) = registrar.unregister_service(old_fullname) {
        warn!("mDNS unregister of {} failed: {} — re-registering anyway", old_fullname, e);
    }
    let info = build_service_info(client_id, client_name, port)?;
    let fullname = info.get_fullname().to_string();
    registrar.register_service(info)?;
    Ok(fullname)
}

impl Discovery {
    pub async fn new(config: &Config, state: AppState, transport: Arc<Transport>) -> Result<Self> {
        let client_id = config.client_id;
        let client_name = config.client_name.clone();
        let osc_port = config.osc_port;

        // ── mDNS (best-effort — gracefully skipped if unavailable) ───────────
        let service_type = "_patch._udp.local.";
        // Returns the daemon handle + registered fullname on success so both
        // can be held for the engine's lifetime (dropping the daemon would
        // stop its thread; the fullname is what `readvertise` unregisters).
        let mdns_setup: anyhow::Result<(ServiceDaemon, String)> = async {
            let mdns = ServiceDaemon::new()?;

            // Register ourselves. A live OSC-port change re-registers with
            // the new port via `Discovery::readvertise` (#192).
            let service = build_service_info(client_id, &client_name, osc_port)?;
            let fullname = service.get_fullname().to_string();

            mdns.register(service)?;
            info!("mDNS service registered as '{}'", client_name);

            // Browse for peers
            let browse_state = state.clone();
            let receiver = mdns.browse(service_type)?;
            tokio::spawn(async move {
                let mut lifecycle = PeerLifecycle::new();
                while let Ok(event) = receiver.recv_async().await {
                    match event {
                        ServiceEvent::ServiceResolved(info) => {
                            let iface_pin = browse_state.config().await.network_interface.clone();
                            let pinned_subnet = iface_pin.as_deref().and_then(pinned_ipv4_subnet);
                            let peer_id_prop =
                                info.get_properties().get("peer_id").map(|p| p.val_str());
                            let peer_name_prop =
                                info.get_properties().get("peer_name").map(|p| p.val_str());

                            let outcome = lifecycle.on_resolved(
                                ResolvedService {
                                    fullname: info.get_fullname(),
                                    peer_id_prop,
                                    peer_name_prop,
                                    addresses: info.get_addresses(),
                                    port: info.get_port(),
                                },
                                client_id,
                                pinned_subnet,
                            );

                            match outcome {
                                ResolveOutcome::SelfService => {}
                                ResolveOutcome::NoAddressOnPinnedSubnet => {
                                    debug!(
                                        "mDNS resolved {} with no address on the pinned network — skipped",
                                        info.get_fullname()
                                    );
                                }
                                ResolveOutcome::Record {
                                    peer_id,
                                    peer_name,
                                    addrs,
                                    port,
                                } => {
                                    debug!(
                                        "mDNS resolved: {} ({}) @ {:?}:{}",
                                        peer_name, peer_id, addrs, port
                                    );
                                    for addr in addrs {
                                        let presence = PeerPresence {
                                            peer_id,
                                            peer_name: peer_name.clone(),
                                            channels: Vec::new(),
                                            role: None,
                                            timestamp: Utc::now(),
                                        };
                                        browse_state
                                            .record_sighting(
                                                PeerSighting::Mdns(presence),
                                                addr,
                                                port,
                                            )
                                            .await;
                                    }
                                }
                            }
                        }
                        ServiceEvent::ServiceRemoved(_, fullname) => {
                            debug!("mDNS removed: {}", fullname);
                            // Mark offline (grey) now instead of waiting out the
                            // heartbeat timeout, but keep it in the list. If it was
                            // a transient mDNS blip and the peer is still up, its
                            // next OSC presence greens it again.
                            if let Some(peer_id) = lifecycle.on_removed(&fullname) {
                                let heartbeat_secs =
                                    browse_state.config().await.heartbeat_interval_secs;
                                browse_state
                                    .mark_peer_offline_unless_recent(peer_id, heartbeat_secs)
                                    .await;
                            }
                        }
                        _ => {}
                    }
                }
            });
            Ok((mdns, fullname))
        }
        .await;

        // Keep the daemon handle alive (in `Discovery`) so the browse task and
        // service registration survive past `new()`; `None` means mDNS is
        // unavailable and we run on the OSC beacon alone.
        let (mdns, registered_fullname) = match mdns_setup {
            Ok((daemon, fullname)) => (Some(daemon), Some(fullname)),
            Err(e) => {
                warn!("mDNS unavailable, falling back to OSC beacon only: {}", e);
                (None, None)
            }
        };

        // ── Heartbeat + beacon task ───────────────────────────────────────────
        spawn_heartbeat_loop(client_id, state, transport);

        Ok(Self {
            mdns,
            registered_fullname: std::sync::Mutex::new(registered_fullname),
        })
    }

    /// Re-advertise the mDNS record after a live OSC-port rebind (#192), so
    /// mDNS-only discovery resolves us at the new port instead of the stale
    /// startup one. Best-effort, like all of mDNS here: with no daemon (mDNS
    /// unavailable at startup) this is a no-op, and a failure is logged — the
    /// port change itself must never fail on it. Reads the current
    /// `client_name` from `config`, so a rename since startup rides along.
    pub async fn readvertise(&self, config: &Config) {
        let Some(mdns) = &self.mdns else {
            debug!("mDNS unavailable — skipping re-advertisement");
            return;
        };
        let old_fullname = self
            .registered_fullname
            .lock()
            .expect("registered_fullname lock poisoned")
            .clone()
            .unwrap_or_default();
        match readvertise_service(
            mdns,
            config.client_id,
            &config.client_name,
            config.osc_port,
            &old_fullname,
        ) {
            Ok(new_fullname) => {
                info!(
                    "mDNS record re-registered as '{}' on port {}",
                    new_fullname, config.osc_port
                );
                *self
                    .registered_fullname
                    .lock()
                    .expect("registered_fullname lock poisoned") = Some(new_fullname);
            }
            Err(e) => warn!(
                "mDNS re-registration for port {} failed: {} — peers will still \
                 converge via the OSC presence beacon",
                config.osc_port, e
            ),
        }
    }
}

/// The presence heartbeat/beacon loop, extracted from `Discovery::new` so the
/// beacon cadence and path decisions are drivable in a test (mirrors
/// `reliability::spawn_retransmit_loop`).
pub(crate) fn spawn_heartbeat_loop(
    client_id: uuid::Uuid,
    state: AppState,
    transport: Arc<Transport>,
) -> tokio::task::JoinHandle<()> {
    let hb_state = state;
    let hb_transport = transport;
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
                        cfg.osc_port
                    );
                    // Broadcast so still-undiscovered peers can find us
                    // (subnet-directed + macOS per-NIC, see transport::broadcast_all_paths).
                    // Unresolved (no pin yet) stays fully inert outbound too.
                    // The target port is re-read from config each tick so a live
                    // OSC-port change (`api::set_osc_port` rebinds the socket
                    // without a restart) moves the beacon with it.
                    if crate::transport::should_broadcast(cfg.network_interface.as_deref()) {
                        hb_transport
                            .broadcast_all_paths(
                                &bytes,
                                cfg.osc_port,
                                cfg.network_interface.as_deref(),
                            )
                            .await;
                    }
                    // Also unicast to peers we already know (dynamic + static):
                    // a peer we can see learns about us even when our broadcast
                    // can't reach them (asymmetric routing / AP isolation).
                    // Unicast routes per-subnet, ignoring a bad default route.
                    // While the pin is unresolved, dynamic discovery is fully
                    // inert (ADR-0011) — presence goes to Static Peers only,
                    // the deliberate exception.
                    if cfg.network_interface.is_some() {
                        let _ = hb_transport.send_to_peers(bytes, &hb_state, &cfg).await;
                    } else {
                        for addr in hb_state.static_peer_addrs(cfg.client_id).await {
                            let _ = hb_transport.send_to(bytes.clone(), addr).await;
                        }
                    }
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
            // The setter validates and config load sanitizes; clamp here
            // too so no path can busy-loop (0) or stall forever.
            let secs = cfg.heartbeat_interval_secs.clamp(
                crate::state::config::HEARTBEAT_MIN_SECS,
                crate::state::config::HEARTBEAT_MAX_SECS,
            );
            tokio::time::sleep(std::time::Duration::from_secs(secs)).await;
        }
    })
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
    use crate::osc::codec::{decode_packet, PatchEvent};
    use uuid::Uuid;

    /// The advertised record must carry the port it was built for — the #192
    /// seam: a live OSC-port rebind re-registers through this same builder,
    /// so the port here is the port peers resolve.
    #[test]
    fn build_service_info_carries_the_given_port_and_identity() {
        let client_id = Uuid::new_v4();
        let info = build_service_info(client_id, "FOH Audio", 9100).unwrap();
        assert_eq!(info.get_port(), 9100);
        assert!(info.get_fullname().contains("._patch._udp.local."));
        assert_eq!(
            info.get_properties()
                .get("peer_id")
                .map(|p| p.val_str().to_string()),
            Some(client_id.to_string())
        );
    }

    /// A recording fake standing in for the mDNS daemon — #192's seam-level
    /// test: assert the re-register happens with the new port without a live
    /// daemon (untestable in CI).
    #[derive(Default)]
    struct FakeRegistrar {
        unregistered: std::sync::Mutex<Vec<String>>,
        registered: std::sync::Mutex<Vec<(String, u16)>>,
    }

    impl MdnsRegistrar for FakeRegistrar {
        fn register_service(&self, info: ServiceInfo) -> anyhow::Result<()> {
            self.registered
                .lock()
                .unwrap()
                .push((info.get_fullname().to_string(), info.get_port()));
            Ok(())
        }
        fn unregister_service(&self, fullname: &str) -> anyhow::Result<()> {
            self.unregistered.lock().unwrap().push(fullname.to_string());
            Ok(())
        }
    }

    #[test]
    fn readvertise_unregisters_the_old_record_and_registers_the_new_port() {
        let fake = FakeRegistrar::default();
        let client_id = Uuid::new_v4();

        let new_fullname =
            readvertise_service(&fake, client_id, "FOH Audio", 9100, "old._patch._udp.local.")
                .unwrap();

        assert_eq!(
            *fake.unregistered.lock().unwrap(),
            vec!["old._patch._udp.local.".to_string()]
        );
        let registered = fake.registered.lock().unwrap();
        assert_eq!(registered.len(), 1);
        assert_eq!(registered[0].0, new_fullname);
        assert_eq!(registered[0].1, 9100, "re-registration must carry the new port");
    }

    /// A failed unregister (e.g. daemon already lost the record) must not
    /// block the re-registration — the fresh record is what matters.
    #[test]
    fn readvertise_still_registers_when_unregister_fails() {
        struct FailingUnregister(FakeRegistrar);
        impl MdnsRegistrar for FailingUnregister {
            fn register_service(&self, info: ServiceInfo) -> anyhow::Result<()> {
                self.0.register_service(info)
            }
            fn unregister_service(&self, _fullname: &str) -> anyhow::Result<()> {
                anyhow::bail!("daemon has no such record")
            }
        }

        let fake = FailingUnregister(FakeRegistrar::default());
        readvertise_service(
            &fake,
            Uuid::new_v4(),
            "FOH Audio",
            9100,
            "old._patch._udp.local.",
        )
        .unwrap();
        assert_eq!(fake.0.registered.lock().unwrap().len(), 1);
    }

    /// Build state + transport + a loopback listener for driving the loop.
    async fn harness() -> (Config, AppState, Arc<Transport>, tokio::net::UdpSocket) {
        let config = Config {
            client_name: "hb-test".into(),
            default_channels: Vec::new(),
            heartbeat_interval_secs: 1, // fastest legal cadence, for the second-beat assertion
            ..Config::default()
        };
        let state = AppState::new(config.clone());
        let reliability = std::sync::Arc::new(tokio::sync::Mutex::new(
            crate::reliability::ReliabilityManager::new(),
        ));
        let transport = Arc::new(
            Transport::new(
                &Config {
                    osc_port: 0,
                    ..config.clone()
                },
                state.clone(),
                reliability,
            )
            .await
            .unwrap(),
        );
        let listener = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
        (config, state, transport, listener)
    }

    /// The heartbeat loop's first beat fires immediately and unicasts our
    /// presence to a Static Peer even while the pin is unresolved — Static
    /// Peers are the deliberate exception to unresolved-is-inert (ADR-0011,
    /// CONTEXT.md "Pinned Network").
    #[tokio::test]
    async fn spawn_heartbeat_loop_unicasts_presence_to_a_static_peer() {
        let (config, state, transport, listener) = harness().await;
        let client_id = config.client_id;
        let listener_addr = listener.local_addr().unwrap();
        state
            .add_static_peer(
                listener_addr.ip().to_string(),
                listener_addr.port(),
                Some("listener-peer".into()),
            )
            .await
            .unwrap();

        let handle = spawn_heartbeat_loop(client_id, state, transport);

        let mut buf = [0u8; 4096];
        let (n, _) = tokio::time::timeout(
            std::time::Duration::from_secs(2),
            listener.recv_from(&mut buf),
        )
        .await
        .expect("expected a presence heartbeat within 2s")
        .unwrap();

        match decode_packet(&buf[..n]).unwrap() {
            PatchEvent::Presence(p) => {
                assert_eq!(p.peer_id, client_id);
                assert_eq!(p.peer_name, "hb-test");
            }
            other => panic!("expected Presence, got {other:?}"),
        }

        // Cadence: a second beat follows within the configured interval
        // (plus slack) — the loop keeps ticking, it isn't a one-shot.
        let (n, _) = tokio::time::timeout(
            std::time::Duration::from_secs(3),
            listener.recv_from(&mut buf),
        )
        .await
        .expect("expected a second heartbeat within the configured cadence")
        .unwrap();
        assert!(matches!(
            decode_packet(&buf[..n]).unwrap(),
            PatchEvent::Presence(_)
        ));
        handle.abort();
    }

    /// While the pin is unresolved, dynamic discovery is fully inert in both
    /// directions (ADR-0011): no broadcast (`should_broadcast`, unit-tested at
    /// the transport seam) and no unicast presence to dynamic peers. In
    /// production a dynamic peer can't even exist while unresolved (admission
    /// drops all inbound); this pins the outbound half at the loop level with
    /// an artificially injected sighting.
    #[tokio::test]
    async fn spawn_heartbeat_loop_is_inert_toward_dynamic_peers_while_unresolved() {
        let (config, state, transport, listener) = harness().await;
        assert!(
            config.network_interface.is_none(),
            "test premise: unresolved"
        );
        let listener_addr = listener.local_addr().unwrap();
        state
            .record_sighting(
                PeerSighting::Presence(PeerPresence {
                    peer_id: Uuid::new_v4(),
                    peer_name: "dynamic-peer".into(),
                    channels: Vec::new(),
                    role: None,
                    timestamp: Utc::now(),
                }),
                listener_addr.ip().to_string(),
                listener_addr.port(),
            )
            .await;

        let handle = spawn_heartbeat_loop(config.client_id, state, transport);

        // The first beat fires immediately; give it a full interval and slack
        // to prove silence rather than a race.
        let mut buf = [0u8; 4096];
        let got = tokio::time::timeout(
            std::time::Duration::from_millis(1500),
            listener.recv_from(&mut buf),
        )
        .await;
        assert!(
            got.is_err(),
            "expected no presence unicast to a dynamic peer while unresolved"
        );
        handle.abort();
    }
}
