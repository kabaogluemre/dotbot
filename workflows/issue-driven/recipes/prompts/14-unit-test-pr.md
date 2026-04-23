---
name: Unit Test PR — Execution
description: Execution phase for Unit Test PR. Analysis (PR read + mandatory gap analysis + severity classification) handled by 98 with unit-test-pr-agent persona. This prompt posts the gap report as a PR comment and writes tests if no CRITICAL gaps.
version: 2.0
---

# Unit Test PR — Execution Phase

> **Repository:** `{{REPOSITORY}}` — use this for every GitHub API / MCP call in this prompt. Do not guess from settings or skill files; the framework resolves this from git remote.

> The analysis phase already ran `98-analyse-task.md` with the `unit-test-pr-agent` persona. It read the PR diff, cross-referenced against AC / CLAUDE.md / design doc / test-cases.md, and classified every gap as CRITICAL or HIGH. The gap report is in `task.analysis.gap_report`. **Your job is the execution phase: post the report as a PR comment, then write tests if no CRITICAL gaps.**

## Step 1 — Load the Analysis Context

Call `mcp__dotbot__task_get_context({ task_id: "{{TASK_ID}}" })` and read:

- `task.analysis.gap_report.critical` — array of CRITICAL gap entries
- `task.analysis.gap_report.high` — array of HIGH gap entries
- `task.analysis.pr_number` — the linked PR number (resolved from `kickstart-prompt.txt` and `Closes #N`)
- `task.analysis.test_plan` — the planned unit tests (which classes/methods, edge cases to cover)
- `.bot/.control/settings.json` → `issue_driven` — unit-test command, labels

## Step 2 — Pre-flight Skip Check

Fetch the issue. If the `needs-qa` label is not present, skip gracefully.

If `issue_driven.test.unit.command` is empty, fail with a configuration error.

Check out the PR branch locally.

## Step 3 — Post the Gap Analysis Report (MANDATORY)

Post a **separate PR comment** via `mcp__github__add_issue_comment` (on the PR issue, not the issue):

```markdown
## Gap Analysis Report

**Documents reviewed:** design.md, CLAUDE.md, issue #{n}, test-cases.md

### CRITICAL
{list from task.analysis.gap_report.critical, or "- None"}

### HIGH
{list from task.analysis.gap_report.high, or "- None"}

**Summary:** {N} critical, {M} high gaps found.
```

## Step 4 — Handle CRITICAL Gaps

If `task.analysis.gap_report.critical` has entries:

1. `mcp__github__update_issue` — add `has-gaps` to the **issue**. Do NOT remove `needs-qa`.
2. Post a follow-up PR comment: "QA is blocked by {N} CRITICAL gaps. Address them, then remove `has-gaps` to re-run QA."
3. Mark task done with a note — do NOT write tests:

   ```
   mcp__dotbot__task_mark_done({
     task_id: "{{TASK_ID}}",
     result: { summary: "Blocked — {N} CRITICAL gaps found. has-gaps label added." }
   })
   ```

Stop here.

## Step 5 — Write Unit Tests (only if no CRITICAL)

Following the test plan in `task.analysis.test_plan`:

- Mock all external deps (DB, HTTP, queues, file system).
- Match the project's existing unit test patterns (framework, assertions, mocking library).
- Test naming: `MethodName_Scenario_ExpectedResult` or the project's equivalent.
- Cover the edge-case checklist from the agent persona.

**Do NOT write:** integration tests, E2E tests, tests hitting real infra, tests that only verify mock invocations.

## Step 6 — Verify & Comment

1. Run `{issue_driven.test.unit.command}` — all tests must pass.
2. Post a summary PR comment: `Added {X} unit tests covering {areas}.`

## Step 7 — Label Transition (MANDATORY)

`mcp__github__update_issue` on the **issue** (not the PR):

- Remove `needs-qa`.
- Add `needs-integration-tests`.

Confirm the transition in the summary comment.

## Step 8 — Mark Task Done

```
mcp__dotbot__task_mark_done({
  task_id: "{{TASK_ID}}",
  result: {
    summary: "Added {X} unit tests. Gap analysis posted ({M} HIGH). Labels transitioned needs-qa → needs-integration-tests.",
    deliverables: ["{test-file-paths}", "PR comment: gap analysis", "PR comment: test summary"]
  }
})
```

## Rules

- Push to the **same PR branch** — never `main`.
- Match existing test patterns.
- If you find a bug, post a PR comment with repro steps — do not modify production code.
- **Unit tests only** — no integration, no E2E, no mocks-only tests.
- Gap analysis is **mandatory** — always post the comment, even if both sections are empty.
- Label transitions are **mandatory**.

## Applicable Persona

Re-read `{{APPLICABLE_AGENTS}}` (should be `unit-test-pr-agent`) for gap severity definitions and test conventions.
