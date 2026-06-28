use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::sync::RwLock;
use uuid::Uuid;

use super::channel::{
    sanitize_binding_collisions, sanitize_loaded_channels, sanitize_loaded_macros, Channel,
    MacroMessage,
};

// ── Data directory resolution ────────────────────────────────────────────────
//
// patch.toml + show_files/ live in a platform-appropriate per-user directory
// when running as a bundled app (Library/Application Support on macOS,
// %APPDATA% on Windows, Documents/ on iOS). The dev binary used to write into
// CWD; we keep that as a fallback on first run, migrating in place so existing
// installs don't lose their client_id and channel layout.
//
// Tests and hosts can pin a specific directory via `set_data_dir`.

static DATA_DIR_OVERRIDE: RwLock<Option<PathBuf>> = RwLock::new(None);

/// Pin the data directory for this process (config + show_files). Production calls
/// this at most once during `init`; the tests reset it per case (serialized via
/// [`test_data_dir_guard`]) so each gets its own isolated temp directory.
pub fn set_data_dir(path: PathBuf) {
    *DATA_DIR_OVERRIDE.write().unwrap_or_else(|e| e.into_inner()) = Some(path);
}

/// Resolves to the directory that holds `patch.toml` and the `show_files/` subdir.
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

/// The config schema version this build writes. Bump when adding an ordered
/// migration step in [`migrate`].
pub const CURRENT_CONFIG_VERSION: u32 = 1;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    /// Schema version. Absent in pre-versioning files (loads as 0 via the serde
    /// default); [`migrate`] stamps it to [`CURRENT_CONFIG_VERSION`] on load so
    /// the on-disk file is always current after first launch.
    #[serde(default)]
    pub config_version: u32,
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
    /// On macOS/Windows, also pulse a borderless always-on-top overlay across
    /// the display the Patch window occupies on every Flash, in addition to
    /// the existing in-app pulse — so a Flash is visible even when Patch
    /// isn't the focused app. Opt-in via Settings → Behavior. Default off.
    #[serde(default)] // default = false
    pub flash_whole_screen: bool,
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

/// True when `address`/`port` are legal for a StaticPeer: `address` must parse
/// as an `IpAddr` and `port` must be non-zero.
///
/// Single source of truth for "is this StaticPeer legal" — mirrors
/// `Channel::validate_channel_id`. [`StaticPeer::new`] calls it for the one
/// path that constructs a `StaticPeer` from raw FFI args (`api::add_static_peer`);
/// `apply_show_file_full` validates already-deserialized show-file peers
/// directly with this function instead of re-deriving the rule.
pub fn validate_static_peer(address: &str, port: u16) -> anyhow::Result<()> {
    address
        .parse::<std::net::IpAddr>()
        .map_err(|_| anyhow::anyhow!("Invalid IP address: '{}'", address))?;
    if port == 0 {
        anyhow::bail!("Port 0 is not valid for a static peer");
    }
    Ok(())
}

impl StaticPeer {
    pub fn new(
        address: impl Into<String>,
        port: u16,
        label: Option<String>,
    ) -> anyhow::Result<Self> {
        let address = address.into();
        validate_static_peer(&address, port)?;
        Ok(Self {
            address,
            port,
            label,
        })
    }
}

/// Drops any peer in `peers` that fails [`validate_static_peer`], logging a
/// warning for each — same load-time, drop-and-warn policy as
/// `channel::sanitize_loaded_channels` (ADR-0006).
fn sanitize_loaded_static_peers(peers: &mut Vec<StaticPeer>) {
    peers.retain(|p| match validate_static_peer(&p.address, p.port) {
        Ok(()) => true,
        Err(e) => {
            tracing::warn!(
                "patch.toml: dropping static peer {:?} at load — {}",
                p.label.as_deref().unwrap_or(p.address.as_str()),
                e
            );
            false
        }
    });
}

