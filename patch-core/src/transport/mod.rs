//! UDP transport layer — OSC send/receive with network interface binding.

use anyhow::{Context, Result};
use network_interface::{NetworkInterface, NetworkInterfaceConfig};
use std::collections::HashSet;
use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;
use tokio::net::UdpSocket;
use tokio::sync::{mpsc, Mutex};
use tracing::{debug, error, warn};
use uuid::Uuid;

use crate::osc::codec::{decode_packet, encode_ack, PatchEvent};
use crate::osc::types::PeerPresence;
use crate::reliability::ReliabilityManager;
use crate::state::{AppEvent, AppState, Config};
use chrono::Utc;

/// A queued outgoing packet, processed by the single `send_loop` task. Routing
/// everything through one task means the per-interface broadcast can set/clear
/// the socket's `IP_BOUND_IF` option without racing concurrent unicast sends.
enum Outgoing {
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
    /// Kept alive so the socket isn't dropped while the send/receive loops run.
    #[allow(dead_code)]
    socket: Arc<UdpSocket>,
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
        let socket = UdpSocket::bind(&bind_addr)
            .await
            .with_context(|| format!("Failed to bind UDP socket on {}", bind_addr))?;

        socket
            .set_broadcast(true)
            .context("Failed to enable UDP broadcast")?;
        tracing::info!("UDP socket bound on {}", bind_addr);

        let socket = Arc::new(socket);
        let (send_tx, send_rx) = mpsc::channel::<Outgoing>(256);

        // Receive loop. It also needs the send half (to emit ACKs for critical
        // messages) and the reliability manager (to clear acked retransmits).
        let rx_socket = socket.clone();
        let rx_state = state.clone();
        let rx_send_tx = send_tx.clone();
        let rx_reliability = Arc::clone(&reliability);
        let client_id = config.client_id;
        tokio::spawn(async move {
            receive_loop(rx_socket, rx_state, client_id, rx_send_tx, rx_reliability).await;
        });

        // Send loop
        let tx_socket = socket.clone();
        tokio::spawn(async move {
            send_loop(tx_socket, send_rx).await;
        });

