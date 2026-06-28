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

    impl crate::macro_router::MacroTrigger for MidiTrigger {
        fn matches(&self, m: &crate::state::channel::MacroMessage) -> bool {
            match self {
                MidiTrigger::Note(n) => m.midi_note == Some(*n),
                MidiTrigger::Cc(c) => m.midi_cc == Some(*c),
            }
        }
    }

    /// Delegate to the shared macro-dispatch engine.
    async fn fire(
        state: &AppState,
        transport: &Arc<Transport>,
        reliability: &Arc<Mutex<ReliabilityManager>>,
        trigger: MidiTrigger,
    ) {
        crate::macro_router::fire_trigger(state, transport, reliability, &trigger).await;
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
