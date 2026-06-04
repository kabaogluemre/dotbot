# Dotbot Product Backlog — v4 Cross-Validation

**Date:** 2026-06-04
**Backlog under review:** [`docs/dotbot-product-backlog.md`](dotbot-product-backlog.md) (authored 2026-06-01 against `main @ 9dce2f4`)
**Validated against:** `main @ bc587c5` (v4 merge, #455) — `9dce2f4..HEAD` = 17 commits, **849 files, +51,004 / −38,947**
**Method:** Multi-agent investigation — two architecture-mapping passes + one investigator per backlog item, each verifying the item against the live v4 code and the `9dce2f4..HEAD` diff. High-stakes verdicts were earmarked for adversarial refutation; none arose (see below).

---

## Executive Summary

**Headline: v4 closed zero backlog items outright.** No item is `RESOLVED` and none is `OBSOLETE`. v4 was a large *structural and platform* release (a `core/` → `src/` relocation plus new `.NET server`, Fleet control-plane, Handoff, layered content, and per-repo artifact pipeline) rather than a release that targeted the pilot/gap backlog. As a result every item remains open, but several need their **framing or file references refreshed**.

### Verdict distribution

| Verdict | Count | Items |
|---|---|---|
| **STILL_VALID** — gap persists essentially unchanged | 15 | C1, C2, C3, C5, C6, G2, G3, G4, G5, G6, S2, S3, S4, S9, S10 |
| **CHANGED** — gap persists but the item's framing/paths are now wrong | 3 | C4, G1, S5 |
| **PARTIAL** — v4 delivered some criteria; meaningful work remains | 4 | S1, S6, S7, S8 |
| **RESOLVED** | 0 | — |
| **OBSOLETE** | 0 | — |

### Recommendation distribution

| Action | Count | Items |
|---|---|---|
| **KEEP** (valid as written; refresh paths only) | 16 | C1, C2, C3, C4, C5, C6, G2, G3, G4, G5, G6, S2, S3, S4, S9, S10 |
| **RESCOPE** (narrow remaining work around new v4 building blocks) | 4 | S1, S6, S7, S8 |
| **REWRITE** (problem framing now factually wrong) | 2 | G1, S5 |

### Cross-cutting findings (apply to almost every item)

1. **`core/*` → `src/*` relocation is universal.** Every item's file references are stale. The runtime now lives under `src/runtime/Modules/Dotbot.*`, MCP tools under `src/mcp/tools/`, the dashboard under `src/ui/`, the CLI under `src/cli/`, and workflow/skill/agent content under `content/`. Path updates are needed across the board even where the gap is unchanged.
2. **New v4 infrastructure is adjacent to several items but doesn't fulfill them.** The new **Fleet control-plane** (`src/ui/modules/FleetAPI.psm1`) + **Handoff** module (`src/runtime/Modules/Dotbot.Handoff`) touch S4/S6; the **`dotbot serve` HTTP runtime** + **`src/server-dotnet` notification PoC** touch S6; **`write-test-plan`/`write-unit-tests` skills** + **tester agent** touch S1; the **`12-publish-to-jira` prompt** touches S8; **layered `content/skills` + per-provider worktree copy** touch S7; the **per-repo artifact pipeline** changes S5's framing. These are building blocks, not completions.
3. **The approval-gate work (C2) regressed within v4 itself.** PR #449 (`merge-approval-documentReview`) was **reverted** (commit `69b6165`), and what it added was a per-*question* approval response type, not the per-*artifact/phase* workflow gates C2 asks for.
4. **One concurrency criterion (S3) was actively de-scoped.** `Get-MaxConcurrent` now hard-returns `1` (`src/ui/modules/ProcessAPI.psm1:292`) because per-slot fan-out overwhelmed the runtime — so S3's "concurrency improvement" criterion must be rethought as a bounded worker pool sharing one MCP, not process-per-slot.
5. **No false "done" claims.** Because no investigator concluded RESOLVED/OBSOLETE, the adversarial refutation stage had nothing to challenge — the conservative read held across all 22.

---

## Verdict & status legend

- **Verdict:** `STILL_VALID` · `CHANGED` · `PARTIAL` · `RESOLVED` · `OBSOLETE`
- **AC status:** `met` · `partial` · `unmet` · `unknown`
- **Recommendation:** `KEEP` · `RESCOPE` · `REWRITE` · `CLOSE` · `SPLIT`

---

## Summary Table (all 22 items)

| ID | Title | Orig. Priority | v4 Verdict | Conf. | Recommendation |
|---|---|---|---|---|---|
| C1 | Partial / In-Place Regeneration | Critical | STILL_VALID | high | KEEP |
| C2 | Workflow Modify Mode + Per-Artifact Approval Gates | Critical | STILL_VALID | high | KEEP |
| C3 | Back-Edges / Loops + Mid-Run Operator Guidance | Critical | STILL_VALID | high | KEEP |
| C4 | Preflight: Content-Aware + Custom/LLM Checks | Medium | CHANGED | high | KEEP (refresh paths) |
| C5 | Input Contract + Source Exclusion List | High | STILL_VALID | high | KEEP |
| C6 | PR-Based Integration + Multi-Repo Targets | High | STILL_VALID | high | KEEP |
| G1 | Auth Expiry / AuthLimit Dead Code | Medium | CHANGED | high | **REWRITE** |
| G2 | needs-review Emits No Notification | Low | STILL_VALID | high | KEEP |
| G3 | Integration Branch Configurable | Low | STILL_VALID | high | KEEP |
| G4 | Runtime-Value Branching | Medium | STILL_VALID | high | KEEP |
| G5 | On-Demand External Task Trigger + Evidence Injection | Low | STILL_VALID | high | KEEP |
| G6 | External Job Invocation + Await / Ingest | Low | STILL_VALID | high | KEEP |
| S1 | QA-Specific Workflows | Critical | PARTIAL | high | **RESCOPE** |
| S2 | Stuck Task Recovery / Kill Switch | Critical | STILL_VALID | high | KEEP |
| S3 | Performance: Speed Gap vs. Direct Claude | High | STILL_VALID | medium | KEEP |
| S4 | Run Portability / Hand-Off | Medium | STILL_VALID | high | KEEP |
| S5 | Output Tailored to Audience | High | CHANGED | high | **REWRITE** |
| S6 | Deployed Application | Medium | PARTIAL | high | **RESCOPE** |
| S7 | Project-Specific Skills Per Codebase | High | PARTIAL | medium | **RESCOPE** |
| S8 | Jira Integration: Read + Write | Medium | PARTIAL | high | **RESCOPE** |
| S9 | Deeper Interview Phase / Gap Detection | High | STILL_VALID | high | KEEP |
| S10 | Version History Across Runs | Low | STILL_VALID | high | KEEP |

---

## Items needing attention first (CHANGED / PARTIAL)

These six are where v4 actually moved something — they need editing, not just a path refresh.

### G1 — Auth Expiry / AuthLimit Dead Code → **REWRITE**
Gap fully persists, but the **type was renamed `AuthLimit` → `AuthError`** and moved to `src/runtime/Modules/Dotbot.Harness/Private/Failure.ps1`. Root cause for implementers: the sole consumer (`src/runtime/Scripts/Invoke-WorkflowProcess.ps1:1846`) calls `Get-FailureReason` with **empty Stdout/Stderr and `TimedOut=$false`**, so no text rule can ever match and only `.recoverable` is read — `.type` is never branched on. Rewrite the item to (a) rename to `AuthError`, (b) repoint paths, (c) note the real fix is feeding real harness output into the classifier *plus* a type-aware needs-input/re-auth branch.

### S5 — Output Tailored to Audience → **REWRITE**
The **HLD/LLD/Functional-Spec taxonomy the item is built on no longer exists** (0 matches across `content/` and `src/`). v4 replaced it with a per-repo artifact pipeline (`mission.md`, `roadmap-overview.md`, per-repo deep dives / implementation plans / handoffs). The audience-tailoring gap is real (no artifact declares an audience; no role-aware rendering — `src/ui/static/modules/product.js` is a generic markdown browser), but the "monolithic LLD" complaint is largely solved as a side effect of the multi-repo design. Rewrite against the v4 artifact set: add an audience field to prompt/frontmatter, drive depth from it, add an audience-aware preview to the product viewer; drop/narrow the per-system criterion.

### S1 — QA-Specific Workflows → **RESCOPE**
v4 added foundational pieces: **`content/skills/write-test-plan`** (test plan from spec + per-task-group scenario blocks → covers the per-component criterion), **`content/skills/write-unit-tests`**, and a **tester agent**. But there is still **no dedicated, discoverable QA workflow**, no push of test cases to Jira, no delta-driven test suggestions, and no usability target. Narrow to: (1) wrap the skills into a QA workflow, (2) push typed test cases to Jira, (3) delta-driven suggestions from PR/code-change summaries, (4) analyse existing repo automation as patterns, (5) define/measure the ≥60% target.

### S6 — Deployed Application → **RESCOPE**
v4 added real scaffolding: **`dotbot serve`** (authenticated per-project HTTP runtime), the **Fleet control-plane** (`FleetAPI.psm1` + `ControlPlaneClient.psm1`, runtimes self-register with a mothership that proxies commands), and an **Azure-deployed `src/server-dotnet`** — but that .NET server is explicitly a *"Multi-Channel Notification PoC"*, not the task engine, and **both the runtime and dashboard still bind to loopback only**. So runs still die with the launching machine. Narrow to: bind beyond loopback / host behind the control plane, simultaneous multi-user dashboard + per-user access control, and decouple run continuity from the launching machine.

### S7 — Project-Specific Skills Per Codebase → **RESCOPE**
Two of four ACs are effectively **met**: project skills install to `.bot/content/skills/` and are auto-copied into every worktree's provider skills dirs (`Copy-DotbotProviderContent`, `src/runtime/Modules/Dotbot.Worktree/Dotbot.Worktree.psm1:690`), and they're git-trackable/shareable. Remaining: (1) richer scoping than the flat `applicable_skills` name list (system/component/task-type), and (2) a first-class create/edit skill-library view in the **main** dashboard (studio-ui can create/edit but is a separate workflow editor; the control panel is read-only). *Confidence medium — much of this predates v4.*

### S8 — Jira Integration: Read + Write → **RESCOPE**
v4 introduced a **genuine Jira write path that didn't exist at base**: `content/workflows/start-from-jira/prompts/12-publish-to-jira.md` (wired into `workflow.json`) creates a single "DOTBOT" tracking issue (hardcoded type `Task`) and posts research summaries as comments via Atlassian MCP. It's narrow and QE-irrelevant: no typed test cases/test sets/sub-tasks, comments-only updates, partial idempotency (tracking issue de-duped, comments re-posted), and prompt-level (not enforced) error handling. Rescope to the QE gap: typed issue creation with issue-type mapping, description/status updates, comment-level idempotency, enforced error surfacing.

---

## STILL_VALID items (gap persists — KEEP, refresh paths only)

> All 15 below need `core/*` → `src/*` path updates; the gap and framing otherwise stand.

### C1 — Partial / In-Place Regeneration (Critical)
Reject still discards the worktree and regenerates from empty. `task-submit-review` calls `Reset-TaskWorktree` ("discard… so the next cycle starts clean"); `Build-TaskPrompt` has no prior-output/feedback channel. **New nuance:** reviewer feedback is now *persisted* (`extensions.review.feedback` accumulates) but is **never read back into the prompt** — so AC3's "accumulated" half is partly met, "injected and honoured" is unmet.
Key: `src/mcp/tools/task-submit-review/script.ps1:62`, `src/runtime/Modules/Dotbot.Worktree/Dotbot.Worktree.psm1:1861`, `src/runtime/Modules/Dotbot.Task/Dotbot.Task.psm1:34`.

### C2 — Workflow Modify Mode + Per-Artifact Approval Gates (Critical)
No modify mode (`workflow-run.ps1` always mints a fresh run; `workflow-start` MCP has no mode param), no phase/gate/approval concept in any `workflow.json`, no `pending-approval` state. The related PR #449 was **reverted** and was about per-question approval anyway. *Minor rescope: the "fresh/append modes unaffected" criterion assumes named modes that don't exist as an enum — only an implicit always-fresh path.*
Key: `src/cli/workflow-run.ps1:353`, `src/runtime/Modules/Dotbot.Task/Private/Transitions.psm1:8`, commit `69b6165`.

### C3 — Back-Edges / Loops + Mid-Run Operator Guidance (Critical)
Still a strictly forward DAG: `TaskDefinition` has a closed field allowlist (no `loop_back_to`), transitions are single-task only, `on_failure` only halts. Mid-run guidance is still a 500-char whisper; session-wide pause/resume exists but not per-task or scope/context redirect.
Key: `src/runtime/Modules/Dotbot.Workflow/Private/TaskDefinition.psm1:18`, `src/ui/modules/ControlAPI.psm1:219`.

### C5 — Input Contract + Source Exclusion List (High)
Engine rewritten but only carries forward producer-exit `Test-TaskOutput`; no consumer-entry input validation, no `inputs:` block in the extension-keys whitelist, no source exclusion. Greenfield: add a `Test-TaskInput` gate mirroring `Test-TaskOutput`, wire failures through `Set-WorkflowTaskNeedsInput`.
Key: `src/runtime/Scripts/Invoke-WorkflowProcess.ps1:655`, `src/runtime/Modules/Dotbot.Workflow/Dotbot.Workflow.psm1:887`.

### C6 — PR-Based Integration + Multi-Repo Targets (High)
Still direct squash-merge + `git push origin $baseBranch` (rejected on protected branches). No `gh pr create`/`az repos pr` primitive, no `targets:` settings block. *(A newer run-level `Complete-RunWorktree` preserves the branch for manual merge, but the task-level path wired into the loop still auto-merges.)*
Key: `src/runtime/Modules/Dotbot.Worktree/Dotbot.Worktree.psm1:1793`, `content/settings/settings.default.json`.

### C4 — Preflight: Content-Aware + Custom/LLM Checks (Medium) *(CHANGED)*
Still presence-only for the three built-ins; `mcp_server` checks registration, not reachability/auth. No `script`/`llm` types; unknown types fall through silently (no `else` branch). Logic moved into new `src/runtime/Modules/Dotbot.Workflow/Dotbot.Workflow.psm1` (`Convert-ManifestRequiresToPreflightChecks`, `Test-WorkflowRequires`) + execution in `src/ui/modules/ProductAPI.psm1:380`.

### G2 — needs-review Emits No Notification (Low)
`task-mark-needs-review` still only patches state; no notification, no `enter-needs-review` hook. **Now cheaper to fix:** `Send-TaskNotification` gained `-Type approval/documentReview`, `-ReviewLinks`, `-DeliverableSummary`, and the no-op-when-disabled plumbing already exists — wiring a call from the needs-review path is mostly mechanical.
Key: `src/mcp/tools/task-mark-needs-review/script.ps1:80`, `src/runtime/Modules/Dotbot.Notification/Dotbot.Notification.psm1:250`.

### G3 — Integration Branch Configurable (Low)
`Resolve-MainBranch` / `Resolve-WorkflowMainBranch` still loop only over `@('main','master')` — byte-for-byte identical to base. No `git.base_branch` setting anywhere.
Key: `src/runtime/Modules/Dotbot.Worktree/Dotbot.Worktree.psm1:147`, `.../Private/Worktree.psm1:136`.

### G4 — Runtime-Value Branching (Medium)
`condition` is still path-existence only (`Test-ManifestCondition`); unmet → `skipped` (`condition-not-met`), no alternative routing. `on_failure` persisted but has no engine consumer for control flow.
Key: `src/runtime/Modules/Dotbot.Workflow/Dotbot.Workflow.psm1:1540`, `src/runtime/Modules/Dotbot.Process/Dotbot.Process.psm1:634`.

### G5 — On-Demand External Task Trigger + Evidence Injection (Low)
No `task-append-evidence` tool exists (string appears only in the backlog). The only attachment path is bound to the question/answer `needs-input` flow — exactly the limitation called out. *Framing note: there is no MCP tool literally named `task-answer-question` in v4; the answer flow runs through `task-update` extensions + NotificationPoller/InboxWatcher — update AC3's reference.*
Key: `src/mcp/tools/` (31 tools, none append evidence), `src/runtime/Modules/Dotbot.Task/Dotbot.Task.psm1:1479`.

### G6 — External Job Invocation + Await / Ingest (Low)
Executors are `barrier, interview, mcp, prompt, script, task_gen` — no `external_job`. The `script` executor still runs synchronously and blocks the (serial, `max_concurrent=1`) runner. The dispatcher is extensible (discovered by `task_type`), so this is additive work.
Key: `src/runtime/Plugins/Executors/script/script.ps1:47`, `.../Dotbot.Executor/Private/Discovery.psm1:268`.

### S2 — Stuck Task Recovery / Kill Switch (Critical)
v4 ships per-**process** controls (Graceful Stop / Kill / kill-by-type / kill-all in the Processes tab) but **not per-task recovery**. Killing a process sets the process to `stopped` without touching the associated task — a task left `in-progress` stays stuck. No Reset/Force-Stop per task, no configurable stuck-timeout auto-flag, no diagnostic on the task. Only reset-to-todo path is review rejection (gated on `needs-review`).
Key: `src/ui/modules/ProcessAPI.psm1:147`, `src/ui/static/modules/roadmap-task-actions.js:474`, `src/ui/modules/TaskAPI.psm1:663`.

### S3 — Performance: Speed Gap vs. Direct Claude (High) *(conf. medium)*
No benchmark infra, no 2× target, and **within-run task concurrency is deliberately disabled** (`Get-MaxConcurrent` hard-returns 1). Partial progress on observability only: token usage is logged to the activity log (`ClaudeCodeAdapter.ps1:404`) but **not surfaced in the dashboard** (dashboard "costs" are static config estimates). Rescope the concurrency criterion toward a bounded worker pool sharing one MCP, and frame token work as "surface in UI."
Key: `src/ui/modules/ProcessAPI.psm1:292`, `src/runtime/Modules/Dotbot.Harness/Adapters/ClaudeCodeAdapter.ps1:404`.

### S4 — Run Portability / Hand-Off (Medium)
No export/import/adopt mechanism. Two adjacent new features: **Fleet** (remote *control* of runtimes on other machines — the run still executes on its origin) and the task-scoped **Handoff** module (human-in-the-loop pause/resume on the **same** machine). Live run state (`.control/`, `.handoffs/`, worktrees at absolute paths) is gitignored as machine-local. Build on Fleet/Handoff but the transfer flow is still missing.
Key: `src/ui/modules/FleetAPI.psm1:1`, `src/runtime/Modules/Dotbot.Handoff/Dotbot.Handoff.psm1:1`, `src/cli/init-project.ps1:229`.

### S9 — Deeper Interview Phase / Gap Detection (High)
Interview loop is generic and prompt-driven; the planning prompt **caps clarification at four questions / one round** and **explicitly forbids a parked open-questions surface** — the direct opposite of AC1/AC4. No contradiction detection, no structured gap report. The triage logic existed verbatim at base. **Design tension to resolve:** "thorough interrogation + persisted gap report" vs v4's deliberate capped, decision-record-based design.
Key: `src/runtime/Modules/Dotbot.Task/Dotbot.Task.psm1:1271`, `content/workflows/start-from-prompt/prompts/01-plan-product.md:255`.

### S10 — Version History Across Runs (Low)
A version-history + restore subsystem exists but is scoped to **roadmap task-definition edits** (`Write-TaskArchive`/`Get-TaskVersionHistory`/`Restore-TaskVersion`), triggered by manual mutations, with **no diff view** — and it existed at base, only relocated in v4. No artifact-level, run-triggered snapshots. Use the task-definition versioning as an architectural template, but the artifact use case is net-new.
Key: `src/mcp/modules/TaskMutation.psm1:284`, `src/ui/static/modules/roadmap-task-actions.js:588`.

---

## Suggested next steps

1. **Refresh the source backlog's path references** (`core/*` → `src/*`) across all 22 items — they are uniformly stale.
2. **Edit the two REWRITE items now** (G1: `AuthLimit`→`AuthError` + real root cause; S5: drop HLD/LLD taxonomy, reframe around the per-repo artifact pipeline) — leaving them as-is will mislead implementers.
3. **Rescope the four PARTIAL items** (S1, S6, S7, S8) to the *remaining* work, crediting v4's new building blocks so effort isn't duplicated.
4. **Re-confirm priorities post-v4.** Critical items C1/C2/C3/S2 are untouched by v4 and remain the highest-leverage gaps; S1 dropped from "no QA workflow" to "QA building blocks exist, no workflow wrapper."
5. The original [`docs/dotbot-product-backlog.md`](dotbot-product-backlog.md) was left **unmodified** per request; this document is the standalone cross-validation overlay.
