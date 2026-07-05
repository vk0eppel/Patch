use std::collections::HashMap;
use std::net::IpAddr;
use std::sync::Arc;

use serde::{Deserialize, Serialize};
use tokio::sync::RwLock;

use crate::osc::types::OscArgKind;

use super::config::ConfigStore;

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
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
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
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
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
        anyhow::bail!("OSC path must start with '/': {:?}", t.path);
    }
    if let Some(arg) = &t.arg {
        crate::osc::codec::build_osc_arg(t.arg_type, arg)?;
    }
    Ok(())
}

/// Single source of truth for "does this macro's key/MIDI binding collide
/// with another macro's": true if `candidate` shares a non-empty
/// `key_binding`, `midi_note`, or `midi_cc` with any macro in `existing`.
///
/// Checked across three tiers (caller decides which `existing` set to pass):
/// global-vs-global, a channel's macros against that same channel's other
/// macros, and — deliberately, as of this check's introduction — a
/// per-channel macro against every global macro and vice versa. That last
/// tier used to be left unchecked: a per-channel macro's F-key was documented
/// to win over a global macro's on the same key at fire time, which masked
/// the conflict rather than preventing it. This check now rejects the
/// collision up front instead.
pub(crate) fn validate_binding_unique<'a>(
    candidate: &MacroMessage,
    existing: impl IntoIterator<Item = &'a MacroMessage>,
) -> anyhow::Result<()> {
    for other in existing {
        if let (Some(a), Some(b)) = (&candidate.key_binding, &other.key_binding) {
            if a == b {
                anyhow::bail!(
                    "key binding '{}' is already used by macro '{}'",
                    a,
                    other.label
                );
            }
        }
        if let (Some(a), Some(b)) = (candidate.midi_note, other.midi_note) {
            if a == b {
                anyhow::bail!("MIDI note {} is already used by macro '{}'", a, other.label);
            }
        }
        if let (Some(a), Some(b)) = (candidate.midi_cc, other.midi_cc) {
            if a == b {
                anyhow::bail!("MIDI CC {} is already used by macro '{}'", a, other.label);
            }
        }
    }
    Ok(())
}

/// Resolve a macro upsert's rename-aware match label, matched by
/// `original_label` when given (an edit, possibly renaming) or `macro_msg.label`
/// otherwise (create/no-op rename). Bails if the new label collides with an
/// existing entry in `existing`. Validates the binding against `existing`'s
/// other entries chained with `other_context` (the macros living in the other
/// scope: global macros for a channel-scoped edit, all channels' macros for a
/// global edit). Shared by `ChannelRegistry::upsert_macro` and
/// `AppState::upsert_global_macro` — the two upsert call sites, one per scope.
pub(crate) fn resolve_macro_rename<'a>(
    existing: &'a [MacroMessage],
    original_label: Option<&str>,
    macro_msg: &MacroMessage,
    other_context: impl Iterator<Item = &'a MacroMessage>,
    scope_desc: &str,
) -> anyhow::Result<String> {
    let match_label = original_label.unwrap_or(macro_msg.label.as_str()).to_owned();
    if match_label != macro_msg.label && existing.iter().any(|s| s.label == macro_msg.label) {
        anyhow::bail!("A macro named '{}' already exists {}", macro_msg.label, scope_desc);
    }
    let same_scope_others = existing.iter().filter(|m| m.label != match_label);
    validate_binding_unique(macro_msg, same_scope_others.chain(other_context))?;
    Ok(match_label)
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

/// Clears whichever of `candidate`'s `key_binding`/`midi_note`/`midi_cc`
/// collides with a macro in `existing`, logging a warning per dropped
/// binding and keeping the macro itself — the load-time/peer-trust
/// counterpart to [`validate_binding_unique`]'s reject-outright policy.
/// Re-checks `candidate`'s current field values on every iteration, so a
/// binding already cleared by an earlier collision can't trigger a second,
/// redundant warning.
fn strip_colliding_bindings<'a>(
    candidate: &mut MacroMessage,
    existing: impl IntoIterator<Item = &'a MacroMessage>,
    context: &str,
) {
    for other in existing {
        if candidate.key_binding.is_some() && candidate.key_binding == other.key_binding {
            let dropped = candidate.key_binding.take().unwrap();
            tracing::warn!(
                "{}: dropping key binding '{}' from macro {:?} — already used by macro {:?}",
                context,
                dropped,
                candidate.label,
                other.label
            );
        }
        if candidate.midi_note.is_some() && candidate.midi_note == other.midi_note {
            let dropped = candidate.midi_note.take().unwrap();
            tracing::warn!(
                "{}: dropping MIDI note {} from macro {:?} — already used by macro {:?}",
                context,
                dropped,
                candidate.label,
                other.label
            );
        }
        if candidate.midi_cc.is_some() && candidate.midi_cc == other.midi_cc {
            let dropped = candidate.midi_cc.take().unwrap();
            tracing::warn!(
                "{}: dropping MIDI CC {} from macro {:?} — already used by macro {:?}",
                context,
                dropped,
                candidate.label,
                other.label
            );
        }
    }
}

