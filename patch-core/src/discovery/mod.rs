//! Hybrid peer discovery:
//!   1. mDNS / Bonjour  — `_patch._udp.local.`
//!   2. OSC broadcast beacon — `/patch/discovery`
//!   3. Static IP fallback — seeded from config, no active probing needed here

use anyhow::Result;
use chrono::Utc;
use mdns_sd::{ServiceDaemon, ServiceEvent, ServiceInfo};
use std::collections::HashMap;
use tracing::{debug, error, info};
use uuid::Uuid;

use crate::osc::{codec::encode_presence, types::PeerPresence};
use crate::state::{AppState, Config};
use crate::transport::Transport;

pub struct Discovery;

impl Discovery {
    pub async fn new(config: &Config, state: AppState) -> Result<Self> {
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
                        let addr = info.get_addresses().iter().next()
                            .map(|a| a.to_string())
                            .unwrap_or_default();
                        let peer_id = info.get_properties()
                            .get("peer_id")
                            .and_then(|p| Uuid::parse_str(p.val_str()).ok())
                            .unwrap_or_else(Uuid::new_v4);

                        let port = info.get_port();
                        debug!("mDNS resolved: {} @ {}:{}", info.get_fullname(), addr, port);
                        let presence = PeerPresence {
                            peer_id,
                            peer_name: info.get_fullname().to_string(),
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
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(
                std::time::Duration::from_secs(heartbeat_secs),
            );
            loop {
                interval.tick().await;
                // Broadcast our presence
                let channels = hb_state
                    .get_channels()
                    .await
                    .iter()
                    .map(|c| c.id.clone())
                    .collect();
                let presence = PeerPresence {
                    peer_id: client_id,
                    peer_name: client_name.clone(),
                    channels,
                    timestamp: Utc::now(),
                };
                // Encode and fire — transport not wired here yet, will be
                // connected via AppEvent in a later pass
                debug!("Heartbeat tick — presence broadcast queued");
                let _ = encode_presence(&presence); // validates encoding

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