impl Default for Config {
    fn default() -> Self {
        Self {
            config_version: CURRENT_CONFIG_VERSION,
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
            flash_whole_screen: false,
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
            let mut config: Config = toml::from_str(&raw)?;
            config.sanitize();
            // Bring the schema up to date; persist if anything changed so the
            // next load is a no-op.
            if migrate(&mut config) {
                config.save()?;
            }
            return Ok(config);
        }

        let legacy = Path::new("patch.toml");
        if legacy.exists() {
            let raw = std::fs::read_to_string(legacy)?;
            let mut config: Config = toml::from_str(&raw)?;
            config.sanitize();
            migrate(&mut config);
            // Persist into the new location so subsequent saves don't fight CWD.
            config.save()?;
            tracing::info!("Migrated legacy patch.toml → {}", target.display());
            return Ok(config);
        }

        let config = Config::default();
        config.save()?;
        Ok(config)
    }

    /// Drops any macro (per-channel or global) or static peer that fails
    /// validation, logging a warning for each — load-time policy for a
    /// hand-edited `patch.toml` (ADR-0006: the 4th OSC-target/static-peer
    /// trust level, drop-and-warn, never refuse to start). Also strips (but
    /// doesn't drop the macro for) any key/MIDI binding collision, run after
    /// the OSC-target pass so it only sees surviving macros.
    fn sanitize(&mut self) {
        sanitize_loaded_channels(&mut self.default_channels);
        sanitize_loaded_macros(&mut self.global_macros, "global macros");
        sanitize_loaded_static_peers(&mut self.static_peers);
        sanitize_binding_collisions(&mut self.global_macros, &mut self.default_channels);
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

    /// True while the display name is still the system-seeded default (the
    /// `whoami()` value used on a fresh install). The UI uses this to decide
    /// whether to show the first-run "set your name" prompt — so a crew member
    /// who never set a name isn't seen by everyone as their login account name.
    /// Once they pick any other name this returns false. The one false positive
    /// — someone whose chosen name equals their login — costs a single dismiss.
    pub fn name_is_default(&self) -> bool {
        self.client_name == whoami()
    }
}

/// Bring a freshly-loaded config up to [`CURRENT_CONFIG_VERSION`], running any
/// ordered per-version migration steps. Returns `true` if the config changed and
/// should be persisted.
///
/// A version *newer* than this build is left untouched (with a warning) rather
/// than refused — serde already tolerates unknown fields, so we load what we can
/// and never block a live show on a downgrade.
pub fn migrate(config: &mut Config) -> bool {
    use std::cmp::Ordering;
    match config.config_version.cmp(&CURRENT_CONFIG_VERSION) {
        Ordering::Equal => false,
        Ordering::Greater => {
            tracing::warn!(
                "config_version {} is newer than this build ({}) — some settings may be ignored",
                config.config_version,
                CURRENT_CONFIG_VERSION
            );
            false
        }
        Ordering::Less => {
            // Ordered migration steps go here, lowest version first. The 0 → 1
            // step is intentionally a no-op (version stamp only) — it exists so
            // future schema changes have a clear, tested home.
            config.config_version = CURRENT_CONFIG_VERSION;
            true
        }
    }
}

/// Coalesce rapid mutations into a single disk write — 500 ms in production,
/// effectively zero in tests so they don't need to sleep.
#[cfg(not(test))]
const SAVE_DEBOUNCE_MS: u64 = 500;
#[cfg(test)]
const SAVE_DEBOUNCE_MS: u64 = 0;

/// Pure config-persistence logic — no `AppEvent`/broadcast-channel
/// dependency. Owns `Config` *and* the lock serializing writes to
/// `patch.toml` (`save_lock` previously lived on `AppState`'s inner state —
/// it's purely a config-persistence concern, see ADR-0003).
///
/// Callers mutate config via [`mutate_and_persist`], which applies the
/// closure immediately and schedules a debounced disk write. Rapid sequential
/// calls coalesce — only the last write fires within the debounce window.
pub(crate) struct ConfigStore {
    config: std::sync::Arc<tokio::sync::RwLock<Config>>,
    /// Serializes config persistence so concurrent writers can't clobber each
    /// other. Held only across the clone + offloaded write, never with the
    /// config read lock, so it doesn't block readers on the hot send path.
    save_lock: std::sync::Arc<tokio::sync::Mutex<()>>,
    /// The in-flight debounced save task, if any.
    pending_save: tokio::sync::Mutex<Option<tokio::task::JoinHandle<()>>>,
}

impl std::fmt::Debug for ConfigStore {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ConfigStore").finish_non_exhaustive()
    }
}