/// Load-time counterpart to [`validate_binding_unique`]: instead of
/// rejecting, strips just the colliding binding field and keeps every macro
/// (ADR-0002/ADR-0006's drop-and-warn posture — there's no Operator present
/// at process startup, or no single edit to reject, to retry against).
///
/// `global_macros` is finalized first — its own internal collisions resolved
/// in list order, first-listed wins — then each channel's macros are checked
/// against the finalized globals plus that channel's own earlier macros.
/// Two different channels' macros are never compared against each other:
/// only one channel is ever the firing context at a time, so the same
/// binding on two different channels was never a real conflict.
pub(crate) fn sanitize_binding_collisions(
    global_macros: &mut [MacroMessage],
    channels: &mut [Channel],
) {
    let mut accepted_globals: Vec<MacroMessage> = Vec::with_capacity(global_macros.len());
    for m in global_macros.iter_mut() {
        strip_colliding_bindings(m, accepted_globals.iter(), "global macros");
        accepted_globals.push(m.clone());
    }
    for ch in channels.iter_mut() {
        let context = format!("channel {:?}", ch.id);
        let mut accepted_channel: Vec<MacroMessage> = Vec::with_capacity(ch.macros.len());
        for m in ch.macros.iter_mut() {
            strip_colliding_bindings(
                m,
                accepted_globals.iter().chain(accepted_channel.iter()),
                &context,
            );
            accepted_channel.push(m.clone());
        }
    }
}

/// Outcome of considering one offered macro for import from a peer's global
/// macro set (see [`classify_macro_import`]) — the ADR-0002 peer-trust tier.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum MacroImportOutcome {
    /// Every field matches a macro we already have — not added.
    AlreadyHave { label: String },
    /// Added with no conflict.
    Added { msg: MacroMessage },
    /// Added, but a colliding key/MIDI binding was stripped first — the macro
    /// itself still comes through (ADR-0002's drop-and-warn, not exclude).
    AddedBindingDropped { msg: MacroMessage, reason: String },
    /// Dropped entirely — invalid OSC target (ADR-0002 peer-trust policy).
    Skipped { label: String, reason: String },
}

/// Pure classification for importing a peer's offered global macros — used by
/// both `AppState::preview_global_macros` (read-only preview) and
/// `AppState::merge_global_macros` (which applies every `Added`/
/// `AddedBindingDropped` outcome and persists). Processes `offered` in order,
/// each one checked against `existing_globals` plus every macro classified so
/// far in this same call (so two offered macros that collide with *each
/// other* are caught too, not just against what we already had):
///
/// 1. An offered macro that exactly matches (every field) one already in
///    `existing_globals` is `AlreadyHave` — excluded, never re-added.
/// 2. An invalid OSC target (`validate_osc_target`) is `Skipped` outright —
///    same ADR-0002 peer-trust policy as `ChannelRegistry::merge`.
/// 3. A key/MIDI binding collision against any already-accepted global or
///    `existing_channel_macros` (`validate_binding_unique`'s three tiers) is
///    `AddedBindingDropped` — the binding is stripped, the macro still comes
///    through.
/// 4. Otherwise `Added` as-is.
pub(crate) fn classify_macro_import(
    offered: &[MacroMessage],
    existing_globals: &[MacroMessage],
    existing_channel_macros: &[MacroMessage],
) -> Vec<MacroImportOutcome> {
    let mut accepted: Vec<MacroMessage> = existing_globals.to_vec();
    let mut out = Vec::with_capacity(offered.len());
    for m in offered {
        if existing_globals.contains(m) {
            out.push(MacroImportOutcome::AlreadyHave {
                label: m.label.clone(),
            });
            continue;
        }
        if let Some(osc) = &m.osc {
            if let Err(e) = validate_osc_target(osc) {
                out.push(MacroImportOutcome::Skipped {
                    label: m.label.clone(),
                    reason: e.to_string(),
                });
                continue;
            }
        }
        let mut candidate = m.clone();
        let context = format!("peer import of macro {:?}", m.label);
        strip_colliding_bindings(
            &mut candidate,
            accepted.iter().chain(existing_channel_macros.iter()),
            &context,
        );
        if candidate.key_binding != m.key_binding
            || candidate.midi_note != m.midi_note
            || candidate.midi_cc != m.midi_cc
        {
            out.push(MacroImportOutcome::AddedBindingDropped {
                msg: candidate.clone(),
                reason: "key/MIDI binding collided with a macro already on this machine".into(),
            });
        } else {
            out.push(MacroImportOutcome::Added {
                msg: candidate.clone(),
            });
        }
        accepted.push(candidate);
    }
    out
}

