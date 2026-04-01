use anyhow::Result;
use clap::{Parser, Subcommand};
use emaclaude::config::Config;
use emaclaude::server;

#[derive(Parser)]
#[command(name = "emaclaude", about = "Claude Code + Doom Emacs orchestration daemon")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Start the emaclaude daemon
    Serve {
        /// Port to listen on (overrides config)
        #[arg(short, long)]
        port: Option<u16>,
    },
    /// Set up symlinks for skills and Emacs module
    Setup,
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let cli = Cli::parse();

    match cli.command {
        Commands::Serve { port } => {
            let mut config = Config::load()?;
            if let Some(p) = port {
                config.port = p;
            }
            tracing::info!(port = config.port, "starting emaclaude daemon");
            server::run(config).await?;
        }
        Commands::Setup => {
            setup()?;
        }
    }

    Ok(())
}

fn setup() -> Result<()> {
    let home = dirs::home_dir().ok_or_else(|| anyhow::anyhow!("could not determine home directory"))?;

    let skills_src = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("skills");
    let skills_dst = home.join(".claude").join("skills").join("emaclaude");

    let emacs_src = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("emacs");
    let emacs_dst = home.join(".doom.d").join("modules").join("tools").join("emaclaude");

    symlink_dir(&skills_src, &skills_dst)?;
    symlink_dir(&emacs_src, &emacs_dst)?;

    tracing::info!("setup complete");
    Ok(())
}

fn symlink_dir(src: &std::path::Path, dst: &std::path::Path) -> Result<()> {
    if let Some(parent) = dst.parent() {
        std::fs::create_dir_all(parent)?;
    }
    if dst.exists() || dst.symlink_metadata().is_ok() {
        tracing::warn!(dst = %dst.display(), "destination already exists, skipping");
        return Ok(());
    }
    std::os::unix::fs::symlink(src, dst)?;
    tracing::info!(src = %src.display(), dst = %dst.display(), "symlinked");
    Ok(())
}
