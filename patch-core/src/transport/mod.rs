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

pub struct Transport {
    /// Kept alive so the socket isn't dropped while the send/receive loops run.
    #[allow(dead_code)]
    socket: Arc<UdpSocket>,
    /// Sender half — clone to send packets from any task.
    send_tx: mpsc::Sender<(Vec<u8>, SocketAddr)>,
}

impl Transport {
    pub async fn new(
        config: &Config,
        state: AppState,
        reliability: Arc<Mutex<ReliabilityManager>>,
    ) -> Result<Self> {
        let bind_addr = bind_address(config)?;
        let socket = UdpSocket::bind(&bind_addr)
            .await
            .with_context(|| format!("Failed to bind UDP socket on {}", bind_addr))?;

        socket
            .set_broadcast(true)
            .context("Failed to enable UDP broadcast")?;
        tracing::info!("UDP socket bound on {}", bind_addr);

        let socket = Arc::new(socket);
        let (send_tx, send_rx) = mpsc::channel::<(Vec<u8>, SocketAddr)>(256);

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
            .send((bytes, addr))
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

    /// Broadcast raw OSC bytes on the LAN (255.255.255.255).
    /// Used only for presence heartbeats and discovery beacons.
    pub async fn broadcast(&self, bytes: Vec<u8>, port: u16) -> Result<()> {
        let addr: SocketAddr = format!("255.255.255.255:{}", port).parse()?;
        self.send_to(bytes, addr).await
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
    send_tx: mpsc::Sender<(Vec<u8>, SocketAddr)>,
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
    send_tx: &mpsc::Sender<(Vec<u8>, SocketAddr)>,
    reliability: &Arc<Mutex<ReliabilityManager>>,
) {
    // For every event that carries a sender_id, record the source address so
    // we can unicast back to that peer later.  Skip our own packets — the Mac
    // receives its own broadcast, and we don't want to add ourselves as a peer.
    let sender_id: Option<Uuid> = match &event {
        PatchEvent::Message(m) => Some(m.sender_id),
        PatchEvent::Presence(p) => Some(p.peer_id),
        PatchEvent::Flash(f) => Some(f.sender_id),
        PatchEvent::Heartbeat { peer_id } => Some(*peer_id),
        PatchEvent::Discovery { peer_id, .. } => Some(*peer_id),
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
                        let _ = send_tx.send((ack_bytes, from)).await;
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
            // Clear the in-flight retransmit entry, then notify the UI.
            reliability.lock().await.ack(message_id, peer_id);
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
            // Graceful departure — drop the peer now instead of waiting out the
            // heartbeat timeout. expire_peer emits PeerExpired → the UI refreshes.
            if peer_id != client_id {
                state.expire_peer(peer_id).await;
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
        PatchEvent::Heartbeat { peer_id } => {
            debug!("Heartbeat from {}", peer_id);
        }
        PatchEvent::Discovery {
            peer_id,
            peer_name,
            osc_port,
        } => {
            debug!(
                "Discovery: {} ({}) on port {}",
                peer_name, peer_id, osc_port
            );
        }
        PatchEvent::Unknown(msg) => {
            debug!("Unknown OSC: {}", msg.addr);
        }
    }
}

async fn send_loop(socket: Arc<UdpSocket>, mut rx: mpsc::Receiver<(Vec<u8>, SocketAddr)>) {
    while let Some((bytes, addr)) = rx.recv().await {
        if let Err(e) = socket.send_to(&bytes, addr).await {
            error!("UDP send error to {}: {}", addr, e);
        }
    }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

fn bind_address(config: &Config) -> Result<String> {
    match &config.network_interface {
        None => Ok(format!("0.0.0.0:{}", config.osc_port)),
        Some(iface_name) => {
            let interfaces =
                NetworkInterface::show().context("Failed to enumerate network interfaces")?;
            let iface = interfaces
                .iter()
                .find(|i| i.name == *iface_name)
                .with_context(|| format!("Network interface '{}' not found", iface_name))?;

            // Prefer IPv4; skip loopback and link-local IPv6 (fe80::).
            let ip: IpAddr = iface
                .addr
                .iter()
                .map(|a| a.ip())
                .filter(|ip| is_usable_ip(&ip.to_string()))
                .find(|ip| ip.is_ipv4()) // IPv4 first
                .or_else(|| {
                    iface
                        .addr
                        .iter()
                        .map(|a| a.ip())
                        .find(|ip| is_usable_ip(&ip.to_string())) // any usable IPv6 fallback
                })
                .with_context(|| format!("Interface '{}' has no usable address", iface_name))?;

            // SocketAddr renders IPv6 with the required brackets (`[::1]:9000`).
            Ok(SocketAddr::new(ip, config.osc_port).to_string())
        }
    }
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
