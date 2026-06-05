//! Reliability layer — ACK tracking and retransmission for critical messages.
//!
//! Only `Priority::Critical` messages require ACKs. Info/Warning messages are
//! fire-and-forget (with optional best-effort retransmit).
//!
//! ACKs are matched by the **source address** of the `/patch/ack` packet, not by
//! the `peer_id` it carries. The targets we track are `SocketAddr`s, and for a
//! synthetic static-peer entry the `peer_id` is a derived UUID that won't match
//! the real sender's id — so addressing is the only thing that lines up on both
//! sides. Everyone binds/sends on the same OSC port, so an ACK's source address
//! equals the target address we unicast to.

use std::collections::{HashMap, HashSet};
use std::net::SocketAddr;
use std::time::Duration;

use tokio::time::sleep;
use tracing::{debug, warn};
use uuid::Uuid;

const MAX_RETRIES: u32 = 5;
const RETRY_BASE_MS: u64 = 100; // doubles each retry (exponential backoff)

/// Entry tracking an in-flight critical message.
#[derive(Debug)]
struct InFlight {
    bytes: Vec<u8>,
    targets: Vec<SocketAddr>,
    /// Target addresses that have ACKed so far.
    acked: HashSet<SocketAddr>,
    retries: u32,
}

/// A critical message that exhausted its retries without every target ACKing.
#[derive(Debug)]
pub struct DeliveryFailure {
    pub message_id: Uuid,
    /// Target addresses that never acknowledged.
    pub unacked: Vec<SocketAddr>,
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
    pub fn track(&mut self, message_id: Uuid, bytes: Vec<u8>, targets: Vec<SocketAddr>) {
        self.in_flight.insert(
            message_id,
            InFlight {
                bytes,
                targets,
                acked: HashSet::new(),
                retries: 0,
            },
        );
    }

    /// Record an ACK received *from* `addr` for `message_id`. Returns
    /// `Some((acked, total))` delivery progress when `addr` is one of the
    /// message's targets — the entry is removed once `acked == total`. Returns
    /// `None` for an unknown message or a stray ACK from a non-target address (a
    /// stray ACK must not trip early completion). Duplicate ACKs from the same
    /// address are idempotent (the acked count doesn't double-increment).
    pub fn ack(&mut self, message_id: Uuid, addr: SocketAddr) -> Option<(u32, u32)> {
        let entry = self.in_flight.get_mut(&message_id)?;
        if !entry.targets.contains(&addr) {
            return None; // stray ACK from a non-target — ignore
        }
        entry.acked.insert(addr);
        let total = entry.targets.len() as u32;
        // `acked` only ever holds target addresses (gated above), so its length
        // is the count of distinct targets that have ACKed.
        let acked = entry.acked.len() as u32;
        if acked >= total {
            self.in_flight.remove(&message_id);
        }
        Some((acked, total))
    }

    /// Advance retransmit state one tick. Returns the messages that still need
    /// re-sending — each paired with **only the targets that haven't ACKed yet**
    /// (a critical sent to N peers where some already ACKed is re-sent only to
    /// the stragglers) — plus any entries that exceeded `MAX_RETRIES` this tick,
    /// reported as `failures` (with the addresses that never ACKed) so the caller
    /// can tell the operator a critical wasn't delivered. Call periodically.
    pub fn drain_retransmits(&mut self) -> DrainResult {
        let mut result = DrainResult::default();
        let mut to_drop = Vec::new();

        for (id, entry) in self.in_flight.iter_mut() {
            let unacked: Vec<SocketAddr> = entry
                .targets
                .iter()
                .filter(|t| !entry.acked.contains(t))
                .copied()
                .collect();

            entry.retries += 1;
            if entry.retries > MAX_RETRIES {
                warn!(
                    "Message {} exceeded max retries — {} peer(s) never ACKed",
                    id,
                    unacked.len()
                );
                result.failures.push(DeliveryFailure {
                    message_id: *id,
                    unacked,
                    acked: entry.acked.len() as u32,
                    total: entry.targets.len() as u32,
                });
                to_drop.push(*id);
                continue;
            }
            if unacked.is_empty() {
                // Fully acked — `ack()` normally removes the entry, but clear it
                // defensively here too rather than spin on an empty target set.
                to_drop.push(*id);
                continue;
            }
            debug!(
                "Retransmitting {} to {} pending target(s) (attempt {})",
                id,
                unacked.len(),
                entry.retries
            );
            result.retransmits.push((*id, entry.bytes.clone(), unacked));
        }

        for id in to_drop {
            self.in_flight.remove(&id);
        }

        result
    }
}

