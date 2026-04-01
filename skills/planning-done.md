---
name: planning-done
description: Signal that planning is complete. Triggers the coding and review agents via emaclaude.
---

You are helping the user signal that planning is done and hand off to the autonomous coding and review agents.

## Step 1: Find the spec file

Look for the most recent spec or plan file in this order:
1. Check `./specs/` for `.md` files (sort by modification time, newest first)
2. Check `./docs/plans/` for `.md` files (sort by modification time, newest first)
3. If nothing is found, ask the user to provide the path manually

Show the user the file you found and ask: "Use this spec file? [Y/n] or enter a different path:"

If the user provides a different path, use that instead.

## Step 2: Compose the prompt for the coding agent

Ask the user: "Any specific instructions for the coding agent? (Press Enter for default)"

If the user provides instructions, use them as-is.

If the user skips (empty input), generate a default prompt based on the spec file content:

```
Implement the project according to the spec at <spec_path>.

Read the spec carefully before starting. Work through it systematically,
committing logical units of work as you go. When you are done with a
significant milestone or the full implementation, run /coding-done.
```

## Step 3: POST to the emaclaude daemon

Run the following curl command, substituting the actual `prompt` and `spec_path` values:

```bash
curl -s -X POST http://localhost:7878/planning-done \
  -H "Content-Type: application/json" \
  -d '{
    "prompt": "<prompt>",
    "spec_path": "<spec_path>"
  }'
```

Use `jq` to build the JSON payload safely so that quotes and newlines in the prompt are properly escaped:

```bash
curl -s -X POST http://localhost:7878/planning-done \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg prompt "<prompt>" --arg spec_path "<spec_path>" \
        '{prompt: $prompt, spec_path: $spec_path}')"
```

## Step 4: Confirm to the user

After the curl command succeeds (HTTP 200), tell the user:

> Planning complete. The emaclaude daemon has been notified. The coding agent and review agent will be spawned in their Emacs vterm buffers and will begin working on the spec shortly.

If the curl command fails (connection refused, non-200 response, etc.), tell the user:

> Could not reach the emaclaude daemon at http://localhost:7878. Make sure the daemon is running (`emaclaude` binary) and try again.
