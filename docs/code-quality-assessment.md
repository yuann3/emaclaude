# Code Quality Assessment

## Scope

This audit covers the tracked Rust and Emacs Lisp code in `src/`, `emacs/`, `tests/`, and the local CLI glue in `bin/`. The requested `knip` and `madge` style checks were adapted to the actual stack here: this repo is Rust + Emacs Lisp rather than TypeScript, so I used direct code inspection, contract tracing, and test updates instead of JS-only tooling.

## 1. Deduplication and DRY

### Assessment

- `src/state.rs` repeated the same signal instructions and follow-up prompt bodies in several transitions.
- `src/main.rs` repeated JSON error serialization and process-exit logic.
- `emacs/emaclaude.el` repeated buffer teardown logic in both full cleanup and cycle reset paths.

### Recommendation

Extract shared prompt builders and buffer cleanup helpers where they reduce branching and copy-paste.

### Implemented

- Centralized repeated Rust prompt text into small helpers in `src/state.rs`.
- Centralized JSON error/output printing in `src/main.rs`.
- Centralized Emacs buffer kill/unregister logic in `emacs/emaclaude.el`.

## 2. Shared type definitions

### Assessment

- The human review comment payload already carried `end_line` from Emacs, but the Rust `Comment` type dropped it.
- That created a lossy contract between `emacs/emaclaude.el` and `src/state.rs`.

### Recommendation

Promote `end_line` into the shared Rust type and preserve it through the state machine.

### Implemented

- Added `end_line: Option<u32>` to `Comment` in `src/state.rs`.
- Updated prompt formatting and tests to preserve line ranges.

## 3. Unused code

### Assessment

- No obviously unused production modules or dependencies were found in the tracked Rust or Emacs code.
- One stale pair of ERT tests duplicated later coverage with outdated naming (`selected-backend` vs `agent-configs`).

### Recommendation

Remove redundant stale tests, but leave production code untouched unless a reference is truly dead.

### Implemented

- Removed the duplicated stale tests from `emacs/emaclaude-test.el`.

## 4. Circular dependencies

### Assessment

- No circular module dependencies were found in the Rust code (`main -> lib -> state`) or the Emacs Lisp entrypoints.
- `madge` is not applicable to this stack, and there is no JS/TS import graph to untangle.

### Recommendation

No code change needed; keep the current one-way module boundaries.

### Implemented

- No change, by design.

## 5. Weak types and loose contracts

### Assessment

- The main weak contract was the dropped `end_line` review metadata.
- `emaclaude-add-comment` fell back to the string `"unknown"` when no file was available, which weakens downstream review data.

### Recommendation

Prefer explicit failures over placeholder data when the surrounding workflow expects a real file/hunk.

### Implemented

- Removed the `"unknown"` file fallback in `emacs/emaclaude.el`.
- Added an explicit `user-error` when a comment is created outside a file hunk.

## 6. Defensive programming and error handling

### Assessment

- `emaclaude-clear-session` used `ignore-errors` and then always ran direct cleanup, even when the state machine succeeded.
- `emaclaude-send-to-agent` caught queueing errors but still returned success, which hid operational failures.

### Recommendation

Keep error handling only where it serves a clear boundary, and make failures observable to callers.

### Implemented

- Removed the redundant `ignore-errors` path from `emaclaude-clear-session`.
- Kept the direct cleanup path only as a real fallback when the state machine returns failure.
- Changed `emaclaude-send-to-agent` to return `nil` on queueing failure instead of reporting false success.

## 7. Deprecated, legacy, and fallback paths

### Assessment

- The PR creation prompt told the coding agent to emit `pr-created`, but no such event exists anywhere in the codebase.
- That was a live contract bug, not just a stale comment.

### Recommendation

Remove the orphaned event contract and reuse the existing `coding-done` signal.

### Implemented

- Replaced the invalid `pr-created` instruction with the existing `coding-done` flow in `src/state.rs`.
- Updated the corresponding test expectation.

## 8. AI slop, stubs, and unhelpful comments

### Assessment

- Most comments are functional, but the duplicated stale tests were a concrete example of drifted scaffolding.
- Several explanatory comments repeated what the code already made obvious.

### Recommendation

Prefer deleting stale scaffolding over preserving misleading names, and keep comments focused on non-obvious behavior.

### Implemented

- Removed the stale duplicated test block.
- Trimmed some repetitive cleanup/reset comments while keeping the non-obvious behavior intact.

## Remaining medium-confidence items not changed

- `emaclaude--workflow-state` is still stored as JSON text in Emacs; moving it to a native structured value would be a larger behavioral refactor.
- The large ERT file could be split by feature area, but that is an organizational change rather than a high-confidence correctness fix.
- Planning docs in `docs/plans/` intentionally preserve historical context, so I did not treat them as dead code.
