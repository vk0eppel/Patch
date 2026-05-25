//! Canonical OSC address constants for the PATCH namespace.

// Core messaging
pub const MESSAGE: &str = "/patch/message";
pub const ACK: &str = "/patch/ack";
pub const TYPING: &str = "/patch/typing";
pub const PRESENCE: &str = "/patch/presence";

// System events
pub const SYSTEM_ALERT: &str = "/patch/system/alert";
pub const SYSTEM_STATUS: &str = "/patch/system/status";
pub const SYSTEM_HEARTBEAT: &str = "/patch/system/heartbeat";

// Discovery
pub const DISCOVERY: &str = "/patch/discovery";

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
