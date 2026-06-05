use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::sync::RwLock;
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

static DATA_DIR_OVERRIDE: RwLock<Option<PathBuf>> = RwLock::new(None);

/// Pin the data directory for this process (config + sessions). Production calls
/// this at most once during `init`; the tests reset it per case (serialized via
/// [`test_data_dir_guard`]) so each gets its own isolated temp directory.
pub fn set_data_dir(path: PathBuf) {
    *DATA_DIR_OVERRIDE.write().unwrap_or_else(|e| e.into_inner()) = Some(path);
}

/// Resolves to the directory that holds `patch.toml` and the `sessions/` subdir.
pub fn data_dir() -> PathBuf {
    if let Some(p) = DATA_DIR_OVERRIDE
        .read()
        .unwrap_or_else(|e| e.into_inner())
        .as_ref()
    {
        return p.clone();
    }
    dirs::data_dir()
        .map(|d| d.join("Patch"))
        .unwrap_or_else(|| PathBuf::from("."))
}

/// Serializes disk-touching tests so the process-global data-dir override can be
/// repointed at a per-test temp directory without races. Hold the returned guard
/// for the duration of the test, then call [`set_data_dir`]. Async (tokio) mutex
/// so the guard can be held across `.await` without tripping `await_holding_lock`.
#[cfg(test)]
pub(crate) async fn test_data_dir_guard() -> tokio::sync::MutexGuard<'static, ()> {
    static LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());
    LOCK.lock().await
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
    /// Interface to scope the discovery beacon to (e.g. "en0", "eth0"). The OSC
    /// socket always binds `0.0.0.0` (listens on all); this only limits which
    /// NIC's subnet the presence broadcast is sent on. None = announce on all.
    pub network_interface: Option<String>,
    /// Manually-added peer addresses (ip:port).
    pub static_peers: Vec<StaticPeer>,
    /// Channels to create/join on startup.
    pub default_channels: Vec<Channel>,
    /// Heartbeat interval in seconds.
    pub heartbeat_interval_secs: u64,
    /// Automatically flash the channel when a critical (priority 3) message is received.
    #[serde(default = "default_true")]
    pub flash_on_critical: bool,
    /// Flash the channel on every incoming message, regardless of priority.
    #[serde(default)] // default = false
    pub flash_on_message: bool,
    /// Number of flash pulses per flash event (3–7).
    #[serde(default = "default_four")]
    pub flash_count: u8,
    /// Number of columns in the macros panel (1–3).
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
            flash_on_critical: true,
            flash_on_message: false,
            flash_count: 4,
            macros_columns: 1,
            hide_keyboard: true,
        }
    }
}

