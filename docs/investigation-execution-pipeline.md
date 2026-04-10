# Execution Pipeline Investigation

**Date:** 2026-04-10  
**Status:** Investigation complete, solutions proposed, implementation pending  
**Related:** [Issue #198](https://github.com/andresharpe/dotbot/issues/198) — Resume button incorrectly appears during active task-runner workflow

---

## Overview

Deep investigation into the task-runner and kickstart execution pipeline to identify UX gaps and propose solutions for stuck/crashed task recovery.

---

## Architecture

### Process Type Hierarchy

```
launch-process.ps1
  ├── task-runner  → Invoke-WorkflowProcess.ps1   (unified analyse+execute loop)
  ├── kickstart    → Invoke-KickstartProcess.ps1   (legacy multi-phase product setup)
  ├── analysis     → Invoke-AnalysisProcess.ps1    (single-task analysis)
  ├── execution    → Invoke-ExecutionProcess.ps1   (single-task execution)
  └── planning/commit/task-creation → Invoke-PromptProcess.ps1
```

### Critical Clarification: Run Button Always Launches Task-Runner

**ALL workflow Run buttons launch task-runner, never kickstart.**

Both the form and no-form paths end up at the same endpoint:

```
runWorkflow(name, hasForm)
  ├── hasForm = true  → opens kickstart modal (useTaskRunner: true)
  │                     → user fills prompt/files
  │                     → submits to POST /api/workflows/{name}/run  → task-runner
  │
  └── hasForm = false → POST /api/workflows/{name}/run directly     → task-runner
```

The kickstart modal is reused purely as a UI form when `hasForm` is true. The submission routes to the task-runner endpoint (`kickstart.js:528-530`), NOT to `/api/product/kickstart`.

**Code proof** (`controls.js:693-704`):
```javascript
async function runWorkflow(name, hasForm) {
    if (hasForm) {
        openKickstartModal(name, { useTaskRunner: true }); // modal, but NOT kickstart
        return;
    }
    // No form → POST /api/workflows/{name}/run directly
}
```

**When does kickstart actually run?** Only via the legacy path: overview page when no product docs exist → `POST /api/product/kickstart` → `launch-process.ps1 -Type kickstart`. The workflows tab Run button never launches kickstart.

### Task-Runner Entry Points

| Entry | Process Type Created | Trigger |
|---|---|---|
| **UI Run (no form)** | `task-runner` | `POST /api/workflows/{name}/run` directly |
| **UI Run (has form)** | `task-runner` | Kickstart modal → `POST /api/workflows/{name}/run` |
| **CLI** | `task-runner` | `scripts/workflow-run.ps1` |
| **Legacy kickstart** | `kickstart` (spawns task-runner children) | `POST /api/product/kickstart` (overview page, no product docs) |

### Task-Runner Core Loop

`Invoke-WorkflowProcess.ps1` — continuous loop:

1. **Pick next task** via `Get-NextWorkflowTask` (priority: resumed > analysed > todo, respects workflow filter + dependencies)
2. **Claim it** with multi-slot race-condition guard (5 retry attempts, 200ms delay)
3. **Dispatch by task type:**
   - `prompt` — analyse (98-analyse-task.md) then execute (99-autonomous-task.md) via Claude
   - `prompt_template` — same but with workflow-specific prompt file
   - `script` / `mcp` / `task_gen` / `barrier` — direct execution, no Claude, slot 0 only
4. **Retry on failure** (max 2 retries per task), mark skipped on permanent failure
5. **Exit** when: max tasks reached, stop signal, no tasks available, or 3 consecutive failures

**Concurrency:**
- Multiple slots run as separate OS processes
- Slot stagger: slots > 0 wait random prime seconds (5/7/11/13)
- Non-prompt tasks restricted to slot 0 only

### Jira Workflow — Step-by-Step Example

When user clicks **Run** on `kickstart-via-jira` (has form):

1. `runWorkflow('kickstart-via-jira', true)` → modal opens with `useTaskRunner: true`
2. User types Jira key, uploads files, clicks submit
3. Modal submits to `POST /api/workflows/kickstart-via-jira/run` (task-runner, not kickstart)
4. Server creates all manifest tasks in `todo/`, launches task-runner

Task-runner processes them in dependency order:

| Priority | Task | Type | Depends On | What Happens |
|---|---|---|---|---|
| 1 | Fetch Jira Context | `prompt` | — | Claude fetches Jira data → `briefing/jira-context.md` |
| 2 | Generate Product Docs | `prompt` | #1 | Claude plans → `mission.md` |
| 3 | Plan Internet Research | `task_gen` | #2 | Script creates research tasks in `todo/` |
| 4 | Plan Atlassian Research | `task_gen` | #2 | Script creates Atlassian research tasks |
| 5 | Plan Sourcebot Research | `task_gen` | #2 | Script creates Sourcebot research tasks |
| 6 | Execute Research | `barrier` | #3,#4,#5 | No-op — marks done immediately; generated tasks run naturally |
| 7 | Create Deep-Dive Tasks | `task_gen` | #6 | Creates deep-dive tasks |
| 8 | Execute Deep Dives | `barrier` | #7 | No-op — generated tasks run naturally |
| 9 | Synthesise Research | `prompt` | #8 | Claude → `research-summary.md` |
| 10 | Publish to Jira | `prompt` | #9 | Claude publishes artifacts to Jira |
| 11-17 | Implementation phases | various | chain | Research repos, refine, plan, create impl tasks, execute, remediate, handoff |

**Key:** Barriers mark themselves done immediately. Task_gen-created tasks land in `todo/` and the task-runner loop picks them up naturally (no unmet dependencies after barrier completes).

---

## UI Buttons — Current Behavior

### Resume Button

- **Scope:** Kickstart phases only (not individual tasks)
- **Rendered in:** `kickstart.js:1133`, `workflow.js:352`
- **Condition:** `data.status === 'incomplete' && data.resume_from`
- **API:** `POST /api/product/kickstart/resume`
- **Backend:** `Resume-ProductKickstart` in `ProductAPI.psm1:816-886`
- **Behavior:** Launches new kickstart process with `-FromPhase` set to next incomplete phase

### Run Button

- **Rendered in:** `controls.js:665` (workflows tab), `kickstart.js:296` (overview page)
- **Both use:** `runWorkflow(name, hasForm)` in `controls.js:693-724`
- **Always goes to:** `POST /api/workflows/{name}/run` → creates tasks → launches task-runner
- **Does NOT:** Re-process existing failed/stuck tasks. Always creates fresh tasks from manifest.

### Stop / Kill Controls

| Control | Location | API | Behavior |
|---|---|---|---|
| Stop (process) | Processes tab | `POST /api/process/{id}/stop` | Graceful — creates `.stop` signal file |
| Kill (process) | Processes tab | `POST /api/process/{id}/kill` | Immediate — `Stop-Process` by PID |
| Stop (workflow) | Workflows tab / Overview | `POST /api/workflows/{name}/stop` | Finds matching task-runner processes, sends stop signal |

### Per-Task Actions (Current)

| Action | Available For | What It Does |
|---|---|---|
| Toggle Ignore | Todo tasks | Acknowledge/block task |
| Edit | Todo tasks | Edit name, description, priority, etc. |
| Delete | Todo tasks | Archive to deleted |

**Missing:** No Reset, Retry, or status change controls for in-progress/skipped/analysed tasks.

---

## Task State Machine

```
todo ──→ analysing ──→ analysed ──→ in-progress ──→ done
 ↑          │             │             │
 │          ▼             ▼             │
 │       needs-input ◄───┘             │
 │          │                           │
 │          └───────────────────────────┘ (question answered → re-analyse)
 │
 └──── skipped (non-recoverable or max-retries)
```

**task-mark-todo transitions (already supported in backend):** `in-progress` → `todo`, `done` → `todo`, `skipped` → `todo`. Not exposed in UI.

---

## Crash Recovery Mechanisms

### Automatic Recovery (Startup Only)

All run at `Invoke-WorkflowProcess.ps1:69-72`, once per task-runner startup:

| Function | What It Recovers |
|---|---|
| `Reset-AnalysingTasks` | Cross-references process registry; requires PID dead + 5-min staleness |
| `Reset-InProgressTasks` | Moves to `analysed` (if has analysis data) or `todo` |
| `Reset-SkippedTasks` | Moves to `todo` if `skip_count < 3` |

**Not called during runtime, not available on-demand from UI.**

### Per-Task Try/Catch (Same Process)

`Invoke-WorkflowProcess.ps1:870-889` — moves crashed task back to `todo/`. Only works if the process itself is still alive.

### Retry Logic

- `maxRetriesPerTask = 2` (3 total attempts)
- Rate-limit retries don't count against the limit
- Non-recoverable failures → skip immediately
- Max retries exhausted → `task-mark-skipped` with reason `max-retries`
- 3 consecutive failures → process stops entirely

---

## Issue #198: Resume Button During Active Task-Runner

### Root Cause

`Get-KickstartStatus()` in `ProductAPI.psm1:773` only looks for `type='kickstart'` processes. Since ALL Run buttons create `type='task-runner'` processes:

1. Process scan finds nothing
2. Falls to filesystem inference (`Resolve-PhaseStatusFromOutputs`)
3. Barrier phases always return `"pending"` (line 572) — can't be resolved without process tracking
4. Task-runner phases have no output files to check → also `"pending"`
5. `completedCount < phases.Count` → `"incomplete"` → Resume button shows
6. Task enrichment (`Resolve-TaskGenChildTasks`) runs AFTER status computation (line 808) — too late

**Result:** Resume button appears during active runs AND after fully successful runs. Clicking it fails because prompt was saved to a different path.

---

## Design Decision: Resume → Continue (Pending Implementation)

### Is Resume still valid?

**No, not for the task-runner world.** Resume re-launches kickstart from a specific phase, but kickstart only runs in the legacy path. In the task-runner world:

- There are no "phases" to resume from — the task files on disk ARE the state
- Task-runner already picks up where it left off via `Get-NextWorkflowTask` (respects dependency order)
- Recovery just means: reset stuck tasks + start a new task-runner worker

### What should replace it?

A **"Continue"** button that:

1. Runs `Reset-InProgressTasks` + `Reset-SkippedTasks` to recover stuck tasks
2. Launches a fresh task-runner with `-Continue` against the existing task queue
3. No prompt needed, no phase tracking needed — tasks on disk are the source of truth

This subsumes both the old Resume concept and the "Retry Failed" concept — it's the same mechanism.

### For legacy kickstart path

Resume still technically works there, but that path is shrinking. Long-term, unify under Continue.

---

## Identified Gaps

| # | Gap | Impact |
|---|---|---|
| 1 | No per-task Reset/Retry button | Tasks stuck in in-progress/skipped need new process or manual file moves |
| 2 | No way to re-run failed tasks without creating fresh ones | Run always creates new tasks from manifest |
| 3 | Resume button shows incorrectly on task-runner runs (#198) | `Get-KickstartStatus` only looks for `type='kickstart'` |
| 4 | Resume is wrong concept for task-runner world | Should be replaced with "Continue" (recover + restart worker) |
| 5 | No heartbeat timeout detection | Hung processes never detected |
| 6 | Skipped tasks with skip_count >= 3 stuck forever | No UI override |
| 7 | Recovery is startup-only | No runtime or on-demand recovery |

---

## Proposed Solutions

### Solution 1: Per-Task "Reset" Action (High Priority)

Add "Reset" button for tasks in `in-progress`, `skipped`, `analysed`, `needs-input` states.

**Files:** `roadmap-task-actions.js`, `server.ps1` (new endpoint), `views.css`  
**Backend exists:** `task-mark-todo/script.ps1`

### Solution 2: "Continue" Button — Replaces Resume + Retry Failed (High Priority)

Replace the Resume button with a Continue button for the task-runner world:
- Runs `Reset-InProgressTasks` + `Reset-SkippedTasks` on demand (no fresh task creation)
- Launches task-runner with `-Continue` against existing task queue
- No prompt needed, no phase tracking — tasks on disk are the state

**Files:** `controls.js` (or wherever Resume currently renders), `server.ps1` (new endpoint), `ProductAPI.psm1` (status logic)  
**Reuse:** `task-reset.ps1` functions  
**Also fixes Issue #198** — Resume no longer shows incorrectly because it's replaced by Continue with proper task-runner awareness

### Solution 3: Process Health Monitor (Medium Priority)

Detect stale processes, auto-recover tasks. Check `last_heartbeat` + PID liveness.

**Files:** `ProductAPI.psm1`, `server.ps1`

### Solution 5: Kickstart Worker Retry (Lower Priority)

Re-launch crashed worker slots if non-done tasks remain.

**Files:** `Invoke-KickstartProcess.ps1`

---

## Key Files Reference

| File | Purpose |
|---|---|
| `workflows/default/systems/runtime/modules/ProcessTypes/Invoke-WorkflowProcess.ps1` | Task-runner main loop |
| `workflows/default/systems/runtime/modules/ProcessTypes/Invoke-KickstartProcess.ps1` | Kickstart orchestrator (legacy path) |
| `workflows/default/systems/runtime/launch-process.ps1` | Process dispatcher + crash trap |
| `workflows/default/systems/runtime/modules/task-reset.ps1` | Task recovery functions (startup-only) |
| `workflows/default/systems/runtime/modules/ProcessRegistry.psm1` | Process tracking, Get-NextWorkflowTask, deadlock detection |
| `workflows/default/systems/mcp/tools/task-mark-todo/script.ps1` | MCP tool — in-progress/skipped/done → todo |
| `workflows/default/systems/ui/modules/ProductAPI.psm1` | Get-KickstartStatus (line 730), Resume-ProductKickstart (line 892) |
| `workflows/default/systems/ui/static/modules/roadmap-task-actions.js` | Per-task UI actions (needs Reset) |
| `workflows/default/systems/ui/static/modules/controls.js` | runWorkflow() (line 693), stopWorkflow() — all paths → task-runner |
| `workflows/default/systems/ui/static/modules/kickstart.js` | Modal reused as form, useTaskRunner flag (line 528) |
| `workflows/default/systems/ui/server.ps1` | All HTTP API endpoints |
| `scripts/workflow-run.ps1` | CLI entry point |


Let's continue on the execution pipeline investigation


