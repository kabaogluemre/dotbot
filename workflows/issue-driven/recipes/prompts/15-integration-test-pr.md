---
name: Integration Test PR — Execution
description: Execution phase for Integration Test PR. Analysis (PR read + test-cases.md mapping + additional gap scenarios) handled by 98 with integration-test-pr-agent persona. This prompt implements Phase 1 (mandatory) and Phase 2 (optional) tests.
version: 2.0
---

# Integration Test PR — Execution Phase

> **Repository:** `{{REPOSITORY}}` — use this for every GitHub API / MCP call in this prompt. Do not guess from settings or skill files; the framework resolves this from git remote.

> The analysis phase already ran `98-analyse-task.md` with the `integration-test-pr-agent` persona. It read the PR diff, located `docs/designs/issue-{n}-{slug}/test-cases.md`, mapped every Test Group to test class/method skeletons, and flagged any additional concurrency/edge cases worth covering. The plan is in `task.analysis.test_plan`. **Your job is the execution phase: implement the tests, run them, push to the PR branch.**

## Step 1 — Load the Analysis Context

Call `mcp__dotbot__task_get_context({ task_id: "{{TASK_ID}}" })` and read:

- `task.analysis.test_plan.pre_designed` — mapping from Test Group / test-id to the target project, class, and method signature
- `task.analysis.test_plan.agent_identified` — optional additional scenarios (concurrency, edge cases) the agent proposed
- `task.analysis.pr_number` — linked PR
- `.bot/.control/settings.json` → `issue_driven` — integration-test command, labels

## Step 2 — Pre-flight Skip Check

Fetch the issue. If `needs-integration-tests` label is not present, skip gracefully.

If `issue_driven.test.integration.command` is empty, fail with a configuration error.

Check out the PR branch locally.

## Step 3 — Phase 1: Implement Pre-Designed Test Cases (MANDATORY)

For each entry in `task.analysis.test_plan.pre_designed`:

- Each Test Group maps to a test class (or logical grouping within a class).
- Each `{Letter}{Number}` (A1, A2, B1) maps to a test method.
- Setup steps → arrange code; Action → act; `Assert:` lines → assertion code.
- Convert natural-language test names to the project's convention (e.g. `MethodName_Scenario_ExpectedResult`).
- Match existing integration test patterns in the project (base class, fixtures, collection attributes, assertion library).

If `test-cases.md` does not exist (analysis couldn't find pre-designed cases), record a warning in the PR summary and move to Phase 2.

## Step 4 — Phase 2: Agent-Identified Additions (OPTIONAL)

For each entry in `task.analysis.test_plan.agent_identified`:

- Only add tests that are **not duplicates** of pre-designed cases.
- Focus on concurrency scenarios, edge cases from reading actual PR code, and failure modes the design missed.

## Step 5 — Verify & Comment

1. Run `{issue_driven.test.integration.command}` — all tests must pass.
2. Post a summary PR comment:

   ```markdown
   ## Integration Tests Added

   - **Pre-designed** ({N} from `test-cases.md`): Groups {letters}
   - **Agent-identified** ({M} additional): {short description}

   Total: {N+M} integration tests. All passing.
   ```

## Step 6 — Label Transition (MANDATORY)

`mcp__github__update_issue` on the **issue**: remove `needs-integration-tests`. Confirm in the summary comment.

## Step 7 — Mark Task Done

```
mcp__dotbot__task_mark_done({
  task_id: "{{TASK_ID}}",
  result: {
    summary: "Implemented {N} pre-designed + {M} agent-identified integration tests. Label needs-integration-tests removed.",
    deliverables: ["{test-file-paths}", "PR comment: integration test summary"]
  }
})
```

## Rules

- Push to the **same PR branch** — never `main`.
- **Integration tests only** — no unit tests, no E2E, no mocks-only tests.
- Match the project's existing patterns exactly.
- If you find a bug while implementing tests, post a PR comment with reproduction steps — do not modify production code.
- Phase 1 is mandatory; Phase 2 is optional. Never duplicate pre-designed cases.
- Label transition is mandatory.

## Applicable Persona

Re-read `{{APPLICABLE_AGENTS}}` (should be `integration-test-pr-agent`) for test layer selection (service / CQRS / API) and scenario design principles.
