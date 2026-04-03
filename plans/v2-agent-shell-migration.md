# Plan: Emaclaude v2 — Agent Shell Migration

> Source PRD: GitHub Issue #1 — "PRD: Migrate emaclaude from vterm to agent-shell (ACP)"

## Architectural decisions

Durable decisions that apply across all phases:

- **Communication protocol**: ACP (Agent Client Protocol) via agent-shell — JSON-over-stdio, no TUI rendering
- **State machine interface**: Stateless Rust CLI — `echo '{"state":..., "event":..., "config":...}' | emaclaude transition` returns `{"state":..., "effects":[...]}`
- **Signaling**: `bin/emaclaude-signal <event> [json]` → `emacsclient --eval (emaclaude--handle-event ...)`
- **State ownership**: Elisp global variable `emaclaude--workflow-state`, serialized as JSON
- **Effect dispatch**: Parameterized effects from Rust, elisp dispatch table executes blindly
- **Buffer names**: `*mra-planning*`, `*mra-coding*`, `*mra-review*`, `*mra-diff*`
- **Diff base**: Always `main` (not upstream), worktree-aware via `default-directory`
- **Logging path**: `~/.emaclaude/logs/YYYY-MM-DD.jsonl`
- **Rust dependencies**: `serde`, `serde_json`, `clap` (everything else removed)
- **Elisp dependencies**: `agent-shell`, `magit` (vterm removed)
- **Skills**: `planning-done` (rewrite), `coding-done` (new), `review-done` (new) — all use `emaclaude-signal`

---

## Phase 1: Single agent-shell session

**User stories**: 2, 21

### What to build

