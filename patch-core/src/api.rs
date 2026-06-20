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

use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;

use anyhow::Result;
use flutter_rust_bridge::frb;
use serde::{Deserialize, Serialize};
use tokio::sync::{Mutex, OnceCell};
use uuid::Uuid;

use crate::discovery::Discovery;
use crate::osc::codec::{
    encode_bye, encode_channels_request, encode_dm, encode_dm_flash, encode_flash, encode_message,
    encode_osc,
};
use crate::osc::types::{ChannelFlash, PatchMessage, Priority};
use crate::reliability::ReliabilityManager;
use crate::state::channel::{Channel, MacroMessage, OscTarget};
use crate::state::show_file::{self, ShowFileConfig, ShowFileMeta};
use crate::state::{config::StaticPeer, AppEvent, AppState, Config};
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
            let config = tokio::task::spawn_blocking(Config::load_or_default).await??;
            tracing::info!(
                client_name = %config.client_name,
                osc_port = config.osc_port,
                "Engine initializing"
            );

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

            // Retransmit poller for unacked critical messages. It ticks every
            // POLL_INTERVAL_MS; each in-flight entry retransmits on its own
            // exponential backoff (drain_retransmits) until acked or it exceeds
            // MAX_RETRIES. When an entry exhausts its retries it comes back as a `failure`,
            // which we surface to the UI as a failed `MessageDelivery` naming the
            // peers that never ACKed.
            let rt_transport = Arc::clone(&transport);
            let rt_reliability = Arc::clone(&reliability);
            let rt_state = state.clone();
            tokio::spawn(async move {
                let mut interval = tokio::time::interval(std::time::Duration::from_millis(
                    crate::reliability::POLL_INTERVAL_MS,
                ));
                loop {
                    interval.tick().await;
                    let due = rt_reliability.lock().await.drain_retransmits();
                    for (_id, bytes, targets) in due.retransmits {
                        for addr in targets {
                            let _ = rt_transport.send_to(bytes.clone(), addr).await;
                        }
                    }
                    for failure in due.failures {
                        crate::reliability::report_delivery_failure(
                            &rt_state,
                            failure.message_id,
                            failure.acked,
                            failure.total,
                            &failure.unacked,
                        )
                        .await;
                    }
                }
            });

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

/// Core send path, shared by the FFI `send_message` and the engine-internal MIDI
/// trigger (`crate::midi`). Encodes the message, unicasts to peers, tracks
/// criticals for ACK/retransmit, stores it locally, and reports an immediate
/// failure for a critical sent with no peers online. Returns the message_id.
#[frb(ignore)]
pub(crate) async fn dispatch_message(
    state: &AppState,
    transport: &Arc<Transport>,
    reliability: &Arc<Mutex<ReliabilityManager>>,
    channel_id: String,
    payload: String,
    prio: Priority,
) -> Result<uuid::Uuid> {
    let config = state.config().await;
    let msg = PatchMessage::new(
        config.client_id,
        &config.client_name,
        channel_id,
        prio,
        payload,
    );
    let bytes = encode_message(&msg)?;
    let targets = transport
        .send_to_peers(bytes.clone(), state, &config)
        .await?;
    let message_id = msg.message_id;
    let is_critical = msg.is_critical();
    // Critical messages require ACKs — register for retransmit until every
    // contacted peer acknowledges (or MAX_RETRIES is exceeded).
    let target_count = if is_critical {
        crate::reliability::track_critical(
            reliability,
            state,
            config.heartbeat_interval_secs,
            message_id,
            bytes,
            targets,
        )
        .await
    } else {
        0
    };
    state.store_message(msg).await;
    // A critical with no peers to send to can never be delivered — surface that
    // immediately (the retransmit poller only knows about *tracked* messages).
    if is_critical && target_count == 0 {
        crate::reliability::report_delivery_failure(state, message_id, 0, 0, &[]).await;
    }
    Ok(message_id)
}

