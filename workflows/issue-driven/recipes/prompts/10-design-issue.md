---
name: Design Issue — Execution
description: Execution phase for the Design Issue task. Analysis (context gathering + gap analysis + user interview) was handled by 98-analyse-task with the design-issue-agent persona. This prompt consumes that analysis and writes the deliverable.
version: 2.0
---

# Design Issue — Execution Phase

> **Repository:** `{{REPOSITORY}}` — use this for every GitHub API / MCP call in this prompt. Do not guess from settings or skill files; the framework resolves this from git remote.

> The analysis phase already ran `98-analyse-task.md` with the `design-issue-agent` persona. It fetched the issue, identified gaps via the agent's gap-analysis rules, asked the user for approval via `task_mark_needs_input`, and stored the answers as `questions_resolved` on the task. **Your job is the execution phase: produce the design deliverable.**

## Pre-conditions (fail fast)

This prompt runs ONLY after `98-analyse-task.md` has completed. The separation is strict — never run analysis logic here. Validate all of the following via `task_get_context` before Step 1:

- `task.status == "analysed"` — analysis phase finished successfully
- `task.analysis.skipped` is not `true` — if the analysis marked the task skipped (e.g. missing `needs-design` label), honor it via `task_mark_done` with the skip reason
- `task.analysis.issue_number` exists — resolved from `kickstart-prompt.txt` during analysis
- `task.analysis.design_plan` exists — the agreed approach, files, data changes, edge cases
- For every entry in `task.analysis.gap_report` flagged `needs_clarification`: a matching answer exists in `task.questions_resolved`

If any invariant is missing, call:

```
mcp__dotbot__task_mark_failed({
  task_id: "{{TASK_ID}}",
  reason: "Execution pre-condition failed: <specific missing field>. Phase 1 analysis was incomplete — re-run the task so 98-analyse-task.md can finish gathering context."
})
```

## What this prompt MUST NOT do

- Fetch the issue body / comments to re-derive requirements. Use `task.analysis` — it already captured everything.
- Compute gaps, conflicts, assumptions, or edge cases. Those live in `task.analysis.gap_report`.
- Call `mcp__dotbot__task_mark_needs_input` or `AskUserQuestion`. The interview window closed in Phase 1. Missing information is a failure, not a prompt to ask again.
- Re-read `CLAUDE.md` / architecture docs for analytic purposes. (Reading them to echo rules into the design body is fine.)
- Introduce new design decisions beyond `design_plan` + `questions_resolved`. If something is undecided, the analysis was incomplete — fail via `task_mark_failed`.

The only GitHub API call before Step 2's skip check should be the single `mcp__github__get_issue` call that verifies the label is still `needs-design` (guard against external state change since analysis).

## Step 1 — Load the Analysis Context

Call `mcp__dotbot__task_get_context({ task_id: "{{TASK_ID}}" })` and read:

- `task.analysis` — the analysis object produced by 98 (entities, files, gap findings, implementation plan)
- `task.questions_resolved` — user answers to the interview questions (clarifications on gaps)
- `.bot/.control/launchers/kickstart-prompt.txt` — the raw user input (issue number)
- `.bot/.control/settings.json` → `issue_driven` — repo, branch prefix, labels

Resolve the issue number from the kickstart prompt. Extract the issue slug from `task.analysis` (or compute from the issue title).

## Step 2 — Pre-flight Skip Check

Fetch the issue via `mcp__github__get_issue`. If the `needs-design` label is **not** present, stop and exit cleanly:

```
mcp__dotbot__task_mark_done({
  task_id: "{{TASK_ID}}",
  result: {
    summary: "Skipped — issue #{n} does not have the `needs-design` label (current: {labels}). Design phase not applicable."
  }
})
```

Do not create files, branches, or comments. The next task in the pipeline will also check its own label.

## Step 3 — Write the Design

Render `task.analysis.design_plan` + `task.questions_resolved` into `docs/designs/issue-{issue-number}-{slug}/design.md` (max 500 lines). Each section of the design is a direct translation of a field in `design_plan`:

| Design section | Source field |
|---|---|
| Approach | `design_plan.approach` |
| Files to Create/Modify | `design_plan.files` |
| Data Changes | `design_plan.data_changes` |
| API Contract | `design_plan.api_contract` |
| Concurrency & Isolation | `design_plan.concurrency` |
| Edge Cases | `design_plan.edge_cases` + clarifications from `questions_resolved` |
| Testing Plan | `design_plan.testing` |
| Complexity | `design_plan.complexity` |

If a field is empty, mirror that in the design (write "N/A" — do not fabricate content). Required sections:

- Approach
- Files to Create/Modify
- Data Changes
- API Contract
- Concurrency & Isolation
- Edge Cases
- Testing Plan
- Complexity (S/M/L)

Follow the template in `.claude/agents/design-issue-agent/AGENT.md` exactly. The persona was already applied during analysis; re-read it here to ensure the execution also follows its rules.

## Step 4 — GitHub Updates

Via `mcp__github__*` against `issue_driven.repository`:

1. `mcp__github__update_issue` — remove `needs-design`, add `ready`.
2. `mcp__github__add_issue_comment`:

   ```markdown
   ## ✅ Technical Design Complete

   Design document: [`docs/designs/issue-{n}-{slug}/design.md`](../blob/main/docs/designs/issue-{n}-{slug}/design.md)

   **Branch:** `{branch_name}`
   **Complexity:** {S/M/L}

   ### Summary
   {1-2 sentence summary from the analysis}
   ```

## Step 6 — Mark Task Done

```
mcp__dotbot__task_mark_done({
  task_id: "{{TASK_ID}}",
  result: {
    summary: "Designed issue #{n}. Branch {branch_name} created, design.md pushed, labels transitioned.",
    deliverables: ["docs/designs/issue-{n}-{slug}/design.md", "{branch_name}"]
  }
})
```

## Rules

- Every commit ends with `[skip ci]`.
- Max 500 lines per design document.
- Never modify `CLAUDE.md` or existing docs.
- Do not re-run gap analysis — the user already answered during the analysis phase. Trust `questions_resolved`.
- If `questions_resolved` is empty (no interview was required), proceed with the design as analyzed.
- Do not write test code — that's the job of `Design Test Cases`, `Unit Test PR`, and `Integration Test PR`.
- If execution fails midway (e.g. GitHub API 5xx), call `task_mark_failed` with the specific step that failed. Do not silently skip steps — the dashboard needs to see the task halted for manual recovery.

## Applicable Persona

Re-read `{{APPLICABLE_AGENTS}}` (should be `design-issue-agent`) and follow its design template, line limits, commit conventions, and label transition rules.
