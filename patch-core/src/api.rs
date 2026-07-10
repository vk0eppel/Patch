//! Public FFI surface for the Flutter app.
//!
//! Functions in this module are the contract between the Flutter UI and the
//! Rust engine. `flutter_rust_bridge` codegen scans this file and emits
//! typed Dart bindings into `patch_app/lib/src/rust/`. Regenerate with
//! `flutter_rust_bridge_codegen generate` from the repo root after any
//! change to a function signature here.
//!
//! Lifecycle: call `init()` once at app start. All other functions assume
//! the engine is up and will panic if called first.

use std::sync::Arc;

use anyhow::Result;
use flutter_rust_bridge::frb;
use serde::{Deserialize, Serialize};
use tokio::sync::{Mutex, OnceCell};
use uuid::Uuid;

use crate::discovery::Discovery;
use crate::osc::codec::{encode_bye, encode_channels_request, encode_macros_request};
use crate::osc::types::{ChannelFlash, OscArgKind, PatchMessage, Priority};
use crate::reliability::ReliabilityManager;
use crate::state::channel::{self, Channel, MacroImportOutcome, MacroMessage, OscTarget};
use crate::state::show_file::{self, ShowFileConfig, ShowFileMeta};
use crate::state::{config::StaticPeer, peer, AppEvent, AppState, Config};
use crate::transport::{list_interfaces, InterfaceInfo, Transport};

// ── Engine handle (singleton) ────────────────────────────────────────────────

/// Shared engine handle. Owned by the static `ENGINE` cell after `init()`.
/// Internal to the crate — not exposed across FFI.
#[frb(ignore)]
pub struct EngineHandle {
    pub state: AppState,
    pub transport: Arc<Transport>,
    /// ACK tracking + retransmit state for critical messages.
    pub reliability: Arc<Mutex<ReliabilityManager>>,
    // Holds the mDNS `ServiceDaemon` handle for the engine's lifetime — dropping
    // `Discovery` would shut the daemon thread down. The heartbeat/browse tasks
    // are detached, so this is the one thing that genuinely needs keeping alive.
    _discovery: Arc<Discovery>,
}

static ENGINE: OnceCell<EngineHandle> = OnceCell::const_new();

/// What to do with `network_interface` at startup, given the currently
/// configured pin (if any) and the interfaces actually enumerated this run.
#[derive(Debug, PartialEq, Eq)]
enum InterfaceResolution {
    /// Already pinned — leave it alone.
    AlreadyPinned,
    /// Unresolved with exactly one usable candidate — auto-select it.
    AutoSelected(String),
    /// Unresolved with zero or 2+ candidates — stay inert pending a manual
    /// choice in Settings → Network. Carries the candidate count for logging.
    Blocked(usize),
}

/// Decide the first-run interface resolution. Pure and independent of the
/// engine singleton so it's directly unit-testable — `init` calls this with
/// the real enumeration and applies the result (persist + log, or just log).
fn resolve_network_interface(
    current: &Option<String>,
    candidates: &[InterfaceInfo],
) -> InterfaceResolution {
    if current.is_some() {
        return InterfaceResolution::AlreadyPinned;
    }
    match candidates {
        [only] => InterfaceResolution::AutoSelected(only.name.clone()),
        _ => InterfaceResolution::Blocked(candidates.len()),
    }
}

/// Initialize the engine. Idempotent — subsequent calls are no-ops.
///
/// `config_dir`, when `Some`, overrides the platform default data directory
/// (used by tests and by hosts that want to pin the config to a specific path).
pub async fn init(config_dir: Option<String>) -> Result<()> {
    init_tracing();
    ENGINE
        .get_or_try_init(|| async move {
            if let Some(dir) = config_dir.as_deref() {
                crate::state::config::set_data_dir(std::path::PathBuf::from(dir));
            }

            // Blocking file I/O — read off the async runtime.
            let mut config = tokio::task::spawn_blocking(Config::load_or_default).await??;
            tracing::info!(
                client_name = %config.client_name,
                osc_port = config.osc_port,
                "Engine initializing"
            );

            // Mandatory pinning: resolve an unset network_interface before any
            // transport/discovery starts, so they never see a stale
            // never-attempted state.
            let candidates = tokio::task::spawn_blocking(list_interfaces).await??;
            match resolve_network_interface(&config.network_interface, &candidates) {
                InterfaceResolution::AlreadyPinned => {}
                InterfaceResolution::AutoSelected(name) => {
                    config.network_interface = Some(name.clone());
                    let cfg_to_save = config.clone();
                    tokio::task::spawn_blocking(move || cfg_to_save.save()).await??;
                    tracing::info!(iface = %name, "Auto-selected the only usable network interface");
                }
                InterfaceResolution::Blocked(candidate_count) => {
                    tracing::warn!(
                        candidate_count,
                        "No network interface pinned — dynamic discovery is inert until one is selected in Settings → Network"
                    );
                }
            }

            let state = AppState::new(config.clone());
            let reliability = Arc::new(Mutex::new(ReliabilityManager::new()));
            let transport =
                Arc::new(Transport::new(&config, state.clone(), Arc::clone(&reliability)).await?);
            let discovery =
                Arc::new(Discovery::new(&config, state.clone(), Arc::clone(&transport)).await?);

            // MIDI input listener (desktop only; no-op on iOS/Android). Fires
            // per-channel macros bound to a Note On / CC. It owns its own OS
            // thread + tokio task, so nothing needs storing on EngineHandle.
            crate::midi::start(
                state.clone(),
                Arc::clone(&transport),
                Arc::clone(&reliability),
            );

            // Retransmit poller for unacked critical messages — see
            // `reliability::spawn_retransmit_loop`.
            crate::reliability::spawn_retransmit_loop(
                state.clone(),
                Arc::clone(&transport),
                Arc::clone(&reliability),
            );

            Ok::<_, anyhow::Error>(EngineHandle {
                state,
                transport,
                reliability,
                _discovery: discovery,
            })
        })
        .await?;
    Ok(())
}

