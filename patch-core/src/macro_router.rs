//! Shared macro-dispatch engine — platform-agnostic trigger → send pipeline.
//!
//! Callers implement [`MacroTrigger`] (one method: `matches`) and call
//! [`fire_trigger`]. The routing logic (`resolve_targets`, `resolve_dm_payloads`,
//! `resolve_osc`) lives here so it's unit-testable and reusable by any future
//! trigger source (MIDI, OSC, key binding …) without touching platform code.

use std::sync::Arc;

use tokio::sync::Mutex;

use crate::reliability::ReliabilityManager;
use crate::state::channel::{Channel, MacroMessage, OscTarget};
use crate::state::AppState;
use crate::transport::Transport;

/// A value that can match against a macro binding. Implement this for each
/// trigger source (MIDI note, CC, OSC address, key binding …).
pub(crate) trait MacroTrigger {
    fn matches(&self, m: &MacroMessage) -> bool;
}

/// Pure routing: which `(channel_id, payload, priority)` to send for a
/// trigger when no DM is open. Per-channel macros fire on their own channel
/// (absolute); global macros fire on each currently-selected channel —
/// mirroring the UI's `_fireMacro` outside DM mode.
pub(crate) fn resolve_targets(
    channels: &[Channel],
    globals: &[MacroMessage],
    selected: &[String],
    trigger: &impl MacroTrigger,
) -> Vec<(String, String, i32)> {
    let mut out = Vec::new();
    for ch in channels {
        for m in &ch.macros {
            if trigger.matches(m) {
                out.push((ch.id.clone(), m.payload.clone(), m.priority));
            }
        }
    }
    for m in globals {
        if trigger.matches(m) {
            for ch_id in selected {
                out.push((ch_id.clone(), m.payload.clone(), m.priority));
            }
        }
    }
    out
}

/// Which `(payload, priority)` to send as a DM when a DM thread is open.
/// Every macro bound to this trigger — per-channel or global — sends as a DM,
/// ignoring the channel/global distinction (no channel to route to in DM mode).
pub(crate) fn resolve_dm_payloads(
    channels: &[Channel],
    globals: &[MacroMessage],
    trigger: &impl MacroTrigger,
) -> Vec<(String, i32)> {
    channels
        .iter()
        .flat_map(|c| &c.macros)
        .chain(globals)
        .filter(|m| trigger.matches(m))
        .map(|m| (m.payload.clone(), m.priority))
        .collect()
}

/// The OSC targets to fire for a trigger — one per matched macro (a global
/// macro fires its OSC once, regardless of how many channels its message goes
/// to; OSC is independent of channel selection/DM mode).
pub(crate) fn resolve_osc(
    channels: &[Channel],
    globals: &[MacroMessage],
    trigger: &impl MacroTrigger,
) -> Vec<OscTarget> {
    let mut out = Vec::new();
    for m in channels.iter().flat_map(|c| &c.macros).chain(globals) {
        if trigger.matches(m) {
            if let Some(o) = &m.osc {
                out.push(o.clone());
            }
        }
    }
    out
}

/// The first macro bound to key `label`, with the Dart panel's precedence:
/// a per-channel macro on a currently-selected Channel beats a Global Macro
/// on the same key, and unselected Channels' bindings never fire. Returns the
/// owning channel id (`None` for a global) alongside the macro.
pub(crate) fn resolve_key_macro<'a>(
    channels: &'a [Channel],
    globals: &'a [MacroMessage],
    selected: &[String],
    label: &str,
) -> Option<(Option<&'a str>, &'a MacroMessage)> {
    let bound = |m: &MacroMessage| m.key_binding.as_deref() == Some(label);
    for ch in channels.iter().filter(|c| selected.contains(&c.id)) {
        if let Some(m) = ch.macros.iter().find(|m| bound(m)) {
            return Some((Some(ch.id.as_str()), m));
        }
    }
    globals.iter().find(|m| bound(m)).map(|m| (None, m))
}

