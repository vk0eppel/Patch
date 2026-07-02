//! The Direct Message thread key.
//!
//! A DM thread is buffered locally under `dm:{other_peer_id}` — each side keys
//! the thread by the *other* Operator's Peer. The `dm:` prefix never crosses
//! the wire: the sender addresses the target peer directly, and the receiver
//! derives its own key from the sender id ([`DmThreadKey::for_peer`]). Because
//! `:` is outside the channel-id slug charset, a DM key can never collide with
//! (or be smuggled in as) a Channel id — `valid_channel_id` rejects it.

use uuid::Uuid;

/// Local buffer key for a Direct Message thread with one Peer.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) struct DmThreadKey(Uuid);

impl DmThreadKey {
    /// The thread with `other_peer` — always keyed by the *other* side.
    pub(crate) fn for_peer(other_peer: Uuid) -> Self {
        Self(other_peer)
    }

    /// The `dm:{peer_id}` form used as the local buffer/channel key.
    pub(crate) fn local_key(&self) -> String {
        format!("dm:{}", self.0)
    }
}

impl std::fmt::Display for DmThreadKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.local_key())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn local_key_carries_the_dm_prefix_and_peer_id() {
        let peer = Uuid::parse_str("6ba7b810-9dad-11d1-80b4-00c04fd430c8").unwrap();
        let key = DmThreadKey::for_peer(peer);
        assert_eq!(key.local_key(), format!("dm:{peer}"));
        assert_eq!(key.to_string(), key.local_key());
    }

    #[test]
    fn a_dm_key_is_never_a_valid_channel_id() {
        let peer = Uuid::parse_str("6ba7b810-9dad-11d1-80b4-00c04fd430c8").unwrap();
        let key = DmThreadKey::for_peer(peer);
        assert!(!crate::osc::codec::valid_channel_id(&key.local_key()));
    }
}
