//! Show file — named channel/peer configurations saved as TOML files.
//!
//! Show files live in `./show_files/` relative to `patch.toml`.
//! They capture channels + shortcuts + static peers but NOT machine config
//! (client_id, ports, network interface — those stay in `patch.toml`).
//!
//! File format: `show_files/{slug}.toml`

use anyhow::{Context, Result};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

use super::channel::Channel;
use super::config::{data_dir, StaticPeer};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ShowFileConfig {
    pub name: String,
    pub created_at: DateTime<Utc>,
    pub channels: Vec<Channel>,
    #[serde(default)]
    pub static_peers: Vec<StaticPeer>,
}

impl ShowFileConfig {
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

fn show_files_dir() -> PathBuf {
    data_dir().join("show_files")
}

fn show_file_path(slug: &str) -> PathBuf {
    show_files_dir().join(format!("{}.toml", slug))
}

/// Sanitise a show file name into a safe filename slug.
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

/// Save a show file. Creates `show_files/` if it doesn't exist.
pub fn save_show_file(show_file: &ShowFileConfig) -> Result<String> {
    let dir = show_files_dir();
    std::fs::create_dir_all(&dir).context("Failed to create show_files directory")?;

    let slug = slugify(&show_file.name);
    if slug.is_empty() {
        anyhow::bail!("Show file name produces an empty slug");
    }
    let path = show_file_path(&slug);
    let raw = toml::to_string_pretty(show_file).context("Failed to serialise show file")?;
    std::fs::write(&path, raw)
        .with_context(|| format!("Failed to write show file {:?}", path))?;
    Ok(slug)
}

/// Load a show file by slug.
pub fn load_show_file(slug: &str) -> Result<ShowFileConfig> {
    let path = show_file_path(slug);
    let raw = std::fs::read_to_string(&path)
        .with_context(|| format!("Show file '{}' not found", slug))?;
    toml::from_str(&raw).with_context(|| format!("Failed to parse show file '{}'", slug))
}

/// List all saved show files as metadata, sorted by name.
pub fn list_show_files() -> Result<Vec<ShowFileMeta>> {
    let dir = show_files_dir();
    if !dir.exists() {
        return Ok(Vec::new());
    }
    let mut show_files = Vec::new();
    for entry in std::fs::read_dir(&dir).context("Failed to read show_files directory")? {
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
            if let Ok(s) = toml::from_str::<ShowFileConfig>(&raw) {
                show_files.push(ShowFileMeta {
                    slug,
                    name: s.name,
                    created_at: s.created_at,
                    channel_count: s.channels.len(),
                });
            }
        }
    }
    show_files.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(show_files)
}

/// Delete a show file by slug.
pub fn delete_show_file(slug: &str) -> Result<()> {
    let path = show_file_path(slug);
    if path.exists() {
        std::fs::remove_file(&path)
            .with_context(|| format!("Failed to delete show file '{}'", slug))?;
    }
    Ok(())
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ShowFileMeta {
    pub slug: String,
    pub name: String,
    pub created_at: DateTime<Utc>,
    pub channel_count: usize,
}