/// Channel/macro-domain logic, plus (ADR-0003 amendment — see
/// `docs/adr/0003-appstate-domain-registries.md`) its own persistence:
/// every write auto-persists a channel snapshot into `Config` once
/// `attach_config` has wired up a `ConfigStore`. Reading `Config`'s flash
/// defaults for `merge` remains owned by `AppState`, which passes them in as
/// plain parameters — `ChannelRegistry` still has no other knowledge of
/// `Config`.
#[derive(Debug, Default)]
pub(crate) struct ChannelRegistry {
    channels: RwLock<HashMap<String, Channel>>,
    config: Option<Arc<ConfigStore>>,
}

impl ChannelRegistry {
    /// Seed the registry with an initial set of channels (e.g. from loaded
    /// config at startup). Sync because `AppState::new` is sync. Persistence
    /// is off until `attach_config` is called — bare `seeded()`/`default()`
    /// stays persistence-free for direct registry unit tests.
    pub(crate) fn seeded(channels: Vec<Channel>) -> Self {
        let map = channels.into_iter().map(|ch| (ch.id.clone(), ch)).collect();
        Self {
            channels: RwLock::new(map),
            config: None,
        }
    }

    /// Wire up auto-persistence. Called once by `AppState::new`.
    pub(crate) fn attach_config(mut self, config: Arc<ConfigStore>) -> Self {
        self.config = Some(config);
        self
    }

    /// Persist the current channel list into `Config`. No-op when no
    /// `ConfigStore` has been attached (e.g. in direct registry unit tests).
    async fn persist(&self) {
        let Some(config) = &self.config else { return };
        let channels = self.list().await;
        config
            .mutate_and_persist(|cfg| cfg.default_channels = channels)
            .await;
    }

    pub(crate) async fn list(&self) -> Vec<Channel> {
        let mut channels: Vec<_> = self.channels.read().await.values().cloned().collect();
        channels.sort_by(|a, b| a.display_name.cmp(&b.display_name));
        channels
    }

    pub(crate) async fn upsert(&self, ch: Channel) {
        self.channels.write().await.insert(ch.id.clone(), ch);
        self.persist().await;
    }

    pub(crate) async fn delete(&self, channel_id: &str) {
        self.channels.write().await.remove(channel_id);
        self.persist().await;
    }

    async fn replace_all_raw(&self, channels: Vec<Channel>) {
        let mut map = self.channels.write().await;
        map.clear();
        for ch in channels {
            map.insert(ch.id.clone(), ch);
        }
    }

    /// Replace every channel with `channels` (used by `apply_show_file_full`/
    /// `apply_show_file` after `validate_show_file_channels` has passed).
    pub(crate) async fn replace_all(&self, channels: Vec<Channel>) {
        self.replace_all_raw(channels).await;
        self.persist().await;
    }

