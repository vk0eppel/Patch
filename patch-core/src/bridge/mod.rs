//! TCP JSON bridge — Flutter ↔ Rust IPC.
//!
//! The Flutter app connects to this local TCP server.
//! All messages are newline-delimited JSON.
//!
//! ## Protocol
//!
//! Flutter → Rust (commands):
//! ```json
//! { "cmd": "send_message", "channel_id": "rf", "payload": "Battery low", "priority": 3 }
//! { "cmd": "send_flash", "channel_id": "rf" }
//! { "cmd": "get_channels" }
//! { "cmd": "get_peers" }
//! { "cmd": "get_messages", "channel_id": "rf", "limit": 50 }
//! { "cmd": "get_interfaces" }
//! { "cmd": "set_interface", "name": "en0" }
//! { "cmd": "add_static_peer", "address": "192.168.1.50", "port": 9000, "label": "FOH Desk" }
//! { "cmd": "upsert_channel", "id": "rf", "display_name": "RF", "color": "#1E88E5" }
//! ```
//!
//! Rust → Flutter (events, newline-delimited):
//! ```json
//! { "event": "message", "data": { ...PatchMessage } }
//! { "event": "peer_updated", "data": { ...Peer } }
//! { "event": "peer_expired", "data": { "peer_id": "..." } }
//! { "event": "channel_flash", "data": { "channel_id": "rf", ... } }
//! { "event": "channel_list_updated" }
//! { "event": "error", "message": "..." }
//! ```

mod commands;
mod events;

use anyhow::Result;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};
use tracing::{error, info};

use crate::state::AppState;
use crate::transport::Transport;

pub struct BridgeServer {
    port: u16,
    state: AppState,
    transport: Transport,
}

impl BridgeServer {
    pub fn new(port: u16, state: AppState, transport: Transport) -> Self {
        Self { port, state, transport }
    }

    pub async fn run(self) -> Result<()> {
        let addr = format!("127.0.0.1:{}", self.port);
        let listener = TcpListener::bind(&addr).await?;
        info!("Bridge server listening on {}", addr);

        let state = self.state;
        let transport = std::sync::Arc::new(self.transport);

        loop {
            match listener.accept().await {
                Ok((stream, peer)) => {
                    info!("Flutter client connected: {}", peer);
                    let conn_state = state.clone();
                    let conn_transport = transport.clone();
                    tokio::spawn(async move {
                        if let Err(e) = handle_connection(stream, conn_state, conn_transport).await {
                            error!("Bridge connection error: {}", e);
                        }
                    });
                }
                Err(e) => error!("Accept error: {}", e),
            }
        }
    }
}

async fn handle_connection(
    stream: TcpStream,
    state: AppState,
    transport: std::sync::Arc<Transport>,
) -> Result<()> {
    let (reader, mut writer) = stream.into_split();
    let mut lines = BufReader::new(reader).lines();

    // Subscribe to app events before entering the read loop
    let mut event_rx = state.subscribe();

    // Spawn event-push task (Rust → Flutter)
    let mut event_writer = {
        // We can't clone the writer directly, so we use a channel
        let (tx, mut rx) = tokio::sync::mpsc::channel::<String>(256);

        // Event forwarder
        let fwd_tx = tx.clone();
        tokio::spawn(async move {
            loop {
                match event_rx.recv().await {
                    Ok(event) => {
                        if let Some(line) = events::serialize_event(event) {
                            let _ = fwd_tx.send(line).await;
                        }
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                        tracing::warn!("Bridge lagged by {} events", n);
                    }
                    Err(_) => break,
                }
            }
        });

        // Writer task
        tokio::spawn(async move {
            while let Some(line) = rx.recv().await {
                let _ = writer.write_all(line.as_bytes()).await;
                let _ = writer.write_all(b"\n").await;
            }
        });

        tx
    };

    // Read loop (Flutter → Rust commands)
    while let Ok(Some(line)) = lines.next_line().await {
        let response = commands::handle_command(&line, &state, &transport).await;
        let _ = event_writer.send(response).await;
    }

    info!("Flutter client disconnected");
    Ok(())
}
