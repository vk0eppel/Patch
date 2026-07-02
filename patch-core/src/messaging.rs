//! Core message origination logic shared across the FFI surface, protocol
//! relay, and macro dispatch. `api.rs` and `protocol.rs` delegate here so the
//! send pipeline is written once.

use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;

use anyhow::Result;
use tokio::sync::Mutex;
use tracing::warn;
use uuid::Uuid;

use crate::osc::codec::{encode_dm, encode_message, encode_osc};
use crate::osc::types::{PatchMessage, Priority};
use crate::reliability::ReliabilityManager;
use crate::state::channel::{self, OscTarget};
use crate::state::AppState;
use crate::transport::{Outgoing, Transport};

/// Encode, send to all reachable peers, track criticals, store locally.
/// Used by the FFI `send_message` path and MIDI/key-binding macro dispatch.
pub(crate) async fn dispatch_channel_message(
    state: &AppState,
    transport: &Arc<Transport>,
    reliability: &Arc<Mutex<ReliabilityManager>>,
    channel_id: String,
    payload: String,
    prio: Priority,
) -> Result<Uuid> {
    let config = state.config().await;
    let msg = PatchMessage::new(
        config.client_id,
        &config.client_name,
        channel_id,
        prio,
        payload,
    );
    let bytes = encode_message(&msg)?;
    let _targets = transport
        .send_to_peers(bytes.clone(), state, &config)
        .await?;
    let message_id = msg.message_id;
    let is_critical = msg.is_critical();
    let target_count = if is_critical {
        let peer_targets = state.reachable_peers_with_addrs(config.client_id).await;
        crate::reliability::track_critical(
            reliability,
            state,
            config.heartbeat_interval_secs,
            message_id,
            bytes,
            peer_targets,
        )
        .await
    } else {
        0
    };
    state.store_message(msg).await;
    if is_critical && target_count == 0 {
        crate::reliability::report_delivery_failure(state, message_id, 0, 0, &[]).await;
    }
    Ok(message_id)
}

/// Originate a message for relay to peers, returning the outbound packets
/// rather than sending directly. Used by the OSC injection path (`/patch/say`)
/// where `transport::receive_loop` owns the socket writes.
pub(crate) async fn originate_for_relay(
    channel_id: String,
    payload: String,
    priority: Priority,
    state: &AppState,
    reliability: &Arc<Mutex<ReliabilityManager>>,
) -> Vec<Outgoing> {
    let mut out = Vec::new();
    let config = state.config().await;
    let msg = PatchMessage::new(
        config.client_id,
        &config.client_name,
        channel_id,
        priority,
        payload,
    );
    match encode_message(&msg) {
        Ok(bytes) => {
            let targets = state.reachable_peer_addrs(config.client_id).await;
            for addr in &targets {
                out.push(Outgoing::To(bytes.clone(), *addr));
            }
            if msg.is_critical() {
                let peer_targets = state.reachable_peers_with_addrs(config.client_id).await;
                let tracked = crate::reliability::track_critical(
                    reliability,
                    state,
                    config.heartbeat_interval_secs,
                    msg.message_id,
                    bytes,
                    peer_targets,
                )
                .await;
                // Same rule as dispatch_channel_message: a critical that
                // reaches nobody must say so, not look sent (#132).
                if tracked == 0 {
                    crate::reliability::report_delivery_failure(state, msg.message_id, 0, 0, &[])
                        .await;
                }
            }
        }
        Err(e) => warn!("Failed to encode OSC-injected message: {}", e),
    }
    state.store_message(msg).await;
    out
}

/// Send a direct (peer-to-peer) message to one peer. Best-effort (no ACK/retransmit).
/// Shared by the FFI `send_direct_message` and `macro_router::fire_trigger`'s DM
/// branch — the latter already holds injected handles, so going through `engine()`
/// would be a redundant singleton re-entry.
pub(crate) async fn dispatch_dm(
    state: &AppState,
    transport: &Arc<Transport>,
    peer_id: Uuid,
    payload: String,
    prio: Priority,
) -> Result<Uuid> {
    let config = state.config().await;
    let msg = PatchMessage::new(
        config.client_id,
        &config.client_name,
        format!("dm:{}", peer_id),
        prio,
        payload,
    );
    let peer = state
        .get_peers()
        .await
        .into_iter()
        .find(|p| p.peer_id == peer_id)
        .ok_or_else(|| anyhow::anyhow!("peer not found"))?;
    if let Some(addr) = peer.best_addr() {
        let bytes = encode_dm(&msg, peer_id)?;
        transport.send_to(bytes, addr).await?;
    } else {
        warn!(
            "DM target {} has no address yet — stored locally only",
            peer_id
        );
    }
    let id = msg.message_id;
    state.store_message(msg).await;
    Ok(id)
}

/// Send an arbitrary OSC packet to an external target. Validates the target
/// before touching the socket so callers get a clean error, not a panic.
pub(crate) async fn dispatch_osc(transport: &Arc<Transport>, target: &OscTarget) -> Result<()> {
    channel::validate_osc_target(target)?;
    let ip: IpAddr = target.address.parse().expect("validated above");
    let bytes = encode_osc(&target.path, target.arg_type, target.arg.as_deref())?;
    transport
        .send_to(bytes, SocketAddr::new(ip, target.port))
        .await?;
    Ok(())
}
