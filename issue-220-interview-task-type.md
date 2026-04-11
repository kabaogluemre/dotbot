# Issue #220 — Interview Task Type: Implementation Notes

**Status:** Scope clarifications agreed. Read this before starting implementation — do not re-derive decisions.

This document captures the decisions reached during review of GitHub issue #220 ("Add interview task type to the task-runner engine"). It exists so the implementation agent has a single source of truth for every judgment call that would otherwise require guessing or re-litigating.

---

## 1. Business context

Dotbot has two execution engines:

- **Kickstart engine** — used when starting a new project. Supports a multi-round interactive interview loop (`Invoke-InterviewLoop` in `workflows/default/systems/runtime/modules/InterviewLoop.ps1`). This already works end-to-end.
- **Task-runner engine** — executes general multi-step workflows defined in `workflow.yaml`. Each step is a "task" with a type (`script`, `mcp`, `task_gen`, `barrier`, or default prompt).

The task-runner engine has a **HITL (Human-in-the-Loop) parity gap**: it cannot run multi-round interviews. The closest current mechanism is `task_mark_needs_input`, which only supports single-question pauses — no multi-round iteration, no cumulative context, no summary artifact.

**Primary use case being solved (Scenario B):** A workflow gathers requirements from the user **once** via an interview, and **multiple downstream tasks** consume that single summary as shared context. This mirrors what the kickstart engine does at project start, but must also be possible mid-workflow, and more than once per workflow.

**Not the use case (Scenario A):** "Each task runs its own mini-interview before doing its work." That is already partially covered by `task_mark_needs_input` and is not what this issue solves.

**Why introduce an explicit `interview` task type?** Today, whether an interview happens is a **runtime behavior** — Claude decides mid-prompt whether to invoke `task_mark_needs_input`. This makes the workflow graph unpredictable: the designer cannot look at the workflow and say "there is a mandatory user-facing step here." Making `interview` an explicit task type puts the HITL step **on the workflow graph** as a first-class node with deterministic behavior.

---

## 2. The existing code that is being wired up

**Already exists and must be reused as-is (no rewrite):**

- `workflows/default/systems/runtime/modules/InterviewLoop.ps1` — implements `Invoke-InterviewLoop`. Runs the multi-round Q&A loop, emits process activity events, writes three files to `$ProductDir`:
  - `clarification-questions.json`
  - `clarification-answers.json`
  - `interview-summary.md` (the artifact downstream tasks consume)
- Kickstart uses it at `Invoke-KickstartProcess.ps1:132` and `:318`.
- Hard-coded file names are at `InterviewLoop.ps1:46-48`. **These must be parameterized** as part of this work so two interviews in one workflow don't clobber each other's files. The kickstart call site should keep its current behavior via parameter defaults — zero regression.
- Interview uses Opus by default (`$interviewModel = Resolve-ProviderModelId -ModelAlias 'Opus'`). Keep Opus as the default for `type: interview` tasks as well.

**Task-runner dispatch site:** `workflows/default/systems/runtime/modules/ProcessTypes/Invoke-WorkflowProcess.ps1`. Two relevant code regions:

- **Pre-dispatch guard (~line 290):** `if ($taskTypeVal -notin @('prompt'))` — this block marks the task in-progress and skips the analysis phase for non-prompt types. Interview must be added here so it does not get dragged into the Claude analysis path meant for `prompt` tasks.
- **Dispatch switch (lines 325-357):** currently handles `script`, `mcp`, `task_gen`, `barrier`. A new `interview` case goes here.

**Correction to the issue description:** the issue says the dispatch list includes `prompt`. It does not — `prompt` is the default fall-through (no case in the switch; execution happens via the normal analysis + execution path above the switch). `prompt_template` is also normalized to `prompt` at lines 273-289 and falls through the same way.

---

## 3. Manifest schema (from doc section 7.1)

```yaml
tasks:
  - name: "Gather Requirements"
    type: interview
    interview:
      prompt_file: "00-kickstart-interview.md"
      summary_file: "interview-summary.md"
    model: Opus
    outputs: ["interview-summary.md"]
    priority: 0

  - name: "Product Documents"
    type: prompt_template
    depends_on: ["Gather Requirements"]
    priority: 1

  - name: "Clarify Architecture After Research"
    type: interview
    depends_on: ["Research Phase"]
    interview:
      prompt_file: "architecture-interview.md"
      summary_file: "architecture-decisions.md"
    priority: 5
```

