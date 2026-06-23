use std::collections::HashMap;
use std::net::IpAddr;

use serde::{Deserialize, Serialize};
use tokio::sync::RwLock;

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

/// Validates every channel id and every macro's OSC target up front, before
/// any mutation — used by both `apply_show_file_full` and `apply_show_file`
/// to reject a malformed show file atomically (a single bad entry can't
/// half-apply). Shared so the two callers can't drift on the rule.
pub(crate) fn validate_show_file_channels(channels: &[Channel]) -> anyhow::Result<()> {
    for ch in channels {
        validate_channel_id(&ch.id).map_err(|e| {
            anyhow::anyhow!("show file contains invalid channel id {:?} — {}", ch.id, e)
        })?;
        for m in &ch.macros {
            if let Some(osc) = &m.osc {
                validate_osc_target(osc).map_err(|e| {
                    anyhow::anyhow!(
                        "show file macro {:?} on channel {:?} has an invalid OSC target — {}",
                        m.label,
                        ch.id,
                        e
                    )
                })?;
            }
        }
    }
    Ok(())
}

/// Drops any macro in `macros` whose OSC target fails [`validate_osc_target`],
/// logging a warning for each. `context` identifies where these macros came
/// from (a channel id, or "global macros") for the log line.
///
/// Load-time sanitization for a hand-edited `patch.toml` — the 4th OSC-target
/// trust level beyond ADR-0002's three (see ADR-0006): unlike a show file
/// (`validate_show_file_channels`, atomic reject) or a peer announce
/// (`ChannelRegistry::merge`, also drop-and-warn), this runs at process
/// startup with no operator present to retry, so it must never block launch —
/// drop-and-warn, same policy as the peer-announce path.
pub(crate) fn sanitize_loaded_macros(macros: &mut Vec<MacroMessage>, context: &str) {
    macros.retain(|m| {
        let Some(osc) = &m.osc else { return true };
        match validate_osc_target(osc) {
            Ok(()) => true,
            Err(e) => {
                tracing::warn!(
                    "patch.toml: dropping macro {:?} ({}) at load — invalid OSC target: {}",
                    m.label,
                    context,
                    e
                );
                false
            }
        }
    });
}

/// Applies [`sanitize_loaded_macros`] to every channel's macro list —
/// load-time sanitization for `Config::default_channels` (ADR-0006).
pub(crate) fn sanitize_loaded_channels(channels: &mut [Channel]) {
    for ch in channels.iter_mut() {
        sanitize_loaded_macros(&mut ch.macros, &format!("channel {:?}", ch.id));
    }
}

/// Pure channel/macro-domain logic — no `AppEvent`/broadcast-channel
/// dependency, and no knowledge of `Config`. Per ADR-0003, cross-domain
/// orchestration (persisting a channel snapshot into `Config`, reading
/// `Config`'s flash defaults for `merge`) is owned by `AppState`, which
/// passes in whatever this registry needs as plain parameters.
#[derive(Debug, Default)]
pub(crate) struct ChannelRegistry {
    channels: RwLock<HashMap<String, Channel>>,
}

impl ChannelRegistry {
    /// Seed the registry with an initial set of channels (e.g. from loaded
    /// config at startup). Sync because `AppState::new` is sync.
    pub(crate) fn seeded(channels: Vec<Channel>) -> Self {
        let map = channels.into_iter().map(|ch| (ch.id.clone(), ch)).collect();
        Self {
            channels: RwLock::new(map),
        }
    }

    pub(crate) async fn list(&self) -> Vec<Channel> {
        let mut channels: Vec<_> = self.channels.read().await.values().cloned().collect();
        channels.sort_by(|a, b| a.display_name.cmp(&b.display_name));
        channels
    }

    pub(crate) async fn upsert(&self, ch: Channel) {
        self.channels.write().await.insert(ch.id.clone(), ch);
    }

    pub(crate) async fn delete(&self, channel_id: &str) {
        self.channels.write().await.remove(channel_id);
    }

    /// Replace every channel with `channels` (used by `apply_show_file_full`/
    /// `apply_show_file` after `validate_show_file_channels` has passed).
    pub(crate) async fn replace_all(&self, channels: Vec<Channel>) {
        let mut map = self.channels.write().await;
        map.clear();
        for ch in channels {
            map.insert(ch.id.clone(), ch);
        }
    }

