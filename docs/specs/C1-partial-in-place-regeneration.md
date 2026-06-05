# Title

C1 — Partial / In-Place Regeneration: add a "Revise" review verb that preserves prior output and injects reviewer feedback

---

# Labels (suggested)

`enhancement` · `priority:high` · `area:runtime` · `area:ui` · `area:mcp`

---

# Description

## Summary

When a task in `needs-review` is rejected, dotbot discards the worktree and branch and regenerates from an empty base. Reviewer feedback is persisted to `extensions.review.feedback[]` but is **never injected** into the execution prompt, so the next attempt starts blind. This makes targeted, iterative corrections impossible — operators get a full regeneration instead of a fine-tuned fix.

This issue introduces a **third review verb, "Revise"**, alongside the existing Approve and Reject, and wires reviewer feedback into the prompt assembler.

- **Approve & merge** → `done` (unchanged)
- **Reject & restart** → discard worktree + branch, regenerate from scratch (**unchanged** — this is the explicit full-regeneration path)
- **Revise** *(new)* → preserve worktree + branch + uncommitted edits, return to `todo`, inject accumulated feedback, perform a targeted in-place correction

## Problem statement

When a task is re-run after rejection, dotbot discards the prior output and regenerates from an empty worktree. Feedback provided after a run is silently ignored — dotbot produces a full regeneration rather than applying targeted corrections to the existing artifact.

**Verified root cause (`main`):**

- `Reset-TaskWorktree` (`src/runtime/Modules/Dotbot.Worktree/Dotbot.Worktree.psm1:1897-1913`) runs `git worktree remove --force` + `git branch -D` + removes the worktree-map entry on every reject. Prior work is destroyed.
- Feedback **is** persisted: appended to `extensions.review.feedback[]` as `{comment, what_was_wrong, timestamp}`, accumulating across cycles (`src/mcp/tools/task-submit-review/script.ps1:50-60`).
- But `Build-TaskPrompt` (`src/runtime/Modules/Dotbot.Task/Dotbot.Task.psm1:34-189`) and the `_FlattenTask` projection that feeds it (`src/runtime/Modules/Dotbot.Process/Dotbot.Process.psm1:373-413`) **never read `extensions.review.feedback`**. No `{{REVIEWER_FEEDBACK}}` placeholder exists in any prompt template.
- The reject logic is **duplicated** across `src/mcp/tools/task-submit-review/script.ps1` and `Submit-TaskReview` in `src/ui/modules/TaskAPI.psm1` — both must change identically, so they should be unified.

## User story

As a delivery team member, I want dotbot to retain my prior artifact as an editable base when I re-run a task, so that only the sections that need to change are updated and my stable, reviewed content is not discarded.

## Acceptance criteria

- [ ] A task can be re-run with its previous output available as an editable base (**Revise** preserves the worktree + branch)
- [ ] Only sections targeted by reviewer feedback are regenerated; unchanged sections are preserved (prompt mandates targeted corrections over rewrite)
- [ ] Reviewer feedback accumulated across multiple cycles is injected and honoured (`{{REVIEWER_FEEDBACK}}` block, "you MUST address each item")
- [ ] The existing full-regeneration path remains available when explicitly requested (**Reject & restart** is unchanged)
- [ ] Manual edits made between runs are preserved unless explicitly in scope of the re-run (Revise never calls `Reset-TaskWorktree`, so uncommitted edits survive)

## Evidence (pilot survey)

> *"It was very hard to have dotbot make specific changes once the initial run had been done and it was poor at fine tuning the outputs"* — R2, Solution Architect
> *"I provided a clear list of issues. After dotbot was executed, none of these problems were resolved"* — R24, Dotbot Team Member
> *"Dotbot needs to learn from the current BS work. We need to define a feedback loop process so that where there are manual updates to code we feed it back again"* — R10, AI Delivery Lead

---

## Proposed fix

### Model: three review verbs

| Verb | Behaviour | Worktree | Feedback | ACs |
|---|---|---|---|---|
| **Approve & merge** | merge → `done` | removed after merge | — | (existing) |
| **Reject & restart** | discard + `todo`, fresh regen | **`Reset-TaskWorktree` (deleted)** | persisted + injected | AC4 |
| **Revise** *(new)* | preserve + `todo`, targeted fix | **preserved** (branch + files) | persisted + injected | AC1, AC2, AC3, AC5 |

