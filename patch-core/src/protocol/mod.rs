//! Protocol logic — what a decoded [`PatchEvent`] means and what should
//! happen in response. Owns message origination/relay, the channel-share
//! reply protocol, ACK bookkeeping, and peer-sighting recording.
//!
//! Deliberately separate from `transport`: this module never touches a
//! socket. [`handle`] takes a decoded event and returns the packets it wants
//! sent as a plain value — `transport::receive_loop` decodes bytes, calls
//! `handle`, and forwards whatever comes back onto the send queue. That
//! split is what makes protocol behaviour testable without a live socket,
//! channel, or receive loop (see the tests below).

use std::sync::Arc;

use tokio::sync::Mutex;
use tracing::{debug, warn};
use uuid::Uuid;

use crate::dm::DmThreadKey;
use crate::osc::codec::{encode_ack, encode_channels_announce, encode_macros_announce, PatchEvent};
use crate::osc::types::{ChannelFlash, PatchMessage, PeerPresence, Priority};
use crate::reliability::ReliabilityManager;
use crate::state::channel::{Channel, MacroMessage};
use crate::state::{is_self, AppEvent, AppState, PeerSighting};
use crate::transport::Outgoing;
use std::net::SocketAddr;

/// Defensive cap on how many channels a peer may offer in one announce.
const MAX_OFFERED_CHANNELS: usize = 64;
/// Defensive cap on how many global macros a peer may offer in one announce.
const MAX_OFFERED_GLOBAL_MACROS: usize = 256;

/// Records that `peer_id`/`peer_name` was just heard from at `from` — the
/// sighting every inbound Message/DirectMessage/DirectFlash/Flash arm needs to
/// log so the sender appears in the peers panel (and an already-known
/// sender's address stays current), even when AP isolation blocks their
/// broadcast heartbeats.
async fn record_sender_sighting(
    state: &AppState,
    peer_id: Uuid,
    peer_name: String,
    from: SocketAddr,
) {
    state
        .record_sighting(
            PeerSighting::Heartbeat { peer_id, peer_name },
            from.ip().to_string(),
            from.port(),
        )
        .await;
}

/// Decide what a decoded [`PatchEvent`] means and what should happen in
/// response. State mutations (sightings, stored messages, published events)
/// and reliability bookkeeping happen directly through `state`/`reliability`;
/// only outbound packets come back as data, in the returned `Vec`.
pub(crate) async fn handle(
    event: PatchEvent,
    from: SocketAddr,
    state: &AppState,
    client_id: Uuid,
    reliability: &Arc<Mutex<ReliabilityManager>>,
) -> Vec<Outgoing> {
    // ADR-0010: while an interface is pinned, packets from sources neither on
    // the Pinned Network nor matching a Static Peer address are dropped whole
    // — no sighting, no message, no Flash. One check for every arm.
    if !state.admits_source(from.ip()).await {
        return Vec::new();
    }
    match event {
        PatchEvent::Message(msg) => handle_message(msg, from, state, client_id).await,
        PatchEvent::DirectMessage { msg, target_id } => {
            handle_direct_message(msg, target_id, from, state, client_id).await
        }
        PatchEvent::DirectFlash {
            sender_id,
            sender_name,
            target_id,
        } => handle_direct_flash(sender_id, sender_name, target_id, from, state, client_id).await,
        PatchEvent::Ack {
            message_id,
            peer_id,
        } => handle_ack(message_id, peer_id, state, reliability).await,
        PatchEvent::Presence(p) => handle_presence(p, from, state, client_id).await,
        PatchEvent::Bye { peer_id } => handle_bye(peer_id, state, client_id).await,
        PatchEvent::Flash {
            flash,
            message_id,
            timestamp,
        } => handle_flash(flash, message_id, timestamp, from, state, client_id).await,
        PatchEvent::Say {
            channel_id,
            payload,
            priority,
        } => handle_say(channel_id, payload, priority, state, reliability).await,
        PatchEvent::ChannelsRequest { peer_id } => {
            handle_channels_request(peer_id, from, state, client_id).await
        }
        PatchEvent::ChannelsAnnounce {
            peer_id,
            peer_name,
            channels_json,
        } => handle_channels_announce(peer_id, peer_name, channels_json, state, client_id).await,
        PatchEvent::MacrosRequest { peer_id } => {
            handle_macros_request(peer_id, from, state, client_id).await
        }
        PatchEvent::MacrosAnnounce {
            peer_id,
            peer_name,
            macros_json,
        } => handle_macros_announce(peer_id, peer_name, macros_json, state, client_id).await,
        PatchEvent::Unknown(msg) => {
            debug!("Unknown OSC: {}", msg.addr);
            Vec::new()
        }
    }
}

async fn handle_message(
    msg: PatchMessage,
    from: SocketAddr,
    state: &AppState,
    client_id: Uuid,
) -> Vec<Outgoing> {
    let mut out = Vec::new();
    // ACK critical messages so the sender can stop retransmitting. This must
    // happen *before* the duplicate check: if our first ACK is lost, the
    // sender retransmits the same message_id — which we see as a duplicate —
    // and dropping it without re-ACKing would burn every retry into a false
    // "failed to deliver" (#130).
    if msg.is_critical() {
        match encode_ack(msg.message_id, client_id) {
            Ok(ack_bytes) => out.push(Outgoing::To(ack_bytes, from)),
            Err(e) => warn!("Failed to encode ACK: {}", e),
        }
    }
    // Drop duplicates that arrive on multiple paths (multi-VLAN send,
    // retransmit after a lost ACK) — ACKed above, but not re-stored.
    if state.is_message_duplicate(msg.message_id).await {
        return out;
    }
    // Record the sighting so the sender appears in the peers panel
    // immediately (even when AP isolation blocks their broadcast
    // heartbeats) and so an already-known sender's address stays
    // current. Skip our own — broadcasts don't echo back to self in
    // practice (Messages are unicast-only, never broadcast), but the
    // guard costs nothing and matches every other sender-recording arm.
    if !is_self(msg.sender_id, client_id) {
        record_sender_sighting(state, msg.sender_id, msg.sender_name.clone(), from).await;
    }
    state.store_message(msg).await;
    out
}

