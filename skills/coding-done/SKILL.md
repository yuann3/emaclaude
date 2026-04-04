---
name: coding-done
description: Signal that coding is complete. Triggers the review phase via emaclaude.
---

You have finished a significant coding milestone or the full implementation. Signal emaclaude so the review agent can begin.

## Step 1: Determine the current branch

```bash
BRANCH=$(git rev-parse --abbrev-ref HEAD)
```

## Step 2: Signal emaclaude

```bash
emaclaude-signal coding-done "$(jq -n --arg branch "$BRANCH" '{branch: $branch}')"
```

## Step 3: Confirm

After the signal command succeeds (exit code 0), tell the user:

> Coding phase complete on branch `<branch>`. Emacs has been notified. The review agent will begin shortly.

If the signal command fails (non-zero exit code), tell the user:

> Could not reach Emacs via emacsclient. Make sure Emacs is running with a server (`M-x server-start`) and try again.
