---
name: Clone Repository — Execution
description: Clones the target repository into ./src using the URL resolved by the analysis phase.
version: 1.1
---

# Clone Repository — Execution Phase

## Step 1 — Mark Task In-Progress

```
mcp__dotbot__task_mark_in_progress({ task_id: "{{TASK_ID}}" })
```

## Step 2 — Get the Clone URL

Call `task_get_context` to read the analysis object:

```
mcp__dotbot__task_get_context({ task_id: "{{TASK_ID}}" })
```

Use `context.analysis.clone_url` as the repository URL to clone.

If `clone_url` is missing or empty (analysis context unavailable), fall back to reading
`.bot/.control/launchers/workflow-launch-prompt.txt` and extract the repository identifier
from the raw launch prompt text using the same rules as the analysis phase (see agent AGENT.md).

## Step 3 — Clone the Repository

- Remove `./src` if it already exists
- Clone the resolved URL into `./src` via Bash
- If the clone fails, call `task_mark_failed` with the error output

## Step 4 — Verify ./src Exists and Is Non-Empty

- Check that `./src` exists as a directory
- Check that `./src` contains at least one file or subdirectory

If `./src` is missing or empty after the clone, retry up to 3 times. If still empty, call
`task_mark_failed` with details.

## Step 5 — Mark Task Done

```
mcp__dotbot__task_mark_done({
  task_id: "{{TASK_ID}}",
  result: {
    summary: "Cloned {repo} into /src. Directory verified non-empty.",
    deliverables: ["/src"]
  }
})
```

## Rules

- The current directory is the dotbot project itself — it is NOT the target repository.
- Do not commit anything. This task only clones.
- Never mark the task done before verifying `./src` exists and is non-empty.