        Ok(Self { socket, send_tx })
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
        self.socket
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
    /// `state.get_peers()` already merges the configured static peers in as
    /// synthetic `ManualIp` entries, so a single pass covers both dynamic and
    /// static targets. We dedup by resolved `SocketAddr` so a static peer that
    /// has also been discovered dynamically isn't contacted twice (which would
    /// double-fire flashes, since flashes carry no dedup id).
    ///
    /// Skips ourselves (by client_id) and peers without a resolved address.
    /// Returns the addresses actually contacted (used for ACK tracking). If no
    /// peers are known yet, the packet is silently dropped — no broadcast fallback.
    pub async fn send_to_peers(
        &self,
        bytes: Vec<u8>,
        state: &AppState,
        config: &Config,
    ) -> Result<Vec<SocketAddr>> {
        let peers = state.get_peers().await;
        let mut targets: Vec<SocketAddr> = Vec::new();
        let mut seen: HashSet<SocketAddr> = HashSet::new();

        for peer in &peers {
            if peer.peer_id == config.client_id {
                continue; // skip ourselves
            }
            if !peer.has_address() {
                debug!("Skipping peer {} — no address yet", peer.peer_name);
                continue;
            }
            // Parse the IP first so IPv6 addresses get correct `[..]:port` form.
            let ip: IpAddr = match peer.address.parse() {
                Ok(ip) => ip,
                Err(e) => {
                    warn!("Invalid peer address for {}: {}", peer.peer_name, e);
                    continue;
                }
            };
            let addr = SocketAddr::new(ip, peer.osc_port);
            if seen.insert(addr) {
                targets.push(addr);
            }
        }

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
    socket: Arc<UdpSocket>,
    state: AppState,
    client_id: Uuid,
    send_tx: mpsc::Sender<Outgoing>,
    reliability: Arc<Mutex<ReliabilityManager>>,
) {
    let mut buf = vec![0u8; 65535];
    loop {
        match socket.recv_from(&mut buf).await {
            Ok((len, peer_addr)) => {
                debug!("OSC packet from {} ({} bytes)", peer_addr, len);
                match decode_packet(&buf[..len]) {
                    Ok(event) => {
                        handle_event(event, peer_addr, &state, client_id, &send_tx, &reliability)
                            .await
                    }
                    Err(e) => warn!("Decode error from {}: {}", peer_addr, e),
                }
            }
            Err(e) => {
                if e.kind() == std::io::ErrorKind::PermissionDenied {
                    state
                        .publish(crate::state::AppEvent::PermissionDenied {
                            context: "OSC socket blocked — check Local Network permission".into(),
                        })
                        .await;
                }
                error!("UDP receive error: {}", e);
            }
        }
    }
}

async fn handle_event(
    event: PatchEvent,
    from: SocketAddr,
    state: &AppState,
    client_id: Uuid,
    send_tx: &mpsc::Sender<Outgoing>,
    reliability: &Arc<Mutex<ReliabilityManager>>,
) {
    // For every event that carries a sender_id, record the source address so
    // we can unicast back to that peer later.  Skip our own packets — the Mac
    // receives its own broadcast, and we don't want to add ourselves as a peer.
    let sender_id: Option<Uuid> = match &event {
        PatchEvent::Message(m) => Some(m.sender_id),
        PatchEvent::Presence(p) => Some(p.peer_id),
        PatchEvent::Flash(f) => Some(f.sender_id),
        _ => None,
    };
    if let Some(id) = sender_id {
        if id != client_id {
            state
                .touch_peer_address(id, from.ip().to_string(), from.port())
                .await;
        }
    }

    match event {
        PatchEvent::Message(msg) => {
            // Auto-register the sender so they appear in the peers panel
            // immediately, even when AP isolation blocks their broadcast heartbeats.
            if !state.has_peer(msg.sender_id).await {
                let presence = PeerPresence {
                    peer_id: msg.sender_id,
                    peer_name: msg.sender_name.clone(),
                    channels: Vec::new(),
                    timestamp: Utc::now(),
                };
                state.upsert_peer(presence).await;
                // touch_peer_address was a no-op above (no entry yet); now it works.
                state
                    .touch_peer_address(msg.sender_id, from.ip().to_string(), from.port())
                    .await;
            }
            // ACK critical messages so the sender can stop retransmitting.
            if msg.is_critical() {
                match encode_ack(msg.message_id, client_id) {
                    Ok(ack_bytes) => {
                        let _ = send_tx.send(Outgoing::To(ack_bytes, from)).await;
                    }
                    Err(e) => warn!("Failed to encode ACK: {}", e),
                }
            }
            state.store_message(msg).await;
        }
        PatchEvent::Ack {
            message_id,
            peer_id,
        } => {
            // Record the ACK (matched by the ACK's source address — see
            // reliability::ReliabilityManager::ack). On a tracked target this
            // returns delivery progress, which we surface so the sender's UI can
            // show "delivered N/M" and a check once every peer has it.
            let progress = reliability.lock().await.ack(message_id, from);
            if let Some((delivered, total)) = progress {
                state
                    .publish(AppEvent::MessageDelivery {
                        message_id,
                        delivered,
                        total,
                        failed: false,
                        failed_peers: Vec::new(),
                    })
                    .await;
            }
            state
                .publish(AppEvent::MessageAcked {
                    message_id,
                    peer_id,
                })
                .await;
        }
        PatchEvent::Presence(p) => {
            // Ignore our own presence broadcast — we receive it on the same socket.
            if p.peer_id == client_id {
                return;
            }
            let peer_id = p.peer_id;
            state.upsert_peer(p).await;
            // touch_peer_address at the top of this fn was a no-op (no entry yet);
            // resolve the address now so the first unicast back isn't delayed a
            // full heartbeat interval.
            state
                .touch_peer_address(peer_id, from.ip().to_string(), from.port())
                .await;
        }
        PatchEvent::Bye { peer_id } => {
            // Graceful departure — mark the peer offline (grey) immediately
            // instead of waiting out the heartbeat timeout, but keep it in the
            // list so the operator still sees who was connected.
            if peer_id != client_id {
                tracing::info!("Received /patch/bye from {} — marking offline", peer_id);
                state.mark_peer_offline(peer_id).await;
            }
        }
        PatchEvent::Flash(f) => {
            // Same auto-register logic as for Message.
            if !state.has_peer(f.sender_id).await {
                let presence = PeerPresence {
                    peer_id: f.sender_id,
                    peer_name: f.sender_name.clone(),
                    channels: Vec::new(),
                    timestamp: Utc::now(),
                };
                state.upsert_peer(presence).await;
                state
                    .touch_peer_address(f.sender_id, from.ip().to_string(), from.port())
                    .await;
            }
            state.publish(AppEvent::ChannelFlash(f)).await;
        }
        PatchEvent::Unknown(msg) => {
            debug!("Unknown OSC: {}", msg.addr);
        }
    }
}

async fn send_loop(socket: Arc<UdpSocket>, mut rx: mpsc::Receiver<Outgoing>) {
    while let Some(item) = rx.recv().await {
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

// Name prefixes of macOS/Linux virtual or system interfaces that are never
// useful for OSC binding and should be hidden from the UI selector.
const SKIP_PREFIXES: &[&str] = &[
    "utun", "awdl", "llw", "stf", "gif", "p2p", "XHC", "anpi", "bridge", "vmnet", "veth", "docker",
];

/// Returns true for IPs that are usable as OSC bind addresses.
/// Rejects loopback, link-local IPv6 (fe80::...), and the IPv6 loopback (::1).
fn is_usable_ip(s: &str) -> bool {
    !s.starts_with("127.") && s != "::1" && !s.to_lowercase().starts_with("fe80")
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
}
