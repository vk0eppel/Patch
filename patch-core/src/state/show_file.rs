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
    std::fs::write(&path, raw).with_context(|| format!("Failed to write show file {:?}", path))?;
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state::config::{set_data_dir, test_data_dir_guard};

    fn make_show_file(name: &str) -> ShowFileConfig {
        ShowFileConfig::new(name, Vec::new(), Vec::new())
    }

    // ── slugify (pure) ────────────────────────────────────────────────────────

    #[test]
    fn slugify_lowercases_and_replaces_spaces() {
        assert_eq!(slugify("Main Stage"), "main_stage");
    }

    #[test]
    fn slugify_trims_leading_and_trailing_underscores() {
        assert_eq!(slugify("!!!foo!!!"), "foo");
    }

    #[test]
    fn slugify_preserves_hyphens() {
        assert_eq!(slugify("show-1"), "show-1");
    }

    #[test]
    fn slugify_empty_string_is_empty() {
        assert_eq!(slugify(""), "");
    }

    // ── disk I/O ─────────────────────────────────────────────────────────────

    #[tokio::test]
    async fn save_and_load_round_trip() {
        let _guard = test_data_dir_guard().await;
        let dir = std::env::temp_dir().join(format!("patch-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        set_data_dir(dir.clone());

        let sf = make_show_file("Main Stage");
        let slug = save_show_file(&sf).unwrap();
        assert_eq!(slug, "main_stage");
        let loaded = load_show_file(&slug).unwrap();
        assert_eq!(loaded.name, "Main Stage");
        assert_eq!(loaded.channels.len(), 0);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn save_creates_show_files_dir_if_absent() {
        let _guard = test_data_dir_guard().await;
        let dir = std::env::temp_dir().join(format!("patch-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        set_data_dir(dir.clone());

        assert!(!dir.join("show_files").exists());
        save_show_file(&make_show_file("Night One")).unwrap();
        assert!(dir.join("show_files").exists());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn load_missing_slug_returns_descriptive_err() {
        let _guard = test_data_dir_guard().await;
        let dir = std::env::temp_dir().join(format!("patch-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        set_data_dir(dir.clone());

        let err = load_show_file("nonexistent").unwrap_err();
        assert!(err.to_string().contains("nonexistent"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn save_name_with_empty_slug_returns_err() {
        let _guard = test_data_dir_guard().await;
        let dir = std::env::temp_dir().join(format!("patch-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        set_data_dir(dir.clone());

        assert!(save_show_file(&make_show_file("!!!")).is_err());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn list_returns_files_sorted_by_name() {
        let _guard = test_data_dir_guard().await;
        let dir = std::env::temp_dir().join(format!("patch-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        set_data_dir(dir.clone());

        save_show_file(&make_show_file("Zebra Show")).unwrap();
        save_show_file(&make_show_file("Alpha Show")).unwrap();
        save_show_file(&make_show_file("Main Show")).unwrap();

        let files = list_show_files().unwrap();
        assert_eq!(files.len(), 3);
        assert_eq!(files[0].name, "Alpha Show");
        assert_eq!(files[1].name, "Main Show");
        assert_eq!(files[2].name, "Zebra Show");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn list_returns_empty_when_dir_absent() {
        let _guard = test_data_dir_guard().await;
        let dir = std::env::temp_dir().join(format!("patch-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        set_data_dir(dir.clone());

        assert!(list_show_files().unwrap().is_empty());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn round_trip_preserves_static_peers() {
        let _guard = test_data_dir_guard().await;
        let dir = std::env::temp_dir().join(format!("patch-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        set_data_dir(dir.clone());

        use crate::state::config::StaticPeer;
        let peer = StaticPeer {
            address: "192.168.1.10".into(),
            port: 9000,
            label: Some("Stage Manager".into()),
        };
        let sf = ShowFileConfig::new("Night One", Vec::new(), vec![peer]);
        let slug = save_show_file(&sf).unwrap();
        let loaded = load_show_file(&slug).unwrap();

        assert_eq!(loaded.static_peers.len(), 1);
        assert_eq!(loaded.static_peers[0].address, "192.168.1.10");
        assert_eq!(
            loaded.static_peers[0].label.as_deref(),
            Some("Stage Manager")
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn load_corrupt_toml_returns_err_without_panic() {
        let _guard = test_data_dir_guard().await;
        let dir = std::env::temp_dir().join(format!("patch-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        set_data_dir(dir.clone());

        let show_dir = dir.join("show_files");
        std::fs::create_dir_all(&show_dir).unwrap();
        std::fs::write(show_dir.join("corrupt.toml"), b"not toml ][[[").unwrap();

        assert!(load_show_file("corrupt").is_err());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn list_ignores_non_toml_files() {
        let _guard = test_data_dir_guard().await;
        let dir = std::env::temp_dir().join(format!("patch-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        set_data_dir(dir.clone());

        save_show_file(&make_show_file("Real Show")).unwrap();
        let show_dir = dir.join("show_files");
        std::fs::write(show_dir.join("readme.txt"), b"ignore me").unwrap();
        std::fs::write(show_dir.join("backup.json"), b"{}").unwrap();

        let files = list_show_files().unwrap();
        assert_eq!(files.len(), 1);
        assert_eq!(files[0].name, "Real Show");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn list_skips_corrupt_toml_and_returns_valid_entries() {
        let _guard = test_data_dir_guard().await;
        let dir = std::env::temp_dir().join(format!("patch-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        set_data_dir(dir.clone());

        save_show_file(&make_show_file("Good Show")).unwrap();
        let show_dir = dir.join("show_files");
        std::fs::write(show_dir.join("corrupt.toml"), b"not toml ][[[").unwrap();

        let files = list_show_files().unwrap();
        assert_eq!(files.len(), 1);
        assert_eq!(files[0].name, "Good Show");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn delete_removes_file_and_second_delete_is_noop() {
        let _guard = test_data_dir_guard().await;
        let dir = std::env::temp_dir().join(format!("patch-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        set_data_dir(dir.clone());

        save_show_file(&make_show_file("Night One")).unwrap();
        assert_eq!(list_show_files().unwrap().len(), 1);

        delete_show_file("night_one").unwrap();
        assert_eq!(list_show_files().unwrap().len(), 0);

        delete_show_file("night_one").unwrap(); // no-op, not an error

        let _ = std::fs::remove_dir_all(&dir);
    }
}
