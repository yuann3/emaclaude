# Emaclaude v2 — Agent Shell Migration Spec

## Problem

vterm's C-based rendering pipeline is fundamentally incompatible with Claude Code's complex TUI (Ink/React). This causes lag across input, rendering, and prompt injection. The entire vterm approach is a mismatch for programmatic agent orchestration.

## Solution

Replace vterm with agent-shell (ACP protocol). Restructure the Rust daemon into a stateless CLI tool. Move all I/O orchestration into elisp.

## Architecture Decisions

| # | Decision | Choice |
|---|----------|--------|
| 1 | Why migrate | vterm fundamentally incompatible with complex TUI agents |
| 2 | ACP vs CLI | ACP — no TUI rendering, structured JSON protocol |
| 3 | Rust daemon | Stateless CLI tool, not a daemon. Emacs owns state, Rust computes transitions |
| 4 | Review loop | Preserve in elisp state machine + keep magit human review as-is |
| 5 | Skill migration | Replace curl-based skills with `emaclaude-signal` CLI tool |
| 6 | Migration strategy | Incremental (single session → multi-agent → review loop → human review) |
| 7 | Meta-agent-shell scope | Primitives only — use as reference, not a dependency |
| 8 | Phase signaling | `emaclaude-signal` → `emacsclient --eval (emaclaude--handle-event ...)` |
| 9 | Agent topology | Three fixed agents: planning, coding, review |
| 10 | Diff view | Compare current branch vs main, worktree-aware |
| 11 | Deletion scope | Remove server.rs, emacs.rs, effects.rs, config.rs, Tokio, Axum |
| 12 | Worktree support | One worktree per feature, all three agents share it, diff against main |
| 13 | Orchestrator | Pure elisp handler, not an agent. Custom `emaclaude-signal` CLI tool |
| 14 | Agent init | Initial message only, no CLAUDE.md |
| 15 | Error recovery | Don't care — agent work survives in git |
| 16 | Dependencies | agent-shell only. DIY JSONL logging + message queueing. Meta-agent-shell as reference |
| 17 | CLI interface | JSON stdin/stdout, validates transitions, rejects invalid events |
| 18 | Effects | Parameterized — Rust returns effect name + all data, elisp executes blindly |
| 19 | Testing | Rust: state transition tests. Elisp: ERT tests |
| 20 | LLM backend | Agent-agnostic via ACP. LLM selectable at launch, per-agent customization later |
| 21 | Packaging | Doom module, `agent-shell` as package dependency |
| 22 | Naming | Keep `emaclaude` |

## What Gets Deleted

- `server.rs` (306 lines) — HTTP server
- `emacs.rs` (113 lines) — EmacsBridge
- `effects.rs` (80 lines) — effect executor
- `config.rs` (69 lines) — config loading
- All Tokio/Axum dependencies
- All vterm code in `emaclaude.el`
- curl-based skills

## What Gets Kept

- `state.rs` (275 lines) — pure state machine, untouched
- Magit diff view + inline commenting UX
- State machine transitions and review loop logic
- Rust test suite

## What Gets Built New

- **`main.rs`** (~30 lines) — CLI wrapper: JSON stdin → state transition → JSON stdout
- **`emaclaude.el`** (rewrite) — agent-shell orchestrator with:
  - State holder (global variable)
  - `emaclaude--handle-event` — receives signals, calls Rust CLI, executes effects
  - `emaclaude-send-to-agent` — wrapper around `shell-maker-submit` with busy queueing
  - `emaclaude--log-event` — JSONL logging
  - `emaclaude--reset-watchdog` — stuck-agent timer
  - LLM selection on launch
- **`bin/emaclaude-signal`** (~10 lines) — bash script agents call to signal phase completion
- **ERT test suite** — orchestrator tests, message routing tests
- **`packages.el`** — declares `agent-shell` instead of `vterm`

### Claude Code Skills (v2)

Skills are rewritten to use `emaclaude-signal` instead of `curl POST`. Created alongside `bin/emaclaude-signal` in migration step 4.

| Skill | Purpose | Signal |
|-------|---------|--------|
| `planning-done` | **Rewrite.** Finds spec, composes prompt, signals handoff to coding/review | `emaclaude-signal planning-done '{"prompt":"...", "spec_path":"..."}'` |
| `coding-done` | **New.** Coding agent calls this when implementation is complete | `emaclaude-signal coding-done '{"branch":"..."}'` |
| `review-done` | **New.** Review agent calls this with approval or feedback | `emaclaude-signal review-done '{"status":"approved"}' or '{"status":"changes_needed","feedback":"..."}'` |

