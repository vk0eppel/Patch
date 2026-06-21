//! UDP transport layer — OSC send/receive with network interface binding.

use anyhow::{Context, Result};
use network_interface::{Addr, NetworkInterface, NetworkInterfaceConfig};
use std::collections::HashSet;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::Arc;
use tokio::net::UdpSocket;
use tokio::sync::{mpsc, watch, Mutex};
use tracing::{debug, error, warn};
use uuid::Uuid;

use crate::osc::codec::decode_packet;
#[cfg(test)]
use crate::osc::types::PeerPresence;
use crate::reliability::ReliabilityManager;
use crate::state::{AppState, Config};

/// A queued outgoing packet, processed by the single `send_loop` task. Routing
/// everything through one task means the per-interface broadcast can set/clear
/// the socket's `IP_BOUND_IF` option without racing concurrent unicast sends.
pub(crate) enum Outgoing {
    /// Unicast these bytes to a specific peer via the default route.
    To(Vec<u8>, SocketAddr),
    /// Best-effort broadcast (presence/discovery beacon). Send failures are
    /// *expected* on some networks — e.g. iOS routinely has no route for the
    /// limited broadcast `255.255.255.255` (cellular / Wi-Fi transitions),
    /// returning `EHOSTUNREACH` — so they're logged at `debug`, not `error`.
    Broadcast(Vec<u8>, SocketAddr),
    /// macOS only: send `255.255.255.255:port` out of **every** usable interface
    /// (optionally pinned to one), binding each send to the interface via
    /// `IP_BOUND_IF`. Works around macOS only egressing the limited broadcast on
    /// the default-route NIC — and only *delivering* `255.255.255.255` (never
    /// subnet-directed) to receiving apps — which otherwise leaves a multi-NIC
    /// Mac (VPN/Ethernet default route) unable to make first contact. The source
    /// port stays 9000 (the main socket), so receivers learn the right unicast port.
    #[cfg(target_os = "macos")]
    PerIfaceBroadcast(Vec<u8>, u16, Option<String>),
}

pub struct Transport {
    /// The live socket, published over a `watch` so it can be swapped for a live
    /// OSC-port rebind. The receive/send loops hold receivers and switch to the
    /// new socket when it changes; once swapped, the old socket's last `Arc` drops
    /// and the OS frees the old port. `socket_tx` also keeps the channel (and thus
    /// the loops' `changed()` future) alive for the transport's lifetime.
    socket_tx: watch::Sender<Arc<UdpSocket>>,
    socket_rx: watch::Receiver<Arc<UdpSocket>>,
    /// Sender half — clone to send packets from any task.
    send_tx: mpsc::Sender<Outgoing>,
}

impl Transport {
    pub async fn new(
        config: &Config,
        state: AppState,
        reliability: Arc<Mutex<ReliabilityManager>>,
    ) -> Result<Self> {
        let bind_addr = bind_address(config);
        let socket = bind_socket(&bind_addr).await?;

        let (socket_tx, socket_rx) = watch::channel(socket);
        let (send_tx, send_rx) = mpsc::channel::<Outgoing>(256);

        // Receive loop. It also needs the send half (to emit ACKs for critical
        // messages) and the reliability manager (to clear acked retransmits).
        let rx_socket = socket_rx.clone();
        let rx_state = state.clone();
        let rx_send_tx = send_tx.clone();
        let rx_reliability = Arc::clone(&reliability);
        let client_id = config.client_id;
        tokio::spawn(async move {
            receive_loop(rx_socket, rx_state, client_id, rx_send_tx, rx_reliability).await;
        });

        // Send loop
        let tx_socket = socket_rx.clone();
        tokio::spawn(async move {
            send_loop(tx_socket, send_rx).await;
        });

        Ok(Self {
            socket_tx,
            socket_rx,
            send_tx,
        })
    }

    /// The current socket. Cheap (`watch::Ref` clone of an `Arc`); reflects the
    /// latest rebind.
    fn socket(&self) -> Arc<UdpSocket> {
        self.socket_rx.borrow().clone()
    }

    /// The port the current socket is bound to. Test-only accessor used to assert
    /// a live rebind actually moved the socket.
    #[cfg(test)]
    pub(crate) fn bound_port(&self) -> u16 {
        self.socket().local_addr().map(|a| a.port()).unwrap_or(0)
    }