impl ConfigStore {
    pub(crate) fn new(config: Config) -> Self {
        Self {
            config: std::sync::Arc::new(tokio::sync::RwLock::new(config)),
            save_lock: std::sync::Arc::new(tokio::sync::Mutex::new(())),
            pending_save: tokio::sync::Mutex::new(None),
        }
    }

    /// Returns a snapshot clone of the current config.
    pub(crate) async fn snapshot(&self) -> Config {
        self.config.read().await.clone()
    }

    /// Read access to the config under the lock, without cloning the whole
    /// struct — for callers that only need a field or two (e.g. the
    /// static-peer list, the flash defaults).
    pub(crate) async fn read<R>(&self, f: impl FnOnce(&Config) -> R) -> R {
        f(&*self.config.read().await)
    }

    /// Apply a mutation and schedule a debounced disk write. The in-memory
    /// change is visible immediately; the file write happens after
    /// `SAVE_DEBOUNCE_MS`. Rapid calls cancel the previous pending write so
    /// only one file I/O fires per burst.
    pub(crate) async fn mutate_and_persist<R>(&self, f: impl FnOnce(&mut Config) -> R) -> R {
        let result = f(&mut *self.config.write().await);
        let config = std::sync::Arc::clone(&self.config);
        let save_lock = std::sync::Arc::clone(&self.save_lock);
        let mut pending = self.pending_save.lock().await;
        if let Some(h) = pending.take() {
            h.abort();
        }
        *pending = Some(tokio::spawn(async move {
            tokio::time::sleep(tokio::time::Duration::from_millis(SAVE_DEBOUNCE_MS)).await;
            let _guard = save_lock.lock().await;
            let cfg = config.read().await.clone();
            if let Err(e) = tokio::task::spawn_blocking(move || cfg.save())
                .await
                .unwrap_or_else(|e| Err(anyhow::anyhow!(e)))
            {
                tracing::warn!("ConfigStore: debounced save failed: {e}");
            }
        }));
        result
    }

