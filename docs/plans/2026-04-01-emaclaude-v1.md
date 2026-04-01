# Emaclaude V1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Rust daemon + Doom Emacs module that orchestrates planning, coding, and review Claude Code sessions with an autonomous review loop.

**Architecture:** Axum HTTP server receives signals from Claude Code skills, a state machine manages workflow transitions, and an emacsclient bridge controls Emacs buffer layout and prompt injection. MRA provides supervisor-based process lifecycle management.

**Tech Stack:** Rust (axum, tokio, serde, figment, clap), MRA (supervisor), Emacs Lisp (Doom module, vterm, magit)

---

### Task 1: Project Scaffolding

**Files:**
- Create: `Cargo.toml`
- Create: `src/main.rs`
- Create: `src/lib.rs`

- [ ] **Step 1: Create Cargo.toml**

```toml
[package]
name = "emaclaude"
version = "0.1.0"
edition = "2024"
rust-version = "1.91"
description = "Claude Code + Doom Emacs orchestration powered by MRA"
license = "MIT"

[dependencies]
mra = { path = "../mra" }
axum = "0.8"
tokio = { version = "1", features = ["full"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
figment = { version = "0.10", features = ["toml", "env"] }
toml = "0.8"
clap = { version = "4", features = ["derive"] }
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter"] }
thiserror = "2"

[dev-dependencies]
reqwest = { version = "0.12", features = ["json"] }
tokio-test = "0.4"
tempfile = "3"
```

- [ ] **Step 2: Create src/lib.rs**

```rust
pub mod config;
pub mod emacs;
pub mod server;
pub mod state;
```

- [ ] **Step 3: Create src/main.rs with CLI**

```rust
use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(name = "emaclaude", about = "Claude Code + Doom Emacs orchestration")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Start the emaclaude daemon
    Serve {
        /// Port to listen on
        #[arg(short, long, default_value = "7878")]
        port: u16,
    },
    /// Install skills and Doom module
    Setup,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "emaclaude=info".parse().unwrap()),
        )
        .init();

    let cli = Cli::parse();

    match cli.command {
        Commands::Serve { port } => {
            tracing::info!("Starting emaclaude daemon on port {port}");
            let config = emaclaude::config::Config::load()?;
            let config = emaclaude::config::Config { port, ..config };
            emaclaude::server::run(config).await?;
        }
        Commands::Setup => {
            setup()?;
        }
    }

    Ok(())
}

fn setup() -> anyhow::Result<()> {
    use std::fs;
    use std::os::unix::fs::symlink;
    use std::path::PathBuf;

    let project_dir = std::env::current_dir()?;
    let skills_src = project_dir.join("skills");
    let emacs_src = project_dir.join("emacs");

    // Symlink skills
    let skills_dest = dirs::home_dir()
        .expect("could not find home directory")
        .join(".claude/skills/emaclaude");

    if skills_dest.exists() {
        fs::remove_file(&skills_dest).or_else(|_| fs::remove_dir_all(&skills_dest))?;
    }
    symlink(&skills_src, &skills_dest)?;
    println!("Linked skills: {} -> {}", skills_src.display(), skills_dest.display());

    // Symlink Doom module
    let doom_dir = dirs::home_dir()
        .expect("could not find home directory")
        .join(".doom.d/modules/tools/emaclaude");

    if let Some(parent) = doom_dir.parent() {
        fs::create_dir_all(parent)?;
    }
    if doom_dir.exists() {
        fs::remove_file(&doom_dir).or_else(|_| fs::remove_dir_all(&doom_dir))?;
    }
    symlink(&emacs_src, &doom_dir)?;
    println!("Linked Doom module: {} -> {}", emacs_src.display(), doom_dir.display());

    println!("\nSetup complete. Add to ~/.doom.d/init.el:");
    println!("  (emaclaude +doom)    ; under :tools");
    println!("\nThen run: doom sync");

    Ok(())
}
```

- [ ] **Step 4: Add `dirs` dependency for home directory resolution**

Add to Cargo.toml dependencies:
```toml
dirs = "6"
anyhow = "1"
```

- [ ] **Step 5: Verify it compiles**