    /// Rebind the UDP socket to the port (and interface scope) in `config`,
    /// **live** — no restart. Binds the new socket first (so a bind failure leaves
    /// the old socket untouched), then publishes it: the receive loop switches via
    /// `select!` on the next event, the send paths read it on their next send, and
    /// the old socket's last `Arc` drops, freeing the old port.
    pub async fn rebind(&self, config: &Config) -> Result<()> {
        let bind_addr = bind_address(config);
        let socket = bind_socket(&bind_addr).await?;
        // Replaces the watched value; both loops observe the change.
        let _ = self.socket_tx.send(socket);
        tracing::info!("UDP socket rebound on {}", bind_addr);
        Ok(())
    }

    /// Send raw OSC bytes to a specific address.
    pub async fn send_to(&self, bytes: Vec<u8>, addr: SocketAddr) -> Result<()> {
        self.send_tx
            .send(Outgoing::To(bytes, addr))
            .await
            .context("Send channel closed")
    }

    /// Send raw OSC bytes immediately on the socket, bypassing the send queue.
    /// Used on shutdown so the departure packet actually flushes before the
    /// process exits (a queued send may never be drained in time).
    pub async fn send_now(&self, bytes: &[u8], addr: SocketAddr) -> Result<()> {
        self.socket()
            .send_to(bytes, addr)
            .await
            .context("Direct send failed")?;
        Ok(())
    }

    /// Broadcast raw OSC bytes (presence heartbeat / discovery beacon) to the
    /// subnet-directed broadcast of every usable interface, so the OS routes a
    /// copy out each NIC. `iface` pins to a single interface when set.
    pub async fn broadcast(&self, bytes: Vec<u8>, port: u16, iface: Option<&str>) -> Result<()> {
        for addr in broadcast_targets(iface, port) {
            // Enqueue as a best-effort Broadcast so send failures (common on iOS
            // for 255.255.255.255) don't surface as errors.
            if self
                .send_tx
                .send(Outgoing::Broadcast(bytes.clone(), addr))
                .await
                .is_err()
            {
                warn!("Send channel closed during broadcast");
                break;
            }
        }
        Ok(())
    }

    /// Same targets as [`broadcast`], but flushed directly on the socket
    /// (used on shutdown so the `/patch/bye` actually goes out before exit).
    pub async fn broadcast_now(&self, bytes: &[u8], port: u16, iface: Option<&str>) {
        for addr in broadcast_targets(iface, port) {
            let _ = self.send_now(bytes, addr).await;
        }
    }

    /// macOS only: additionally send the limited broadcast (`255.255.255.255`)
    /// out of **every** usable interface (or just `iface` when pinned), so a
    /// multi-NIC Mac whose default route is a VPN/Ethernet still reaches the show
    /// Wi-Fi for first contact. Additive on top of [`broadcast`] (which still
    /// sends the default-route copy + subnet-directed targets) — never a
    /// replacement, so it can't regress the working path. A no-op off macOS,
    /// where the routing table already pushes subnet-directed broadcasts out each
    /// NIC and those *are* delivered to receiving apps.
    pub async fn broadcast_per_interface(&self, bytes: Vec<u8>, port: u16, iface: Option<&str>) {
        #[cfg(target_os = "macos")]
        {
            let _ = self
                .send_tx
                .send(Outgoing::PerIfaceBroadcast(
                    bytes,
                    port,
                    iface.map(str::to_string),
                ))
                .await;
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = (bytes, port, iface); // unused off macOS
        }
    }

    /// Unicast raw OSC bytes to every known peer.
    ///
    /// Target resolution (skip self, skip unaddressed peers, dedup by
    /// `SocketAddr` so a static peer also seen dynamically isn't double-fired)
    /// lives in `AppState::reachable_peer_addrs` — shared with the `/patch/say`
    /// relay in `protocol::handle`, which sends the same target list a different
    /// way (queued via `send_tx` instead of direct socket send).
    ///
    /// Returns the addresses actually contacted (used for ACK tracking). If no
    /// peers are known yet, the packet is silently dropped — no broadcast fallback.
    pub async fn send_to_peers(
        &self,
        bytes: Vec<u8>,
        state: &AppState,
        config: &Config,
    ) -> Result<Vec<SocketAddr>> {
        let targets = state.reachable_peer_addrs(config.client_id).await;

        let mut sent = 0usize;
        for addr in &targets {
            if let Err(e) = self.send_to(bytes.clone(), *addr).await {
                warn!("Send to {} failed: {}", addr, e);
            } else {
                debug!("Unicast → {}", addr);
                sent += 1;
            }
        }

        if sent == 0 {
            if targets.is_empty() {
                debug!("No peers known yet — packet not sent");
            } else {
                warn!("send_to_peers: all {} send(s) failed", targets.len());
            }
        }

        Ok(targets)
    }
}