Key fields on an `interview` task:
- `interview.prompt_file` — path to the interview prompt template. Resolution order is the same as the existing `prompt_template` task resolution: workflow dir first, then `.bot/` fallback (see `Invoke-WorkflowProcess.ps1:273-289` for the existing pattern to mirror).
- `interview.summary_file` — **filename** the interview summary is written as. This is relative to `product/` (see section 4 below).
- `model` — defaults to `Opus`. Use whatever `Resolve-ProviderModelId` returns for the declared alias.
- `outputs` — standard manifest field, used by validation (not by runtime injection — see section 5).

---

## 4. Output path convention

**Decision: paths are relative to `product/`, matching the kickstart engine.**

- `summary_file: "interview-summary.md"` resolves to `.bot/workspace/product/interview-summary.md`.
- Collision prevention between multiple interview tasks is **the designer's responsibility via the manifest** — each interview declares its own `summary_file`. No automatic per-task-id uniqueness. This is explicit and keeps the schema honest about where files land.
- The doc's second example intentionally uses `architecture-decisions.md` to show this pattern.

**Worktree vs product dir:** The interview summary lives in `product/` (shared), NOT in the per-task git worktree. Rationale: the worktree gets squash-merged and cleaned up after the task completes; downstream tasks run in their own separate worktrees and would never see the file. `product/` is the correct place because the summary is project-level requirements context, not task-local code.

**What to parameterize in `InterviewLoop.ps1`:** Add parameters for the three output paths. Defaults preserve current hard-coded filenames (so kickstart is untouched):

```powershell
function Invoke-InterviewLoop {
    param(
        # ... existing params ...
        [string]$QuestionsFileName = "clarification-questions.json",
        [string]$AnswersFileName   = "clarification-answers.json",
        [string]$SummaryFileName   = "interview-summary.md",
        [string]$InterviewPromptPath  # defaults to recipes\prompts\00-kickstart-interview.md if not set
    )
    # ... use $ProductDir joined with the passed-in filenames ...
}
```

The task-runner dispatch case passes `interview.summary_file` as `$SummaryFileName` and `interview.prompt_file` (resolved) as `$InterviewPromptPath`. The two JSON intermediate files (`questions`/`answers`) should **also** be made per-task to avoid collision — suggest prefixing them with the task id or sanitized task name, but confirm with the review comment thread if uncertain.

---

## 5. Downstream consumption — convention, not injection

**Decision: no automatic output → input injection mechanism is added in this issue.**

How downstream tasks actually see the interview summary:
1. The downstream task is typically a `prompt_template` task.
2. Its prompt template file (e.g. `product-documents.md`) contains a **static reference** to the summary path — e.g. the template literally contains a line like:
   > "Before starting, read `product/interview-summary.md` for user-provided requirements."
3. `depends_on` guarantees the interview completes first.
4. At runtime Claude reads the prompt template, sees the instruction, opens the file.

**Why not build automatic injection?**
- The `outputs` field on tasks exists, but today it is only used by the kickstart engine for file-existence validation (`Invoke-KickstartProcess.ps1:587-589`). The task-runner does not read `outputs` at all — grep returns zero hits in `Invoke-WorkflowProcess.ps1`.
- Making `outputs` drive automatic prompt-context injection would be a framework-wide change affecting all task types, not just interview. That expands the scope by 2-3x and is not required to satisfy this issue.
- The doc (section 7.1) explicitly says "subsequent tasks that depend on the interview can access the summary via **standard file references and prompt injection**" — i.e. the existing convention.
- If a framework-wide I/O binding system is later desired, it should be tracked as its own issue.

**Implementer: do not invent a new injection mechanism here. Rely on the convention above.**

---

## 6. Barrier / parallelism behavior

**Decision: soft barrier via standard `depends_on` semantics.**

- An interview task does **not** globally freeze the workflow.
- Only tasks that have the interview in their `depends_on` chain will wait.
- Independent parallel branches continue executing while the user is answering questions.
- This is what the existing `depends_on` resolver does for every other task type — no special case needed for interview.

Rationale for the soft-barrier choice: if the designer wants other tasks to wait for the interview, they can declare `depends_on`. Forcing a global freeze would override their explicit decisions and surprise workflow authors. If a future issue wants a "hard barrier" interview, it can be added as a new task type or a flag — out of scope here.

---

## 7. UI — two separate pieces of work

