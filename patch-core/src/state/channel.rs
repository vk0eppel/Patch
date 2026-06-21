use std::net::IpAddr;

use serde::{Deserialize, Serialize};

use crate::osc::types::OscArgKind;

fn default_true() -> bool {
    true
}

/// A logical communication channel.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Channel {
    /// Stable slug used in OSC addresses (e.g. "rf", "foh").
    pub id: String,
    /// Human-readable display name shown in the UI.
    pub display_name: String,
    /// Hex colour for UI differentiation (e.g. "#E53935").
    pub color: String,
    /// Pre-configured macro messages for this channel.
    pub macros: Vec<MacroMessage>,
    /// Flash this channel's message box when a critical (priority 3) message arrives.
    #[serde(default = "default_true")]
    pub flash_on_critical: bool,
    /// Flash this channel's message box on every incoming message.
    #[serde(default)]
    pub flash_on_message: bool,
    /// Per-channel flash pulse count override. None = use global setting.
    #[serde(default)]
    pub flash_count: Option<u8>,
}

/// True when `id` is legal for a Channel — the OSC-path slug rule
/// (`osc::codec::valid_channel_id`) plus the reserved `__all__` broadcast id.
/// `__all__` is a legal message-routing target (an inbound broadcast must
/// still decode), just never a real Channel a user can create — so this is a
/// stricter check than the wire-level one, not a replacement for it.
///
/// Single source of truth for "is this Channel id legal": [`Channel::new`]
/// calls it for the one path that constructs a `Channel` from a raw id
/// (`api::upsert_channel`'s FFI argument); every other path validates a
/// `Channel` already built by `serde::Deserialize` (a show file, a peer's
/// `channels_announce`) and calls this directly instead of re-deriving the
/// rule.
pub fn validate_channel_id(id: &str) -> anyhow::Result<()> {
    if id == "__all__" {
        anyhow::bail!("channel id '__all__' is reserved for crew-wide broadcasts");
    }
    if !crate::osc::codec::valid_channel_id(id) {
        anyhow::bail!(
            "channel id '{}' is invalid — use only lowercase letters, digits, _ or - (≤64 chars)",
            id
        );
    }
    Ok(())
}

impl Channel {
    pub fn new(
        id: impl Into<String>,
        display_name: impl Into<String>,
        color: impl Into<String>,
    ) -> anyhow::Result<Self> {
        let id = id.into();
        validate_channel_id(&id)?;
        Ok(Self {
            id,
            display_name: display_name.into(),
            color: color.into(),
            macros: Vec::new(),
            flash_on_critical: true,
            flash_on_message: false,
            flash_count: None,
        })
    }
}

/// A one-tap/keyboard macro message.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MacroMessage {
    /// Short label shown on the button (e.g. "HOLD", "CLEAR", "BACK IN 5").
    pub label: String,
    /// The message text that will be sent.
    pub payload: String,
    /// Optional key binding (e.g. "F1", "ctrl+1").
    pub key_binding: Option<String>,
    /// Priority override — defaults to Info.
    pub priority: i32,
    /// Optional MIDI Note number (0–127) that fires this macro. The engine's MIDI
    /// listener fires the macro on its own channel when a Note On for this number
    /// arrives (per-channel macros only).
    #[serde(default)]
    pub midi_note: Option<u8>,
    /// Optional MIDI Control Change number (0–127) that fires this macro (on a CC
    /// value ≥ 64, i.e. a footswitch "press").
    #[serde(default)]
    pub midi_cc: Option<u8>,
    /// Optional outbound OSC target — when the macro fires, Patch *also* sends this
    /// OSC message to external gear, alongside the normal Patch channel message.
    #[serde(default)]
    pub osc: Option<OscTarget>,
}

/// An outbound OSC target attached to a macro (dual action — fired alongside the
/// Patch message). Lets a macro trigger QLab cues, Companion buttons, vMix
/// overlays, etc. from the same button/key/MIDI that messages the crew.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OscTarget {
    /// Destination IP address (e.g. "192.168.1.50").
    pub address: String,
    /// Destination UDP port (e.g. 53000 for QLab).
    pub port: u16,
    /// OSC address path, must start with '/' (e.g. "/cue/1/start").
    pub path: String,
    /// Optional single argument, stored as text regardless of `arg_type` —
    /// parsed into the matching `OscType` (Int/Float/String) when the macro
    /// fires (`osc::codec::build_osc_arg`).
    #[serde(default)]
    pub arg: Option<String>,
    /// How `arg` should be parsed/sent. Defaults to `String` so existing
    /// macros and hand-edited `patch.toml` files without this field keep
    /// behaving exactly as before this field was added.
    #[serde(default)]
    pub arg_type: OscArgKind,
}

/// Single source of truth for "is this OscTarget legal": address parses as an
/// IP, port is non-zero, path is a valid OSC address (starts with '/'), and —
/// when an argument is set — it parses per its declared `arg_type`
/// (`osc::codec::build_osc_arg`).
///
/// Every caller uses this same check, but applies its own policy on top
/// depending on how trustworthy its input is — see ADR-0002. An Operator
/// editing a macro in the UI rejects immediately; loading a local show file
/// rejects the whole file atomically (mirroring `validate_channel_id`);
/// adopting a peer's offered channels over the network drops just the one
/// bad macro and keeps the rest. There is no fallback policy here — that
/// choice belongs to the caller, not to this check.
pub(crate) fn validate_osc_target(t: &OscTarget) -> anyhow::Result<()> {
    t.address
        .parse::<IpAddr>()
        .map_err(|_| anyhow::anyhow!("invalid OSC address '{}'", t.address))?;
    if t.port == 0 {
        anyhow::bail!("OSC port 0 is not valid");
    }
    if !t.path.starts_with('/') {
        anyhow::bail!("OSC path must start with '/'");
    }
    if let Some(arg) = &t.arg {
        crate::osc::codec::build_osc_arg(t.arg_type, arg)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn target(
        address: &str,
        port: u16,
        path: &str,
        arg: Option<&str>,
        arg_type: OscArgKind,
    ) -> OscTarget {
        OscTarget {
            address: address.into(),
            port,
            path: path.into(),
            arg: arg.map(String::from),
            arg_type,
        }
    }

    #[test]
    fn validate_osc_target_accepts_a_fully_valid_target() {
        let t = target(
            "127.0.0.1",
            53000,
            "/cue/1/start",
            Some("3"),
            OscArgKind::Int,
        );
        assert!(validate_osc_target(&t).is_ok());
    }

    #[test]
    fn validate_osc_target_rejects_bad_address() {
        let t = target("not-an-ip", 53000, "/cue/1/start", None, OscArgKind::String);
        assert!(validate_osc_target(&t).is_err());
    }

    #[test]
    fn validate_osc_target_rejects_port_zero() {
        let t = target("127.0.0.1", 0, "/cue/1/start", None, OscArgKind::String);
        assert!(validate_osc_target(&t).is_err());
    }

    #[test]
    fn validate_osc_target_rejects_path_without_leading_slash() {
        let t = target("127.0.0.1", 53000, "cue/1/start", None, OscArgKind::String);
        assert!(validate_osc_target(&t).is_err());
    }

    #[test]
    fn validate_osc_target_rejects_mismatched_arg_type() {
        let t = target(
            "127.0.0.1",
            53000,
            "/cue/1/start",
            Some("loud"),
            OscArgKind::Float,
        );
        assert!(validate_osc_target(&t).is_err());
    }
}