/// Install a `tracing` subscriber so engine diagnostics (send failures, decode
/// errors, permission-denied, mDNS failures…) actually appear instead of being
/// dropped. Writes to stderr, which surfaces under `flutter run`. Level is
/// controlled by `RUST_LOG` (defaults to `info`). `try_init` is a no-op if a
/// global subscriber is already set, so repeated `init()` calls and the test
/// harness are safe.
#[frb(ignore)]
fn init_tracing() {
    use tracing_subscriber::{fmt, EnvFilter};
    let filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new("info"))
        // `mdns-sd` logs a per-interface "No route to host" ERROR for every
        // tunnel / cellular / virtual NIC on each query (it multicasts out them
        // all). On iOS with a VPN that's a dozen+ benign errors per query —
        // silence the crate's own logging (our own mDNS diagnostics are emitted
        // from `discovery::` and are unaffected).
        .add_directive(
            "mdns_sd=off"
                .parse()
                .expect("static tracing directive is valid"),
        );
    let _ = fmt().with_env_filter(filter).with_target(false).try_init();
}

/// Internal: borrow the live engine. Panics if `init()` hasn't completed.
#[frb(ignore)]
pub fn engine() -> &'static EngineHandle {
    ENGINE
        .get()
        .expect("patch_core::api::init() must be called before any other API function")
}

// ── Messaging ────────────────────────────────────────────────────────────────

/// Fire an OSC message to an external target (e.g. QLab). Used by the UI's
/// dual-action macro (the macro sends its Patch message *and* this OSC packet).
/// Validates before touching `engine()` — same pattern as `upsert_macro` — so a
/// bad target returns Err without a running engine; `dispatch_osc` validates
/// again for its other caller (the MIDI fire path), which doesn't go through
/// `engine()` at all.
pub async fn send_osc_macro(
    address: String,
    port: u16,
    path: String,
    arg: Option<String>,
    arg_type: OscArgKind,
) -> Result<()> {
    let target = OscTarget {
        address,
        port,
        path,
        arg,
        arg_type,
    };
    channel::validate_osc_target(&target)?;
    crate::messaging::dispatch_osc(&engine().transport, &target).await
}

/// Fire a Macro from the UI (tap or F-key): `channel_id` names the Channel a
/// Channel Macro lives on, `None` means a Global Macro. Routing — DM-open
/// precedence, own-channel vs current selection, OSC dual-action exactly once
/// — is owned by `macro_router`, the same brain every other trigger source
/// (MIDI, key binding) goes through. See ADR-0009.
pub async fn fire_macro(channel_id: Option<String>, label: String) -> Result<()> {
    let h = engine();
    crate::macro_router::fire_identified(
        &h.state,
        &h.transport,
        &h.reliability,
        channel_id.as_deref(),
        &label,
    )
    .await
}

/// Fire whatever Macro is bound to key `label`. Precedence is engine-owned:
/// a Channel Macro on a currently-selected Channel beats a Global Macro on
/// the same key; unselected Channels' bindings never fire. Returns whether a
/// macro was bound (the UI consumes the key event only if so).
pub async fn fire_key_binding(label: String) -> Result<bool> {
    let h = engine();
    let channels = h.state.get_channels().await;
    let globals = h.state.config().await.global_macros;
    let selected = h.state.selected_channels().await;
    Ok(crate::macro_router::fire_key_bound_macro(
        &h.state,
        &h.transport,
        &h.reliability,
        &channels,
        &globals,
        &selected,
        &label,
    )
    .await)
}

/// Sends a message on a channel. Returns the message_id.
pub async fn send_message(channel_id: String, payload: String, priority: i32) -> Result<String> {
    let h = engine();
    let prio = Priority::try_from(priority).unwrap_or(Priority::Info);
    let id = crate::messaging::dispatch_channel_message(
        &h.state,
        &h.transport,
        &h.reliability,
        channel_id,
        payload,
        prio,
    )
    .await?;
    Ok(id.to_string())
}

/// Send a direct (peer-to-peer) message to one peer. Stored locally under a
/// `dm:{peer_id}` key and unicast **only** to that peer (never broadcast/relayed).
/// Returns the message_id. DMs are best-effort (no retransmit) in this version.
pub async fn send_direct_message(
    peer_id: String,
    payload: String,
    priority: i32,
) -> Result<String> {
    let h = engine();
    let target = Uuid::parse_str(&peer_id).map_err(|_| anyhow::anyhow!("invalid peer id"))?;
    let prio = Priority::try_from(priority).unwrap_or(Priority::Info);
    Ok(
        crate::messaging::dispatch_dm(&h.state, &h.transport, target, payload, prio)
            .await?
            .to_string(),
    )
}

/// Flashes a channel (sends to peers + fires local event).
pub async fn send_flash(channel_id: String) -> Result<()> {
    let h = engine();
    crate::messaging::dispatch_flash(&h.state, &h.transport, channel_id).await
}

/// Send a direct flash/attention ping to one peer. Unicast **only** to that peer
/// (never broadcast); the recipient's DM thread with us flashes. Locally we flash
/// our own `dm:{peer}` thread so the sender sees the ping land too. Best-effort
/// (no ACK/retransmit), mirroring `send_direct_message`.
pub async fn send_dm_flash(peer_id: String) -> Result<()> {
    let h = engine();
    let target = Uuid::parse_str(&peer_id).map_err(|_| anyhow::anyhow!("invalid peer id"))?;
    crate::messaging::dispatch_dm_flash(&h.state, &h.transport, target).await
}