/// Fire the macro bound to key `label`, if any (the OS-level key handler's
/// entry point). Resolves the macro exactly once via [`resolve_key_macro`]'s
/// precedence walk and fires it directly through [`fire_matching`] — the
/// caller's `channels`/`globals` are reused as-is rather than re-fetched, and
/// the macro found isn't re-searched by label a second time. Routing stays
/// centralized in `fire_matching` (ADR-0009); this only removes the duplicate
/// lookup. Returns `false` when nothing is bound to `label`.
pub(crate) async fn fire_key_bound_macro(
    state: &AppState,
    transport: &Arc<Transport>,
    reliability: &Arc<Mutex<ReliabilityManager>>,
    channels: &[Channel],
    globals: &[MacroMessage],
    selected: &[String],
    label: &str,
) -> bool {
    let Some((channel_id, macro_msg)) = resolve_key_macro(channels, globals, selected, label)
    else {
        return false;
    };

    let (narrowed_channels, narrowed_globals): (Vec<Channel>, Vec<MacroMessage>) = match channel_id
    {
        Some(id) => {
            let ch = channels
                .iter()
                .find(|c| c.id == id)
                .cloned()
                .expect("resolve_key_macro returned an id it found in `channels`");
            (vec![ch], Vec::new())
        }
        None => (Vec::new(), vec![macro_msg.clone()]),
    };

    fire_matching(
        state,
        transport,
        reliability,
        &narrowed_channels,
        &narrowed_globals,
        &LabelTrigger(&macro_msg.label),
    )
    .await;
    true
}

/// Matches exactly one macro by label — used to funnel a UI tap (which already
/// knows *which* macro fired) through the same routing as every other trigger.
struct LabelTrigger<'a>(&'a str);
impl MacroTrigger for LabelTrigger<'_> {
    fn matches(&self, m: &MacroMessage) -> bool {
        m.label == self.0
    }
}

/// Fire one macro identified by its home (`Some(channel_id)` for a Channel
/// Macro, `None` for a Global Macro) and label — the UI tap/F-key entry point.
/// Routing is `fire_matching` over a universe narrowed to just that macro, so
/// the policy (DM-open precedence, own-channel vs selection, OSC-once) has a
/// single owner for every trigger source.
pub(crate) async fn fire_identified(
    state: &AppState,
    transport: &Arc<Transport>,
    reliability: &Arc<Mutex<ReliabilityManager>>,
    channel_id: Option<&str>,
    label: &str,
) -> anyhow::Result<()> {
    let channels = state.get_channels().await;
    let globals = state.config().await.global_macros;
    let (channels, globals): (Vec<Channel>, Vec<MacroMessage>) = match channel_id {
        Some(id) => {
            let ch = channels
                .into_iter()
                .find(|c| c.id == id && c.macros.iter().any(|m| m.label == label))
                .ok_or_else(|| anyhow::anyhow!("macro not found: {}/{}", id, label))?;
            (vec![ch], Vec::new())
        }
        None => {
            if !globals.iter().any(|m| m.label == label) {
                anyhow::bail!("macro not found: global/{}", label);
            }
            (Vec::new(), globals)
        }
    };
    fire_matching(
        state,
        transport,
        reliability,
        &channels,
        &globals,
        &LabelTrigger(label),
    )
    .await;
    Ok(())
}

/// Fire every macro bound to `trigger`: Patch message(s) routed to the open
/// DM thread if one exists, otherwise to channels, plus any OSC dual-action.
pub(crate) async fn fire_trigger(
    state: &AppState,
    transport: &Arc<Transport>,
    reliability: &Arc<Mutex<ReliabilityManager>>,
    trigger: &impl MacroTrigger,
) {
    let channels = state.get_channels().await;
    let globals = state.config().await.global_macros;
    fire_matching(state, transport, reliability, &channels, &globals, trigger).await;
}

