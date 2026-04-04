# README v2 Update Design Spec

## Overview

Full rewrite of README.org to reflect the v2 agent-shell architecture while preserving the original conversational voice and treating the new architecture as the baseline (not a migration).

## Decisions

| Decision | Choice |
|----------|--------|
| Format | Keep org-mode (README.org) |
| Voice | Full rewrite with same conversational/opinionated tone |
| Approach | Experience-first — workflow stays front and center, architecture is implementation detail |
| Architecture diagram | ~15 lines, same size as current |
| Config section | Replace TOML with elisp customize examples |
| Sections | Keep same 8 sections, just update content |

## Section-by-Section Changes

### 1. Intro/Philosophy
- Update Electron wrapper examples (cmux/emdashes/conductor → cursor/windsurf)
- Remove "vterm" — just say "split buffers"
- Change "rust daemon" → "rust CLI and elisp orchestrator"
- Change "talk through http" → "signal each other through emacs"

### 2. How It Works
- Keep identical — workflow description was already accurate
- Remove "replies on github" detail

### 3. The Layout
- No changes — buffer names and layout identical in v2

### 4. Architecture
- vterm → agent-shell
- "daemon" → "CLI"
- "axum http server" → "stateless state machine, stdin/stdout JSON"
- "curl" → "emaclaude-signal"
- Update line count (~500 → ~130) and deps (axum/tokio/figment → serde/clap)

### 5. The Review Loop
- No changes — review loop logic identical in v2

### 6. Installation
- Remove "vterm" from requirements (agent-shell is elisp package dep)
- Add note about `emaclaude-signal` in `~/.local/bin/` needing to be in PATH

### 7. Usage
- Update `emaclaude-launch` description: "select LLM backend + open all three agent buffers"
- Remove `M-x emaclaude-open-diff` — diff view now opens automatically

### 8. Config
- Replace TOML config with elisp `setq` examples
- Remove `port` and `emacsclient_path` (no longer exist)
- Add `emaclaude-watchdog-timeout` (new in v2)
- Add comments explaining each option

## Full Proposed README

