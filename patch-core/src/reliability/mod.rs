//! Reliability layer — ACK tracking and retransmission for critical messages.
//!
//! Only `Priority::Critical` messages require ACKs. Info/Warning messages are
//! fire-and-forget (with optional best-effort retransmit).

use std::collections::HashMap;
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
    acked_by: Vec<Uuid>,
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
                acked_by: Vec::new(),
                retries: 0,
            },
        );
    }

    /// Record an ACK from a peer. Returns true if all targets have ACKed.
    pub fn ack(&mut self, message_id: Uuid, peer_id: Uuid) -> bool {
        if let Some(entry) = self.in_flight.get_mut(&message_id) {
            if !entry.acked_by.contains(&peer_id) {
                entry.acked_by.push(peer_id);
            }
            if entry.acked_by.len() >= entry.targets.len() {
                self.in_flight.remove(&message_id);
                return true;
            }
        }
        false
    }

    /// Returns messages that need retransmission (increments retry counter).
    /// Call periodically from the transport layer.
    pub fn drain_retransmits(&mut self) -> Vec<(Uuid, Vec<u8>, Vec<SocketAddr>)> {
        let mut to_retransmit = Vec::new();
        let mut to_drop = Vec::new();

        for (id, entry) in self.in_flight.iter_mut() {
            entry.retries += 1;
            if entry.retries > MAX_RETRIES {
                warn!("Message {} exceeded max retries — dropping", id);
                to_drop.push(*id);
            } else {
                debug!("Retransmitting {} (attempt {})", id, entry.retries);
                to_retransmit.push((*id, entry.bytes.clone(), entry.targets.clone()));
            }
        }

        for id in to_drop {
            self.in_flight.remove(&id);
        }

        to_retransmit
    }
}

/// Spawn a background retransmit poller.
/// `send_fn` is called with (bytes, addr) for each retransmit needed.
pub async fn retransmit_delay(retry: u32) {
    let delay = RETRY_BASE_MS * (1 << retry.min(6));
    sleep(Duration::from_millis(delay)).await;
}