// ── Internal loops ────────────────────────────────────────────────────────────

async fn receive_loop(
    mut socket_rx: watch::Receiver<Arc<UdpSocket>>,
    state: AppState,
    client_id: Uuid,
    send_tx: mpsc::Sender<Outgoing>,
    reliability: Arc<Mutex<ReliabilityManager>>,
) {
    let mut buf = vec![0u8; 65535];
    let mut socket = socket_rx.borrow_and_update().clone();
    loop {
        tokio::select! {
            // `recv_from` is cancel-safe, so dropping it when the socket changes
            // loses no data (nothing was received on the cancelled branch).
            res = socket.recv_from(&mut buf) => match res {
                Ok((len, peer_addr)) => {
                    debug!("OSC packet from {} ({} bytes)", peer_addr, len);
                    match decode_packet(&buf[..len]) {
                        Ok(event) => {
                            let outgoing = crate::protocol::handle(
                                event, peer_addr, &state, client_id, &reliability,
                            )
                            .await;
                            for item in outgoing {
                                let _ = send_tx.send(item).await;
                            }
                        }
                        Err(e) => warn!("Decode error from {}: {}", peer_addr, e),
                    }
                }
                Err(e) => {
                    if e.kind() == std::io::ErrorKind::PermissionDenied {
                        state
                            .publish(crate::state::AppEvent::PermissionDenied {
                                context: "OSC socket blocked — check Local Network permission"
                                    .into(),
                            })
                            .await;
                    }
                    error!("UDP receive error: {}", e);
                }
            },
            // A live OSC-port rebind published a new socket — switch to it. The
            // old `Arc` is dropped here, freeing the old port once no send holds it.
            changed = socket_rx.changed() => {
                if changed.is_err() {
                    break; // transport dropped — stop the loop
                }
                socket = socket_rx.borrow_and_update().clone();
                debug!("Receive loop switched to rebound socket");
            }
        }
    }
}

async fn send_loop(socket_rx: watch::Receiver<Arc<UdpSocket>>, mut rx: mpsc::Receiver<Outgoing>) {
    while let Some(item) = rx.recv().await {
        // Read the current socket per item so sends follow a live rebind.
        let socket = socket_rx.borrow().clone();
        match item {
            Outgoing::To(bytes, addr) => {
                if let Err(e) = socket.send_to(&bytes, addr).await {
                    // A unicast send can fail when a peer has just left the
                    // network — recoverable, so warn rather than error.
                    warn!("UDP send error to {}: {}", addr, e);
                }
            }
            Outgoing::Broadcast(bytes, addr) => {
                if let Err(e) = socket.send_to(&bytes, addr).await {
                    // Best-effort discovery; failures (e.g. iOS with no broadcast
                    // route for 255.255.255.255) are expected and non-fatal.
                    debug!("Broadcast to {} failed (best-effort): {}", addr, e);
                }
            }
            #[cfg(target_os = "macos")]
            Outgoing::PerIfaceBroadcast(bytes, port, iface) => {
                send_per_interface_broadcast(&socket, &bytes, port, iface.as_deref()).await;
            }
        }
    }
}

/// macOS: send `255.255.255.255:port` out of each usable interface by setting
/// `IP_BOUND_IF` on the (single, shared) send socket immediately before each
/// send and clearing it right after, so the receive loop's interface scope is
/// only constrained for the microsecond of the send. Running inside `send_loop`
/// guarantees no concurrent unicast send observes the bound state.
#[cfg(target_os = "macos")]
async fn send_per_interface_broadcast(
    socket: &UdpSocket,
    bytes: &[u8],
    port: u16,
    iface_pin: Option<&str>,
) {
    use std::os::fd::AsRawFd;
    let fd = socket.as_raw_fd();
    let dest = SocketAddr::from((std::net::Ipv4Addr::BROADCAST, port));
    for (name, idx) in usable_iface_indices(iface_pin) {
        if !set_bound_if(fd, idx) {
            warn!("IP_BOUND_IF failed for {} (idx {})", name, idx);
            continue;
        }
        let result = socket.send_to(bytes, dest).await;
        set_bound_if(fd, 0); // restore default routing / receive scope immediately
        match result {
            Ok(_) => debug!("per-iface broadcast → {} via {}", dest, name),
            Err(e) => debug!("per-iface broadcast via {} failed: {}", name, e),
        }
    }
}

