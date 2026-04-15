# Kickstart Engine Retirement — Parity-Gap Analysis

**Status:** Draft for review
**Author:** @kabaogluemre
**Tracks issue:** [#259](https://github.com/andresharpe/dotbot/issues/259)
**Date:** 2026-04-15

---

## 1. Executive Summary

Repo owner (@andresharpe) requested on issue #259:

> *"I want to remove all kickstart code (and rename the workflows). The new task runner needs to be upgraded first with legacy kickstart features. Want to do an analysis and we can review before implementing?"*

This document is that analysis. It inventories every capability the **kickstart engine** (`Invoke-KickstartProcess.ps1`) provides that the **task-runner engine** (`Invoke-WorkflowProcess.ps1` + `Invoke-ExecutionProcess.ps1`) does not, maps each gap to existing open issues, lists the kickstart-specific code surface that would need to be removed or rerouted, and proposes a sequencing plan for retirement.

**Top-level finding.** The two engines are not interchangeable today. Kickstart retains six capabilities that task-runner cannot reproduce, plus eight more whose fate (port vs. deprecate) requires an explicit decision. Two task-runner-specific robustness gaps (#213, #214) must also be addressed before the task-runner becomes the sole engine. None of the gaps are individually large, but their interactions (especially interview + clarification + outputs validation) form the critical path.

**Recommended sequencing** (detail in §6):

1. Fix engine-agnostic foundations (Turkish-I locale, `task_gen` LLM routing).
2. Port the six P0 parity features, in dependency order (#220 → #221 → outputs validation → commit without worktree → UI engine-awareness → task-runner robustness).
3. Decide P1 items with the owner — port, redesign, or deprecate.
4. Remove the kickstart engine.
5. Rename `kickstart-*` workflows.

Nothing in this document assumes any of the above is final. Each item calls out what needs to be decided and who should decide it.

### 1.1 Summary Tables

**Priority legend:** P0 = mandatory port before retirement · P1 = port / redesign / deprecate decision required · P2 = standalone, retirement-adjacent · R = task-runner robustness (not parity, but blocking).

#### P0 — Mandatory ports (6)

| # | Feature | Tracked by | Recommendation |
|---|---------|------------|----------------|
| P0-1 | `type: interview` task dispatch (invokes `Invoke-InterviewLoop`) | #220, #219 | Port |
| P0-2 | Post-phase clarification Q&A loop (ask → answer → adjust) | #221, #219 | Port (after P0-1) |
| P0-3 | Per-phase direct commits (`commit.paths`, `commit.message`) without worktree | Backlog #6 | Port |
| P0-4 | Declarative outputs validation (`outputs`, `outputs_dir`, `min_output_count`) | #255, #256 | Port |
| P0-5 | `task_gen` LLM routing when `workflow:` is set | #263 (PR #264) | Port |
| P0-6 | UI must become engine-aware (retire `/api/kickstart/status`, rewrite Resume) | #259, #241, #239, #198 | Port |

#### P1 — Decision required (8)

| # | Feature | Tracked by | Used by | Recommendation |
|---|---------|------------|---------|----------------|
| P1-1 | `Resume -FromPhase` semantics | #241, #198 | UI Resume button | **Redesign** (replace with `-Continue`) |
| P1-2 | `skip_phases` preflight UI | — | Kickstart modal | **Deprecate** *or* **Redesign** as per-task skip UI (pick tasks to skip pre-launch) |
| P1-3a | `auto_workflow` form param | — | Kickstart modal | **Remove** — dead parameter, never read by runtime (no decision needed) |
| P1-3b | `needs_interview` form param | — | Kickstart modal | **Deprecate** (manifest decides — interview task present = interview runs) *or* **Redesign** as runtime skip flag for interview-typed tasks |
| P1-4 | `files` uploads — saved to `briefing/` but never injected into task-runner prompts | — | Kickstart modal | **Port** (wire injection into prompts, see P1-6) |
| P1-5 | YAML front-matter metadata injection (`front_matter_docs`) | — | Kickstart LLM phases | **Port** |
| P1-6 | Product briefing context injection (`briefing/` → all LLM phases) | — | Kickstart LLM phases | **Port** (unlocks P1-4) |
| P1-7 | Interview summary global injection | — | Kickstart LLM phases | **Port** (with P0-1, by convention) |
| P1-8 | Heartbeat polling of child processes | — | Kickstart supervising task-runner | **Deprecate** (obsolete post-retirement) |

#### P2 — Standalone / adjacent (4)

| # | Item | Dependency on retirement |
|---|------|--------------------------|
| P2-1 | Turkish-I locale bug (`.ToUpper()` without `InvariantCulture`) | **Fix first** — affects both engines, new code inherits the bug otherwise |
| P2-2 | Workflow tab prompt file loader `shortType` bug | Independent, fix anytime |
| P2-3 | Workflow rename (`kickstart-*` → `*`) | **Last step** of the retirement sequence |
| P2-4 | Task-runner schema honesty — dead fields (`env`, `timeout`, `retry`, `max_concurrent`) | **Decide during retirement** — either wire up or drop from schema; leaving them parsed-but-ignored after kickstart is gone misleads manifest authors |

#### R — Task-runner robustness (2, blocking)

| # | Defect | Tracked by | Why blocking |
|---|--------|------------|--------------|
| R1 | Task killed mid-`analysing` is not resumed | #214 | Task-runner will be the sole engine after retirement — resume gaps become load-bearing |
| R2 | Task-runner continues after non-optional task failure | #213 | Same reason — no fallback engine to catch failure semantics |

#### Already ported (verified)

The following might initially look like gaps but **task-runner already supports them** — no action required:

| Feature | Task-runner location | Notes |
|---------|----------------------|-------|
| `type: barrier` dispatch | `Invoke-WorkflowProcess.ps1:427-431` | No-op case identical to kickstart's (`Invoke-KickstartProcess.ps1:227-230`). |
| `post_script:` field | `Invoke-WorkflowProcess.ps1:445, 961` + `post-script-runner.ps1` + `workflow-manifest.ps1:329` | Task-runner has a full port including `needs-input` escalation on failure. |
| Per-phase/-task script resolution with workflow-dir + `systems/runtime/` fallback | `Invoke-WorkflowProcess.ps1:367-382` | Fallback chain identical to kickstart; applies to `script`, `task_gen`, `prompt_template`. |
| `condition:` field evaluation (gitignore-style path patterns) | `systems/mcp/tools/task-get-next/script.ps1:97-114` | Condition is evaluated when the MCP `task_get_next` tool picks a task. Non-matching tasks are moved to `skipped` with `skip_reason = 'condition-not-met'`. Same semantic as kickstart's phase-level skip, just at task-selection time. |

#### At-a-glance counts

| Bucket | Count | Meaning |
|--------|------:|---------|
| P0 | 6 | Mandatory ports before kickstart can be removed |
| P1 (port) | 4 | Port with moderate effort (P1-4, P1-5, P1-6, P1-7) |
| P1 (redesign) | 1 | Semantics change on retirement (P1-1) |
| P1 (deprecate **or** redesign — owner choice) | 2 | Two-option items (P1-2, P1-3b) |
| P1 (remove — dead code) | 1 | P1-3a (`auto_workflow`) — runtime never reads it |
| P1 (deprecate) | 1 | P1-8 (kickstart-supervisor heartbeat) |
| P2 | 4 | Standalone, retirement-adjacent |
| R | 2 | Task-runner robustness, blocking |
| **Total work items** | **21** | Spread across 5 phases (see §6) |

---

## 2. Context

### 2.1 The two engines today

dotbot currently ships two execution engines that dispatch from `launch-process.ps1`:

| Engine | Entry point | Scope |
|--------|-------------|-------|
| **Kickstart** | `-Type kickstart` → `Invoke-KickstartProcess.ps1` | Manifest-driven, phase-by-phase pipeline. Runs directly in the main repo. Orchestrates LLM invocations, scripts, interviews, and Q&A loops per phase. |
| **Task-runner** | `-Type task-runner` → `Invoke-WorkflowProcess.ps1` (+ `Invoke-ExecutionProcess.ps1`) | Queue-driven. Picks tasks from `.bot/workspace/tasks/todo/`, analyses/executes each with per-task worktree isolation, supports slot concurrency. |

Both engines read the same `workflow.yaml` manifest shape, but dispatch different parts of it. The kickstart engine enumerates `phases:` and runs each; the task-runner enumerates `tasks:` and runs each.

---

## 3. Parity Gap Matrix

Each gap is classified by urgency:

- **P0** — must be ported before kickstart can be removed.
- **P1** — requires an explicit port / redesign / deprecate decision.
- **P2** — standalone items, retirement-adjacent but not blocking.

### 3.1 P0 — Mandatory ports

#### P0-1. Interview task type (`type: interview`)

**Kickstart:** `Invoke-KickstartProcess.ps1:305-321` dispatches `type: interview` phases into `Invoke-InterviewLoop` (`InterviewLoop.ps1`), which runs a multi-round Q&A with the user, writes `clarification-questions.json` when more input is needed, and produces `interview-summary.md` on completion.

**Task-runner:** No dispatch case exists. Two edits needed:
- `Invoke-WorkflowProcess.ps1:290` — add `interview` to the pre-dispatch guard so the analysis phase is skipped.
- Switch at `Invoke-WorkflowProcess.ps1:325-357` — add a case that invokes `Invoke-InterviewLoop`.

The existing `InterviewLoop.ps1` hardcodes its three output filenames at `InterviewLoop.ps1:46-48` under `$ProductDir`. These must be parameterised so task-runner can pass per-task filenames (see #220 follow-up for schema).

**Tracked by:** #220, #219 (symptom).

#### P0-2. Post-phase clarification Q&A loop

**Kickstart:** `Invoke-KickstartProcess.ps1:339-572` — after any LLM phase, kickstart checks for `clarification-questions.json`. If present, it enters an ask → answer → adjust loop: sends questions to the user (UI + Teams), records answers, runs an adjustment pass over the phase's outputs using `adjust-after-answers.md`, then cleans up.

**Task-runner:** Zero references to `clarification-questions` exist in `Invoke-WorkflowProcess.ps1`. The feature would need to be rebuilt from scratch (~230 lines adapted from kickstart).

Key decisions already documented on #221:
- **Adjustment is inline, not a follow-up task** — same pattern as kickstart (`Invoke-KickstartProcess.ps1:529-572`).
- **`pending_questions[]` as an array**, not scalar. Schema migration touches `task-mark-needs-input/script.ps1`, `Invoke-WorkflowProcess.ps1:929-935`, the task-detail UI panel, and `NotificationClient.psm1`.
- **Per-task `clarification_file:` path in the manifest** (not a shared fixed path — parallel tasks would collide).
- **Detection is opt-in** — only tasks declaring `clarification_file:` get post-run detection.
- **Interview tasks must be excluded** from detection to avoid loops.
- **Consolidate the Teams Q&A orchestration loop, don't copy it** — `NotificationClient.psm1` already exposes `Send-TaskNotification` / `Get-TaskNotificationResponse` / `Resolve-NotificationAnswer` primitives, and both existing callers use them. What's duplicated is the orchestration *around* those primitives (~80 lines in each): batch-send foreach → timeout-bounded polling loop → per-question answered/unanswered tracking → "all answered" aggregation → write merged answers file. The pattern lives in `InterviewLoop.ps1:140-222` and `Invoke-KickstartProcess.ps1:399-479`. #221's follow-up already plans to extend `Send-TaskNotification` for arrays (send side). The port must also extract the polling/aggregation loop into a shared helper (e.g. `Invoke-NotificationQuestionLoop` in `NotificationClient.psm1`) and rewire both `InterviewLoop` and the new task-runner clarification handler to call it. Copy-paste-adapt here would leave the duplication permanent after retirement — two callsites instead of one.

Sequencing: must land after P0-1 (the "skip interview" guard can't be written until `type: interview` exists).

**Tracked by:** #221, #219 (symptom).

#### P0-3. Per-phase direct commits (`commit.paths`, `commit.message`) without a worktree

**Kickstart:** `Invoke-KickstartProcess.ps1:637-652` reads `commit.paths` + `commit.message` from each phase and runs `git add` / `git commit` directly against the main repo:

```powershell
foreach ($cp in $commitPaths) {
    git -C $projectRoot add ".bot/$cp"
}
git -C $projectRoot commit --quiet -m $commitMsg
```

This is how non-code work (product documents, research notes) gets checkpointed without a worktree roundtrip.

**Task-runner:** All commit logic in `Invoke-WorkflowProcess.ps1:899` is gated behind `if ($worktreePath)`. When a task declares `skip_worktree: true`, `$worktreePath` is null, so no commit happens — the work is done but never committed. Additionally, `New-WorkflowTask` in `workflow-manifest.ps1` doesn't parse the `commit:` field at all, so even if the dispatch path were fixed, the task metadata wouldn't carry the commit instructions forward.

**Required changes:**
- Parse `commit:` in `New-WorkflowTask`.
- In the task-runner post-execution path, if `skip_worktree` and `commit.paths` are set, run direct `git add` + `git commit` on the main repo, following the kickstart pattern.
- Consider whether the same logic should fire for worktree-backed tasks that also declare `commit:`, or whether the worktree squash-merge already covers that case.
- **Honor the `auto_push_phase_commits` setting** (`Invoke-KickstartProcess.ps1:659-662, 695`). Kickstart reads this key to decide whether the per-phase commit is also pushed to origin immediately. Environments that opt out (air-gapped dev, CI without push tokens, "review before publishing" operators) rely on this switch. Task-runner has zero references to it — without enforcement, P0-3 will silently start pushing in environments that had explicitly disabled it.
- **Decide legacy flat-alias policy**: kickstart also accepts `commit_paths:` / `commit_message:` as flat aliases alongside the nested `commit.paths` / `commit.message` form (`Invoke-KickstartProcess.ps1:636-638`). Either (a) add alias support in `New-WorkflowTask`, or (b) migrate any shipped manifests that use the flat form. Without one of these, existing workflows using legacy names will silently lose their commit instructions post-retirement.

**Tracked by:** Backlog #6.

#### P0-4. Declarative outputs validation (`outputs`, `outputs_dir`, `min_output_count`)

**Kickstart:** `Invoke-KickstartProcess.ps1:587-605` validates each phase's declared outputs after it runs:

- `outputs: ["mission.md"]` — file must exist in the product directory.
- `outputs_dir: "tasks/todo"` + `min_output_count: 1` — directory must contain at least N entries.

If validation fails, the phase (and therefore the process) fails hard.

**Task-runner:** No validation. A task is considered done the moment it calls `task_mark_done` via MCP. Both #255 (Claude edited wrong files instead of creating `mission.md`) and #256 (Claude never wrote files into `tasks/todo/`) are direct consequences — the task-runner never noticed the declared outputs were missing.

**Required changes:**
- Port the validation block into `Invoke-WorkflowProcess.ps1` / `Invoke-ExecutionProcess.ps1` so it runs after task completion.
- Decide whether failure should be hard (fail the task) or soft (emit a warning). Recommended: hard, matching kickstart.
- Consider adding a `max_output_count` or `required_files` shortcut for common cases.
- **Decide legacy alias policy**: kickstart accepts `required_outputs:` / `required_outputs_dir:` as aliases for `outputs:` / `outputs_dir:` (`Invoke-KickstartProcess.ps1:590-591`). Either add alias support in `New-WorkflowTask`, or migrate any shipped manifests using the legacy names. Otherwise those workflows silently lose validation post-retirement.

**Tracked by:** #255, #256 (both are symptoms of this gap).

#### P0-5. `task_gen` LLM routing when `workflow:` is set

**Kickstart:** `task_gen` is not a dedicated case — it falls through to the LLM branch, which sends the named prompt to Claude. Claude then invokes `task_create` via MCP to generate tasks. This is the correct behaviour.

**Task-runner:** `Invoke-WorkflowProcess.ps1:343-350` treats `task_gen` as a script invocation. When the manifest has a `workflow:` field but no `script:` field (the normal case, e.g. the "Plan Internet Research" task), `$task.script_path` is null and execution fails.

**Required change:** When `task_gen` has a `workflow:` field, route to the LLM branch instead of the script branch. Both fields should be allowed (script-based task generation still exists), and the routing should prefer `workflow:` when both are present.

**Tracked by:** [#263](https://github.com/andresharpe/dotbot/issues/263) (addressed by [PR #264](https://github.com/andresharpe/dotbot/pull/264)). Also contributes to #255 and #256.

#### P0-6. UI must become engine-aware

**Kickstart:** The Overview and Workflow tabs read from `/api/kickstart/status`, which `ProductAPI.psm1:769` implements via `Get-KickstartStatus`. The function already accepts both engines when looking up the latest process (`ProductAPI.psm1:812-823`):

```powershell
$isKickstart     = $pData.type -eq 'kickstart'
$isWorkflowRunner = $pData.type -eq 'task-runner' -and $workflowName -and
                    $pData.workflow_name -eq $workflowName
if ($isKickstart -or $isWorkflowRunner) { $latestProc = $pData; break }
```

The recognition is partial, though — task-runner process files don't carry a `phases:` array, so for every phase `procEntry = $null` and the function falls through to filesystem inference (`Resolve-PhaseStatusFromOutputs`, `ProductAPI.psm1:546-760`). Stale output files from previous runs then make unrelated phases appear completed.

**`Resume-ProductKickstart` is the harder gap** (`ProductAPI.psm1:977-988`): regardless of which engine produced the existing run, the Resume button hardcodes `-Type kickstart -FromPhase $resumePhase`, ignoring the task-runner queue from the previous run.

**Required changes:**
- Teach the phase-status path to understand the task-runner queue: map tasks → phases (by workflow definition), so `procEntry` has meaningful status even when the run comes from `task-runner`. Or retire the phase concept from the UI entirely and show task-level progress.
- Rewrite `Resume-ProductKickstart` to start a task-runner continuation (`Start-ProcessLaunch -Type task-runner -Continue $true`) when the existing run was task-runner-driven.
- Either retire `/api/kickstart/status` or rename it to `/api/workflow/status`, and stop treating phases as a kickstart-only concept in the UI layer.
- `Resolve-PhaseStatusFromOutputs` can stay as a "no run active" fallback but must not override live data from a task-runner process.
- Remove DOM IDs like `overview-kickstart-phases` from `index.html` and rename the JS module (`kickstart.js` → `workflow-runner.js`).
- Remove the `'kickstart'` entry from the `typeOrder` array and `typeLabels` map in `workflows/default/systems/ui/static/modules/processes.js:88-98` — otherwise the Processes tab keeps rendering an empty "Kickstart" group after retirement.
- Rename the `type = "kickstart-questions"` action item emitted by `Get-ActionsForSidebar` (`workflows/default/systems/ui/modules/TaskAPI.psm1:352-367`) and its render branch in `workflows/default/systems/ui/static/modules/actions.js:277, 402`. The server-side condition (`$proc.status -eq 'needs-input' -and $proc.pending_questions`) is already engine-agnostic — once P0-2 lands, task-runner processes will trigger this item but appear under the kickstart label. Rename to something engine-neutral (e.g. `workflow-questions`) and update the frontend accordingly. This is a downstream dependency of P0-2, not an independent change.

**Tracked by:** #259, #241, #239, #198, Backlog #3.

### 3.2 P1 — Decision required

These features exist in kickstart and are used by at least one shipped workflow. Each needs a deliberate decision: port, redesign, or deprecate.

| # | Feature | Kickstart location | Used by | Recommendation |
|---|---------|-------------------|---------|----------------|
| P1-1 | `Resume -FromPhase` semantics (skip everything before phase N) — **tracks #241, #198** | `launch-process.ps1:424`, `Resume-ProductKickstart` | UI Resume button | **Redesign** — "resume from phase" doesn't map to a task queue. Replace with "continue the existing task queue" (already what `-Continue` does). **Decision blocks #241 and #198** — P0-6 cannot wire up the Resume button until this semantic question is answered. |
| P1-2 | `skip_phases` preflight UI | `kickstart.js:493-528`, `launch-process.ps1:62` | Kickstart modal | **Two options:** (a) **Deprecate** — phase concept doesn't exist in task-runner, drop the modal toggle entirely; (b) **Redesign** — reimplement as per-task skip UI (operator picks which tasks to skip before launch). Option (a) is simpler; (b) preserves the "I want to skip Phase 3" UX in task-runner terms. |
| P1-3a | `auto_workflow` form param | `kickstart.js:567-577`, `launch-process.ps1:59`, `ProductAPI.psm1:435,983` | Kickstart modal | **Remove** — `[switch]$AutoWorkflow` is declared in `launch-process.ps1:59` and threaded through the launcher, but neither `Invoke-KickstartProcess.ps1` nor `Invoke-WorkflowProcess.ps1` ever reads `$AutoWorkflow`. The flag has zero runtime effect today. No "decision" to take — just delete the parameter and the UI checkbox. |
| P1-3b | `needs_interview` form param | `kickstart.js:567-577`, `Invoke-KickstartProcess.ps1:309`, `Invoke-WorkflowProcess.ps1:536` | Kickstart modal | **Two options:** (a) **Deprecate** — once interview is a task type (P0-1), the manifest itself decides whether an interview runs. No user-facing toggle needed. (b) **Redesign** — keep the toggle but rewire it to skip any `type: interview` tasks at launch time (depends on P1-2's per-task skip mechanism if option (b) was picked there). Trade-off: (a) is cleaner; (b) preserves the "use this workflow without the interview" flexibility some users may want. |
| P1-4 | `files` uploads — saved today but orphaned | `kickstart.js` → `server.ps1:2012-2019` saves them to `.bot/workspace/product/briefing/` | Kickstart modal | **Port** — the save path already works. What's missing is prompt-side injection so Claude actually reads them. Delivered by P1-6. |
| P1-5 | YAML front-matter metadata injection (`front_matter_docs`) | `Invoke-KickstartProcess.ps1:608-623` | Kickstart LLM phases | **Port** — zero references in task-runner. Low cost, helps debuggability. |
| P1-6 | Product briefing context injection (`briefing/` files → all LLM phases) | `Invoke-KickstartProcess.ps1:144-154` | Kickstart LLM phases | **Port** — task-runner has no equivalent. Unlocks P1-4. |
| P1-7 | Interview summary global injection | `Invoke-KickstartProcess.ps1:156-166` | Kickstart LLM phases | **Port with P0-1** — once interview tasks exist, all downstream tasks can opt into reading the summary. Handled by convention (static prompt references), not framework injection — matches the decision already taken on #220. |
| P1-8 | Heartbeat polling of child processes | `Invoke-KickstartProcess.ps1:277-295` | Kickstart supervising task-runner children | **Deprecate** — only exists because kickstart launches task-runner as a subprocess. Task-runner has its own `heartbeat_status` / `last_heartbeat` throughout (`Invoke-WorkflowProcess.ps1:233, 518, 619, 720, 738, 879, 1043`). Once kickstart is gone, the supervision layer disappears. |

### 3.3 P2 — Standalone / adjacent

| # | Item | Note |
|---|------|------|
| P2-1 | Turkish-I locale bug (`.ToUpper()` without `InvariantCulture`) | Backlog #1. Affects both engines — `dotbot-mcp.ps1:216`, `Invoke-WorkflowProcess.ps1:335`, `Invoke-ExecutionProcess.ps1:153`. Must fix before the P0 ports go in, otherwise the new code paths inherit the bug. |
| P2-2 | Workflow tab prompt file loader `shortType` bug | Backlog #9. `server.ps1:2006` + `ReferenceCache.psm1:337-352`. Independent of retirement. |
| P2-3 | Workflow rename (`kickstart-*` → `*`) | Owner's explicit second request. Low-risk mechanical change, last step of the retirement sequence. |
| P2-4 | Task-runner schema honesty: `env`, `timeout`, `retry`, `max_concurrent` are parsed but never applied | `New-WorkflowTask` writes these fields into task JSON (`workflow-manifest.ps1:322-324, 328`) but `Invoke-WorkflowProcess.ps1` and `Invoke-ExecutionProcess.ps1` contain zero references to any of them. A manifest author writing `timeout: 600` or `retry: 3` gets a silent no-op — the schema promises a safety net the runtime doesn't deliver. While kickstart is still around, subprocess supervision provides an indirect timeout cushion; once it's retired, task-runner is the only engine and these dead knobs become actively misleading. **Decision required:** either wire each field up in the execution path, or drop it from the parsed schema with a migration note. Do not leave them parsed-but-ignored post-retirement. |

### 3.4 Task-runner robustness gaps (must fix before kickstart removal)

These are not parity gaps — they are task-runner defects. They're listed here because once kickstart is gone, task-runner is the only engine, and these defects become load-bearing.

| # | Defect | Issue | Summary |
|---|--------|-------|---------|
| R1 | Task killed mid-`analysing` is not resumed | #214 | Restarting task-runner does not pick up tasks that were in `analysing` when the previous run was killed. Needs a queue-level resume + zombie status cleanup. |
| R2 | Task-runner continues after non-optional task failure | #213 | A failed task should halt the pipeline. Today task-runner picks the next task regardless. The `on_failure:` field already exists in shipped manifests (e.g. `kickstart-via-jira/workflow.yaml:72` uses `on_failure: halt`) and is already captured into task JSON by `workflow-manifest.ps1:325` — but no execution-path code reads it (0 references in `Invoke-WorkflowProcess.ps1` / `Invoke-ExecutionProcess.ps1`). Fix is to enforce the existing field, not design a new one: add the read-and-act code in the execution path, and decide vocabulary (ship `halt` only — already used — or extend with `continue` / `optional`). |