/// Exponential backoff delay for retry `retry` (100ms → 200ms → 400ms → …).
/// Helper for a future per-message backoff curve; the current poller uses a
/// fixed tick (see TODO.md → reliability backoff).
pub async fn retransmit_delay(retry: u32) {
    let delay = RETRY_BASE_MS * (1 << retry.min(6));
    sleep(Duration::from_millis(delay)).await;
}

#[cfg(test)]
mod tests {
    use super::*;

    fn addr(n: u8) -> SocketAddr {
        format!("10.0.0.{}:9000", n).parse().unwrap()
    }

    #[test]
    fn full_ack_completes_and_clears() {
        let mut r = ReliabilityManager::new();
        let id = Uuid::new_v4();
        r.track(id, vec![1, 2, 3], vec![addr(1), addr(2)]);
        assert_eq!(r.ack(id, addr(1)), Some((1, 2))); // progress
        assert_eq!(r.ack(id, addr(2)), Some((2, 2))); // all acked — completes
                                                      // Entry cleared — nothing left to retransmit.
        assert!(r.drain_retransmits().retransmits.is_empty());
    }

    #[test]
    fn stray_ack_from_non_target_is_ignored() {
        let mut r = ReliabilityManager::new();
        let id = Uuid::new_v4();
        r.track(id, vec![0], vec![addr(1)]);
        assert_eq!(r.ack(id, addr(9)), None); // never a target — ignored
        let due = r.drain_retransmits();
        assert_eq!(due.retransmits.len(), 1);
        assert_eq!(due.retransmits[0].2, vec![addr(1)]); // still pending to the real target
    }

    #[test]
    fn retransmit_targets_exclude_acked_addresses() {
        let mut r = ReliabilityManager::new();
        let id = Uuid::new_v4();
        r.track(id, vec![0], vec![addr(1), addr(2), addr(3)]);
        assert_eq!(r.ack(id, addr(2)), Some((1, 3))); // 2 acked; 1 and 3 still pending
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
        r.track(id, vec![0], vec![addr(1), addr(2)]);
        assert_eq!(r.ack(id, addr(1)), Some((1, 2)));
        assert_eq!(r.ack(id, addr(1)), Some((1, 2))); // same address — count unchanged
        assert_eq!(r.ack(id, addr(2)), Some((2, 2))); // the other target completes it
    }

    #[test]
    fn entry_dropped_after_max_retries_and_reports_failure() {
        let mut r = ReliabilityManager::new();
        let id = Uuid::new_v4();
        r.track(id, vec![0], vec![addr(1), addr(2)]);
        r.ack(id, addr(1)); // one of two acks; addr(2) never will
                            // The first MAX_RETRIES drains surface it for retransmit; the next reports failure.
        for _ in 0..MAX_RETRIES {
            assert_eq!(r.drain_retransmits().retransmits.len(), 1);
        }
        let due = r.drain_retransmits();
        assert!(due.retransmits.is_empty());
        assert_eq!(due.failures.len(), 1);
        let f = &due.failures[0];
        assert_eq!(f.message_id, id);
        assert_eq!(f.acked, 1);
        assert_eq!(f.total, 2);
        assert_eq!(f.unacked, vec![addr(2)]); // the straggler is named
        assert_eq!(r.ack(id, addr(2)), None); // a late ACK now finds nothing
    }

    #[test]
    fn ack_for_unknown_message_is_none() {
        let mut r = ReliabilityManager::new();
        assert_eq!(r.ack(Uuid::new_v4(), addr(1)), None);
    }
}