- MCP decision value: `revise` · `extensions.review.status`: `revision_requested`
- Feedback injection applies to **both** reject and revise (even a fresh regen benefits from knowing what was wrong). Worktree preservation is **revise-only**.
- The **Revise** path skips re-analysis and goes straight to execution with feedback injected (no `98-analyse-task.md` change needed).

### File-by-file change list

**1. Surface feedback onto the task object** — `src/runtime/Modules/Dotbot.Process/Dotbot.Process.psm1` (~line 407, in `_FlattenTask`):
```powershell
review_feedback = if ($Content.extensions.review) { $Content.extensions.review.feedback } else { $null }
```

**2. Inject into the prompt** — `src/runtime/Modules/Dotbot.Task/Dotbot.Task.psm1` (~line 168, mirroring the `questions_resolved` pattern): build a `{{REVIEWER_FEEDBACK}}` block from `$Task.review_feedback` with a strong mandate — *"You MUST address each item below. The worktree already contains your prior attempt — make targeted corrections per this feedback; do not rewrite untouched sections."*

**3. Template placeholder** — add `{{REVIEWER_FEEDBACK}}` to:
- `content/prompts/99-autonomous-task.md` (under the "User Decisions" block in §Task Details)
- `content/workflows/start-from-jira/prompts/99-autonomous-task.md`
- *(A missing placeholder is a harmless no-op `-replace`, so custom/project templates degrade gracefully.)*

**4. Shared review-decision helper (de-dup)** — new `Resolve-TaskReviewDecision` in `Dotbot.Task`, holding the three-way logic in one place:
- `revise` → append feedback, set `extensions.review.status = revision_requested`, transition `todo`, **do NOT call `Reset-TaskWorktree`** (worktree + branch + map entry preserved → next pickup hits the "worktree already exists" reuse path at `Dotbot.Worktree.psm1:1335`).
- `reject` → existing behaviour (`Reset-TaskWorktree`).

**5. MCP tool** — `src/mcp/tools/task-submit-review/script.ps1`: add a `decision` enum param (`approve` | `reject` | `revise`); keep `approved` bool for backward compatibility (`true`→approve, `false`→reject). Call the shared helper. Add `decision` to `src/mcp/tools/task-submit-review/metadata.json`.

**6. UI backend** — `src/ui/modules/TaskAPI.psm1` (`Submit-TaskReview`, line 620): remove the duplicated reject block, call the shared helper. Pass `decision` through the route at `src/ui/server.ps1:1705`.

**7. UI frontend** — `src/ui/static/modules/actions.js`:
- add a third button at line 1382: `<button class="ctrl-btn revise-review">Revise</button>`
- wire it next to the existing handlers at lines 851–857
- refactor `handleReviewAction(btn, approved)` (line 1390) to take a `decision` string instead of a boolean; require the comment fields for **Revise** as well as Reject.

### AC coverage matrix

| AC | Delivered by |
|---|---|
| AC1 — prior output as editable base | Revise preserves the worktree (#4) |
| AC2 — only targeted sections regenerated | #2/#3 "targeted corrections" mandate + preserved files |
| AC3 — accumulated feedback injected & honoured | #1 + #2 + #3 |
| AC4 — full-regen explicitly available | "Reject & restart" unchanged |
| AC5 — manual edits preserved | Revise never calls `Reset-TaskWorktree` → uncommitted edits survive |

### Edge cases (all handled)

- **Worktree deleted externally** → `New-TaskWorktree` recreates from the preserved branch (`Dotbot.Worktree.psm1:1392`); if the branch is also gone, it starts clean from base (graceful degradation).
- **Multi-cycle** → feedback array accumulates; all entries injected, timestamp-ordered.
- **Go mode** has no separate analysis phase (`Invoke-WorkflowProcess.ps1:1596`) → Revise naturally re-enters execution in a single session.

### Test plan (closes current gaps)

- `src/mcp/tools/task-submit-review/` has **no `test.ps1`** today — add: revise appends feedback + preserves branch; reject discards.
- Unit: `Build-TaskPrompt` injects feedback when present, empty substitution otherwise.
- Layer-3 mock-Claude: full revise → re-run cycle proving prior files persist and feedback reaches the prompt.
- Update `tests/Test-Structure.ps1:1353` to assert the new `Resolve-TaskReviewDecision` export.

### Out of scope / boundaries

- Selective workflow re-run across tasks (**C2**), back-edges/loops (**C3**), and per-task stuck-recovery reset (**S2**) are separate items — this issue covers single-task review-driven in-place regeneration only.
