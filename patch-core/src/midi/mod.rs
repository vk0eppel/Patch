//! MIDI input — fire macros from a Note On / Control Change.
//!
//! A macro can carry a `midi_note` and/or `midi_cc` (0–127). When a matching MIDI
//! message arrives, the engine fires hands-free — so a footswitch or pad triggers
//! a callout without touching the screen, even when Patch isn't focused. Routing
//! mirrors the UI's `_fireMacro`: a **per-channel** macro fires on **its own
//! channel** (absolute — regardless of selection; if bound on several channels,
//! each fires); a **global** macro fires on the **currently-selected channel(s)**.
//! The engine can't see UI selection on its own, so Flutter pushes it via
//! `set_selected_channels` (it includes `__all__` in ALL/broadcast mode, so a
//! global macro fired then broadcasts — same as a tap). See `resolve_targets`.
//!
//! Desktop only: `midir` provides CoreMIDI (macOS), WinMM (Windows), and ALSA
//! (Linux) backends. On iOS/Android there's no backend, so [`start`] and
//! [`list_ports`] are no-ops (and `midir` isn't depended on — see Cargo.toml).
//!
//! Threading: the OS MIDI callback runs on the backend's own thread and forwards
//! a parsed trigger over a tokio mpsc to a task that does the (async) send. The
//! `MidiInputConnection`s are kept alive for the process lifetime by a dedicated
//! parked thread (dropping a connection closes its callback) — mirroring how the
//! mDNS daemon handle is kept alive.

use std::sync::Arc;

use tokio::sync::Mutex;

use crate::reliability::ReliabilityManager;
use crate::state::AppState;
use crate::transport::Transport;

#[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
mod backend {
    use super::*;
    use midir::{MidiInput, MidiInputConnection};

    const CLIENT_NAME: &str = "Patch";

    /// What an incoming MIDI message resolved to (a macro trigger).
    #[derive(Clone, Copy, Debug)]
    enum MidiTrigger {
        Note(u8),
        Cc(u8),
    }

    pub fn list_ports() -> Vec<String> {
        let Ok(input) = MidiInput::new(CLIENT_NAME) else {
            return Vec::new();
        };
        input
            .ports()
            .iter()
            .filter_map(|p| input.port_name(p).ok())
            .collect()
    }

    pub fn start(
        state: AppState,
        transport: Arc<Transport>,
        reliability: Arc<Mutex<ReliabilityManager>>,
    ) {
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<MidiTrigger>();

        // Consumer: fire matching macros on the tokio runtime.
        tokio::spawn(async move {
            while let Some(trigger) = rx.recv().await {
                fire(&state, &transport, &reliability, trigger).await;
            }
        });

        // Owner thread: hold the connections alive for the process lifetime
        // (dropping a MidiInputConnection closes its callback), then park.
        std::thread::Builder::new()
            .name("patch-midi".into())
            .spawn(move || match connect_all(tx) {
                Ok(conns) => {
                    tracing::info!("MIDI: listening on {} input port(s)", conns.len());
                    loop {
                        std::thread::park();
                    }
                }
                Err(e) => tracing::warn!("MIDI unavailable: {}", e),
            })
            .ok();
    }

    /// Open every available input port, forwarding parsed triggers onto `tx`.
    fn connect_all(
        tx: tokio::sync::mpsc::UnboundedSender<MidiTrigger>,
    ) -> anyhow::Result<Vec<MidiInputConnection<()>>> {
        // A fresh `MidiInput` is consumed per `connect`, so enumerate with a probe.
        let probe = MidiInput::new(CLIENT_NAME)?;
        let ports = probe.ports();
        let mut conns = Vec::new();
        for port in &ports {
            let input = MidiInput::new(CLIENT_NAME)?;
            let name = input.port_name(port).unwrap_or_else(|_| "?".into());
            let txc = tx.clone();
            match input.connect(
                port,
                "patch-midi-in",
                move |_ts, msg, _| {
                    if let Some(trigger) = parse(msg) {
                        let _ = txc.send(trigger);
                    }
                },
                (),
            ) {
                Ok(conn) => {
                    tracing::info!("MIDI port connected: {}", name);
                    conns.push(conn);
                }
                Err(e) => tracing::warn!("MIDI connect failed for {}: {}", name, e),
            }
        }
        Ok(conns)
    }

