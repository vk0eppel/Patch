//! Core message origination logic shared across the FFI surface, protocol
//! relay, and macro dispatch. `api.rs` and `protocol.rs` delegate here so the
//! send pipeline is written once.

use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;

use anyhow::Result;
use tokio::sync::Mutex;
use tracing::warn;
use uuid::Uuid;

use crate::dm::DmThreadKey;
use crate::osc::codec::{encode_dm, encode_dm_flash, encode_flash, encode_message, encode_osc};
use crate::osc::types::{ChannelFlash, PatchMessage, Priority};
use crate::reliability::ReliabilityManager;
use crate::state::channel::{self, OscTarget};
use crate::state::{AppEvent, AppState};
use crate::transport::{Outgoing, Transport};

/// How an originated channel message leaves this machine.
pub(crate) enum Delivery<'a> {
    /// Send now via the transport (FFI `send_message`, MIDI/key macro fire).
    Direct(&'a Arc<Transport>),
    /// Return the packets instead — the OSC injection path (`/patch/say`),
    /// where `transport::receive_loop` owns the socket writes.
    Relay,
}

/// The one channel-message origination pipeline: encode → fan out to all
/// reachable peers (per [`Delivery`]) → track Critical delivery → store
/// locally → report a Critical that reached nobody as a failed delivery
/// (#132). Returns the message id and, for `Relay`, the packets to emit.
pub(crate) async fn originate_channel_message(
    state: &AppState,
    reliability: &Arc<Mutex<ReliabilityManager>>,
    channel_id: String,
    payload: String,
    prio: Priority,
    delivery: Delivery<'_>,
) -> Result<(Uuid, Vec<Outgoing>)> {
    let config = state.config().await;
    let msg = PatchMessage::new(
        config.client_id,
        &config.client_name,
        channel_id,
        prio,
        payload,
    );
    let bytes = encode_message(&msg)?;
    let out = match delivery {
        Delivery::Direct(transport) => {
            transport
                .send_to_peers(bytes.clone(), state, &config)
                .await?;
            Vec::new()
        }
        Delivery::Relay => state
            .reachable_peer_addrs(config.client_id)
            .await
            .into_iter()
            .map(|addr| Outgoing::To(bytes.clone(), addr))
            .collect(),
    };
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
    Ok((message_id, out))
}

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
    let (id, _) = originate_channel_message(
        state,
        reliability,
        channel_id,
        payload,
        prio,
        Delivery::Direct(transport),
    )
    .await?;
    Ok(id)
}

