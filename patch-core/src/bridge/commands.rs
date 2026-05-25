//! Command handler — parses Flutter JSON commands and dispatches to engine.

use serde_json::{json, Value};
use tracing::{debug, warn};

use crate::osc::codec::{encode_flash, encode_message};
use crate::osc::types::{ChannelFlash, PatchMessage, Priority};
use crate::state::{
    channel::{Channel, ShortcutMessage},
    session::{self, SessionConfig},
    AppEvent, AppState,
};
use crate::transport::{list_interfaces, Transport};

pub async fn handle_command(
    line: &str,
    state: &AppState,
    transport: &Transport,
) -> String {
    debug!("Bridge cmd: {}", line);
    let result: Value = match serde_json::from_str::<Value>(line) {
        Err(e) => json!({ "event": "error", "message": format!("JSON parse: {}", e) }),
        Ok(cmd) => dispatch(cmd, state, transport).await,
    };
    result.to_string()
}

async fn dispatch(cmd: Value, state: &AppState, transport: &Transport) -> Value {
    let op = cmd["cmd"].as_str().unwrap_or("");
    match op {
        "send_message"     => cmd_send_message(cmd, state, transport).await,
        "send_flash"       => cmd_send_flash(cmd, state, transport).await,
        "get_channels"     => cmd_get_channels(state).await,
        "get_peers"        => cmd_get_peers(state).await,
        "get_messages"     => cmd_get_messages(cmd, state).await,
        "get_interfaces"   => cmd_get_interfaces(),
        "get_config"       => cmd_get_config(state).await,
        "set_interface"    => cmd_set_interface(cmd),
        "set_client_name"  => cmd_set_client_name(cmd, state).await,
        "add_static_peer"  => cmd_add_static_peer(cmd, state).await,
        "upsert_channel"   => cmd_upsert_channel(cmd, state).await,
        "upsert_shortcut"  => cmd_upsert_shortcut(cmd, state).await,
        "delete_shortcut"  => cmd_delete_shortcut(cmd, state).await,
        "delete_channel"   => cmd_delete_channel(cmd, state).await,
        "save_session"     => cmd_save_session(cmd, state).await,
        "load_session"     => cmd_load_session(cmd, state).await,
        "list_sessions"    => cmd_list_sessions(),
        "delete_session"   => cmd_delete_session(cmd),
        _                  => {
            warn!("Unknown bridge command: {}", op);
            json!({ "event": "error", "message": format!("Unknown command: {}", op) })
        }
    }
}

async fn cmd_send_message(cmd: Value, state: &AppState, transport: &Transport) -> Value {
    let channel_id = match cmd["channel_id"].as_str() {
        Some(s) => s.to_string(),
        None => return json!({ "event": "error", "message": "missing channel_id" }),
    };
    let payload = cmd["payload"].as_str().unwrap_or("").to_string();
    let priority = Priority::try_from(cmd["priority"].as_i64().unwrap_or(1) as i32)
        .unwrap_or(Priority::Info);

    let config = state.config().await;
    let msg = PatchMessage::new(config.client_id, &config.client_name, channel_id, priority, payload);

    match encode_message(&msg) {
        Ok(bytes) => {
            let _ = transport.send_to_peers(bytes, state, &config).await;
            state.store_message(msg.clone()).await;
            json!({ "event": "ack_send", "message_id": msg.message_id.to_string() })
        }
        Err(e) => json!({ "event": "error", "message": e.to_string() }),
    }
}

async fn cmd_send_flash(cmd: Value, state: &AppState, transport: &Transport) -> Value {
    let channel_id = match cmd["channel_id"].as_str() {
        Some(s) => s.to_string(),
        None => return json!({ "event": "error", "message": "missing channel_id" }),
    };
    let config = state.config().await;
    let flash = ChannelFlash {
        channel_id,
        sender_id: config.client_id,
        sender_name: config.client_name.clone(),
    };
    match encode_flash(&flash) {
        Ok(bytes) => {
            let _ = transport.send_to_peers(bytes, state, &config).await;
            // Also fire locally so the sender sees their own flash immediately.
            state.publish(AppEvent::ChannelFlash(flash)).await;
            json!({ "event": "ok" })
        }
        Err(e) => json!({ "event": "error", "message": e.to_string() }),
    }
}

async fn cmd_get_channels(state: &AppState) -> Value {
    let channels = state.get_channels().await;
    json!({ "event": "channels", "data": channels })
}

async fn cmd_get_peers(state: &AppState) -> Value {
    let peers = state.get_peers().await;
    json!({ "event": "peers", "data": peers })
}

async fn cmd_get_messages(cmd: Value, state: &AppState) -> Value {
    let channel_id = cmd["channel_id"].as_str().unwrap_or("").to_string();
    let limit = cmd["limit"].as_u64().unwrap_or(50) as usize;
    let messages = state.get_messages(&channel_id, limit).await;
    json!({ "event": "messages", "channel_id": channel_id, "data": messages })
}

fn cmd_get_interfaces() -> Value {
    match list_interfaces() {
        Ok(ifaces) => json!({ "event": "interfaces", "data": ifaces }),
        Err(e) => json!({ "event": "error", "message": e.to_string() }),
    }
}

async fn cmd_get_config(state: &AppState) -> Value {
    let config = state.config().await;
    json!({
        "event": "config",
        "data": {
            "client_name": config.client_name,
            "osc_port": config.osc_port,
            "network_interface": config.network_interface,
            "static_peers": config.static_peers,
        }
    })
}