    /// Merge incoming channels, **adding only ids not already present** —
    /// never overwrites an existing channel's colour/macros, never deletes.
    /// Each id is validated against the OSC slug rule and the reserved
    /// `__all__` id is skipped (this is untrusted network input). Adopts
    /// **structure only**: behavioural flash flags are reset to
    /// `flash_on_critical`/`flash_on_message` (the local machine's config
    /// defaults, passed in by the caller — see ADR-0003) rather than
    /// inheriting the source peer's. A macro with an invalid OSC target is
    /// dropped individually rather than rejecting the whole channel (ADR-0002
    /// — untrusted peer input gets the lenient policy). Returns the number of
    /// channels actually added.
    pub(crate) async fn merge(
        &self,
        channels: Vec<Channel>,
        flash_on_critical: bool,
        flash_on_message: bool,
    ) -> usize {
        let mut added = 0usize;
        let mut map = self.channels.write().await;
        for mut ch in channels {
            if let Err(e) = validate_channel_id(&ch.id) {
                tracing::warn!(
                    "merge_channels: skipping invalid/reserved id {:?}: {}",
                    ch.id,
                    e
                );
                continue;
            }
            if map.contains_key(&ch.id) {
                continue; // keep the existing channel untouched
            }
            ch.flash_on_critical = flash_on_critical;
            ch.flash_on_message = flash_on_message;
            ch.flash_count = None;
            ch.macros.retain(|m| {
                let Some(osc) = &m.osc else { return true };
                match validate_osc_target(osc) {
                    Ok(()) => true,
                    Err(e) => {
                        tracing::warn!(
                            "merge_channels: dropping macro {:?} on channel {:?} — invalid OSC target: {}",
                            m.label,
                            ch.id,
                            e
                        );
                        false
                    }
                }
            });
            map.insert(ch.id.clone(), ch);
            added += 1;
        }
        added
    }

    /// Update per-channel flash flags. `None` means "leave unchanged".
    pub(crate) async fn set_flash(
        &self,
        channel_id: &str,
        flash_on_critical: Option<bool>,
        flash_on_message: Option<bool>,
        flash_count: Option<u8>,
    ) -> anyhow::Result<()> {
        let mut channels = self.channels.write().await;
        let ch = channels
            .get_mut(channel_id)
            .ok_or_else(|| anyhow::anyhow!("Channel '{}' not found", channel_id))?;
        if let Some(v) = flash_on_critical {
            ch.flash_on_critical = v;
        }
        if let Some(v) = flash_on_message {
            ch.flash_on_message = v;
        }
        // None = leave unchanged, Some(0) = clear override (use global),
        // Some(n) = set per-channel override to n.
        if let Some(v) = flash_count {
            ch.flash_count = if v == 0 { None } else { Some(v.clamp(3, 7)) };
        }
        Ok(())
    }

    /// Add or replace a macro on a channel (matched by label).
    pub(crate) async fn upsert_macro(
        &self,
        channel_id: &str,
        macro_msg: MacroMessage,
    ) -> anyhow::Result<()> {
        let mut channels = self.channels.write().await;
        let ch = channels
            .get_mut(channel_id)
            .ok_or_else(|| anyhow::anyhow!("Channel '{}' not found", channel_id))?;
        if let Some(pos) = ch.macros.iter().position(|s| s.label == macro_msg.label) {
            ch.macros[pos] = macro_msg;
        } else {
            ch.macros.push(macro_msg);
        }
        Ok(())
    }

    /// Remove a macro from a channel by label.
    pub(crate) async fn delete_macro(&self, channel_id: &str, label: &str) -> anyhow::Result<()> {
        let mut channels = self.channels.write().await;
        let ch = channels
            .get_mut(channel_id)
            .ok_or_else(|| anyhow::anyhow!("Channel '{}' not found", channel_id))?;
        ch.macros.retain(|s| s.label != label);
        Ok(())
    }

    /// Reorder a channel's macros to match `ordered_labels`.
    ///
    /// Macros are pulled out in the given label order; any macro whose label is
    /// not listed is appended at the end (never dropped), and labels that don't
    /// match a macro are ignored. Labels are unique per channel.
    pub(crate) async fn reorder_macros(
        &self,
        channel_id: &str,
        ordered_labels: Vec<String>,
    ) -> anyhow::Result<()> {
        let mut channels = self.channels.write().await;
        let ch = channels
            .get_mut(channel_id)
            .ok_or_else(|| anyhow::anyhow!("Channel '{}' not found", channel_id))?;
        let mut remaining = std::mem::take(&mut ch.macros);
        let mut reordered = Vec::with_capacity(remaining.len());
        for label in &ordered_labels {
            if let Some(pos) = remaining.iter().position(|m| &m.label == label) {
                reordered.push(remaining.remove(pos));
            }
        }
        reordered.append(&mut remaining);
        ch.macros = reordered;
        Ok(())
    }
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