/// The routing core shared by every trigger source: DM-open beats channels;
/// per-channel macros fire absolute; globals fire on the current selection;
/// each matched macro's OSC dual-action fires exactly once.
async fn fire_matching(
    state: &AppState,
    transport: &Arc<Transport>,
    reliability: &Arc<Mutex<ReliabilityManager>>,
    channels: &[Channel],
    globals: &[MacroMessage],
    trigger: &impl MacroTrigger,
) {
    use crate::osc::types::Priority;

    if let Some(peer_id) = state.dm_target().await {
        for (payload, priority) in resolve_dm_payloads(channels, globals, trigger) {
            let prio = Priority::try_from(priority).unwrap_or(Priority::Info);
            if let Err(e) =
                crate::messaging::dispatch_dm(state, transport, peer_id, payload, prio).await
            {
                tracing::warn!("macro trigger DM send to {} failed: {}", peer_id, e);
            }
        }
    } else {
        let selected = state.selected_channels().await;
        for (ch_id, payload, priority) in resolve_targets(channels, globals, &selected, trigger) {
            let prio = Priority::try_from(priority).unwrap_or(Priority::Info);
            if let Err(e) = crate::messaging::dispatch_channel_message(
                state,
                transport,
                reliability,
                ch_id.clone(),
                payload,
                prio,
            )
            .await
            {
                tracing::warn!("macro trigger send failed on {}: {}", ch_id, e);
            }
        }
    }
    for target in resolve_osc(channels, globals, trigger) {
        if let Err(e) = crate::messaging::dispatch_osc(transport, &target).await {
            tracing::warn!("macro OSC to {} failed: {}", target.address, e);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state::channel::{Channel, MacroMessage, OscTarget};

    /// Test trigger matching on MIDI note number.
    struct NoteTrigger(u8);
    impl MacroTrigger for NoteTrigger {
        fn matches(&self, m: &MacroMessage) -> bool {
            m.midi_note == Some(self.0)
        }
    }

    /// Test trigger matching on MIDI CC number.
    struct CcTrigger(u8);
    impl MacroTrigger for CcTrigger {
        fn matches(&self, m: &MacroMessage) -> bool {
            m.midi_cc == Some(self.0)
        }
    }

    fn mac(label: &str, note: Option<u8>, cc: Option<u8>) -> MacroMessage {
        MacroMessage {
            label: label.into(),
            payload: format!("p-{label}"),
            key_binding: None,
            priority: 2,
            midi_note: note,
            midi_cc: cc,
            osc: None,
        }
    }

    fn mac_osc(label: &str, note: u8, osc: OscTarget) -> MacroMessage {
        MacroMessage {
            osc: Some(osc),
            ..mac(label, Some(note), None)
        }
    }

    #[test]
    fn per_channel_fires_on_own_channel_global_on_selected() {
        let mut rf = Channel::new("rf", "RF", "#fff").unwrap();
        rf.macros = vec![mac("A", Some(60), None)];
        let mut audio = Channel::new("audio", "AUDIO", "#fff").unwrap();
        audio.macros = vec![mac("B", Some(61), None)];
        let globals = vec![mac("G", Some(60), None)];
        let selected = vec!["rf".to_string(), "audio".to_string()];
        let chans = [rf, audio];

        // Note 60: rf's "A" (own channel) + global "G" on each selected channel.
        let t = resolve_targets(&chans, &globals, &selected, &NoteTrigger(60));
        assert_eq!(t.len(), 3);
        assert!(t.contains(&("rf".into(), "p-A".into(), 2)));
        assert!(t.contains(&("rf".into(), "p-G".into(), 2)));
        assert!(t.contains(&("audio".into(), "p-G".into(), 2)));

        // Note 61: only audio's "B"; no global matches.
        let t2 = resolve_targets(&chans, &globals, &selected, &NoteTrigger(61));
        assert_eq!(t2, vec![("audio".into(), "p-B".into(), 2)]);
    }

    #[test]
    fn cc_matches_and_empty_selection_skips_globals() {
        let globals = vec![mac("G", None, Some(64))];
        // No selection → a global macro has nowhere to fire.
        assert!(resolve_targets(&[], &globals, &[], &CcTrigger(64)).is_empty());
        // With a selection → fires there.
        assert_eq!(
            resolve_targets(&[], &globals, &["rf".into()], &CcTrigger(64)),
            vec![("rf".into(), "p-G".into(), 2)]
        );
    }

    #[test]
    fn osc_fires_once_per_matched_macro_regardless_of_channels() {
        let osc = OscTarget {
            address: "10.0.0.9".into(),
            port: 53000,
            path: "/cue/1/start".into(),
            arg: None,
            arg_type: Default::default(),
        };
        let mut rf = Channel::new("rf", "RF", "#fff").unwrap();
        rf.macros = vec![mac("A", Some(60), None)];
        let globals = vec![mac_osc("G", 60, osc.clone())];

        // Global's message goes to 2 selected channels, but its OSC fires exactly once.
        let got = resolve_osc(&[rf], &globals, &NoteTrigger(60));
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].path, "/cue/1/start");

        // A trigger that matches nothing yields no OSC.
        assert!(resolve_osc(&[], &globals, &NoteTrigger(61)).is_empty());
    }

    #[test]
    fn dm_payloads_include_both_per_channel_and_global_macros() {
        let mut rf = Channel::new("rf", "RF", "#fff").unwrap();
        rf.macros = vec![mac("A", Some(60), None)];
        let globals = vec![mac("G", Some(60), None)];

        let got = resolve_dm_payloads(&[rf], &globals, &NoteTrigger(60));
        assert_eq!(got.len(), 2);
        assert!(got.contains(&("p-A".to_string(), 2)));
        assert!(got.contains(&("p-G".to_string(), 2)));
    }

    #[test]
    fn dm_payloads_empty_when_trigger_matches_nothing() {
        let globals = vec![mac("G", Some(60), None)];
        assert!(resolve_dm_payloads(&[], &globals, &NoteTrigger(61)).is_empty());
    }

    // ── Key-binding resolution (engine-side F-key precedence, #138) ──────────

    fn mac_key(label: &str, key: &str) -> MacroMessage {
        MacroMessage {
            key_binding: Some(key.into()),
            ..mac(label, None, None)
        }
    }

    #[test]
    fn key_binding_per_channel_beats_global_on_a_shared_key() {
        let mut rf = Channel::new("rf", "RF", "#fff").unwrap();
        rf.macros = vec![mac_key("A", "F1")];
        let globals = vec![mac_key("G", "F1")];
        let selected = vec!["rf".to_string()];
        let chans = [rf];

        let (ch, m) = resolve_key_macro(&chans, &globals, &selected, "F1").unwrap();
        assert_eq!(ch, Some("rf"));
        assert_eq!(m.label, "A");
    }

    #[test]
    fn key_binding_ignores_unselected_channels_and_falls_back_to_global() {
        let mut rf = Channel::new("rf", "RF", "#fff").unwrap();
        rf.macros = vec![mac_key("A", "F1")];
        let globals = vec![mac_key("G", "F1")];
        let chans = [rf];
        // rf not selected — its binding must not fire; the global wins.
        let (ch, m) = resolve_key_macro(&chans, &globals, &[], "F1").unwrap();
        assert_eq!(ch, None);
        assert_eq!(m.label, "G");
    }

    #[test]
    fn key_binding_with_no_match_resolves_nothing() {
        let globals = vec![mac_key("G", "F1")];
        assert!(resolve_key_macro(&[], &globals, &[], "F2").is_none());
    }

    // ── fire_key_bound_macro (OS key handler → engine routing, #170) ─────────

    #[tokio::test]
    async fn fire_key_bound_macro_fires_the_channel_macro_on_its_own_channel() {
        let state = test_state();
        let (transport, reliability) = deps(&state).await;
        let mut rf = Channel::new("rf", "RF", "#fff").unwrap();
        rf.macros = vec![mac_key("A", "F1")];
        state.upsert_channel(rf.clone()).await;
        let selected = vec!["rf".to_string()];

        let fired = fire_key_bound_macro(
            &state,
            &transport,
            &reliability,
            &[rf],
            &[],
            &selected,
            "F1",
        )
        .await;

        assert!(fired);
        let stored = state.get_messages("rf", 10).await;
        assert_eq!(stored.len(), 1);
        assert_eq!(stored[0].payload, "p-A");
    }

    #[tokio::test]
    async fn fire_key_bound_macro_fires_the_global_macro_on_selected_channels() {
        let state = test_state();
        let (transport, reliability) = deps(&state).await;
        let rf = Channel::new("rf", "RF", "#fff").unwrap();
        state.upsert_channel(rf.clone()).await;
        state.set_selected_channels(vec!["rf".into()]).await;
        let globals = vec![mac_key("G", "F1")];
        let selected = vec!["rf".to_string()];

        let fired = fire_key_bound_macro(
            &state,
            &transport,
            &reliability,
            &[rf],
            &globals,
            &selected,
            "F1",
        )
        .await;

        assert!(fired);
        let stored = state.get_messages("rf", 10).await;
        assert_eq!(stored.len(), 1);
        assert_eq!(stored[0].payload, "p-G");
    }

    #[tokio::test]
    async fn fire_key_bound_macro_returns_false_when_nothing_is_bound() {
        let state = test_state();
        let (transport, reliability) = deps(&state).await;

        let fired =
            fire_key_bound_macro(&state, &transport, &reliability, &[], &[], &[], "F1").await;

        assert!(!fired);
    }

    // ── fire_identified (UI tap → engine routing, #138) ──────────────────────

    use crate::state::{AppState, Config};

    fn test_state() -> AppState {
        AppState::new(Config {
            osc_port: 0,
            default_channels: Vec::new(),
            ..Config::default()
        })
    }

    async fn deps(state: &AppState) -> (Arc<Transport>, Arc<Mutex<ReliabilityManager>>) {
        let config = state.config().await;
        let reliability = Arc::new(Mutex::new(ReliabilityManager::new()));
        let transport = Arc::new(
            Transport::new(&config, state.clone(), Arc::clone(&reliability))
                .await
                .unwrap(),
        );
        (transport, reliability)
    }

    #[tokio::test]
    async fn fire_identified_channel_macro_fires_on_its_own_channel() {
        let state = test_state();
        let (transport, reliability) = deps(&state).await;
        let mut rf = Channel::new("rf", "RF", "#fff").unwrap();
        rf.macros = vec![mac("A", None, None)];
        state.upsert_channel(rf).await;

        fire_identified(&state, &transport, &reliability, Some("rf"), "A")
            .await
            .unwrap();

        let stored = state.get_messages("rf", 10).await;
        assert_eq!(stored.len(), 1);
        assert_eq!(stored[0].payload, "p-A");
    }

    #[tokio::test]
    async fn fire_identified_global_with_nothing_selected_sends_nothing() {
        // CONTEXT.md, Global Macro: "If nothing is selected, the macro sends
        // nothing."
        let state = test_state();
        let (transport, reliability) = deps(&state).await;
        state
            .upsert_global_macro(None, mac("G", None, None))
            .await
            .unwrap();

        fire_identified(&state, &transport, &reliability, None, "G")
            .await
            .unwrap();

        assert!(state.get_messages("rf", 10).await.is_empty());
    }

    #[tokio::test]
    async fn fire_identified_global_fires_on_each_selected_channel() {
        let state = test_state();
        let (transport, reliability) = deps(&state).await;
        state
            .upsert_global_macro(None, mac("G", None, None))
            .await
            .unwrap();
        state
            .set_selected_channels(vec!["rf".into(), "audio".into()])
            .await;

        fire_identified(&state, &transport, &reliability, None, "G")
            .await
            .unwrap();

        assert_eq!(state.get_messages("rf", 10).await.len(), 1);
        assert_eq!(state.get_messages("audio", 10).await.len(), 1);
    }

    #[tokio::test]
    async fn fire_identified_routes_to_the_open_dm_thread() {
        let state = test_state();
        let (transport, reliability) = deps(&state).await;
        let peer_id = uuid::Uuid::new_v4();
        state
            .record_sighting(
                crate::state::PeerSighting::Heartbeat {
                    peer_id,
                    peer_name: "rigger".into(),
                },
                "127.0.0.1".into(),
                9909,
            )
            .await;
        let mut rf = Channel::new("rf", "RF", "#fff").unwrap();
        rf.macros = vec![mac("A", None, None)];
        state.upsert_channel(rf).await;
        state.set_dm_target(Some(peer_id)).await;

        fire_identified(&state, &transport, &reliability, Some("rf"), "A")
            .await
            .unwrap();

        // Routed to the DM thread, not the macro's own channel.
        assert!(state.get_messages("rf", 10).await.is_empty());
        let dm_key = crate::dm::DmThreadKey::for_peer(peer_id).local_key();
        assert_eq!(state.get_messages(&dm_key, 10).await.len(), 1);
    }

    #[tokio::test]
    async fn fire_identified_unknown_macro_is_a_clean_error() {
        let state = test_state();
        let (transport, reliability) = deps(&state).await;
        let err = fire_identified(&state, &transport, &reliability, None, "ghost")
            .await
            .unwrap_err();
        assert!(err.to_string().contains("macro not found"));
    }
}
