use serde::{Deserialize, Serialize};

fn default_true() -> bool { true }

/// A logical communication channel.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Channel {
    /// Stable slug used in OSC addresses (e.g. "rf", "foh").
    pub id: String,
    /// Human-readable display name shown in the UI.
    pub display_name: String,
    /// Hex colour for UI differentiation (e.g. "#E53935").
    pub color: String,
    /// Pre-configured macro messages for this channel.
    pub macros: Vec<MacroMessage>,
    /// Flash this channel's message box when a critical (priority 3) message arrives.
    #[serde(default = "default_true")]
    pub flash_on_critical: bool,
    /// Flash this channel's message box on every incoming message.
    #[serde(default)]
    pub flash_on_message: bool,
    /// Per-channel flash pulse count override. None = use global setting.
    #[serde(default)]
    pub flash_count: Option<u8>,
}

impl Channel {
    pub fn new(id: impl Into<String>, display_name: impl Into<String>, color: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            display_name: display_name.into(),
            color: color.into(),
            macros: Vec::new(),
            flash_on_critical: true,
            flash_on_message: false,
            flash_count: None,
        }
    }
}

/// A one-tap/keyboard macro message.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MacroMessage {
    /// Short label shown on the button (e.g. "HOLD", "CLEAR", "BACK IN 5").
    pub label: String,
    /// The message text that will be sent.
    pub payload: String,
    /// Optional key binding (e.g. "F1", "ctrl+1").
    pub key_binding: Option<String>,
    /// Priority override — defaults to Info.
    pub priority: i32,
}
