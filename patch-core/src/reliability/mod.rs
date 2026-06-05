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

    /// Record an ACK received *from* `addr` for `message_id`. Returns true when
    /// every target address has acknowledged (and the entry is cleared).
    ///
    /// ACKs from an address we didn't send to are ignored — they can't complete
    /// the entry and shouldn't be able to (a stray ACK from a non-target must not
    /// trip early completion). Duplicate ACKs from the same address are idempotent.
    pub fn ack(&mut self, message_id: Uuid, addr: SocketAddr) -> bool {
        if let Some(entry) = self.in_flight.get_mut(&message_id) {
            if !entry.targets.contains(&addr) {
                return false; // stray ACK from a non-target — ignore
            }
            entry.acked.insert(addr);
            if entry.targets.iter().all(|t| entry.acked.contains(t)) {
                self.in_flight.remove(&message_id);
                return true;
            }
        }
        false
    }

    /// Returns messages that still need retransmission, each paired with **only
    /// the targets that haven't ACKed yet** (increments the retry counter). A
    /// message sent to N peers where some have already ACKed is re-sent only to
    /// the stragglers. Entries past `MAX_RETRIES` are dropped. Call periodically.
    pub fn drain_retransmits(&mut self) -> Vec<(Uuid, Vec<u8>, Vec<SocketAddr>)> {
        let mut to_retransmit = Vec::new();
        let mut to_drop = Vec::new();

        for (id, entry) in self.in_flight.iter_mut() {
            entry.retries += 1;
            if entry.retries > MAX_RETRIES {
                warn!("Message {} exceeded max retries — dropping", id);
                to_drop.push(*id);
                continue;
            }
            let pending: Vec<SocketAddr> = entry
                .targets
                .iter()
                .filter(|t| !entry.acked.contains(t))
                .copied()
                .collect();
            if pending.is_empty() {
                // Fully acked — `ack()` normally removes the entry, but clear it
                // defensively here too rather than spin on an empty target set.
                to_drop.push(*id);
                continue;
            }
            debug!(
                "Retransmitting {} to {} pending target(s) (attempt {})",
                id,
                pending.len(),
                entry.retries
            );
            to_retransmit.push((*id, entry.bytes.clone(), pending));
        }

        for id in to_drop {
            self.in_flight.remove(&id);
        }

        to_retransmit
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
        assert!(!r.ack(id, addr(1))); // one of two — not complete
        assert!(r.ack(id, addr(2))); // all targets acked — completes
                                     // Entry cleared — nothing left to retransmit.
        assert!(r.drain_retransmits().is_empty());
    }

    #[test]
    fn stray_ack_from_non_target_is_ignored() {
        let mut r = ReliabilityManager::new();
        let id = Uuid::new_v4();
        r.track(id, vec![0], vec![addr(1)]);
        assert!(!r.ack(id, addr(9))); // never a target — must not complete
        let due = r.drain_retransmits();
        assert_eq!(due.len(), 1);
        assert_eq!(due[0].2, vec![addr(1)]); // still pending to the real target
    }

    #[test]
    fn retransmit_targets_exclude_acked_addresses() {
        let mut r = ReliabilityManager::new();
        let id = Uuid::new_v4();
        r.track(id, vec![0], vec![addr(1), addr(2), addr(3)]);
        assert!(!r.ack(id, addr(2))); // 2 acked; 1 and 3 still pending
        let due = r.drain_retransmits();
        assert_eq!(due.len(), 1);
        let pending = &due[0].2;
        assert!(pending.contains(&addr(1)));
        assert!(pending.contains(&addr(3)));
        assert!(!pending.contains(&addr(2))); // acked — not retransmitted
    }

    #[test]
    fn duplicate_ack_is_idempotent() {
        let mut r = ReliabilityManager::new();
        let id = Uuid::new_v4();
        r.track(id, vec![0], vec![addr(1), addr(2)]);
        assert!(!r.ack(id, addr(1)));
        assert!(!r.ack(id, addr(1))); // same address again — still not complete
        assert!(r.ack(id, addr(2))); // the other target completes it
    }

    #[test]
    fn entry_dropped_after_max_retries() {
        let mut r = ReliabilityManager::new();
        let id = Uuid::new_v4();
        r.track(id, vec![0], vec![addr(1)]);
        // The first MAX_RETRIES drains surface it; the next one drops it.
        for _ in 0..MAX_RETRIES {
            assert_eq!(r.drain_retransmits().len(), 1);
        }
        assert!(r.drain_retransmits().is_empty()); // exceeded — dropped
        assert!(!r.ack(id, addr(1))); // a late ACK now finds nothing
    }

    #[test]
    fn ack_for_unknown_message_is_false() {
        let mut r = ReliabilityManager::new();
        assert!(!r.ack(Uuid::new_v4(), addr(1)));
    }
}
