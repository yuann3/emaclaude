# Per-Agent LLM Backend Configuration

## Summary

Allow users to configure different LLM backends for each of emaclaude's three agents (planning, coding, review). For example: Claude Code for planning and coding, Codex for review.

## Current Behavior

- `emaclaude-launch` prompts user once via `agent-shell-select-config`
- Stores selection in `emaclaude--selected-agent-config`
- All three agents share this single config

## Proposed Behavior

- Three new defcustom variables specify the backend for each agent
- Default (nil) inherits from `agent-shell-preferred-agent-config`
- `M-x emaclaude-launch` silently uses configured defaults
- `C-u M-x emaclaude-launch` prompts for all three agents

## Design Decisions

| # | Question | Decision |
|---|----------|----------|
| 1 | Config storage | Hybrid: defcustom defaults + `C-u` override |
| 2 | Launch UX | Silent launch with defaults |
| 3 | Override granularity | All-or-nothing (3 prompts) |
| 4 | Default values | Inherit from `agent-shell-preferred-agent-config` |
| 5 | Config value type | Symbol only (e.g., `'claude-code`) |
| 6 | Variable naming | `-agent` suffix |
| 7 | Resolution failure | Error immediately |
| 8 | Inheritance representation | nil means inherit |
| 9 | Customize grouping | Flat in existing `emaclaude` group |
| 10 | Session state | Single alist `emaclaude--agent-configs` |
| 11 | Override storage | Same alist, no distinction |
| 12 | Resolution functions | Two functions (symbol + role wrappers) |
| 13 | Prompt flow | Simple, three `completing-read` calls |
| 14 | spawn-buffer signature | Keep current, caller passes resolved config |

## API Changes

### New Defcustoms

```elisp
(defcustom emaclaude-planning-agent nil
  "Agent backend for the planning agent.
A symbol identifying an agent in `agent-shell-agent-configs' (e.g., `claude-code').
When nil, inherits from `agent-shell-preferred-agent-config'."
  :type '(choice (const :tag "Inherit from agent-shell" nil)
                 (symbol :tag "Agent identifier"))
  :group 'emaclaude)

(defcustom emaclaude-coding-agent nil
  "Agent backend for the coding agent.
A symbol identifying an agent in `agent-shell-agent-configs' (e.g., `claude-code').
When nil, inherits from `agent-shell-preferred-agent-config'."
  :type '(choice (const :tag "Inherit from agent-shell" nil)
                 (symbol :tag "Agent identifier"))
  :group 'emaclaude)

(defcustom emaclaude-review-agent nil
  "Agent backend for the review agent.
A symbol identifying an agent in `agent-shell-agent-configs' (e.g., `codex').
When nil, inherits from `agent-shell-preferred-agent-config'."
  :type '(choice (const :tag "Inherit from agent-shell" nil)
                 (symbol :tag "Agent identifier"))
  :group 'emaclaude)
```

### New Internal Variable

```elisp
(defvar emaclaude--agent-configs nil
  "Alist mapping roles to resolved agent configs for the current session.
Keys are symbols: `planning', `coding', `review'.
Values are full agent-shell config alists.
Set by `emaclaude-launch', cleared by `emaclaude--cleanup-buffers-and-windows'.")
```

Replaces the existing `emaclaude--selected-agent-config`.

### New Functions

```elisp
(defun emaclaude--resolve-agent-symbol (symbol)
  "Resolve SYMBOL to a full agent config alist.
SYMBOL should be an identifier like `claude-code' or `codex'.
Returns the matching config from `agent-shell-agent-configs'.
Signals an error if SYMBOL is not found.")

(defun emaclaude--resolve-agent-config (role)
  "Resolve the agent config for ROLE.
ROLE is a symbol: `planning', `coding', or `review'.
Looks up the corresponding defcustom (e.g., `emaclaude-planning-agent').
If nil, falls back to `agent-shell-preferred-agent-config'.
If still nil, signals an error asking user to configure.
Returns a full agent-shell config alist.")
```

### Modified Functions

**`emaclaude-launch`**
- Accept optional prefix arg
- Without prefix: resolve configs from defcustoms, populate `emaclaude--agent-configs`
- With prefix: prompt for all three agents via `agent-shell-select-config`
- Pass resolved configs to `emaclaude--spawn-buffer`

**`emaclaude--cleanup-buffers-and-windows`**
- Clear `emaclaude--agent-configs` instead of `emaclaude--selected-agent-config`

## Example Usage

```elisp
;; In user's config: planning and coding use Claude Code, review uses Codex
(setq emaclaude-planning-agent 'claude-code)
(setq emaclaude-coding-agent 'claude-code)
(setq emaclaude-review-agent 'codex)

;; Or via customize:
;; M-x customize-variable RET emaclaude-review-agent RET

;; Launch with configured defaults:
;; M-x emaclaude-launch

;; Override for this session only:
;; C-u M-x emaclaude-launch
;; -> Select planning agent: gemini-cli
;; -> Select coding agent: claude-code
;; -> Select review agent: codex
```

## Implementation Tasks

1. Add three new defcustoms
2. Add `emaclaude--agent-configs` variable
3. Remove `emaclaude--selected-agent-config` variable
4. Implement `emaclaude--resolve-agent-symbol`
5. Implement `emaclaude--resolve-agent-config`
6. Modify `emaclaude-launch` to handle prefix arg and per-agent resolution
7. Modify `emaclaude-spawn-agent` to read from `emaclaude--agent-configs`
8. Modify `emaclaude--cleanup-buffers-and-windows` to clear new variable
