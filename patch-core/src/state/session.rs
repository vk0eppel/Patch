//! Session configuration — named channel/shortcut presets saved as TOML files.
//!
//! Sessions live in `./sessions/` relative to `patch.toml`.
//! They capture channels + shortcuts + static peers but NOT machine config
//! (client_id, ports, network interface — those stay in `patch.toml`).
//!
//! File format: `sessions/{slug}.toml`

use anyhow::{Context, Result};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

use super::channel::Channel;
use super::config::{data_dir, StaticPeer};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionConfig {
    pub name: String,
    pub created_at: DateTime<Utc>,
    pub channels: Vec<Channel>,
    #[serde(default)]
    pub static_peers: Vec<StaticPeer>,
}

impl SessionConfig {
    pub fn new(
        name: impl Into<String>,
        channels: Vec<Channel>,
        static_peers: Vec<StaticPeer>,
    ) -> Self {
        Self {
            name: name.into(),
            created_at: Utc::now(),
            channels,
            static_peers,
        }
    }
}

// ── File helpers ──────────────────────────────────────────────────────────────

fn sessions_dir() -> PathBuf {
    data_dir().join("sessions")
}

fn session_path(slug: &str) -> PathBuf {
    sessions_dir().join(format!("{}.toml", slug))
}

/// Sanitise a session name into a safe filename slug.
pub fn slugify(name: &str) -> String {
    name.to_lowercase()
        .chars()
        .map(|c| {
            if c.is_alphanumeric() || c == '-' {
                c
            } else {
                '_'
            }
        })
        .collect::<String>()
        .trim_matches('_')
        .to_string()
}

// ── Public API ────────────────────────────────────────────────────────────────

/// Save a session. Creates `sessions/` if it doesn't exist.
pub fn save_session(session: &SessionConfig) -> Result<String> {
    let dir = sessions_dir();
    std::fs::create_dir_all(&dir).context("Failed to create sessions directory")?;

    let slug = slugify(&session.name);
    if slug.is_empty() {
        anyhow::bail!("Session name produces an empty slug");
    }
    let path = session_path(&slug);
    let raw = toml::to_string_pretty(session).context("Failed to serialise session")?;
    std::fs::write(&path, raw)
        .with_context(|| format!("Failed to write session file {:?}", path))?;
    Ok(slug)
}

/// Load a session by slug.
pub fn load_session(slug: &str) -> Result<SessionConfig> {
    let path = session_path(slug);
    let raw =
        std::fs::read_to_string(&path).with_context(|| format!("Session '{}' not found", slug))?;
    toml::from_str(&raw).with_context(|| format!("Failed to parse session '{}'", slug))
}

/// List all saved sessions as `(slug, name)` pairs, sorted by name.
pub fn list_sessions() -> Result<Vec<SessionMeta>> {
    let dir = sessions_dir();
    if !dir.exists() {
        return Ok(Vec::new());
    }
    let mut sessions = Vec::new();
    for entry in std::fs::read_dir(&dir).context("Failed to read sessions directory")? {
        let entry = entry?;
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("toml") {
            continue;
        }
        let slug = path
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("")
            .to_string();
        if let Ok(raw) = std::fs::read_to_string(&path) {
            if let Ok(s) = toml::from_str::<SessionConfig>(&raw) {
                sessions.push(SessionMeta {
                    slug,
                    name: s.name,
                    created_at: s.created_at,
                    channel_count: s.channels.len(),
                });
            }
        }
    }
    sessions.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(sessions)
}

/// Delete a session file by slug.
pub fn delete_session(slug: &str) -> Result<()> {
    let path = session_path(slug);
    if path.exists() {
        std::fs::remove_file(&path)
            .with_context(|| format!("Failed to delete session '{}'", slug))?;
    }
    Ok(())
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionMeta {
    pub slug: String,
    pub name: String,
    pub created_at: DateTime<Utc>,
    pub channel_count: usize,
}