**Key changes from v1 skills:**
- No `curl` or HTTP — all signaling goes through `emaclaude-signal` → `emacsclient --eval`
- No hardcoded port numbers
- `coding-done` and `review-done` are now explicit skills rather than raw curl commands embedded in state machine prompts
- The Rust state machine's `SideEffect` prompt text references these skill names so agents know what to call

## System Workflow Diagram

```
╔══════════════════════════════════════════════════════════════════════════════╗
║                        EMACLAUDE v2 — SYSTEM WORKFLOW                      ║
╚══════════════════════════════════════════════════════════════════════════════╝

 ┌─────────────────────────────────────────────────────────────────────────┐
 │                          1. LAUNCH PHASE                                │
 │                                                                         │
 │  M-x emaclaude-launch                                                   │
 │       │                                                                 │
 │       ▼                                                                 │
 │  Select LLM backend (Claude, Gemini, Codex, etc.)                       │
 │       │                                                                 │
 │       ▼                                                                 │
 │  Save window config ──▶ Spawn *mra-planning* (agent-shell/ACP buffer)   │
 │                              │                                          │
 │                              ▼                                          │
 │                     User chats with planning agent                      │
 └─────────────────────────────┬───────────────────────────────────────────┘
                               │
                               ▼
 ┌─────────────────────────────────────────────────────────────────────────┐
 │                     2. PLANNING → CODING HANDOFF                        │
 │                                                                         │
 │  Agent calls: emaclaude-signal planning-done '{"prompt":"..."}'         │
 │       │                                                                 │
 │       ▼                                                                 │
 │  ┌──────────────────────────────────────────────────────┐               │
 │  │ SIGNALING PIPELINE (used for ALL phase transitions)  │               │
 │  │                                                      │               │
 │  │  bin/emaclaude-signal (bash)                         │               │
 │  │       │                                              │               │
 │  │       ▼                                              │               │
 │  │  emacsclient --eval (emaclaude--handle-event ...)    │               │
 │  │       │                                              │               │
 │  │       ▼                                              │               │
 │  │  Elisp: JSON encode ──pipe──▶ emaclaude transition   │               │
 │  │                                  (Rust CLI)          │               │
 │  │                                     │                │               │
 │  │                                     ▼                │               │
 │  │  Rust: validate + compute ──▶ {state, effects[]}     │               │
 │  │                                     │                │               │
 │  │                                     ▼                │               │
 │  │  Elisp: execute parameterized effects                │               │
 │  └──────────────────────────────────────────────────────┘               │
 │       │                                                                 │
 │       ▼  Rust: Idle ──▶ Coding                                         │
 │                                                                         │
 │  Effects:  ┌─ Spawn *mra-coding*  (agent-shell buffer)                  │
 │            ├─ Spawn *mra-review*  (agent-shell buffer)                  │
 │            ├─ Send initial prompt to coding agent                       │
 │            └─ 3-way split layout                                        │
 └─────────────────────────────┬───────────────────────────────────────────┘
                               │
                               ▼
 ┌─────────────────────────────────────────────────────────────────────────┐
 │                   3. AUTONOMOUS REVIEW LOOP                             │
 │                                                                         │
 │  ┌──────────────────┐                                                   │
 │  │                  │                                                   │
 │  │  Coding agent    │◀──────────────────────────────────┐               │
 │  │  works in        │                                   │               │
 │  │  *mra-coding*    │                                   │               │
 │  │                  │                                   │               │
 │  └────────┬─────────┘                                   │               │
 │           │                                             │               │
 │           ▼                                             │               │
 │  emaclaude-signal coding-done                           │               │
 │           │                                             │               │
 │           ▼                                             │               │
 │  Rust: Coding ──▶ Reviewing                             │               │
 │           │                                             │               │
 │           ▼                                             │               │
 │  Effect: emaclaude-send-to-agent                        │               │
 │          *mra-review* "Review diff branch..main"        │               │
 │           │                                             │               │
 │           ▼                                             │               │
 │  ┌──────────────────┐                                   │               │
 │  │  Review agent    │                                   │               │
 │  │  checks diff     │                                   │               │
 │  │  branch vs main  │                                   │               │
 │  └────────┬─────────┘                                   │               │
 │           │                                             │               │
 │           ▼                                             │               │
 │     ┌───────────┐    YES     emaclaude-signal           │               │
 │     │ Approved? ├──────────▶ review-done                │               │
 │     └─────┬─────┘            {status: approved}         │               │
 │           │ NO                    │                     │               │
 │           ▼                       │                     │               │
 │  emaclaude-signal                 │                     │               │
 │  review-done                      │                     │               │
 │  {status: changes_needed,         │                     │               │
 │   feedback: "..."}                │                     │               │
 │           │                       │                     │               │
 │           ▼                       │                     │               │
 │  Rust: Reviewing ──▶ Coding       │                     │               │
 │           │                       │                     │               │
 │           ▼                       │                     │               │
 │  Effect: send feedback ───────────┼─────────────────────┘               │
 │          to *mra-coding*          │                                     │
 │                                   │                                     │
 └───────────────────────────────────┼─────────────────────────────────────┘
                                     │
                                     ▼
 ┌─────────────────────────────────────────────────────────────────────────┐
 │                    4. CONFIRMATION PASSES                                │
 │                                                                         │
 │  Rust: Reviewing ──▶ Confirming{n=1}                                    │
 │           │                                                             │
 │           ▼                                                             │
 │  Effect: re-send review prompt (review-only, no coding)                 │
 │           │                                                             │
 │           ▼                                                             │
 │     ┌─────────────┐                                                     │
 │     │ Confirmed?  │                                                     │
 │     └──┬──────┬───┘                                                     │
 │        │      │                                                         │
 │    NO  │      │ YES                                                     │
 │        │      │                                                         │
 │        ▼      ▼                                                         │
 │  ┌─────────┐  ┌──────────────────┐                                      │
 │  │ Reset   │  │ n+1 >= loops?    │                                      │
 │  │ to      │  └───┬─────────┬───┘                                      │
 │  │ Coding  │      │         │                                           │
 │  │ (n=0)   │   NO │     YES │                                           │
 │  └────┬────┘      ▼         ▼                                           │
 │       │     Confirming   Rust: ──▶ HumanReview                          │
 │       │     {n+1}             │                                         │
 │       │       │               ▼                                         │
 │       │       └──▶ loop  Effects:                                       │
 │       │                  ├─ Open magit diff (branch vs main)            │
 │       ▼                  └─ Notify user                                 │
 │  ▲ Back to Review Loop                                                  │
 └──────────────────────────────────────────────────┬──────────────────────┘
                                                    │
                                                    ▼
 ┌─────────────────────────────────────────────────────────────────────────┐
 │                      5. HUMAN REVIEW                                    │
 │                                                                         │
 │  ┌─────────────────────────────────────────────────────┐                │
 │  │  Magit Diff View (current branch vs main)           │                │
 │  │  • worktree-aware                                   │                │
 │  │  • inline comment overlays                          │                │
 │  │                                                     │                │
 │  │  Keybindings:                                       │                │
 │  │    V select ──▶ SPC m c ──▶ add comment             │                │
 │  │                 SPC m s ──▶ submit all comments ─────┼──┐            │
 │  │                 SPC m p ──▶ create PR ───────────────┼──┼──┐         │
 │  │                 SPC m q ──▶ close/cleanup ───────────┼──┼──┼──┐      │
 │  └─────────────────────────────────────────────────────┘  │  │  │      │
 │                                                            │  │  │      │
 │       ┌────────────────────────────────────────────────────┘  │  │      │
 │       ▼                                                       │  │      │
 │  Rust: HumanReview ──▶ HumanReview (no state change)         │  │      │
 │       │                                                       │  │      │
 │       ▼                                                       │  │      │
 │  Effect: send formatted comments to *mra-coding*              │  │      │
 │       │                                                       │  │      │
 │       ▼                                                       │  │      │
 │  Coding agent fixes ──▶ emaclaude-signal coding-done          │  │      │
 │       │                                                       │  │      │
 │       ▼                                                       │  │      │
 │  Effect: refresh magit diff ──▶ User reviews again (loop)     │  │      │
 │                                                               │  │      │
 └───────────────────────────────────────────────────────────────┼──┼──────┘
                                                                 │  │
                           ┌─────────────────────────────────────┘  │
                           ▼                                        │
 ┌─────────────────────────────────────────────────────────────┐    │
 │                   6. PR CREATION                             │    │
 │                                                              │    │
 │  Rust: HumanReview ──▶ PrCreated                             │    │
 │       │                                                      │    │
 │       ▼                                                      │    │
 │  Effect: send PR prompt to *mra-coding*                      │    │
 │       │                                                      │    │
 │       ▼                                                      │    │
 │  Coding agent: gh pr create ──▶ emaclaude-signal coding-done │    │
 │       │                                                      │    │
 │       ▼                                                      │    │
 │  Effect: refresh diff                                        │    │
 └──────────────────────────────┬───────────────────────────────┘    │
                                │                                    │
                                ▼                                    │
 ┌─────────────────────────────────────────────────────────────┐     │
 │                7. GITHUB REVIEW COMMENTS                     │     │
 │                                                              │     │
 │  M-x emaclaude-address-github-reviews (enter PR #)           │     │
 │       │                                                      │     │
 │       ▼                                                      │     │
 │  Rust: PrCreated ──▶ PrCreated                               │     │
 │       │                                                      │     │
 │       ▼                                                      │     │
 │  Effect: send prompt to fetch gh api PR comments             │     │
 │       │                                                      │     │
 │       ▼                                                      │     │
 │  Coding agent: address comments, push, resolve               │     │
 │       │                                                      │     │
 │       ▼                                                      │     │
 │  emaclaude-signal coding-done ──▶ refresh diff               │     │
 └──────────────────────────────┬───────────────────────────────┘     │
                                │                                     │
                                ▼                                     │
 ┌────────────────────────────────────────────────────────────────────┼──┐
 │                        8. CLEANUP                                  │  │
 │                                                          ◀─────────┘  │
 │  M-x emaclaude-clear-session                                         │
 │       │                                                               │
 │       ├──▶ Kill *mra-planning* (agent-shell buffer)                   │
 │       ├──▶ Kill *mra-coding*   (agent-shell buffer)                   │
 │       ├──▶ Kill *mra-review*   (agent-shell buffer)                   │
 │       ├──▶ Kill magit diff buffer                                     │
 │       └──▶ Restore saved window configuration                        │
 └───────────────────────────────────────────────────────────────────────┘


 ┌───────────────────────────────────────────────────────────────────────┐
 │              INFRASTRUCTURE (runs throughout all phases)               │
 │                                                                       │
 │  ┌─────────────────┐  ┌──────────────────┐  ┌─────────────────────┐  │
 │  │  JSONL Logger    │  │  Watchdog Timer   │  │  Message Queue      │  │
 │  │                  │  │                   │  │                     │  │
 │  │  Logs all phase  │  │  Fires if no      │  │  If agent is busy   │  │
 │  │  transitions &   │  │  signal received  │  │  (shell-maker-busy) │  │
 │  │  inter-agent     │  │  within timeout   │  │  messages enqueued  │  │
 │  │  messages to     │  │                   │  │  via agent-shell--  │  │
 │  │  ~/.emaclaude/   │  │  Resets on each   │  │  enqueue-request    │  │
 │  │  logs/YYYY-MM-   │  │  successful       │  │                     │  │
 │  │  DD.jsonl        │  │  signal           │  │  Auto-delivered     │  │
 │  │                  │  │                   │  │  when agent ready   │  │
 │  └─────────────────┘  └──────────────────┘  └─────────────────────┘  │
 └───────────────────────────────────────────────────────────────────────┘


 ┌───────────────────────────────────────────────────────────────────────┐
 │                     STATE MACHINE (Rust CLI)                          │
 │                                                                       │
 │  Idle ──▶ Coding ──▶ Reviewing ──┬──▶ Confirming{n} ──▶ HumanReview  │
 │                 ▲                │          │                  │       │
 │                 │                │          │                  │       │
 │                 └── changes ─────┘          │                  ▼       │
 │                 └── changes ───────────────┘              PrCreated   │
 │                                                                       │
 │  Any state + ClearSession ──▶ Idle (cleanup)                          │
 └───────────────────────────────────────────────────────────────────────┘
```

## Migration Order

1. Get single Claude Code session running in agent-shell
2. **Verify lag is gone** (critical checkpoint)
3. Add multi-agent spawning (three agent-shell buffers)
4. Build `bin/emaclaude-signal` CLI tool + rewrite/create all skills (`planning-done`, `coding-done`, `review-done`)
5. Update Rust state machine prompt text to reference `emaclaude-signal` instead of `curl`
6. Port state machine invocation to elisp (JSON pipe to Rust CLI)
7. Build effect executor in elisp
8. Re-integrate magit review workflow
9. Add JSONL logging + watchdog
10. Write ERT tests
11. Retire vterm + daemon code

## References

- [agent-shell](https://github.com/xenodium/agent-shell) — ACP-based Emacs agent interface
- [meta-agent-shell](https://github.com/ElleNajt/meta-agent-shell) — Reference architecture for multi-agent coordination