async fn handle_direct_message(
    msg: PatchMessage,
    target_id: Uuid,
    from: SocketAddr,
    state: &AppState,
    client_id: Uuid,
) -> Vec<Outgoing> {
    // Only accept DMs addressed to us (they're unicast, so this should
    // always hold — defensive).
    if !is_self(target_id, client_id) {
        return Vec::new();
    }
    // Drop duplicates from multi-path delivery.
    if state.is_message_duplicate(msg.message_id).await {
        return Vec::new();
    }
    // Record the sighting so the DM thread + peers panel show them.
    record_sender_sighting(state, msg.sender_id, msg.sender_name.clone(), from).await;
    // msg.channel_id is already `dm:{sender_id}` (set by decode_dm).
    state.store_message(msg).await;
    Vec::new()
}

async fn handle_direct_flash(
    sender_id: Uuid,
    sender_name: String,
    target_id: Uuid,
    from: SocketAddr,
    state: &AppState,
    client_id: Uuid,
) -> Vec<Outgoing> {
    // Only accept pings addressed to us (unicast — defensive check).
    if !is_self(target_id, client_id) {
        return Vec::new();
    }
    // Record the sighting so the DM thread + peers panel show them.
    record_sender_sighting(state, sender_id, sender_name.clone(), from).await;
    // Flash our DM thread with the sender (keyed by the *other* peer,
    // exactly like an inbound DM). The id is built locally, so it never
    // passes through valid_channel_id (which rejects `dm:` keys).
    state
        .publish(AppEvent::ChannelFlash(ChannelFlash {
            channel_id: DmThreadKey::for_peer(sender_id).local_key(),
            sender_id,
            sender_name,
        }))
        .await;
    Vec::new()
}

pub(crate) async fn handle_ack(
    message_id: Uuid,
    peer_id: Uuid,
    state: &AppState,
    reliability: &Arc<Mutex<ReliabilityManager>>,
) -> Vec<Outgoing> {
    // Record the ACK matched by peer_id (the wire format already carries
    // it). Returns delivery progress so the UI can show "delivered N/M".
    let progress = reliability.lock().await.ack(message_id, peer_id);
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
        if delivered >= total {
            state
                .publish(AppEvent::MessageAcked {
                    message_id,
                    peer_id,
                })
                .await;
        }
    }
    Vec::new()
}

pub(crate) async fn handle_presence(
    p: PeerPresence,
    from: SocketAddr,
    state: &AppState,
    client_id: Uuid,
) -> Vec<Outgoing> {
    // Ignore our own presence broadcast — we receive it on the same socket.
    if is_self(p.peer_id, client_id) {
        return Vec::new();
    }
    state
        .record_sighting(
            PeerSighting::Presence(p),
            from.ip().to_string(),
            from.port(),
        )
        .await;
    Vec::new()
}

async fn handle_bye(peer_id: Uuid, state: &AppState, client_id: Uuid) -> Vec<Outgoing> {
    // Graceful departure — mark the peer offline (grey) immediately
    // instead of waiting out the heartbeat timeout, but keep it in the
    // list so the operator still sees who was connected.
    if !is_self(peer_id, client_id) {
        tracing::info!("Received /patch/bye from {} — marking offline", peer_id);
        state.mark_peer_offline(peer_id).await;
    }
    Vec::new()
}

async fn handle_flash(
    f: ChannelFlash,
    message_id: Uuid,
    timestamp: chrono::DateTime<chrono::Utc>,
    from: SocketAddr,
    state: &AppState,
    client_id: Uuid,
) -> Vec<Outgoing> {
    // Our own flash echoed back (e.g. a static peer misconfigured to our own
    // address) — registering it would put us in our own peers panel and
    // double-log the flash. Same is_self rule as every sender-registering arm.
    if is_self(f.sender_id, client_id) {
        return Vec::new();
    }
    // Drop the copies multi-path delivery produces (one broadcast per
    // interface) — same guard, same order as handle_message: dedup before
    // sighting, so N copies mean one log entry and one pulse.
    if state.is_message_duplicate(message_id).await {
        return Vec::new();
    }
    // Same sighting as for Message.
    record_sender_sighting(state, f.sender_id, f.sender_name.clone(), from).await;
    // Log a Flash entry in the channel's message thread so operators
    // can see who flashed and when. Role is best-effort: it's only
    // available after a presence heartbeat has arrived. The wire
    // timestamp (sender's clock) is used so the entry reads consistently
    // next to that sender's messages — display only, never liveness.
    let sender_role = state.peer_role(f.sender_id).await;
    let flash_log = PatchMessage::new_flash_log(
        message_id,
        f.sender_id,
        f.sender_name.clone(),
        sender_role,
        f.channel_id.clone(),
        timestamp,
    );
    state.store_message(flash_log).await;
    state.publish(AppEvent::ChannelFlash(f)).await;
    Vec::new()
}

async fn handle_say(
    channel_id: String,
    payload: String,
    priority: Priority,
    state: &AppState,
    reliability: &Arc<Mutex<ReliabilityManager>>,
) -> Vec<Outgoing> {
    crate::messaging::originate_for_relay(channel_id, payload, priority, state, reliability).await
}