/// Announce departure so peers drop us promptly instead of waiting out the
/// heartbeat timeout. Call from the Dart side when the app is closing. Sends a
/// `/patch/bye` directly on the socket (bypassing the queue, so it flushes
/// before the process exits) to every known/static peer plus a LAN broadcast.
/// Best-effort and idempotent — safe to call more than once.
pub async fn shutdown() -> Result<()> {
    let Some(h) = ENGINE.get() else { return Ok(()) }; // never initialized
    let config = h.state.config().await;
    let bytes = encode_bye(config.client_id)?;
    tracing::info!("Shutdown — broadcasting /patch/bye ({})", config.client_id);

    // Unicast to all resolved addresses (covers static / AP-isolated / multi-VLAN).
    for peer in h.state.get_peers().await {
        if peer.peer_id == config.client_id {
            continue;
        }
        for addr in peer.all_addrs() {
            let _ = h.transport.send_now(&bytes, addr).await;
        }
    }
    // Broadcast (per-interface) for anyone we haven't resolved yet. Unresolved
    // (no pin yet) stays fully inert outbound too.
    if crate::transport::should_broadcast(config.network_interface.as_deref()) {
        h.transport
            .broadcast_now(&bytes, config.osc_port, config.network_interface.as_deref())
            .await;
    }
    Ok(())
}

// ── Reads ────────────────────────────────────────────────────────────────────

pub async fn get_channels() -> Vec<Channel> {
    engine().state.get_channels().await
}

/// A [`crate::state::peer::Peer`] plus its display [`PeerStatus`] (Online /
/// Stale / Offline), computed against the configured heartbeat interval so
/// the UI never has to re-derive the staleness thresholds itself.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PeerSnapshot {
    pub peer_id: Uuid,
    pub peer_name: String,
    pub channels: Vec<String>,
    pub role: Option<String>,
    pub discovery_mode: peer::DiscoveryMode,
    pub address: String,
    pub osc_port: u16,
    pub last_seen: chrono::DateTime<chrono::Utc>,
    pub departed: bool,
    pub status: peer::PeerStatus,
}

pub async fn get_peers() -> Vec<PeerSnapshot> {
    let h = engine();
    let heartbeat_secs = h.state.config().await.heartbeat_interval_secs;
    h.state
        .get_peers()
        .await
        .into_iter()
        .map(|p| {
            let best = p.best_addr();
            PeerSnapshot {
                status: p.status(heartbeat_secs),
                peer_id: p.peer_id,
                peer_name: p.peer_name,
                channels: p.channels,
                role: p.role,
                discovery_mode: p.discovery_mode,
                address: best.map(|a| a.ip().to_string()).unwrap_or_default(),
                osc_port: best.map(|a| a.port()).unwrap_or(0),
                last_seen: p.last_seen,
                departed: p.departed,
            }
        })
        .collect()
}

pub async fn get_messages(channel_id: String, limit: u32) -> Vec<PatchMessage> {
    engine()
        .state
        .get_messages(&channel_id, limit as usize)
        .await
}

pub fn get_interfaces() -> Result<Vec<InterfaceInfo>> {
    list_interfaces()
}

/// Names of available MIDI input ports (for a future port-selector UI). Empty on
/// platforms without a MIDI backend (iOS/Android) or when no devices are present.
pub fn get_midi_ports() -> Vec<String> {
    crate::midi::list_ports()
}

/// Lightweight snapshot of the runtime-mutable parts of the config.
/// Mirrors the JSON payload the legacy `get_config` command returned.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConfigSnapshot {
    pub client_name: String,
    pub role: Option<String>,
    pub osc_port: u16,
    pub network_interface: Option<String>,
    pub static_peers: Vec<StaticPeer>,
    pub flash_on_critical: bool,
    pub flash_on_message: bool,
    pub flash_count: u8,
    pub macros_columns: u8,
    pub hide_keyboard: bool,
    pub audible_alert: bool,
    pub flash_whole_screen: bool,
    pub global_macros: Vec<MacroMessage>,
    /// Presence heartbeat interval (seconds). Editable in Settings; the
    /// online/amber/grey dot thresholds derived from it live engine-side in
    /// `Peer::status` (see `PeerSnapshot`), not in the UI.
    pub heartbeat_interval_secs: u32,
    /// True while `client_name` is still the system-seeded default — drives the
    /// first-run "set your name" prompt in the UI.
    pub name_is_default: bool,
}

pub async fn get_config() -> ConfigSnapshot {
    let cfg = engine().state.config().await;
    // Compute before moving fields out of `cfg` below.
    let name_is_default = cfg.name_is_default();
    ConfigSnapshot {
        client_name: cfg.client_name,
        role: cfg.role,
        osc_port: cfg.osc_port,
        network_interface: cfg.network_interface,
        static_peers: cfg.static_peers,
        flash_on_critical: cfg.flash_on_critical,
        flash_on_message: cfg.flash_on_message,
        flash_count: cfg.flash_count,
        macros_columns: cfg.macros_columns,
        hide_keyboard: cfg.hide_keyboard,
        audible_alert: cfg.audible_alert,
        flash_whole_screen: cfg.flash_whole_screen,
        global_macros: cfg.global_macros,
        heartbeat_interval_secs: cfg.heartbeat_interval_secs as u32,
        name_is_default,
    }
}

// ── Mutations ────────────────────────────────────────────────────────────────

pub async fn set_client_name(name: String) -> Result<()> {
    let trimmed = name.trim();
    if trimmed.is_empty() {
        anyhow::bail!("name must be a non-empty string");
    }
    engine().state.set_client_name(trimmed.to_string()).await
}