    // ── validate_show_file_channels ──────────────────────────────────────────

    fn plain_macro(label: &str) -> MacroMessage {
        MacroMessage {
            label: label.into(),
            payload: "go".into(),
            key_binding: None,
            priority: 1,
            midi_note: None,
            midi_cc: None,
            osc: None,
        }
    }

    fn macro_with_osc(label: &str, osc: OscTarget) -> MacroMessage {
        MacroMessage {
            osc: Some(osc),
            ..plain_macro(label)
        }
    }

    fn bad_osc() -> OscTarget {
        target("not-an-ip", 53000, "/cue/1/start", None, OscArgKind::String)
    }

    #[test]
    fn validate_show_file_channels_accepts_valid_channels() {
        let ch = Channel::new("rf", "RF", "#fff").unwrap();
        assert!(validate_show_file_channels(&[ch]).is_ok());
    }

    #[test]
    fn validate_show_file_channels_rejects_invalid_id() {
        let mut ch = Channel::new("rf", "RF", "#fff").unwrap();
        ch.id = "RF/../x".into(); // bypass Channel::new's own validation
        assert!(validate_show_file_channels(&[ch]).is_err());
    }

    #[test]
    fn validate_show_file_channels_rejects_invalid_macro_osc_target() {
        let mut ch = Channel::new("rf", "RF", "#fff").unwrap();
        ch.macros = vec![macro_with_osc("GO", bad_osc())];
        assert!(validate_show_file_channels(&[ch]).is_err());
    }

    // ── sanitize_loaded_macros / sanitize_loaded_channels (ADR-0006) ────────

    #[test]
    fn sanitize_loaded_macros_drops_only_the_invalid_one() {
        let mut macros = vec![plain_macro("GOOD"), macro_with_osc("BAD", bad_osc())];
        sanitize_loaded_macros(&mut macros, "global macros");
        let labels: Vec<_> = macros.iter().map(|m| m.label.clone()).collect();
        assert_eq!(labels, vec!["GOOD"]);
    }

    #[test]
    fn sanitize_loaded_macros_keeps_macros_without_osc() {
        let mut macros = vec![plain_macro("A"), plain_macro("B")];
        sanitize_loaded_macros(&mut macros, "global macros");
        assert_eq!(macros.len(), 2);
    }

    #[test]
    fn sanitize_loaded_channels_drops_only_the_invalid_macro_keeps_the_channel() {
        let mut ch = Channel::new("rf", "RF", "#fff").unwrap();
        ch.macros = vec![plain_macro("GOOD"), macro_with_osc("BAD", bad_osc())];
        let mut channels = vec![ch];
        sanitize_loaded_channels(&mut channels);
        assert_eq!(channels.len(), 1); // the channel itself is never dropped
        let labels: Vec<_> = channels[0].macros.iter().map(|m| m.label.clone()).collect();
        assert_eq!(labels, vec!["GOOD"]);
    }

    // ── ChannelRegistry — direct, no AppState/event bus needed ──────────────

    #[tokio::test]
    async fn upsert_then_list_returns_sorted_by_display_name() {
        let reg = ChannelRegistry::default();
        reg.upsert(Channel::new("b", "Bravo", "#fff").unwrap())
            .await;
        reg.upsert(Channel::new("a", "Alpha", "#fff").unwrap())
            .await;
        let names: Vec<_> = reg
            .list()
            .await
            .into_iter()
            .map(|c| c.display_name)
            .collect();
        assert_eq!(names, vec!["Alpha", "Bravo"]);
    }

    #[tokio::test]
    async fn delete_removes_the_channel() {
        let reg = ChannelRegistry::default();
        reg.upsert(Channel::new("rf", "RF", "#fff").unwrap()).await;
        reg.delete("rf").await;
        assert!(reg.list().await.is_empty());
    }

    #[tokio::test]
    async fn replace_all_clears_existing_channels_first() {
        let reg = ChannelRegistry::default();
        reg.upsert(Channel::new("old", "OLD", "#fff").unwrap())
            .await;
        reg.replace_all(vec![Channel::new("new", "NEW", "#fff").unwrap()])
            .await;
        let ids: Vec<_> = reg.list().await.into_iter().map(|c| c.id).collect();
        assert_eq!(ids, vec!["new"]);
    }

