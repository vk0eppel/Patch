use serde::{Deserialize, Serialize};

/// A logical communication channel.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Channel {
    /// Stable slug used in OSC addresses (e.g. "rf", "foh").
    pub id: String,
    /// Human-readable display name shown in the UI.
    pub display_name: String,
    /// Hex colour for UI differentiation (e.g. "#E53935").
    pub color: String,
    /// Pre-configured shortcut messages for this channel.
    pub shortcuts: Vec<ShortcutMessage>,
}

impl Channel {
    pub fn new(id: impl Into<String>, display_name: impl Into<String>, color: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            display_name: display_name.into(),
            color: color.into(),
            shortcuts: Vec::new(),
        }
    }
}

/// A one-tap/keyboard shortcut message.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ShortcutMessage {
    /// Short label shown on the button (e.g. "HOLD", "CLEAR", "BACK IN 5").
    pub label: String,
    /// The message text that will be sent.
    pub payload: String,
    /// Optional keyboard shortcut (e.g. "F1", "ctrl+1").
    pub key_binding: Option<String>,
    /// Priority override — defaults to Info.
    pub priority: i32,
}