async fn handle_channels_request(
    peer_id: Uuid,
    from: SocketAddr,
    state: &AppState,
    client_id: Uuid,
) -> Vec<Outgoing> {
    if is_self(peer_id, client_id) {
        return Vec::new(); // don't answer our own request
    }
    let mut out = Vec::new();
    // Reply with our current channel layout, unicast back to the requester.
    let config = state.config().await;
    let channels = state.get_channels().await;
    match serde_json::to_string(&channels) {
        Ok(json) => match encode_channels_announce(config.client_id, &config.client_name, &json) {
            Ok(bytes) => {
                debug!("Replying to channels request from {} ({})", peer_id, from);
                out.push(Outgoing::To(bytes, from));
            }
            Err(e) => warn!("Failed to encode channels announce: {}", e),
        },
        Err(e) => warn!("Failed to serialise channels for announce: {}", e),
    }
    out
}

async fn handle_channels_announce(
    peer_id: Uuid,
    peer_name: String,
    channels_json: String,
    state: &AppState,
    client_id: Uuid,
) -> Vec<Outgoing> {
    if is_self(peer_id, client_id) {
        return Vec::new();
    }
    match serde_json::from_str::<Vec<Channel>>(&channels_json) {
        Ok(channels) => {
            if channels.len() > MAX_OFFERED_CHANNELS {
                warn!(
                    "Channels announce from {} has {} channels (> {}), dropping",
                    peer_name,
                    channels.len(),
                    MAX_OFFERED_CHANNELS
                );
                return Vec::new();
            }
            // Surface for a UI preview/merge prompt — never auto-applied.
            state
                .publish(AppEvent::ChannelsOffered {
                    from_peer_id: peer_id,
                    from_name: peer_name,
                    channels,
                })
                .await;
        }
        Err(e) => warn!(
            "Failed to parse channels announce from {}: {}",
            peer_name, e
        ),
    }
    Vec::new()
}

async fn handle_macros_request(
    peer_id: Uuid,
    from: SocketAddr,
    state: &AppState,
    client_id: Uuid,
) -> Vec<Outgoing> {
    if is_self(peer_id, client_id) {
        return Vec::new(); // don't answer our own request
    }
    let mut out = Vec::new();
    // Reply with our current global macros, unicast back to the requester.
    let config = state.config().await;
    match serde_json::to_string(&config.global_macros) {
        Ok(json) => match encode_macros_announce(config.client_id, &config.client_name, &json) {
            Ok(bytes) => {
                debug!("Replying to macros request from {} ({})", peer_id, from);
                out.push(Outgoing::To(bytes, from));
            }
            Err(e) => warn!("Failed to encode macros announce: {}", e),
        },
        Err(e) => warn!("Failed to serialise global macros for announce: {}", e),
    }
    out
}

