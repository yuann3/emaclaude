# Emaclaude — Product Requirements Document

## Problem Statement

Building production software with AI coding assistants today is fragmented. Developers switch between terminals, editors, and web interfaces. Planning, implementation, and review happen in disconnected tools with no automated handoff between phases. There is no integrated workflow that lets a developer plan in one session, have AI implement autonomously, get automated review with iterative fixing, and then do a final human review — all within their editor.

## Solution

Emaclaude is a Doom Emacs-native development workflow that orchestrates multiple Claude Code sessions for planning, coding, and review. A lightweight Rust daemon coordinates the sessions while Emacs provides full visibility and control through vterm buffers and a magit-based review interface.

## Users

- Developers who use Doom Emacs as their primary editor
- Developers who use Claude Code for AI-assisted development
- Teams building production software who want structured AI-assisted workflows

## Workflow

### Phase 1: Planning
The developer opens a Claude Code session in Emacs and plans — brainstorming, writing specs, creating PRDs. This is fully human-driven. The output is a spec document.

### Phase 2: Autonomous Implementation
The developer triggers `/planning-done`. The system automatically:
- Opens a coding agent buffer (Claude Code session)
- Opens a review agent buffer (Claude Code session)
- Sends the spec to the coding agent
- The coding agent implements the spec

### Phase 3: Autonomous Review Loop
When the coding agent finishes:
- The review agent reviews the git diff (code quality, security, redundancy)
- If issues found: feedback goes back to the coding agent for fixes
- If approved: the review agent re-reviews 2 more times to confirm (no coding agent involvement in confirmation loops)
- The loop runs until 2 consecutive approvals with no hard iteration cap

### Phase 4: Human Review
When the automated loop completes:
- A magit-based diff view opens in Emacs
- The developer reviews code, adds inline comments
- Comments are sent to the coding agent for fixing
- The diff view auto-refreshes after fixes
- No automated review loop runs on human-requested fixes

### Phase 5: PR Creation
The developer triggers PR creation from the diff view. The coding agent commits and creates a PR with an auto-generated description based on the spec.

### Phase 6: GitHub Review Integration
After receiving GitHub PR review comments, the developer triggers a command. The coding agent fetches the comments, addresses each one, replies on GitHub, resolves conversations, and pushes.

### Phase 7: Cleanup
The developer clears the session. All agent buffers close, the daemon shuts down, and Emacs restores the previous window layout.

## Requirements

### R1: Emaclaude Daemon

| ID | Requirement | Priority |
|----|-------------|----------|
| R1.1 | HTTP API server accepting workflow signals from Claude Code skills | Must |
| R1.2 | Workflow state machine managing transitions between phases | Must |
| R1.3 | Emacs bridge via `emacsclient --eval` for buffer and layout management | Must |
| R1.4 | Process supervision via MRA library (restart crashed sessions) | Must |
| R1.5 | Reconnect to existing buffers on daemon restart | Should |
| R1.6 | Configurable server port and buffer names | Should |
| R1.7 | Health check endpoint for debugging | Should |

### R2: Doom Emacs Module

| ID | Requirement | Priority |
|----|-------------|----------|
| R2.1 | `M-x emaclaude-launch` — start daemon + planning buffer | Must |
| R2.2 | `M-x emaclaude-clear-session` — graceful shutdown, restore layout | Must |
| R2.3 | `M-x emaclaude-address-github-reviews` — fetch and address PR comments | Must |
| R2.4 | Three-way vterm split layout (planning, coding, review) | Must |
| R2.5 | Fourth column for magit diff view when entering human review | Must |
| R2.6 | Window layout restoration via `winner-mode` on clear | Must |
| R2.7 | All agent buffers use vterm for full PTY support | Must |

### R3: Diff Review Interface