/// Originate a message for relay to peers, returning the outbound packets
/// rather than sending directly. An encode failure is logged, not propagated —
/// the injection path has no caller to surface an Err to.
pub(crate) async fn originate_for_relay(
    channel_id: String,
    payload: String,
    priority: Priority,
    state: &AppState,
    reliability: &Arc<Mutex<ReliabilityManager>>,
) -> Vec<Outgoing> {
    match originate_channel_message(
        state,
        reliability,
        channel_id,
        payload,
        priority,
        Delivery::Relay,
    )
    .await
    {
        Ok((_, out)) => out,
        Err(e) => {
            warn!("Failed to encode OSC-injected message: {}", e);
            Vec::new()
        }
    }
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
        DmThreadKey::for_peer(peer_id).local_key(),
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

/// Flash a Channel: send to all reachable peers and fire the local
/// ChannelFlash so the sender's own UI pulses too. Best-effort (no ACK).
pub(crate) async fn dispatch_flash(
    state: &AppState,
    transport: &Arc<Transport>,
    channel_id: String,
) -> Result<()> {
    let config = state.config().await;
    let flash = ChannelFlash {
        channel_id,
        sender_id: config.client_id,
        sender_name: config.client_name.clone(),
    };
    let bytes = encode_flash(&flash)?;
    transport.send_to_peers(bytes, state, &config).await?;
    state.publish(AppEvent::ChannelFlash(flash)).await;
    Ok(())
}

/// Flash one Peer's Direct Message thread: unicast **only** to that peer
/// (never broadcast), then fire the local flash on our own `dm:{peer}` thread
/// so the sender sees the ping land. A peer with no resolved address yet gets
/// the local flash only. Best-effort (no ACK), mirroring `dispatch_dm`.
pub(crate) async fn dispatch_dm_flash(
    state: &AppState,
    transport: &Arc<Transport>,
    target: Uuid,
) -> Result<()> {
    let config = state.config().await;
    let flash = ChannelFlash {
        // Local key: our thread with the target peer.
        channel_id: DmThreadKey::for_peer(target).local_key(),
        sender_id: config.client_id,
        sender_name: config.client_name.clone(),
    };
    let peer = state
        .get_peers()
        .await
        .into_iter()
        .find(|p| p.peer_id == target)
        .ok_or_else(|| anyhow::anyhow!("peer not found"))?;
    if let Some(addr) = peer.best_addr() {
        let bytes = encode_dm_flash(&flash, target)?;
        transport.send_to(bytes, addr).await?;
    } else {
        warn!(
            "DM flash target {} has no address yet — local flash only",
            target
        );
    }
    state.publish(AppEvent::ChannelFlash(flash)).await;
    Ok(())
}

/// Unicast one encoded packet to a single Peer identified by its id string.
/// Owns the lookup → best-address → send orchestration (and the operator-facing
/// error text) shared by every single-target request — the level above
/// `Peer::best_addr()`'s single-address resolution. The encoder is handed our
/// own client id, the one field every request packet signs itself with.
pub(crate) async fn send_to_peer_by_id<F>(
    state: &AppState,
    transport: &Arc<Transport>,
    peer_id: &str,
    encode: F,
) -> Result<()>
where
    F: FnOnce(Uuid) -> Result<Vec<u8>>,
{
    let pid = Uuid::parse_str(peer_id).map_err(|_| anyhow::anyhow!("invalid peer id"))?;
    let peer = state
        .get_peers()
        .await
        .into_iter()
        .find(|p| p.peer_id == pid)
        .ok_or_else(|| anyhow::anyhow!("peer not found"))?;
    let addr = peer.best_addr().ok_or_else(|| {
        anyhow::anyhow!("peer has no resolved address yet — try again once it's online")
    })?;
    let client_id = state.config().await.client_id;
    let bytes = encode(client_id)?;
    transport.send_to(bytes, addr).await
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state::{AppEvent, Config};

    fn test_state() -> AppState {
        AppState::new(Config {
            osc_port: 0, // ephemeral — tests must not collide on a fixed port
            default_channels: Vec::new(),
            ..Config::default()
        })
    }

    async fn transport(state: &AppState) -> Arc<Transport> {
        let config = state.config().await;
        let reliability = Arc::new(Mutex::new(ReliabilityManager::new()));
        Arc::new(
            Transport::new(&config, state.clone(), reliability)
                .await
                .unwrap(),
        )
    }

    /// Bounded wait for a failed MessageDelivery — a missing event fails the
    /// test instead of hanging it.
    async fn expect_delivery_failure(events: &mut tokio::sync::broadcast::Receiver<AppEvent>) {
        let wait = tokio::time::timeout(std::time::Duration::from_secs(2), async {
            loop {
                match events.recv().await.unwrap() {
                    AppEvent::MessageDelivery { failed, .. } => break failed,
                    _ => continue,
                }
            }
        })
        .await;
        assert!(matches!(wait, Ok(true)), "no failed MessageDelivery event");
    }

    #[tokio::test]
    async fn critical_reaching_nobody_reports_failure_relay_path() {
        // The #132 rule, exercised through the one origination core: a
        // Critical Message that tracks zero targets must publish a failed
        // MessageDelivery, not look sent.
        let state = test_state();
        let mut events = state.subscribe();
        let reliability = Arc::new(Mutex::new(ReliabilityManager::new()));

        let (_, out) = originate_channel_message(
            &state,
            &reliability,
            "rf".into(),
            "go".into(),
            Priority::Critical,
            Delivery::Relay,
        )
        .await
        .unwrap();

        assert!(out.is_empty(), "nobody to relay to");
        expect_delivery_failure(&mut events).await;
    }

    #[tokio::test]
    async fn critical_reaching_nobody_reports_failure_direct_path() {
        let state = test_state();
        let transport = transport(&state).await;
        let mut events = state.subscribe();
        let reliability = Arc::new(Mutex::new(ReliabilityManager::new()));

        let (_, out) = originate_channel_message(
            &state,
            &reliability,
            "rf".into(),
            "go".into(),
            Priority::Critical,
            Delivery::Direct(&transport),
        )
        .await
        .unwrap();

        assert!(out.is_empty(), "direct delivery returns no relay packets");
        expect_delivery_failure(&mut events).await;
    }

    #[tokio::test]
    async fn origination_stores_the_message_locally() {
        let state = test_state();
        let reliability = Arc::new(Mutex::new(ReliabilityManager::new()));

        let (id, _) = originate_channel_message(
            &state,
            &reliability,
            "rf".into(),
            "standby".into(),
            Priority::Info,
            Delivery::Relay,
        )
        .await
        .unwrap();

        let stored = state.get_messages("rf", 10).await;
        assert_eq!(stored.len(), 1);
        assert_eq!(stored[0].message_id, id);
    }

    /// Bounded wait for the next ChannelFlash — returns its channel_id.
    async fn expect_flash(events: &mut tokio::sync::broadcast::Receiver<AppEvent>) -> String {
        let wait = tokio::time::timeout(std::time::Duration::from_secs(2), async {
            loop {
                if let AppEvent::ChannelFlash(f) = events.recv().await.unwrap() {
                    break f.channel_id;
                }
            }
        })
        .await;
        wait.expect("no ChannelFlash event")
    }

    #[tokio::test]
    async fn flash_origination_publishes_the_local_flash() {
        let state = test_state();
        let transport = transport(&state).await;
        let mut events = state.subscribe();

        dispatch_flash(&state, &transport, "rf".into())
            .await
            .unwrap();

        assert_eq!(expect_flash(&mut events).await, "rf");
    }

    #[tokio::test]
    async fn dm_flash_to_unknown_peer_is_a_clean_error() {
        let state = test_state();
        let transport = transport(&state).await;

        let err = dispatch_dm_flash(&state, &transport, Uuid::new_v4())
            .await
            .unwrap_err();
        assert!(err.to_string().contains("peer not found"));
    }

    #[tokio::test]
    async fn dm_flash_to_addressless_peer_still_flashes_locally() {
        // A Static Peer that hasn't resolved yet: the sender must still see
        // their own ping land on the local DM thread.
        let state = test_state();
        let transport = transport(&state).await;
        let peer_id = Uuid::new_v4();
        // An mDNS sighting with an empty address registers the peer without
        // giving it a reachable path.
        state
            .record_sighting(
                crate::state::PeerSighting::Mdns(crate::osc::types::PeerPresence {
                    peer_id,
                    peer_name: "rigger".into(),
                    channels: Vec::new(),
                    role: None,
                    timestamp: chrono::Utc::now(),
                }),
                String::new(),
                0,
            )
            .await;
        let mut events = state.subscribe();

        dispatch_dm_flash(&state, &transport, peer_id)
            .await
            .unwrap();

        assert_eq!(
            expect_flash(&mut events).await,
            DmThreadKey::for_peer(peer_id).local_key()
        );
    }

    // ── send_to_peer_by_id ────────────────────────────────────────────────────

    fn encode_probe(client_id: Uuid) -> Result<Vec<u8>> {
        crate::osc::codec::encode_channels_request(client_id)
    }

    #[tokio::test]
    async fn send_to_peer_by_id_rejects_a_malformed_id() {
        let state = test_state();
        let transport = transport(&state).await;
        let err = send_to_peer_by_id(&state, &transport, "not-a-uuid", encode_probe)
            .await
            .unwrap_err();
        assert!(err.to_string().contains("invalid peer id"));
    }

    #[tokio::test]
    async fn send_to_peer_by_id_reports_an_unknown_peer() {
        let state = test_state();
        let transport = transport(&state).await;
        let err = send_to_peer_by_id(
            &state,
            &transport,
            &Uuid::new_v4().to_string(),
            encode_probe,
        )
        .await
        .unwrap_err();
        assert!(err.to_string().contains("peer not found"));
    }

    #[tokio::test]
    async fn send_to_peer_by_id_is_a_clean_error_for_an_addressless_peer() {
        // A Peer known via mDNS but with no resolved address must produce the
        // operator-facing "try again" error, not a panic or a silent drop.
        let state = test_state();
        let transport = transport(&state).await;
        let peer_id = Uuid::new_v4();
        state
            .record_sighting(
                crate::state::PeerSighting::Mdns(crate::osc::types::PeerPresence {
                    peer_id,
                    peer_name: "rigger".into(),
                    channels: Vec::new(),
                    role: None,
                    timestamp: chrono::Utc::now(),
                }),
                String::new(),
                0,
            )
            .await;
        let err = send_to_peer_by_id(&state, &transport, &peer_id.to_string(), encode_probe)
            .await
            .unwrap_err();
        assert!(err.to_string().contains("no resolved address yet"));
    }

    #[tokio::test]
    async fn send_to_peer_by_id_sends_to_a_reachable_peer() {
        let state = test_state();
        let transport = transport(&state).await;
        let peer_id = Uuid::new_v4();
        state
            .record_sighting(
                crate::state::PeerSighting::Heartbeat {
                    peer_id,
                    peer_name: "rigger".into(),
                },
                "127.0.0.1".into(),
                9909,
            )
            .await;
        send_to_peer_by_id(&state, &transport, &peer_id.to_string(), encode_probe)
            .await
            .unwrap();
    }
}
