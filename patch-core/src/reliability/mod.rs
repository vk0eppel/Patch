//! Reliability layer — ACK tracking and retransmission for critical messages.
//!
//! Only `Priority::Critical` messages require ACKs. Info/Warning messages are
//! fire-and-forget (with optional best-effort retransmit).
//!
//! ACKs are matched by **peer_id** — the sender id carried in the `/patch/ack`
//! wire format. This is correct for multi-VLAN topologies where a peer may
//! send ACKs from a different address than the one we unicast to (e.g. the
//! reply comes back on the interface the peer first receives on).

use std::collections::{HashMap, HashSet};
use std::net::SocketAddr;
use std::sync::Arc;

use tokio::sync::Mutex;
use tracing::{debug, warn};
use uuid::Uuid;

use crate::state::{AppEvent, AppState};
use crate::transport::Transport;

/// Max retransmit attempts for an unacked critical before it's reported failed.
const MAX_RETRIES: u32 = 5;

/// Poll interval (ms) for the retransmit loop. Each in-flight entry retransmits
/// on an **exponential backoff** measured in these ticks (2 → 4 → 8 → 16 → 32),
/// i.e. ~200ms, 400ms, 800ms, 1.6s, 3.2s between attempts — so a lossy link
/// isn't hammered, while the first retransmit still fires within ~one tick.
pub const POLL_INTERVAL_MS: u64 = 100;

/// Entry tracking an in-flight critical message.
#[derive(Debug)]
struct InFlight {
    bytes: Vec<u8>,
    /// peer_id → all their addresses (for retransmit to all paths).
    targets: HashMap<Uuid, Vec<SocketAddr>>,
    /// Peer IDs that have sent an ACK.
    acked: HashSet<Uuid>,
    retries: u32,
    /// Poll ticks remaining until the next retransmit attempt (0 = due now).
    /// Set to `2^retries` after each attempt for exponential backoff.
    ticks_until_retry: u32,
}

/// A critical message that exhausted its retries without every target ACKing.
#[derive(Debug)]
pub struct DeliveryFailure {
    pub message_id: Uuid,
    /// Peer IDs that never acknowledged.
    pub unacked: Vec<Uuid>,
    pub acked: u32,
    pub total: u32,
}

/// Outcome of one [`ReliabilityManager::drain_retransmits`] tick.
#[derive(Default)]
pub struct DrainResult {
    /// (message_id, bytes, still-pending targets) to re-send.
    pub retransmits: Vec<(Uuid, Vec<u8>, Vec<SocketAddr>)>,
    /// Entries dropped this tick because they exceeded `MAX_RETRIES`.
    pub failures: Vec<DeliveryFailure>,
}

/// Manages retransmit state for critical messages.
#[derive(Default)]
pub struct ReliabilityManager {
    /// message_id → in-flight record
    in_flight: HashMap<Uuid, InFlight>,
}

impl ReliabilityManager {
    pub fn new() -> Self {
        Self::default()
    }

    /// Register a critical message for ACK tracking.
    pub fn track(
        &mut self,
        message_id: Uuid,
        bytes: Vec<u8>,
        targets: Vec<(Uuid, Vec<SocketAddr>)>,
    ) {
        self.in_flight.insert(
            message_id,
            InFlight {
                bytes,
                targets: targets.into_iter().collect(),
                acked: HashSet::new(),
                retries: 0,
                ticks_until_retry: 0, // first retransmit is due on the next tick
            },
        );
    }

    /// Record an ACK from `peer_id` for `message_id`. Returns
    /// `Some((acked, total))` delivery progress when `peer_id` is one of the
    /// tracked targets — the entry is removed once `acked == total`. Returns
    /// `None` for an unknown message or a stray ACK from a non-target peer.
    /// Duplicate ACKs from the same peer are idempotent.
    pub fn ack(&mut self, message_id: Uuid, peer_id: Uuid) -> Option<(u32, u32)> {
        let entry = self.in_flight.get_mut(&message_id)?;
        if !entry.targets.contains_key(&peer_id) {
            return None; // stray ACK — ignore
        }
        entry.acked.insert(peer_id);
        let total = entry.targets.len() as u32;
        let acked = entry.acked.len() as u32;
        if acked >= total {
            self.in_flight.remove(&message_id);
        }
        Some((acked, total))
    }