Run: `cd /Users/yuan/Developer/emaclaude && cargo check`
Expected: compiles (with warnings about missing modules, which is fine since we'll create stub files)

- [ ] **Step 6: Create stub modules so it compiles**

Create `src/config.rs`:
```rust
use serde::Deserialize;

#[derive(Debug, Clone, Deserialize)]
pub struct Config {
    pub port: u16,
    pub emacsclient_path: String,
    pub confirmation_loops: u32,
    pub buffers: BufferNames,
}

#[derive(Debug, Clone, Deserialize)]
pub struct BufferNames {
    pub planning: String,
    pub coding: String,
    pub review: String,
    pub diff: String,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            port: 7878,
            emacsclient_path: "emacsclient".into(),
            confirmation_loops: 2,
            buffers: BufferNames::default(),
        }
    }
}

impl Default for BufferNames {
    fn default() -> Self {
        Self {
            planning: "*mra-planning*".into(),
            coding: "*mra-coding*".into(),
            review: "*mra-review*".into(),
            diff: "*mra-diff*".into(),
        }
    }
}

impl Config {
    pub fn load() -> anyhow::Result<Self> {
        use figment::{Figment, providers::{Serialized, Toml, Env}};

        let config: Config = Figment::new()
            .merge(Serialized::defaults(ConfigFile::default()))
            .merge(Toml::file(config_path()))
            .merge(Env::prefixed("EMACLAUDE_"))
            .extract()?;

        Ok(config)
    }
}

#[derive(Debug, Clone, serde::Serialize, Deserialize)]
struct ConfigFile {
    port: u16,
    emacsclient_path: String,
    confirmation_loops: u32,
    buffers: BufferNames,
}

impl Default for ConfigFile {
    fn default() -> Self {
        let c = Config::default();
        Self {
            port: c.port,
            emacsclient_path: c.emacsclient_path,
            confirmation_loops: c.confirmation_loops,
            buffers: c.buffers,
        }
    }
}

impl serde::Serialize for BufferNames {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeStruct;
        let mut s = serializer.serialize_struct("BufferNames", 4)?;
        s.serialize_field("planning", &self.planning)?;
        s.serialize_field("coding", &self.coding)?;
        s.serialize_field("review", &self.review)?;
        s.serialize_field("diff", &self.diff)?;
        s.end()
    }
}

fn config_path() -> std::path::PathBuf {
    dirs::config_dir()
        .unwrap_or_else(|| std::path::PathBuf::from("."))
        .join("emaclaude/config.toml")
}
```

Create `src/state.rs`:
```rust
// Stub - implemented in Task 2
```

Create `src/server.rs`:
```rust
// Stub - implemented in Task 3
use crate::config::Config;

pub async fn run(_config: Config) -> anyhow::Result<()> {
    Ok(())
}
```

Create `src/emacs.rs`:
```rust
// Stub - implemented in Task 4
```

- [ ] **Step 7: Verify full compilation**

Run: `cd /Users/yuan/Developer/emaclaude && cargo check`
Expected: PASS with no errors

- [ ] **Step 8: Commit**

```bash
cd /Users/yuan/Developer/emaclaude
git add -A
git commit -m "feat: project scaffolding with CLI, config, and stub modules"
```

---

### Task 2: Workflow State Machine

**Files:**
- Create: `src/state.rs`
- Create: `tests/state_test.rs`

The state machine is the core logic of emaclaude. It's a pure function: given current state + event → new state + side effects. No I/O, fully testable.

- [ ] **Step 1: Write failing test for basic state transitions**

Create `tests/state_test.rs`:
```rust
use emaclaude::state::{WorkflowState, Event, Transition, SideEffect};

#[test]
fn idle_to_coding_on_planning_done() {
    let state = WorkflowState::Idle;
    let event = Event::PlanningDone {
        prompt: "Implement feature X".into(),
        spec_path: "./specs/plan.md".into(),
    };

    let transition = state.next(event);

    assert_eq!(transition.state, WorkflowState::Coding);
    assert!(transition.effects.contains(&SideEffect::SpawnCodingAgent {
        prompt: "Implement feature X".into(),
        spec_path: "./specs/plan.md".into(),
    }));
    assert!(transition.effects.contains(&SideEffect::SpawnReviewAgent));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/yuan/Developer/emaclaude && cargo test --test state_test`
Expected: FAIL — state types don't exist yet

- [ ] **Step 3: Implement state machine types and PlanningDone transition**

Replace `src/state.rs`:
```rust
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum WorkflowState {
    Idle,
    Coding,
    Reviewing,
    Confirming { approval_count: u32 },
    HumanReview,
    PrCreated,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    PlanningDone { prompt: String, spec_path: String },
    CodingDone { branch: String },
    ReviewDone { status: ReviewStatus, feedback: String },
    HumanComments { comments: Vec<Comment> },
    CreatePr,
    AddressGithubReviews { pr_number: u64 },
    ClearSession,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum ReviewStatus {
    Approved,
    ChangesNeeded,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Comment {
    pub file: String,
    pub line: u32,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SideEffect {
    SpawnCodingAgent { prompt: String, spec_path: String },
    SpawnReviewAgent,
    SendToCodingAgent { prompt: String },
    SendToReviewAgent { prompt: String },
    OpenDiffView,
    RefreshDiffView,
    Notify { message: String },
    Shutdown,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Transition {
    pub state: WorkflowState,
    pub effects: Vec<SideEffect>,
}

impl WorkflowState {
    pub fn next(self, event: Event) -> Transition {
        match (self, event) {
            (WorkflowState::Idle, Event::PlanningDone { prompt, spec_path }) => Transition {
                state: WorkflowState::Coding,
                effects: vec![
                    SideEffect::SpawnCodingAgent { prompt, spec_path },
                    SideEffect::SpawnReviewAgent,
                ],
            },
            // Unhandled transitions return same state with no effects
            (state, _) => Transition {
                state,
                effects: vec![],
            },
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/yuan/Developer/emaclaude && cargo test --test state_test`
Expected: PASS

- [ ] **Step 5: Write failing test for CodingDone transition**

Add to `tests/state_test.rs`:
```rust
#[test]
fn coding_to_reviewing_on_coding_done() {
    let state = WorkflowState::Coding;
    let event = Event::CodingDone { branch: "feat/x".into() };

    let transition = state.next(event);

    assert_eq!(transition.state, WorkflowState::Reviewing);
    assert!(matches!(
        &transition.effects[0],
        SideEffect::SendToReviewAgent { .. }
    ));
}
```

- [ ] **Step 6: Run test to verify it fails**

Run: `cd /Users/yuan/Developer/emaclaude && cargo test --test state_test coding_to_reviewing`
Expected: FAIL — transition not implemented

- [ ] **Step 7: Implement CodingDone transition**

Add to the `match` in `WorkflowState::next`:
```rust
(WorkflowState::Coding, Event::CodingDone { branch }) => Transition {
    state: WorkflowState::Reviewing,
    effects: vec![SideEffect::SendToReviewAgent {
        prompt: format!(
            "Review the git diff of branch `{branch}` against `main`. \
             Check for: code quality, security vulnerabilities, redundant code, \
             and adherence to the spec. When done, run:\n\
             curl -s -X POST http://localhost:7878/review-done \
             -H 'Content-Type: application/json' \
             -d '{{\"status\": \"approved_or_changes_needed\", \"feedback\": \"YOUR_FEEDBACK\"}}'"
        ),
    }],
},
```

- [ ] **Step 8: Run test to verify it passes**

Run: `cd /Users/yuan/Developer/emaclaude && cargo test --test state_test`
Expected: PASS

- [ ] **Step 9: Write failing test for review loop (changes needed)**

Add to `tests/state_test.rs`:
```rust
#[test]
fn reviewing_to_coding_on_changes_needed() {
    let state = WorkflowState::Reviewing;
    let event = Event::ReviewDone {
        status: ReviewStatus::ChangesNeeded,
        feedback: "Fix error handling in auth.rs".into(),
    };

    let transition = state.next(event);

    assert_eq!(transition.state, WorkflowState::Coding);
    assert!(matches!(
        &transition.effects[0],
        SideEffect::SendToCodingAgent { .. }
    ));
}
```

- [ ] **Step 10: Run test, verify fail, implement**

Add to the `match`:
```rust
(WorkflowState::Reviewing, Event::ReviewDone { status: ReviewStatus::ChangesNeeded, feedback }) => Transition {
    state: WorkflowState::Coding,
    effects: vec![SideEffect::SendToCodingAgent {
        prompt: format!(
            "The review agent found issues. Fix them:\n\n{feedback}\n\n\
             When done, run:\n\
             curl -s -X POST http://localhost:7878/coding-done \
             -H 'Content-Type: application/json' \
             -d '{{\"branch\": \"CURRENT_BRANCH\"}}'"
        ),
    }],
},
```

Run: `cd /Users/yuan/Developer/emaclaude && cargo test --test state_test`
Expected: PASS

- [ ] **Step 11: Write failing test for review approved → confirming**

Add to `tests/state_test.rs`:
```rust
#[test]
fn reviewing_to_confirming_on_approved() {
    let state = WorkflowState::Reviewing;
    let event = Event::ReviewDone {
        status: ReviewStatus::Approved,
        feedback: "Looks good".into(),
    };

    let transition = state.next(event);

    assert_eq!(transition.state, WorkflowState::Confirming { approval_count: 1 });
    // Should re-run review agent (skip coding agent)
    assert!(matches!(
        &transition.effects[0],
        SideEffect::SendToReviewAgent { .. }
    ));
}
```

- [ ] **Step 12: Implement approved → confirming**

Add to the `match`:
```rust
(WorkflowState::Reviewing, Event::ReviewDone { status: ReviewStatus::Approved, .. }) => Transition {
    state: WorkflowState::Confirming { approval_count: 1 },
    effects: vec![SideEffect::SendToReviewAgent {
        prompt: "Re-review the code one more time to confirm your previous approval. \
                 Check git diff against main again thoroughly. When done, run:\n\
                 curl -s -X POST http://localhost:7878/review-done \
                 -H 'Content-Type: application/json' \
                 -d '{\"status\": \"approved_or_changes_needed\", \"feedback\": \"YOUR_FEEDBACK\"}'".into(),
    }],
},
```

Run: `cd /Users/yuan/Developer/emaclaude && cargo test --test state_test`
Expected: PASS

- [ ] **Step 13: Write failing tests for confirming transitions**

Add to `tests/state_test.rs`:
```rust
#[test]
fn confirming_increments_on_approved() {
    let state = WorkflowState::Confirming { approval_count: 1 };
    let event = Event::ReviewDone {
        status: ReviewStatus::Approved,
        feedback: "Still looks good".into(),
    };

    let transition = state.next(event);

    // 2 consecutive approvals → human review
    assert_eq!(transition.state, WorkflowState::HumanReview);
    assert!(transition.effects.contains(&SideEffect::OpenDiffView));
}

#[test]
fn confirming_resets_on_changes_needed() {
    let state = WorkflowState::Confirming { approval_count: 1 };
    let event = Event::ReviewDone {
        status: ReviewStatus::ChangesNeeded,
        feedback: "Found a new issue".into(),
    };

    let transition = state.next(event);

    assert_eq!(transition.state, WorkflowState::Coding);
    assert!(matches!(
        &transition.effects[0],
        SideEffect::SendToCodingAgent { .. }
    ));
}
```

- [ ] **Step 14: Implement confirming transitions**

We need `confirmation_loops` as a parameter. Refactor `next` to take config:

Update `src/state.rs` — add a config param to `next`:
```rust
#[derive(Debug, Clone)]
pub struct WorkflowConfig {
    pub confirmation_loops: u32,
    pub port: u16,
}

impl Default for WorkflowConfig {
    fn default() -> Self {
        Self {
            confirmation_loops: 2,
            port: 7878,
        }
    }
}

impl WorkflowState {
    pub fn next(self, event: Event, config: &WorkflowConfig) -> Transition {
        match (self, event) {
            // ... existing arms unchanged, just add config param to signature ...

            (WorkflowState::Confirming { approval_count }, Event::ReviewDone { status: ReviewStatus::Approved, .. }) => {
                if approval_count >= config.confirmation_loops {
                    Transition {
                        state: WorkflowState::HumanReview,
                        effects: vec![
                            SideEffect::OpenDiffView,
                            SideEffect::Notify { message: "Review loop complete. Ready for human review.".into() },
                        ],
                    }
                } else {
                    Transition {
                        state: WorkflowState::Confirming { approval_count: approval_count + 1 },
                        effects: vec![SideEffect::SendToReviewAgent {
                            prompt: "Re-review the code one more time to confirm your previous approval. \
                                     Check git diff against main again thoroughly. When done, run:\n\
                                     curl -s -X POST http://localhost:7878/review-done \
                                     -H 'Content-Type: application/json' \
                                     -d '{\"status\": \"approved_or_changes_needed\", \"feedback\": \"YOUR_FEEDBACK\"}'".into(),
                        }],
                    }
                }
            },

            (WorkflowState::Confirming { .. }, Event::ReviewDone { status: ReviewStatus::ChangesNeeded, feedback }) => Transition {
                state: WorkflowState::Coding,
                effects: vec![SideEffect::SendToCodingAgent {
                    prompt: format!(
                        "The review agent found new issues during confirmation. Fix them:\n\n{feedback}\n\n\
                         When done, run:\n\
                         curl -s -X POST http://localhost:7878/coding-done \
                         -H 'Content-Type: application/json' \
                         -d '{{\"branch\": \"CURRENT_BRANCH\"}}'"
                    ),
                }],
            },

            // fallthrough
            (state, _) => Transition {
                state,
                effects: vec![],
            },
        }
    }
}
```

Update all tests to pass `&WorkflowConfig::default()` to `next()`.

Run: `cd /Users/yuan/Developer/emaclaude && cargo test --test state_test`
Expected: PASS

- [ ] **Step 15: Write failing tests for HumanReview and PrCreated states**

Add to `tests/state_test.rs`:
```rust
#[test]
fn human_review_sends_comments_to_coding_agent() {
    let config = WorkflowConfig::default();
    let state = WorkflowState::HumanReview;
    let event = Event::HumanComments {
        comments: vec![Comment {
            file: "src/auth.rs".into(),
            line: 42,
            text: "Add error handling here".into(),
        }],
    };

    let transition = state.next(event, &config);

    assert_eq!(transition.state, WorkflowState::HumanReview);
    assert!(matches!(
        &transition.effects[0],
        SideEffect::SendToCodingAgent { .. }
    ));
}

#[test]
fn human_review_to_pr_created() {
    let config = WorkflowConfig::default();
    let state = WorkflowState::HumanReview;
    let event = Event::CreatePr;

    let transition = state.next(event, &config);

    assert_eq!(transition.state, WorkflowState::PrCreated);
    assert!(matches!(
        &transition.effects[0],
        SideEffect::SendToCodingAgent { .. }
    ));
}

#[test]
fn pr_created_to_idle_on_clear() {
    let config = WorkflowConfig::default();
    let state = WorkflowState::PrCreated;
    let event = Event::ClearSession;

    let transition = state.next(event, &config);

    assert_eq!(transition.state, WorkflowState::Idle);
    assert!(transition.effects.contains(&SideEffect::Shutdown));
}
```

- [ ] **Step 16: Implement remaining transitions**

Add to the `match`:
```rust
(WorkflowState::HumanReview, Event::HumanComments { comments }) => {
    let formatted = comments.iter()
        .map(|c| format!("- {}:{} — {}", c.file, c.line, c.text))
        .collect::<Vec<_>>()
        .join("\n");
    Transition {
        state: WorkflowState::HumanReview,
        effects: vec![SideEffect::SendToCodingAgent {
            prompt: format!(
                "Address these review comments:\n\n{formatted}\n\n\
                 When done, run:\n\
                 curl -s -X POST http://localhost:7878/coding-done \
                 -H 'Content-Type: application/json' \
                 -d '{{\"branch\": \"CURRENT_BRANCH\"}}'"
            ),
        }],
    }
},

(WorkflowState::HumanReview, Event::CreatePr) => Transition {
    state: WorkflowState::PrCreated,
    effects: vec![SideEffect::SendToCodingAgent {
        prompt: "Commit all changes and create a PR. Generate the PR title and description \
                 from the spec and the git diff. Use `gh pr create`. When done, output the PR URL.".into(),
    }],
},

(WorkflowState::PrCreated, Event::AddressGithubReviews { pr_number }) => Transition {
    state: WorkflowState::PrCreated,
    effects: vec![SideEffect::SendToCodingAgent {
        prompt: format!(
            "Fetch review comments from PR #{pr_number} using `gh api`. \
             Address each comment, reply to it on GitHub, resolve the conversation, \
             and push the fixes. Do NOT re-request review."
        ),
    }],
},

(state, Event::ClearSession) => Transition {
    state: WorkflowState::Idle,
    effects: vec![
        SideEffect::Notify { message: "Clearing session...".into() },
        SideEffect::Shutdown,
    ],
},
```

Run: `cd /Users/yuan/Developer/emaclaude && cargo test --test state_test`
Expected: PASS

- [ ] **Step 17: Commit**

```bash
cd /Users/yuan/Developer/emaclaude
git add -A
git commit -m "feat: workflow state machine with full transition logic and tests"
```

---

### Task 3: HTTP API Server

**Files:**
- Create: `src/server.rs`
- Create: `tests/server_test.rs`

- [ ] **Step 1: Write failing test for health endpoint**

Create `tests/server_test.rs`:
```rust
use reqwest;

async fn spawn_server() -> u16 {
    let config = emaclaude::config::Config {
        port: 0, // random port
        ..Default::default()
    };
    let (addr, server) = emaclaude::server::create(config).await.unwrap();
    tokio::spawn(server);
    addr.port()
}

#[tokio::test]
async fn health_returns_current_state() {
    let port = spawn_server().await;

    let resp = reqwest::get(format!("http://localhost:{port}/health"))
        .await
        .unwrap();

    assert_eq!(resp.status(), 200);
    let body: serde_json::Value = resp.json().await.unwrap();
    assert_eq!(body["state"], "Idle");
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/yuan/Developer/emaclaude && cargo test --test server_test`
Expected: FAIL — `server::create` doesn't exist

- [ ] **Step 3: Implement server with health endpoint**

Replace `src/server.rs`:
```rust
use std::net::SocketAddr;
use std::sync::Arc;
use tokio::sync::Mutex;
use axum::{Router, Json, extract::State, routing::{get, post}};
use serde::{Deserialize, Serialize};

use crate::config::Config;
use crate::state::{WorkflowState, WorkflowConfig, Event, ReviewStatus, Comment, Transition, SideEffect};

pub struct AppState {
    pub workflow: WorkflowState,
    pub workflow_config: WorkflowConfig,
    pub config: Config,
}

type SharedState = Arc<Mutex<AppState>>;

pub async fn create(config: Config) -> anyhow::Result<(SocketAddr, impl std::future::Future<Output = ()>)> {
    let workflow_config = WorkflowConfig {
        confirmation_loops: config.confirmation_loops,
        port: config.port,
    };

    let state = Arc::new(Mutex::new(AppState {
        workflow: WorkflowState::Idle,
        workflow_config,
        config: config.clone(),
    }));

    let app = Router::new()
        .route("/health", get(health))
        .route("/planning-done", post(planning_done))
        .route("/coding-done", post(coding_done))
        .route("/review-done", post(review_done))
        .route("/human-review", post(human_review))
        .route("/create-pr", post(create_pr))
        .with_state(state);

    let addr = SocketAddr::from(([127, 0, 0, 1], config.port));
    let listener = tokio::net::TcpListener::bind(addr).await?;
    let actual_addr = listener.local_addr()?;

    let server = async move {
        axum::serve(listener, app).await.unwrap();
    };

    Ok((actual_addr, server))
}

pub async fn run(config: Config) -> anyhow::Result<()> {
    let (addr, server) = create(config).await?;
    tracing::info!("Listening on {addr}");
    server.await;
    Ok(())
}

#[derive(Serialize)]
struct HealthResponse {
    state: String,
}

async fn health(State(state): State<SharedState>) -> Json<HealthResponse> {
    let s = state.lock().await;
    Json(HealthResponse {
        state: format!("{:?}", s.workflow),
    })
}

#[derive(Deserialize)]
struct PlanningDonePayload {
    prompt: String,
    spec_path: String,
}

async fn planning_done(
    State(state): State<SharedState>,
    Json(payload): Json<PlanningDonePayload>,
) -> Json<serde_json::Value> {
    let mut s = state.lock().await;
    let transition = s.workflow.clone().next(
        Event::PlanningDone {
            prompt: payload.prompt,
            spec_path: payload.spec_path,
        },
        &s.workflow_config,
    );
    s.workflow = transition.state;
    // TODO: execute side effects via emacs bridge
    Json(serde_json::json!({ "status": "ok", "state": format!("{:?}", s.workflow) }))
}

#[derive(Deserialize)]
struct CodingDonePayload {
    branch: String,
}

async fn coding_done(
    State(state): State<SharedState>,
    Json(payload): Json<CodingDonePayload>,
) -> Json<serde_json::Value> {
    let mut s = state.lock().await;
    let transition = s.workflow.clone().next(
        Event::CodingDone { branch: payload.branch },
        &s.workflow_config,
    );
    s.workflow = transition.state;
    Json(serde_json::json!({ "status": "ok", "state": format!("{:?}", s.workflow) }))
}

#[derive(Deserialize)]
struct ReviewDonePayload {
    status: String,
    feedback: String,
}

async fn review_done(
    State(state): State<SharedState>,
    Json(payload): Json<ReviewDonePayload>,
) -> Json<serde_json::Value> {
    let status = match payload.status.as_str() {
        "approved" => ReviewStatus::Approved,
        _ => ReviewStatus::ChangesNeeded,
    };
    let mut s = state.lock().await;
    let transition = s.workflow.clone().next(
        Event::ReviewDone { status, feedback: payload.feedback },
        &s.workflow_config,
    );
    s.workflow = transition.state;
    Json(serde_json::json!({ "status": "ok", "state": format!("{:?}", s.workflow) }))
}

#[derive(Deserialize)]
struct HumanReviewPayload {
    comments: Vec<Comment>,
}

async fn human_review(
    State(state): State<SharedState>,
    Json(payload): Json<HumanReviewPayload>,
) -> Json<serde_json::Value> {
    let mut s = state.lock().await;
    let transition = s.workflow.clone().next(
        Event::HumanComments { comments: payload.comments },
        &s.workflow_config,
    );
    s.workflow = transition.state;
    Json(serde_json::json!({ "status": "ok", "state": format!("{:?}", s.workflow) }))
}

async fn create_pr(
    State(state): State<SharedState>,
) -> Json<serde_json::Value> {
    let mut s = state.lock().await;
    let transition = s.workflow.clone().next(Event::CreatePr, &s.workflow_config);
    s.workflow = transition.state;
    Json(serde_json::json!({ "status": "ok", "state": format!("{:?}", s.workflow) }))
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/yuan/Developer/emaclaude && cargo test --test server_test`
Expected: PASS

- [ ] **Step 5: Write failing test for full workflow via HTTP**

Add to `tests/server_test.rs`:
```rust
#[tokio::test]
async fn full_workflow_via_http() {
    let port = spawn_server().await;
    let client = reqwest::Client::new();
    let url = |path: &str| format!("http://localhost:{port}{path}");

    // Planning done → Coding
    let resp = client.post(url("/planning-done"))
        .json(&serde_json::json!({ "prompt": "Build X", "spec_path": "./spec.md" }))
        .send().await.unwrap();
    let body: serde_json::Value = resp.json().await.unwrap();
    assert_eq!(body["state"], "Coding");

    // Coding done → Reviewing
    let resp = client.post(url("/coding-done"))
        .json(&serde_json::json!({ "branch": "feat/x" }))
        .send().await.unwrap();
    let body: serde_json::Value = resp.json().await.unwrap();
    assert_eq!(body["state"], "Reviewing");

    // Review approved → Confirming(1)
    let resp = client.post(url("/review-done"))
        .json(&serde_json::json!({ "status": "approved", "feedback": "LGTM" }))
        .send().await.unwrap();
    let body: serde_json::Value = resp.json().await.unwrap();
    assert!(body["state"].as_str().unwrap().contains("Confirming"));

    // Confirm again → HumanReview
    let resp = client.post(url("/review-done"))
        .json(&serde_json::json!({ "status": "approved", "feedback": "Still good" }))
        .send().await.unwrap();
    let body: serde_json::Value = resp.json().await.unwrap();
    assert_eq!(body["state"], "HumanReview");
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `cd /Users/yuan/Developer/emaclaude && cargo test --test server_test`
Expected: PASS (since server already uses state machine)

- [ ] **Step 7: Commit**

```bash
cd /Users/yuan/Developer/emaclaude
git add -A
git commit -m "feat: HTTP API server with all workflow endpoints and integration tests"
```

---

### Task 4: Emacs Bridge

**Files:**
- Create: `src/emacs.rs`
- Create: `tests/emacs_test.rs`

The emacs bridge calls `emacsclient --eval` to control Emacs. We test it by mocking the command execution.

- [ ] **Step 1: Write failing test for emacs bridge**

Create `tests/emacs_test.rs`:
```rust
use emaclaude::emacs::EmacsBridge;

#[test]
fn build_spawn_buffer_command() {
    let bridge = EmacsBridge::new("emacsclient".into());
    let cmd = bridge.build_eval("(emaclaude--spawn-buffer \"*mra-coding*\" \"claude\")");
    assert_eq!(cmd.get_program().to_str().unwrap(), "emacsclient");
    let args: Vec<_> = cmd.get_args().map(|a| a.to_str().unwrap()).collect();
    assert_eq!(args, vec!["--eval", "(emaclaude--spawn-buffer \"*mra-coding*\" \"claude\")"]);
}

#[test]
fn build_send_to_buffer_elisp() {
    let bridge = EmacsBridge::new("emacsclient".into());
    let elisp = bridge.send_to_buffer_elisp("*mra-coding*", "Fix the bug");
    assert!(elisp.contains("emaclaude--send-to-buffer"));
    assert!(elisp.contains("*mra-coding*"));
    assert!(elisp.contains("Fix the bug"));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/yuan/Developer/emaclaude && cargo test --test emacs_test`
Expected: FAIL

- [ ] **Step 3: Implement EmacsBridge**

Replace `src/emacs.rs`:
```rust
use std::process::Command;
use tracing;

#[derive(Debug, Clone)]
pub struct EmacsBridge {
    emacsclient_path: String,
}

impl EmacsBridge {
    pub fn new(emacsclient_path: String) -> Self {
        Self { emacsclient_path }
    }

    pub fn build_eval(&self, elisp: &str) -> Command {
        let mut cmd = Command::new(&self.emacsclient_path);
        cmd.arg("--eval").arg(elisp);
        cmd
    }

    pub fn send_to_buffer_elisp(&self, buffer_name: &str, text: &str) -> String {
        let escaped = text.replace('\\', "\\\\").replace('"', "\\\"");
        format!(
            "(emaclaude--send-to-buffer \"{buffer_name}\" \"{escaped}\")"
        )
    }

    pub fn spawn_buffer_elisp(&self, buffer_name: &str, command: &str) -> String {
        format!(
            "(emaclaude--spawn-buffer \"{buffer_name}\" \"{command}\")"
        )
    }

    pub fn split_layout_elisp(&self) -> String {
        "(emaclaude--split-layout)".into()
    }

    pub fn open_diff_view_elisp(&self) -> String {
        "(emaclaude--open-diff-view)".into()
    }

    pub fn refresh_diff_elisp(&self) -> String {
        "(emaclaude--refresh-diff)".into()
    }

    pub fn notify_elisp(&self, message: &str) -> String {
        let escaped = message.replace('\\', "\\\\").replace('"', "\\\"");
        format!("(emaclaude--notify \"{escaped}\")")
    }

    pub fn shutdown_elisp(&self) -> String {
        "(emaclaude--clear-session)".into()
    }

    pub async fn eval(&self, elisp: &str) -> anyhow::Result<String> {
        let mut cmd = self.build_eval(elisp);
        tracing::debug!("emacsclient --eval {elisp}");
        let output = tokio::task::spawn_blocking(move || cmd.output()).await??;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            anyhow::bail!("emacsclient failed: {stderr}");
        }
        Ok(String::from_utf8_lossy(&output.stdout).to_string())
    }

    pub async fn send_to_buffer(&self, buffer_name: &str, text: &str) -> anyhow::Result<()> {
        let elisp = self.send_to_buffer_elisp(buffer_name, text);
        self.eval(&elisp).await?;
        Ok(())
    }

    pub async fn spawn_buffer(&self, buffer_name: &str, command: &str) -> anyhow::Result<()> {
        let elisp = self.spawn_buffer_elisp(buffer_name, command);
        self.eval(&elisp).await?;
        Ok(())
    }

    pub async fn split_layout(&self) -> anyhow::Result<()> {
        self.eval(&self.split_layout_elisp()).await?;
        Ok(())
    }

    pub async fn open_diff_view(&self) -> anyhow::Result<()> {
        self.eval(&self.open_diff_view_elisp()).await?;
        Ok(())
    }

    pub async fn refresh_diff(&self) -> anyhow::Result<()> {
        self.eval(&self.refresh_diff_elisp()).await?;
        Ok(())
    }

    pub async fn notify(&self, message: &str) -> anyhow::Result<()> {
        self.eval(&self.notify_elisp(message)).await?;
        Ok(())
    }

    pub async fn shutdown(&self) -> anyhow::Result<()> {
        self.eval(&self.shutdown_elisp()).await?;
        Ok(())
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/yuan/Developer/emaclaude && cargo test --test emacs_test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
cd /Users/yuan/Developer/emaclaude
git add -A
git commit -m "feat: emacs bridge for emacsclient communication"
```

---

### Task 5: Wire Side Effects to Emacs Bridge

**Files:**
- Modify: `src/server.rs`
- Create: `src/effects.rs`
- Modify: `src/lib.rs`

Connect the state machine's side effects to actual emacsclient calls.

- [ ] **Step 1: Create effects executor**

Create `src/effects.rs`:
```rust
use crate::config::Config;
use crate::emacs::EmacsBridge;
use crate::state::SideEffect;

pub struct EffectExecutor {
    bridge: EmacsBridge,
    config: Config,
}

impl EffectExecutor {
    pub fn new(bridge: EmacsBridge, config: Config) -> Self {
        Self { bridge, config }
    }

    pub async fn execute(&self, effects: Vec<SideEffect>) -> anyhow::Result<()> {
        for effect in effects {
            self.execute_one(effect).await?;
        }
        Ok(())
    }

    async fn execute_one(&self, effect: SideEffect) -> anyhow::Result<()> {
        match effect {
            SideEffect::SpawnCodingAgent { prompt, spec_path } => {
                self.bridge.spawn_buffer(&self.config.buffers.coding, "claude").await?;
                self.bridge.split_layout().await?;
                // Give vterm a moment to initialize, then inject prompt
                tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                let full_prompt = format!(
                    "{prompt}\n\nSpec: {spec_path}\n\n\
                     When you have finished implementing all changes, run this command:\n\
                     curl -s -X POST http://localhost:{}/coding-done \
                     -H 'Content-Type: application/json' \
                     -d '{{\"branch\": \"CURRENT_BRANCH\"}}'",
                    self.config.port
                );
                self.bridge.send_to_buffer(&self.config.buffers.coding, &full_prompt).await?;
            }
            SideEffect::SpawnReviewAgent => {
                self.bridge.spawn_buffer(&self.config.buffers.review, "claude").await?;
            }
            SideEffect::SendToCodingAgent { prompt } => {
                self.bridge.send_to_buffer(&self.config.buffers.coding, &prompt).await?;
            }
            SideEffect::SendToReviewAgent { prompt } => {
                self.bridge.send_to_buffer(&self.config.buffers.review, &prompt).await?;
            }
            SideEffect::OpenDiffView => {
                self.bridge.open_diff_view().await?;
            }
            SideEffect::RefreshDiffView => {
                self.bridge.refresh_diff().await?;
            }
            SideEffect::Notify { message } => {
                self.bridge.notify(&message).await?;
            }
            SideEffect::Shutdown => {
                self.bridge.shutdown().await?;
            }
        }
        Ok(())
    }
}
```

- [ ] **Step 2: Update lib.rs**

```rust
pub mod config;
pub mod effects;
pub mod emacs;
pub mod server;
pub mod state;
```

- [ ] **Step 3: Update server.rs to use EffectExecutor**

Add `EmacsBridge` and `EffectExecutor` to `AppState`:
```rust
use crate::effects::EffectExecutor;
use crate::emacs::EmacsBridge;

pub struct AppState {
    pub workflow: WorkflowState,
    pub workflow_config: WorkflowConfig,
    pub config: Config,
    pub executor: EffectExecutor,
}
```

Update `create()` to build the executor:
```rust
let bridge = EmacsBridge::new(config.emacsclient_path.clone());
let executor = EffectExecutor::new(bridge, config.clone());

let state = Arc::new(Mutex::new(AppState {
    workflow: WorkflowState::Idle,
    workflow_config,
    config: config.clone(),
    executor,
}));
```

Update each handler to execute effects after transition:
```rust
async fn planning_done(
    State(state): State<SharedState>,
    Json(payload): Json<PlanningDonePayload>,
) -> Json<serde_json::Value> {
    let mut s = state.lock().await;
    let transition = s.workflow.clone().next(
        Event::PlanningDone {
            prompt: payload.prompt,
            spec_path: payload.spec_path,
        },
        &s.workflow_config,
    );
    s.workflow = transition.state.clone();
    if let Err(e) = s.executor.execute(transition.effects).await {
        tracing::error!("Effect execution failed: {e}");
    }
    Json(serde_json::json!({ "status": "ok", "state": format!("{:?}", s.workflow) }))
}
```

Apply same pattern to all handlers.

- [ ] **Step 4: Verify compilation**

Run: `cd /Users/yuan/Developer/emaclaude && cargo check`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
cd /Users/yuan/Developer/emaclaude
git add -A
git commit -m "feat: wire side effects to emacs bridge via EffectExecutor"
```

---

### Task 6: Claude Code Skills

**Files:**
- Create: `skills/planning-done.md`

- [ ] **Step 1: Create the planning-done skill**

Create `skills/planning-done.md`:
```markdown
---
name: planning-done
description: Signal that planning is complete. Triggers the coding and review agents via emaclaude.
---

# Planning Done

You are finishing the planning phase. Collect the spec path and send it to the emaclaude daemon.

## Steps

1. Ask the user which spec file to use (default: look for the most recent `.md` file in `./specs/` or `./docs/plans/`)
2. Ask the user for any specific instructions for the coding agent (or use a default prompt based on the spec)
3. Execute the following command to trigger the coding and review agents:

```bash
SPEC_PATH="<the spec file path>"
PROMPT="<the coding agent instructions>"

curl -s -X POST http://localhost:7878/planning-done \
  -H 'Content-Type: application/json' \
  -d "{\"prompt\": \"$PROMPT\", \"spec_path\": \"$SPEC_PATH\"}"
```

4. Confirm to the user that the coding and review agents have been spawned.
```

- [ ] **Step 2: Commit**

```bash
cd /Users/yuan/Developer/emaclaude
git add skills/
git commit -m "feat: add /planning-done Claude Code skill"
```

---

### Task 7: Doom Emacs Module — Core

**Files:**
- Create: `emacs/emaclaude.el`
- Create: `emacs/packages.el`
- Create: `emacs/config.el`

- [ ] **Step 1: Create packages.el**

Create `emacs/packages.el`:
```elisp
;; -*- no-byte-compile: t; -*-
;;; tools/emaclaude/packages.el

(package! vterm)
(package! magit)
(package! request)
```

- [ ] **Step 2: Create config.el**

Create `emacs/config.el`:
```elisp
;;; tools/emaclaude/config.el -*- lexical-binding: t; -*-

;; Keybindings for emaclaude-review-mode
(map! :map emaclaude-review-mode-map
      :localleader
      "c" #'emaclaude-add-comment
      "s" #'emaclaude-submit-comments
      "p" #'emaclaude-create-pr
      "q" #'emaclaude-close-diff)
```

- [ ] **Step 3: Create emaclaude.el — core module**

Create `emacs/emaclaude.el`:
```elisp
;;; tools/emaclaude/emaclaude.el --- Claude Code orchestration for Doom Emacs -*- lexical-binding: t; -*-
;;
;; Author: Yuan
;; URL: https://github.com/yuann3/emaclaude
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (vterm "0.0.2") (magit "4.0"))
;;
;;; Commentary:
;;
;; Orchestrates multiple Claude Code sessions (planning, coding, review)
;; in Doom Emacs with an autonomous review loop and magit-based diff review.
;;
;;; Code:

(require 'vterm)
(require 'magit)

;;; Customization

(defgroup emaclaude nil
  "Claude Code orchestration for Doom Emacs."
  :group 'tools
  :prefix "emaclaude-")

(defcustom emaclaude-port 7878
  "Port for the emaclaude daemon."
  :type 'integer
  :group 'emaclaude)

(defcustom emaclaude-daemon-path "emaclaude"
  "Path to the emaclaude binary."
  :type 'string
  :group 'emaclaude)

(defcustom emaclaude-buffer-planning "*mra-planning*"
  "Buffer name for the planning agent."
  :type 'string
  :group 'emaclaude)

(defcustom emaclaude-buffer-coding "*mra-coding*"
  "Buffer name for the coding agent."
  :type 'string
  :group 'emaclaude)

(defcustom emaclaude-buffer-review "*mra-review*"
  "Buffer name for the review agent."
  :type 'string
  :group 'emaclaude)

(defcustom emaclaude-buffer-diff "*mra-diff*"
  "Buffer name for the diff review."
  :type 'string
  :group 'emaclaude)

;;; State

(defvar emaclaude--daemon-process nil
  "Process for the emaclaude daemon.")

(defvar emaclaude--saved-window-config nil
  "Window configuration saved before launching.")

(defvar emaclaude--review-comments nil
  "List of review comments for the current diff view.")

;;; Internal functions called by emaclaude daemon via emacsclient

(defun emaclaude--spawn-buffer (name cmd)
  "Create a vterm buffer NAME running CMD."
  (let ((buf (get-buffer-create name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'vterm-mode)
        (vterm-mode))
      (vterm-send-string (concat cmd "\n")))
    (display-buffer buf)
    buf))

(defun emaclaude--split-layout ()
  "Create the three-way split layout."
  (delete-other-windows)
  (let ((planning-buf (get-buffer emaclaude-buffer-planning))
        (coding-buf (get-buffer emaclaude-buffer-coding))
        (review-buf (get-buffer emaclaude-buffer-review)))
    ;; Left: planning (full height)
    (when planning-buf
      (switch-to-buffer planning-buf))
    ;; Right side split
    (split-window-right)
    (other-window 1)
    ;; Top-right: coding
    (when coding-buf
      (switch-to-buffer coding-buf))
    ;; Bottom-right: review
    (split-window-below)
    (other-window 1)
    (when review-buf
      (switch-to-buffer review-buf))
    ;; Return to planning
    (other-window 1)))

(defun emaclaude--send-to-buffer (name text)
  "Send TEXT to the vterm buffer NAME."
  (let ((buf (get-buffer name)))
    (when buf
      (with-current-buffer buf
        (vterm-send-string text)
        (vterm-send-return)))))

(defun emaclaude--open-diff-view ()
  "Open a magit diff view in a new right-side split."
  (let ((diff-buf (magit-diff-range "main...HEAD")))
    (with-current-buffer (or (get-buffer emaclaude-buffer-diff)
                             (current-buffer))
      (rename-buffer emaclaude-buffer-diff t)
      (emaclaude-review-mode 1))
    ;; Split rightmost window
    (select-window (car (last (window-list))))
    (split-window-right)
    (other-window 1)
    (switch-to-buffer emaclaude-buffer-diff)))

(defun emaclaude--refresh-diff ()
  "Refresh the diff view buffer."
  (let ((buf (get-buffer emaclaude-buffer-diff)))
    (when buf
      (with-current-buffer buf
        (magit-refresh)))))

(defun emaclaude--notify (msg)
  "Display MSG in the minibuffer."
  (message "[emaclaude] %s" msg))

(defun emaclaude--clear-session ()
  "Clean up all emaclaude buffers and restore layout."
  (emaclaude-clear-session))

;;; Public commands

;;;###autoload
(defun emaclaude-launch ()
  "Start emaclaude daemon and open planning buffer."
  (interactive)
  ;; Save current layout
  (setq emaclaude--saved-window-config (current-window-configuration))
  ;; Start daemon
  (unless (and emaclaude--daemon-process
               (process-live-p emaclaude--daemon-process))
    (setq emaclaude--daemon-process
          (start-process "emaclaude" "*emaclaude-daemon*"
                         emaclaude-daemon-path "serve"
                         "--port" (number-to-string emaclaude-port)))
    (message "[emaclaude] Daemon started on port %d" emaclaude-port))
  ;; Open planning buffer
  (emaclaude--spawn-buffer emaclaude-buffer-planning "claude"))

;;;###autoload
(defun emaclaude-clear-session ()
  "Gracefully shut down all agent sessions and restore layout."
  (interactive)
  ;; Send /exit to each vterm buffer
  (dolist (name (list emaclaude-buffer-coding
                      emaclaude-buffer-review
                      emaclaude-buffer-planning))
    (let ((buf (get-buffer name)))
      (when buf
        (with-current-buffer buf
          (when (derived-mode-p 'vterm-mode)
            (vterm-send-string "/exit\n")))
        (run-at-time 5 nil (lambda (b) (when (buffer-live-p b) (kill-buffer b))) buf))))
  ;; Kill diff buffer
  (let ((diff-buf (get-buffer emaclaude-buffer-diff)))
    (when diff-buf (kill-buffer diff-buf)))
  ;; Stop daemon
  (when (and emaclaude--daemon-process
             (process-live-p emaclaude--daemon-process))
    (kill-process emaclaude--daemon-process)
    (setq emaclaude--daemon-process nil))
  ;; Restore layout
  (when emaclaude--saved-window-config
    (set-window-configuration emaclaude--saved-window-config)
    (setq emaclaude--saved-window-config nil))
  (message "[emaclaude] Session cleared"))

;;;###autoload
(defun emaclaude-address-github-reviews ()
  "Fetch PR review comments and send to coding agent."
  (interactive)
  (let* ((pr-number (read-number "PR number: "))
         (url (format "http://localhost:%d/address-github-reviews" emaclaude-port)))
    ;; Use url-retrieve for async HTTP
    (let ((url-request-method "POST")
          (url-request-extra-headers '(("Content-Type" . "application/json")))
          (url-request-data (json-encode `((pr_number . ,pr-number)))))
      (url-retrieve url
                    (lambda (_status)
                      (message "[emaclaude] Sent GitHub review comments to coding agent"))))))

