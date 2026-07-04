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

/// Type of a single outbound OSC macro argument — selects which `rosc::OscType`
/// variant the macro's stored `arg` string is parsed into when it fires.
/// Variant names mirror `rosc::OscType` exactly (`Int`/`Float`/`String`); only
/// the 32-bit `Int`/`Float` wire types are supported, not `Long`/`Double`, since
/// those are the OSC types most consoles/show-control gear expect.
///
/// Serialized as a plain string (`"Float"`, not an int code) — unlike
/// `Priority`, this never travels over the wire itself, it only selects how
/// `arg` gets encoded, so there's no compactness reason to int-code it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub enum OscArgKind {
    #[default]
    String,
    Int,
    Float,
}

/// A single PATCH message — maps 1-to-1 to the `/patch/message` OSC packet.
/// Flash log entries reuse this type with `is_flash: true` so they flow
/// through the same message buffer and bridge path as regular messages.
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
    /// True for synthesized Flash log entries (never for wire messages).
    pub is_flash: bool,
    /// Display name of the peer that sent the Flash (Flash log entries only).
    pub flash_sender_name: Option<String>,
    /// Production role of the peer that sent the Flash (Flash log entries only).
    pub flash_sender_role: Option<String>,
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
            is_flash: false,
            flash_sender_name: None,
            flash_sender_role: None,
        }
    }

    /// Synthesize a Flash log entry for a received channel Flash.
    /// Stored in the message buffer so the message thread can display
    /// "Name (Role) flashed". Never sent over the wire.
    ///
    /// `message_id` and `timestamp` come from the Flash packet itself: the id
    /// so multi-path copies dedup to one entry, the timestamp so the entry
    /// reads on the sender's clock like every other message (display only —
    /// it never feeds liveness, per ERRORS.md).
    pub fn new_flash_log(
        message_id: Uuid,
        sender_id: Uuid,
        sender_name: impl Into<String>,
        sender_role: Option<String>,
        channel_id: impl Into<String>,
        timestamp: DateTime<Utc>,
    ) -> Self {
        let name: String = sender_name.into();
        Self {
            message_id,
            sender_id,
            sender_name: name.clone(),
            channel_id: channel_id.into(),
            timestamp,
            priority: Priority::Info,
            payload: String::new(),
            is_flash: true,
            flash_sender_name: Some(name),
            flash_sender_role: sender_role,
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
    /// Optional self-assigned production role (free text, e.g. "FOH", "PM").
    /// `None` when unset or when received from an older peer (4-arg presence).
    pub role: Option<String>,
    pub timestamp: DateTime<Utc>,
}

/// A flash/page event targeting a specific channel.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChannelFlash {
    pub channel_id: String,
    pub sender_id: Uuid,
    pub sender_name: String,
}
