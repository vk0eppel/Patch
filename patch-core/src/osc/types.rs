//! PATCH domain types — kept OSC-agnostic so they can be serialised
//! over the bridge or stored locally without pulling in `rosc`.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// Priority levels for PATCH messages.
///
/// Serialized as an integer (0–3) so the Flutter bridge and OSC codec
/// both see a plain number rather than a variant name string.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
#[repr(i32)]
pub enum Priority {
    Debug = 0,
    Info = 1,
    Warning = 2,
    Critical = 3,
}

impl TryFrom<i32> for Priority {
    type Error = anyhow::Error;
    fn try_from(v: i32) -> Result<Self, Self::Error> {
        match v {
            0 => Ok(Self::Debug),
            1 => Ok(Self::Info),
            2 => Ok(Self::Warning),
            3 => Ok(Self::Critical),
            _ => anyhow::bail!("Unknown priority value: {}", v),
        }
    }
}

impl serde::Serialize for Priority {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_i32(*self as i32)
    }
}

impl<'de> serde::Deserialize<'de> for Priority {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let v = i32::deserialize(d)?;
        Priority::try_from(v).map_err(serde::de::Error::custom)
    }
}

/// A single PATCH message — maps 1-to-1 to the `/patch/message` OSC packet.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PatchMessage {
    /// UUID v4 — unique per message, used for ACK and dedup.
    pub message_id: Uuid,
    /// Stable UUID for the sender (persisted across sessions).
    pub sender_id: Uuid,
    /// Human-readable display name for the sender.
    pub sender_name: String,
    /// Stable channel ID (slug, e.g. "rf", "foh").
    pub channel_id: String,
    /// UTC timestamp when the message was created.
    pub timestamp: DateTime<Utc>,
    pub priority: Priority,
    /// The actual message text or shortcut payload.
    pub payload: String,
}

impl PatchMessage {
    pub fn new(
        sender_id: Uuid,
        sender_name: impl Into<String>,
        channel_id: impl Into<String>,
        priority: Priority,
        payload: impl Into<String>,
    ) -> Self {
        Self {
            message_id: Uuid::new_v4(),
            sender_id,
            sender_name: sender_name.into(),
            channel_id: channel_id.into(),
            timestamp: Utc::now(),
            priority,
            payload: payload.into(),
        }
    }

    pub fn is_critical(&self) -> bool {
        self.priority == Priority::Critical
    }
}

/// A presence/heartbeat announcement.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PeerPresence {
    pub peer_id: Uuid,
    pub peer_name: String,
    /// Which channels this peer is currently subscribed to.
    pub channels: Vec<String>,
    pub timestamp: DateTime<Utc>,
}

/// A flash/page event targeting a specific channel.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChannelFlash {
    pub channel_id: String,
    pub sender_id: Uuid,
    pub sender_name: String,
}
