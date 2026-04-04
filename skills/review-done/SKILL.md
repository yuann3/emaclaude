---
name: review-done
description: Signal that code review is complete. Reports approval or requested changes back to emaclaude.
---

You have finished reviewing the code changes. Signal emaclaude with the review outcome.

## Step 1: Determine the review status

The status must be one of:
- `"approved"` — the code is ready to merge
- `"changes_needed"` — the code requires revisions

If changes are needed, include a `feedback` field with a summary of what needs to change.

## Step 2: Signal emaclaude

For approval:

```bash
emaclaude-signal review-done '{"status":"approved"}'
```

For changes needed:

```bash
emaclaude-signal review-done "$(jq -n --arg status 'changes_needed' --arg feedback '<feedback summary>' \
  '{status: $status, feedback: $feedback}')"
```

## Step 3: Confirm

After the signal command succeeds (exit code 0), tell the user:

> Review complete (status: `<status>`). Emacs has been notified.

If the signal command fails (non-zero exit code), tell the user:

> Could not reach Emacs via emacsclient. Make sure Emacs is running with a server (`M-x server-start`) and try again.
