---
name: Clone Repository — Execution
description: Reads the repository name or URL from the kickstart prompt text and clones it into /src. First step of the issue-driven pipeline.
version: 1.0
---

# Clone Repository — Execution Phase

> **You are running inside the dotbot workspace, not inside the target repository.**
> The current working directory is the project that uses dotbot — it is NOT the repository you need to clone.
> Your job is to clone a completely separate repository (specified in the kickstart prompt) into `/src`.
> Do not inspect the current directory to determine what to clone. Always read the kickstart prompt.

## Step 1 — Mark Task In-Progress

```
mcp__dotbot__task_mark_in_progress({ task_id: "{{TASK_ID}}" })
```

## Step 2 — Read the Kickstart Prompt

Read the raw kickstart text from `.bot/.control/launchers/kickstart-prompt.txt`.

This text was typed by the user when starting the workflow. It contains the repository to clone — as a GitHub `owner/repo` shorthand, a full HTTPS URL, or mixed with other text such as an issue number. Use your judgement to extract the repository identifier.

Examples of what the text might look like:
- `myorg/myrepo 42`
- `https://github.com/myorg/myrepo 42`
- `myorg/myrepo`
- `https://github.com/myorg/myrepo.git`

## Step 3 — Clone the Repository

Once you have identified the repository, clone it into `./src`:

- If you extracted an `owner/repo` shorthand, clone `https://github.com/owner/repo.git`
- If you extracted a full HTTPS URL, use it directly
- Remove `./src` first if it already exists

Run the clone via Bash. If it fails, call `task_mark_failed` with the error output.

## Step 4 — Verify /src Exists

After the clone, confirm the directory was created and is not empty:

- Check that `./src` exists as a directory
- Check that `./src` contains at least one file or subdirectory (e.g. list its top-level contents)

If `./src` is missing or empty, try cloning 3 times more and then the clone silently failed — call `task_mark_failed` with details.

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

- **The repository to clone is always the one in the kickstart prompt — never the current working directory.**
- Do not read CLAUDE.md, settings, or GitHub APIs — the only input you need is `.bot/.control/launchers/kickstart-prompt.txt`.
- Do not commit anything. This task only clones.
- If the kickstart text contains no recognisable repository identifier, call `task_mark_failed` with a clear message.
- Never mark the task done before verifying `./src` exists and is non-empty.