The doc (7.1) only lists the design-time editor. Implementation must cover **both**:

### 7.1. Design-time (Studio editor)
- `studio-ui/src/client/components/PropertiesPanel.tsx` — add `interview` to the task type dropdown, and when selected, show form fields for `interview.prompt_file`, `interview.summary_file`. Treat `outputs`, `model`, `depends_on` using the existing field rendering.
- The existing `outputs` form field (already in `PropertiesPanel.tsx:905`) should appear for interview tasks too.

### 7.2. Runtime UI (web UI) — **missing from doc 7.1, but in scope here**
- The kickstart interview panel already exists and already renders questions / collects answers.
- `Invoke-InterviewLoop` already emits `Write-ProcessActivity` events and writes to the same process registry the UI polls. The plumbing is there.
- The missing piece is in `workflows/default/systems/ui/modules/ProductAPI.psm1` — it currently branches to the interview panel for kickstart processes only. Extend that branch (or its equivalent) so task-runner processes whose currently-executing task has `type: interview` also route to the same panel.
- No new panel, no new React components. Reuse everything.

---

## 8. Out of scope — do not implement as part of this issue

1. **Doc 7.2 (Post-Phase Question Detection + adjustment pass)** — this is the other half of full kickstart HITL parity. Separate issue if needed. Do not conflate.
2. **Automatic `outputs` → downstream prompt context injection** — see section 5.
3. **Hard-barrier interview behavior** — see section 6.
4. **Task-id-based auto-unique summary filenames** — see section 4. Designer declares uniqueness via the manifest.
5. **Changes to `task_mark_needs_input`** — it keeps working as-is for single-question pauses during `prompt` tasks. Unrelated.

---

## 9. File modification list

| File | Change |
|---|---|
| `workflows/default/systems/runtime/modules/InterviewLoop.ps1` | Add parameters for output filenames and interview prompt path. Defaults preserve current behavior for kickstart. |
| `workflows/default/systems/runtime/modules/ProcessTypes/Invoke-WorkflowProcess.ps1` | (a) add `interview` to the pre-dispatch guard near line 290; (b) add `interview` case to the switch at lines 325-357 that resolves the prompt path and calls `Invoke-InterviewLoop` with the per-task parameters. |
| Task type ValidateSet (search for the existing set — likely in the manifest loader / schema module) | Add `interview`. |
| `workflows/default/systems/mcp/tools/new-workflow-task/script.ps1` (or equivalent `New-WorkflowTask` tool) | Recognize `interview` as a valid type, accept the `interview` block. |
| `workflows/default/systems/ui/modules/ProductAPI.psm1` | Route task-runner processes whose current task is `type: interview` to the existing kickstart interview panel endpoints. |
| `studio-ui/src/client/components/PropertiesPanel.tsx` | Add design-time form fields for `interview.prompt_file` and `interview.summary_file` when task type is `interview`. |
| `tests/Test-WorkflowManifest.ps1` | Manifest validation test covering `type: interview` with a valid `interview` block. |
| A new or existing Layer 2 component test | Verify dispatch: a mock `interview` task invokes `Invoke-InterviewLoop` (can stub the module) and does not enter the analysis phase. |

---

## 10. Manual test (from the issue, with corrections)

1. Create a test workflow under `workflows/default/recipes/workflows/test-interview/` with a single `type: interview` task pointing at a simple prompt file.
2. Run `pwsh install.ps1` to rebuild `.bot/`.
3. In a test project, run the workflow from the web UI.
4. Verify the interview task pauses and asks the user questions interactively over multiple rounds **via the same interview panel kickstart uses**.
5. Verify the generated summary file is written to `.bot/workspace/product/interview-summary.md`.
6. Add a second `type: prompt_template` task (**not** `type: prompt` — that is not an explicit manifest type) that `depends_on` the interview task. Its prompt template file should reference `product/interview-summary.md`. Verify it runs after the interview and has the summary available when Claude opens it.
7. Add a second interview task later in the workflow with a different `summary_file` (e.g. `architecture-decisions.md`). Verify both interviews run and both summary files are written without collision.
8. Run `pwsh tests/Run-Tests.ps1` (layers 1-3) and confirm no regressions.

---

## 11. Metadata corrections for the issue

- Label: `type:bug` → `type:enhancement`. This is a missing capability, not a defect.
- Description: correct the dispatch type list (see section 2).
- Test step 7: `type: prompt` → `type: prompt_template`.
