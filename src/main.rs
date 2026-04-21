use clap::{Parser, Subcommand};
use emaclaude::state::{Event, Transition, WorkflowConfig, WorkflowState};
use std::io::Read;
use std::process;

#[derive(Parser)]
#[command(
    name = "emaclaude",
    about = "Claude Code + Doom Emacs orchestration CLI"
)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Process a state transition: reads JSON from stdin, writes result to stdout
    Transition,
    /// Set up symlinks for skills and Emacs module
    Setup,
}

#[derive(serde::Deserialize)]
struct TransitionInput {
    state: WorkflowState,
    event: Event,
    config: WorkflowConfig,
}

#[derive(serde::Serialize)]
struct TransitionOutput {
    state: WorkflowState,
    effects: Vec<emaclaude::state::SideEffect>,
}

#[derive(serde::Serialize)]
struct ErrorOutput {
    error: String,
}

fn print_json<T: serde::Serialize>(value: &T) {
    println!(
        "{}",
        serde_json::to_string(value).expect("failed to serialize JSON output")
    );
}

fn exit_with_error(message: impl Into<String>) -> ! {
    print_json(&ErrorOutput {
        error: message.into(),
    });
    process::exit(1);
}

fn main() {
    let cli = Cli::parse();

    match cli.command {
        Commands::Transition => {
            run_transition();
        }
        Commands::Setup => {
            if let Err(e) = setup() {
                eprintln!("setup failed: {}", e);
                process::exit(1);
            }
        }
    }
}

fn run_transition() {
    let mut input = String::new();
    if let Err(e) = std::io::stdin().read_to_string(&mut input) {
        exit_with_error(format!("failed to read stdin: {}", e));
    }

    let parsed: TransitionInput = match serde_json::from_str(&input) {
        Ok(v) => v,
        Err(e) => exit_with_error(format!("invalid input JSON: {}", e)),
    };

    let Transition { state, effects } = parsed.state.next(parsed.event, &parsed.config);

    let output = TransitionOutput { state, effects };
    print_json(&output);
}

fn setup() -> Result<(), Box<dyn std::error::Error>> {
    let home = std::env::var("HOME")
        .map(std::path::PathBuf::from)
        .map_err(|_| "could not determine home directory")?;
    let manifest_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));

    // Symlink each skill directory individually into ~/.claude/skills/
    let skills_src = manifest_dir.join("skills");
    let skills_parent = home.join(".claude").join("skills");
    std::fs::create_dir_all(&skills_parent)?;

    for entry in std::fs::read_dir(&skills_src)? {
        let entry = entry?;
        if entry.file_type()?.is_dir() {
            let name = entry.file_name();
            let dst = skills_parent.join(&name);
            symlink_path(&entry.path(), &dst)?;
        }
    }

    // Symlink bin/emaclaude-signal to ~/.local/bin/
    let signal_src = manifest_dir.join("bin").join("emaclaude-signal");
    let local_bin = home.join(".local").join("bin");
    std::fs::create_dir_all(&local_bin)?;
    let signal_dst = local_bin.join("emaclaude-signal");
    symlink_path(&signal_src, &signal_dst)?;

    // Symlink Doom module
    let emacs_src = manifest_dir.join("emacs");
    let emacs_dst = home
        .join(".doom.d")
        .join("modules")
        .join("tools")
        .join("emaclaude");
    symlink_path(&emacs_src, &emacs_dst)?;

    eprintln!("setup complete");
    Ok(())
}

fn symlink_path(
    src: &std::path::Path,
    dst: &std::path::Path,
) -> Result<(), Box<dyn std::error::Error>> {
    if let Some(parent) = dst.parent() {
        std::fs::create_dir_all(parent)?;
    }
    if dst.exists() || dst.symlink_metadata().is_ok() {
        eprintln!("destination already exists, skipping: {}", dst.display());
        return Ok(());
    }
    std::os::unix::fs::symlink(src, dst)?;
    eprintln!("symlinked: {} -> {}", src.display(), dst.display());
    Ok(())
}