/// Send an arbitrary outbound OSC message to external gear (the "OSC macro"
/// action). Shared by the FFI `send_osc_macro` and the engine-side MIDI fire path.
/// Validates the address + port + path; the packet goes out on the OSC socket via
/// the normal send queue.
#[frb(ignore)]
pub(crate) async fn dispatch_osc(transport: &Arc<Transport>, target: &OscTarget) -> Result<()> {
    let ip: IpAddr = target
        .address
        .parse()
        .map_err(|_| anyhow::anyhow!("invalid OSC address '{}'", target.address))?;
    if target.port == 0 {
        anyhow::bail!("OSC port 0 is not valid");
    }
    let bytes = encode_osc(&target.path, target.arg.as_deref())?;
    transport
        .send_to(bytes, SocketAddr::new(ip, target.port))
        .await?;
    Ok(())
}

/// Fire an OSC message to an external target (e.g. QLab). Used by the UI's
/// dual-action macro (the macro sends its Patch message *and* this OSC packet).
pub async fn send_osc_macro(
    address: String,
    port: u16,
    path: String,
    arg: Option<String>,
) -> Result<()> {
    let target = OscTarget {
        address,
        port,
        path,
        arg,
    };
    dispatch_osc(&engine().transport, &target).await
}

/// Sends a message on a channel. Returns the message_id.
pub async fn send_message(channel_id: String, payload: String, priority: i32) -> Result<String> {
    let h = engine();
    let prio = Priority::try_from(priority).unwrap_or(Priority::Info);
    let id = dispatch_message(
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
    let config = h.state.config().await;
    let msg = PatchMessage::new(
        config.client_id,
        &config.client_name,
        format!("dm:{}", target),
        prio,
        payload,
    );
    let peer = h
        .state
        .get_peers()
        .await
        .into_iter()
        .find(|p| p.peer_id == target)
        .ok_or_else(|| anyhow::anyhow!("peer not found"))?;
    if let Some(addr) = peer.socket_addr() {
        let bytes = encode_dm(&msg, target)?;
        h.transport.send_to(bytes, addr).await?;
    } else {
        tracing::warn!(
            "DM target {} has no address yet — stored locally only",
            target
        );
    }
    let id = msg.message_id.to_string();
    h.state.store_message(msg).await;
    Ok(id)
}

/// Flashes a channel (sends to peers + fires local event).
pub async fn send_flash(channel_id: String) -> Result<()> {
    let h = engine();
    let config = h.state.config().await;
    let flash = ChannelFlash {
        channel_id,
        sender_id: config.client_id,
        sender_name: config.client_name.clone(),
    };
    let bytes = encode_flash(&flash)?;
    h.transport.send_to_peers(bytes, &h.state, &config).await?;
    h.state.publish(AppEvent::ChannelFlash(flash)).await;
    Ok(())
}

/// Send a direct flash/attention ping to one peer. Unicast **only** to that peer
/// (never broadcast); the recipient's DM thread with us flashes. Locally we flash
/// our own `dm:{peer}` thread so the sender sees the ping land too. Best-effort
/// (no ACK/retransmit), mirroring `send_direct_message`.
pub async fn send_dm_flash(peer_id: String) -> Result<()> {
    let h = engine();
    let target = Uuid::parse_str(&peer_id).map_err(|_| anyhow::anyhow!("invalid peer id"))?;
    let config = h.state.config().await;
    let flash = ChannelFlash {
        // Local key: our thread with the target peer.
        channel_id: format!("dm:{}", target),
        sender_id: config.client_id,
        sender_name: config.client_name.clone(),
    };
    let peer = h
        .state
        .get_peers()
        .await
        .into_iter()
        .find(|p| p.peer_id == target)
        .ok_or_else(|| anyhow::anyhow!("peer not found"))?;
    if let Some(addr) = peer.socket_addr() {
        let bytes = encode_dm_flash(&flash, target)?;
        h.transport.send_to(bytes, addr).await?;
    } else {
        tracing::warn!(
            "DM flash target {} has no address yet — local flash only",
            target
        );
    }
    // Fire the local flash so the sender sees their own ping (like send_flash).
    h.state.publish(AppEvent::ChannelFlash(flash)).await;
    Ok(())
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

    // Unicast to resolved peers (covers static / AP-isolated).
    for peer in h.state.get_peers().await {
        if peer.peer_id == config.client_id {
            continue;
        }
        if let Some(addr) = peer.socket_addr() {
            let _ = h.transport.send_now(&bytes, addr).await;
        }
    }
    // Broadcast (per-interface) for anyone we haven't resolved yet.
    h.transport
        .broadcast_now(&bytes, config.osc_port, config.network_interface.as_deref())
        .await;
    Ok(())
}

// ── Reads ────────────────────────────────────────────────────────────────────

pub async fn get_channels() -> Vec<Channel> {
    engine().state.get_channels().await
}

pub async fn get_peers() -> Vec<crate::state::peer::Peer> {
    engine().state.get_peers().await
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
    pub global_macros: Vec<MacroMessage>,
    /// Presence heartbeat interval (seconds). The UI derives its peer
    /// online/amber/grey dot thresholds from this.
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
        None | Some("") | Some("auto") => None,
        Some(s) => Some(s.to_string()),
    };
    engine().state.set_network_interface(iface).await
}

