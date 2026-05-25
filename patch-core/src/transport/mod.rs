//! UDP transport layer — OSC send/receive with network interface binding.

use anyhow::{Context, Result};
use network_interface::{NetworkInterface, NetworkInterfaceConfig};
use std::net::SocketAddr;
use std::sync::Arc;
use tokio::net::UdpSocket;
use tokio::sync::mpsc;
use tracing::{debug, error, warn};
use uuid::Uuid;

use crate::osc::codec::{decode_packet, PatchEvent};
use crate::state::{AppEvent, AppState, Config};

pub struct Transport {
    socket: Arc<UdpSocket>,
    /// Sender half — clone to send packets from any task.
    send_tx: mpsc::Sender<(Vec<u8>, SocketAddr)>,
}

impl Transport {
    pub async fn new(config: &Config, state: AppState) -> Result<Self> {
        let bind_addr = bind_address(config)?;
        let socket = UdpSocket::bind(&bind_addr)
            .await
            .with_context(|| format!("Failed to bind UDP socket on {}", bind_addr))?;

        socket.set_broadcast(true).context("Failed to enable UDP broadcast")?;
        tracing::info!("UDP socket bound on {}", bind_addr);

        let socket = Arc::new(socket);
        let (send_tx, send_rx) = mpsc::channel::<(Vec<u8>, SocketAddr)>(256);

        // Receive loop
        let rx_socket = socket.clone();
        let rx_state = state.clone();
        tokio::spawn(async move {
            receive_loop(rx_socket, rx_state).await;
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
        self.send_tx.send((bytes, addr)).await.context("Send channel closed")
    }

    /// Broadcast raw OSC bytes on the LAN (255.255.255.255).
    /// Used only for presence heartbeats and discovery beacons.
    pub async fn broadcast(&self, bytes: Vec<u8>, port: u16) -> Result<()> {
        let addr: SocketAddr = format!("255.255.255.255:{}", port).parse()?;
        self.send_to(bytes, addr).await
    }

    /// Unicast raw OSC bytes to every known peer in the registry,
    /// plus any static peers defined in config.
    ///
    /// Skips ourselves (by client_id) and peers without a resolved address.
    /// If no peers are known yet, the packet is silently dropped — no broadcast fallback.
    pub async fn send_to_peers(
        &self,
        bytes: Vec<u8>,
        state: &AppState,
        config: &Config,
    ) -> Result<()> {
        let peers = state.get_peers().await;
        let mut sent = 0usize;

        for peer in &peers {
            // Skip ourselves
            if peer.peer_id == config.client_id {
                continue;
            }
            if !peer.has_address() {
                debug!("Skipping peer {} — no address yet", peer.peer_name);
                continue;
            }
            let addr: SocketAddr = match format!("{}:{}", peer.address, peer.osc_port).parse() {
                Ok(a) => a,
                Err(e) => {
                    warn!("Invalid peer address for {}: {}", peer.peer_name, e);
                    continue;
                }
            };
            if let Err(e) = self.send_to(bytes.clone(), addr).await {
                warn!("Send to peer {} failed: {}", peer.peer_name, e);
            } else {
                debug!("Unicast → {} ({})", peer.peer_name, addr);
                sent += 1;
            }
        }

        // Also send to manually-configured static peers
        for static_peer in &config.static_peers {
            let addr: SocketAddr =
                match format!("{}:{}", static_peer.address, static_peer.port).parse() {
                    Ok(a) => a,
                    Err(e) => {
                        warn!("Invalid static peer address: {}", e);
                        continue;
                    }
                };
            if let Err(e) = self.send_to(bytes.clone(), addr).await {
                warn!("Send to static peer {:?} failed: {}", static_peer.label, e);
            } else {
                debug!("Unicast → static {:?} ({})", static_peer.label, addr);
                sent += 1;
            }
        }

        if sent == 0 && peers.is_empty() && config.static_peers.is_empty() {
            debug!("No peers known yet — packet not sent");
        }

        Ok(())
    }
}

// ── Internal loops ────────────────────────────────────────────────────────────

async fn receive_loop(socket: Arc<UdpSocket>, state: AppState) {
    let mut buf = vec![0u8; 65535];
    loop {
        match socket.recv_from(&mut buf).await {
            Ok((len, peer_addr)) => {
                debug!("OSC packet from {} ({} bytes)", peer_addr, len);
                match decode_packet(&buf[..len]) {
                    Ok(event) => handle_event(event, peer_addr, &state).await,
                    Err(e) => warn!("Decode error from {}: {}", peer_addr, e),
                }
            }
            Err(e) => {
                error!("UDP receive error: {}", e);
            }
        }
    }
}

async fn handle_event(event: PatchEvent, from: SocketAddr, state: &AppState) {
    // For every event that carries a sender_id, record the source address so
    // we can unicast back to that peer later.
    let sender_id: Option<Uuid> = match &event {
        PatchEvent::Message(m)    => Some(m.sender_id),
        PatchEvent::Presence(p)   => Some(p.peer_id),
        PatchEvent::Flash(f)      => Some(f.sender_id),
        PatchEvent::Heartbeat { peer_id } => Some(*peer_id),
        PatchEvent::Discovery { peer_id, .. } => Some(*peer_id),
        _ => None,
    };
    if let Some(id) = sender_id {
        state.touch_peer_address(id, from.ip().to_string(), from.port()).await;
    }

    match event {
        PatchEvent::Message(msg) => {
            state.store_message(msg).await;
        }
        PatchEvent::Ack { message_id, peer_id } => {
            state.publish(AppEvent::MessageAcked { message_id, peer_id }).await;
        }
        PatchEvent::Presence(p) => {
            state.upsert_peer(p).await;
        }
        PatchEvent::Flash(f) => {
            state.publish(AppEvent::ChannelFlash(f)).await;
        }
        PatchEvent::Heartbeat { peer_id } => {
            debug!("Heartbeat from {}", peer_id);
        }
        PatchEvent::Discovery { peer_id, peer_name, osc_port } => {
            debug!("Discovery: {} ({}) on port {}", peer_name, peer_id, osc_port);
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
            let interfaces = NetworkInterface::show().context("Failed to enumerate network interfaces")?;
            let iface = interfaces
                .iter()
                .find(|i| i.name == *iface_name)
                .with_context(|| format!("Network interface '{}' not found", iface_name))?;

            let addr = iface
                .addr
                .first()
                .with_context(|| format!("Interface '{}' has no addresses", iface_name))?;

            Ok(format!("{}:{}", addr.ip(), config.osc_port))
        }
    }
}

/// Returns a list of available network interfaces for the UI selector.
pub fn list_interfaces() -> Result<Vec<InterfaceInfo>> {
    let interfaces = NetworkInterface::show().context("Failed to enumerate network interfaces")?;
    Ok(interfaces
        .iter()
        .filter_map(|i| {
            let ip = i.addr.first().map(|a| a.ip().to_string())?;
            Some(InterfaceInfo {
                name: i.name.clone(),
                ip,
            })
        })
        .collect())
}

#[derive(Debug, serde::Serialize, serde::Deserialize)]
pub struct InterfaceInfo {
    pub name: String,
    pub ip: String,
}