    /// Replace channels without auto-persisting. Used by `apply_show_file_full`
    /// which combines the channels + static-peers write in one
    /// `mutate_and_persist` call — persisting here too would double-write.
    pub(crate) async fn replace_all_silent(&self, channels: Vec<Channel>) {
        self.replace_all_raw(channels).await;
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
        drop(map);
        if added > 0 {
            self.persist().await;
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
        drop(channels);
        self.persist().await;
        Ok(())
    }

    /// Add or replace a macro on a channel. Matched by `original_label` when
    /// given (an edit of an existing macro, possibly renaming it) so the entry
    /// is updated in place instead of appending a second one under the new
    /// label; matched by `macro_msg.label` otherwise (create, or no-op rename).
    ///
    /// `global_macros` is passed in by `AppState` (ADR-0003 — this registry
    /// has no knowledge of `Config`) so [`validate_binding_unique`] can also
    /// reject a binding shared with a global macro, not just another macro on
    /// this same channel.
    pub(crate) async fn upsert_macro(
        &self,
        channel_id: &str,
        original_label: Option<&str>,
        macro_msg: MacroMessage,
        global_macros: &[MacroMessage],
    ) -> anyhow::Result<()> {
        let mut channels = self.channels.write().await;
        let ch = channels
            .get_mut(channel_id)
            .ok_or_else(|| anyhow::anyhow!("Channel '{}' not found", channel_id))?;
        let match_label = resolve_macro_rename(
            &ch.macros,
            original_label,
            &macro_msg,
            global_macros.iter(),
            "on this channel",
        )?;
        if let Some(pos) = ch.macros.iter().position(|s| s.label == match_label) {
            ch.macros[pos] = macro_msg;
        } else {
            ch.macros.push(macro_msg);
        }
        drop(channels);
        self.persist().await;
        Ok(())
    }

    /// Remove a macro from a channel by label.
    pub(crate) async fn delete_macro(&self, channel_id: &str, label: &str) -> anyhow::Result<()> {
        let mut channels = self.channels.write().await;
        let ch = channels
            .get_mut(channel_id)
            .ok_or_else(|| anyhow::anyhow!("Channel '{}' not found", channel_id))?;
        ch.macros.retain(|s| s.label != label);
        drop(channels);
        self.persist().await;
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
        drop(channels);
        self.persist().await;
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
        let err = validate_osc_target(&t).unwrap_err();
        assert!(err.to_string().contains("cue/1/start"));
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

    // ── sanitize_binding_collisions (ADR-0006) ──────────────────────────────

    #[test]
    fn sanitize_binding_collisions_strips_global_vs_global_keeps_both_macros() {
        let mut first = plain_macro("GO");
        first.key_binding = Some("F3".into());
        let mut second = plain_macro("STANDBY");
        second.key_binding = Some("F3".into());
        let mut globals = vec![first, second];
        let mut channels: Vec<Channel> = vec![];

        sanitize_binding_collisions(&mut globals, &mut channels);

        assert_eq!(globals.len(), 2); // neither macro is dropped
        assert_eq!(globals[0].key_binding.as_deref(), Some("F3")); // first-listed wins
        assert_eq!(globals[1].key_binding, None); // loser keeps the macro, loses the binding
    }

    #[test]
    fn sanitize_binding_collisions_strips_same_channel_collision() {
        let mut go = plain_macro("GO");
        go.midi_note = Some(60);
        let mut standby = plain_macro("STANDBY");
        standby.midi_note = Some(60);
        let mut ch = Channel::new("rf", "RF", "#fff").unwrap();
        ch.macros = vec![go, standby];
        let mut globals: Vec<MacroMessage> = vec![];
        let mut channels = vec![ch];

        sanitize_binding_collisions(&mut globals, &mut channels);

        let macros = &channels[0].macros;
        assert_eq!(macros.len(), 2);
        assert_eq!(macros[0].midi_note, Some(60));
        assert_eq!(macros[1].midi_note, None);
    }

    #[test]
    fn sanitize_binding_collisions_strips_channel_macro_colliding_with_a_global() {
        let mut global_go = plain_macro("GO");
        global_go.key_binding = Some("F3".into());
        let mut channel_go = plain_macro("STANDBY");
        channel_go.key_binding = Some("F3".into());
        let mut ch = Channel::new("rf", "RF", "#fff").unwrap();
        ch.macros = vec![channel_go];
        let mut globals = vec![global_go];
        let mut channels = vec![ch];

        sanitize_binding_collisions(&mut globals, &mut channels);

        assert_eq!(globals[0].key_binding.as_deref(), Some("F3")); // global keeps its binding
        assert_eq!(channels[0].macros[0].key_binding, None); // channel macro loses it, stays
    }

    #[test]
    fn sanitize_binding_collisions_never_compares_across_different_channels() {
        let mut rf = plain_macro("GO");
        rf.midi_cc = Some(10);
        let mut lx = plain_macro("GO");
        lx.midi_cc = Some(10);
        let mut rf_channel = Channel::new("rf", "RF", "#fff").unwrap();
        rf_channel.macros = vec![rf];
        let mut lx_channel = Channel::new("lx", "LX", "#fff").unwrap();
        lx_channel.macros = vec![lx];
        let mut globals: Vec<MacroMessage> = vec![];
        let mut channels = vec![rf_channel, lx_channel];

        sanitize_binding_collisions(&mut globals, &mut channels);

        assert_eq!(channels[0].macros[0].midi_cc, Some(10));
        assert_eq!(channels[1].macros[0].midi_cc, Some(10)); // unaffected — different channels
    }

    #[test]
    fn classify_macro_import_adds_a_brand_new_macro() {
        let offered = vec![plain_macro("GO")];
        let out = classify_macro_import(&offered, &[], &[]);
        assert_eq!(out.len(), 1);
        match &out[0] {
            MacroImportOutcome::Added { msg } => assert_eq!(msg.label, "GO"),
            other => panic!("expected Added, got {other:?}"),
        }
    }

    #[test]
    fn classify_macro_import_reports_an_exact_duplicate_as_already_have() {
        let existing = plain_macro("GO");
        let offered = vec![existing.clone()];
        let out = classify_macro_import(&offered, &[existing], &[]);
        assert_eq!(out.len(), 1);
        match &out[0] {
            MacroImportOutcome::AlreadyHave { label } => assert_eq!(label, "GO"),
            other => panic!("expected AlreadyHave, got {other:?}"),
        }
    }

    #[test]
    fn classify_macro_import_drops_an_invalid_osc_target() {
        let mut bad = plain_macro("GO");
        bad.osc = Some(target(
            "not-an-ip",
            53000,
            "/cue/go",
            None,
            OscArgKind::String,
        ));
        let out = classify_macro_import(&[bad], &[], &[]);
        assert_eq!(out.len(), 1);
        assert!(matches!(out[0], MacroImportOutcome::Skipped { .. }));
    }

    #[test]
    fn classify_macro_import_strips_a_binding_colliding_with_an_existing_global() {
        let mut existing = plain_macro("STANDBY");
        existing.key_binding = Some("F3".into());
        let mut offered_macro = plain_macro("GO");
        offered_macro.key_binding = Some("F3".into());
        let out = classify_macro_import(&[offered_macro], &[existing], &[]);
        assert_eq!(out.len(), 1);
        match &out[0] {
            MacroImportOutcome::AddedBindingDropped { msg, .. } => {
                assert_eq!(msg.label, "GO");
                assert_eq!(msg.key_binding, None);
            }
            other => panic!("expected AddedBindingDropped, got {other:?}"),
        }
    }

    #[test]
    fn classify_macro_import_strips_a_binding_colliding_with_an_existing_channel_macro() {
        let mut existing = plain_macro("STANDBY");
        existing.midi_note = Some(60);
        let mut offered_macro = plain_macro("GO");
        offered_macro.midi_note = Some(60);
        let out = classify_macro_import(&[offered_macro], &[], &[existing]);
        match &out[0] {
            MacroImportOutcome::AddedBindingDropped { msg, .. } => {
                assert_eq!(msg.midi_note, None);
            }
            other => panic!("expected AddedBindingDropped, got {other:?}"),
        }
    }

    #[test]
    fn classify_macro_import_catches_two_offered_macros_colliding_with_each_other() {
        let mut first = plain_macro("GO");
        first.key_binding = Some("F3".into());
        let mut second = plain_macro("STANDBY");
        second.key_binding = Some("F3".into());
        let out = classify_macro_import(&[first, second], &[], &[]);
        assert_eq!(out.len(), 2);
        assert!(matches!(out[0], MacroImportOutcome::Added { .. }));
        match &out[1] {
            MacroImportOutcome::AddedBindingDropped { msg, .. } => {
                assert_eq!(msg.key_binding, None);
            }
            other => panic!("expected AddedBindingDropped, got {other:?}"),
        }
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
        reg.upsert_macro("rf", None, plain_macro("GO"), &[])
            .await
            .unwrap();
        let mut replaced = plain_macro("GO");
        replaced.payload = "different".into();
        reg.upsert_macro("rf", None, replaced, &[]).await.unwrap();
        let macros = &reg.list().await[0].macros;
        assert_eq!(macros.len(), 1);
        assert_eq!(macros[0].payload, "different");
    }

    #[tokio::test]
    async fn upsert_macro_with_original_label_renames_in_place() {
        let reg = ChannelRegistry::default();
        reg.upsert(Channel::new("rf", "RF", "#fff").unwrap()).await;
        reg.upsert_macro("rf", None, plain_macro("GO"), &[])
            .await
            .unwrap();
        reg.upsert_macro("rf", None, plain_macro("STANDBY"), &[])
            .await
            .unwrap();
        let mut renamed = plain_macro("HOLD");
        renamed.payload = "renamed".into();
        reg.upsert_macro("rf", Some("GO"), renamed, &[])
            .await
            .unwrap();
        let macros = &reg.list().await[0].macros;
        assert_eq!(macros.len(), 2);
        assert_eq!(macros[0].label, "HOLD"); // renamed in place, not appended
        assert_eq!(macros[0].payload, "renamed");
        assert_eq!(macros[1].label, "STANDBY");
    }

    #[tokio::test]
    async fn upsert_macro_rename_to_existing_label_errors() {
        let reg = ChannelRegistry::default();
        reg.upsert(Channel::new("rf", "RF", "#fff").unwrap()).await;
        reg.upsert_macro("rf", None, plain_macro("GO"), &[])
            .await
            .unwrap();
        reg.upsert_macro("rf", None, plain_macro("STANDBY"), &[])
            .await
            .unwrap();
        let collision = plain_macro("STANDBY");
        assert!(reg
            .upsert_macro("rf", Some("GO"), collision, &[])
            .await
            .is_err());
        let macros = &reg.list().await[0].macros;
        assert_eq!(macros.len(), 2); // unchanged
    }

    #[tokio::test]
    async fn upsert_macro_rejects_binding_collision_on_same_channel() {
        let reg = ChannelRegistry::default();
        reg.upsert(Channel::new("rf", "RF", "#fff").unwrap()).await;
        let mut go = plain_macro("GO");
        go.key_binding = Some("F3".into());
        reg.upsert_macro("rf", None, go, &[]).await.unwrap();

        let mut standby = plain_macro("STANDBY");
        standby.key_binding = Some("F3".into());
        let err = reg
            .upsert_macro("rf", None, standby, &[])
            .await
            .unwrap_err();
        assert!(err.to_string().contains("F3"));
        assert_eq!(reg.list().await[0].macros.len(), 1); // rejected, not added
    }

    #[tokio::test]
    async fn upsert_macro_rejects_binding_collision_with_a_global_macro() {
        let reg = ChannelRegistry::default();
        reg.upsert(Channel::new("rf", "RF", "#fff").unwrap()).await;
        let mut global_hold = plain_macro("HOLD");
        global_hold.midi_note = Some(60);

        let mut channel_go = plain_macro("GO");
        channel_go.midi_note = Some(60);
        let err = reg
            .upsert_macro("rf", None, channel_go, &[global_hold])
            .await
            .unwrap_err();
        assert!(err.to_string().contains("HOLD"));
        assert!(reg.list().await[0].macros.is_empty());
    }

    #[tokio::test]
    async fn upsert_macro_allows_rename_keeping_its_own_binding() {
        let reg = ChannelRegistry::default();
        reg.upsert(Channel::new("rf", "RF", "#fff").unwrap()).await;
        let mut go = plain_macro("GO");
        go.key_binding = Some("F3".into());
        reg.upsert_macro("rf", None, go, &[]).await.unwrap();

        let mut renamed = plain_macro("STANDBY");
        renamed.key_binding = Some("F3".into());
        reg.upsert_macro("rf", Some("GO"), renamed, &[])
            .await
            .unwrap();
        let macros = &reg.list().await[0].macros;
        assert_eq!(macros.len(), 1);
        assert_eq!(macros[0].label, "STANDBY");
    }

    #[tokio::test]
    async fn delete_macro_removes_by_label() {
        let reg = ChannelRegistry::default();
        reg.upsert(Channel::new("rf", "RF", "#fff").unwrap()).await;
        reg.upsert_macro("rf", None, plain_macro("GO"), &[])
            .await
            .unwrap();
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