/// Set (or clear, with `ifindex == 0`) the `IP_BOUND_IF` egress interface on a
/// raw socket fd. Returns true on success.
#[cfg(target_os = "macos")]
fn set_bound_if(fd: std::os::fd::RawFd, ifindex: u32) -> bool {
    let idx = ifindex as libc::c_uint;
    let rc = unsafe {
        libc::setsockopt(
            fd,
            libc::IPPROTO_IP,
            libc::IP_BOUND_IF,
            &idx as *const libc::c_uint as *const libc::c_void,
            std::mem::size_of::<libc::c_uint>() as libc::socklen_t,
        )
    };
    rc == 0
}

/// (name, ifindex) for each usable IPv4 interface, honouring an optional pin.
/// Reuses the same `SKIP_PREFIXES` / `is_usable_ip` filters as the UI picker.
#[cfg(target_os = "macos")]
fn usable_iface_indices(iface_pin: Option<&str>) -> Vec<(String, u32)> {
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    let Ok(interfaces) = NetworkInterface::show() else {
        return out;
    };
    for iface in &interfaces {
        if SKIP_PREFIXES.iter().any(|p| iface.name.starts_with(p)) {
            continue;
        }
        if iface_pin.is_some_and(|pin| iface.name != pin) {
            continue;
        }
        let has_v4 = iface
            .addr
            .iter()
            .any(|a| a.ip().is_ipv4() && is_usable_ip(&a.ip().to_string()));
        if !has_v4 || !seen.insert(iface.name.clone()) {
            continue;
        }
        if let Ok(cname) = std::ffi::CString::new(iface.name.clone()) {
            let idx = unsafe { libc::if_nametoindex(cname.as_ptr()) };
            if idx != 0 {
                out.push((iface.name.clone(), idx));
            }
        }
    }
    out
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/// The OSC socket always binds `0.0.0.0`, so it receives on **every** interface
/// (including `255.255.255.255` broadcasts — a socket bound to a specific NIC IP
/// can't). The `network_interface` setting is applied at *send* time instead:
/// `broadcast_targets` scopes the discovery beacon to the chosen NIC. So changing
/// the NIC takes effect live (next heartbeat) with no rebind/restart.
fn bind_address(config: &Config) -> String {
    format!("0.0.0.0:{}", config.osc_port)
}

/// Bind a UDP socket on `bind_addr` with broadcast enabled, returning a shared
/// handle. Shared by initial bind and live rebind.
async fn bind_socket(bind_addr: &str) -> Result<Arc<UdpSocket>> {
    let socket = UdpSocket::bind(bind_addr)
        .await
        .with_context(|| format!("Failed to bind UDP socket on {}", bind_addr))?;
    socket
        .set_broadcast(true)
        .context("Failed to enable UDP broadcast")?;
    tracing::info!("UDP socket bound on {}", bind_addr);
    Ok(Arc::new(socket))
}

// Name prefixes of macOS/Linux virtual or system interfaces that are never
// useful for OSC binding and should be hidden from the UI selector.
const SKIP_PREFIXES: &[&str] = &[
    "utun", "awdl", "llw", "stf", "gif", "p2p", "XHC", "anpi", "bridge", "vmnet", "veth", "docker",
];

/// Returns true for IPs that are usable as OSC bind addresses.
/// Rejects loopback, link-local IPv6 (fe80::...), and the IPv6 loopback (::1).
/// Deliberately does **not** reject IPv4 link-local (169.254.x.x) — Dante and
/// similar AV networks use that range intentionally, and this app needs to
/// run on them.
fn is_usable_ip(s: &str) -> bool {
    !s.starts_with("127.") && s != "::1" && !s.to_lowercase().starts_with("fe80")
}

/// The pinned interface's own IPv4 address and netmask, if it has one.
///
/// Used to filter mDNS-resolved peer addresses down to the same network as
/// our configured NIC. mDNS multicasts over every active interface, so a
/// resolved service can carry an address per interface a peer has up (e.g.
/// both a wired/Dante 169.254.x.x address and an unrelated Wi-Fi address) —
/// without this, whichever the `mdns-sd` crate happens to return first wins,
/// silently overriding the correct address the OSC presence beacon already
/// learned (which *does* respect the pin).
pub(crate) fn pinned_ipv4_subnet(iface_pin: &str) -> Option<(Ipv4Addr, Ipv4Addr)> {
    let interfaces = NetworkInterface::show().ok()?;
    let iface = interfaces.into_iter().find(|i| i.name == iface_pin)?;
    iface.addr.into_iter().find_map(|a| match a {
        Addr::V4(v4) if is_usable_ip(&IpAddr::V4(v4.ip).to_string()) => {
            v4.netmask.map(|mask| (v4.ip, mask))
        }
        _ => None,
    })
}

/// True if `ip` is in the same IPv4 subnet as the pinned interface's address.
pub(crate) fn in_pinned_subnet(ip: Ipv4Addr, iface_ip: Ipv4Addr, mask: Ipv4Addr) -> bool {
    u32::from(ip) & u32::from(mask) == u32::from(iface_ip) & u32::from(mask)
}

/// Broadcast targets for the presence/discovery beacon.
///
/// **Always includes `255.255.255.255`** (limited broadcast) — that's the one
/// address macOS reliably delivers to apps, and it's what discovery relies on.
/// Subnet-directed broadcasts (e.g. `192.168.1.255`) for each usable IPv4 NIC
/// are added on top: on Linux/Windows they let the routing table push a copy
/// out every interface (useful with a VPN/Ethernet alongside Wi-Fi); macOS
/// ignores directed broadcasts, so there the `255.255.255.255` copy is what
/// counts. `iface_pin` limits the subnet copies to one interface.
fn broadcast_targets(iface_pin: Option<&str>, port: u16) -> Vec<SocketAddr> {
    let mut out: Vec<SocketAddr> = Vec::new();
    let mut seen: HashSet<SocketAddr> = HashSet::new();

    // Limited broadcast — always sent.
    if let Ok(sa) = format!("255.255.255.255:{}", port).parse::<SocketAddr>() {
        seen.insert(sa);
        out.push(sa);
    }

    // Plus each usable interface's subnet-directed broadcast.
    if let Ok(interfaces) = NetworkInterface::show() {
        for iface in &interfaces {
            if SKIP_PREFIXES.iter().any(|p| iface.name.starts_with(p)) {
                continue;
            }
            if iface_pin.is_some_and(|pin| iface.name != pin) {
                continue;
            }
            for a in &iface.addr {
                let ip = a.ip();
                if !ip.is_ipv4() || !is_usable_ip(&ip.to_string()) {
                    continue;
                }
                if let Some(bcast) = a.broadcast() {
                    let sa = SocketAddr::new(bcast, port);
                    if seen.insert(sa) {
                        out.push(sa);
                    }
                }
            }
        }
    }

    out
}

/// Returns a list of available network interfaces for the UI selector.
/// Filters out virtual/system interfaces and link-local addresses.
/// Prefers IPv4 over IPv6 when an interface has both.
pub fn list_interfaces() -> Result<Vec<InterfaceInfo>> {
    let interfaces = NetworkInterface::show().context("Failed to enumerate network interfaces")?;
    let mut result = Vec::new();

    for iface in &interfaces {
        // Skip virtual/system interface name prefixes.
        if SKIP_PREFIXES.iter().any(|p| iface.name.starts_with(p)) {
            continue;
        }

        // Collect all usable IPs for this interface.
        let addrs: Vec<String> = iface
            .addr
            .iter()
            .map(|a| a.ip().to_string())
            .filter(|s| is_usable_ip(s))
            .collect();

        // Prefer IPv4 (contains '.'); fall back to first IPv6 if no IPv4.
        let ip = addrs
            .iter()
            .find(|s| s.contains('.'))
            .or_else(|| addrs.first())
            .cloned();

        if let Some(ip) = ip {
            result.push(InterfaceInfo {
                name: iface.name.clone(),
                ip,
            });
        }
    }

    Ok(result)
}

#[derive(Debug, serde::Serialize, serde::Deserialize)]
pub struct InterfaceInfo {
    pub name: String,
    pub ip: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn broadcast_targets_non_empty_ipv4_on_port() {
        let targets = broadcast_targets(None, 9000);
        assert!(!targets.is_empty()); // real subnets, or the 255.255.255.255 fallback
        assert!(targets.iter().all(|a| a.port() == 9000));
        assert!(targets.iter().all(|a| a.ip().is_ipv4()));
    }

    #[test]
    fn broadcast_targets_always_include_limited_broadcast() {
        // Limited broadcast is always present; pinning to an unknown interface
        // adds no subnet copies, leaving just 255.255.255.255.
        let targets = broadcast_targets(Some("definitely-not-a-real-iface-xyz"), 5000);
        assert_eq!(targets, vec!["255.255.255.255:5000".parse().unwrap()]);
        // And it's present even with no pin.
        assert!(broadcast_targets(None, 9000).contains(&"255.255.255.255:9000".parse().unwrap()));
    }

    /// Diagnostic: prints the broadcast targets this machine would use.
    /// Run with: `cargo test -p patch_core print_broadcast_targets -- --ignored --nocapture`
    #[test]
    #[ignore = "diagnostic only"]
    fn print_broadcast_targets() {
        for t in broadcast_targets(None, 9000) {
            eprintln!("broadcast target: {t}");
        }
    }

    /// The per-interface egress list must contain only real (non-zero) interface
    /// indices, and pinning to a non-existent interface yields nothing.
    #[cfg(target_os = "macos")]
    #[test]
    fn usable_iface_indices_are_nonzero_and_pinnable() {
        let all = usable_iface_indices(None);
        assert!(all.iter().all(|(name, idx)| *idx != 0 && !name.is_empty()));
        assert!(usable_iface_indices(Some("definitely-not-a-real-iface-xyz")).is_empty());
    }

    /// Diagnostic: prints the (interface, ifindex) pairs the per-interface macOS
    /// broadcast would send `255.255.255.255` out of.
    /// `cargo test -p patch_core print_iface_indices -- --ignored --nocapture`
    #[cfg(target_os = "macos")]
    #[test]
    #[ignore = "diagnostic only"]
    fn print_iface_indices() {
        for (name, idx) in usable_iface_indices(None) {
            eprintln!("per-iface broadcast egress: {name} (ifindex {idx})");
        }
    }

    /// The live OSC-port rebind moves the socket **and** the receive loop follows
    /// it: after rebinding to a fresh port, a packet sent to the new port is
    /// processed (registering the sender as a peer). Guards the watch-based
    /// hot-swap that makes the in-app OSC-port setting take effect without a
    /// restart.
    #[tokio::test]
    async fn rebind_moves_socket_and_receive_loop_to_new_port() {
        use crate::osc::codec::encode_presence;
        use crate::reliability::ReliabilityManager;
        use std::time::Duration;

        // Port 0 → the OS assigns a free port (no flaky hard-coded ports).
        let config = Config {
            osc_port: 0,
            ..Config::default()
        };
        let state = AppState::new(config.clone());
        let reliability = Arc::new(Mutex::new(ReliabilityManager::new()));
        let transport = Transport::new(&config, state.clone(), reliability)
            .await
            .unwrap();

        let port_a = transport.bound_port();
        assert_ne!(port_a, 0, "initial bind should have a real port");

        // Rebind to another OS-assigned port.
        transport.rebind(&config).await.unwrap();
        let port_b = transport.bound_port();
        assert_ne!(port_b, 0);
        assert_ne!(port_a, port_b, "rebind should move to a different port");

        // Send a presence packet to the NEW port; the receive loop must process
        // it (registering the sender), proving it switched sockets.
        let sender = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let presence = PeerPresence {
            peer_id: Uuid::new_v4(), // distinct from our client_id → not self-filtered
            peer_name: "rebind-tester".to_string(),
            channels: Vec::new(),
            role: None,
            timestamp: chrono::Utc::now(),
        };
        let bytes = encode_presence(&presence).unwrap();
        // Let the receive loop observe the watch change before we send.
        tokio::time::sleep(Duration::from_millis(50)).await;
        sender.send_to(&bytes, ("127.0.0.1", port_b)).await.unwrap();

        let mut registered = false;
        for _ in 0..40 {
            tokio::time::sleep(Duration::from_millis(25)).await;
            if !state.get_peers().await.is_empty() {
                registered = true;
                break;
            }
        }
        assert!(
            registered,
            "receive loop did not process a packet on the rebound port"
        );
    }
}