    /// Advance retransmit state one tick. Returns the messages that still need
    /// re-sending — each paired with **only the addresses of unacked peers** —
    /// plus any entries that exceeded `MAX_RETRIES`, reported as `failures`.
    pub fn drain_retransmits(&mut self) -> DrainResult {
        let mut result = DrainResult::default();
        let mut to_drop = Vec::new();

        for (id, entry) in self.in_flight.iter_mut() {
            // Exponential backoff — only attempt once the per-entry countdown
            // elapses; other ticks just decrement it.
            if entry.ticks_until_retry > 0 {
                entry.ticks_until_retry -= 1;
                continue;
            }

            let unacked_peers: Vec<Uuid> = entry
                .targets
                .keys()
                .filter(|pid| !entry.acked.contains(*pid))
                .copied()
                .collect();
            if unacked_peers.is_empty() {
                // Fully acked — `ack()` normally removes the entry, but clear it
                // defensively here too rather than spin on an empty target set.
                to_drop.push(*id);
                continue;
            }

            entry.retries += 1;
            if entry.retries > MAX_RETRIES {
                warn!(
                    "Message {} exceeded max retries — {} peer(s) never ACKed",
                    id,
                    unacked_peers.len()
                );
                result.failures.push(DeliveryFailure {
                    message_id: *id,
                    unacked: unacked_peers.clone(),
                    acked: entry.acked.len() as u32,
                    total: entry.targets.len() as u32,
                });
                to_drop.push(*id);
                continue;
            }

            // Collect all addresses of unacked peers for retransmit.
            let unacked_addrs: Vec<SocketAddr> = unacked_peers
                .iter()
                .flat_map(|pid| entry.targets[pid].iter().copied())
                .collect();

            // Schedule the next attempt: 2, 4, 8, 16, 32 ticks (capped).
            entry.ticks_until_retry = 1u32 << entry.retries.min(6);
            debug!(
                "Retransmitting {} to {} pending peer(s) (attempt {})",
                id,
                unacked_peers.len(),
                entry.retries
            );
            result
                .retransmits
                .push((*id, entry.bytes.clone(), unacked_addrs));
        }

        for id in to_drop {
            self.in_flight.remove(&id);
        }

        result
    }
}

/// Registers a critical message for ACK tracking, after filtering out peers
/// that already look offline — tracking them only buys pointless retransmits
/// ending in a "failed to deliver" warning that could've been skipped up front.
///
/// Returns the number of peers actually tracked (0 means nothing to track —
/// callers use this to decide whether to report an immediate failure).
pub async fn track_critical(
    reliability: &Mutex<ReliabilityManager>,
    state: &AppState,
    heartbeat_secs: u64,
    message_id: Uuid,
    bytes: Vec<u8>,
    targets: Vec<(Uuid, Vec<SocketAddr>)>,
) -> usize {
    let peers = state.get_peers().await;
    let trackable: Vec<(Uuid, Vec<SocketAddr>)> = targets
        .into_iter()
        .filter(|(peer_id, _)| {
            crate::state::peer::find_peer(&peers, *peer_id)
                .map(|p| !p.looks_offline(heartbeat_secs))
                .unwrap_or(true) // unknown peer → track anyway
        })
        .collect();
    let count = trackable.len();
    if count > 0 {
        reliability.lock().await.track(message_id, bytes, trackable);
    }
    count
}

/// Publishes a failed-delivery `MessageDelivery` event, resolving unacked
/// peer IDs to display names. Shared by `dispatch_message`'s "no peers
/// to send to" case and the retransmit poller's "exceeded MAX_RETRIES" case.
pub async fn report_delivery_failure(
    state: &AppState,
    message_id: Uuid,
    delivered: u32,
    total: u32,
    unacked: &[Uuid],
) {
    let failed_peers = resolve_peer_names(state, unacked).await;
    state
        .publish(AppEvent::MessageDelivery {
            message_id,
            delivered,
            total,
            failed: true,
            failed_peers,
        })
        .await;
}

