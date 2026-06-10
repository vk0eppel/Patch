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
    /// Optional self-assigned production role (free text, e.g. "FOH", "PM"),
    /// broadcast in presence and shown next to this peer's name on other devices.
    #[serde(default)]
    pub role: Option<String>,
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
    /// Play a short sound when a channel flashes (critical message / page /
    /// broadcast). Opt-in via Settings → Behavior. Default off.
    #[serde(default)] // default = false
    pub audible_alert: bool,
    /// Macros shown on every channel's panel (configured once, not tied to a
    /// channel). Fired on the currently-selected channel(s), like a per-channel
    /// macro — so common callouts (YES / NO / COPY …) live in one place instead
    /// of being duplicated onto each channel.
    #[serde(default)]
    pub global_macros: Vec<MacroMessage>,
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
            role: None,
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
            audible_alert: false,
            // Fresh installs get the generic global macro set. NB this is the
            // *first-run* seed; the serde field default stays empty so loading an
            // existing patch.toml never injects these over a user's own setup.
            global_macros: default_global_macros(),
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
    // Colours are spread around the hue wheel — red · amber · green · blue ·
    // purple — so every channel dot/tab is easily told apart at a glance (the old
    // red/deep-orange and teal/green pairs were too close).
    let specs = [
        ("audio", "AUDIO", "#E53935"),       // red
        ("rf", "RF", "#1E88E5"),             // blue
        ("lighting", "LIGHTING", "#FFB300"), // amber
        ("video", "VIDEO", "#8E24AA"),       // purple
        ("stage", "STAGE", "#43A047"),       // green
    ];

    // Channels start with **no** per-channel macros — the common cross-channel
    // callouts ship as global macros instead (see `default_global_macros`). Users
    // add channel-specific macros in Settings when their show needs them.
    specs
        .iter()
        .map(|(id, name, color)| Channel::new(*id, *name, *color))
        .collect()
}

/// Generic, cross-channel macros seeded on a **fresh** install. Global macros are
/// shown on every channel's panel and fire on the currently-selected channel(s),
/// so these are the out-of-the-box quick-sends now that channels start macro-less
/// ("start simple, customise if needed"). Only applied via `Config::default()`
/// (first run) — an existing `patch.toml` keeps whatever it has, since the serde
/// field default for `global_macros` is empty.
pub fn default_global_macros() -> Vec<MacroMessage> {
    // Compact builder (F-key optional, no MIDI binding).
    let g = |label: &str, payload: &str, priority: i32, fkey: Option<&str>| MacroMessage {
        label: label.into(),
        payload: payload.into(),
        key_binding: fkey.map(String::from),
        priority,
        midi_note: None,
        midi_cc: None,
        osc: None,
    };
    vec![
        g("COPY", "Copy", 1, Some("F1")),
        g("STANDBY", "Standby", 2, Some("F2")),
        g("YES", "Yes", 1, Some("F3")),
        g("NO", "No", 1, Some("F4")),
        g("HOLD", "Hold", 2, Some("F5")),
        g("PROBLEM W/", "Problem with:", 3, Some("F6")),
        g("CH1", "Channel 1", 1, None),
        g("CH2", "Channel 2", 1, None),
        g("CH3", "Channel 3", 1, None),
        g("CH4", "Channel 4", 1, None),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Default channels now ship **macro-less** — the common callouts live in the
    /// global set (`default_global_macros`). Locks that so a regression can't
    /// silently reintroduce per-channel seeds.
    #[test]
    fn default_channels_have_no_macros() {
        let channels = default_channels();
        let ids: Vec<&str> = channels.iter().map(|c| c.id.as_str()).collect();
        assert_eq!(ids, vec!["audio", "rf", "lighting", "video", "stage"]);
        for ch in &channels {
            assert!(
                ch.macros.is_empty(),
                "channel {} should ship with no macros",
                ch.id
            );
        }
    }

    /// Locks the seeded global macros so an accidental edit doesn't silently
    /// change what a fresh install ships with. Tuples: (label, priority, F-key).
    #[test]
    fn default_global_macros_seed() {
        let macros = default_global_macros();
        let got: Vec<(&str, i32, Option<&str>)> = macros
            .iter()
            .map(|m| (m.label.as_str(), m.priority, m.key_binding.as_deref()))
            .collect();
        assert_eq!(
            got,
            vec![
                ("COPY", 1, Some("F1")),
                ("STANDBY", 2, Some("F2")),
                ("YES", 1, Some("F3")),
                ("NO", 1, Some("F4")),
                ("HOLD", 2, Some("F5")),
                ("PROBLEM W/", 3, Some("F6")),
                ("CH1", 1, None),
                ("CH2", 1, None),
                ("CH3", 1, None),
                ("CH4", 1, None),
            ]
        );
    }

    /// A fresh `Config` seeds the globals (the serde-default-is-empty half is
    /// covered by `representative_config_deserializes`, whose TOML omits the field).
    #[test]
    fn fresh_config_seeds_globals() {
        assert_eq!(Config::default().global_macros.len(), 10);
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
        // The TOML omits `global_macros`, so serde fills it empty — an existing
        // config is never retro-seeded with the new defaults.
        assert!(cfg.global_macros.is_empty());
    }
}