/// Set (or clear) the self-assigned role. An empty/whitespace-only string clears
/// it (`None`); otherwise the trimmed value is stored and broadcast in presence.
pub async fn set_role(role: Option<String>) -> Result<()> {
    let role = role.and_then(|s| {
        let t = s.trim().to_string();
        if t.is_empty() {
            None
        } else {
            Some(t)
        }
    });
    engine().state.set_role(role).await
}

/// Pass `None` (or an empty string at the caller) to bind all interfaces.
pub async fn set_interface(name: Option<String>) -> Result<()> {
    let iface = match name.as_deref() {
        None | Some("") => None,
        Some(s) => Some(s.to_string()),
    };
    engine().state.set_network_interface(iface).await
}

/// Apply a partial update of the scalar behavior settings — one command for
/// any subset of them, `None` fields untouched (issue #179, ADR-0003-compatible:
/// `AppState` stays the facade, just one deep method instead of seven shallow).
pub async fn patch_config(patch: crate::state::ConfigPatch) -> Result<()> {
    engine().state.patch_config(patch).await
}

/// Restore the scalar behavior settings to their factory defaults — the
/// engine owns the default values (issue #180); the UI sends no literals.
pub async fn reset_behavior_config() -> Result<()> {
    engine().state.reset_behavior_config().await
}

pub async fn set_heartbeat_interval(secs: u64) -> Result<()> {
    engine().state.set_heartbeat_interval(secs).await
}

/// Change the OSC UDP port and rebind the live socket — no restart. Validated
/// 1024–65535. The socket is rebound **first** (so a bind failure, e.g. the port
/// is already in use, surfaces as an error and leaves the persisted config
/// untouched); only on success is the new port saved.
pub async fn set_osc_port(port: u16) -> Result<()> {
    if !(1024..=65535).contains(&port) {
        anyhow::bail!("OSC port must be 1024–65535 (got {})", port);
    }
    let h = engine();
    let mut config = h.state.config().await;
    config.osc_port = port;
    h.transport.rebind(&config).await?;
    h.state.set_osc_port(port).await
}

pub async fn set_channel_flash(
    channel_id: String,
    flash_on_critical: Option<bool>,
    flash_on_message: Option<bool>,
    flash_count: Option<u8>,
) -> Result<()> {
    engine()
        .state
        .set_channel_flash(
            &channel_id,
            flash_on_critical,
            flash_on_message,
            flash_count,
        )
        .await
}

pub async fn add_static_peer(address: String, port: u16, label: Option<String>) -> Result<()> {
    engine().state.add_static_peer(address, port, label).await
}

pub async fn remove_static_peer(address: String, port: u16) -> Result<()> {
    engine().state.remove_static_peer(&address, port).await
}

/// Remove dynamic (OscBeacon / Mdns) peers not heard from within `max_age_secs`.
/// ManualIp / static peers are never removed.
pub async fn clear_stale_peers(max_age_secs: u64) -> Result<()> {
    let removed = engine().state.clear_stale_peers(max_age_secs).await;
    for id in removed {
        engine().state.publish(AppEvent::PeerExpired(id)).await;
    }
    Ok(())
}

pub async fn upsert_channel(
    id: String,
    display_name: Option<String>,
    color: Option<String>,
) -> Result<()> {
    let id_for_name = id.clone();
    let display_name = display_name.unwrap_or(id_for_name);
    let color = color.unwrap_or_else(|| "#607D8B".to_string());
    // Validate before touching the engine — same as before this was folded into
    // Channel::new, a bad id must error without requiring init() to have run.
    let mut channel = Channel::new(id, display_name, color)?;
    let h = engine();
    let cfg = h.state.config().await;
    channel.flash_on_critical = cfg.flash_on_critical;
    channel.flash_on_message = cfg.flash_on_message;
    h.state.upsert_channel(channel).await;
    Ok(())
}

pub async fn delete_channel(id: String) -> Result<()> {
    engine().state.delete_channel(&id).await
}

/// Clear the message buffer for a specific channel, or all channels when `channel_id` is `None`.
pub async fn clear_messages(channel_id: Option<String>) -> Result<()> {
    engine().state.clear_messages(channel_id.as_deref()).await;
    Ok(())
}

/// Export messages to a CSV file at `path`.
/// When `channel_id` is `Some`, only that channel's messages are exported.
/// When `None`, all channels are exported (a `channel` column is included).
pub async fn export_messages(channel_id: Option<String>, path: String) -> Result<()> {
    let msgs = engine().state.get_all_messages().await;
    let csv = crate::state::export::messages_to_csv(&msgs, channel_id.as_deref());
    tokio::task::spawn_blocking(move || std::fs::write(&path, csv)).await??;
    Ok(())
}

pub async fn reset_channels() -> Result<()> {
    engine().state.reset_channels().await
}

// ── Channel sharing over the network ──────────────────────────────────────────

/// Ask a peer (by id) for its channel layout. The peer replies with a
/// `/patch/channels/announce`, surfaced to the UI as a `ChannelsOffered` event —
/// it is **not** auto-applied; the UI previews and calls `adopt_channels`.
pub async fn request_channels(peer_id: String) -> Result<()> {
    let h = engine();
    crate::messaging::send_to_peer_by_id(&h.state, &h.transport, &peer_id, encode_channels_request)
        .await
}

/// Adopt channels offered by a peer — **merge** (adds only ids we don't already
/// have; never overwrites or deletes). Returns the number actually added.
pub async fn adopt_channels(channels: Vec<Channel>) -> Result<u32> {
    Ok(engine().state.merge_channels(channels).await? as u32)
}

