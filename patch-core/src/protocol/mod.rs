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

use crate::osc::codec::{
    encode_ack, encode_channels_announce, encode_macros_announce, encode_message, PatchEvent,
};
use crate::osc::types::PatchMessage;
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
    let mut out = Vec::new();
    match event {
        PatchEvent::Message(msg) => {
            // Record the sighting so the sender appears in the peers panel
            // immediately (even when AP isolation blocks their broadcast
            // heartbeats) and so an already-known sender's address stays
            // current. Skip our own — broadcasts don't echo back to self in
            // practice (Messages are unicast-only, never broadcast), but the
            // guard costs nothing and matches every other sender-recording arm.
            if !is_self(msg.sender_id, client_id) {
                record_sender_sighting(state, msg.sender_id, msg.sender_name.clone(), from).await;
            }
            // ACK critical messages so the sender can stop retransmitting.
            if msg.is_critical() {
                match encode_ack(msg.message_id, client_id) {
                    Ok(ack_bytes) => out.push(Outgoing::To(ack_bytes, from)),
                    Err(e) => warn!("Failed to encode ACK: {}", e),
                }
            }
            state.store_message(msg).await;
        }
        PatchEvent::DirectMessage { msg, target_id } => {
            // Only accept DMs addressed to us (they're unicast, so this should
            // always hold — defensive).
            if !is_self(target_id, client_id) {
                return out;
            }
            // Record the sighting so the DM thread + peers panel show them.
            record_sender_sighting(state, msg.sender_id, msg.sender_name.clone(), from).await;
            // msg.channel_id is already `dm:{sender_id}` (set by decode_dm).
            state.store_message(msg).await;
        }
        PatchEvent::DirectFlash {
            sender_id,
            sender_name,
            target_id,
        } => {
            // Only accept pings addressed to us (unicast — defensive check).
            if !is_self(target_id, client_id) {
                return out;
            }
            // Record the sighting so the DM thread + peers panel show them.
            record_sender_sighting(state, sender_id, sender_name.clone(), from).await;
            // Flash our DM thread with the sender (keyed by the *other* peer,
            // exactly like an inbound DM). The id is built locally, so it never
            // passes through valid_channel_id (which rejects `dm:` keys).
            state
                .publish(AppEvent::ChannelFlash(crate::osc::types::ChannelFlash {
                    channel_id: format!("dm:{}", sender_id),
                    sender_id,
                    sender_name,
                }))
                .await;
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
            if is_self(p.peer_id, client_id) {
                return out;
            }
            state
                .record_sighting(
                    PeerSighting::Presence(p),
                    from.ip().to_string(),
                    from.port(),
                )
                .await;
        }
        PatchEvent::Bye { peer_id } => {
            // Graceful departure — mark the peer offline (grey) immediately
            // instead of waiting out the heartbeat timeout, but keep it in the
            // list so the operator still sees who was connected.
            if !is_self(peer_id, client_id) {
                tracing::info!("Received /patch/bye from {} — marking offline", peer_id);
                state.mark_peer_offline(peer_id).await;
            }
        }
        PatchEvent::Flash(f) => {
            // Same sighting as for Message.
            record_sender_sighting(state, f.sender_id, f.sender_name.clone(), from).await;
            state.publish(AppEvent::ChannelFlash(f)).await;
        }
        PatchEvent::Say {
            channel_id,
            payload,
            priority,
        } => {
            // External OSC injection (e.g. QLab). This node *originates* the
            // message — its identity, a fresh id + timestamp — then relays it to
            // every known peer and stores it locally, so an OSC source can post to
            // the whole crew through this node (exactly as if typed here).
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
                    // Same target resolution as `Transport::send_to_peers` — this
                    // path just returns the packets instead of sending directly.
                    let targets = state.reachable_peer_addrs(config.client_id).await;
                    for addr in &targets {
                        out.push(Outgoing::To(bytes.clone(), *addr));
                    }
                    // Track criticals for retransmit, like a hand-sent message —
                    // same offline-peer filter `dispatch_message` applies, so an
                    // injected critical doesn't retransmit against peers already
                    // known to be gone.
                    if msg.is_critical() {
                        crate::reliability::track_critical(
                            reliability,
                            state,
                            config.heartbeat_interval_secs,
                            msg.message_id,
                            bytes,
                            targets,
                        )
                        .await;
                    }
                }
                Err(e) => warn!("Failed to encode OSC-injected message: {}", e),
            }
            state.store_message(msg).await;
        }
        PatchEvent::ChannelsRequest { peer_id } => {
            if is_self(peer_id, client_id) {
                return out; // don't answer our own request
            }
            // Reply with our current channel layout, unicast back to the requester.
            let config = state.config().await;
            let channels = state.get_channels().await;
            match serde_json::to_string(&channels) {
                Ok(json) => {
                    match encode_channels_announce(config.client_id, &config.client_name, &json) {
                        Ok(bytes) => {
                            debug!("Replying to channels request from {} ({})", peer_id, from);
                            out.push(Outgoing::To(bytes, from));
                        }
                        Err(e) => warn!("Failed to encode channels announce: {}", e),
                    }
                }
                Err(e) => warn!("Failed to serialise channels for announce: {}", e),
            }
        }
        PatchEvent::ChannelsAnnounce {
            peer_id,
            peer_name,
            channels_json,
        } => {
            if is_self(peer_id, client_id) {
                return out;
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
                        return out;
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
        }
        PatchEvent::MacrosRequest { peer_id } => {
            if is_self(peer_id, client_id) {
                return out; // don't answer our own request
            }
            // Reply with our current global macros, unicast back to the requester.
            let config = state.config().await;
            match serde_json::to_string(&config.global_macros) {
                Ok(json) => {
                    match encode_macros_announce(config.client_id, &config.client_name, &json) {
                        Ok(bytes) => {
                            debug!("Replying to macros request from {} ({})", peer_id, from);
                            out.push(Outgoing::To(bytes, from));
                        }
                        Err(e) => warn!("Failed to encode macros announce: {}", e),
                    }
                }
                Err(e) => warn!("Failed to serialise global macros for announce: {}", e),
            }
        }
        PatchEvent::MacrosAnnounce {
            peer_id,
            peer_name,
            macros_json,
        } => {
            if is_self(peer_id, client_id) {
                return out;
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
                        return out;
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
        }
        PatchEvent::Unknown(msg) => {
            debug!("Unknown OSC: {}", msg.addr);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::osc::codec::decode_packet;
    use crate::osc::types::{ChannelFlash, Priority};
    use crate::state::{Config, PeerSighting};

    fn test_state() -> AppState {
        AppState::new(Config {
            default_channels: Vec::new(),
            ..Config::default()
        })
    }

    /// A state whose `config.client_id` is `client_id` — needed by any test
    /// where `protocol::handle`'s `client_id` param must match what
    /// `state.config().client_id` will be used to originate/sign packets with
    /// (e.g. `Say` origination, `ChannelsRequest` replies).
    fn test_state_with_id(client_id: Uuid) -> AppState {
        AppState::new(Config {
            client_id,
            default_channels: Vec::new(),
            ..Config::default()
        })
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
        reliability
            .lock()
            .await
            .track(message_id, vec![0], vec![addr(6)]);

        handle(
            PatchEvent::Ack {
                message_id,
                peer_id: Uuid::new_v4(),
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
            PatchEvent::Flash(ChannelFlash {
                channel_id: "rf".into(),
                sender_id,
                sender_name: "Sender".into(),
            }),
            addr(7),
            &state,
            Uuid::new_v4(),
            &reliability,
        )
        .await;

        let peers = state.get_peers().await;
        assert!(peers.iter().any(|p| p.peer_id == sender_id));
        // The sighting publishes PeerUpdated first, then the flash itself.
        assert!(matches!(
            events.recv().await.unwrap(),
            AppEvent::PeerUpdated(_)
        ));
        match events.recv().await.unwrap() {
            AppEvent::ChannelFlash(f) => assert_eq!(f.channel_id, "rf"),
            other => panic!("expected ChannelFlash, got {other:?}"),
        }
    }
}