    #[tokio::test]
    async fn merge_skips_invalid_id_and_existing_and_resets_flash_flags() {
        let reg = ChannelRegistry::default();
        let mut existing = Channel::new("rf", "RF", "#000").unwrap();
        existing.macros = vec![plain_macro("KEEP")];
        reg.upsert(existing).await;

        let mut hot = Channel::new("audio", "AUDIO", "#fff").unwrap();
        hot.flash_on_message = true;
        hot.flash_on_critical = false;
        hot.flash_count = Some(7);

        let mut bad_id = Channel::new("audio2", "BAD", "#fff").unwrap();
        bad_id.id = "BAD/../x".into();

        let added = reg
            .merge(
                vec![hot, bad_id, Channel::new("rf", "RF NEW", "#fff").unwrap()],
                true,
                false,
            )
            .await;

        assert_eq!(added, 1); // only "audio"
        let chans = reg.list().await;
        assert!(chans.iter().any(|c| c.id == "audio"));
        assert!(!chans.iter().any(|c| c.id == "BAD/../x"));
        let audio = chans.iter().find(|c| c.id == "audio").unwrap();
        assert!(audio.flash_on_critical); // reset to the passed-in default
        assert!(!audio.flash_on_message);
        assert_eq!(audio.flash_count, None);
        let rf = chans.iter().find(|c| c.id == "rf").unwrap();
        assert_eq!(rf.color, "#000"); // untouched — existing id skipped
        assert_eq!(rf.macros.len(), 1);
    }

    #[tokio::test]
    async fn merge_drops_only_the_macro_with_an_invalid_osc_target() {
        let reg = ChannelRegistry::default();
        let mut incoming = Channel::new("rf", "RF", "#fff").unwrap();
        incoming.macros = vec![plain_macro("GOOD"), macro_with_osc("BAD", bad_osc())];

        let added = reg.merge(vec![incoming], true, false).await;
        assert_eq!(added, 1);
        let labels: Vec<_> = reg.list().await[0]
            .macros
            .iter()
            .map(|m| m.label.clone())
            .collect();
        assert_eq!(labels, vec!["GOOD"]);
    }

    #[tokio::test]
    async fn set_flash_updates_only_the_fields_provided() {
        let reg = ChannelRegistry::default();
        reg.upsert(Channel::new("rf", "RF", "#fff").unwrap()).await;
        reg.set_flash("rf", Some(false), None, Some(5))
            .await
            .unwrap();
        let ch = &reg.list().await[0];
        assert!(!ch.flash_on_critical);
        assert!(!ch.flash_on_message); // untouched (was already false)
        assert_eq!(ch.flash_count, Some(5));
    }

    #[tokio::test]
    async fn set_flash_unknown_channel_errors() {
        let reg = ChannelRegistry::default();
        assert!(reg
            .set_flash("missing", Some(true), None, None)
            .await
            .is_err());
    }

    #[tokio::test]
    async fn upsert_macro_replaces_same_label_appends_otherwise() {
        let reg = ChannelRegistry::default();
        reg.upsert(Channel::new("rf", "RF", "#fff").unwrap()).await;
        reg.upsert_macro("rf", plain_macro("GO")).await.unwrap();
        let mut replaced = plain_macro("GO");
        replaced.payload = "different".into();
        reg.upsert_macro("rf", replaced).await.unwrap();
        let macros = &reg.list().await[0].macros;
        assert_eq!(macros.len(), 1);
        assert_eq!(macros[0].payload, "different");
    }

    #[tokio::test]
    async fn delete_macro_removes_by_label() {
        let reg = ChannelRegistry::default();
        reg.upsert(Channel::new("rf", "RF", "#fff").unwrap()).await;
        reg.upsert_macro("rf", plain_macro("GO")).await.unwrap();
        reg.delete_macro("rf", "GO").await.unwrap();
        assert!(reg.list().await[0].macros.is_empty());
    }

    #[tokio::test]
    async fn reorder_macros_applies_order_and_preserves_unlisted() {
        let reg = ChannelRegistry::default();
        let mut ch = Channel::new("rf", "RF", "#fff").unwrap();
        ch.macros = vec![plain_macro("A"), plain_macro("B"), plain_macro("C")];
        reg.upsert(ch).await;
        reg.reorder_macros("rf", vec!["C".into(), "A".into()])
            .await
            .unwrap();
        let labels: Vec<_> = reg.list().await[0]
            .macros
            .iter()
            .map(|m| m.label.clone())
            .collect();
        assert_eq!(labels, vec!["C", "A", "B"]); // unlisted "B" appended at the end
    }
}
