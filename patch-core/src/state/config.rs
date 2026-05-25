use anyhow::Result;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use super::channel::{Channel, ShortcutMessage};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    /// Stable client UUID — generated once and persisted.
    pub client_id: Uuid,
    /// Display name shown to other peers.
    pub client_name: String,
    /// UDP port for OSC transport.
    pub osc_port: u16,
    /// TCP port for the Flutter bridge server.
    pub bridge_port: u16,
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
            bridge_port: 9001,
            network_interface: None,
            static_peers: Vec::new(),
            default_channels: default_channels(),
            heartbeat_interval_secs: 7,
            peer_timeout_secs: 30,
            flash_on_critical: true,
        }
    }
}

fn default_true() -> bool { true }

impl Config {
    /// Load from `patch.toml` in the current directory, or create defaults.
    pub fn load_or_default() -> Result<Self> {
        let path = std::path::Path::new("patch.toml");
        if path.exists() {
            let raw = std::fs::read_to_string(path)?;
            let config: Config = toml::from_str(&raw)?;
            Ok(config)
        } else {
            let config = Config::default();
            config.save()?;
            Ok(config)
        }
    }

    pub fn save(&self) -> Result<()> {
        let raw = toml::to_string_pretty(self)?;
        std::fs::write("patch.toml", raw)?;
        Ok(())
    }
}

fn whoami() -> String {
    std::env::var("USER")
        .or_else(|_| std::env::var("USERNAME"))
        .unwrap_or_else(|_| "crew".to_string())
}

fn default_channels() -> Vec<Channel> {
    let specs = [
        ("foh",        "FOH",        "#E53935"),
        ("mon",        "MON",        "#8E24AA"),
        ("rf",         "RF",         "#1E88E5"),
        ("lighting",   "LIGHTING",   "#F4511E"),
        ("video",      "VIDEO",      "#00897B"),
        ("stage",      "STAGE",      "#43A047"),
        ("production", "PRODUCTION", "#FFB300"),
    ];

    specs.iter().map(|(id, name, color)| {
        let mut ch = Channel::new(*id, *name, *color);
        // Seed RF with some practical shortcuts
        if *id == "rf" {
            ch.shortcuts = vec![
                ShortcutMessage { label: "CLEAR".into(),      payload: "Channel clear".into(),     key_binding: Some("F1".into()), priority: 1 },
                ShortcutMessage { label: "HOLD".into(),       payload: "HOLD — do not transmit".into(), key_binding: Some("F2".into()), priority: 2 },
                ShortcutMessage { label: "BATTERY LOW".into(),payload: "Battery low — swap now".into(),  key_binding: Some("F3".into()), priority: 3 },
            ];
        }
        ch
    }).collect()
}
