//! Hybrid peer discovery:
//!   1. mDNS / Bonjour  — `_patch._udp.local.`
//!   2. OSC broadcast beacon — `/patch/discovery`
//!   3. Static IP fallback — seeded from config, no active probing needed here

use anyhow::Result;
use chrono::Utc;
use mdns_sd::{ServiceDaemon, ServiceEvent, ServiceInfo};
use std::collections::HashMap;
use std::sync::Arc;
use tracing::{debug, info, warn};
use uuid::Uuid;

use crate::osc::{codec::encode_presence, types::PeerPresence};
use crate::state::{AppState, Config};
use crate::transport::Transport;

pub struct Discovery;

impl Discovery {
    pub async fn new(config: &Config, state: AppState, transport: Arc<Transport>) -> Result<Self> {
        let client_id = config.client_id;
        let client_name = config.client_name.clone();
        let osc_port = config.osc_port;
        let heartbeat_secs = config.heartbeat_interval_secs;
        let peer_timeout = config.peer_timeout_secs;

        // ── mDNS ──────────────────────────────────────────────────────────────
        let mdns = ServiceDaemon::new().expect("Failed to create mDNS daemon");

        // Register ourselves
        let service_type = "_patch._udp.local.";
        let instance_name = &client_name;
        let host_name = format!("{}.local.", gethostname());
        let mut props = HashMap::new();
        props.insert("peer_id".to_string(), client_id.to_string());
        props.insert("peer_name".to_string(), client_name.clone());
        props.insert("version".to_string(), "0.1.0".to_string());

        let service = ServiceInfo::new(
            service_type,
            instance_name,
            &host_name,
            "",
            osc_port,
            props,
        )
        .expect("Invalid mDNS service info");

        mdns.register(service).expect("Failed to register mDNS service");
        info!("mDNS service registered as '{}'", instance_name);

        // Browse for peers
        let browse_state = state.clone();
        let receiver = mdns.browse(service_type).expect("Failed to browse mDNS");
        tokio::spawn(async move {
            while let Ok(event) = receiver.recv_async().await {
                match event {
                    ServiceEvent::ServiceResolved(info) => {
                        let peer_id = info.get_properties()
                            .get("peer_id")
                            .and_then(|p| Uuid::parse_str(p.val_str()).ok())
                            .unwrap_or_else(Uuid::new_v4);

                        // Skip our own service — mDNS resolves it too.
                        if peer_id == client_id {
                            continue;
                        }

                        let addr = info.get_addresses().iter().next()
                            .map(|a| a.to_string())
                            .unwrap_or_default();
                        let port = info.get_port();

                        // Prefer the peer_name TXT record; fall back to stripping
                        // the service-type suffix from the full DNS name.
                        let peer_name = info.get_properties()
                            .get("peer_name")
                            .map(|p| p.val_str().to_string())
                            .unwrap_or_else(|| {
                                info.get_fullname()
                                    .split("._patch._udp")
                                    .next()
                                    .unwrap_or(info.get_fullname())
                                    .to_string()
                            });

                        debug!("mDNS resolved: {} ({}) @ {}:{}", peer_name, peer_id, addr, port);
                        let presence = PeerPresence {
                            peer_id,
                            peer_name,
                            channels: Vec::new(),
                            timestamp: Utc::now(),
                        };
                        browse_state.upsert_peer(presence).await;
                        // Wire the resolved IP+port into the peer record so
                        // unicast sends work immediately after mDNS discovery.
                        if !addr.is_empty() {
                            browse_state.touch_peer_address(peer_id, addr, port).await;
                        }
                    }
                    ServiceEvent::ServiceRemoved(_, fullname) => {
                        debug!("mDNS removed: {}", fullname);
                    }
                    _ => {}
                }
            }
        });

        // ── Heartbeat + beacon task ───────────────────────────────────────────
        let hb_state = state.clone();
        let hb_transport = transport.clone();
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(
                std::time::Duration::from_secs(heartbeat_secs),
            );
            loop {
                interval.tick().await;
                // Broadcast our presence so every peer on the LAN can discover us.
                let channels = hb_state
                    .get_channels()
                    .await
                    .iter()
                    .map(|c| c.id.clone())
                    .collect();
                // Re-read the name on every tick so renames propagate to peers
                // within one heartbeat interval without requiring a restart.
                let current_name = hb_state.config().await.client_name.clone();
                let presence = PeerPresence {
                    peer_id: client_id,
                    peer_name: current_name,
                    channels,
                    timestamp: Utc::now(),
                };
                match encode_presence(&presence) {
                    Ok(bytes) => {
                        debug!("Heartbeat — broadcasting presence on port {}", osc_port);
                        if let Err(e) = hb_transport.broadcast(bytes, osc_port).await {
                            warn!("Presence broadcast failed: {}", e);
                        }
                    }
                    Err(e) => warn!("Failed to encode presence: {}", e),
                }

                // Expire stale peers
                let peers = hb_state.get_peers().await;
                for peer in peers {
                    if peer.peer_id != client_id && peer.is_stale(peer_timeout) {
                        info!("Expiring stale peer: {} ({})", peer.peer_name, peer.peer_id);
                        hb_state.expire_peer(peer.peer_id).await;
                    }
                }
            }
        });

        Ok(Self)
    }
}

fn gethostname() -> String {
    std::env::var("HOSTNAME")
        .or_else(|_| {
            std::process::Command::new("hostname")
                .output()
                .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
                .map_err(|_| std::env::VarError::NotPresent)
        })
        .unwrap_or_else(|_| "patch-node".to_string())
}
