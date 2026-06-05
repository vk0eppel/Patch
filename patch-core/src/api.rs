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

use crate::discovery::Discovery;
use crate::osc::codec::{encode_bye, encode_flash, encode_message};
use crate::osc::types::{ChannelFlash, PatchMessage, Priority};
use crate::reliability::ReliabilityManager;
use crate::state::channel::{Channel, MacroMessage};
use crate::state::session::{self, SessionConfig, SessionMeta};
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

            // Retransmit poller for unacked critical messages. drain_retransmits
            // increments each entry's retry counter and surfaces it until it is
            // acked or exceeds MAX_RETRIES, so a fixed tick gives bounded retries.
            // When an entry exhausts its retries it comes back as a `failure`,
            // which we surface to the UI as a failed `MessageDelivery` naming the
            // peers that never ACKed.
            let rt_transport = Arc::clone(&transport);
            let rt_reliability = Arc::clone(&reliability);
            let rt_state = state.clone();
            tokio::spawn(async move {
                let mut interval = tokio::time::interval(std::time::Duration::from_millis(400));
                loop {
                    interval.tick().await;
                    let due = rt_reliability.lock().await.drain_retransmits();
                    for (_id, bytes, targets) in due.retransmits {
                        for addr in targets {
                            let _ = rt_transport.send_to(bytes.clone(), addr).await;
                        }
                    }
                    for failure in due.failures {
                        let failed_peers = resolve_peer_names(&rt_state, &failure.unacked).await;
                        rt_state
                            .publish(AppEvent::MessageDelivery {
                                message_id: failure.message_id,
                                delivered: failure.acked,
                                total: failure.total,
                                failed: true,
                                failed_peers,
                            })
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
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));
    let _ = fmt().with_env_filter(filter).with_target(false).try_init();
}

/// Internal: borrow the live engine. Panics if `init()` hasn't completed.
#[frb(ignore)]
pub fn engine() -> &'static EngineHandle {
    ENGINE
        .get()
        .expect("patch_core::api::init() must be called before any other API function")
}

/// Map socket addresses (reliability targets) back to peer display names for the
/// "not delivered to …" alert, falling back to the raw `ip:port` if unknown.
#[frb(ignore)]
async fn resolve_peer_names(state: &AppState, addrs: &[SocketAddr]) -> Vec<String> {
    if addrs.is_empty() {
        return Vec::new();
    }
    let peers = state.get_peers().await;
    addrs
        .iter()
        .map(|addr| {
            peers
                .iter()
                .find(|p| {
                    p.address
                        .parse::<IpAddr>()
                        .map(|ip| SocketAddr::new(ip, p.osc_port))
                        .map(|sa| sa == *addr)
                        .unwrap_or(false)
                })
                .map(|p| p.peer_name.clone())
                .unwrap_or_else(|| addr.to_string())
        })
        .collect()
}

// ── Messaging ────────────────────────────────────────────────────────────────

