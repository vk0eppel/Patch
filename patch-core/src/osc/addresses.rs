//! Canonical OSC address constants for the PATCH namespace.

// Core messaging
pub const ACK: &str = "/patch/ack";
/// Presence/heartbeat beacon — the single address used for discovery, liveness,
/// and external-tool announce (broadcast each heartbeat + unicast to known peers).
pub const PRESENCE: &str = "/patch/presence";
/// Departure announcement broadcast on graceful shutdown so peers drop us promptly.
pub const BYE: &str = "/patch/bye";
/// Direct (peer-to-peer) message — unicast to one peer. Args include a target_id
/// so the recipient confirms it's addressed to them. Stored under a `dm:{peer}` key.
pub const DM: &str = "/patch/dm";
/// Request a peer's full channel layout (unicast). Arg: requester peer_id.
pub const CHANNELS_REQUEST: &str = "/patch/channels/request";
/// Reply to a channels request (unicast). Args: peer_id, peer_name, channels JSON.
pub const CHANNELS_ANNOUNCE: &str = "/patch/channels/announce";

// Flash / page (per-channel suffix appended at runtime)
pub const CHANNEL_FLASH_PREFIX: &str = "/patch/channel";

/// Build a per-channel message address: `/patch/channel/{channel_id}/message`
pub fn channel_message(channel_id: &str) -> String {
    format!("{}/{}/message", CHANNEL_FLASH_PREFIX, channel_id)
}

/// Build a per-channel flash address: `/patch/channel/{channel_id}/flash`
pub fn channel_flash(channel_id: &str) -> String {
    format!("{}/{}/flash", CHANNEL_FLASH_PREFIX, channel_id)
}
