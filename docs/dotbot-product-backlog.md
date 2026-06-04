# Dotbot Product Backlog

**Prepared by:** Product Owner  
**Date:** 2026-06-01  
**Source:** Engine gap analysis (main @ 9dce2f4) + Pilot survey (28 respondents, 5 PODs)  
**Status:** Draft — pending GitHub issue creation
**v4 Cross-Validation:** 2026-06-04 — validated against `main @ bc587c5` (v4 merge, #455). v4 closed **0 of 22** items (0 RESOLVED, 0 OBSOLETE): **15 STILL_VALID**, **3 CHANGED** (C4, G1, S5), **4 PARTIAL** (S1, S6, S7, S8). The codebase was relocated `core/*` → `src/*` everywhere, so every item's file references are refreshed inline in the per-item **v4** callouts below. Full analysis: [dotbot-backlog-v4-crossvalidation.md](dotbot-backlog-v4-crossvalidation.md).

---

## How to Read This Document

| Field | Meaning |
|---|---|
| **Type** | Bug / Feature / Enhancement |
| **Priority** | Critical / High / Medium / Low |
| **Source** | Consolidated (both sources) · Gap Doc Only · Survey Only |
| **Weight** | 1–10 score based on survey frequency, abandonment impact, and breadth |

---

## Section A — Consolidated (Gap Analysis + Pilot Survey)

---

### C1 — Partial / In-Place Regeneration

> **v4 (2026-06-04): STILL_VALID · KEEP.** Unchanged — reject still discards the worktree and regenerates from empty (`src/mcp/tools/task-submit-review/script.ps1` → `Reset-TaskWorktree`). New nuance: reviewer feedback is now *persisted* (`extensions.review.feedback` accumulates) but is **never injected** into the prompt assembler (`src/runtime/Modules/Dotbot.Task/Dotbot.Task.psm1` `Build-TaskPrompt`), so AC3's "accumulated" half is partly met, "injected and honoured" is unmet.

| Field | Value |
|---|---|
| **Type** | Enhancement |
| **Priority** | Critical |
| **Source** | Consolidated |
| **Survey Hits** | R2, R7, R10, R24 — 4 respondents |
| **Weight** | 9/10 |

**Problem Statement**  
When a task is re-run after rejection or operator feedback, dotbot discards the prior
output and regenerates from an empty worktree. Feedback provided after a run is silently
ignored — dotbot produces a full regeneration rather than applying targeted corrections
to the existing artifact.

**User Story**  
As a delivery team member, I want dotbot to retain my prior artifact as an editable base
when I re-run a task, so that only the sections that need to change are updated and my
stable, reviewed content is not discarded.

**Acceptance Criteria**
- [ ] A task can be re-run with its previous output available as an editable base
- [ ] Only sections targeted by reviewer feedback are regenerated; unchanged sections are preserved
- [ ] Reviewer feedback accumulated across multiple cycles is injected and honoured
- [ ] The existing full-regeneration path remains available when explicitly requested
- [ ] Manual edits made between runs are preserved unless explicitly in scope of the re-run

**Evidence**  
> *"It was very hard to have dotbot make specific changes once the initial run had been done and it was poor at fine tuning the outputs"* — R2, Solution Architect  
> *"I provided a clear list of issues. After dotbot was executed, none of these problems were resolved"* — R24, Dotbot Team Member  
> *"Dotbot needs to learn from the current BS work. We need to define a feedback loop process so that where there are manual updates to code we feed it back again"* — R10, AI Delivery Lead

---

### C2 — Workflow Modify Mode + Per-Artifact Approval Gates

> **v4 (2026-06-04): STILL_VALID · KEEP.** No modify mode (`src/cli/workflow-run.ps1` always mints a fresh run; `workflow-start` MCP has no mode param), no phase/approval-gate concept in any `workflow.json`, no `pending-approval` state (`src/runtime/Modules/Dotbot.Task/Private/Transitions.psm1`). The related approval PR #449 was **reverted** (`69b6165`) and was per-*question*, not per-*artifact/phase*. Minor rescope: the "fresh/append modes" referenced in AC5 are conceptual, not a real code enum.

| Field | Value |
|---|---|
| **Type** | Enhancement |
| **Priority** | Critical |
| **Source** | Consolidated |
| **Survey Hits** | R2, R5, R7, R9, R27 — 5 respondents |
| **Weight** | 9/10 |

**Problem Statement**  
Re-running a completed workflow always wipes all tasks and regenerates from scratch.
There is no approval gate between artifacts — dotbot proceeds from Functional Spec → HLD
→ LLD → Code without requiring sign-off at each stage, causing significant rework when
downstream artifacts are built on top of unreviewed upstream ones.

**User Story**  
As a delivery lead, I want to re-run a workflow to update already-published artifacts
without rebuilding from scratch, and I want each artifact stage to require explicit
approval before the next one begins.

**Acceptance Criteria**
- [ ] `workflow-run` supports a `modify` mode that updates prior artifacts rather than wiping from manifest
- [ ] Unchanged artifacts and stable internal IDs are preserved; only deltas are applied
- [ ] A workflow can declare approval gates between named phases
- [ ] A phase awaiting approval enters a `pending-approval` state visible in the dashboard
- [ ] The existing `fresh` and `append` modes are unaffected

**Evidence**  
> *"Stick to one artifact being created at a time and having that completed and signed off before moving down the flow"* — R2, Solution Architect  
> *"Splitting workflows into multiple ones with specific deliverables for each one and approval process for each stage"* — R5, Dotbot Team Member  
> *"Create custom specific workflows for IWG, for BSes, Enhancements, for HLD, LLD, functional spec etc."* — R9, Technical Lead

---

### C3 — Back-Edges / Loops + Mid-Run Operator Guidance

> **v4 (2026-06-04): STILL_VALID · KEEP.** Still a strictly forward DAG: `TaskDefinition` has a closed field allowlist with no `loop_back_to` (`src/runtime/Modules/Dotbot.Workflow/Private/TaskDefinition.psm1`); `on_failure` only halts. Mid-run guidance is still a 500-char whisper (`src/ui/modules/ControlAPI.psm1`); session-wide pause/resume exists but not per-task or scope/context redirect.

| Field | Value |
|---|---|
| **Type** | Enhancement |
| **Priority** | Critical |
| **Source** | Consolidated |
| **Survey Hits** | R2, R5, R15, R24 — 4 respondents |
| **Weight** | 9/10 |

**Problem Statement**  
Workflow is a strictly forward DAG — once running it cannot loop back to an earlier phase
on rejection or failure. Operators also cannot guide or redirect dotbot mid-execution the
way they can with direct Claude. These are the two most-cited reasons teams abandoned
dotbot for Claude during the pilot.

**User Story**  
As an operator, I want to redirect dotbot during execution when it is going in the wrong
direction, and I want a review rejection to automatically route back to the appropriate
earlier phase, so that I do not have to manually reset state or abandon the run.

**Acceptance Criteria**
- [ ] A workflow can declare `loop_back_to` on a review gate or failure handler, naming the earlier phase to return to
- [ ] The named phase and all dependent downstream tasks return to initial state and re-run forward
- [ ] Multi-step back-jumps (3+ phases) work without manual queue surgery
- [ ] Mid-run operator guidance goes beyond string whispers — operators can redirect scope, attach context, or pause/resume tasks from the dashboard
- [ ] Existing single-task `reject → redo same task` behaviour is preserved
- [ ] All loop iterations are logged with their triggering reason

**Evidence**  
> *"Dotbot would run full workflow and it wasn't possible to guide it once it started executing"* — R15, AI Delivery Lead  
> *"Ability to guide it once it starts running (like you can do with Claude)"* — R15  
> Primary reason cited by 7 respondents who abandoned dotbot for Claude mid-pilot.

---

### C4 — Preflight: Content-Aware Checks + Custom / LLM-Driven Scripts

> **v4 (2026-06-04): CHANGED · KEEP (refresh paths).** Gap unchanged — still presence-only; `mcp_server` checks registration not reachability; no `script`/`llm` types; unknown types fall through silently (no `else` branch). Logic relocated: definition/validation now in `src/runtime/Modules/Dotbot.Workflow/Dotbot.Workflow.psm1` (`Convert-ManifestRequiresToPreflightChecks`, `Test-WorkflowRequires`), execution in `src/ui/modules/ProductAPI.psm1:380`.

| Field | Value |
|---|---|
| **Type** | Enhancement |
| **Priority** | Medium |
| **Source** | Consolidated (Gap 2 + Gap 11) |
| **Survey Hits** | R2, R9 — indirect |
| **Weight** | 5/10 |

**Problem Statement**  
All three built-in preflight check types (`env_var`, `mcp_server`, `cli_tool`) are
presence-only. A server that is registered but unreachable passes preflight. Failures
surface mid-run as confusing tool errors rather than upfront as actionable messages.
No extension point exists for custom or LLM-driven checks.

**User Story**  
As a workflow author, I want to declare custom preflight checks that validate content
and connectivity — not just presence — so that runs fail fast at launch with actionable
messages rather than stalling mid-execution.

**Acceptance Criteria**
- [ ] A registered-but-unreachable or unauthenticated MCP server fails preflight with an actionable message
- [ ] Workflows can declare a `script` check (exit code + output message = pass/fail)
- [ ] Workflows can declare an `llm` check (prompt + structured boolean/JSON result)
- [ ] Unknown check types produce a diagnostic error, not silent failure
- [ ] The existing three built-in check types continue to work unchanged

---

### C5 — Input Contract: Artifact Pre-Check + Source Exclusion List

> **v4 (2026-06-04): STILL_VALID · KEEP.** Engine rewritten but only carries forward producer-exit `Test-TaskOutput` (`src/runtime/Scripts/Invoke-WorkflowProcess.ps1:655`); no consumer-entry input validation, no `inputs:` block in the extension-keys whitelist (`src/runtime/Modules/Dotbot.Workflow/Dotbot.Workflow.psm1:887`), no source exclusion. Greenfield: add a `Test-TaskInput` gate mirroring `Test-TaskOutput`, wire failures through `Set-WorkflowTaskNeedsInput`.

| Field | Value |
|---|---|
| **Type** | Enhancement |
| **Priority** | High |
| **Source** | Consolidated |
| **Survey Hits** | R2, R9, R24, R27 — 4 respondents |
| **Weight** | 7/10 |

**Problem Statement**  
Tasks have no declared input contract. Stale, contradictory, or irrelevant upstream
artifacts are consumed without validation, leading to hallucinated outputs (imaginary
tables, contradictory LLD instructions). There is also no way to tell dotbot to exclude
specific sources (old Confluence pages, deprecated reference docs) from its context.

**User Story**  
As a delivery team member, I want to declare what artifacts a task requires as input and
mark specific sources to be ignored, so that dotbot validates its context before starting
and does not pull in stale or irrelevant material.

**Acceptance Criteria**
- [ ] A task can declare an `inputs:` block specifying required artifacts with file presence, non-empty, and optional shape assertions
- [ ] Input validation runs at consumer-task entry, before the agent's prompt fires
- [ ] A failed input check promotes the task to `needs-input` with a specific, actionable reason
- [ ] Workflow authors can declare an exclusion list of source paths or patterns dotbot must not read or cite
- [ ] Existing producer-exit `Test-TaskOutput` behaviour is preserved

**Evidence**  
> *"The bot often either ignored changes or failed to pick up on them"* — R2, Solution Architect  
> *"Ability to mark items for dotbot to ignore"* — R2  
> *"I could find imaginary tables and columns in those scripts"* — R24, Dotbot Team Member

---

### C6 — PR-Based Integration + Multi-Repo Targets

> **v4 (2026-06-04): STILL_VALID · KEEP.** Still direct squash-merge + `git push origin $baseBranch` (rejected on protected branches) at `src/runtime/Modules/Dotbot.Worktree/Dotbot.Worktree.psm1:1793`. No `gh pr create`/`az repos pr` primitive, no `targets:` settings block (`content/settings/settings.default.json`). A newer run-level `Complete-RunWorktree` preserves the branch for manual merge, but the task-level path wired into the loop still auto-merges.

| Field | Value |
|---|---|
| **Type** | Enhancement |
| **Priority** | High |
| **Source** | Consolidated (Gap 7 + Gap 13) |
| **Survey Hits** | R11, R13, R18 — 3 respondents |
| **Weight** | 6/10 |

**Problem Statement**  
Core integrates completed tasks by squash-merging directly to the base branch. On
protected branches (the enterprise norm) this push is rejected. Cross-repo PRs are
entirely hand-rolled per workflow and per provider with no shared primitive.

**User Story**  
As a delivery engineer, I want dotbot to open a PR against the target base branch rather
than direct-merging, and I want to declare multiple target repositories in settings, so
that I can deliver to protected branches and cross-system repos without custom scripting.

**Acceptance Criteria**
- [ ] Tasks/workflows can choose PR-based integration as an alternative to direct squash-merge
- [ ] PR creation works for GitHub (`gh`) and Azure DevOps (`az repos`) via a shared primitive
- [ ] PR title, body, draft flag, and reviewer list are configurable per workflow
- [ ] A `targets:` settings block enumerates named repos with per-target attributes
- [ ] The existing direct squash-merge mode remains the default and is unaffected

**Evidence**  
> *"Too much time lost because someone from one system has to make a PR on a system they don't know well"* — R11, AI Engineer  
> *"Lead system should do HLD, other system should be responsible for LLD and implementation — otherwise we will have a huge mess"* — R13, AI Engineer

---

## Section B — Gap Analysis Only

---

### G1 — Auth Expiry / AuthLimit Classification Dead Code

> **v4 (2026-06-04): CHANGED · REWRITE.** Gap persists but the framing is now stale: the classifier type was **renamed `AuthLimit` → `AuthError`** and moved to `src/runtime/Modules/Dotbot.Harness/Private/Failure.ps1`. **Real root cause for implementers:** the sole consumer (`src/runtime/Scripts/Invoke-WorkflowProcess.ps1:1846`) calls `Get-FailureReason` with **empty Stdout/Stderr and `TimedOut=$false`**, so no text-based rule (auth or otherwise) can *ever* match, and only `.recoverable` is read — `.type` is never branched on. The fix is twofold: feed real harness output into the classifier **and** add a type-aware needs-input/re-auth branch. (Rename "AuthLimit" → "AuthError" in the title/criteria below.)

| Field | Value |
|---|---|
| **Type** | Bug |
| **Priority** | Medium |
| **Source** | Gap Doc Only |
| **Weight** | 4/10 |

**Problem Statement**  
When an external MCP server's auth token expires mid-run, the failure collapses into the
generic retry path. The `AuthLimit` classifier type is produced but never consumed — it
is dead code. Runs silently retry or degrade rather than prompting for re-authentication.

**User Story**  
As an operator, I want a mid-run auth expiry to pause the workflow and prompt me to
re-authenticate, so that I can resume without restarting from the beginning.

**Acceptance Criteria**
- [ ] Auth-expiry errors are detected and classified distinctly from generic failures
- [ ] The run parks to `needs-input` with an actionable re-authentication prompt
- [ ] The task resumes from the park after re-auth, not from the beginning
- [ ] `AuthLimit` is either consumed by a handler or removed as dead code

---

### G2 — needs-review State Emits No Notification

> **v4 (2026-06-04): STILL_VALID · KEEP.** `task-mark-needs-review` still only patches state, no notification, no `enter-needs-review` hook. **Now cheaper to fix:** `Send-TaskNotification` gained `-Type approval/documentReview`, `-ReviewLinks`, `-DeliverableSummary` (`src/runtime/Modules/Dotbot.Notification/Dotbot.Notification.psm1:250`), and no-op-when-disabled already exists — wiring a call from the needs-review path is mostly mechanical.

| Field | Value |
|---|---|
| **Type** | Enhancement |
| **Priority** | Low |
| **Source** | Gap Doc Only |
| **Weight** | 2/10 |

**Problem Statement**  
Moving a task to `needs-review` is silent — only `needs-input` sends a notification.
Reviewers have no signal that work is waiting for their attention.

**User Story**  
As a reviewer, I want to be notified when a task enters `needs-review` so that I know
it is my turn to act without watching the dashboard.

**Acceptance Criteria**
- [ ] Entering `needs-review` emits a notification to configured recipients with a link to the review action
- [ ] Notification is no-op when notifications are disabled
- [ ] Notification identifies the task, BS, and submitting party

---

### G3 — Integration Branch Hard-Coded to main/master

> **v4 (2026-06-04): STILL_VALID · KEEP.** `Resolve-MainBranch` / `Resolve-WorkflowMainBranch` still loop only over `@('main','master')` — byte-for-byte identical to base, just relocated to `src/runtime/Modules/Dotbot.Worktree/Dotbot.Worktree.psm1:147` and `.../Private/Worktree.psm1:136`. No `git.base_branch` setting anywhere.

| Field | Value |
|---|---|
| **Type** | Enhancement |
| **Priority** | Low |
| **Source** | Gap Doc Only |
| **Weight** | 3/10 |

**Problem Statement**  
`Resolve-MainBranch` only looks for `main` or `master`. Repos on `develop`, `trunk`, or
a release line cannot use dotbot without renaming their branch.

**User Story**  
As a team using a non-standard trunk name, I want to configure the integration branch in
settings so that dotbot creates and merges task branches against our actual trunk.

**Acceptance Criteria**
- [ ] A `git.base_branch` setting is configurable per-project and per-user
- [ ] `Resolve-MainBranch` reads the configured value, falling back to `main`/`master`
- [ ] Worktree creation, `base_branch` record, and `Complete-TaskWorktree` honour the configured value
- [ ] A repo on `develop` works end-to-end without renaming

---

### G4 — Runtime-Value Branching

> **v4 (2026-06-04): STILL_VALID · KEEP.** `condition` is still path-existence only (`Test-ManifestCondition`, `src/runtime/Modules/Dotbot.Workflow/Dotbot.Workflow.psm1:1540`); unmet → `skipped` (`condition-not-met`, `src/runtime/Modules/Dotbot.Process/Dotbot.Process.psm1:634`), no alternative routing. `on_failure` persisted but still has no engine consumer for control flow.

| Field | Value |
|---|---|
| **Type** | Enhancement |
| **Priority** | Medium |
| **Source** | Gap Doc Only |
| **Weight** | 5/10 |

**Problem Statement**  
The `condition` field is path-existence only. Workflows cannot branch on a value produced
at runtime by a prior task. An unmet condition skips the task rather than routing to an
alternative branch. The `on_failure` field is persisted but has no engine consumer.

**User Story**  
As a workflow author, I want to route execution to different downstream tasks based on a
prior task's structured output value, so that I can express conditional pipelines without
encoding decisions as sentinel files.

**Acceptance Criteria**
- [ ] A task can declare branch routing on a prior task's runtime output value (e.g. a JSON field)
- [ ] Tasks on a non-selected branch are not run
- [ ] Existing path-existence `condition` semantics remain valid
- [ ] Multi-way routing (more than two branches) is supported

---

### G5 — On-Demand External Task Trigger + Evidence Injection

> **v4 (2026-06-04): STILL_VALID · KEEP.** No `task-append-evidence` tool exists (string appears only in this backlog). The only attachment path is bound to the question/answer `needs-input` flow (`src/runtime/Modules/Dotbot.Task/Dotbot.Task.psm1:1479`) — exactly the limitation called out. Framing note: there is no MCP tool literally named `task-answer-question` in v4 (the answer flow runs through `task-update` extensions + NotificationPoller/InboxWatcher) — update AC3's reference.

| Field | Value |
|---|---|
| **Type** | Enhancement |
| **Priority** | Low |
| **Source** | Gap Doc Only |
| **Weight** | 2/10 |

**Problem Statement**  
There is no way to inject findings from an ad-hoc agent or operator into a specific
in-flight task without forcing it to park in `needs-input` first.

**User Story**  
As an operator, I want to attach evidence to a specific in-flight task without forcing
it to pause, so that the task can incorporate additional context and continue.

**Acceptance Criteria**
- [ ] A `task-append-evidence` MCP tool attaches structured artifacts to any in-flight or queued task
- [ ] The receiving task can re-poll its context and pick up the new evidence
- [ ] Existing `task-answer-question` and `InboxWatcher` semantics are unchanged

---

### G6 — External Job Invocation + Await / Ingest

> **v4 (2026-06-04): STILL_VALID · KEEP.** Executors are `barrier, interview, mcp, prompt, script, task_gen` — no `external_job`. The `script` executor still runs synchronously and blocks the (serial, `max_concurrent=1`) runner (`src/runtime/Plugins/Executors/script/script.ps1:47`). The dispatcher is extensible (discovered by `task_type`, `src/runtime/Modules/Dotbot.Executor/Private/Discovery.psm1:268`), so this is additive work.

| Field | Value |
|---|---|
| **Type** | Enhancement |
| **Priority** | Low |
| **Source** | Gap Doc Only |
| **Weight** | 2/10 |

**Problem Statement**  
The runtime can only spawn Claude CLI processes. There is no primitive to trigger an
external long-running job (CI pipeline, test runner) and await and ingest its structured
result. The existing `script` type is synchronous only and blocks the runner.

**User Story**  
As a workflow author, I want to trigger an external CI job, park the task while it runs,
and resume with the job's structured result, so I can orchestrate work outside Claude.

**Acceptance Criteria**
- [ ] An `external_job` task type declares: invocation method, await contract, and result-ingest path
- [ ] The runner does not block other workflow progress while the job is awaited
- [ ] The ingested result is available as a declared input to downstream tasks
- [ ] Existing synchronous `script` behaviour is preserved

---

## Section C — Pilot Survey Only

---

### S1 — QA-Specific Workflows

> **v4 (2026-06-04): PARTIAL · RESCOPE.** v4 added foundational pieces: `content/skills/write-test-plan` (test plan from spec + per-task-group scenario blocks → per-component criterion met), `content/skills/write-unit-tests`, and a tester agent. But there is still **no dedicated, discoverable QA workflow**, no push of test cases to Jira, no delta-driven suggestions, no usability target. Narrow remaining work to: wrap the skills into a QA workflow, push typed test cases to Jira, delta-driven suggestions from PRs, analyse existing automation as patterns, define/measure ≥60%.

| Field | Value |
|---|---|
| **Type** | Feature |
| **Priority** | Critical |
| **Source** | Survey Only |
| **Survey Hits** | R15, R16, R19, R20, R22 — 5 respondents across 4 PODs |
| **Weight** | 9/10 |

**Problem Statement**  
No QA-focused dotbot workflows existed at pilot start. QE practitioners across four PODs
had no dotbot workflow for test plan creation, test case generation, or automation
scripting. All five affected respondents fell back to Claude, Codex, or ChatGPT for QA
activities. This is the largest role-based adoption gap in the pilot.

**User Story**  
As a QA Engineer, I want dotbot workflows for QA activities so that I can create test
plans, generate test cases with detailed steps, produce automation-ready scripts, and
push results to Jira without leaving the dotbot workflow.

**Acceptance Criteria**
- [ ] A dedicated QA workflow covers: test plan creation from functional spec, test case generation with steps and expected results, automation candidate identification
- [ ] Test cases are generated per system/component, not as a single monolithic output
- [ ] Generated test cases can be pushed directly to Jira (create and update)
- [ ] Code change summaries can trigger suggested automated test cases based on the delta
- [ ] Existing automation scripts in the repo are analysed and used as generation patterns
- [ ] QA workflow output quality target: ≥ 60% usable with minor changes (pilot baseline was 0–20%)

**Evidence**  
> *"It did not have workflow for QAs or at least it was not known at the time"* — R15, AI Delivery Lead  
> *"QA-focused version of Dotbot was not yet available"* — R16, AI QE Engineer  
> *"QA Dotbot part is just being developed and there's not much use of it at this point"* — R22, AI QE Engineer  
> *"Outputs were way too broad, generalized and not per-system"* — R19, R28

---

### S2 — Stuck Task Recovery / In-App Kill Switch

> **v4 (2026-06-04): STILL_VALID · KEEP.** v4 ships per-*process* controls (Graceful Stop / Kill / kill-by-type / kill-all in the Processes tab) but **not per-task recovery**. Killing a process sets the process to `stopped` without touching the associated task (`src/ui/modules/ProcessAPI.psm1:147`) — a task left `in-progress` stays stuck. No per-task Reset/Force-Stop, no configurable stuck-timeout auto-flag, no diagnostic on the task. Only reset-to-todo path is review rejection (gated on `needs-review`, `src/ui/modules/TaskAPI.psm1:663`).

| Field | Value |
|---|---|
| **Type** | Bug |
| **Priority** | Critical |
| **Source** | Survey Only |
| **Survey Hits** | R2, R4, R5, R9, R13, R14 — 6 respondents |
| **Weight** | 9/10 |

**Problem Statement**  
Tasks regularly got stuck in workflow statuses with no in-app way to recover. The only
resolution was manual filesystem edits outside dotbot. Error messages when stuck were not
actionable. Teams abandoned dotbot entirely on affected BSes rather than diagnose and recover.

**User Story**  
As an operator, I want to reset or terminate a stuck task from the dashboard with a
single action and receive a clear diagnostic, so that I do not need to manually edit the
filesystem or restart the entire workflow.

**Acceptance Criteria**
- [ ] Dashboard provides "Reset" and "Force Stop" actions on any non-progressing task
- [ ] A task stuck beyond a configurable timeout is automatically flagged with its last known status and error
- [ ] Reset returns the task to `todo` cleanly — no orphaned locks, no corrupted state
- [ ] Force Stop terminates the associated Claude process and parks with a diagnostic message
- [ ] The stuck state (status, last error, duration) is recorded in the task activity log

**Evidence**  
> *"The ability to kill tasks stuck in the workflow (other than by hand)"* — R2, Solution Architect  
> *"dotbot was stuck in some statuses (e.g after interview questions were answered)"* — R9, Technical Lead  
> *"dotbot execution issues where it gets stuck and the team was struggling to get it up and running"* — R4, Solution Architect

---

### S3 — Performance: Speed Gap vs. Direct Claude

> **v4 (2026-06-04): STILL_VALID (conf. medium) · KEEP.** No benchmark infra, no 2× target, and **within-run task concurrency is deliberately disabled** — `Get-MaxConcurrent` hard-returns 1 (`src/ui/modules/ProcessAPI.psm1:292`) because per-slot fan-out overwhelmed the runtime. Partial progress on observability: token usage is logged to the activity log (`ClaudeCodeAdapter.ps1:404`) but **not surfaced in the dashboard** (dashboard "costs" are static estimates). Rescope the concurrency criterion toward a bounded worker pool sharing one MCP; frame token work as "surface in UI."

| Field | Value |
|---|---|
| **Type** | Enhancement |
| **Priority** | High |
| **Source** | Survey Only |
| **Survey Hits** | R11, R13, R25 — 3 respondents |
| **Weight** | 6/10 |

**Problem Statement**  
Dotbot tasks took hours for work that respondents completed in minutes using Claude
directly. The speed gap was the primary reason three respondents switched to Claude and
did not return to dotbot for the rest of the pilot.

**User Story**  
As a developer, I want dotbot tasks to complete in a timeframe comparable to direct
Claude usage, so that I do not lose time to tooling overhead on work I could do faster
manually.

**Acceptance Criteria**
- [ ] Baseline performance benchmarks are established for common task types
- [ ] Investigation-type tasks complete within 2x the time of an equivalent direct Claude session
- [ ] Context building does not repeat file reads already performed in the same session
- [ ] Token usage per task is visible in the dashboard and logged for trend analysis
- [ ] At least one concurrency improvement is implemented for tasks without shared state dependencies

**Evidence**  
> *"Dotbot was much slower than Claude. Some investigations took hours"* — R11, AI Engineer  
> *"Slowness, pressure to deliver BS"* — R13, AI Engineer

---

### S4 — Run Portability: Hand-Off Between People and Machines

> **v4 (2026-06-04): STILL_VALID · KEEP.** No export/import/adopt mechanism. Two adjacent new features: **Fleet** (`src/ui/modules/FleetAPI.psm1`, remote *control* of runtimes on other machines — the run still executes on its origin) and the task-scoped **Handoff** module (`src/runtime/Modules/Dotbot.Handoff`, human-in-the-loop pause/resume on the **same** machine). Live run state (`.control/`, `.handoffs/`, worktrees at absolute paths) is gitignored as machine-local. Build on Fleet/Handoff, but the transfer flow is still missing.

| Field | Value |
|---|---|
| **Type** | Enhancement |
| **Priority** | Medium |
| **Source** | Survey Only |
| **Survey Hits** | R2 — 1 respondent, high severity |
| **Weight** | 4/10 |

**Problem Statement**  
An in-progress run is bound to the local machine that started it. Run state and metadata
are local, making it impossible to transfer a run to another person or machine. If the
operator is unavailable, the run stalls.

**User Story**  
As a team member, I want to hand off an in-progress dotbot run to a colleague on a
different machine, so that absence of the original operator does not block a long-running
workflow.

**Acceptance Criteria**
- [ ] All run state required to resume a task is stored in `.bot/`, not in local machine state
- [ ] A hand-off mechanism (export/import or equivalent) allows transferring an in-progress run
- [ ] The receiving machine can resume from the exact state at transfer time
- [ ] No data loss or state corruption occurs during hand-off

---

### S5 — Output Tailored to Audience

> **v4 (2026-06-04): CHANGED · REWRITE.** The **HLD/LLD/Functional-Spec taxonomy this item is built on no longer exists** in v4 (0 matches across `content/` and `src/`) — replaced by a per-repo artifact pipeline (`mission.md`, `roadmap-overview.md`, per-repo deep dives / implementation plans / handoffs). The "monolithic LLD" complaint is largely solved as a side effect (output is now per-repo). The audience-tailoring gap remains: no artifact declares an audience and the dashboard viewer (`src/ui/static/modules/product.js`) is a generic markdown browser. **Reframe the item around the v4 artifact set:** add an audience field to prompt/frontmatter, drive depth from it, add an audience-aware preview; drop/narrow the per-system criterion.

| Field | Value |
|---|---|
| **Type** | Enhancement |
| **Priority** | High |
| **Source** | Survey Only |
| **Survey Hits** | R19, R27, R28 — 4 respondents |
| **Weight** | 6/10 |

**Problem Statement**  
Generated artifacts are written at a single level of technical depth that serves no
audience well. LLD is too technical for BA review, too verbose for developers, and too
generic for QEs. HLD is reported to be barely distinguishable from the Functional Spec.

**User Story**  
As a Business Analyst, I want the functional review output in plain language focused on
business rules; as a Developer I want concise system-specific implementation guidance —
so that each role receives an artifact calibrated to what they actually need.

**Acceptance Criteria**
- [ ] Each workflow artifact declares its intended audience (BA, SA, Developer, QA)
- [ ] Output rendering adapts depth and terminology to the declared audience
- [ ] LLD output is broken down per system/component, not as a monolithic document
- [ ] HLD is meaningfully differentiated from the Functional Spec in structure and content level
- [ ] Audience-specific output can be previewed in the dashboard before distribution

**Evidence**  
> *"Output from dotbot (LLD) is really hard for human to understand. It is written in very complex way"* — R27, AI Delivery Lead  
> *"HLD is very similar to the functional specification, which reduces its purpose and value"* — R27  
> *"Outputs were way too broad, generalized and not per-system"* — R19, R28

---

### S6 — Deployed Application (Not Local PowerShell)

> **v4 (2026-06-04): PARTIAL · RESCOPE.** v4 added `dotbot serve` (an authenticated per-project HTTP runtime), a **Fleet control-plane** (`src/ui/modules/FleetAPI.psm1` + `src/runtime/Modules/Dotbot.Runtime/Private/ControlPlaneClient.psm1`: runtimes register *outbound* with a "mothership" that proxies stop/kill/whisper/run commands), and an Azure-deployed `src/server-dotnet` — but that server is only a *Multi-Channel Notification PoC*, **not the task engine**.
>
> **Key finding (deploy reality):** Claude/runner processes spawn wherever the runtime runs (`Start-DotbotChildProcess`, `src/runtime/Modules/Dotbot.Process/Dotbot.Process.psm1:802`), so running the runtime on a server **does** spawn compute there. **But both the runtime API and the dashboard bind to loopback only** (`127.0.0.1` / `localhost` — `Lifecycle.psm1`, `src/ui/server.ps1:262`), so you **cannot reach the deployed UI from another machine** without your own tunnel/reverse proxy or the partial Fleet mothership (command-proxy, loopback-bound, no per-user dashboard auth). Runs still die with the launching machine.
>
> Remaining: bind beyond loopback / hosted control plane, simultaneous multi-user dashboard + per-user access control, decouple run continuity from the launcher being online.

| Field | Value |
|---|---|
| **Type** | Feature |
| **Priority** | Medium |
| **Source** | Survey Only |
| **Survey Hits** | R2, R13 — 2 respondents |
| **Weight** | 4/10 |

**Problem Statement**  
Dotbot runs as a local PowerShell process tied to one person's machine. This creates a
single point of failure and prevents team-wide shared access to the dashboard and task queue.

**User Story**  
As a delivery team, I want dotbot to run as a deployed shared service rather than a
local process, so that the dashboard and task queue are accessible to all team members
and runs are not interrupted by individual machine availability.

**Acceptance Criteria**
- [ ] Dotbot can be deployed as a persistent service accessible over the network
- [ ] Multiple team members can access the dashboard simultaneously
- [ ] Runs are not interrupted by the launching machine going offline
- [ ] Authentication and access control are in place for the shared service
- [ ] Local single-machine mode continues to work for individual use

**Evidence**  
> *"Making the process not run in PowerShell windows but as a scaleable deployed application"* — R2, Solution Architect  
> *"Not to be used locally but to deploy it"* — R13, AI Engineer

---

### S7 — Project-Specific Skills Per Codebase

> **v4 (2026-06-04): PARTIAL (conf. medium) · RESCOPE.** Two of four ACs are effectively **met**: project skills install to `.bot/content/skills/` and are auto-copied into every worktree's provider skills dirs (`Copy-DotbotProviderContent`, `src/runtime/Modules/Dotbot.Worktree/Dotbot.Worktree.psm1:690`), and they're git-trackable/shareable. Remaining: (1) richer scoping than the flat `applicable_skills` name list (system/component/task-type), and (2) a first-class create/edit skill-library view in the **main** dashboard (studio-ui can create/edit but is a separate workflow editor; the control panel is read-only). Note much of this predates v4.

| Field | Value |
|---|---|
| **Type** | Enhancement |
| **Priority** | High |
| **Source** | Survey Only |
| **Survey Hits** | R6, R19, R28 — 3 respondents |
| **Weight** | 6/10 |

**Problem Statement**  
AI output quality improved significantly when skills were written specifically for a
project and its systems. No standardised mechanism exists for teams to build, share, and
reuse project-specific skills across PODs and BSes.

**User Story**  
As a delivery team, I want a library of project-specific skills that dotbot loads
automatically when working on our codebase, so that each run benefits from accumulated
knowledge about our systems and does not start from zero.

**Acceptance Criteria**
- [ ] A project skill can be created, stored in `.bot/`, and automatically loaded for all tasks in that project
- [ ] Skills can be scoped to a specific system, component, or task type
- [ ] A skill library view in the dashboard shows active skills and allows creation/editing
- [ ] Skills are version-controlled and shareable across team members

**Evidence**  
> *"AI skills for every project would massively improve the quality, speed and efficiency"* — R6, AI Engineer  
> *"Since switching to Claude our progress has been huge"* (after writing custom skills) — R6, AI Engineer

---

### S8 — Jira Integration: Read + Write

> **v4 (2026-06-04): PARTIAL · RESCOPE.** v4 introduced a genuine Jira **write** path that didn't exist at base: `content/workflows/start-from-jira/prompts/12-publish-to-jira.md` (wired into `workflow.json`) creates a single "DOTBOT" tracking issue (hardcoded type `Task`) and posts research summaries as comments via Atlassian MCP. Narrow and QE-irrelevant: no typed test cases/test sets/sub-tasks, comments-only updates, partial idempotency (tracking issue de-duped, comments re-posted), prompt-level (not enforced) error handling. Rescope to: typed issue creation with issue-type mapping, description/status updates, comment-level idempotency, enforced error surfacing.

| Field | Value |
|---|---|
| **Type** | Enhancement |
| **Priority** | Medium |
| **Source** | Survey Only |
| **Survey Hits** | R19, R20 — 2 respondents |
| **Weight** | 4/10 |

**Problem Statement**  
Dotbot can read from Jira but cannot create or update Jira items. QEs manually copy
dotbot output into Jira after every run.

**User Story**  
As a QA Engineer, I want dotbot to create and update test cases, test sets, and test
plans directly in Jira so that I do not manually copy generated content.

**Acceptance Criteria**
- [ ] Dotbot can create Jira issues (stories, test cases, test sets, sub-tasks) from generated output
- [ ] Dotbot can update existing Jira issues (append comments, update description, change status)
- [ ] Jira write operations require explicit configuration (project key, issue type mapping)
- [ ] Write operations are idempotent — re-running does not create duplicates
- [ ] Jira write failures surface as actionable errors, not silent skips

**Evidence**  
> *"Better Jira connectivity — including the ability to create posts, make edits, and fix or update already posted content"* — R19, AI QE Engineer  
> *"Dotbot could generate test cases directly in Jira"* — R20, AI QE Engineer

---

### S9 — Deeper Interview Phase / Proactive Gap Detection

> **v4 (2026-06-04): STILL_VALID · KEEP.** Interview loop is generic and prompt-driven (`Invoke-InterviewLoop`, `src/runtime/Modules/Dotbot.Task/Dotbot.Task.psm1:1271`); the planning prompt **caps clarification at four questions / one round** and **explicitly forbids a parked open-questions surface** (`content/workflows/start-from-prompt/prompts/01-plan-product.md`) — the direct opposite of AC1/AC4. No contradiction detection, no structured gap report. **Design tension to resolve:** "thorough interrogation + persisted gap report" vs v4's deliberate capped, decision-record-based design.

| Field | Value |
|---|---|
| **Type** | Enhancement |
| **Priority** | High |
| **Source** | Survey Only |
| **Survey Hits** | R6, R17, R22 — 3 respondents |
| **Weight** | 5/10 |

**Problem Statement**  
During analysis, dotbot asks too few questions and does not challenge ambiguous or
incomplete specifications. It proceeds with assumptions rather than surfacing gaps.
By the time implementation reveals a gap, significant rework has accumulated.

**User Story**  
As a delivery lead, I want dotbot to thoroughly interrogate the specification during the
interview phase — identifying gaps, contradictions, and missing details — so that the
team resolves ambiguity before implementation begins.

**Acceptance Criteria**
- [ ] The interview phase asks probing questions calibrated to spec completeness (more questions for vaguer specs)
- [ ] Dotbot flags contradictions between sections of the same specification
- [ ] Missing acceptance criteria, undefined terms, and implicit business rules are surfaced as explicit questions
- [ ] Interview output includes a structured gap report alongside the Q&A
- [ ] The gap report is included in the analysis context package for the execution phase

**Evidence**  
> *"During the interview phase, it asked very few questions and did not seem to explore the requirements deeply enough"* — R17, AI Engineer  
> *"Should be better at identifying gaps, challenging ambiguous requirements, and surfacing missing details early"* — R17, AI Engineer

---

### S10 — Version History Across Runs

> **v4 (2026-06-04): STILL_VALID · KEEP.** A version-history + restore subsystem exists but is scoped to **roadmap task-definition edits** (`Write-TaskArchive`/`Get-TaskVersionHistory`/`Restore-TaskVersion`, `src/mcp/modules/TaskMutation.psm1:284`), triggered by manual mutations, with **no diff view** — and it existed at base, only relocated in v4. No artifact-level, run-triggered snapshots. Use the task-definition versioning as an architectural template; the artifact use case is net-new.

| Field | Value |
|---|---|
| **Type** | Enhancement |
| **Priority** | Low |
| **Source** | Survey Only |
| **Survey Hits** | R7 — 1 respondent |
| **Weight** | 3/10 |

**Problem Statement**  
There is no history of what changed between runs. Teams have no audit trail and cannot
compare the current artifact to a prior version or roll back if a regeneration made
things worse.

**User Story**  
As a delivery team member, I want to view the history of an artifact across all runs —
including what changed and what feedback triggered the change — so that I have full
auditability and can roll back if needed.

**Acceptance Criteria**
- [ ] Every run that modifies an artifact creates a versioned snapshot in `.bot/`
- [ ] The dashboard shows a version timeline per artifact with the triggering event
- [ ] A diff view shows what changed between any two versions
- [ ] A version can be restored as the current artifact
- [ ] Version history is retained for the lifetime of the task

---

## Backlog Summary

| ID | Title | Type | Priority | Source | Weight | v4 Verdict | v4 Rec |
|---|---|---|---|---|---|---|---|
| C1 | Partial / In-Place Regeneration | Enhancement | Critical | Consolidated | 9/10 | STILL_VALID | KEEP |
| C2 | Workflow Modify Mode + Per-Artifact Approval Gates | Enhancement | Critical | Consolidated | 9/10 | STILL_VALID | KEEP |
| C3 | Back-Edges / Loops + Mid-Run Operator Guidance | Enhancement | Critical | Consolidated | 9/10 | STILL_VALID | KEEP |
| S1 | QA-Specific Workflows | Feature | Critical | Survey Only | 9/10 | PARTIAL | RESCOPE |
| S2 | Stuck Task Recovery / Kill Switch | Bug | Critical | Survey Only | 9/10 | STILL_VALID | KEEP |
| C5 | Input Contract + Source Exclusion List | Enhancement | High | Consolidated | 7/10 | STILL_VALID | KEEP |
| C6 | PR-Based Integration + Multi-Repo Targets | Enhancement | High | Consolidated | 6/10 | STILL_VALID | KEEP |
| S3 | Performance: Speed Gap vs. Direct Claude | Enhancement | High | Survey Only | 6/10 | STILL_VALID | KEEP |
| S5 | Output Tailored to Audience | Enhancement | High | Survey Only | 6/10 | CHANGED | REWRITE |
| S7 | Project-Specific Skills Per Codebase | Enhancement | High | Survey Only | 6/10 | PARTIAL | RESCOPE |
| S9 | Deeper Interview Phase / Proactive Gap Detection | Enhancement | High | Survey Only | 5/10 | STILL_VALID | KEEP |
| C4 | Preflight: Content-Aware + Custom Script Checks | Enhancement | Medium | Consolidated | 5/10 | CHANGED | KEEP |
| G4 | Runtime-Value Branching | Enhancement | Medium | Gap Doc Only | 5/10 | STILL_VALID | KEEP |
| G1 | Auth Expiry / AuthLimit Dead Code | Bug | Medium | Gap Doc Only | 4/10 | CHANGED | REWRITE |
| S4 | Run Portability / Hand-Off | Enhancement | Medium | Survey Only | 4/10 | STILL_VALID | KEEP |
| S6 | Deployed Application | Feature | Medium | Survey Only | 4/10 | PARTIAL | RESCOPE |
| S8 | Jira Integration: Read + Write | Enhancement | Medium | Survey Only | 4/10 | PARTIAL | RESCOPE |
| G3 | Integration Branch Configurable | Enhancement | Low | Gap Doc Only | 3/10 | STILL_VALID | KEEP |
| S10 | Version History Across Runs | Enhancement | Low | Survey Only | 3/10 | STILL_VALID | KEEP |
| G2 | needs-review Emits No Notification | Enhancement | Low | Gap Doc Only | 2/10 | STILL_VALID | KEEP |
| G5 | On-Demand External Task Trigger + Evidence Injection | Enhancement | Low | Gap Doc Only | 2/10 | STILL_VALID | KEEP |
| G6 | External Job Invocation + Await / Ingest | Enhancement | Low | Gap Doc Only | 2/10 | STILL_VALID | KEEP |

**Total: 22 items** — 5 Critical · 6 High · 6 Medium · 5 Low

**v4 cross-validation rollup (2026-06-04):** 0 RESOLVED · 0 OBSOLETE · 15 STILL_VALID · 3 CHANGED (C4, G1, S5) · 4 PARTIAL (S1, S6, S7, S8). Actions: **16 KEEP** · **4 RESCOPE** (S1, S6, S7, S8) · **2 REWRITE** (G1, S5). v4 closed zero items; all file references were refreshed `core/*` → `src/*` in the per-item v4 callouts. Detail: [dotbot-backlog-v4-crossvalidation.md](dotbot-backlog-v4-crossvalidation.md).