/// Sends a message on a channel. Returns the message_id.
pub async fn send_message(channel_id: String, payload: String, priority: i32) -> Result<String> {
    let h = engine();
    let prio = Priority::try_from(priority).unwrap_or(Priority::Info);
    let config = h.state.config().await;
    let msg = PatchMessage::new(
        config.client_id,
        &config.client_name,
        channel_id,
        prio,
        payload,
    );
    let bytes = encode_message(&msg)?;
    let targets = h
        .transport
        .send_to_peers(bytes.clone(), &h.state, &config)
        .await?;
    let id = msg.message_id.to_string();
    let message_id = msg.message_id;
    let is_critical = msg.is_critical();
    let target_count = targets.len();
    // Critical messages require ACKs — register for retransmit until every
    // contacted peer acknowledges (or MAX_RETRIES is exceeded).
    if is_critical && target_count > 0 {
        h.reliability.lock().await.track(message_id, bytes, targets);
    }
    h.state.store_message(msg).await;
    // A critical with no peers to send to can never be delivered — surface that
    // immediately (the retransmit poller only knows about *tracked* messages).
    if is_critical && target_count == 0 {
        h.state
            .publish(AppEvent::MessageDelivery {
                message_id,
                delivered: 0,
                total: 0,
                failed: true,
                failed_peers: Vec::new(),
            })
            .await;
    }
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
        if peer.peer_id == config.client_id || !peer.has_address() {
            continue;
        }
        if let Ok(ip) = peer.address.parse::<IpAddr>() {
            let _ = h
                .transport
                .send_now(&bytes, SocketAddr::new(ip, peer.osc_port))
                .await;
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

/// Lightweight snapshot of the runtime-mutable parts of the config.
/// Mirrors the JSON payload the legacy `get_config` command returned.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConfigSnapshot {
    pub client_name: String,
    pub osc_port: u16,
    pub network_interface: Option<String>,
    pub static_peers: Vec<StaticPeer>,
    pub flash_on_critical: bool,
    pub flash_on_message: bool,
    pub flash_count: u8,
    pub macros_columns: u8,
    pub hide_keyboard: bool,
    pub global_macros: Vec<MacroMessage>,
    /// Presence heartbeat interval (seconds). The UI derives its peer
    /// online/amber/grey dot thresholds from this.
    pub heartbeat_interval_secs: u32,
}

pub async fn get_config() -> ConfigSnapshot {
    let cfg = engine().state.config().await;
    ConfigSnapshot {
        client_name: cfg.client_name,
        osc_port: cfg.osc_port,
        network_interface: cfg.network_interface,
        static_peers: cfg.static_peers,
        flash_on_critical: cfg.flash_on_critical,
        flash_on_message: cfg.flash_on_message,
        flash_count: cfg.flash_count,
        macros_columns: cfg.macros_columns,
        hide_keyboard: cfg.hide_keyboard,
        global_macros: cfg.global_macros,
        heartbeat_interval_secs: cfg.heartbeat_interval_secs as u32,
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
    // Validate that the id is safe to embed in an OSC address path. Same rule
    // the codec enforces on inbound packets and sessions (see `valid_channel_id`).
    if !crate::osc::codec::valid_channel_id(&id) {
        anyhow::bail!(
            "channel id '{}' is invalid — use only lowercase letters, digits, _ or - (≤64 chars)",
            id
        );
    }
    let id_for_name = id.clone();
    let display_name = display_name.unwrap_or(id_for_name);
    let color = color.unwrap_or_else(|| "#607D8B".to_string());
    let h = engine();
    let cfg = h.state.config().await;
    let mut channel = Channel::new(id, display_name, color);
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

pub async fn upsert_macro(
    channel_id: String,
    label: String,
    payload: String,
    priority: i32,
    key_binding: Option<String>,
) -> Result<()> {
    let label = label.trim().to_string();
    if label.is_empty() {
        anyhow::bail!("label must be non-empty");
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

pub async fn upsert_global_macro(
    label: String,
    payload: String,
    priority: i32,
    key_binding: Option<String>,
) -> Result<()> {
    let label = label.trim().to_string();
    if label.is_empty() {
        anyhow::bail!("label must be non-empty");
    }
    engine()
        .state
        .upsert_global_macro(MacroMessage {
            label,
            payload,
            key_binding,
            priority,
        })
        .await
}

pub async fn delete_global_macro(label: String) -> Result<()> {
    engine().state.delete_global_macro(&label).await
}

/// Reorder global macros to match `ordered_labels` (drag-to-reorder).
pub async fn reorder_global_macros(ordered_labels: Vec<String>) -> Result<()> {
    engine().state.reorder_global_macros(ordered_labels).await
}

// ── Sessions ─────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionSaved {
    pub slug: String,
    pub name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionLoaded {
    pub slug: String,
    pub name: String,
    pub channel_count: u32,
}

pub async fn save_session(name: String) -> Result<SessionSaved> {
    let name = name.trim().to_string();
    if name.is_empty() {
        anyhow::bail!("name must be a non-empty string");
    }
    let h = engine();
    let channels = h.state.get_channels().await;
    let cfg = h.state.config().await;
    let sess = SessionConfig::new(&name, channels, cfg.static_peers);
    let slug = tokio::task::spawn_blocking(move || session::save_session(&sess)).await??;
    Ok(SessionSaved { slug, name })
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
    let sess = SessionConfig::new(name, channels, cfg.static_peers);
    let raw = toml::to_string_pretty(&sess)?;
    tokio::task::spawn_blocking(move || std::fs::write(&path, raw)).await??;
    Ok(())
}

/// Import a session from an arbitrary file path (file-picker) and apply it.
pub async fn import_layout(path: String) -> Result<SessionLoaded> {
    let read_path = path.clone();
    let raw = tokio::task::spawn_blocking(move || std::fs::read_to_string(&read_path)).await??;
    let sess: SessionConfig = toml::from_str(&raw)?;
    let name = sess.name.clone();
    let channel_count = sess.channels.len() as u32;
    // Derive a slug from the file stem or name
    let slug = std::path::Path::new(&path)
        .file_stem()
        .and_then(|s| s.to_str())
        .map(session::slugify)
        .unwrap_or_else(|| session::slugify(&name));
    engine()
        .state
        .apply_session_full(sess.channels, sess.static_peers)
        .await?;
    Ok(SessionLoaded {
        slug,
        name,
        channel_count,
    })
}

pub async fn load_session(slug: String) -> Result<SessionLoaded> {
    let load_slug = slug.clone();
    let sess = tokio::task::spawn_blocking(move || session::load_session(&load_slug)).await??;
    let name = sess.name.clone();
    let channel_count = sess.channels.len() as u32;
    engine()
        .state
        .apply_session_full(sess.channels, sess.static_peers)
        .await?;
    Ok(SessionLoaded {
        slug,
        name,
        channel_count,
    })
}

pub fn list_sessions() -> Result<Vec<SessionMeta>> {
    session::list_sessions()
}

pub fn delete_session(slug: String) -> Result<()> {
    session::delete_session(&slug)
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
            AppEvent::ClientNameChanged(name) => Self::ClientNameChanged { name },
            AppEvent::PermissionDenied { context } => Self::PermissionDenied { context },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::csv_escape;

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
}