async fn cmd_set_client_name(cmd: Value, state: &AppState) -> Value {
    let name = match cmd["name"].as_str().map(|s| s.trim().to_string()) {
        Some(n) if !n.is_empty() => n,
        _ => return json!({ "event": "error", "message": "name must be a non-empty string" }),
    };
    match state.set_client_name(name.clone()).await {
        Ok(()) => json!({ "event": "config_updated", "client_name": name }),
        Err(e) => json!({ "event": "error", "message": e.to_string() }),
    }
}

fn cmd_set_interface(cmd: Value) -> Value {
    let name = cmd["name"].as_str().unwrap_or("").to_string();
    json!({ "event": "ok", "message": format!("Interface set to {} — restart required", name) })
}

async fn cmd_add_static_peer(cmd: Value, state: &AppState) -> Value {
    let address = cmd["address"].as_str().unwrap_or("").to_string();
    let port = cmd["port"].as_u64().unwrap_or(9000) as u16;
    let label = cmd["label"].as_str().map(|s| s.to_string());
    json!({ "event": "ok", "data": { "address": address, "port": port, "label": label } })
}

async fn cmd_upsert_channel(cmd: Value, state: &AppState) -> Value {
    let id = match cmd["id"].as_str() {
        Some(s) => s.to_string(),
        None => return json!({ "event": "error", "message": "missing id" }),
    };
    let display_name = cmd["display_name"].as_str().unwrap_or(&id).to_string();
    let color = cmd["color"].as_str().unwrap_or("#607D8B").to_string();
    let channel = Channel::new(id, display_name, color);
    state.upsert_channel(channel).await;
    json!({ "event": "ok" })
}

async fn cmd_upsert_shortcut(cmd: Value, state: &AppState) -> Value {
    let channel_id = match cmd["channel_id"].as_str() {
        Some(s) => s.to_string(),
        None => return json!({ "event": "error", "message": "missing channel_id" }),
    };
    let label = match cmd["label"].as_str() {
        Some(s) if !s.trim().is_empty() => s.trim().to_string(),
        _ => return json!({ "event": "error", "message": "label must be non-empty" }),
    };
    let payload = cmd["payload"].as_str().unwrap_or("").to_string();
    let key_binding = cmd["key_binding"].as_str().map(|s| s.to_string());
    let priority = cmd["priority"].as_i64().unwrap_or(1) as i32;

    let shortcut = ShortcutMessage { label, payload, key_binding, priority };

    match state.upsert_shortcut(&channel_id, shortcut).await {
        Ok(()) => json!({ "event": "ok" }),
        Err(e) => json!({ "event": "error", "message": e.to_string() }),
    }
}

async fn cmd_delete_shortcut(cmd: Value, state: &AppState) -> Value {
    let channel_id = match cmd["channel_id"].as_str() {
        Some(s) => s.to_string(),
        None => return json!({ "event": "error", "message": "missing channel_id" }),
    };
    let label = match cmd["label"].as_str() {
        Some(s) => s.to_string(),
        None => return json!({ "event": "error", "message": "missing label" }),
    };
    match state.delete_shortcut(&channel_id, &label).await {
        Ok(()) => json!({ "event": "ok" }),
        Err(e) => json!({ "event": "error", "message": e.to_string() }),
    }
}

async fn cmd_delete_channel(cmd: Value, state: &AppState) -> Value {
    let id = match cmd["id"].as_str() {
        Some(s) => s.to_string(),
        None => return json!({ "event": "error", "message": "missing id" }),
    };
    match state.delete_channel(&id).await {
        Ok(()) => json!({ "event": "ok" }),
        Err(e) => json!({ "event": "error", "message": e.to_string() }),
    }
}

async fn cmd_save_session(cmd: Value, state: &AppState) -> Value {
    let name = match cmd["name"].as_str().map(|s| s.trim().to_string()) {
        Some(n) if !n.is_empty() => n,
        _ => return json!({ "event": "error", "message": "name must be a non-empty string" }),
    };
    let channels = state.get_channels().await;
    let config = state.config().await;
    let sess = SessionConfig::new(&name, channels, config.static_peers);
    match session::save_session(&sess) {
        Ok(slug) => json!({ "event": "session_saved", "slug": slug, "name": name }),
        Err(e)   => json!({ "event": "error", "message": e.to_string() }),
    }
}

async fn cmd_load_session(cmd: Value, state: &AppState) -> Value {
    let slug = match cmd["slug"].as_str() {
        Some(s) => s.to_string(),
        None => return json!({ "event": "error", "message": "missing slug" }),
    };
    match session::load_session(&slug) {
        Ok(sess) => {
            let name = sess.name.clone();
            let channel_count = sess.channels.len();
            match state.apply_session(sess.channels).await {
                Ok(()) => json!({ "event": "session_loaded", "slug": slug, "name": name, "channel_count": channel_count }),
                Err(e) => json!({ "event": "error", "message": e.to_string() }),
            }
        }
        Err(e) => json!({ "event": "error", "message": e.to_string() }),
    }
}

fn cmd_list_sessions() -> Value {
    match session::list_sessions() {
        Ok(list) => json!({ "event": "sessions", "data": list }),
        Err(e)   => json!({ "event": "error", "message": e.to_string() }),
    }
}

fn cmd_delete_session(cmd: Value) -> Value {
    let slug = match cmd["slug"].as_str() {
        Some(s) => s.to_string(),
        None => return json!({ "event": "error", "message": "missing slug" }),
    };
    match session::delete_session(&slug) {
        Ok(()) => json!({ "event": "ok" }),
        Err(e) => json!({ "event": "error", "message": e.to_string() }),
    }
}