fn default_true() -> bool {
    true
}
fn default_four() -> u8 {
    4
}
fn default_one() -> u8 {
    1
}

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
            tracing::info!("Migrated legacy patch.toml → {}", target.display());
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
        ("audio", "AUDIO", "#E53935"),
        ("rf", "RF", "#1E88E5"),
        ("lighting", "LIGHTING", "#F4511E"),
        ("video", "VIDEO", "#00897B"),
        ("stage", "STAGE", "#43A047"),
    ];

    specs
        .iter()
        .map(|(id, name, color)| {
            let mut ch = Channel::new(*id, *name, *color);
            match *id {
                "audio" => {
                    ch.macros = vec![
                        MacroMessage {
                            label: "ONE".into(),
                            payload: "One".into(),
                            key_binding: Some("F1".into()),
                            priority: 1,
                        },
                        MacroMessage {
                            label: "TWO".into(),
                            payload: "Two".into(),
                            key_binding: Some("F2".into()),
                            priority: 1,
                        },
                        MacroMessage {
                            label: "CHECK".into(),
                            payload: "Line check".into(),
                            key_binding: Some("F3".into()),
                            priority: 2,
                        },
                        MacroMessage {
                            label: "PROBLEM W/".into(),
                            payload: "Problem with:".into(),
                            key_binding: Some("F4".into()),
                            priority: 3,
                        },
                    ];
                }
                "rf" => {
                    ch.macros = vec![
                        MacroMessage {
                            label: "CLEAR".into(),
                            payload: "Channel clear".into(),
                            key_binding: Some("F1".into()),
                            priority: 1,
                        },
                        MacroMessage {
                            label: "HOLD".into(),
                            payload: "HOLD — do not transmit".into(),
                            key_binding: Some("F2".into()),
                            priority: 2,
                        },
                        MacroMessage {
                            label: "LOW BATT".into(),
                            payload: "Battery low — swap now".into(),
                            key_binding: Some("F3".into()),
                            priority: 3,
                        },
                    ];
                }
                "lighting" => {
                    ch.macros = vec![
                        MacroMessage {
                            label: "READY".into(),
                            payload: "Lighting ready".into(),
                            key_binding: Some("F1".into()),
                            priority: 1,
                        },
                        MacroMessage {
                            label: "FIXTURE DOWN".into(),
                            payload: "Fixture down".into(),
                            key_binding: Some("F2".into()),
                            priority: 2,
                        },
                        MacroMessage {
                            label: "DMX FAULT".into(),
                            payload: "DMX fault — no output".into(),
                            key_binding: Some("F3".into()),
                            priority: 3,
                        },
                    ];
                }
                "video" => {
                    ch.macros = vec![
                        MacroMessage {
                            label: "READY".into(),
                            payload: "Video ready".into(),
                            key_binding: Some("F1".into()),
                            priority: 1,
                        },
                        MacroMessage {
                            label: "GLITCH".into(),
                            payload: "Video glitch".into(),
                            key_binding: Some("F2".into()),
                            priority: 2,
                        },
                        MacroMessage {
                            label: "NO SIGNAL".into(),
                            payload: "No signal — feed lost".into(),
                            key_binding: Some("F3".into()),
                            priority: 3,
                        },
                    ];
                }
                "stage" => {
                    ch.macros = vec![
                        MacroMessage {
                            label: "CLEAR".into(),
                            payload: "Stage clear".into(),
                            key_binding: Some("F1".into()),
                            priority: 1,
                        },
                        MacroMessage {
                            label: "HAZARD".into(),
                            payload: "Hazard on deck".into(),
                            key_binding: Some("F2".into()),
                            priority: 2,
                        },
                        MacroMessage {
                            label: "MEDICAL".into(),
                            payload: "Medical — need help on stage".into(),
                            key_binding: Some("F3".into()),
                            priority: 3,
                        },
                    ];
                }
                _ => {}
            }
            ch
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Locks the seeded default macros so an accidental edit to `default_channels`
    /// doesn't silently change what new installs ship with.
    #[test]
    fn default_channels_seed_macros() {
        let channels = default_channels();
        assert_eq!(channels.len(), 5);
        let by_id = |id: &str| channels.iter().find(|c| c.id == id).unwrap();

        // AUDIO: mic-check vocabulary (ONE/TWO/CHECK/PROBLEM W/).
        let audio: Vec<(&str, i32)> = by_id("audio")
            .macros
            .iter()
            .map(|m| (m.label.as_str(), m.priority))
            .collect();
        assert_eq!(
            audio,
            vec![("ONE", 1), ("TWO", 1), ("CHECK", 2), ("PROBLEM W/", 3)]
        );

        // The three previously-empty channels now each ship 3 info/warning/critical macros.
        for (id, expected) in [
            (
                "lighting",
                [("READY", 1), ("FIXTURE DOWN", 2), ("DMX FAULT", 3)],
            ),
            ("video", [("READY", 1), ("GLITCH", 2), ("NO SIGNAL", 3)]),
            ("stage", [("CLEAR", 1), ("HAZARD", 2), ("MEDICAL", 3)]),
        ] {
            let got: Vec<(&str, i32)> = by_id(id)
                .macros
                .iter()
                .map(|m| (m.label.as_str(), m.priority))
                .collect();
            assert_eq!(got, expected.to_vec(), "macros for channel {id}");
        }
    }

    /// A config in the documented `patch.toml` format must stay deserialisable
    /// into the current `Config` schema — guards against field drift (e.g. the
    /// old `shortcuts`/`bridge_port` leftovers). Kept inline rather than reading
    /// the on-disk `patch.toml`, which is gitignored (a per-user runtime file,
    /// absent on a clean CI checkout).
    #[test]
    fn representative_config_deserializes() {
        let raw = r##"
client_id = "00000000-0000-0000-0000-000000000000"
client_name = "FOH Engineer"
osc_port = 9000
network_interface = "en0"
heartbeat_interval_secs = 7
# Removed field — an existing patch.toml may still carry it; serde must ignore it.
peer_timeout_secs = 30
flash_on_critical = true
flash_on_message = false
flash_count = 4
macros_columns = 2
hide_keyboard = true

[[static_peers]]
address = "192.168.1.50"
port = 9000
label = "Monitor World"

[[default_channels]]
id = "rf"
display_name = "RF"
color = "#1E88E5"
flash_on_critical = true
flash_on_message = false

[[default_channels.macros]]
label = "CLEAR"
payload = "Channel clear"
key_binding = "F1"
priority = 1

[[default_channels]]
id = "audio"
display_name = "AUDIO"
color = "#E53935"
macros = []
flash_on_critical = true
flash_on_message = false
"##;
        let cfg: Config = toml::from_str(raw).expect("representative config must deserialize");
        assert_eq!(cfg.default_channels.len(), 2);
        assert_eq!(cfg.static_peers.len(), 1);
        assert_eq!(cfg.network_interface.as_deref(), Some("en0"));
        assert_eq!(cfg.macros_columns, 2);
        let rf = cfg.default_channels.iter().find(|c| c.id == "rf").unwrap();
        assert_eq!(rf.macros.len(), 1);
        assert_eq!(rf.macros[0].label, "CLEAR");
    }
}