async fn handle_macros_announce(
    peer_id: Uuid,
    peer_name: String,
    macros_json: String,
    state: &AppState,
    client_id: Uuid,
) -> Vec<Outgoing> {
    if is_self(peer_id, client_id) {
        return Vec::new();
    }
    match serde_json::from_str::<Vec<MacroMessage>>(&macros_json) {
        Ok(global_macros) => {
            if global_macros.len() > MAX_OFFERED_GLOBAL_MACROS {
                warn!(
                    "Macros announce from {} has {} macros (> {}), dropping",
                    peer_name,
                    global_macros.len(),
                    MAX_OFFERED_GLOBAL_MACROS
                );
                return Vec::new();
            }
            // Surface for a UI preview/merge prompt — never auto-applied.
            state
                .publish(AppEvent::GlobalMacrosOffered {
                    from_peer_id: peer_id,
                    from_name: peer_name,
                    global_macros,
                })
                .await;
        }
        Err(e) => warn!("Failed to parse macros announce from {}: {}", peer_name, e),
    }
    Vec::new()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::osc::codec::decode_packet;
    use crate::osc::types::{ChannelFlash, Priority};
    use crate::state::{Config, PeerSighting};

    /// These handler tests exercise message-routing logic, not the Pinned
    /// Network admission boundary (ADR-0010) — but under mandatory pinning,
    /// an unresolved `AppState` denies every non-Static-Peer source, which
    /// would silently drop every synthetic `addr(n)` packet these tests send.
    /// Pin to a fake interface name and inject a subnet covering `addr()`'s
    /// `10.0.0.0/24` range, mirroring the existing `set_pinned_subnet_for_test`
    /// pattern (real CI has no interface with this fake name to resolve).
    fn pin_test_subnet(state: &AppState) {
        state.set_pinned_subnet_for_test(Some((
            std::net::Ipv4Addr::new(10, 0, 0, 0),
            std::net::Ipv4Addr::new(255, 255, 255, 0),
        )));
    }

    fn test_state() -> AppState {
        let state = AppState::new(Config {
            default_channels: Vec::new(),
            network_interface: Some("test-pin".into()),
            ..Config::default()
        });
        pin_test_subnet(&state);
        state
    }

    /// A state whose `config.client_id` is `client_id` — needed by any test
    /// where `protocol::handle`'s `client_id` param must match what
    /// `state.config().client_id` will be used to originate/sign packets with
    /// (e.g. `Say` origination, `ChannelsRequest` replies).
    fn test_state_with_id(client_id: Uuid) -> AppState {
        let state = AppState::new(Config {
            client_id,
            default_channels: Vec::new(),
            network_interface: Some("test-pin".into()),
            ..Config::default()
        });
        pin_test_subnet(&state);
        state
    }

    fn addr(n: u8) -> SocketAddr {
        format!("10.0.0.{}:9000", n).parse().unwrap()
    }

    /// Records `peer_id` as reachable at `addr(n)` — stands in for a prior
    /// `/patch/presence` heartbeat, the setup every relay/ACK test needs.
    async fn add_known_peer(state: &AppState, peer_id: Uuid, n: u8) {
        state
            .record_sighting(
                PeerSighting::Heartbeat {
                    peer_id,
                    peer_name: "peer".into(),
                },
                format!("10.0.0.{}", n),
                addr(n).port(),
            )
            .await;
    }

    #[tokio::test]
    async fn message_from_new_sender_records_sighting_and_is_stored() {
        let state = test_state();
        let sender_id = Uuid::new_v4();
        let reliability = Arc::new(Mutex::new(ReliabilityManager::new()));
        let msg = PatchMessage::new(sender_id, "Sender", "rf", Priority::Info, "hi");

        let out = handle(
            PatchEvent::Message(msg),
            addr(1),
            &state,
            Uuid::new_v4(),
            &reliability,
        )
        .await;

        assert!(out.is_empty()); // Info priority — no ACK
        let peers = state.get_peers().await;
        assert!(peers.iter().any(|p| p.peer_id == sender_id));
        let stored = state.get_messages("rf", 10).await;
        assert_eq!(stored.len(), 1);
    }

    #[tokio::test]
    async fn critical_message_produces_an_ack() {
        let state = test_state();
        let client_id = Uuid::new_v4();
        let sender_id = Uuid::new_v4();
        let reliability = Arc::new(Mutex::new(ReliabilityManager::new()));
        let msg = PatchMessage::new(sender_id, "Sender", "rf", Priority::Critical, "fire");
        let message_id = msg.message_id;

        let out = handle(
            PatchEvent::Message(msg),
            addr(1),
            &state,
            client_id,
            &reliability,
        )
        .await;

        assert_eq!(out.len(), 1);
        let Outgoing::To(bytes, to) = &out[0] else {
            panic!("expected an ACK To packet")
        };
        assert_eq!(*to, addr(1));
        match decode_packet(bytes).unwrap() {
            PatchEvent::Ack {
                message_id: acked_id,
                peer_id,
            } => {
                assert_eq!(acked_id, message_id);
                assert_eq!(peer_id, client_id);
            }
            other => panic!("expected Ack, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn duplicate_critical_message_is_reacked_but_not_restored() {
        // A lost ACK must cost one retransmit round-trip, not a false
        // "failed to deliver": the sender retransmits, and the receiver must
        // re-ACK the duplicate even though it drops it from storage (#130).
        let state = test_state();
        let client_id = Uuid::new_v4();
        let reliability = Arc::new(Mutex::new(ReliabilityManager::new()));
        let msg = PatchMessage::new(Uuid::new_v4(), "Sender", "rf", Priority::Critical, "fire");

        let first = handle(
            PatchEvent::Message(msg.clone()),
            addr(1),
            &state,
            client_id,
            &reliability,
        )
        .await;
        // Simulate the ACK being lost — the sender retransmits the same packet.
        let second = handle(
            PatchEvent::Message(msg),
            addr(1),
            &state,
            client_id,
            &reliability,
        )
        .await;

        // Both deliveries ACK.
        for out in [&first, &second] {
            assert_eq!(out.len(), 1);
            let Outgoing::To(bytes, to) = &out[0] else {
                panic!("expected an ACK To packet")
            };
            assert_eq!(*to, addr(1));
            assert!(matches!(
                decode_packet(bytes).unwrap(),
                PatchEvent::Ack { .. }
            ));
        }
        // But the message is stored only once.
        assert_eq!(state.get_messages("rf", 10).await.len(), 1);
    }

    #[tokio::test]
    async fn say_originates_relays_and_tracks_critical() {
        let client_id = Uuid::new_v4();
        let state = test_state_with_id(client_id);
        let peer_id = Uuid::new_v4();
        add_known_peer(&state, peer_id, 2).await;
        let reliability = Arc::new(Mutex::new(ReliabilityManager::new()));

        let out = handle(
            PatchEvent::Say {
                channel_id: "rf".into(),
                payload: "go".into(),
                priority: Priority::Critical,
            },
            addr(9), // external OSC source — not itself a Patch peer
            &state,
            client_id,
            &reliability,
        )
        .await;

        // Relayed to the one known peer.
        assert_eq!(out.len(), 1);
        let Outgoing::To(bytes, to) = &out[0] else {
            panic!("expected a relay To packet")
        };
        assert_eq!(*to, addr(2));
        match decode_packet(bytes).unwrap() {
            PatchEvent::Message(msg) => {
                assert_eq!(msg.channel_id, "rf");
                assert_eq!(msg.payload, "go");
                assert_eq!(msg.sender_id, client_id); // originated as us
            }
            other => panic!("expected Message, got {other:?}"),
        }
        // Originated and stored locally too.
        let stored = state.get_messages("rf", 10).await;
        assert_eq!(stored.len(), 1);
        // Critical — tracked for retransmit against the one reachable peer
        // (the first retransmit is due immediately, on the next drain).
        let drained = reliability.lock().await.drain_retransmits();
        assert_eq!(drained.retransmits.len(), 1);
        assert_eq!(drained.retransmits[0].2, vec![addr(2)]);
    }

    /// Pins the state to a (test-injected) 10.1.0.0/24 Pinned Network.
    /// `set_network_interface` recomputes the cache from real interfaces —
    /// which don't exist in CI — so the test override comes after it.
    async fn pin_to_10_1(state: &AppState) {
        state
            .set_network_interface(Some("test0".into()))
            .await
            .unwrap();
        state.set_pinned_subnet_for_test(Some((
            "10.1.0.1".parse().unwrap(),
            "255.255.255.0".parse().unwrap(),
        )));
    }

    fn presence(peer_id: Uuid) -> PatchEvent {
        PatchEvent::Presence(PeerPresence {
            peer_id,
            peer_name: "Wanderer".into(),
            channels: vec![],
            role: None,
            timestamp: chrono::Utc::now(),
        })
    }

    #[tokio::test]
    async fn pinned_drops_presence_from_outside_the_pinned_network() {
        // ADR-0010: operate-only pinning — a peer beaconing from another
        // network must not appear at all.
        let state = test_state();
        pin_to_10_1(&state).await;
        let reliability = Arc::new(Mutex::new(ReliabilityManager::new()));
        let peer_id = Uuid::new_v4();

        handle(
            presence(peer_id),
            "192.168.4.7:9000".parse().unwrap(),
            &state,
            Uuid::new_v4(),
            &reliability,
        )
        .await;

        assert!(
            state.get_peers().await.is_empty(),
            "off-subnet presence must be dropped whole while pinned"
        );
    }

    #[tokio::test]
    async fn pinned_accepts_presence_from_the_pinned_network() {
        let state = test_state();
        pin_to_10_1(&state).await;
        let reliability = Arc::new(Mutex::new(ReliabilityManager::new()));
        let peer_id = Uuid::new_v4();

        handle(
            presence(peer_id),
            "10.1.0.42:9000".parse().unwrap(),
            &state,
            Uuid::new_v4(),
            &reliability,
        )
        .await;

        assert!(state.get_peers().await.iter().any(|p| p.peer_id == peer_id));
    }

    #[tokio::test]
    async fn pinned_admits_a_configured_static_peer_from_beyond_the_network() {
        // The ADR-0010 exemption: an explicitly configured address is
        // Operator intent — routed rigs stay reachable via Static Peers.
        let state = test_state();
        pin_to_10_1(&state).await;
        state
            .add_static_peer("192.168.4.7".into(), 9000, Some("LX".into()))
            .await
            .unwrap();
        let reliability = Arc::new(Mutex::new(ReliabilityManager::new()));
        let peer_id = Uuid::new_v4();

        handle(
            presence(peer_id),
            "192.168.4.7:9000".parse().unwrap(),
            &state,
            Uuid::new_v4(),
            &reliability,
        )
        .await;

        assert!(
            state.get_peers().await.iter().any(|p| p.peer_id == peer_id),
            "a Static Peer's off-subnet source must be admitted while pinned"
        );
    }

    #[tokio::test]
    async fn pinned_drops_channel_messages_and_flashes_whole() {
        // Whole-packet semantics: no ghost senders whose messages render
        // while the Peer itself is filtered.
        let state = test_state();
        pin_to_10_1(&state).await;
        let reliability = Arc::new(Mutex::new(ReliabilityManager::new()));
        let off_subnet: SocketAddr = "192.168.4.7:9000".parse().unwrap();

        handle(
            PatchEvent::Message(PatchMessage::new(
                Uuid::new_v4(),
                "Wanderer",
                "rf",
                Priority::Info,
                "hello?",
            )),
            off_subnet,
            &state,
            Uuid::new_v4(),
            &reliability,
        )
        .await;
        handle(
            PatchEvent::Flash {
                flash: ChannelFlash {
                    channel_id: "rf".into(),
                    sender_id: Uuid::new_v4(),
                    sender_name: "Wanderer".into(),
                },
                message_id: Uuid::new_v4(),
                timestamp: chrono::Utc::now(),
            },
            off_subnet,
            &state,
            Uuid::new_v4(),
            &reliability,
        )
        .await;

        assert!(state.get_messages("rf", 10).await.is_empty());
        assert!(state.get_peers().await.is_empty());
    }

    #[tokio::test]
    async fn repinning_to_a_new_network_readmits_its_sources() {
        // Switching the pin to a different network must refresh the
        // admission gate — the cache can't stay stuck on the old Pinned
        // Network. Under mandatory pinning there's no "unpin" action, only
        // ever a move to a different pin, so this exercises that move
        // directly rather than a round-trip through the unresolved state.
        let state = test_state();
        pin_to_10_1(&state).await;
        let reliability = Arc::new(Mutex::new(ReliabilityManager::new()));
        let peer_id = Uuid::new_v4();
        let from: SocketAddr = "192.168.4.7:9000".parse().unwrap();

        handle(
            presence(peer_id),
            from,
            &state,
            Uuid::new_v4(),
            &reliability,
        )
        .await;
        assert!(state.get_peers().await.is_empty());

        // Re-pin to the network `from` is actually on.
        state
            .set_network_interface(Some("test1".into()))
            .await
            .unwrap();
        state.set_pinned_subnet_for_test(Some((
            "192.168.4.1".parse().unwrap(),
            "255.255.255.0".parse().unwrap(),
        )));
        handle(
            presence(peer_id),
            from,
            &state,
            Uuid::new_v4(),
            &reliability,
        )
        .await;
        assert!(state.get_peers().await.iter().any(|p| p.peer_id == peer_id));
    }

    #[tokio::test]
    async fn duplicate_flash_from_multipath_delivery_is_logged_once() {
        // ADR-0007 multi-path delivery: the same Flash broadcast arrives once
        // per interface on a multi-NIC receiver. Only one Flash log entry and
        // one ChannelFlash pulse may result — same dedup guarantee messages
        // already have.
        let state = test_state();
        let reliability = Arc::new(Mutex::new(ReliabilityManager::new()));
        let sender_id = Uuid::new_v4();
        let flash = ChannelFlash {
            channel_id: "rf".into(),
            sender_id,
            sender_name: "Sender".into(),
        };
        let message_id = Uuid::new_v4();
        let timestamp = chrono::Utc::now();

        // Two copies of the same packet, arriving via two paths — same
        // wire message_id, different source addresses.
        handle(
            PatchEvent::Flash {
                flash: flash.clone(),
                message_id,
                timestamp,
            },
            addr(7),
            &state,
            Uuid::new_v4(),
            &reliability,
        )
        .await;
        handle(
            PatchEvent::Flash {
                flash,
                message_id,
                timestamp,
            },
            addr(8),
            &state,
            Uuid::new_v4(),
            &reliability,
        )
        .await;

        assert_eq!(
            state.get_messages("rf", 10).await.len(),
            1,
            "one flash delivered over two paths must log exactly one entry"
        );
    }

    #[tokio::test]
    async fn flash_from_self_is_ignored_entirely() {
        // Reachable when a static peer is misconfigured to our own address —
        // the echoed flash must not register us as a peer, log a duplicate
        // flash entry, or re-fire the flash event (#131; ERRORS.md invariant:
        // every sender-registering arm checks is_self).
        let client_id = Uuid::new_v4();
        let state = test_state_with_id(client_id);
        let mut events = state.subscribe();
        let reliability = Arc::new(Mutex::new(ReliabilityManager::new()));

        let out = handle(
            PatchEvent::Flash {
                flash: ChannelFlash {
                    channel_id: "rf".into(),
                    sender_id: client_id, // our own flash echoed back
                    sender_name: "us".into(),
                },
                message_id: Uuid::new_v4(),
                timestamp: chrono::Utc::now(),
            },
            addr(1),
            &state,
            client_id,
            &reliability,
        )
        .await;

        assert!(out.is_empty());
        assert!(state.get_peers().await.is_empty()); // no self-sighting
        assert!(state.get_messages("rf", 10).await.is_empty()); // no flash log
                                                                // No ChannelFlash published — a sentinel is the first event observed.
        state.publish(AppEvent::ChannelListUpdated).await;
        assert!(matches!(
            events.recv().await.unwrap(),
            AppEvent::ChannelListUpdated
        ));
    }

    #[tokio::test]
    async fn critical_say_with_no_reachable_peers_reports_delivery_failure() {
        // The normal send path reports an immediate failure when a critical
        // tracks zero targets; the /patch/say injection path must too, or the
        // message looks sent with no feedback (#132).
        let client_id = Uuid::new_v4();
        let state = test_state_with_id(client_id);
        let mut events = state.subscribe();
        let reliability = Arc::new(Mutex::new(ReliabilityManager::new()));

        let out = handle(
            PatchEvent::Say {
                channel_id: "rf".into(),
                payload: "go".into(),
                priority: Priority::Critical,
            },
            addr(9),
            &state,
            client_id,
            &reliability,
        )
        .await;

        assert!(out.is_empty()); // nobody to relay to
                                 // A failed MessageDelivery must be published (skip the
                                 // MessageReceived from the local store). Bounded wait so a missing
                                 // event fails the test instead of hanging it.
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
    async fn channels_request_replies_with_channels_announce() {
        let client_id = Uuid::new_v4();
        let state = test_state_with_id(client_id);
        let requester = Uuid::new_v4();
        state
            .upsert_channel(crate::state::channel::Channel::new("rf", "RF", "#fff").unwrap())
            .await;
        let reliability = Arc::new(Mutex::new(ReliabilityManager::new()));

        let out = handle(
            PatchEvent::ChannelsRequest { peer_id: requester },
            addr(3),
            &state,
            client_id,
            &reliability,
        )
        .await;

        assert_eq!(out.len(), 1);
        let Outgoing::To(bytes, to) = &out[0] else {
            panic!("expected a reply To packet")
        };
        assert_eq!(*to, addr(3)); // unicast back to the requester
        match decode_packet(bytes).unwrap() {
            PatchEvent::ChannelsAnnounce {
                peer_id,
                channels_json,
                ..
            } => {
                assert_eq!(peer_id, client_id);
                assert!(channels_json.contains("\"rf\""));
            }
            other => panic!("expected ChannelsAnnounce, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn channels_announce_over_the_cap_is_dropped_without_publishing() {
        let state = test_state();
        let mut events = state.subscribe();
        let reliability = Arc::new(Mutex::new(ReliabilityManager::new()));

        let channels: Vec<_> = (0..MAX_OFFERED_CHANNELS + 1)
            .map(|i| crate::state::channel::Channel::new(format!("ch{i}"), "X", "#fff").unwrap())
            .collect();
        let channels_json = serde_json::to_string(&channels).unwrap();

        let out = handle(
            PatchEvent::ChannelsAnnounce {
                peer_id: Uuid::new_v4(),
                peer_name: "peer".into(),
                channels_json,
            },
            addr(4),
            &state,
            Uuid::new_v4(),
            &reliability,
        )
        .await;

        assert!(out.is_empty());
        // No ChannelsOffered published — confirm by publishing a sentinel and
        // checking it's the *first* thing observed.
        state.publish(AppEvent::ChannelListUpdated).await;
        assert!(matches!(
            events.recv().await.unwrap(),
            AppEvent::ChannelListUpdated
        ));
    }

    fn test_macro(label: &str) -> MacroMessage {
        MacroMessage {
            label: label.into(),
            payload: label.into(),
            key_binding: None,
            priority: 1,
            midi_note: None,
            midi_cc: None,
            osc: None,
        }
    }

    #[tokio::test]
    async fn macros_request_replies_with_macros_announce() {
        let client_id = Uuid::new_v4();
        let state = test_state_with_id(client_id);
        let requester = Uuid::new_v4();
        state
            .upsert_global_macro(None, test_macro("GO"))
            .await
            .unwrap();
        let reliability = Arc::new(Mutex::new(ReliabilityManager::new()));

        let out = handle(
            PatchEvent::MacrosRequest { peer_id: requester },
            addr(6),
            &state,
            client_id,
            &reliability,
        )
        .await;

        assert_eq!(out.len(), 1);
        let Outgoing::To(bytes, to) = &out[0] else {
            panic!("expected a reply To packet")
        };
        assert_eq!(*to, addr(6)); // unicast back to the requester
        match decode_packet(bytes).unwrap() {
            PatchEvent::MacrosAnnounce {
                peer_id,
                macros_json,
                ..
            } => {
                assert_eq!(peer_id, client_id);
                assert!(macros_json.contains("\"GO\""));
            }
            other => panic!("expected MacrosAnnounce, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn macros_announce_over_the_cap_is_dropped_without_publishing() {
        let state = test_state();
        let mut events = state.subscribe();
        let reliability = Arc::new(Mutex::new(ReliabilityManager::new()));

        let macros: Vec<_> = (0..MAX_OFFERED_GLOBAL_MACROS + 1)
            .map(|i| test_macro(&format!("m{i}")))
            .collect();
        let macros_json = serde_json::to_string(&macros).unwrap();

        let out = handle(
            PatchEvent::MacrosAnnounce {
                peer_id: Uuid::new_v4(),
                peer_name: "peer".into(),
                macros_json,
            },
            addr(7),
            &state,
            Uuid::new_v4(),
            &reliability,
        )
        .await;

        assert!(out.is_empty());
        state.publish(AppEvent::ChannelListUpdated).await;
        assert!(matches!(
            events.recv().await.unwrap(),
            AppEvent::ChannelListUpdated
        ));
    }

    #[tokio::test]
    async fn bye_marks_the_peer_offline() {
        let state = test_state();
        let peer_id = Uuid::new_v4();
        add_known_peer(&state, peer_id, 5).await;
        let reliability = Arc::new(Mutex::new(ReliabilityManager::new()));

        handle(
            PatchEvent::Bye { peer_id },
            addr(5),
            &state,
            Uuid::new_v4(),
            &reliability,
        )
        .await;

        let peer = state
            .get_peers()
            .await
            .into_iter()
            .find(|p| p.peer_id == peer_id)
            .unwrap();
        assert!(peer.departed);
    }

    #[tokio::test]
    async fn ack_updates_delivery_progress_and_publishes_acked() {
        let state = test_state();
        let mut events = state.subscribe();
        let reliability = Arc::new(Mutex::new(ReliabilityManager::new()));
        let message_id = Uuid::new_v4();
        let sender_peer_id = Uuid::new_v4();
        reliability
            .lock()
            .await
            .track(message_id, vec![0], vec![(sender_peer_id, vec![addr(6)])]);

        handle(
            PatchEvent::Ack {
                message_id,
                peer_id: sender_peer_id,
            },
            addr(6),
            &state,
            Uuid::new_v4(),
            &reliability,
        )
        .await;

        let event = events.recv().await.unwrap();
        match event {
            AppEvent::MessageDelivery {
                message_id: id,
                delivered,
                total,
                failed,
                ..
            } => {
                assert_eq!(id, message_id);
                assert_eq!(delivered, 1);
                assert_eq!(total, 1);
                assert!(!failed);
            }
            other => panic!("expected MessageDelivery, got {other:?}"),
        }
        assert!(matches!(
            events.recv().await.unwrap(),
            AppEvent::MessageAcked { .. }
        ));
    }

    #[tokio::test]
    async fn flash_records_sighting_and_publishes_channel_flash() {
        let state = test_state();
        let mut events = state.subscribe();
        let reliability = Arc::new(Mutex::new(ReliabilityManager::new()));
        let sender_id = Uuid::new_v4();

        handle(
            PatchEvent::Flash {
                flash: ChannelFlash {
                    channel_id: "rf".into(),
                    sender_id,
                    sender_name: "Sender".into(),
                },
                message_id: Uuid::new_v4(),
                timestamp: chrono::Utc::now(),
            },
            addr(7),
            &state,
            Uuid::new_v4(),
            &reliability,
        )
        .await;

        let peers = state.get_peers().await;
        assert!(peers.iter().any(|p| p.peer_id == sender_id));
        // PeerUpdated from the sighting, MessageReceived for the flash log
        // entry, then ChannelFlash for the UI trigger.
        assert!(matches!(
            events.recv().await.unwrap(),
            AppEvent::PeerUpdated(_)
        ));
        match events.recv().await.unwrap() {
            AppEvent::MessageReceived(m) => {
                assert!(m.is_flash);
                assert_eq!(m.channel_id, "rf");
                assert_eq!(m.flash_sender_name.as_deref(), Some("Sender"));
            }
            other => panic!("expected MessageReceived(flash log), got {other:?}"),
        }
        match events.recv().await.unwrap() {
            AppEvent::ChannelFlash(f) => assert_eq!(f.channel_id, "rf"),
            other => panic!("expected ChannelFlash, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn duplicate_message_is_silently_dropped() {
        use crate::osc::types::Priority;
        let client_id = Uuid::new_v4();
        let state = test_state_with_id(client_id);
        let mut events = state.subscribe();
        let reliability = Arc::new(Mutex::new(ReliabilityManager::new()));
        let sender_id = Uuid::new_v4();
        let msg_id = Uuid::new_v4();

        let make_event = || {
            PatchEvent::Message(PatchMessage {
                message_id: msg_id,
                sender_id,
                sender_name: "Sender".into(),
                channel_id: "ops".into(),
                priority: Priority::Info,
                payload: "hello".into(),
                is_flash: false,
                flash_sender_name: None,
                flash_sender_role: None,
                timestamp: chrono::Utc::now(),
            })
        };

        handle(make_event(), addr(1), &state, client_id, &reliability).await;
        handle(make_event(), addr(2), &state, client_id, &reliability).await; // same id, different path

        // Consume events from first delivery.
        events.recv().await.unwrap(); // PeerUpdated
        events.recv().await.unwrap(); // MessageReceived

        // Second delivery should be silent — no more events.
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(50), events.recv())
                .await
                .is_err(),
            "duplicate message must not produce a second event"
        );
    }

    // ── per-handler direct tests ──────────────────────────────────────────────

    #[tokio::test]
    async fn handle_channels_announce_directly_rejects_over_cap() {
        let state = test_state();
        let mut events = state.subscribe();

        let channels: Vec<_> = (0..MAX_OFFERED_CHANNELS + 1)
            .map(|i| crate::state::channel::Channel::new(format!("ch{i}"), "X", "#fff").unwrap())
            .collect();
        let channels_json = serde_json::to_string(&channels).unwrap();

        let out = handle_channels_announce(
            Uuid::new_v4(),
            "remote".into(),
            channels_json,
            &state,
            Uuid::new_v4(), // different client_id so self-check passes
        )
        .await;

        assert!(out.is_empty());
        // Confirm no ChannelsOffered was published.
        state.publish(AppEvent::ChannelListUpdated).await;
        assert!(matches!(
            events.recv().await.unwrap(),
            AppEvent::ChannelListUpdated
        ));
    }

    #[tokio::test]
    async fn handle_message_directly_drops_duplicate() {
        let client_id = Uuid::new_v4();
        let state = test_state_with_id(client_id);
        let mut events = state.subscribe();
        let sender_id = Uuid::new_v4();
        let msg_id = Uuid::new_v4();

        let make_msg = || PatchMessage {
            message_id: msg_id,
            sender_id,
            sender_name: "Sender".into(),
            channel_id: "ops".into(),
            priority: Priority::Info,
            payload: "hello".into(),
            is_flash: false,
            flash_sender_name: None,
            flash_sender_role: None,
            timestamp: chrono::Utc::now(),
        };

        handle_message(make_msg(), addr(1), &state, client_id).await;
        handle_message(make_msg(), addr(2), &state, client_id).await; // same id, different path

        events.recv().await.unwrap(); // PeerUpdated
        events.recv().await.unwrap(); // MessageReceived

        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(50), events.recv())
                .await
                .is_err(),
            "duplicate must be dropped by handle_message directly"
        );
    }

    // ── per-arm unit tests (#109) ─────────────────────────────────────────────

    /// `handle_presence` called directly — a non-self presence packet records
    /// the peer sighting without going through the full router.
    #[tokio::test]
    async fn handle_presence_records_peer_sighting() {
        use crate::osc::types::PeerPresence;

        let client_id = Uuid::new_v4();
        let peer_id = Uuid::new_v4();
        let state = test_state_with_id(client_id);

        let presence = PeerPresence {
            peer_id,
            peer_name: "Stage Manager".into(),
            channels: Vec::new(),
            role: None,
            timestamp: chrono::Utc::now(),
        };

        let out = handle_presence(presence, addr(5), &state, client_id).await;

        assert!(out.is_empty());
        let peers = state.get_peers().await;
        assert!(
            peers.iter().any(|p| p.peer_id == peer_id),
            "peer sighting should be recorded"
        );
    }

    /// `handle_presence` with self peer_id is a no-op — own heartbeats must
    /// not create a self-entry in the peer list.
    #[tokio::test]
    async fn handle_presence_ignores_own_heartbeat() {
        use crate::osc::types::PeerPresence;

        let client_id = Uuid::new_v4();
        let state = test_state_with_id(client_id);

        let presence = PeerPresence {
            peer_id: client_id, // same as client_id → self
            peer_name: "Self".into(),
            channels: Vec::new(),
            role: None,
            timestamp: chrono::Utc::now(),
        };

        handle_presence(presence, addr(1), &state, client_id).await;

        assert!(state.get_peers().await.is_empty());
    }

    /// `handle_ack` called directly — resolves the correct (message_id, peer_id)
    /// pair and publishes delivery progress without going through the full router.
    #[tokio::test]
    async fn handle_ack_resolves_correct_message_and_peer() {
        let state = test_state();
        let reliability = Arc::new(Mutex::new(ReliabilityManager::new()));
        let message_id = Uuid::new_v4();
        let peer_id = Uuid::new_v4();

        // Register the message as expecting 1 ACK from peer_id.
        let target_addr: SocketAddr = "10.0.0.5:9000".parse().unwrap();
        reliability.lock().await.track(
            message_id,
            b"bytes".to_vec(),
            vec![(peer_id, vec![target_addr])],
        );

        let mut events = state.subscribe();

        let out = handle_ack(message_id, peer_id, &state, &reliability).await;

        assert!(out.is_empty());
        // Delivery progress event should have been published.
        let evt = tokio::time::timeout(std::time::Duration::from_millis(100), events.recv())
            .await
            .expect("timed out waiting for event")
            .unwrap();
        match evt {
            AppEvent::MessageDelivery {
                message_id: mid,
                delivered,
                total,
                ..
            } => {
                assert_eq!(mid, message_id);
                assert_eq!(delivered, 1);
                assert_eq!(total, 1);
            }
            other => panic!("unexpected event: {:?}", other),
        }
    }
}
