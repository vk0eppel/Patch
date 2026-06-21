//! The recent-message ring buffer, with O(1) dedup.
//!
//! Pure domain logic — no `AppEvent`/broadcast-channel dependency. Per
//! ADR-0003, `AppState` decides what (if anything) to publish based on what
//! [`MessageBuffer::store`] returns; this module just owns the data.

use std::collections::{HashSet, VecDeque};

use tokio::sync::RwLock;
use uuid::Uuid;

use crate::osc::types::PatchMessage;

const MAX_BUFFER: usize = 500;

/// Bounded message ring buffer with O(1) dedup.
///
/// `queue` keeps insertion order (and is popped from the front on overflow);
/// `seen` mirrors the message IDs currently in `queue` so duplicates — our own
/// broadcast echoes back over UDP — are rejected without scanning the queue.
#[derive(Debug, Default)]
pub(crate) struct MessageBuffer {
    inner: RwLock<Inner>,
}

#[derive(Debug, Default)]
struct Inner {
    queue: VecDeque<PatchMessage>,
    seen: HashSet<Uuid>,
}

impl MessageBuffer {
    /// Stores `msg` unless its id was already seen (a UDP echo of our own
    /// broadcast). Returns whether it was actually stored — the caller
    /// publishes `AppEvent::MessageReceived` only on `true`.
    pub(crate) async fn store(&self, msg: PatchMessage) -> bool {
        let mut buf = self.inner.write().await;
        if !buf.seen.insert(msg.message_id) {
            return false;
        }
        if buf.queue.len() >= MAX_BUFFER {
            if let Some(old) = buf.queue.pop_front() {
                buf.seen.remove(&old.message_id);
            }
        }
        buf.queue.push_back(msg);
        true
    }

    /// Clears messages for a specific channel, or all channels when
    /// `channel_id` is `None`. Either way, the dedup set is rebuilt so a
    /// cleared id can be received again.
    pub(crate) async fn clear(&self, channel_id: Option<&str>) {
        let mut buf = self.inner.write().await;
        match channel_id {
            Some(id) => {
                buf.queue.retain(|m| m.channel_id != id);
                buf.seen = buf.queue.iter().map(|m| m.message_id).collect();
            }
            None => {
                buf.queue.clear();
                buf.seen.clear();
            }
        }
    }

    pub(crate) async fn get_all(&self) -> Vec<PatchMessage> {
        self.inner.read().await.queue.iter().cloned().collect()
    }

    pub(crate) async fn get(&self, channel_id: &str, limit: usize) -> Vec<PatchMessage> {
        let buf = self.inner.read().await;
        buf.queue
            .iter()
            .filter(|m| m.channel_id == channel_id)
            .rev()
            .take(limit)
            .cloned()
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::osc::types::Priority;

    fn msg(channel: &str) -> PatchMessage {
        PatchMessage::new(Uuid::new_v4(), "tester", channel, Priority::Info, "hi")
    }

    #[tokio::test]
    async fn store_dedups_by_id() {
        let buf = MessageBuffer::default();
        let m = msg("rf");
        assert!(buf.store(m.clone()).await);
        assert!(!buf.store(m.clone()).await); // same id again (our UDP echo)
        assert_eq!(buf.get_all().await.len(), 1);
    }

    #[tokio::test]
    async fn store_evicts_oldest_on_overflow() {
        let buf = MessageBuffer::default();
        let first = msg("rf");
        buf.store(first.clone()).await;
        for _ in 0..MAX_BUFFER {
            buf.store(msg("rf")).await;
        }
        let all = buf.get_all().await;
        assert_eq!(all.len(), MAX_BUFFER);
        assert!(all.iter().all(|m| m.message_id != first.message_id)); // front evicted
                                                                       // Eviction also drops the id from the dedup set, so it can re-arrive.
        buf.store(first.clone()).await;
        assert!(buf
            .get_all()
            .await
            .iter()
            .any(|m| m.message_id == first.message_id));
    }

    #[tokio::test]
    async fn clear_all_allows_re_receive() {
        let buf = MessageBuffer::default();
        let m = msg("rf");
        buf.store(m.clone()).await;
        buf.clear(None).await;
        assert_eq!(buf.get_all().await.len(), 0);
        assert!(buf.store(m.clone()).await); // same id, accepted after clear
        assert_eq!(buf.get_all().await.len(), 1);
    }

    #[tokio::test]
    async fn clear_by_channel_rebuilds_dedup_set() {
        let buf = MessageBuffer::default();
        let rf = msg("rf");
        let audio = msg("audio");
        buf.store(rf.clone()).await;
        buf.store(audio.clone()).await;
        buf.clear(Some("rf")).await;
        let remaining = buf.get_all().await;
        assert_eq!(remaining.len(), 1);
        assert_eq!(remaining[0].channel_id, "audio");
        assert!(buf.store(rf.clone()).await); // rf id was cleared from `seen`
        assert_eq!(buf.get_all().await.len(), 2);
    }

    #[tokio::test]
    async fn get_filters_by_channel_and_limits_to_most_recent() {
        let buf = MessageBuffer::default();
        for _ in 0..3 {
            buf.store(msg("rf")).await;
        }
        buf.store(msg("audio")).await;
        let got = buf.get("rf", 2).await;
        assert_eq!(got.len(), 2);
        assert!(got.iter().all(|m| m.channel_id == "rf"));
    }
}