// ── Global macro sharing over the network ──────────────────────────────────────

/// Ask a peer (by id) for its global macros. The peer replies with a
/// `/patch/macros/announce`, surfaced to the UI as a `GlobalMacrosOffered`
/// event — it is **not** auto-applied; the UI previews (`preview_global_macros`)
/// and calls `adopt_global_macros`.
pub async fn request_global_macros(peer_id: String) -> Result<()> {
    let h = engine();
    crate::messaging::send_to_peer_by_id(&h.state, &h.transport, &peer_id, encode_macros_request)
        .await
}

/// Classify offered global macros against what this machine already has —
/// for the import preview dialog. Read-only; does not add or persist
/// anything. Each item reports whether it's already had, will be added
/// as-is, will be added with a colliding binding stripped, or will be
/// skipped outright (invalid OSC target).
pub async fn preview_global_macros(global_macros: Vec<MacroMessage>) -> Vec<MacroImportOutcome> {
    engine().state.preview_global_macros(global_macros).await
}

/// Adopt global macros offered by a peer — **merge** (adds new macros,
/// strips colliding bindings rather than excluding the macro, drops macros
/// with an invalid OSC target). Returns the same per-item classification as
/// `preview_global_macros` so the UI can report what happened.
pub async fn adopt_global_macros(
    global_macros: Vec<MacroMessage>,
) -> Result<Vec<MacroImportOutcome>> {
    engine().state.merge_global_macros(global_macros).await
}

/// The shared trim → reject-empty-label → validate-OSC → build step for both
/// Macro homes (#186). ADR-0002's live-edit trust level: an invalid OSC
/// target rejects immediately, before any state mutation.
fn build_validated_macro(
    label: String,
    payload: String,
    priority: i32,
    key_binding: Option<String>,
    midi_note: Option<u8>,
    midi_cc: Option<u8>,
    osc: Option<OscTarget>,
) -> Result<MacroMessage> {
    let label = label.trim().to_string();
    if label.is_empty() {
        anyhow::bail!("label must be non-empty");
    }
    if let Some(o) = &osc {
        channel::validate_osc_target(o)?;
    }
    Ok(MacroMessage {
        label,
        payload,
        key_binding,
        priority,
        midi_note,
        midi_cc,
        osc,
    })
}

/// Upsert a Macro into either home, keyed on `channel_id` (#186): `Some` is a
/// Channel Macro (stored inside that Channel), `None` is a Global Macro
/// (stored in config, fired on the current selection) — the same
/// discriminator macro routing uses (ADR-0009). The engine-side registries
/// stay split behind this one entry (ADR-0003 lock ownership).
///
/// `original_label` is the macro's label before this edit — pass it when
/// editing an existing macro (even if the label didn't change) so a rename
/// updates that macro in place instead of appending a new one under the new
/// label. Omit (`None`) only when creating a brand-new macro.
#[allow(clippy::too_many_arguments)]
pub async fn upsert_macro(
    channel_id: Option<String>,
    original_label: Option<String>,
    label: String,
    payload: String,
    priority: i32,
    key_binding: Option<String>,
    midi_note: Option<u8>,
    midi_cc: Option<u8>,
    osc: Option<OscTarget>,
) -> Result<()> {
    let macro_msg = build_validated_macro(
        label,
        payload,
        priority,
        key_binding,
        midi_note,
        midi_cc,
        osc,
    )?;
    match channel_id {
        Some(id) => {
            engine()
                .state
                .upsert_macro(&id, original_label.as_deref(), macro_msg)
                .await
        }
        None => {
            engine()
                .state
                .upsert_global_macro(original_label.as_deref(), macro_msg)
                .await
        }
    }
}

pub async fn delete_macro(channel_id: String, label: String) -> Result<()> {
    engine().state.delete_macro(&channel_id, &label).await
}

/// Reorder a channel's macros to match `ordered_labels` (drag-to-reorder).
pub async fn reorder_macros(channel_id: String, ordered_labels: Vec<String>) -> Result<()> {
    engine()
        .state
        .reorder_macros(&channel_id, ordered_labels)
        .await
}

// ── Global macros ────────────────────────────────────────────────────────────
//
// Shown on every channel's macro panel; fired on the currently-selected
// channel(s) by the UI. Stored on the config, surfaced via `ConfigSnapshot`.

/// Tell the engine which channels the UI currently has selected, so a
/// MIDI-triggered *global* macro fires on the same channel(s) a tap/F-key would.
/// Includes the reserved `__all__` id when the UI is in ALL/broadcast mode.
pub async fn set_selected_channels(ids: Vec<String>) -> Result<()> {
    engine().state.set_selected_channels(ids).await;
    Ok(())
}

/// Tell the engine which peer's DM thread is currently open in the UI (`None`
/// when no DM is open), so a MIDI-triggered macro routes the same way a
/// tap/F-key would — every macro fired while a DM is open goes to that peer
/// instead of a channel (see `_fireMacro` in home_screen.dart).
pub async fn set_dm_target(peer_id: Option<String>) -> Result<()> {
    let parsed = match peer_id {
        Some(s) => Some(Uuid::parse_str(&s).map_err(|_| anyhow::anyhow!("invalid peer id"))?),
        None => None,
    };
    engine().state.set_dm_target(parsed).await;
    Ok(())
}

pub async fn delete_global_macro(label: String) -> Result<()> {
    engine().state.delete_global_macro(&label).await
}

/// Restore the factory default global macros (replaces the current set).
pub async fn reset_global_macros() -> Result<()> {
    engine().state.reset_global_macros().await
}

/// Reorder global macros to match `ordered_labels` (drag-to-reorder).
pub async fn reorder_global_macros(ordered_labels: Vec<String>) -> Result<()> {
    engine().state.reorder_global_macros(ordered_labels).await
}

