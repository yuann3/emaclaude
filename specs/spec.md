# Emaclaude — Technical Specification

## Overview

Emaclaude is a Claude Code + Doom Emacs orchestration tool that enables a multi-session development workflow: planning, coding, and code review — all running as independent Claude Code sessions in Emacs vterm buffers, coordinated by a lightweight Rust daemon backed by the MRA framework.

## Core Concept

Three Claude Code sessions run simultaneously in Emacs split buffers:

1. **Planning Agent** — human-driven brainstorming, spec writing, PRD creation
2. **Coding Agent** — autonomous implementation based on specs
3. **Review Agent** — autonomous code review with security, quality, and redundancy checks

The coding and review agents form an autonomous loop. A Rust daemon (emaclaude) orchestrates the lifecycle, message routing, and state transitions. Emacs owns all processes and visual layout.

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                        Doom Emacs                            │
│  ┌──────────────┬──────────────┬──────────────┐              │
│  │              │   *mra-      │              │              │
│  │              │   coding*    │   *mra-diff* │              │
│  │  *mra-       ├──────────────┤   (appears   │              │
│  │  planning*   │   *mra-      │    later)    │              │
│  │              │   review*    │              │              │
│  │              │              │              │              │
│  └──────────────┴──────────────┴──────────────┘              │
│                                                              │
│  Emacs owns all PTYs via vterm                               │
│  emacsclient --eval for all external control                 │
└──────────────────────────────────────────────────────────────┘
        ▲                    ▲
        │ vterm-send-string  │ spawn/split buffers
        │                    │
┌───────┴────────────────────┴─────────────────────────────────┐
│                    Emaclaude Daemon                           │
│                                                              │
│  ┌─────────────┐  ┌──────────────┐  ┌─────────────────────┐ │
│  │  HTTP API   │  │    State     │  │   Emacs Bridge      │ │
│  │  (axum)     │──│   Machine    │──│  (emacsclient)      │ │
│  └─────────────┘  └──────────────┘  └─────────────────────┘ │
│                          │                                   │
│                   ┌──────┴──────┐                            │
│                   │ MRA Library │                            │
│                   │ (supervisor)│                            │
│                   └─────────────┘                            │
└──────────────────────────────────────────────────────────────┘
        ▲
        │ curl (from Claude Code skills)
        │
┌───────┴──────────────────────────────────────────────────────┐
│              Claude Code Skills                              │
│  /planning-done  /coding-done  /review-done                  │
└──────────────────────────────────────────────────────────────┘
```

## Components

### 1. Emaclaude Daemon (Rust binary)

A lightweight process that coordinates the workflow. It does NOT make any LLM calls — all AI work happens inside Claude Code sessions.

**Depends on:**
- `axum` — HTTP server
- `tokio` — async runtime
- `serde`/`serde_json` — payload serialization

#### 1.1 HTTP API

| Endpoint | Method | Called By | Payload | Action |
|----------|--------|-----------|---------|--------|
| `/planning-done` | POST | Planning skill | `{ prompt: String, spec_path: String }` | Spawn coding + review buffers, inject initial prompt |
| `/coding-done` | POST | Coding agent | `{ branch: String }` | Inject review prompt into review agent |
| `/review-done` | POST | Review agent | `{ status: "approved" \| "changes_needed", feedback: String }` | Route feedback or advance approval counter |
| `/human-review` | POST | Emacs diff view | `{ comments: [{ file, line, text }] }` | Format and inject comments into coding agent |
| `/health` | GET | Emacs/debugging | — | Return daemon status and current state |

#### 1.2 Workflow State Machine

```
IDLE
  │
  ├─ POST /planning-done
  ▼
CODING
  │
  ├─ POST /coding-done
  ▼
REVIEWING
  │
  ├─ status: "changes_needed" ──► CODING (reset approval_count to 0)
  │
  ├─ status: "approved" ──► CONFIRMING(approval_count + 1)
  ▼
CONFIRMING(n)
  │
  ├─ n < 2 ──► re-run review agent (skip coding agent)
  │
  ├─ n == 2 ──► HUMAN_REVIEW (open diff view)
  │
  ├─ found issues ──► CODING (reset approval_count to 0)
  ▼
