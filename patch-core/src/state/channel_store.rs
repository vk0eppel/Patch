//! `ChannelStore` — auto-persisting wrapper around [`ChannelRegistry`].
//!
//! Every write method mutates the registry and immediately schedules a debounced
//! config write via `ConfigStore::mutate_and_persist`. This eliminates the
//! 8 manual `persist_channels()` call sites that previously lived in `AppState`.
//!
//! Cross-domain note (ADR-0003 exception): `ChannelStore` holds an
//! `Arc<ConfigStore>` so it can auto-persist without a separate orchestration
//! call. This is the one documented exception to the rule that cross-domain
//! wiring stays in `AppState`. The `replace_all_silent` method is provided for
//! callers (`apply_show_file_full`) that need to batch a channels+peers write
//! in a single `mutate_and_persist` — in that case the caller is responsible
//! for the persist.

use std::sync::Arc;

use super::channel::{Channel, MacroMessage};
use super::config::ConfigStore;

// Re-use the registry for all the actual data storage and locking.
use super::channel::ChannelRegistry;

#[derive(Debug)]
pub(crate) struct ChannelStore {
    registry: ChannelRegistry,
    config: Arc<ConfigStore>,
}

impl ChannelStore {
    pub(crate) fn seeded(channels: Vec<Channel>, config: Arc<ConfigStore>) -> Self {
        Self {
            registry: ChannelRegistry::seeded(channels),
            config,
        }
    }

    async fn persist(&self) {
        let channels = self.registry.list().await;
        self.config
            .mutate_and_persist(|cfg| cfg.default_channels = channels)
            .await;
    }

    // ── Read ──────────────────────────────────────────────────────────────────

    pub(crate) async fn list(&self) -> Vec<Channel> {
        self.registry.list().await
    }

    // ── Writes (auto-persist) ─────────────────────────────────────────────────

    pub(crate) async fn upsert(&self, ch: Channel) {
        self.registry.upsert(ch).await;
        self.persist().await;
    }

    pub(crate) async fn delete(&self, channel_id: &str) {
        self.registry.delete(channel_id).await;
        self.persist().await;
    }

    pub(crate) async fn replace_all(&self, channels: Vec<Channel>) {
        self.registry.replace_all(channels).await;
        self.persist().await;
    }

    /// Replace channels without auto-persisting. Used by `apply_show_file_full`
    /// which combines the channels + static-peers write in one `mutate_and_persist`.
    pub(crate) async fn replace_all_silent(&self, channels: Vec<Channel>) {
        self.registry.replace_all(channels).await;
    }

    /// Merge incoming channels; auto-persists only when at least one was added.
    /// Returns the number actually added so `AppState` can decide whether to emit
    /// `ChannelListUpdated`.
    pub(crate) async fn merge(
        &self,
        channels: Vec<Channel>,
        flash_on_critical: bool,
        flash_on_message: bool,
    ) -> usize {
        let added = self
            .registry
            .merge(channels, flash_on_critical, flash_on_message)
            .await;
        if added > 0 {
            self.persist().await;
        }
        added
    }

    pub(crate) async fn set_flash(
        &self,
        channel_id: &str,
        flash_on_critical: Option<bool>,
        flash_on_message: Option<bool>,
        flash_count: Option<u8>,
    ) -> anyhow::Result<()> {
        self.registry
            .set_flash(channel_id, flash_on_critical, flash_on_message, flash_count)
            .await?;
        self.persist().await;
        Ok(())
    }

    pub(crate) async fn upsert_macro(
        &self,
        channel_id: &str,
        original_label: Option<&str>,
        macro_msg: MacroMessage,
        global_macros: &[MacroMessage],
    ) -> anyhow::Result<()> {
        self.registry
            .upsert_macro(channel_id, original_label, macro_msg, global_macros)
            .await?;
        self.persist().await;
        Ok(())
    }

    pub(crate) async fn delete_macro(&self, channel_id: &str, label: &str) -> anyhow::Result<()> {
        self.registry.delete_macro(channel_id, label).await?;
        self.persist().await;
        Ok(())
    }

    pub(crate) async fn reorder_macros(
        &self,
        channel_id: &str,
        ordered_labels: Vec<String>,
    ) -> anyhow::Result<()> {
        self.registry
            .reorder_macros(channel_id, ordered_labels)
            .await?;
        self.persist().await;
        Ok(())
    }
}