    /// Parse a raw MIDI message into a trigger, ignoring everything we don't bind
    /// to. Note On with velocity 0 is a Note Off (ignored); a CC only fires on a
    /// value ≥ 64 (a footswitch "press"), so the release (0) doesn't double-fire.
    fn parse(msg: &[u8]) -> Option<MidiTrigger> {
        if msg.len() < 3 {
            return None;
        }
        match msg[0] & 0xF0 {
            0x90 if msg[2] > 0 => Some(MidiTrigger::Note(msg[1])),
            0xB0 if msg[2] >= 64 => Some(MidiTrigger::Cc(msg[1])),
            _ => None,
        }
    }

    /// Pure routing: which `(channel_id, payload, priority)` to send for a
    /// trigger. **Per-channel** macros fire on their own channel (absolute);
    /// **global** macros fire on each currently-selected channel — exactly
    /// mirroring the UI's `_fireMacro` (a tap/F-key). Kept side-effect-free so the
    /// routing is unit-testable without a running engine.
    fn resolve_targets(
        channels: &[crate::state::channel::Channel],
        globals: &[crate::state::channel::MacroMessage],
        selected: &[String],
        trigger: MidiTrigger,
    ) -> Vec<(String, String, i32)> {
        let hit = |m: &crate::state::channel::MacroMessage| match trigger {
            MidiTrigger::Note(n) => m.midi_note == Some(n),
            MidiTrigger::Cc(c) => m.midi_cc == Some(c),
        };
        let mut out = Vec::new();
        for ch in channels {
            for m in &ch.macros {
                if hit(m) {
                    out.push((ch.id.clone(), m.payload.clone(), m.priority));
                }
            }
        }
        for m in globals {
            if hit(m) {
                for ch_id in selected {
                    out.push((ch_id.clone(), m.payload.clone(), m.priority));
                }
            }
        }
        out
    }

    /// Fire every macro bound to this trigger (see `resolve_targets`).
    async fn fire(
        state: &AppState,
        transport: &Arc<Transport>,
        reliability: &Arc<Mutex<ReliabilityManager>>,
        trigger: MidiTrigger,
    ) {
        use crate::osc::types::Priority;
        let channels = state.get_channels().await;
        let globals = state.config().await.global_macros;
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
                tracing::warn!("MIDI macro send failed on {}: {}", ch_id, e);
            }
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use crate::state::channel::{Channel, MacroMessage};

        fn mac(label: &str, note: Option<u8>, cc: Option<u8>) -> MacroMessage {
            MacroMessage {
                label: label.into(),
                payload: format!("p-{label}"),
                key_binding: None,
                priority: 2,
                midi_note: note,
                midi_cc: cc,
            }
        }

        #[test]
        fn per_channel_fires_on_own_channel_global_on_selected() {
            let mut rf = Channel::new("rf", "RF", "#fff");
            rf.macros = vec![mac("A", Some(60), None)];
            let mut audio = Channel::new("audio", "AUDIO", "#fff");
            audio.macros = vec![mac("B", Some(61), None)];
            let globals = vec![mac("G", Some(60), None)];
            let selected = vec!["rf".to_string(), "audio".to_string()];
            let chans = [rf, audio];

            // Note 60: rf's "A" (own channel) + global "G" on each selected channel.
            let t = resolve_targets(&chans, &globals, &selected, MidiTrigger::Note(60));
            assert_eq!(t.len(), 3);
            assert!(t.contains(&("rf".into(), "p-A".into(), 2)));
            assert!(t.contains(&("rf".into(), "p-G".into(), 2)));
            assert!(t.contains(&("audio".into(), "p-G".into(), 2)));

            // Note 61: only audio's "B"; no global matches.
            let t2 = resolve_targets(&chans, &globals, &selected, MidiTrigger::Note(61));
            assert_eq!(t2, vec![("audio".into(), "p-B".into(), 2)]);
        }

        #[test]
        fn cc_matches_and_empty_selection_skips_globals() {
            let globals = vec![mac("G", None, Some(64))];
            // No selection → a global macro has nowhere to fire.
            assert!(resolve_targets(&[], &globals, &[], MidiTrigger::Cc(64)).is_empty());
            // With a selection → fires there.
            assert_eq!(
                resolve_targets(&[], &globals, &["rf".into()], MidiTrigger::Cc(64)),
                vec![("rf".into(), "p-G".into(), 2)]
            );
        }
    }
}

#[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
mod backend {
    use super::*;

    pub fn list_ports() -> Vec<String> {
        Vec::new()
    }

    pub fn start(
        _state: AppState,
        _transport: Arc<Transport>,
        _reliability: Arc<Mutex<ReliabilityManager>>,
    ) {
    }
}

pub use backend::{list_ports, start};
