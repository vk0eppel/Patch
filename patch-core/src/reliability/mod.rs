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

use tracing::{debug, warn};
use uuid::Uuid;

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
    targets: Vec<SocketAddr>,
    /// Target addresses that have ACKed so far.
    acked: HashSet<SocketAddr>,
    retries: u32,
    /// Poll ticks remaining until the next retransmit attempt (0 = due now).
    /// Set to `2^retries` after each attempt for exponential backoff.
    ticks_until_retry: u32,
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
                ticks_until_retry: 0, // first retransmit is due on the next tick
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
            // Exponential backoff — only attempt once the per-entry countdown
            // elapses; other ticks just decrement it.
            if entry.ticks_until_retry > 0 {
                entry.ticks_until_retry -= 1;
                continue;
            }

            let unacked: Vec<SocketAddr> = entry
                .targets
                .iter()
                .filter(|t| !entry.acked.contains(t))
                .copied()
                .collect();
            if unacked.is_empty() {
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
            // Schedule the next attempt: 2, 4, 8, 16, 32 ticks (capped).
            entry.ticks_until_retry = 1u32 << entry.retries.min(6);
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
    fn retransmit_uses_exponential_backoff_spacing() {
        let mut r = ReliabilityManager::new();
        let id = Uuid::new_v4();
        r.track(id, vec![0], vec![addr(1)]);
        // First attempt is due immediately; the next is scheduled 2 ticks out,
        // so the two intervening drains are quiet before attempt 2 fires.
        assert_eq!(r.drain_retransmits().retransmits.len(), 1); // attempt 1
        assert!(r.drain_retransmits().retransmits.is_empty()); // backoff tick 1/2
        assert!(r.drain_retransmits().retransmits.is_empty()); // backoff tick 2/2
        assert_eq!(r.drain_retransmits().retransmits.len(), 1); // attempt 2
    }

    #[test]
    fn entry_dropped_after_max_retries_and_reports_failure() {
        let mut r = ReliabilityManager::new();
        let id = Uuid::new_v4();
        r.track(id, vec![0], vec![addr(1), addr(2)]);
        r.ack(id, addr(1)); // one of two acks; addr(2) never will
                            // Drain until the entry exhausts its retries (backoff spaces the attempts,
                            // so this takes more ticks than MAX_RETRIES).
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
        assert_eq!(attempts, MAX_RETRIES as usize); // exactly MAX_RETRIES sends, then failure
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