    /// Wait for any pending debounced write to complete. Test-only.
    #[cfg(test)]
    pub(crate) async fn flush(&self) {
        if let Some(h) = self.pending_save.lock().await.take() {
            let _ = h.await;
        }
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
        .map(|(id, name, color)| {
            Channel::new(*id, *name, *color).expect("default channel id is valid")
        })
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

    #[test]
    fn name_is_default_tracks_whoami() {
        // A fresh config seeds client_name = whoami() → still the default.
        assert!(Config::default().name_is_default());
        // Any custom name → no longer the default.
        let custom = Config {
            client_name: "Alice on FOH".to_string(),
            ..Config::default()
        };
        assert!(!custom.name_is_default());
    }

    /// A config in the documented `patch.toml` format must stay deserialisable
    /// into the current `Config` schema — guards against field drift (e.g. the
    /// old `shortcuts`/`bridge_port` leftovers). Kept inline rather than reading
    /// the on-disk `patch.toml`, which is gitignored (a per-user runtime file,
    /// absent on a clean CI checkout).
    #[test]
    fn representative_config_deserializes() {
        let raw = r##"
config_version = 1
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
        assert_eq!(cfg.config_version, 1);
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

    /// A hand-edited `patch.toml` (ADR-0006) with one bad macro per
    /// channel-macro-list, one bad global macro, and one bad static peer,
    /// each mixed in alongside a valid sibling — `sanitize` must drop only
    /// the bad entries and leave everything else untouched.
    #[test]
    fn sanitize_drops_only_the_invalid_entries() {
        let raw = r##"
config_version = 1
client_id = "00000000-0000-0000-0000-000000000000"
client_name = "FOH Engineer"
osc_port = 9000
network_interface = "en0"
heartbeat_interval_secs = 7
flash_on_critical = true
flash_on_message = false
flash_count = 4
macros_columns = 1
hide_keyboard = true

[[static_peers]]
address = "192.168.1.50"
port = 9000
label = "Monitor World"

[[static_peers]]
address = "not-an-ip"
port = 9000
label = "Bad Peer"

[[default_channels]]
id = "rf"
display_name = "RF"
color = "#1E88E5"
flash_on_critical = true
flash_on_message = false

[[default_channels.macros]]
label = "GOOD"
payload = "Go"
priority = 1

[[default_channels.macros]]
label = "BAD"
payload = "Go bad"
priority = 1

[default_channels.macros.osc]
address = "192.168.1.50"
port = 53000
path = "cue/1/start"

[[global_macros]]
label = "GOOD GLOBAL"
payload = "ok"
priority = 1

[[global_macros]]
label = "BAD GLOBAL"
payload = "bad"
priority = 1

[global_macros.osc]
address = "192.168.1.50"
port = 0
path = "/cue/2/start"
"##;
        let mut cfg: Config = toml::from_str(raw).expect("fixture must deserialize");
        cfg.sanitize();

        assert_eq!(cfg.static_peers.len(), 1);
        assert_eq!(cfg.static_peers[0].label.as_deref(), Some("Monitor World"));

        let rf = cfg.default_channels.iter().find(|c| c.id == "rf").unwrap();
        let macro_labels: Vec<_> = rf.macros.iter().map(|m| m.label.as_str()).collect();
        assert_eq!(macro_labels, vec!["GOOD"]);

        let global_labels: Vec<_> = cfg.global_macros.iter().map(|m| m.label.as_str()).collect();
        assert_eq!(global_labels, vec!["GOOD GLOBAL"]);
    }

    /// A hand-edited `patch.toml` with a key-binding collision between two
    /// global macros and a MIDI-note collision between a channel macro and a
    /// global macro — `sanitize` must strip just the colliding bindings
    /// (first-listed wins) and keep every macro (ADR-0006).
    #[test]
    fn sanitize_strips_binding_collisions_keeps_every_macro() {
        let raw = r##"
config_version = 1
client_id = "00000000-0000-0000-0000-000000000000"
client_name = "FOH Engineer"
osc_port = 9000
network_interface = "en0"
heartbeat_interval_secs = 7
flash_on_critical = true
flash_on_message = false
flash_count = 4
macros_columns = 1
hide_keyboard = true
static_peers = []

[[default_channels]]
id = "rf"
display_name = "RF"
color = "#1E88E5"
flash_on_critical = true
flash_on_message = false

[[default_channels.macros]]
label = "STANDBY"
payload = "Standby"
priority = 1
midi_note = 60

[[global_macros]]
label = "GO"
payload = "Go"
priority = 1
key_binding = "F3"
midi_note = 60

[[global_macros]]
label = "YES"
payload = "Yes"
priority = 1
key_binding = "F3"
"##;
        let mut cfg: Config = toml::from_str(raw).expect("fixture must deserialize");
        cfg.sanitize();

        // Global-vs-global: first-listed ("GO") keeps "F3"; "YES" loses it.
        let go = cfg.global_macros.iter().find(|m| m.label == "GO").unwrap();
        let yes = cfg.global_macros.iter().find(|m| m.label == "YES").unwrap();
        assert_eq!(go.key_binding.as_deref(), Some("F3"));
        assert_eq!(yes.key_binding, None);

        // Channel-vs-global: globals are finalized first, so "GO" keeps its
        // MIDI note; the channel macro loses it but stays on the channel.
        let rf = cfg.default_channels.iter().find(|c| c.id == "rf").unwrap();
        assert_eq!(rf.macros.len(), 1);
        assert_eq!(rf.macros[0].label, "STANDBY");
        assert_eq!(rf.macros[0].midi_note, None);
    }

    /// A pre-versioning `patch.toml` (no `config_version`) loads as version 0,
    /// so `migrate` can recognise and stamp it.
    #[test]
    fn config_without_version_field_loads_as_zero() {
        let raw = r##"
client_id = "00000000-0000-0000-0000-000000000000"
client_name = "X"
osc_port = 9000
network_interface = "en0"
heartbeat_interval_secs = 7
static_peers = []
default_channels = []
"##;
        let cfg: Config = toml::from_str(raw).expect("must deserialize");
        assert_eq!(cfg.config_version, 0);
    }

    #[test]
    fn fresh_config_is_current_version() {
        assert_eq!(Config::default().config_version, CURRENT_CONFIG_VERSION);
    }

    #[test]
    fn migrate_stamps_pre_versioning_config() {
        let mut cfg = Config {
            config_version: 0,
            ..Config::default()
        };
        assert!(migrate(&mut cfg)); // changed → caller should persist
        assert_eq!(cfg.config_version, CURRENT_CONFIG_VERSION);
    }

    #[test]
    fn migrate_is_noop_on_current_version() {
        let mut cfg = Config::default(); // already current
        assert!(!migrate(&mut cfg));
        assert_eq!(cfg.config_version, CURRENT_CONFIG_VERSION);
    }

    #[test]
    fn migrate_leaves_future_version_untouched() {
        let mut cfg = Config {
            config_version: 9999,
            ..Config::default()
        };
        assert!(!migrate(&mut cfg)); // no change, never downgrade
        assert_eq!(cfg.config_version, 9999);
    }

    // ── ConfigStore — direct, no AppState/event bus needed ──────────────────

    #[tokio::test]
    async fn snapshot_returns_a_clone_of_the_current_config() {
        let store = ConfigStore::new(Config {
            client_name: "Alice".into(),
            ..Config::default()
        });
        assert_eq!(store.snapshot().await.client_name, "Alice");
    }

    #[tokio::test]
    async fn mutate_and_persist_applies_immediately() {
        let store = ConfigStore::new(Config::default());
        store
            .mutate_and_persist(|c| c.client_name = "Bob".into())
            .await;
        assert_eq!(store.snapshot().await.client_name, "Bob");
    }

    #[tokio::test]
    async fn mutate_and_persist_returns_the_closures_value() {
        let store = ConfigStore::new(Config::default());
        let port = store
            .mutate_and_persist(|c| {
                c.osc_port = 9001;
                c.osc_port
            })
            .await;
        assert_eq!(port, 9001);
    }

    #[tokio::test]
    async fn read_does_not_clone_the_whole_config() {
        let store = ConfigStore::new(Config {
            client_name: "Alice".into(),
            ..Config::default()
        });
        let name_len = store.read(|c| c.client_name.len()).await;
        assert_eq!(name_len, 5);
    }

    #[tokio::test]
    async fn rapid_mutations_coalesce_into_one_write() {
        let _guard = test_data_dir_guard().await;
        let dir = std::env::temp_dir().join(format!("patch-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        set_data_dir(dir.clone());

        let store = ConfigStore::new(Config::default());
        store
            .mutate_and_persist(|c| c.client_name = "First".into())
            .await;
        store
            .mutate_and_persist(|c| c.client_name = "Second".into())
            .await;
        store
            .mutate_and_persist(|c| c.client_name = "Third".into())
            .await;
        // Flush waits for the single coalesced write.
        store.flush().await;

        let reloaded = Config::load_or_default().unwrap();
        assert_eq!(reloaded.client_name, "Third");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn mutate_and_persist_then_flush_round_trips() {
        let _guard = test_data_dir_guard().await;
        let dir = std::env::temp_dir().join(format!("patch-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        set_data_dir(dir.clone());

        let store = ConfigStore::new(Config::default());
        store
            .mutate_and_persist(|c| c.client_name = "Persisted".into())
            .await;
        store.flush().await;

        let reloaded = Config::load_or_default().unwrap();
        assert_eq!(reloaded.client_name, "Persisted");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
