//! Serialize AppEvents into newline-delimited JSON for the Flutter client.

use serde_json::{json, Value};

use crate::state::AppEvent;

/// Returns `None` for events that should not be forwarded to the UI.
pub fn serialize_event(event: AppEvent) -> Option<String> {
    let v: Value = match event {
        AppEvent::MessageReceived(msg) => json!({ "event": "message", "data": msg }),
        AppEvent::MessageAcked { message_id, peer_id } => json!({
            "event": "message_acked",
            "message_id": message_id.to_string(),
            "peer_id": peer_id.to_string(),
        }),
        AppEvent::PeerUpdated(peer) => json!({ "event": "peer_updated", "data": peer }),
        AppEvent::PeerExpired(peer_id) => json!({
            "event": "peer_expired",
            "data": { "peer_id": peer_id.to_string() },
        }),
        AppEvent::ChannelFlash(flash) => json!({ "event": "channel_flash", "data": flash }),
        AppEvent::ChannelListUpdated => json!({ "event": "channel_list_updated" }),
        AppEvent::ClientNameChanged(name) => json!({ "event": "client_name_changed", "name": name }),
    };
    Some(v.to_string())
}
