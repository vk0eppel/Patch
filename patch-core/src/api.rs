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
use tokio::sync::OnceCell;

use crate::discovery::Discovery;
use crate::osc::codec::{encode_flash, encode_message};
use crate::osc::types::{ChannelFlash, PatchMessage, Priority};
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
    // Keep discovery alive for the lifetime of the engine.
    _discovery: Arc<Discovery>,
}

static ENGINE: OnceCell<EngineHandle> = OnceCell::const_new();

/// Initialize the engine. Idempotent — subsequent calls are no-ops.
///
/// `config_dir`, when `Some`, overrides the platform default data directory
/// (used by tests and by hosts that want to pin the config to a specific path).
pub async fn init(config_dir: Option<String>) -> Result<()> {
    ENGINE
        .get_or_try_init(|| async move {
            if let Some(dir) = config_dir.as_deref() {
                crate::state::config::set_data_dir(std::path::PathBuf::from(dir));
            }

            let config = Config::load_or_default()?;
            tracing::info!(
                client_name = %config.client_name,
                osc_port = config.osc_port,
                "Engine initializing"
            );

            let state = AppState::new(config.clone());
            let transport = Arc::new(Transport::new(&config, state.clone()).await?);
            let discovery = Arc::new(Discovery::new(&config, state.clone(), Arc::clone(&transport)).await?);

            Ok::<_, anyhow::Error>(EngineHandle {
                state,
                transport,
                _discovery: discovery,
            })
        })
        .await?;
    Ok(())
}

/// Internal: borrow the live engine. Panics if `init()` hasn't completed.
#[frb(ignore)]
pub fn engine() -> &'static EngineHandle {
    ENGINE.get().expect("patch_core::api::init() must be called before any other API function")
}

// ── Messaging ────────────────────────────────────────────────────────────────

/// Sends a message on a channel. Returns the message_id.
pub async fn send_message(channel_id: String, payload: String, priority: i32) -> Result<String> {
    let h = engine();
    let prio = Priority::try_from(priority).unwrap_or(Priority::Info);
    let config = h.state.config().await;
    let msg = PatchMessage::new(config.client_id, &config.client_name, channel_id, prio, payload);
    let bytes = encode_message(&msg)?;
    h.transport.send_to_peers(bytes, &h.state, &config).await?;
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

// ── Reads ────────────────────────────────────────────────────────────────────

pub async fn get_channels() -> Vec<Channel> {
    engine().state.get_channels().await
}

pub async fn get_peers() -> Vec<crate::state::peer::Peer> {
    engine().state.get_peers().await
}

pub async fn get_messages(channel_id: String, limit: u32) -> Vec<PatchMessage> {
    engine().state.get_messages(&channel_id, limit as usize).await
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

pub async fn set_channel_flash(
    channel_id: String,
    flash_on_critical: Option<bool>,
    flash_on_message: Option<bool>,
    flash_count: Option<u8>,
) -> Result<()> {
    engine().state
        .set_channel_flash(&channel_id, flash_on_critical, flash_on_message, flash_count)
        .await
}

pub async fn add_static_peer(address: String, port: u16, label: Option<String>) -> Result<()> {
    engine().state.add_static_peer(address, port, label).await
}

pub async fn remove_static_peer(address: String, port: u16) -> Result<()> {
    engine().state.remove_static_peer(&address, port).await
}

pub async fn upsert_channel(id: String, display_name: Option<String>, color: Option<String>) -> Result<()> {
    // Validate that the id is safe to embed in an OSC address path.
    if id.is_empty() || id.chars().any(|c| !matches!(c, 'a'..='z' | '0'..='9' | '_' | '-')) {
        anyhow::bail!("channel id '{}' is invalid — use only lowercase letters, digits, _ or -", id);
    }
    let id_for_name = id.clone();
    let display_name = display_name.unwrap_or(id_for_name);
    let color = color.unwrap_or_else(|| "#607D8B".to_string());
    let h = engine();
    let cfg = h.state.config().await;
    let mut channel = Channel::new(id, display_name, color);
    channel.flash_on_critical = cfg.flash_on_critical;
    channel.flash_on_message  = cfg.flash_on_message;
    h.state.upsert_channel(channel).await;
    Ok(())
}

pub async fn delete_channel(id: String) -> Result<()> {
    engine().state.delete_channel(&id).await
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
    engine().state
        .upsert_macro(&channel_id, MacroMessage { label, payload, key_binding, priority })
        .await
}

pub async fn delete_macro(channel_id: String, label: String) -> Result<()> {
    engine().state.delete_macro(&channel_id, &label).await
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
    let slug = session::save_session(&sess)?;
    Ok(SessionSaved { slug, name })
}

/// Export the current channel layout to an arbitrary file path (file-picker).
pub async fn export_layout(path: String, name: String) -> Result<()> {
    let name = name.trim().to_string();
    let name = if name.is_empty() { "Exported Layout".to_string() } else { name };
    let h = engine();
    let channels = h.state.get_channels().await;
    let cfg = h.state.config().await;
    let sess = SessionConfig::new(name, channels, cfg.static_peers);
    let raw = toml::to_string_pretty(&sess)?;
    std::fs::write(&path, raw)?;
    Ok(())
}

/// Import a session from an arbitrary file path (file-picker) and apply it.
pub async fn import_layout(path: String) -> Result<SessionLoaded> {
    let raw = std::fs::read_to_string(&path)?;
    let sess: SessionConfig = toml::from_str(&raw)?;
    let name = sess.name.clone();
    let channel_count = sess.channels.len() as u32;
    // Derive a slug from the file stem or name
    let slug = std::path::Path::new(&path)
        .file_stem()
        .and_then(|s| s.to_str())
        .map(|s| session::slugify(s))
        .unwrap_or_else(|| session::slugify(&name));
    engine().state.apply_session(sess.channels).await?;
    Ok(SessionLoaded { slug, name, channel_count })
}

pub async fn load_session(slug: String) -> Result<SessionLoaded> {
    let sess = session::load_session(&slug)?;
    let name = sess.name.clone();
    let channel_count = sess.channels.len() as u32;
    engine().state.apply_session(sess.channels).await?;
    Ok(SessionLoaded { slug, name, channel_count })
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
pub async fn subscribe_events(
    sink: crate::frb_generated::StreamSink<PatchAppEvent>,
) -> Result<()> {
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
    MessageAcked { message_id: String, peer_id: String },
    PeerUpdated(crate::osc::types::PeerPresence),
    PeerExpired { peer_id: String },
    ChannelFlash(ChannelFlash),
    ChannelListUpdated,
    ClientNameChanged { name: String },
    /// The OS denied network access (iOS/macOS Local Network permission).
    PermissionDenied { context: String },
}

impl From<AppEvent> for PatchAppEvent {
    fn from(ev: AppEvent) -> Self {
        match ev {
            AppEvent::MessageReceived(m) => Self::Message(m),
            AppEvent::MessageAcked { message_id, peer_id } => Self::MessageAcked {
                message_id: message_id.to_string(),
                peer_id: peer_id.to_string(),
            },
            AppEvent::PeerUpdated(p) => Self::PeerUpdated(p),
            AppEvent::PeerExpired(id) => Self::PeerExpired { peer_id: id.to_string() },
            AppEvent::ChannelFlash(f) => Self::ChannelFlash(f),
            AppEvent::ChannelListUpdated => Self::ChannelListUpdated,
            AppEvent::ClientNameChanged(name) => Self::ClientNameChanged { name },
            AppEvent::PermissionDenied { context } => Self::PermissionDenied { context },
        }
    }
}

