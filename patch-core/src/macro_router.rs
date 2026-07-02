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

/// Fire every macro bound to `trigger`: Patch message(s) routed to the open
/// DM thread if one exists, otherwise to channels, plus any OSC dual-action.
pub(crate) async fn fire_trigger(
    state: &AppState,
    transport: &Arc<Transport>,
    reliability: &Arc<Mutex<ReliabilityManager>>,
    trigger: &impl MacroTrigger,
) {
    use crate::osc::types::Priority;
    let channels = state.get_channels().await;
    let globals = state.config().await.global_macros;

    if let Some(peer_id) = state.dm_target().await {
        for (payload, priority) in resolve_dm_payloads(&channels, &globals, trigger) {
            let prio = Priority::try_from(priority).unwrap_or(Priority::Info);
            if let Err(e) =
                crate::messaging::dispatch_dm(state, transport, peer_id, payload, prio).await
            {
                tracing::warn!("macro trigger DM send to {} failed: {}", peer_id, e);
            }
        }
    } else {
        let selected = state.selected_channels().await;
        for (ch_id, payload, priority) in resolve_targets(&channels, &globals, &selected, trigger) {
            let prio = Priority::try_from(priority).unwrap_or(Priority::Info);
            if let Err(e) = crate::api::dispatch_message(
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
    for target in resolve_osc(&channels, &globals, trigger) {
        if let Err(e) = crate::api::dispatch_osc(transport, &target).await {
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
}