// ── Show Files ────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ShowFileSaved {
    pub slug: String,
    pub name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ShowFileLoaded {
    pub name: String,
    pub channel_count: u32,
}

pub async fn save_show_file(name: String) -> Result<ShowFileSaved> {
    let name = name.trim().to_string();
    if name.is_empty() {
        anyhow::bail!("name must be a non-empty string");
    }
    let h = engine();
    let channels = h.state.get_channels().await;
    let cfg = h.state.config().await;
    let sf = ShowFileConfig::new(&name, channels, cfg.static_peers);
    let slug = tokio::task::spawn_blocking(move || show_file::save_show_file(&sf)).await??;
    Ok(ShowFileSaved { slug, name })
}

/// Export the current channel layout to an arbitrary file path (file-picker).
pub async fn export_layout(path: String, name: String) -> Result<()> {
    let name = name.trim().to_string();
    let name = if name.is_empty() {
        "Exported Layout".to_string()
    } else {
        name
    };
    let h = engine();
    let channels = h.state.get_channels().await;
    let cfg = h.state.config().await;
    let sf = ShowFileConfig::new(name, channels, cfg.static_peers);
    let raw = toml::to_string_pretty(&sf)?;
    tokio::task::spawn_blocking(move || std::fs::write(&path, raw)).await??;
    Ok(())
}

/// Import a show file from an arbitrary file path (file-picker) and apply it.
pub async fn import_layout(path: String) -> Result<ShowFileLoaded> {
    let read_path = path.clone();
    let raw = tokio::task::spawn_blocking(move || std::fs::read_to_string(&read_path)).await??;
    let sf: ShowFileConfig = toml::from_str(&raw)?;
    let name = sf.name.clone();
    let channel_count = sf.channels.len() as u32;
    engine()
        .state
        .apply_show_file_full(sf.channels, sf.static_peers)
        .await?;
    Ok(ShowFileLoaded {
        name,
        channel_count,
    })
}

pub async fn load_show_file(slug: String) -> Result<ShowFileLoaded> {
    let sf = tokio::task::spawn_blocking(move || show_file::load_show_file(&slug)).await??;
    let name = sf.name.clone();
    let channel_count = sf.channels.len() as u32;
    engine()
        .state
        .apply_show_file_full(sf.channels, sf.static_peers)
        .await?;
    Ok(ShowFileLoaded {
        name,
        channel_count,
    })
}

pub fn list_show_files() -> Result<Vec<ShowFileMeta>> {
    show_file::list_show_files()
}

pub fn delete_show_file(slug: String) -> Result<()> {
    show_file::delete_show_file(&slug)
}

// ── Event stream ─────────────────────────────────────────────────────────────

/// Subscribe to engine events. Each event is converted to a wire-friendly
/// `PatchAppEvent` and pushed onto the sink. Codegen exposes this in Dart as
/// `Stream<PatchAppEvent> subscribeEvents()`.
///
/// `async` so FRB invokes us with its Tokio runtime as the ambient context —
/// otherwise `tokio::spawn` below has no reactor to attach to.
pub async fn subscribe_events(sink: crate::frb_generated::StreamSink<PatchAppEvent>) -> Result<()> {
    let mut rx = engine().state.subscribe();
    tokio::spawn(async move {
        while let EventForward::Push(ev) = forward_decision(rx.recv().await) {
            if sink.add(ev).is_err() {
                break; // Dart-side stream was closed.
            }
        }
    });
    Ok(())
}

/// What the event-forwarding loop should do with one `recv()` outcome —
/// extracted from [`subscribe_events`] so the lag-recovery rule is testable
/// without an FRB sink.
#[frb(ignore)]
pub(crate) enum EventForward {
    Push(PatchAppEvent),
    Stop,
}

#[frb(ignore)]
pub(crate) fn forward_decision(
    res: std::result::Result<AppEvent, tokio::sync::broadcast::error::RecvError>,
) -> EventForward {
    use tokio::sync::broadcast::error::RecvError;
    match res {
        Ok(ev) => EventForward::Push(PatchAppEvent::from(ev)),
        // This subscriber fell behind and `n` events were dropped for it —
        // possibly including Message events, which the Dart store never
        // refetches on its own. Tell it to resync rather than losing them
        // silently. Subscriber-local by design: the lag is per-receiver, so
        // it must not go out on the broadcast bus.
        Err(RecvError::Lagged(n)) => {
            tracing::warn!("FRB event sink lagged by {} events — sending Desynced", n);
            EventForward::Push(PatchAppEvent::Desynced)
        }
        Err(RecvError::Closed) => EventForward::Stop,
    }
}

/// Wire-format event delivered to the Flutter UI. Decoupled from the internal
/// `AppEvent` so the wire shape stays explicit (UUIDs serialized as strings,
/// no internal-only variants leak across the boundary).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum PatchAppEvent {
    Message(PatchMessage),
    MessageAcked {
        message_id: String,
        peer_id: String,
    },
    /// Delivery progress/result for a critical message we sent.
    MessageDelivery {
        message_id: String,
        delivered: u32,
        total: u32,
        failed: bool,
        failed_peers: Vec<String>,
    },
    PeerUpdated(crate::osc::types::PeerPresence),
    PeerExpired {
        peer_id: String,
    },
    ChannelFlash(ChannelFlash),
    ChannelListUpdated,
    /// A peer offered its channel layout (reply to our `request_channels`).
    /// Surfaced for a UI preview/merge prompt — not auto-applied.
    ChannelsOffered {
        from_peer_id: String,
        from_name: String,
        channels: Vec<Channel>,
    },
    /// A peer offered its global macros (reply to our `request_global_macros`).
    /// Surfaced for a UI preview/merge prompt — not auto-applied.
    GlobalMacrosOffered {
        from_peer_id: String,
        from_name: String,
        global_macros: Vec<MacroMessage>,
    },
    ClientNameChanged {
        name: String,
    },
    /// The OS denied network access (iOS/macOS Local Network permission).
    PermissionDenied {
        context: String,
    },
    /// This subscriber's event stream lagged and dropped events — fetched
    /// state (peers, channels, messages) may be stale and must be re-read.
    /// Never converted from an [`AppEvent`]: it's synthesized per-subscriber
    /// in [`subscribe_events`] when *that* receiver falls behind.
    Desynced,
}

