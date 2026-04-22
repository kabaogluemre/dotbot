---
name: Design Test Cases — Execution
description: Execution phase for the Design Test Cases task. Analysis (context + 6-angle scenario analysis + user approval) handled by 98 with design-test-cases-agent persona. This prompt writes test-cases.md.
version: 2.0
---

# Design Test Cases — Execution Phase

> The analysis phase already ran `98-analyse-task.md` with the `design-test-cases-agent` persona. It read the issue + design doc, performed a 6-angle scenario analysis (happy path, real-life production, failure & recovery, isolation, edge cases, data integrity), presented proposed Test Groups to the user via `task_mark_needs_input`, and stored approved test groups in `questions_resolved`. **Your job is the execution phase: write `test-cases.md`.**

## Step 1 — Load the Analysis Context

Call `mcp__dotbot__task_get_context({ task_id: "{{TASK_ID}}" })` and read:

- `task.analysis` — approved Test Groups (letters, names, test-per-group counts) plus coverage matrix
- `task.questions_resolved` — any adjustments the user made during the interview
- `.bot/.control/launchers/kickstart-prompt.txt` — issue number
- `.bot/.control/settings.json` → `issue_driven` — repo, branch prefix

Resolve the issue number and slug.

## Step 2 — Pre-flight Skip Check

Check for the design doc at `docs/designs/issue-{n}-{slug}/design.md`. If it does not exist, skip gracefully:

```
mcp__dotbot__task_mark_done({
  task_id: "{{TASK_ID}}",
  result: { summary: "Skipped — no design doc found at docs/designs/issue-{n}-{slug}/design.md. Run Design Issue first." }
})
```

If `test-cases.md` already exists and the user did not explicitly approve overwrite during the interview, skip.

## Step 3 — Write test-cases.md

Write `docs/designs/issue-{n}-{slug}/test-cases.md` using the approved Test Groups from the analysis:

```markdown
# Test Cases — Issue #{issue-number} {title}

> Linked design: [design.md](./design.md)
> Linked GitHub issue: #{issue-number}

## Test Group A — {Descriptive Name from analysis}

**A1. {Natural-language test name}**
- {Setup / precondition}
- {Action}
- Assert: {concrete expected outcome — value, state, status code}
- Assert: {another}

**A2. {Next test}**
- ...

## Test Group B — {Name}

...

<!-- Coverage Matrix:
AC-1 (description) → A1, A3, B2
AC-2 (description) → B1, C1
-->
```

### Format rules (from the design-test-cases-agent persona)

- Group letters: sequential uppercase (A, B, C, ...).
- Test numbering: `{Letter}{Number}` (A1, A2, B1).
- Natural-language test names — not code syntax.
- Setup → Action → Assert: lines, concrete and verifiable.
- No vague assertions like "Assert: works correctly". Require values, states, or codes.
- Every test traces to at least one AC via the Coverage Matrix comment.

## Step 4 — Mark Task Done

```
mcp__dotbot__task_mark_done({
  task_id: "{{TASK_ID}}",
  result: {
    summary: "Wrote {N} test groups ({M} total test cases) covering every acceptance criterion.",
    deliverables: ["docs/designs/issue-{n}-{slug}/test-cases.md"]
  }
})
```

## Rules

- Read-only on source code — never modify source files.
- No test code — this is design only; implementation is `Integration Test PR`.
- No duplication — analysis phase checked existing tests; respect its findings.
- Every test traces to an AC.
- Commit ends with `[skip ci]`.

## Applicable Persona

Re-read `{{APPLICABLE_AGENTS}}` (should be `design-test-cases-agent`) for format details.
