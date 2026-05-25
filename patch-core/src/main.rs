use anyhow::Result;
use tracing::info;

mod bridge;
mod discovery;
mod osc;
mod reliability;
mod state;
mod transport;

#[tokio::main]
async fn main() -> Result<()> {
    // Initialise structured logging — override with RUST_LOG env var
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "patch_core=debug".into()),
        )
        .init();

    info!("Patch core engine starting");

    // Load or create default config
    let config = state::config::Config::load_or_default()?;
    info!(client_name = %config.client_name, osc_port = config.osc_port, "Config loaded");

    // Shared application state
    let app_state = state::AppState::new(config.clone());

    // Start the OSC transport (UDP listener + sender)
    let transport = transport::Transport::new(&config, app_state.clone()).await?;

    // Start mDNS discovery + OSC beacon
    let _discovery = discovery::Discovery::new(&config, app_state.clone()).await?;

    // Start the bridge server (Flutter ↔ Rust JSON/TCP socket)
    let bridge = bridge::BridgeServer::new(config.bridge_port, app_state.clone(), transport);
    bridge.run().await?;

    Ok(())
}