HUMAN_REVIEW
  │
  ├─ POST /human-review ──► CODING (then back to HUMAN_REVIEW, no review loop)
  │
  ├─ SPC m p (create PR) ──► PR_CREATED
  ▼
PR_CREATED
  │
  ├─ M-x mra-address-github-reviews ──► CODING (address comments, push, back to PR_CREATED)
  │
  ├─ M-x mra-clear-session ──► IDLE
  ▼
IDLE
```

**Key rules:**
- No hard cap on review loop iterations
- Confirmation loops re-run the review agent only (coding agent is skipped)
- Approval counter resets to 0 if any confirmation loop finds issues
- Human-initiated fixes (from diff view comments) skip the automated review loop
- GitHub review fixes also skip the automated review loop

#### 1.3 Emacs Bridge

All communication with Emacs goes through `emacsclient --eval`. The daemon never directly touches PTY file descriptors.

**Functions the bridge calls:**

| elisp function | Purpose |
|---------------|---------|
| `(emaclaude--spawn-buffer NAME CMD)` | Create vterm buffer with given name and command |
| `(emaclaude--split-layout)` | Create three-way split layout |
| `(emaclaude--send-to-buffer NAME TEXT)` | Inject text into a named vterm buffer via `vterm-send-string` |
| `(emaclaude--open-diff-view BRANCH)` | Open magit diff view on the right |
| `(emaclaude--refresh-diff)` | Refresh the diff view after new changes |
| `(emaclaude--notify MSG)` | Show message in minibuffer |
| `(emaclaude--show-pr-link URL)` | Display PR URL in diff view buffer |

#### 1.4 Process Management

No active process monitoring. Claude Code is stable production software — crash recovery is unnecessary overhead. If Emacs or a session dies, the user restarts manually via `M-x emaclaude-launch`. Graceful shutdown is handled by `M-x emaclaude-clear-session` which sends `/exit` to each vterm buffer.

### 2. Doom Emacs Module

Located in `emacs/` directory. Installed as a Doom module at `~/.doom.d/modules/tools/emaclaude/`.

#### 2.1 M-x Commands

| Command | Description |
|---------|-------------|
| `M-x emaclaude-launch` | Start emaclaude daemon + open `*mra-planning*` vterm buffer with `claude` |
| `M-x emaclaude-address-github-reviews` | Fetch PR review comments via `gh api`, send to coding agent |
| `M-x emaclaude-clear-session` | Graceful shutdown of all agent sessions, kill buffers, restore previous window layout via `winner-mode` |

#### 2.2 Keybindings (in diff review mode)

| Key | Command | Description |
|-----|---------|-------------|
| `SPC m c` | `emaclaude-add-comment` | Add inline comment on current hunk |
| `SPC m s` | `emaclaude-submit-comments` | Submit all comments to coding agent via MRA |
| `SPC m p` | `emaclaude-create-pr` | Send PR creation prompt to coding agent |
| `SPC m q` | `emaclaude-close-diff` | Close diff view buffer |

#### 2.3 Diff Review Mode

Built on top of `magit-diff-mode`:
- `emaclaude-review-mode` — minor mode activated in the diff buffer
- Inline comment rendering (similar to GitHub's review interface)
- Comments stored as buffer-local overlay data until submitted
- Auto-refresh when coding agent signals completion (emaclaude daemon calls `emaclaude--refresh-diff`)

#### 2.4 Buffer Layout

Three-way split created when `/planning-done` triggers:

```
┌──────────────┬──────────────┐
│              │   *mra-      │
│              │   coding*    │
│  *mra-       ├──────────────┤
│  planning*   │   *mra-      │
│              │   review*    │
│              │              │
└──────────────┴──────────────┘
```

When entering HUMAN_REVIEW state, a fourth column appears:

```
┌──────────────┬──────────────┬──────────────┐
│              │   *mra-      │              │
│              │   coding*    │              │
│  *mra-       ├──────────────┤   *mra-diff* │
│  planning*   │   *mra-      │              │
│              │   review*    │              │
│              │              │              │
└──────────────┴──────────────┴──────────────┘
```

### 3. Claude Code Skills

Installed to `~/.claude/skills/emaclaude/` via symlink.

#### 3.1 `/planning-done`

Triggered manually by the user in the planning session. Collects the spec path and a prompt, then curls emaclaude's HTTP API.

```
User runs /planning-done in planning buffer
  → Skill executes: curl -X POST localhost:PORT/planning-done \
      -d '{"prompt": "...", "spec_path": "./specs/plan.md"}'
  → Emaclaude spawns coding + review buffers
  → Emaclaude injects initial prompt into coding agent
