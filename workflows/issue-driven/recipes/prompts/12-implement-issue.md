---
name: Implement Issue — Execution
description: Execution phase for Implement Issue. Analysis (design reading + code pattern study + implementation plan) handled by 98 with implement-issue-agent persona. This prompt writes code, runs build, and adds the needs-qa label. PR creation is owned by the dedicated Open PR task that runs next.
version: 2.1
---

# Implement Issue — Execution Phase

> **Repository:** `{{REPOSITORY}}` — use this for every GitHub API / MCP call in this prompt. Do not guess from settings or skill files; the framework resolves this from git remote.

> The analysis phase already ran `98-analyse-task.md` with the `implement-issue-agent` persona. It read the design doc, studied existing code patterns, identified files to modify, and produced an implementation plan in the analysis object. If the plan had genuine ambiguities, the user answered them via `task_mark_needs_input`. **Your job is the execution phase: write the code, run the build, and add `needs-qa` to the issue.** The shared branch is committed and pushed automatically by the framework after this task completes; the PR is opened by the dedicated `Open PR` task that runs next.

## Step 1 — Load the Analysis Context

Call `mcp__dotbot__task_get_context({ task_id: "{{TASK_ID}}" })` and read:

- `task.analysis.files.to_modify` — the files the plan will change
- `task.analysis.files.patterns_from` — reference implementations to mirror
- `task.analysis.implementation` — the implementation steps
- `task.questions_resolved` — any user decisions on implementation ambiguities
- `.bot/.control/launchers/workflow-launch-prompt.txt` — issue number
- `.bot/.control/settings.json` → `issue_driven` — build command, branch prefix, labels

Resolve issue number and slug.

## Step 2 — Pre-flight Skip Check

Fetch the issue via `mcp__github__get_issue`. If the `ready` label is **not** present, skip:

```
mcp__dotbot__task_mark_done({
  task_id: "{{TASK_ID}}",
  result: { summary: "Skipped — issue #{n} does not have the `ready` label. Implementation not applicable yet." }
})
```

If `issue_driven.build.command` is empty, fail with an actionable message — the user must configure it before proceeding.

## Step 3 — Implement

Following the analysis's implementation plan and the `implement-issue-agent` persona rules:

- Write production code only — **no tests**.
- Match existing code patterns from `task.analysis.files.patterns_from`.
- Reuse helpers/extensions/utilities rather than writing inline logic.
- Methods under ~20 lines; decompose when longer.
- Propagate cancellation/context through async boundaries as the project does.

## Step 4 — Build Verification

Run the configured build command:

```
{issue_driven.build.command}
```

Must succeed with zero warnings. If it fails, fix and re-run — do not leave a broken build.

Run any existing test command to ensure nothing broke.

## Step 6 — Add `needs-qa` Label

Signal to the unit test task that implementation is complete:

```
mcp__github__update_issue({
  owner: "{owner}",
  repo:  "{repo}",
  issue_number: {n},
  labels: [ ...existing_labels, "needs-qa" ]
})
```

Do **not** remove any existing labels (e.g. `ready`). Only append `needs-qa`.

## Step 7 — Mark Task Done

```
mcp__dotbot__task_mark_done({
  task_id: "{{TASK_ID}}",
  result: {
    summary: "Implemented issue #{n}. Build passes, all existing tests green. needs-qa label added; PR will be opened by the next task.",
    deliverables: []
  }
})
```

## Rules

- Never modify `CLAUDE.md` or existing docs.
- **Do not write tests.** That is the job of `Unit Tests` and `Integration Tests` tasks.
- Follow existing code patterns from `task.analysis.files.patterns_from`.

## Applicable Persona

Re-read `{{APPLICABLE_AGENTS}}` (should be `implement-issue-agent`) for code conventions, checklist, and PR template details.