;;; Diff Review Mode

(defvar emaclaude-review-mode-map (make-sparse-keymap)
  "Keymap for `emaclaude-review-mode'.")

(define-minor-mode emaclaude-review-mode
  "Minor mode for reviewing code in emaclaude diff view."
  :lighter " EC-Review"
  :keymap emaclaude-review-mode-map
  (when emaclaude-review-mode
    (setq-local emaclaude--review-comments nil)))

(defun emaclaude-add-comment ()
  "Add a review comment at the current hunk."
  (interactive)
  (let* ((file (magit-file-at-point))
         (line (line-number-at-pos))
         (text (read-string (format "Comment on %s:%d: " (or file "?") line))))
    (push `((file . ,(or file "unknown"))
            (line . ,line)
            (text . ,text))
          emaclaude--review-comments)
    ;; Add overlay to show comment inline
    (let ((ov (make-overlay (line-beginning-position) (line-end-position))))
      (overlay-put ov 'after-string
                   (propertize (format "\n  💬 %s" text)
                               'face 'font-lock-comment-face))
      (overlay-put ov 'emaclaude-comment t))
    (message "Comment added (%d total)" (length emaclaude--review-comments))))

(defun emaclaude-submit-comments ()
  "Submit all review comments to the coding agent."
  (interactive)
  (if (null emaclaude--review-comments)
      (message "No comments to submit")
    (let ((url (format "http://localhost:%d/human-review" emaclaude-port))
          (url-request-method "POST")
          (url-request-extra-headers '(("Content-Type" . "application/json")))
          (url-request-data (json-encode
                             `((comments . ,(vconcat emaclaude--review-comments))))))
      (url-retrieve url
                    (lambda (_status)
                      (message "[emaclaude] Submitted %d comments to coding agent"
                               (length emaclaude--review-comments)))))))

