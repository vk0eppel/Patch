use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use uuid::Uuid;

use super::channel::{Channel, MacroMessage};

// ── Data directory resolution ────────────────────────────────────────────────
//
// patch.toml + sessions/ live in a platform-appropriate per-user directory
// when running as a bundled app (Library/Application Support on macOS,
// %APPDATA% on Windows, Documents/ on iOS). The dev binary used to write into
// CWD; we keep that as a fallback on first run, migrating in place so existing
// installs don't lose their client_id and channel layout.
//
// Tests and hosts can pin a specific directory via `set_data_dir`.

static DATA_DIR_OVERRIDE: OnceLock<PathBuf> = OnceLock::new();

/// Pin the data directory for this process (config + sessions). Must be called
/// before `Config::load_or_default()`. Subsequent calls are ignored.
pub fn set_data_dir(path: PathBuf) {
    let _ = DATA_DIR_OVERRIDE.set(path);
}

/// Resolves to the directory that holds `patch.toml` and the `sessions/` subdir.
pub fn data_dir() -> PathBuf {
    if let Some(p) = DATA_DIR_OVERRIDE.get() {
        return p.clone();
    }
    dirs::data_dir()
        .map(|d| d.join("Patch"))
        .unwrap_or_else(|| PathBuf::from("."))
}

fn config_path() -> PathBuf {
    data_dir().join("patch.toml")
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    /// Stable client UUID — generated once and persisted.
    pub client_id: Uuid,
    /// Display name shown to other peers.
    pub client_name: String,
    /// UDP port for OSC transport.
    pub osc_port: u16,
    /// Network interface name to bind to (e.g. "en0", "eth0").
    /// None = bind to all interfaces.
    pub network_interface: Option<String>,
    /// Manually-added peer addresses (ip:port).
    pub static_peers: Vec<StaticPeer>,
    /// Channels to create/join on startup.
    pub default_channels: Vec<Channel>,
    /// Heartbeat interval in seconds.
    pub heartbeat_interval_secs: u64,
    /// Peer expiry timeout in seconds (missed heartbeats).
    pub peer_timeout_secs: i64,
    /// Automatically flash the channel when a critical (priority 3) message is received.
    #[serde(default = "default_true")]
    pub flash_on_critical: bool,
    /// Flash the channel on every incoming message, regardless of priority.
    #[serde(default)]  // default = false
    pub flash_on_message: bool,
    /// Number of flash pulses per flash event (1–10).
    #[serde(default = "default_four")]
    pub flash_count: u8,
    /// Number of columns in the macros panel (1–2).
    #[serde(default = "default_one")]
    pub macros_columns: u8,
    /// Hide the software keyboard on channel switch (iOS/Android). Default on.
    #[serde(default = "default_true")]
    pub hide_keyboard: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StaticPeer {
    pub address: String,
    pub port: u16,
    pub label: Option<String>,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            client_id: Uuid::new_v4(),
            client_name: whoami(),
            osc_port: 9000,
            network_interface: None,
            static_peers: Vec::new(),
            default_channels: default_channels(),
            heartbeat_interval_secs: 7,
            peer_timeout_secs: 30,
            flash_on_critical: true,
            flash_on_message: false,
            flash_count: 4,
            macros_columns: 1,
            hide_keyboard: true,
        }
    }
}

fn default_true() -> bool { true }
fn default_four() -> u8 { 4 }
fn default_one()  -> u8 { 1 }

impl Config {
    /// Load `patch.toml` from the platform data directory, migrating an existing
    /// CWD-local config in place if one exists. Creates defaults if neither is
    /// present.
    pub fn load_or_default() -> Result<Self> {
        let target = config_path();
        if target.exists() {
            let raw = std::fs::read_to_string(&target)?;
            return Ok(toml::from_str(&raw)?);
        }

        let legacy = Path::new("patch.toml");
        if legacy.exists() {
            let raw = std::fs::read_to_string(legacy)?;
            let config: Config = toml::from_str(&raw)?;
            // Persist into the new location so subsequent saves don't fight CWD.
            config.save()?;
            tracing::info!(
                "Migrated legacy patch.toml → {}",
                target.display()
            );
            return Ok(config);
        }

        let config = Config::default();
        config.save()?;
        Ok(config)
    }

    pub fn save(&self) -> Result<()> {
        let path = config_path();
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let raw = toml::to_string_pretty(self)?;
        std::fs::write(&path, raw)?;
        Ok(())
    }
}

fn whoami() -> String {
    std::env::var("USER")
        .or_else(|_| std::env::var("USERNAME"))
        .unwrap_or_else(|_| "crew".to_string())
}

pub fn default_channels() -> Vec<Channel> {
    let specs = [
        ("audio",    "AUDIO",    "#E53935"),
        ("rf",       "RF",       "#1E88E5"),
        ("lighting", "LIGHTING", "#F4511E"),
        ("video",    "VIDEO",    "#00897B"),
        ("stage",    "STAGE",    "#43A047"),
    ];

    specs.iter().map(|(id, name, color)| {
        let mut ch = Channel::new(*id, *name, *color);
        match *id {
            "audio" => {
                ch.macros = vec![
                    MacroMessage { label: "YES".into(),          payload: "Yes".into(),          key_binding: Some("F1".into()), priority: 1 },
                    MacroMessage { label: "NO".into(),           payload: "No".into(),           key_binding: Some("F2".into()), priority: 1 },
                    MacroMessage { label: "PROBLEM W/".into(),   payload: "Problem with:".into(),key_binding: Some("F3".into()), priority: 3 },
                ];
            }
            "rf" => {
                ch.macros = vec![
                    MacroMessage { label: "CLEAR".into(),       payload: "Channel clear".into(),          key_binding: Some("F1".into()), priority: 1 },
                    MacroMessage { label: "HOLD".into(),        payload: "HOLD — do not transmit".into(), key_binding: Some("F2".into()), priority: 2 },
                    MacroMessage { label: "LOW BATT".into(),    payload: "Battery low — swap now".into(), key_binding: Some("F3".into()), priority: 3 },
                ];
            }
            _ => {}
        }
        ch
    }).collect()
}
