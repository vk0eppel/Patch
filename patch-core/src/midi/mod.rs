//! MIDI input — fire macros from a Note On / Control Change.
//!
//! A per-channel macro can carry a `midi_note` and/or `midi_cc` (0–127). When a
//! matching MIDI message arrives, the engine fires that macro **on its own
//! channel**, regardless of what the UI has selected — so a footswitch or pad
//! triggers a callout hands-free, even on a channel you aren't viewing. (This is
//! deliberately different from F-keys, which fire on the *selected* channel via
//! the Flutter layer; MIDI bindings are absolute and handled engine-side so they
//! work without focus.) If the same note/CC is bound on several channels, each
//! fires on its own channel.
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

    /// Fire every per-channel macro whose binding matches, each on its own channel.
    async fn fire(
        state: &AppState,
        transport: &Arc<Transport>,
        reliability: &Arc<Mutex<ReliabilityManager>>,
        trigger: MidiTrigger,
    ) {
        use crate::osc::types::Priority;
        for ch in &state.get_channels().await {
            for m in &ch.macros {
                let hit = match trigger {
                    MidiTrigger::Note(n) => m.midi_note == Some(n),
                    MidiTrigger::Cc(c) => m.midi_cc == Some(c),
                };
                if hit {
                    let prio = Priority::try_from(m.priority).unwrap_or(Priority::Info);
                    if let Err(e) = crate::api::dispatch_message(
                        state,
                        transport,
                        reliability,
                        ch.id.clone(),
                        m.payload.clone(),
                        prio,
                    )
                    .await
                    {
                        tracing::warn!("MIDI macro send failed on {}: {}", ch.id, e);
                    }
                }
            }
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