pub async fn set_flash_on_critical(enabled: bool) -> Result<()> {
    engine().state.set_flash_on_critical(enabled).await
}

pub async fn set_flash_on_message(enabled: bool) -> Result<()> {
    engine().state.set_flash_on_message(enabled).await
}

pub async fn set_flash_count(count: u8) -> Result<()> {
    engine().state.set_flash_count(count).await
}

pub async fn set_macros_columns(columns: u8) -> Result<()> {
    engine().state.set_macros_columns(columns).await
}

pub async fn set_hide_keyboard(enabled: bool) -> Result<()> {
    engine().state.set_hide_keyboard(enabled).await
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

pub async fn set_audible_alert(enabled: bool) -> Result<()> {
    engine().state.set_audible_alert(enabled).await
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

/// Escape a value for a quoted CSV field, neutralising spreadsheet formula
/// injection. Excel/Sheets treat a cell starting with `=`, `+`, `-`, `@`, tab,
/// or CR as a formula; since these values come from arbitrary LAN OSC sources,
/// such cells are prefixed with `'`. Double-quotes are doubled per RFC 4180.
fn csv_escape(s: &str) -> String {
    let needs_guard = s
        .chars()
        .next()
        .is_some_and(|c| matches!(c, '=' | '+' | '-' | '@' | '\t' | '\r'));
    let mut out = String::with_capacity(s.len() + 2);
    if needs_guard {
        out.push('\'');
    }
    out.push_str(&s.replace('"', "\"\""));
    out
}

/// Export messages to a CSV file at `path`.
/// When `channel_id` is `Some`, only that channel's messages are exported.
/// When `None`, all channels are exported (a `channel` column is included).
pub async fn export_messages(channel_id: Option<String>, path: String) -> Result<()> {
    let msgs = engine().state.get_all_messages().await;
    let filtered: Vec<_> = match channel_id.as_deref() {
        Some(id) => msgs.into_iter().filter(|m| m.channel_id == id).collect(),
        None => msgs,
    };

    let include_channel = channel_id.is_none();
    let mut out = String::new();

    // Header
    if include_channel {
        out.push_str("timestamp,channel,sender,priority,message\n");
    } else {
        out.push_str("timestamp,sender,priority,message\n");
    }

    for m in &filtered {
        let ts = m.timestamp.format("%Y-%m-%dT%H:%M:%S").to_string();
        let priority = match m.priority {
            crate::osc::types::Priority::Debug => "debug",
            crate::osc::types::Priority::Info => "info",
            crate::osc::types::Priority::Warning => "warning",
            crate::osc::types::Priority::Critical => "critical",
        };
        // Payload/sender/channel are network-sourced — neutralise spreadsheet
        // formula injection in addition to RFC 4180 quote-escaping.
        let payload = csv_escape(&m.payload);
        let sender = csv_escape(&m.sender_name);
        if include_channel {
            out.push_str(&format!(
                "{},\"{}\",\"{}\",{},\"{}\"\n",
                ts,
                csv_escape(&m.channel_id),
                sender,
                priority,
                payload
            ));
        } else {
            out.push_str(&format!(
                "{},\"{}\",{},\"{}\"\n",
                ts, sender, priority, payload
            ));
        }
    }

    tokio::task::spawn_blocking(move || std::fs::write(&path, out)).await??;
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
    let pid = Uuid::parse_str(&peer_id).map_err(|_| anyhow::anyhow!("invalid peer id"))?;
    let peer = h
        .state
        .get_peers()
        .await
        .into_iter()
        .find(|p| p.peer_id == pid)
        .ok_or_else(|| anyhow::anyhow!("peer not found"))?;
    let addr = peer
        .socket_addr()
        .ok_or_else(|| anyhow::anyhow!("peer has no resolved address yet — try again once it's online"))?;
    let config = h.state.config().await;
    let bytes = encode_channels_request(config.client_id)?;
    h.transport.send_to(bytes, addr).await?;
    Ok(())
}

/// Adopt channels offered by a peer — **merge** (adds only ids we don't already
/// have; never overwrites or deletes). Returns the number actually added.
pub async fn adopt_channels(channels: Vec<Channel>) -> Result<u32> {
    Ok(engine().state.merge_channels(channels).await? as u32)
}

/// Validate an OSC macro target before storing it: address parses as an IP, port
/// is non-zero, path is a valid OSC address (starts with '/').
#[frb(ignore)]
fn validate_osc(t: &OscTarget) -> Result<()> {
    t.address
        .parse::<IpAddr>()
        .map_err(|_| anyhow::anyhow!("invalid OSC address '{}'", t.address))?;
    if t.port == 0 {
        anyhow::bail!("OSC port 0 is not valid");
    }
    if !t.path.starts_with('/') {
        anyhow::bail!("OSC path must start with '/'");
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
pub async fn upsert_macro(
    channel_id: String,
    label: String,
    payload: String,
    priority: i32,
    key_binding: Option<String>,
    midi_note: Option<u8>,
    midi_cc: Option<u8>,
    osc: Option<OscTarget>,
) -> Result<()> {
    let label = label.trim().to_string();
    if label.is_empty() {
        anyhow::bail!("label must be non-empty");
    }
    if let Some(o) = &osc {
        validate_osc(o)?;
    }
    engine()
        .state
        .upsert_macro(
            &channel_id,
            MacroMessage {
                label,
                payload,
                key_binding,
                priority,
                midi_note,
                midi_cc,
                osc,
            },
        )
        .await
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

#[allow(clippy::too_many_arguments)]
pub async fn upsert_global_macro(
    label: String,
    payload: String,
    priority: i32,
    key_binding: Option<String>,
    midi_note: Option<u8>,
    midi_cc: Option<u8>,
    osc: Option<OscTarget>,
) -> Result<()> {
    let label = label.trim().to_string();
    if label.is_empty() {
        anyhow::bail!("label must be non-empty");
    }
    if let Some(o) = &osc {
        validate_osc(o)?;
    }
    engine()
        .state
        .upsert_global_macro(MacroMessage {
            label,
            payload,
            key_binding,
            priority,
            // A MIDI-triggered global macro fires on the UI's currently-selected
            // channel(s) — the engine learns that selection via
            // `set_selected_channels` (pushed from Flutter).
            midi_note,
            midi_cc,
            osc,
        })
        .await
}

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
    pub slug: String,
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
    let slug = std::path::Path::new(&path)
        .file_stem()
        .and_then(|s| s.to_str())
        .map(show_file::slugify)
        .unwrap_or_else(|| show_file::slugify(&name));
    engine()
        .state
        .apply_show_file_full(sf.channels, sf.static_peers)
        .await?;
    Ok(ShowFileLoaded {
        slug,
        name,
        channel_count,
    })
}

pub async fn load_show_file(slug: String) -> Result<ShowFileLoaded> {
    let load_slug = slug.clone();
    let sf = tokio::task::spawn_blocking(move || show_file::load_show_file(&load_slug)).await??;
    let name = sf.name.clone();
    let channel_count = sf.channels.len() as u32;
    engine()
        .state
        .apply_show_file_full(sf.channels, sf.static_peers)
        .await?;
    Ok(ShowFileLoaded {
        slug,
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
        loop {
            match rx.recv().await {
                Ok(ev) => {
                    if sink.add(PatchAppEvent::from(ev)).is_err() {
                        // Dart-side stream was closed.
                        break;
                    }
                }
                Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                    tracing::warn!("FRB event sink lagged by {} events", n);
                }
                Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
            }
        }
    });
    Ok(())
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
    ClientNameChanged {
        name: String,
    },
    /// The OS denied network access (iOS/macOS Local Network permission).
    PermissionDenied {
        context: String,
    },
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
            AppEvent::ClientNameChanged(name) => Self::ClientNameChanged { name },
            AppEvent::PermissionDenied { context } => Self::PermissionDenied { context },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::csv_escape;

    /// `upsert_channel` must reject the reserved broadcast id. The validation
    /// runs before `engine()`, so this returns Err without a running engine.
    #[tokio::test]
    async fn upsert_channel_rejects_reserved_all_id() {
        assert!(super::upsert_channel("__all__".into(), None, None)
            .await
            .is_err());
    }

    #[test]
    fn csv_escape_neutralises_formulas() {
        assert_eq!(csv_escape("=1+1"), "'=1+1");
        assert_eq!(csv_escape("-2"), "'-2");
        assert_eq!(csv_escape("+x"), "'+x");
        assert_eq!(csv_escape("@cmd"), "'@cmd");
        assert_eq!(csv_escape("\tlead"), "'\tlead");
    }

    #[test]
    fn csv_escape_passes_through_safe_text() {
        assert_eq!(csv_escape("hello"), "hello");
        assert_eq!(csv_escape("Channel clear"), "Channel clear");
    }

    #[test]
    fn csv_escape_doubles_quotes_and_combines_with_guard() {
        assert_eq!(csv_escape("a\"b"), "a\"\"b");
        assert_eq!(csv_escape("=a\"b"), "'=a\"\"b");
    }

    /// `ConfigSnapshot` has no FFI-generated map — `bridge_client.dart::getConfig()`
    /// hand-lists every field into a `Map<String, dynamic>`, and Dart's
    /// `AppConfig.fromJson` hand-lists them again on the way back out (see
    /// ERRORS.md: a forgotten field there silently resets UI state to its
    /// default). Rust can't see across the FFI boundary to check Dart directly,
    /// but it CAN refuse to compile/test silently when a field is added here and
    /// forgotten everywhere else: `serde` always serializes every field, so if
    /// this test's hardcoded key list drifts from the struct, the mismatch is a
    /// hard failure — not a silent reset three hops away in Flutter.
    ///
    /// If this test fails after editing `ConfigSnapshot`: update the list below,
    /// then go update `bridge_client.dart::getConfig()` and
    /// `patch_app/lib/models/config.dart::AppConfig.fromJson` to match.
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
            "global_macros",
            "heartbeat_interval_secs",
            "name_is_default",
        ];
        expected.sort_unstable();

        assert_eq!(actual, expected);
    }
}