```org
#+title: emaclaude
#+author: Yuan

so we got cursor, windsurf, and whatever the latest "agentic IDE" is this week. they wrap claude in an electron app and charge you for the privilege.

here's the thing though. if you're already running emacs, you have a programmable operating system sitting right there. you can split buffers, run agents, diff code, talk to external processes, script literally anything in elisp. so why not just... do it in emacs?

emaclaude is three claude code sessions running in split buffers, coordinated by a small rust CLI and an elisp orchestrator. one plans. one codes. one reviews. they signal each other through emacs. you watch the whole thing happen live in split panes.

for now, using Doom Module so it's *DOOM EMACS ONLY*, but i will change that in the future.

* how it works

you plan in one buffer, write specs and PRDs with claude. when you're done, hit ~/planning-done~ and the system spawns a coding agent and a review agent in two more buffers. the coding agent implements your spec. when it finishes, the review agent checks the code for quality, security, redundant junk, and spec compliance. if the review agent finds problems, it sends feedback back to the coding agent. they loop until the review agent approves twice in a row (we run confirmation passes because sometimes the reviewer hallucinates an approval).

when the loop finishes, a magit diff view opens on the right side of your frame. you can read through the changes, select lines with ~V~, hit ~SPC m c~ to leave comments, and ~SPC m s~ to send them to the coding agent for fixes. when you're happy, ~SPC m p~ creates the PR.

later, when your teammates leave github review comments, you run ~M-x emaclaude-address-github-reviews~ and the coding agent picks them up, fixes everything, and pushes. you never leave emacs.

* the layout

#+begin_src
┌──────────────┬──────────────┬──────────────┐
│              │   *mra-      │              │
│              │   coding*    │              │
│  *mra-       ├──────────────┤   *mra-diff* │
│  planning*   │   *mra-      │   (appears   │
│              │   review*    │    later)    │
│              │              │              │
└──────────────┴──────────────┴──────────────┘
#+end_src

planning stays on the left so you can reference it while watching the agents work. diff view slides in on the right when the review loop finishes.

* architecture

#+begin_src
┌───────────────────────────────────────────────────┐
│                   Doom Emacs                      │
│                                                   │
│  agent-shell buffers (planning, coding, review)   │
│  elisp orchestrator owns all state + effects      │
└──────────────────────┬────────────────────────────┘
                       │ JSON pipe
                       │
┌──────────────────────┴─────────────────────────────┐
│              emaclaude CLI (rust)                  │
│                                                    │
│  stateless state machine ── stdin/stdout JSON     │
└──────────────────────┬─────────────────────────────┘
                       │ emaclaude-signal
                       │
┌──────────────────────┴─────────────────────────────┐
│           claude code skills                       │
│  /planning-done    /coding-done    /review-done    │
└────────────────────────────────────────────────────┘
#+end_src

the CLI doesn't call any LLMs. it doesn't run a server. all the AI work happens inside the claude code sessions. elisp pipes state + event JSON to the CLI, gets back new state + effects, and executes them. skills signal phase transitions through ~emaclaude-signal~ which calls back into emacs via ~emacsclient --eval~.

the whole CLI is ~130 lines of rust. serde for JSON, clap for arg parsing, nothing else.

* the review loop

#+begin_src
coding agent ──► review agent ──► approved? ─── no ──► coding agent (loop)
                                      │
                                     yes
                                      │
                              confirm again (×2)
                                      │
                              all clear? ─── no ──► coding agent (reset)
                                      │
                                     yes
                                      │
                              magit diff view opens
                                      │
                              you review, comment
                                      │
                              SPC m p ──► PR
#+end_src

the confirmation passes exist because we found the review agent sometimes says "looks good" without actually reading the diff. running it twice more catches those ghost approvals. if a confirmation pass finds new issues, the whole approval count resets.

there's no iteration cap. the loop runs until the code is actually clean. in practice it usually converges in 2-4 rounds.

* installation

you need rust, claude code cli, doom emacs (with magit), and the ~gh~ cli.

#+begin_src bash
git clone https://github.com/yuann3/emaclaude.git
cd emaclaude
cargo install --path .
emaclaude setup
#+end_src

~emaclaude setup~ symlinks the claude code skills into =~/.claude/skills/= and the doom module into =~/.doom.d/modules/tools/emaclaude/=. it also puts ~emaclaude-signal~ in =~/.local/bin/= (make sure that's in your PATH). then add it to your doom config and sync:

#+begin_src elisp
;; in ~/.doom.d/init.el, under :tools
(emaclaude)
#+end_src

#+begin_src bash
doom sync
#+end_src

or if you just want to test without the full doom module setup:

#+begin_src elisp
M-x load-file RET ~/.doom.d/modules/tools/emaclaude/emaclaude.el RET
#+end_src

* usage

#+begin_src
M-x emaclaude-launch          select LLM backend + open all three agent buffers
/planning-done                 hand off spec to coding + review agents
M-x emaclaude-address-github-reviews   fetch + fix PR comments
M-x emaclaude-clear-session    kill everything, restore your layout
#+end_src

in the diff view:
#+begin_src
V          select lines (evil visual)
SPC m c    comment on selection
SPC m s    submit all comments to coding agent
SPC m p    create PR
SPC m q    close diff view
#+end_src

* config

optional. defaults work out of the box. if you want to change something, add to your doom config:

#+begin_src elisp
;; number of confirmation passes before human review (default 2)
(setq emaclaude-confirmation-loops 3)

;; watchdog timeout in seconds — notifies if agents go quiet (default 600)
(setq emaclaude-watchdog-timeout 300)

;; buffer names (defaults are fine for most people)
(setq emaclaude-buffer-planning "*mra-planning*")
(setq emaclaude-buffer-coding "*mra-coding*")
(setq emaclaude-buffer-review "*mra-review*")
(setq emaclaude-buffer-diff "*mra-diff*")
#+end_src
```

## Implementation

Single file change: replace contents of `README.org` with the proposed content above.
