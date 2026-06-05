//! Canonical OSC address constants for the PATCH namespace.

// Core messaging
pub const ACK: &str = "/patch/ack";
/// Presence/heartbeat beacon — the single address used for discovery, liveness,
/// and external-tool announce (broadcast each heartbeat + unicast to known peers).
pub const PRESENCE: &str = "/patch/presence";
/// Departure announcement broadcast on graceful shutdown so peers drop us promptly.
pub const BYE: &str = "/patch/bye";

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
