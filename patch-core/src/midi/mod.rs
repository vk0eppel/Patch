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
//! Besides every physical input port, on **macOS/Linux** a virtual input port
//! named "Patch" is created (`connect_all`) so other software/gear can send MIDI
//! to Patch with no hardware. Windows (WinMM) has no virtual ports — those users
//! route through a loopback driver (loopMIDI) and a physical port.
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

    /// Open every available input port (plus a virtual port on macOS/Linux),
    /// forwarding parsed triggers onto `tx`.
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

        // Virtual input port — appears as a "Patch" MIDI **destination** that other
        // software/gear on the machine can send to directly, no hardware needed (a
        // DAW, Bitfocus Companion, another app routing MIDI…). Feeds the same parse
        // → fire pipeline. CoreMIDI (macOS) + ALSA (Linux) only; WinMM (Windows)
        // has no virtual-port concept — Windows users route through a loopback
        // driver (e.g. loopMIDI) and a physical port instead.
        #[cfg(any(target_os = "macos", target_os = "linux"))]
        {
            use midir::os::unix::VirtualInput;
            let input = MidiInput::new(CLIENT_NAME)?;
            let txc = tx.clone();
            match input.create_virtual(
                CLIENT_NAME,
                move |_ts, msg, _| {
                    if let Some(trigger) = parse(msg) {
                        let _ = txc.send(trigger);
                    }
                },
                (),
            ) {
                Ok(conn) => {
                    tracing::info!("MIDI: virtual input port '{}' created", CLIENT_NAME);
                    conns.push(conn);
                }
                Err(e) => tracing::warn!("MIDI: virtual port creation failed: {}", e),
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

    /// Whether a macro is bound to this trigger. Shared by every `resolve_*`
    /// function below so the Note/CC match rule lives in one place.
    fn matches(m: &crate::state::channel::MacroMessage, trigger: MidiTrigger) -> bool {
        match trigger {
            MidiTrigger::Note(n) => m.midi_note == Some(n),
            MidiTrigger::Cc(c) => m.midi_cc == Some(c),
        }
    }

    /// Pure routing: which `(channel_id, payload, priority)` to send for a
    /// trigger when no DM is open. **Per-channel** macros fire on their own
    /// channel (absolute); **global** macros fire on each currently-selected
    /// channel — exactly mirroring the UI's `_fireMacro` (a tap/F-key) outside
    /// DM mode. Kept side-effect-free so the routing is unit-testable without a
    /// running engine.
    fn resolve_targets(
        channels: &[crate::state::channel::Channel],
        globals: &[crate::state::channel::MacroMessage],
        selected: &[String],
        trigger: MidiTrigger,
    ) -> Vec<(String, String, i32)> {
        let mut out = Vec::new();
        for ch in channels {
            for m in &ch.macros {
                if matches(m, trigger) {
                    out.push((ch.id.clone(), m.payload.clone(), m.priority));
                }
            }
        }
        for m in globals {
            if matches(m, trigger) {
                for ch_id in selected {
                    out.push((ch_id.clone(), m.payload.clone(), m.priority));
                }
            }
        }
        out
    }

    /// Which `(payload, priority)` to send as a DM when a DM thread is open.
    /// Mirrors `_fireMacro`'s DM-mode rule: *every* macro bound to this
    /// trigger — per-channel or global alike — sends as a DM, ignoring the
    /// channel/global distinction entirely (there's no channel to route to).
    fn resolve_dm_payloads(
        channels: &[crate::state::channel::Channel],
        globals: &[crate::state::channel::MacroMessage],
        trigger: MidiTrigger,
    ) -> Vec<(String, i32)> {
        channels
            .iter()
            .flat_map(|c| &c.macros)
            .chain(globals)
            .filter(|m| matches(m, trigger))
            .map(|m| (m.payload.clone(), m.priority))
            .collect()
    }

    /// The OSC targets to fire for a trigger — **one per matched macro** (a global
    /// macro fires its OSC once, regardless of how many channels its message goes
    /// to; OSC is independent of channel selection/DM mode).
    fn resolve_osc(
        channels: &[crate::state::channel::Channel],
        globals: &[crate::state::channel::MacroMessage],
        trigger: MidiTrigger,
    ) -> Vec<crate::state::channel::OscTarget> {
        let mut out = Vec::new();
        for m in channels.iter().flat_map(|c| &c.macros).chain(globals) {
            if matches(m, trigger) {
                if let Some(o) = &m.osc {
                    out.push(o.clone());
                }
            }
        }
        out
    }

    /// Fire every macro bound to this trigger: the Patch message(s) — routed to
    /// the open DM thread if one exists (`resolve_dm_payloads`), otherwise to
    /// channels (`resolve_targets`) — plus any attached OSC packet (dual action).
    async fn fire(
        state: &AppState,
        transport: &Arc<Transport>,
        reliability: &Arc<Mutex<ReliabilityManager>>,
        trigger: MidiTrigger,
    ) {
        use crate::osc::types::Priority;
        let channels = state.get_channels().await;
        let globals = state.config().await.global_macros;

        if let Some(peer_id) = state.dm_target().await {
            for (payload, priority) in resolve_dm_payloads(&channels, &globals, trigger) {
                if let Err(e) =
                    crate::api::send_direct_message(peer_id.to_string(), payload, priority).await
                {
                    tracing::warn!("MIDI macro DM send to {} failed: {}", peer_id, e);
                }
            }
        } else {
            let selected = state.selected_channels().await;
            for (ch_id, payload, priority) in
                resolve_targets(&channels, &globals, &selected, trigger)
            {
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
        // OSC macros (dual action) — once per matched macro.
        for target in resolve_osc(&channels, &globals, trigger) {
            if let Err(e) = crate::api::dispatch_osc(transport, &target).await {
                tracing::warn!("MIDI OSC macro to {} failed: {}", target.address, e);
            }
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use crate::state::channel::{Channel, MacroMessage, OscTarget};

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

        #[test]
        fn osc_fires_once_per_matched_macro_regardless_of_channels() {
            let osc = OscTarget {
                address: "10.0.0.9".into(),
                port: 53000,
                path: "/cue/1/start".into(),
                arg: None,
                arg_type: Default::default(),
            };
            // A global macro (note 60) with an OSC target + a plain per-channel
            // macro (note 60, no OSC) on "rf".
            let mut rf = Channel::new("rf", "RF", "#fff").unwrap();
            rf.macros = vec![mac("A", Some(60), None)];
            let globals = vec![mac_osc("G", 60, osc.clone())];

            // The global's message goes to 2 selected channels, but its OSC fires
            // exactly once; the per-channel macro has no OSC.
            let got = resolve_osc(&[rf], &globals, MidiTrigger::Note(60));
            assert_eq!(got.len(), 1);
            assert_eq!(got[0].path, "/cue/1/start");

            // A trigger that matches nothing yields no OSC.
            assert!(resolve_osc(&[], &globals, MidiTrigger::Note(61)).is_empty());
        }

        #[test]
        fn dm_payloads_include_both_per_channel_and_global_macros() {
            // Mirrors `_fireMacro`'s DM-mode rule: with a DM open, the
            // per-channel/global distinction stops mattering — every macro
            // bound to the trigger becomes a DM payload, channel-independent.
            let mut rf = Channel::new("rf", "RF", "#fff").unwrap();
            rf.macros = vec![mac("A", Some(60), None)];
            let globals = vec![mac("G", Some(60), None)];

            let got = resolve_dm_payloads(&[rf], &globals, MidiTrigger::Note(60));
            assert_eq!(got.len(), 2);
            assert!(got.contains(&("p-A".to_string(), 2)));
            assert!(got.contains(&("p-G".to_string(), 2)));
        }

        #[test]
        fn dm_payloads_empty_when_trigger_matches_nothing() {
            let globals = vec![mac("G", Some(60), None)];
            assert!(resolve_dm_payloads(&[], &globals, MidiTrigger::Note(61)).is_empty());
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