```

The skill includes the full coding agent prompt — instructions on what to implement, where the spec is, and the instruction to curl `/coding-done` when finished.

#### 3.2 `/coding-done`

Not a user-facing skill. The instruction to call this endpoint is baked into the coding agent's initial prompt:

```
"When you have finished implementing all changes, run this command:
curl -s -X POST localhost:PORT/coding-done -H 'Content-Type: application/json' -d '{\"branch\": \"CURRENT_BRANCH\"}'"
```

#### 3.3 `/review-done`

Not a user-facing skill. Baked into the review agent's prompt:

```
"When your review is complete, run this command:
curl -s -X POST localhost:PORT/review-done -H 'Content-Type: application/json' -d '{\"status\": \"approved|changes_needed\", \"feedback\": \"YOUR_FEEDBACK\"}'"
```

## Communication Flow

```
[You] ──type──► [Planning Agent] ──/planning-done──► [Emaclaude HTTP]
                                                          │
                                          emacsclient: spawn buffers
                                          emacsclient: vterm-send-string
                                                          │
                                                          ▼
                                                   [Coding Agent]
                                                          │
                                                   curl /coding-done
                                                          │
                                                          ▼
                                                   [Emaclaude HTTP]
                                                          │
                                          emacsclient: vterm-send-string
                                                          │
                                                          ▼
                                                   [Review Agent]
                                                          │
                                                   curl /review-done
                                                          │
                                                          ▼
                                                   [Emaclaude HTTP]
                                                     │         │
                                          feedback ──┘         └── approved (x2)
                                             │                        │
                                             ▼                        ▼
                                      [Coding Agent]          [Diff View opens]
                                      (loop continues)              │
                                                              [You comment]
                                                                    │
                                                              SPC m s submit
                                                                    │
                                                                    ▼
                                                             [Emaclaude HTTP]
                                                                    │
                                                        vterm-send-string
                                                                    │
                                                                    ▼
                                                             [Coding Agent]
                                                             (fixes, done)
                                                                    │
                                                             diff refreshes
                                                                    │
                                                             SPC m p ──► PR
```

## Configuration

`~/.config/emaclaude/config.toml`:

```toml
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

[github]
# Uses gh CLI, no additional config needed
```

## Installation

```bash
# Clone
git clone https://github.com/yuann3/emaclaude.git
cd emaclaude

# Build and install binary
cargo install --path .

# Setup: symlink skills + install Doom module
emaclaude setup

# Add to Doom config (~/.doom.d/init.el)
# (emaclaude +doom)    ; under :tools

# Sync Doom
doom sync
```

### Requirements

- Rust toolchain (1.91+)
- Claude Code CLI
- Doom Emacs with:
  - `vterm` module enabled
  - `magit` module enabled
- `gh` CLI (for GitHub integration)

## Project Structure

```
emaclaude/
├── Cargo.toml
├── src/
│   ├── main.rs             # CLI entry: `emaclaude serve`, `emaclaude setup`
│   ├── lib.rs              # Module exports
│   ├── server.rs           # Axum HTTP API
│   ├── state.rs            # Workflow state machine
│   ├── emacs.rs            # Emacs bridge (emacsclient calls)
│   ├── effects.rs          # Side effect executor
│   └── config.rs           # Configuration loading
├── emacs/
│   ├── emaclaude.el        # Main Doom module (includes review mode)
│   ├── packages.el         # Doom package declarations
│   └── config.el           # Doom module config
└── skills/
    └── planning-done.md    # /planning-done skill
```