/// Maps peer IDs to display names for the "not delivered to …" alert,
/// falling back to the raw UUID string if unknown.
async fn resolve_peer_names(state: &AppState, peer_ids: &[Uuid]) -> Vec<String> {
    if peer_ids.is_empty() {
        return Vec::new();
    }
    let peers = state.get_peers().await;
    peer_ids
        .iter()
        .map(|id| {
            crate::state::peer::find_peer(&peers, *id)
                .map(|p| p.peer_name.clone())
                .unwrap_or_else(|| id.to_string())
        })
        .collect()
}

/// Starts the retransmit poller for unacked critical messages and returns its
/// task handle. Ticks every [`POLL_INTERVAL_MS`]; each in-flight entry
/// retransmits on its own exponential backoff (`drain_retransmits`) until
/// acked or it exceeds `MAX_RETRIES`. When an entry exhausts its retries it
/// comes back as a failure, surfaced to the UI as a failed `MessageDelivery`
/// naming the peers that never ACKed.
pub fn spawn_retransmit_loop(
    state: AppState,
    transport: Arc<Transport>,
    reliability: Arc<Mutex<ReliabilityManager>>,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let mut interval =
            tokio::time::interval(std::time::Duration::from_millis(POLL_INTERVAL_MS));
        loop {
            interval.tick().await;
            let due = reliability.lock().await.drain_retransmits();
            for (_id, bytes, targets) in due.retransmits {
                for addr in targets {
                    let _ = transport.send_to(bytes.clone(), addr).await;
                }
            }
            for failure in due.failures {
                report_delivery_failure(
                    &state,
                    failure.message_id,
                    failure.acked,
                    failure.total,
                    &failure.unacked,
                )
                .await;
            }
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn addr(n: u8) -> SocketAddr {
        format!("10.0.0.{}:9000", n).parse().unwrap()
    }

    fn peer_target(peer_id: Uuid, addrs: &[u8]) -> (Uuid, Vec<SocketAddr>) {
        (peer_id, addrs.iter().map(|n| addr(*n)).collect())
    }

    #[test]
    fn full_ack_completes_and_clears() {
        let mut r = ReliabilityManager::new();
        let id = Uuid::new_v4();
        let p1 = Uuid::new_v4();
        let p2 = Uuid::new_v4();
        r.track(
            id,
            vec![1, 2, 3],
            vec![peer_target(p1, &[1]), peer_target(p2, &[2])],
        );
        assert_eq!(r.ack(id, p1), Some((1, 2))); // progress
        assert_eq!(r.ack(id, p2), Some((2, 2))); // all acked — completes
        assert!(r.drain_retransmits().retransmits.is_empty());
    }

    #[test]
    fn stray_ack_from_non_target_is_ignored() {
        let mut r = ReliabilityManager::new();
        let id = Uuid::new_v4();
        let p1 = Uuid::new_v4();
        r.track(id, vec![0], vec![peer_target(p1, &[1])]);
        assert_eq!(r.ack(id, Uuid::new_v4()), None); // never a target — ignored
        let due = r.drain_retransmits();
        assert_eq!(due.retransmits.len(), 1);
        assert_eq!(due.retransmits[0].2, vec![addr(1)]); // still pending
    }

    #[test]
    fn retransmit_targets_exclude_acked_peers() {
        let mut r = ReliabilityManager::new();
        let id = Uuid::new_v4();
        let p1 = Uuid::new_v4();
        let p2 = Uuid::new_v4();
        let p3 = Uuid::new_v4();
        r.track(
            id,
            vec![0],
            vec![
                peer_target(p1, &[1]),
                peer_target(p2, &[2]),
                peer_target(p3, &[3]),
            ],
        );
        assert_eq!(r.ack(id, p2), Some((1, 3))); // p2 acked; p1 and p3 still pending
        let due = r.drain_retransmits();
        assert_eq!(due.retransmits.len(), 1);
        let pending = &due.retransmits[0].2;
        assert!(pending.contains(&addr(1)));
        assert!(pending.contains(&addr(3)));
        assert!(!pending.contains(&addr(2))); // acked — not retransmitted
    }

    #[test]
    fn duplicate_ack_is_idempotent() {
        let mut r = ReliabilityManager::new();
        let id = Uuid::new_v4();
        let p1 = Uuid::new_v4();
        let p2 = Uuid::new_v4();
        r.track(
            id,
            vec![0],
            vec![peer_target(p1, &[1]), peer_target(p2, &[2])],
        );
        assert_eq!(r.ack(id, p1), Some((1, 2)));
        assert_eq!(r.ack(id, p1), Some((1, 2))); // same peer — count unchanged
        assert_eq!(r.ack(id, p2), Some((2, 2)));
    }

    #[test]
    fn retransmit_uses_exponential_backoff_spacing() {
        let mut r = ReliabilityManager::new();
        let id = Uuid::new_v4();
        r.track(id, vec![0], vec![peer_target(Uuid::new_v4(), &[1])]);
        assert_eq!(r.drain_retransmits().retransmits.len(), 1); // attempt 1
        assert!(r.drain_retransmits().retransmits.is_empty()); // backoff tick 1/2
        assert!(r.drain_retransmits().retransmits.is_empty()); // backoff tick 2/2
        assert_eq!(r.drain_retransmits().retransmits.len(), 1); // attempt 2
    }

    #[test]
    fn entry_dropped_after_max_retries_and_reports_failure() {
        let mut r = ReliabilityManager::new();
        let id = Uuid::new_v4();
        let p1 = Uuid::new_v4();
        let p2 = Uuid::new_v4();
        r.track(
            id,
            vec![0],
            vec![peer_target(p1, &[1]), peer_target(p2, &[2])],
        );
        r.ack(id, p1); // one of two acks; p2 never will
        let mut attempts = 0;
        let mut failure = None;
        for _ in 0..1000 {
            let due = r.drain_retransmits();
            attempts += due.retransmits.len();
            if let Some(f) = due.failures.into_iter().next() {
                failure = Some(f);
                break;
            }
        }
        let f = failure.expect("must report a failure after MAX_RETRIES");
        assert_eq!(attempts, MAX_RETRIES as usize);
        assert_eq!(f.message_id, id);
        assert_eq!(f.acked, 1);
        assert_eq!(f.total, 2);
        assert_eq!(f.unacked, vec![p2]); // the straggler is named by peer_id
        assert_eq!(r.ack(id, p2), None); // a late ACK now finds nothing
    }

    #[test]
    fn ack_for_unknown_message_is_none() {
        let mut r = ReliabilityManager::new();
        assert_eq!(r.ack(Uuid::new_v4(), Uuid::new_v4()), None);
    }

    // ── New Task 3 tests ──────────────────────────────────────────────────────

    #[test]
    fn ack_by_peer_id_clears_that_peer() {
        let mut r = ReliabilityManager::new();
        let id = Uuid::new_v4();
        let peer_a = Uuid::new_v4();
        let peer_b = Uuid::new_v4();
        r.track(
            id,
            vec![0],
            vec![peer_target(peer_a, &[1, 2]), peer_target(peer_b, &[3])],
        );
        assert_eq!(r.ack(id, peer_a), Some((1, 2)));
        assert_eq!(r.ack(id, peer_b), Some((2, 2)));
        assert!(r.drain_retransmits().retransmits.is_empty());
    }

    #[test]
    fn ack_from_unknown_peer_id_is_ignored() {
        let mut r = ReliabilityManager::new();
        let id = Uuid::new_v4();
        let peer_a = Uuid::new_v4();
        r.track(id, vec![0], vec![peer_target(peer_a, &[1])]);
        assert_eq!(r.ack(id, Uuid::new_v4()), None); // not a target
        let due = r.drain_retransmits();
        assert_eq!(due.retransmits.len(), 1);
    }

    #[test]
    fn retransmit_sends_all_addresses_of_unacked_peer() {
        let mut r = ReliabilityManager::new();
        let id = Uuid::new_v4();
        let peer_a = Uuid::new_v4();
        let peer_b = Uuid::new_v4();
        r.track(
            id,
            vec![0],
            vec![
                peer_target(peer_a, &[1, 2]), // two addresses
                peer_target(peer_b, &[3]),
            ],
        );
        r.ack(id, peer_a); // peer_a acked; peer_b still pending
        let due = r.drain_retransmits();
        assert_eq!(due.retransmits.len(), 1);
        let pending_addrs = &due.retransmits[0].2;
        assert_eq!(pending_addrs.len(), 1);
        assert_eq!(pending_addrs[0], addr(3)); // only peer_b's address
    }

    fn test_state() -> AppState {
        AppState::new(crate::state::Config {
            default_channels: Vec::new(),
            ..crate::state::Config::default()
        })
    }

    /// Returns the peer_id of the offline peer (needed for track_critical tests).
    async fn add_offline_peer(state: &AppState, address: &str) -> Uuid {
        let id = Uuid::new_v4();
        state
            .record_sighting(
                crate::state::PeerSighting::Presence(crate::osc::types::PeerPresence {
                    peer_id: id,
                    peer_name: "offline-peer".into(),
                    channels: Vec::new(),
                    role: None,
                    timestamp: chrono::Utc::now(),
                }),
                address.to_string(),
                9000,
            )
            .await;
        state.mark_peer_offline(id).await;
        id
    }

    #[tokio::test]
    async fn track_critical_filters_out_offline_targets() {
        let state = test_state();
        let offline_id = add_offline_peer(&state, "10.0.0.1").await;
        let reliability = Mutex::new(ReliabilityManager::new());
        let id = Uuid::new_v4();
        let online_id = Uuid::new_v4();

        let tracked = track_critical(
            &reliability,
            &state,
            7,
            id,
            vec![0],
            vec![(offline_id, vec![addr(1)]), (online_id, vec![addr(2)])],
        )
        .await;

        assert_eq!(tracked, 1); // only the online target
        let mut r = reliability.lock().await;
        assert_eq!(r.ack(id, online_id), Some((1, 1))); // tracked
        assert_eq!(r.ack(id, offline_id), None); // never tracked — filtered out
    }

    #[tokio::test]
    async fn track_critical_tracks_nothing_when_every_target_is_offline() {
        let state = test_state();
        let offline_id = add_offline_peer(&state, "10.0.0.1").await;
        let reliability = Mutex::new(ReliabilityManager::new());

        let tracked = track_critical(
            &reliability,
            &state,
            7,
            Uuid::new_v4(),
            vec![0],
            vec![(offline_id, vec![addr(1)])],
        )
        .await;

        assert_eq!(tracked, 0);
    }

    #[tokio::test]
    async fn report_delivery_failure_resolves_peer_names_and_publishes_failed_event() {
        let state = test_state();
        let offline_id = add_offline_peer(&state, "10.0.0.1").await;
        let mut events = state.subscribe();
        let id = Uuid::new_v4();

        report_delivery_failure(&state, id, 1, 2, &[offline_id]).await;

        let event = events.recv().await.unwrap();
        match event {
            AppEvent::MessageDelivery {
                message_id,
                delivered,
                total,
                failed,
                failed_peers,
            } => {
                assert_eq!(message_id, id);
                assert_eq!(delivered, 1);
                assert_eq!(total, 2);
                assert!(failed);
                assert_eq!(failed_peers, vec!["offline-peer".to_string()]);
            }
            other => panic!("expected MessageDelivery, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn spawn_retransmit_loop_resends_an_unacked_critical_message() {
        let state = test_state();
        let reliability = Arc::new(Mutex::new(ReliabilityManager::new()));
        let transport = Arc::new(
            Transport::new(
                &crate::state::Config {
                    osc_port: 0,
                    default_channels: Vec::new(),
                    ..crate::state::Config::default()
                },
                state.clone(),
                Arc::clone(&reliability),
            )
            .await
            .unwrap(),
        );

        // A local UDP socket standing in for the unacked peer — the loop
        // should retransmit to it without any ACK ever arriving.
        let listener = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let listener_addr = listener.local_addr().unwrap();

        reliability.lock().await.track(
            Uuid::new_v4(),
            b"hello".to_vec(),
            vec![(Uuid::new_v4(), vec![listener_addr])],
        );

        let _handle = spawn_retransmit_loop(state, transport, Arc::clone(&reliability));

        let mut buf = [0u8; 16];
        let (n, _) = tokio::time::timeout(
            std::time::Duration::from_secs(2),
            listener.recv_from(&mut buf),
        )
        .await
        .expect("expected a retransmit within 2s")
        .unwrap();
        assert_eq!(&buf[..n], b"hello");
    }
}