| ID | Requirement | Priority |
|----|-------------|----------|
| R3.1 | Magit-diff based review buffer with inline commenting | Must |
| R3.2 | `SPC m c` to add comment on hunk | Must |
| R3.3 | `SPC m s` to submit all comments to coding agent | Must |
| R3.4 | `SPC m p` to trigger PR creation | Must |
| R3.5 | `SPC m q` to close diff view | Must |
| R3.6 | Diff view persists until manually closed | Must |
| R3.7 | Auto-refresh diff view when coding agent finishes fixes | Must |
| R3.8 | Display PR link after PR creation | Should |

### R4: Claude Code Skills

| ID | Requirement | Priority |
|----|-------------|----------|
| R4.1 | `/planning-done` skill — user-triggered, sends spec to daemon | Must |
| R4.2 | Coding agent prompt includes curl to `/coding-done` on completion | Must |
| R4.3 | Review agent prompt includes curl to `/review-done` with status/feedback | Must |
| R4.4 | Review agent prompt covers: code quality, security, redundancy, spec adherence | Must |

### R5: Review Loop

| ID | Requirement | Priority |
|----|-------------|----------|
| R5.1 | Autonomous coding ↔ review loop with no human intervention | Must |
| R5.2 | 2 consecutive approvals required before human review (confirmation loops) | Must |
| R5.3 | Confirmation loops re-run review agent only (skip coding agent) | Must |
| R5.4 | Approval counter resets if confirmation loop finds new issues | Must |
| R5.5 | No hard cap on iterations | Must |
| R5.6 | Human-initiated fixes skip the automated review loop | Must |

### R6: GitHub Integration

| ID | Requirement | Priority |
|----|-------------|----------|
| R6.1 | Fetch PR review comments via `gh api` | Must |
| R6.2 | Coding agent addresses each comment, replies, and resolves | Must |
| R6.3 | Auto-push after addressing comments | Must |
| R6.4 | Do not auto-re-request review | Must |

### R7: Installation

| ID | Requirement | Priority |
|----|-------------|----------|
| R7.1 | `cargo install --path .` for the binary | Must |
| R7.2 | `emaclaude setup` symlinks skills to `~/.claude/skills/emaclaude/` | Must |
| R7.3 | `emaclaude setup` installs Doom module to `~/.doom.d/modules/tools/emaclaude/` | Must |
| R7.4 | Works on macOS (primary target) | Must |
| R7.5 | Works on Linux | Should |
| R7.6 | Open source (MIT or Apache 2.0) | Must |

## Non-Requirements (Explicit Exclusions)

- **No budget tracking** — Claude Code handles its own token limits
- **No LLM calls from emaclaude** — all AI work happens in Claude Code sessions
- **No prompt generation from emaclaude** — prompts live in skills
- **No vanilla Emacs / Spacemacs support in v1** — Doom-only
- **No Windows support in v1**
- **No streaming or partial results** — each phase completes fully before the next begins

## Dependencies

| Dependency | Purpose |
|-----------|---------|
| MRA framework | Supervisor tree for process lifecycle management |
| Axum | HTTP server for the daemon |
| Tokio | Async runtime |
| Claude Code CLI | All AI agent sessions |
| Doom Emacs | Editor environment |
| vterm | Terminal emulation in Emacs |
| magit | Git interface and diff rendering in Emacs |
| `gh` CLI | GitHub PR and review comment integration |

## Success Criteria

1. A developer can go from spec to PR without leaving Emacs
2. The coding ↔ review loop runs autonomously without human intervention
3. The human review interface (diff view with inline comments) is as usable as GitHub's review UI
4. GitHub review comments can be addressed from Emacs with a single command
5. Session cleanup fully restores the previous Emacs state
6. Other developers can install and use emaclaude via the documented setup process

## Open Questions

1. Should the Doom module be distributed via MELPA in the future, or always installed from the repo?
2. Should emaclaude support multiple concurrent workflow sessions (e.g., working on two features in two different frames)?
3. Should there be a dashboard or status buffer showing the current workflow state and loop count?