impl From<AppEvent> for PatchAppEvent {
    fn from(ev: AppEvent) -> Self {
        match ev {
            AppEvent::MessageReceived(m) => Self::Message(m),
            AppEvent::MessageAcked {
                message_id,
                peer_id,
            } => Self::MessageAcked {
                message_id: message_id.to_string(),
                peer_id: peer_id.to_string(),
            },
            AppEvent::MessageDelivery {
                message_id,
                delivered,
                total,
                failed,
                failed_peers,
            } => Self::MessageDelivery {
                message_id: message_id.to_string(),
                delivered,
                total,
                failed,
                failed_peers,
            },
            AppEvent::PeerUpdated(p) => Self::PeerUpdated(p),
            AppEvent::PeerExpired(id) => Self::PeerExpired {
                peer_id: id.to_string(),
            },
            AppEvent::ChannelFlash(f) => Self::ChannelFlash(f),
            AppEvent::ChannelListUpdated => Self::ChannelListUpdated,
            AppEvent::ChannelsOffered {
                from_peer_id,
                from_name,
                channels,
            } => Self::ChannelsOffered {
                from_peer_id: from_peer_id.to_string(),
                from_name,
                channels,
            },
            AppEvent::GlobalMacrosOffered {
                from_peer_id,
                from_name,
                global_macros,
            } => Self::GlobalMacrosOffered {
                from_peer_id: from_peer_id.to_string(),
                from_name,
                global_macros,
            },
            AppEvent::ClientNameChanged(name) => Self::ClientNameChanged { name },
            AppEvent::PermissionDenied { context } => Self::PermissionDenied { context },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn osc(addr: &str) -> OscTarget {
        OscTarget {
            address: addr.into(),
            port: 53000,
            path: "/cue/1/start".into(),
            arg: None,
            arg_type: crate::osc::types::OscArgKind::String,
        }
    }

    /// #186: the trim → reject-empty → validate-OSC → build step exists once,
    /// shared by the Channel-Macro and Global-Macro targets of `upsert_macro`.
    #[test]
    fn build_validated_macro_trims_label_and_carries_fields() {
        let m = build_validated_macro(
            "  GO  ".into(),
            "GO GO GO".into(),
            3,
            Some("F1".into()),
            Some(60),
            None,
            Some(osc("10.0.0.9")),
        )
        .unwrap();
        assert_eq!(m.label, "GO");
        assert_eq!(m.payload, "GO GO GO");
        assert_eq!(m.priority, 3);
        assert_eq!(m.key_binding.as_deref(), Some("F1"));
        assert_eq!(m.midi_note, Some(60));
        assert!(m.osc.is_some());
    }

    #[test]
    fn build_validated_macro_rejects_blank_label_and_invalid_osc() {
        assert!(
            build_validated_macro("   ".into(), "x".into(), 1, None, None, None, None).is_err()
        );
        // ADR-0002 live-edit trust level: an invalid OSC target rejects
        // immediately, for both macro homes.
        assert!(build_validated_macro(
            "GO".into(),
            "x".into(),
            1,
            None,
            None,
            None,
            Some(osc("not-an-ip"))
        )
        .is_err());
    }

    #[test]
    fn lagged_event_subscriber_is_told_to_resync_not_silently_skipped() {
        use tokio::sync::broadcast::error::RecvError;
        // The dropped events may include MessageReceived, which the Dart
        // store never refetches on its own — the subscriber must be told.
        assert!(matches!(
            forward_decision(Err(RecvError::Lagged(3))),
            EventForward::Push(PatchAppEvent::Desynced)
        ));
    }

    #[test]
    fn resolve_network_interface_blocked_when_multiple_candidates() {
        let candidates = vec![
            InterfaceInfo {
                name: "en0".into(),
                ip: "192.168.1.5".into(),
            },
            InterfaceInfo {
                name: "en1".into(),
                ip: "10.0.0.2".into(),
            },
        ];
        assert_eq!(
            resolve_network_interface(&None, &candidates),
            InterfaceResolution::Blocked(2)
        );
    }

    #[test]
    fn resolve_network_interface_blocked_when_zero_candidates() {
        assert_eq!(
            resolve_network_interface(&None, &[]),
            InterfaceResolution::Blocked(0)
        );
    }

    #[test]
    fn resolve_network_interface_auto_selects_sole_candidate() {
        let candidates = vec![InterfaceInfo {
            name: "en0".into(),
            ip: "192.168.1.5".into(),
        }];
        assert_eq!(
            resolve_network_interface(&None, &candidates),
            InterfaceResolution::AutoSelected("en0".into())
        );
    }

    #[test]
    fn resolve_network_interface_already_pinned_is_a_noop() {
        let candidates = vec![
            InterfaceInfo {
                name: "en0".into(),
                ip: "192.168.1.5".into(),
            },
            InterfaceInfo {
                name: "en1".into(),
                ip: "10.0.0.2".into(),
            },
        ];
        let current = Some("en0".to_string());
        assert!(matches!(
            resolve_network_interface(&current, &candidates),
            InterfaceResolution::AlreadyPinned
        ));
    }

    /// `upsert_channel` must reject the reserved broadcast id. The validation
    /// runs before `engine()`, so this returns Err without a running engine.
    #[tokio::test]
    async fn upsert_channel_rejects_reserved_all_id() {
        assert!(super::upsert_channel("__all__".into(), None, None)
            .await
            .is_err());
    }

    /// `upsert_macro`/`upsert_global_macro` validate the OSC target (including
    /// arg_type/arg) before touching `engine()`, so a mismatched pair returns
    /// Err without a running engine — same pattern as
    /// `upsert_channel_rejects_reserved_all_id` above.
    #[tokio::test]
    async fn upsert_macro_rejects_mismatched_arg_type() {
        use crate::osc::types::OscArgKind;
        use crate::state::channel::OscTarget;

        let bad = OscTarget {
            address: "127.0.0.1".into(),
            port: 53000,
            path: "/cue/1/start".into(),
            arg: Some("loud".into()),
            arg_type: OscArgKind::Float,
        };
        assert!(super::upsert_macro(
            Some("rf".into()),
            None,
            "GO".into(),
            "payload".into(),
            1,
            None,
            None,
            None,
            Some(bad),
        )
        .await
        .is_err());
    }

    #[tokio::test]
    async fn upsert_global_macro_rejects_mismatched_arg_type() {
        use crate::osc::types::OscArgKind;
        use crate::state::channel::OscTarget;

        let bad = OscTarget {
            address: "127.0.0.1".into(),
            port: 53000,
            path: "/cue/1/start".into(),
            arg: Some("loud".into()),
            arg_type: OscArgKind::Int,
        };
        assert!(super::upsert_macro(
            None,
            None,
            "GO".into(),
            "payload".into(),
            1,
            None,
            None,
            None,
            Some(bad),
        )
        .await
        .is_err());
    }

    /// `send_osc_macro` validates via `dispatch_osc` → `validate_osc_target`
    /// before touching `engine()` (#65), so these all return Err without a
    /// running engine — same pattern as `upsert_channel_rejects_reserved_all_id`.
    #[tokio::test]
    async fn send_osc_macro_rejects_invalid_address() {
        use crate::osc::types::OscArgKind;

        assert!(super::send_osc_macro(
            "not-an-ip".into(),
            53000,
            "/cue/1/start".into(),
            None,
            OscArgKind::String,
        )
        .await
        .is_err());
    }

    #[tokio::test]
    async fn send_osc_macro_rejects_port_zero() {
        use crate::osc::types::OscArgKind;

        assert!(super::send_osc_macro(
            "127.0.0.1".into(),
            0,
            "/cue/1/start".into(),
            None,
            OscArgKind::String,
        )
        .await
        .is_err());
    }

    #[tokio::test]
    async fn send_osc_macro_rejects_path_without_leading_slash() {
        use crate::osc::types::OscArgKind;

        assert!(super::send_osc_macro(
            "127.0.0.1".into(),
            53000,
            "cue/1/start".into(),
            None,
            OscArgKind::String,
        )
        .await
        .is_err());
    }

    #[tokio::test]
    async fn send_osc_macro_rejects_mismatched_arg_type() {
        use crate::osc::types::OscArgKind;

        assert!(super::send_osc_macro(
            "127.0.0.1".into(),
            53000,
            "/cue/1/start".into(),
            Some("loud".into()),
            OscArgKind::Float,
        )
        .await
        .is_err());
    }

    /// Dart's `AppConfig.fromRust` hand-lists every `ConfigSnapshot` field
    /// into the UI model (see ERRORS.md: a forgotten field there silently
    /// resets UI state to its default). Rust can't see across the FFI boundary
    /// to check Dart directly, but it CAN refuse to compile/test silently when
    /// a field is added here and forgotten everywhere else: `serde` always
    /// serializes every field, so if this test's hardcoded key list drifts
    /// from the struct, the mismatch is a hard failure — not a silent reset
    /// three hops away in Flutter.
    ///
    /// If this test fails after editing `ConfigSnapshot`: update the list
    /// below, then go update
    /// `patch_app/lib/models/config.dart::AppConfig.fromRust` to match.
    #[test]
    fn config_snapshot_field_set_is_pinned() {
        use super::{ConfigSnapshot, StaticPeer};

        let snapshot = ConfigSnapshot {
            client_name: String::new(),
            role: None,
            osc_port: 0,
            network_interface: None,
            static_peers: vec![StaticPeer {
                address: String::new(),
                port: 0,
                label: None,
            }],
            flash_on_critical: false,
            flash_on_message: false,
            flash_count: 0,
            macros_columns: 0,
            hide_keyboard: false,
            audible_alert: false,
            flash_whole_screen: false,
            global_macros: Vec::new(),
            heartbeat_interval_secs: 0,
            name_is_default: false,
        };

        let value = serde_json::to_value(&snapshot).expect("ConfigSnapshot must serialize");
        let mut actual: Vec<&str> = value
            .as_object()
            .expect("ConfigSnapshot serializes to a JSON object")
            .keys()
            .map(|k| k.as_str())
            .collect();
        actual.sort_unstable();

        let mut expected = vec![
            "client_name",
            "role",
            "osc_port",
            "network_interface",
            "static_peers",
            "flash_on_critical",
            "flash_on_message",
            "flash_count",
            "macros_columns",
            "hide_keyboard",
            "audible_alert",
            "flash_whole_screen",
            "global_macros",
            "heartbeat_interval_secs",
            "name_is_default",
        ];
        expected.sort_unstable();

        assert_eq!(actual, expected);
    }
}
