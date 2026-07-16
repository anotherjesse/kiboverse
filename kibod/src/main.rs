use kibod::ai::Ai;
use kibod::store::Store;
use std::net::SocketAddr;
use std::path::PathBuf;
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "kibod=info,tower_http=info".into()),
        )
        .init();
    let address: SocketAddr = std::env::var("KIBO_BIND")
        .unwrap_or_else(|_| "127.0.0.1:3000".into())
        .parse()?;
    let data_dir = std::env::var_os("KIBO_DATA_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            let home = std::env::var_os("HOME")
                .map(PathBuf::from)
                .unwrap_or_else(|| ".".into());
            home.join("kibo-data")
        });
    let store = Store::open(&data_dir)?;
    let ai = Ai::from_env();
    tracing::info!(data_dir = %data_dir.display(), mock_ai = ai.is_mock(), "opened kibo store");
    let listener = tokio::net::TcpListener::bind(address).await?;
    tracing::info!(url = %format!("http://{address}"), "kibod listening");
    axum::serve(listener, kibod::app(store, ai)?)
        .with_graceful_shutdown(shutdown_signal())
        .await?;
    Ok(())
}

async fn shutdown_signal() {
    let ctrl_c = async {
        tokio::signal::ctrl_c()
            .await
            .expect("install Ctrl+C handler");
    };
    #[cfg(unix)]
    let terminate = async {
        tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
            .expect("install terminate handler")
            .recv()
            .await;
    };
    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();
    tokio::select! {
        () = ctrl_c => {},
        () = terminate => {},
    }
}