A minimal `emaclaude-launch` command that spawns a single agent-shell buffer named `*mra-planning*` with ACP. The user selects an LLM backend at launch (from agent-shell's configured backends). The buffer opens in the current window and the user can chat with the agent interactively. No orchestration, no multi-agent, no state machine — just proof that agent-shell replaces vterm without lag.

Update `packages.el` to declare `agent-shell` as a dependency and remove `vterm`.

### Acceptance criteria

- [ ] `M-x emaclaude-launch` prompts for LLM backend selection
- [ ] An agent-shell buffer named `*mra-planning*` is created and connected via ACP
- [ ] User can send messages and receive responses without lag
- [ ] `packages.el` declares `agent-shell` dependency, no `vterm` reference
- [ ] **Critical checkpoint**: Verify lag is eliminated compared to vterm

---

## Phase 2: Multi-agent spawning + layout

**User stories**: 1, 3, 24

### What to build

Extend `emaclaude-launch` to save the current window configuration. Add `emaclaude-spawn-agent` that creates named agent-shell buffers with the selected LLM backend. Add `emaclaude--split-layout` that arranges three buffers in a 3-way split (planning left, coding top-right, review bottom-right). At this phase, the coding and review agents are spawnable but not yet orchestrated — they just exist as interactive agent-shell sessions.

Add `emaclaude-send-to-agent` that wraps `shell-maker-submit` with busy-queueing: if `shell-maker-busy` returns true, use `agent-shell--enqueue-request` for automatic delivery when ready.

### Acceptance criteria

- [ ] `emaclaude-launch` saves window config before spawning
- [ ] Three agent-shell buffers can be spawned: `*mra-planning*`, `*mra-coding*`, `*mra-review*`
- [ ] 3-way split layout displays correctly
- [ ] `emaclaude-send-to-agent` delivers messages to a named buffer
- [ ] `emaclaude-send-to-agent` queues messages when the target agent is busy
- [ ] All three agents use the LLM backend selected at launch

---

## Phase 3: Signal CLI + skills

**User stories**: 18, 25, 26, 27

### What to build

Create `bin/emaclaude-signal`, a bash script that agents call to signal phase transitions. It takes an event name and optional JSON payload, and calls `emacsclient --eval` to invoke `emaclaude--handle-event` in Emacs.

Create a stub `emaclaude--handle-event` in elisp that receives signals and logs them (full orchestration comes in Phase 5).

Rewrite the `planning-done` skill to use `emaclaude-signal` instead of `curl POST`. Create new `coding-done` and `review-done` skills.

Update `emaclaude setup` to symlink `bin/emaclaude-signal` to a location in PATH and symlink all skills.

### Acceptance criteria

- [ ] `bin/emaclaude-signal planning-done '{"prompt":"...", "spec_path":"..."}'` successfully invokes `emaclaude--handle-event` in Emacs
- [ ] `bin/emaclaude-signal coding-done '{"branch":"feat/x"}'` works
- [ ] `bin/emaclaude-signal review-done '{"status":"approved"}'` works
- [ ] `skills/planning-done/SKILL.md` references `emaclaude-signal` (no curl)
- [ ] `skills/coding-done/SKILL.md` exists with correct signaling protocol
- [ ] `skills/review-done/SKILL.md` exists with correct signaling protocol
- [ ] `emaclaude setup` symlinks the signal script and all skills
- [ ] An agent running in an agent-shell buffer can successfully call `emaclaude-signal` and the event is received by Emacs

---

## Phase 4: Rust CLI conversion

**User stories**: 19, 20

### What to build

Convert the Rust binary from a long-running HTTP daemon to a stateless CLI tool. Rewrite `main.rs` to read JSON from stdin, deserialize to state + event + config, call `WorkflowState::next()`, serialize the result (new state + parameterized effects) to JSON on stdout. Exit 0 on success, exit 1 with JSON error on invalid transition.

Add `Serialize`/`Deserialize` derives to `SideEffect` and all related types. Update prompt text in `state.rs` effects to reference `emaclaude-signal` instead of `curl POST` to localhost.

Delete `server.rs`, `emacs.rs`, `effects.rs`, `config.rs`. Remove Tokio, Axum, figment, toml, reqwest, tempfile, tracing, thiserror, dirs, anyhow from `Cargo.toml`.

Update existing tests to verify `emaclaude-signal` references in effect prompts. Add tests for JSON round-trip serialization and invalid event rejection.

### Acceptance criteria

- [ ] `echo '{"state":"Idle","event":{"PlanningDone":{"prompt":"...","spec_path":"..."}},"config":{"confirmation_loops":2}}' | emaclaude transition` returns valid JSON with `state: "Coding"` and parameterized effects
- [ ] Invalid transitions return exit code 1 with `{"error":"..."}` on stdout
- [ ] All `SideEffect` prompt text references `emaclaude-signal` (no `curl`, no `localhost`)
- [ ] `server.rs`, `emacs.rs`, `effects.rs`, `config.rs` are deleted
- [ ] `Cargo.toml` has only `serde`, `serde_json`, `clap` as dependencies
- [ ] `cargo test` passes — all existing state transition tests updated and passing
- [ ] New tests for JSON contract and invalid event rejection pass

---

## Phase 5: Elisp orchestrator + autonomous review loop

**User stories**: 4, 5, 6, 7, 23

### What to build

Implement the full `emaclaude--handle-event` function. It holds workflow state in `emaclaude--workflow-state`, constructs JSON input, pipes it to the Rust CLI via `shell-command-to-string`, parses the JSON output, and dispatches parameterized effects through a dispatch table.

The effect dispatch table maps effect names to elisp functions:
- `SpawnCodingAgent` → spawn agent-shell buffer + send initial prompt
- `SpawnReviewAgent` → spawn agent-shell buffer
- `SendToCodingAgent` → `emaclaude-send-to-agent` with message
- `SendToReviewAgent` → `emaclaude-send-to-agent` with message
- `OpenDiffView` → deferred (Phase 6)
- `RefreshDiffView` → deferred (Phase 6)
- `Notify` → `emaclaude--notify`
- `Shutdown` → deferred (Phase 8)

Wire up the full flow: planning-done signal → spawn coding+review → coding-done → send review prompt → review-done (approved/changes_needed) → feedback loop → confirmation passes → escalate to human review (opens diff in Phase 6, for now just notifies).

### Acceptance criteria

- [ ] `emaclaude--handle-event "planning-done" "{...}"` transitions from Idle to Coding, spawns coding and review agent-shell buffers, sends initial prompt to coding agent
- [ ] Coding agent calling `emaclaude-signal coding-done` triggers review prompt sent to review agent
- [ ] Review agent calling `emaclaude-signal review-done '{"status":"changes_needed","feedback":"..."}'` sends feedback to coding agent
- [ ] Review agent calling `emaclaude-signal review-done '{"status":"approved"}'` increments confirmation count
- [ ] After sufficient confirmation passes, state transitions to HumanReview with notification
- [ ] Confirmation rejection resets approval count back to Coding
- [ ] Messages are queued when target agent is busy and delivered when ready
- [ ] Full autonomous review loop runs end-to-end without human intervention

---

## Phase 6: Magit human review

**User stories**: 8, 9, 10, 11, 12

### What to build

Wire up the `OpenDiffView` and `RefreshDiffView` effects. The diff view shows `magit-diff-range` comparing the current branch against `main`, with `default-directory` set correctly for worktree support. Enable `emaclaude-review-mode` on the diff buffer.

Port the existing review mode functions to use `emaclaude--handle-event` instead of `emaclaude--post`:
- `emaclaude-submit-comments` → calls `emaclaude--handle-event "human-comments" "{...}"` directly
- `emaclaude-create-pr` → calls `emaclaude--handle-event "create-pr" "{}"`

The coding agent receives formatted comments, makes fixes, signals `coding-done`, and the diff refreshes automatically.

### Acceptance criteria

- [ ] When state reaches HumanReview, magit diff opens comparing current branch vs `main`
- [ ] Diff view works correctly when inside a git worktree
- [ ] `SPC m c` adds inline comment overlays on selected lines
- [ ] `SPC m s` submits comments → coding agent receives formatted feedback
- [ ] Coding agent fixes → `emaclaude-signal coding-done` → diff refreshes automatically
- [ ] Multiple rounds of human comments → fixes → refresh work correctly
- [ ] `SPC m q` closes the diff view

---

## Phase 7: PR creation + GitHub reviews

**User stories**: 13, 14

### What to build

Wire up the PR creation flow. `SPC m p` triggers `emaclaude--handle-event "create-pr"`, which transitions to PrCreated and sends a PR creation prompt to the coding agent. The coding agent uses `gh pr create` and signals `coding-done`.

Implement `emaclaude-address-github-reviews` which prompts for a PR number, triggers `emaclaude--handle-event "address-github-reviews" '{"pr_number":N}'`, and the coding agent fetches PR comments via `gh api`, addresses them, pushes fixes, and signals completion.

### Acceptance criteria

- [ ] `SPC m p` in diff view triggers PR creation by the coding agent
- [ ] Coding agent creates PR via `gh pr create` and signals done
- [ ] Diff refreshes after PR creation
- [ ] `M-x emaclaude-address-github-reviews` prompts for PR number
- [ ] Coding agent fetches PR comments, addresses them, pushes fixes
- [ ] Diff refreshes after GitHub review fixes

---

## Phase 8: Infrastructure — logging, watchdog, cleanup

**User stories**: 15, 16, 17

### What to build

Implement `emaclaude--log-event` that appends JSONL entries to `~/.emaclaude/logs/YYYY-MM-DD.jsonl`. Hook it into the orchestrator (every state transition) and agent manager (every message send).

Implement the watchdog timer: `emaclaude--reset-watchdog` starts/resets a timer on each successful `emaclaude--handle-event`. If no signal arrives within the configurable timeout, `emaclaude--notify` alerts the user. `emaclaude--cancel-watchdog` cleans up on session clear.

Implement `emaclaude-clear-session`: kill all agent-shell buffers, kill the diff buffer, cancel the watchdog, restore the saved window configuration. Wire up the `Shutdown` effect in the dispatch table.

### Acceptance criteria

- [ ] Every state transition produces a JSONL log entry at `~/.emaclaude/logs/YYYY-MM-DD.jsonl`
- [ ] Log entries contain timestamp, event type, from, to, and payload
- [ ] Watchdog timer fires notification after configurable timeout with no signal
- [ ] Watchdog resets on each successful signal
- [ ] `M-x emaclaude-clear-session` kills all agent-shell buffers
- [ ] `M-x emaclaude-clear-session` kills the diff buffer
- [ ] `M-x emaclaude-clear-session` restores the saved window configuration
- [ ] No orphaned processes or timers remain after clear

---

## Phase 9: ERT tests + dead code retirement

**User stories**: 22 (verification)

### What to build

Write ERT tests for:
- **Orchestrator**: Mock `shell-command-to-string` to return canned Rust CLI responses. Verify state updates and effect dispatch for each transition.
- **Agent Manager**: Mock agent-shell functions. Verify `emaclaude-send-to-agent` calls `shell-maker-submit` when not busy and `agent-shell--enqueue-request` when busy.
- **Logger**: Write events to a temp file, read back and verify JSONL structure.
- **Watchdog**: Set short timeout, verify notification fires. Reset timer, verify old is cancelled.

Delete all remaining dead code:
- Any vterm references in elisp
- Old HTTP helper functions (`emaclaude--post`, `emaclaude--kill-stale-daemon`)
- Old daemon process management code
- Old server/integration tests that tested the HTTP API (`tests/server_test.rs`, `tests/emacs_test.rs`)

Verify the full workflow runs agent-agnostically (the architecture doesn't assume Claude).

### Acceptance criteria

- [ ] ERT test suite for orchestrator passes (mocked Rust CLI)
- [ ] ERT test suite for agent manager passes (mocked agent-shell)
- [ ] ERT test suite for logger passes (temp file verification)
- [ ] ERT test suite for watchdog passes (timer behavior)
- [ ] No references to `vterm` remain anywhere in the codebase
- [ ] No references to `curl`, `localhost:7878`, or HTTP endpoints remain
- [ ] No `server.rs`, `emacs.rs`, `effects.rs`, `config.rs` exist
- [ ] `cargo test` passes with updated test suite
- [ ] `emaclaude setup` successfully symlinks all components
- [ ] Full workflow demoable end-to-end: launch → plan → code → review loop → human review → PR