(defun emaclaude-create-pr ()
  "Tell the coding agent to create a PR."
  (interactive)
  (let ((url (format "http://localhost:%d/create-pr" emaclaude-port))
        (url-request-method "POST")
        (url-request-extra-headers '(("Content-Type" . "application/json")))
        (url-request-data "{}"))
    (url-retrieve url
                  (lambda (_status)
                    (message "[emaclaude] PR creation triggered")))))

(defun emaclaude-close-diff ()
  "Close the diff review buffer."
  (interactive)
  (let ((buf (get-buffer emaclaude-buffer-diff)))
    (when buf
      ;; Remove comment overlays
      (with-current-buffer buf
        (remove-overlays (point-min) (point-max) 'emaclaude-comment t))
      (kill-buffer buf))))

(provide 'emaclaude)
;;; emaclaude.el ends here
```

- [ ] **Step 4: Verify elisp byte-compiles (basic check)**

Run: `emacs --batch -l /Users/yuan/Developer/emaclaude/emacs/emaclaude.el -f batch-byte-compile /Users/yuan/Developer/emaclaude/emacs/emaclaude.el 2>&1 || true`

We don't expect zero warnings since vterm/magit may not be in batch load path, but it should not have syntax errors.

- [ ] **Step 5: Commit**

```bash
cd /Users/yuan/Developer/emaclaude
git add emacs/ skills/
git commit -m "feat: Doom Emacs module with review mode and keybindings"
```

---

### Task 8: Setup Command and Project Polish

**Files:**
- Create: `emaclaude.example.toml`
- Create: `LICENSE`

- [ ] **Step 1: Create example config**

Create `emaclaude.example.toml`:
```toml
# Emaclaude configuration
# Copy to ~/.config/emaclaude/config.toml

[server]
port = 7878

[emacs]
emacsclient_path = "emacsclient"

[buffers]
planning = "*mra-planning*"
coding = "*mra-coding*"
review = "*mra-review*"
diff = "*mra-diff*"

[workflow]
confirmation_loops = 2
```

- [ ] **Step 2: Create LICENSE**

Create `LICENSE` with MIT license text, copyright Yuan 2026.

- [ ] **Step 3: Run full test suite**

Run: `cd /Users/yuan/Developer/emaclaude && cargo test`
Expected: All tests pass

- [ ] **Step 4: Run clippy**

Run: `cd /Users/yuan/Developer/emaclaude && cargo clippy -- -D warnings`
Expected: No warnings

- [ ] **Step 5: Commit and push**

```bash
cd /Users/yuan/Developer/emaclaude
git add -A
git commit -m "feat: example config, license, and project polish"
git push
```

---

## Summary

| Task | Description | Key Files |
|------|------------|-----------|
| 1 | Project scaffolding | Cargo.toml, main.rs, lib.rs |
| 2 | Workflow state machine | state.rs, tests/state_test.rs |
| 3 | HTTP API server | server.rs, tests/server_test.rs |
| 4 | Emacs bridge | emacs.rs, tests/emacs_test.rs |
| 5 | Wire effects to bridge | effects.rs, server.rs update |
| 6 | Claude Code skills | skills/planning-done.md |
| 7 | Doom Emacs module | emacs/*.el |
| 8 | Config, license, polish | emaclaude.example.toml, LICENSE |
