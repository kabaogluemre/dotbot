# dotbot core — engine gaps & hardening candidates

**Status:** Draft proposal — pending, not yet filed as issues
**Verified against:** `main` @ `793a535` (code-level sweep of `core/`, `scripts/`, `workflows/`)
**Audience:** dotbot maintainers

---

## What this is

While building two real-world workflows on top of dotbot — one that **authors documents** (reports/specs published to an external system) rather than source code, and one that **leans heavily on an external HTTP MCP server** with expiring auth — we hit a set of limitations that are *not* specific to those workflows. They are general dotbot-engine gaps that any of the following would also hit:

- any workflow whose primary output is **markdown/documents** rather than code (dotbot already ships one — `start-from-jira`, with its `researcher`/`documenter` agents and research-mode prompt);
- any workflow that **re-runs a task to refine its previous output** (e.g. after a review rejection) instead of regenerating from scratch;
- any workflow that depends on an **external MCP server with OAuth/refresh-token auth** that can expire mid-run;
- any package that wants to **ship reusable slash commands** to the IDE, the same way it already ships agents and skills;
- any workflow that, after completion, must be re-run to **update its already-published outputs** (whole-pipeline modification) rather than regenerate everything from scratch.

Each item below is written to stand on its own as a candidate GitHub issue: observed behaviour with code references, why it matters in general terms, a non-prescriptive proposed direction, and acceptance criteria. Workflow-specific content (the actual agents, prompts, integrations) is **out of scope** here — these are only the engine-level enablers.

Several of these are natural extensions of patterns dotbot already has:
- Issue 5 extends the org-quota → needs-input park added in #391/#402 to a second trigger class.
- Issue 2 promotes the hand-rolled "research execution mode" in `start-from-jira` into a first-class mode.
- Issue 6 adds a third artifact type alongside the agents/skills that `core/init.ps1` already deploys to IDEs.

---

## Summary

| # | Title | Type | Area | Size |
|---|-------|------|------|------|
| 1 | Non-code task output is squash-merged into the code branch (no output-disposition guard) | Bug | runtime / worktree | S–M |
| 2 | No first-class "document / non-code task" mode (code framing + unsafe defaults per task) | Enhancement | runtime / prompts | S–M |
| 3 | Re-run regenerates from scratch — no partial / in-place regeneration of prior output | Enhancement | runtime / task + workflow rerun | L |
| 4 | MCP-server preflight is presence-only — a dead/unauthenticated server passes | Bug | ui / preflight | S |
| 5 | External-MCP auth expiry wedges silently mid-run; `AuthLimit` classification is dead code | Bug | runtime / failure handling | M |
| 6 | `init` deploys agents and skills to IDEs but not slash commands | Enhancement | init / IDE artifacts | M |
| 7 | No workflow-level *modification* re-run mode — whole-workflow rerun is fresh-from-scratch only (workflow-scoped Issue 3) | Enhancement | runtime / workflow rerun | L–XL |
| 8 | Tasks entering `needs-review` emit no notification (only `needs-input` notifies) | Enhancement | runtime / notifications | S |
| 9 | Integration/base branch is hard-coded to `main`/`master` — not configurable | Enhancement | runtime / worktree + git | S–M |
| 10 | No first-class PR-based integration; core only direct-merges, PR creation reinvented per workflow | Enhancement | runtime / git integration | M–L |
| 11 | Workflow execution is a strictly forward DAG — no back-edge / loop to an earlier phase on review reject or failure | Enhancement | runtime / control flow | XL |
| 12 | No runtime-value branching — `condition` is path-existence only; cannot route on a prior task's output value | Enhancement | runtime / control flow | M–L |
| 13 | No consumer-entry input contract — tasks have no `inputs:` declaration and no artifact pre-check before execution | Enhancement | runtime / task contract | M–L |
| 14 | Preflight is fixed and presence-only — no custom-script and no LLM-driven check support (core change) | Enhancement | runtime / preflight | M |
| 15 | No on-demand external task/workflow trigger that feeds evidence into an in-flight task | Enhancement | runtime / task IO + orchestration | M–L |
| 16 | Multi-repo / cross-repo targets are not a first-class engine concept — engine is locked to one project repo | Enhancement | runtime / git + worktree + settings | L–XL |
| 17 | No external (non-Claude) job invocation + await/ingest primitive — only synchronous local scripts | Enhancement | runtime / process types | M |

---

## Issue 1 — Non-code task output is squash-merged into the code branch

**Type:** Bug · **Area:** runtime / worktree · **Size:** S–M

### Summary
A task whose output is **not source code** (markdown reports, generated docs, analysis artifacts) has no supported way to keep that output *off* the code branch. When such a task runs inside a worktree, its `workspace/product/*` artifacts are committed to the task branch and carried through the squash-merge into the base branch. Additionally, because `workspace/product/` is a junction into shared state, agent writes are not actually isolated to the worktree.

### Current behaviour
- `workspace/product/` inside a worktree is a **directory junction/symlink to the main repo's shared `workspace/product/`** — so any write inside the worktree lands directly in shared state, not in an isolated copy: `core/runtime/modules/WorktreeManager.psm1:565-578` (`New-DirectoryLink`).
- On a `task/*` branch, the bot-state commit step excludes only `workspace/tasks/`, **not** `workspace/product/` — so `product/*` is staged and committed to the task branch: `core/hooks/scripts/commit-bot-state.ps1:29-34`.
- At completion, `Complete-TaskWorktree` backs up and restores only the `tasks/` state directories across the squash-merge; `product/` is reset pre-merge but **not** restored, so `product/` changes flow into the merge commit on the base branch: `core/runtime/modules/WorktreeManager.psm1:693-764`.

Net effect: a document-authoring task leaks its artifacts into the code branch's history, and its "isolated" writes aren't isolated.

### Why it matters
dotbot already ships a document-producing workflow (`start-from-jira`), and any workflow that generates reports/specs/analysis as its deliverable will hit this. For these, the markdown is meant to be *published elsewhere* (or simply discarded after handoff), not merged into the product's source tree. There is currently no declarative "this output is not source code — keep it off the code branch" concept.

### Proposed direction (non-prescriptive)
One or more of:
- A per-task / per-workflow **output disposition** declaration (e.g. `output_target: none|branch|external`) that, when set to non-branch, gitignores or excludes the declared output paths from the task-branch commit and the squash-merge.
- Discard the worktree without merging when a task declares it produces no source-code changes.
- Decide whether `workspace/product/` should be a real isolated copy in worktrees rather than a junction (or document the junction behaviour as intentional and add the guard above on top).

Related to Issue 2 (the unsafe defaults that cause document tasks to get a worktree in the first place).

### Acceptance criteria
- [ ] A task can declare that its output is not source code, and that output never appears in the base-branch history after completion.
- [ ] Writes from such a task do not silently mutate shared `workspace/product/` outside the task's lifecycle (or this is explicitly documented as intended).
- [ ] Existing code-task behaviour is unchanged.

---

## Issue 2 — No first-class "document / non-code task" mode

**Type:** Enhancement · **Area:** runtime / prompts · **Size:** S–M

### Summary
The framework's execution prompts assume a code-implementation framing, and a `type: prompt` task defaults to getting both an analysis phase and a worktree. Authoring a document-only task therefore requires hand-wiring several flags plus a custom prompt template on every task. There is no packaged "document mode" — and one workflow has already had to roll its own.

### Current behaviour
- The core execution prompt is code-centric: TDD guidance, incremental commits, dependency-lockfile handling, "start with `files.to_modify`": `core/prompts/99-autonomous-task.md:134-155`, `:125`. The analysis prompt is framed as preparing a code implementation: `core/prompts/98-analyse-task.md:72`.
- For `type: prompt` tasks, both `skip_analysis` and `skip_worktree` **default to `false`** — i.e. a prompt task gets analysis + a worktree unless each flag is explicitly overridden: `core/runtime/modules/workflow-manifest.ps1:586-587`.
- A `type: prompt_template` override exists to swap the execution prompt per task: `core/runtime/modules/ProcessTypes/Invoke-WorkflowProcess.ps1:818-833`. It works, but it's per-task plumbing, not a mode.
- `start-from-jira` has already hand-rolled a "research execution mode" by dispatching on `analysis.mode == "research"` inside its own copy of the 99 prompt: `workflows/start-from-jira/recipes/prompts/99-autonomous-task.md:84-101`. This is exactly the gap — the pattern exists but is reinvented per workflow.

### Why it matters
Document-authoring is a recurring use case (already in-tree). Today each such task is a footgun: forget to set `skip_worktree`/`skip_analysis` and you get a worktree you don't want (see Issue 1) and a code-framed prompt steering a non-code task. The behaviour ends up depending on three independent knobs being set correctly by hand.

### Proposed direction (non-prescriptive)
- A first-class mode (e.g. `type: document` or `mode: doc`) that bundles safe defaults (skip the worktree and/or code-analysis phase as appropriate) and a document-framed execution prompt, so workflows stop reinventing the `start-from-jira` research branch.
- Alternatively, promote the existing research-mode dispatch into the core 98/99 prompts behind a documented analysis-mode flag.

### Acceptance criteria
- [ ] A workflow can declare a document/non-code task in one place and get sensible defaults without per-task flag wiring.
- [ ] The execution prompt presented to such a task is not code-framed.
- [ ] `start-from-jira`'s research mode can be expressed via the new mode (or the mode is shown to subsume it).

---

## Issue 3 — Re-run regenerates from scratch — no partial / in-place regeneration of prior output

**Type:** Enhancement · **Area:** runtime / task + workflow rerun · **Size:** L

### Summary
When a task *or* a workflow is re-run, the prior output is not available as an **editable base** — both levels regenerate from scratch (the task from an empty worktree, the workflow from the static manifest). There is no way to regenerate only the changed sections (partial / delta). Reviewer feedback is already handled well; what is missing is *retaining the prior artifact and editing on top of it*.

### Current behaviour
- **Feedback handling — already works (do not rebuild this):** on rejection a `comment` is mandatory and `reviewer_feedback` is accumulated across cycles (`core/mcp/tools/task-submit-review/script.ps1:41-57`), then injected into **both** `core/prompts/98-analyse-task.md` and `core/prompts/99-autonomous-task.md` via the `{{REVIEWER_FEEDBACK}}` placeholder, under a "you MUST address ALL of the following feedback" heading (`core/runtime/modules/prompt-builder.ps1:141-155`).
- **Task level:** on reject, `Reset-TaskWorktree` removes the worktree and branch, the task returns to `todo`, and execution-phase fields are cleared — the next cycle starts in an empty worktree (`core/mcp/tools/task-submit-review/script.ps1:64-82`, `core/runtime/modules/WorktreeManager.psm1:941-952`). The prior draft files are gone.
- **Workflow level:** `workflow-run.ps1` rerun supports only `fresh` (clear existing tasks + recreate from the manifest) or `append`; neither feeds the prior canonical output back as input (`scripts/workflow-run.ps1:83-134`).
- Output is validated only by file existence / count (`Test-TaskOutput`, `core/runtime/modules/ProcessTypes/Invoke-WorkflowProcess.ps1:131-190`); there is no content-level diff / patch / partial-update primitive (only git merge-conflict handling exists).

### Why it matters
For any workflow producing a large or structured artifact that evolves over time, regenerating from scratch is both wasteful and risky: the whole thing is rewritten when only one section changed, and stable internal structure that was not explicitly captured (internal IDs, section ordering) can drift. Feedback is already fed back in — the missing piece is partial regeneration on top of the retained prior output.

This also settles what happens when a workflow is re-triggered (manually today, or programmatically per Issue 7): it **regenerates from scratch** — `workflow-run.ps1` `fresh` wipes and recreates the tasks from the manifest — so re-running an upstream stage after a downstream change produces a brand-new artifact rather than a modification of the prior one. (An agent can be prompted to read the prior published artifact and re-author it, but that is recipe content and still a full re-author, not an engine-level delta with stable IDs preserved.) Modification-mode re-run is *this* issue; the trigger mechanism is Issue 7.

### Proposed direction (non-prescriptive)
- On rerun, retain the prior output as editable input rather than discarding the worktree.
- A delta-aware update that regenerates only the changed sections; if stable internal IDs are in scope, preserve them across reruns.
- Exploratory — the architectural shape (a separate "modify" mode, a post-pass, or in-prompt) is for maintainers to decide.

### Acceptance criteria
- [ ] A task/workflow can be re-run with its previous output available as an editable base (not from an empty worktree / a manifest wipe).
- [ ] Only the changed parts can be regenerated, guided by the cumulative feedback.
- [ ] The existing feedback injection is preserved.

---

## Issue 4 — MCP-server preflight is presence-only

**Type:** Bug · **Area:** ui / preflight · **Size:** S

### Summary
The preflight check for a required MCP server passes as long as the server *name* is registered — it never connects, invokes, or validates auth. A server that is registered but unreachable or holding a dead token passes preflight and then wedges the workflow mid-run.

### Current behaviour
- `Get-PreflightResults` resolves an `mcp_server` check by looking for the server name in `.mcp.json`, falling back to a regex match against `claude mcp list` output; `passed` is set purely on name presence: `core/ui/modules/ProductAPI.psm1:388-416`.
- `scripts/doctor.ps1` performs only local health checks (dependencies, settings/theme JSON validity, process locks, orphaned worktrees, task-queue health, output hygiene) — it never probes external MCP reachability or auth: `scripts/doctor.ps1:65-295`.
- dotbot is not itself an MCP client for external servers; it relies on the Claude CLI's cwd-based `.mcp.json` discovery and does not pass `--mcp-config` when spawning Claude: `core/runtime/ClaudeCLI/ClaudeCLI.psm1:480-499`, `:585-589`. So a real probe has to go through `claude mcp` or an equivalent connectivity test rather than introspecting a live client.

### Why it matters
Any workflow that lists an external MCP server as a precondition gets false confidence from the green preflight. The failure then surfaces deep inside a run as a confusing tool error rather than up front as "this server isn't reachable / not authenticated."

### Proposed direction (non-prescriptive)
- Upgrade the `mcp_server` preflight from name-presence to an actual connectivity/auth probe (e.g. a lightweight tool listing or handshake), so a dead or unauthenticated server fails preflight.
- Optionally surface the same probe in `doctor.ps1`.

### Acceptance criteria
- [ ] A registered-but-unreachable or unauthenticated MCP server fails preflight with an actionable message.
- [ ] A healthy server still passes.

---

## Issue 5 — External-MCP auth expiry wedges silently; `AuthLimit` is dead code

**Type:** Bug · **Area:** runtime / failure handling · **Size:** M

### Summary
When an external MCP server's auth expires mid-run (e.g. an OAuth/refresh token reaching its TTL), the failure is not recognised as an auth problem — it collapses into the generic recoverable retry/skip path. The failure classifier *does* produce an `AuthLimit` type, but nothing consumes it. The runtime already has a clean "park to needs-input" pattern (added for org quota in #391/#402) that this should reuse.

### Current behaviour
- `get-failure-reason.ps1` returns `type = "AuthLimit"` for auth-flavoured patterns (`unauthorized`, etc.): `core/runtime/modules/get-failure-reason.ps1:58`.
- The consumer only reads `.recoverable` and ignores `.type`, so `AuthLimit` never changes behaviour — it's effectively dead: `core/runtime/modules/ProcessTypes/Invoke-WorkflowProcess.ps1:1803-1811`.
- There is **no matcher** anywhere for "refresh token expired" / "re-authentication required" / token-TTL conditions (confirmed by repo-wide search).
- The park-to-needs-input machinery exists and is live, but is hard-keyed to org/monthly quota only: `Move-TaskToOrgQuotaNeedsInput` in `core/runtime/modules/OrgQuotaEscalation.psm1:15-90`, invoked via `Invoke-OrgQuotaEscalationStep` at `core/runtime/modules/ProcessTypes/Invoke-WorkflowProcess.ps1:460-500`, `:1340-1346`, `:1697-1702`. The agent-driven equivalent is the `task_mark_needs_input` tool (`core/mcp/tools/task-mark-needs-input/`).

### Why it matters
External MCP servers with expiring credentials are common. Today, when the token dies mid-run, the workflow silently retries/skips instead of telling the operator to re-authenticate — the run wedges or quietly degrades. The fix is mostly *wiring*: a matcher plus a second trigger into the park pattern that #391 already established.

### Proposed direction (non-prescriptive)
- Add a matcher for auth-expiry / re-auth-required tool errors (and wire the existing `AuthLimit` classification so it stops being dead).
- Route that to a needs-input park mirroring `Move-TaskToOrgQuotaNeedsInput`, with a re-authentication prompt, so the run resumes from the pause after the operator re-auths rather than restarting.
- Generalising the org-quota escalation into a small "park reason" abstraction (quota | auth | …) would keep this DRY.

### Acceptance criteria
- [ ] An auth-expiry/re-auth tool error is detected and routed to a needs-input park with an actionable re-auth prompt — no silent retry/skip.
- [ ] The task resumes from the park after re-auth rather than rebuilding.
- [ ] `AuthLimit` is either consumed or removed (no dead classification).

---

## Issue 6 — `init` deploys agents and skills to IDEs but not slash commands

**Type:** Enhancement · **Area:** init / IDE artifacts · **Size:** M

### Summary
`core/init.ps1` deploys `agents/` and `skills/` into the IDE config directories (`.claude`, `.codex`, `.gemini`), but there is no path for deploying custom **slash commands** (`.claude/commands/` and equivalents). A package therefore cannot ship reusable, individually-triggerable IDE commands the way it ships agents and skills — the things the README calls "slash commands" are actually skills (model-invoked), not Claude Code slash commands (user-invoked).

### Current behaviour
- `core/init.ps1` resolves an agents source and a skills source and copies them to the provider IDE directories; there is no commands source or `.../commands` destination: `core/init.ps1:54-105`.
- The README's "slash commands" (`/status`, `/verify`, …) map to entries under `core/skills/`, i.e. skills, not real slash commands.

### Why it matters
Claude Code (and peers) support user-invoked custom slash commands as a first-class artifact distinct from skills. Workflows that want to expose a set of discrete, manually-triggered steps to engineers in their IDE — rather than only model-invoked skills or a runtime-driven DAG — currently have no supported deployment channel. This is a clean third artifact type alongside the agents/skills `init` already handles.

### Proposed direction (non-prescriptive)
- Add a commands artifact type (e.g. `recipes/commands/`) and deploy it to `.claude/commands/` (and the codex/gemini equivalents) in `init.ps1`, parallel to the existing agents/skills deployment.
- Clarify README terminology so "slash commands" vs "skills" is unambiguous.

### Acceptance criteria
- [ ] A workflow/package can ship slash commands that land in `.claude/commands/` (and equivalents) on `init`.
- [ ] Existing agents/skills deployment is unaffected.
- [ ] README distinguishes skills from slash commands.

---

## Issue 7 — No workflow-level "modification" re-run mode (whole-workflow rerun is fresh-from-scratch only)

**Type:** Enhancement · **Area:** runtime / workflow rerun · **Size:** L–XL

### Summary
Re-running a *whole* completed workflow has no "modification" mode. `workflow-run.ps1` supports only `fresh` (wipe all tasks and regenerate the entire pipeline from the manifest) or `append`. There is no mode in which the whole workflow re-runs against its **prior published / canonical artifacts and updates them** — applying deltas across all of the workflow's outputs and preserving continuity. This is the workflow-scoped analogue of the task-level modification re-run (Issue 3): same capability, applied to the entire pipeline rather than a single task.

### Current behaviour
- `workflow-run.ps1` rerun modes are `fresh` (default — `Clear-WorkflowTasks` removes existing tasks, then recreate from the manifest) and `append`; neither feeds the workflow's prior canonical output back as a modifiable base (`scripts/workflow-run.ps1:83-108`, default at `:85`).
- Re-running therefore regenerates every task's artifact from scratch — there is no whole-workflow "update what already exists" pass.
- There is no first-class "workflow run" entity to re-enter or modify — the active workflow is resolved purely from `settings.workflow` (`core/runtime/modules/workflow-manifest.ps1:201-250`).

### Why it matters
When a completed workflow's inputs change, teams want to re-run the workflow to **update its already-published outputs** — not regenerate the whole pipeline from scratch and lose continuity across all its artifacts (stable IDs, unchanged sections, cross-artifact references). Today the only whole-workflow rerun is `fresh`, which discards the prior result and rebuilds. This is the workflow-level counterpart of Issue 3 and the largest item: it applies the same prior-output-as-editable-base / delta-update primitives across the whole DAG.

### Proposed direction (non-prescriptive)
- A `modify` rerun mode for `workflow-run.ps1` (alongside `fresh` / `append`) in which the workflow re-runs against its prior canonical / published artifacts and updates them in place.
- Reuse the task-level modification machinery (Issue 3) across every task in the run; preserve stable identifiers and unchanged sections workflow-wide.
- How the rerun is *triggered* (operator or otherwise) is out of scope — manual trigger already works (`workflow-run.ps1`).

### Acceptance criteria
- [ ] `workflow-run.ps1` supports a modification rerun mode that updates the workflow's prior published artifacts rather than wiping and regenerating from the manifest.
- [ ] Across the whole run, unchanged artifacts/sections and stable IDs are preserved; only deltas are applied.
- [ ] The existing `fresh` / `append` modes are unaffected.

---

## Issue 8 — Tasks entering `needs-review` emit no notification

**Type:** Enhancement · **Area:** runtime / notifications · **Size:** S

### Summary
Moving a task to `needs-review` (the review-gate state) emits no notification — only `needs-input` does. A reviewer is therefore not told when work is ready for review; they have to watch the UI (or rely on the optional mothership task sync). Any review-gated workflow is affected.

### Current behaviour
- Notifications fire only from the `needs-input` paths — `task-mark-needs-input` calls `Send-TaskNotification` / `Send-SplitProposalNotification` (`core/mcp/tools/task-mark-needs-input/script.ps1`) — and from merge-conflict escalation (`core/runtime/modules/MergeConflictEscalation.psm1`).
- `core/mcp/tools/task-mark-needs-review/script.ps1` has no notification call — the transition to `needs-review` is silent.
- Other lifecycle events (task done, workflow complete, errors/quota) also don't notify, but `needs-review` is the salient one because it is a human gate that blocks progress.

### Why it matters
Review gates are a core feature (`needs-review`, `task-submit-review`, reject-with-feedback rerun all exist), but the person who must act on the gate isn't told it's their turn. For asynchronous teams a workflow can silently park on a review nobody knows is waiting.

### Proposed direction (non-prescriptive)
- Emit a notification on transition to `needs-review` (reuse `Send-TaskNotification`), addressed to the review recipients, linking to where the reviewer acts.
- Optionally generalise into a small notification-on-state-change hook so other gate states can opt in.

### Acceptance criteria
- [ ] Entering `needs-review` emits a notification (when notifications are enabled) to the configured recipients, with a link to act on it.
- [ ] No-op when notifications are disabled, consistent with the existing `needs-input` behaviour.

---

## Issue 9 — Integration/base branch is hard-coded to `main`/`master`

**Type:** Enhancement · **Area:** runtime / worktree + git · **Size:** S–M

### Summary
The branch that task worktrees are created from and squash-merged back into is resolved purely by name — only `main` or `master`. There is no setting to point it at a different integration branch (`develop`, `trunk`, a release line). A repo whose trunk is named anything else cannot be used without renaming.

### Current behaviour
- `Resolve-MainBranch` finds the integration branch by explicit name lookup over `@('main','master')` only, and deliberately does not read symbolic HEAD: `core/runtime/modules/WorktreeManager.psm1:141-155`.
- Worktree creation branches off that base; if neither `main` nor `master` exists it throws, instructing the user to rename their integration branch: `:490-494` (error at `:491-492`).
- The base branch chosen at creation is recorded on the worktree entry (`base_branch`) and reused at completion, immune to HEAD drift: `:466`, `:589`, `:647`.
- No `branch` / `base_branch` / `default_branch` key exists in settings (`core/settings/settings.default.json`).

### Why it matters
Many repositories integrate on a branch other than `main`/`master` (`develop`, `trunk`, a release line). Today dotbot forces a rename, which is a non-starter for established repos and team conventions. Making the integration branch configurable is a small, generic change with broad applicability.

### Proposed direction (non-prescriptive)
- Have `Resolve-MainBranch` read a configurable integration branch (e.g. `git.base_branch`) from settings, falling back to the current `main`/`master` lookup when unset.
- Thread the resolved value through worktree creation, the `base_branch` record, and `Complete-TaskWorktree` (these already use a single resolved value, so the change is localized).

### Acceptance criteria
- [ ] The integration/base branch can be configured (per-project / per-user) and is honoured by worktree creation and squash-merge.
- [ ] When unset, behaviour is unchanged (`main`/`master` lookup).
- [ ] A repo whose trunk is e.g. `develop` works without renaming.

---

## Issue 10 — No first-class PR-based integration; core only direct-merges, PR creation reinvented per workflow

**Type:** Enhancement · **Area:** runtime / git integration · **Size:** M–L

### Summary
Core integrates a completed task by squash-merging its branch into the base branch locally and then pushing the base branch straight to the remote. There is no option to integrate via a pull request, and no shared PR primitive — every workflow that wants a PR hand-rolls it with a provider-specific CLI. On a protected / PR-required base branch, the direct push is rejected.

### Current behaviour
- On approval, `Complete-TaskWorktree` squash-merges the task branch into the base branch (`core/runtime/modules/WorktreeManager.psm1:615`, `:647`) and then **pushes the base branch directly to `origin`** — `git push origin $baseBranch` (`:838-849`). No PR is opened.
- Core has no PR-creation capability. PRs exist only as workflow content and are provider-specific: `start-from-jira` opens an ADO PR via `az repos pr create --draft` in a prompt (`workflows/start-from-jira/recipes/prompts/11-draft-system-docs.md:198-206`); a GitHub `gh pr` reference exists only as manual guidance in `core/prompts/05-retrospective-task.md`. There is no `gh` integration path and nothing shared across workflows.
- Result: a direct push to a protected base branch fails, and any workflow needing PR-based integration reinvents "push branch → open PR" per provider.

### Why it matters
PR-based integration is the norm for most teams (protected `main`, required reviews/checks, CI on PRs). Today dotbot's only integration mode is a direct merge + push, which neither fits protected branches nor gives a review surface on the remote. Because PR creation is reinvented per workflow and per provider, the same logic is duplicated and ADO-only. A generic PR integration mode would let any workflow opt into PR-based delivery without custom code, and would naturally consume the configurable base branch from Issue 9.

### Proposed direction (non-prescriptive)
- A first-class integration mode (alongside the existing direct squash-merge) that pushes the task branch and opens a PR against the (configurable — Issue 9) base branch, instead of merging + pushing locally.
- A shared, provider-aware PR primitive (GitHub `gh` and ADO `az` at minimum) — a task type, MCP tool, or completion option — so workflows stop reinventing it.
- PR metadata (title, body with task/links, draft flag) supplied by the workflow; the mechanics (push, provider detection, PR open) provided by core.

### Acceptance criteria
- [ ] A task/workflow can choose PR-based integration instead of direct merge + push.
- [ ] PR creation works for at least GitHub and ADO via a shared primitive (no per-workflow reimplementation).
- [ ] The PR targets the configurable base branch (Issue 9); the existing direct-merge mode remains the default and is unaffected.

---

## W2-derived engine gaps (Issues 11–17)

A third workflow has since been examined on top of dotbot: a test-execution + automation pipeline (W2) whose diagram-level shape exposes engine gaps independent of the workflow-content concerns that drove Issues 1–10. These were derived by reading the W2 diagram directly and asking "could a dotbot workflow express this shape if we wanted it to?" For several load-bearing features the answer is no.

W2's chosen *delivery* architecture (a library of IDE-triggerable slash commands rather than a runtime-driven DAG) is a deliberate design tangent and is **not** raised here as a dotbot gap. The items below are the underlying *engine-shape* gaps that would block the W2 pipeline if anyone tried to express it as a dotbot workflow — and that block any third workflow with the same shape, regardless of UI choice.

All items below are verified against the current `main` of `core/`; each carries an explicit **W2 diagram reference** in addition to the standard sections.

---

## Issue 11 — Workflow execution is a strictly forward DAG — no back-edge / loop to an earlier phase

**Type:** Enhancement · **Area:** runtime / control flow · **Size:** XL

### Summary
Workflow execution is a forward-only DAG: a task in a terminal state (`done`/`split`/intentional-skip) never re-enters the pickable set, and there is no back-edge / goto / loop construct. The only re-do is "this one task from scratch" (review reject restarts the same task from an empty worktree). Many real workflows need to loop back several phases on a late-stage rejection or after an auto-fix and re-run forward from there — that cannot be expressed today.

### Current behaviour
- Eligibility is "all dependencies are in a satisfied terminal state": `Test-AllDependenciesMet` / `Test-DependencyMet` at `core/mcp/modules/TaskIndexCache.psm1:759-800`; terminal states at `:942-968`. Done tasks stay terminal — nothing moves them back to `todo`.
- Review reject (`core/mcp/tools/task-submit-review/script.ps1:39-98`) returns the **same single task** to `todo` with accumulated `reviewer_feedback`, clears execution fields, and discards the worktree via `Reset-TaskWorktree` (`:82`). It does not route flow to an earlier different phase and does not re-run any downstream task.
- Feedback is injected into the re-run prompt via `{{REVIEWER_FEEDBACK}}` (`core/runtime/modules/prompt-builder.ps1:141-155`) — but it is a self-loop on one task, not a back-edge in the DAG.
- The only iterative constructs are operational poll/retry loops (`core/runtime/modules/ProcessTypes/Invoke-WorkflowProcess.ps1:608-714` task-pickup wait, `$maxRetriesPerTask = 2` at `:592`) — they are runner-level retries, not workflow control-flow cycles.
- `on_failure` field is persisted on task JSON (`workflow-manifest.ps1:627`) but **has no engine consumer** (writer + test only; no reader anywhere in `core/`).

Result: "loop back to phase X and re-run forward" is structurally inexpressible.

### W2 diagram reference
- 2.6 reject → 2.5 (1 step back)
- 2.9 reject → 2.8 (1 step back)
- 2.12b *"re-run loop → back to 2.10 or 2.11"* after auto-fix (2–3 steps back)
- 2.15 reject → *"return to relevant step"* (2–10 steps back: codegen issue → 2.8; TC issue → 2.5; Test Run issue → 2.13)

### Why it matters
Any workflow with a real failure-recovery or review-revision pattern — auto-fix → re-run execution; late-gate rejection that invalidates several earlier phases — cannot be expressed. The only re-do dotbot can model is "same task, empty worktree, retry." For pipelines whose late gates can send flow several phases back, this means the workflow either cannot run as a DAG at all, or every back-edge has to be approximated by hand (extra `todo` tasks, sentinel files, operator intervention).

### Proposed direction (non-prescriptive)
One or more of:
- A workflow-level "loop back to phase X" primitive: when invoked (by a review-reject path, a failure handler, or an agent), the named phase and every dependent downstream task return to their initial state and the chain re-runs forward.
- A `reject_target` / `loop_back_to` field on review gates and failure handlers that names which earlier phase rollback applies to.
- Architectural decisions (state retention vs. discard across rolled-back phases, partial-output preservation per Issue 3) settled in implementation design.

### Acceptance criteria
- [ ] A workflow can declare or trigger "loop back to phase X" semantics; X and every dependent downstream task return to their initial state and re-run forward.
- [ ] Multi-step back-jumps (≥ 3 phases) work without manual queue surgery.
- [ ] Existing single-task `reject → redo same task` behaviour is preserved as a special case.

---

## Issue 12 — No runtime-value branching — `condition` is path-existence only

**Type:** Enhancement · **Area:** runtime / control flow · **Size:** M–L

### Summary
The `condition` field is a filesystem path-existence predicate only. An unmet condition skips the task rather than routing to an alternative branch. There is no `when` / `case` / `switch` / `route` keyword anywhere in the manifest layer. Workflows cannot branch on a value emitted at runtime by an earlier task (e.g. a classification result, a yes/no decision).

### Current behaviour
- `Test-ManifestCondition` (`core/runtime/modules/ManifestCondition.psm1:1-71`) is path-existence + glob only: `Test-Path $fullPath` and glob match against the project root (`:61-65`). No value comparison, no JSON field lookup, no prior-task output reference.
- Unmet condition → task moved to `skipped/` with `skip_reason: condition-not-met` (`core/mcp/tools/task-get-next/script.ps1:104-110`). Not routed to an alternative branch.
- A repo-wide search for `when` / `case` / `switch` / `route` / `else_task` in `workflow-manifest.ps1` and `core/` returns zero matches.
- `on_failure` field is written on the task JSON (`workflow-manifest.ps1:627`) but no engine code reads it — the failure-routing key is effectively dormant.

### W2 diagram reference
- 2.2 *Drift detected? Yes → trigger W1 rerun · No → continue* (boolean routing on the 2.1 delta-report value).
- 2.12 *Failure classification* → `system_bug → 2.12a` · `bad_test / flaky / environment → 2.12b` (multi-way value routing).

### Why it matters
Real workflows branch on data: "if drift detected → trigger upstream rerun, else continue"; "if classification = system_bug → create dev bug, else attempt auto-fix"; "if no existing TCs in area → only run the new-TC path." Today the only approximation is multiple `condition`-gated parallel tasks each gated on a different sentinel file the upstream task happens to write — fragile, cannot express exclusive either/or, and forces structured outputs to be encoded as filesystem state.

### Proposed direction (non-prescriptive)
- A value-aware routing primitive — e.g. a `route_on:` block referencing a prior task's structured output, with named branches that map values to downstream task subsets.
- Or extend `condition` with comparisons against a typed output value (requires Issue 13's input contract).
- Plays cleanly with Issue 11 (cycles): a route target may be a downstream branch *or* a back-edge.

### Acceptance criteria
- [ ] A task can declare branch routing on a prior task's runtime output value.
- [ ] Tasks on a non-selected branch are not run (vs. today's only option of "task is skipped because path missing").
- [ ] The existing path-existence `condition` semantics remain valid for migration.

---

## Issue 13 — No consumer-entry input contract — tasks have no `inputs:` declaration and no artifact pre-check

**Type:** Enhancement · **Area:** runtime / task contract · **Size:** M–L

### Summary
Tasks have no declared input contract. A consumer task starts as soon as its upstream tasks are in `done/`, with no validation that the upstream artifacts still exist on disk, match an expected shape, or are fresh. The producer-exit `Test-TaskOutput` is the only artifact check and is too weak (file existence / file count) to substitute for a consumer-entry pre-check. In any pipeline where each task is fed from the previous, this is a silent-corruption surface.

### Current behaviour
- Producer-exit gate `Test-TaskOutput` (`core/runtime/modules/ProcessTypes/Invoke-WorkflowProcess.ps1:131-190`) checks only file existence (`outputs`) or directory file-count delta (`outputs_dir` + `min_output_count`, `:154-187`). No schema, no content, no size, no shape.
- `Test-TaskOutput` is invoked only at the producer's exit (`Invoke-WorkflowProcess.ps1:1105` script path, `:1874` prompt path). Never re-consulted from the consumer.
- Consumer-entry gate `Test-AllDependenciesMet` (`TaskIndexCache.psm1:783-800`) only checks upstream task *state*, not their artifacts.
- The only consumer-side artifact gate is the task's own `condition` (path-existence on a rule the consumer's author wrote); it does not look at any dependency's outputs.
- No `inputs:` / `requires_artifacts:` / `input_schema:` key in the workflow.yaml task schema (`New-WorkflowTask` accept-list at `workflow-manifest.ps1:522-647`).
- Consumer context at start = own task fields + own `analysis` payload (from `task-get-context`) + blind dump of every file in `workspace/product/briefing/` (`Invoke-WorkflowProcess.ps1:425-454`). No targeted "give me upstream artifact X."

### W2 diagram reference
- Every inter-phase arrow carries a structured payload: 2.1 delta report → 2.2 decision; 2.3 findings → 2.4; 2.4 TC-details → 2.5; 2.5 TC list → 2.6 / 2.7; 2.7 ADO TCs → 2.8; 2.10 / 2.11 run results → 2.12; 2.12 classification → 2.12a / 2.12b.

### Why it matters
Drift between producer and consumer is the rule, not the exception: a producer can write `mission.md` without the heading the consumer assumes; a hand-edit between runs can blank out half a file; a stale artifact from a prior run satisfies `Test-Path` but is semantically wrong; `min_output_count` happily passes a directory of 0-byte placeholders. None of this is caught until the consumer agent reads the file mid-task and either hallucinates around the gap or burns retries. The producer's exit check, run days/runs/edits ago, tells the consumer nothing useful.

### Proposed direction (non-prescriptive)
- Add an `inputs:` field to `workflow.yaml` declaring the artifacts each task consumes, with shape assertions (file present, non-empty, parseable as JSON/YAML/Markdown with required keys/headings; optional schema/checksum; optional freshness window vs. the producer's `completed_at`).
- A `Test-TaskInput` helper, symmetric to `Test-TaskOutput`, called at consumer entry between `Test-AllDependenciesMet` and the analyse-prompt build (architectural slots: `task-get-next/script.ps1:98-120` and/or `Invoke-WorkflowProcess.ps1:1216`).
- On fail, route the task to `needs-input/` with a structured `pending_question` describing the missing/malformed input — rather than feeding a broken context to the model and silently retrying.

### Acceptance criteria
- [ ] A task can declare its inputs in the manifest with at least: file presence + non-empty + (optional) shape assertion.
- [ ] On consumer entry, inputs are validated before the agent's prompt fires.
- [ ] A failed input promotes the task to `needs-input/` with a specific, actionable reason; no silent retry against a broken context.
- [ ] Existing producer-exit `Test-TaskOutput` behaviour is preserved.

---

## Issue 14 — Preflight is fixed and presence-only — no custom-script and no LLM-driven check support

**Type:** Enhancement · **Area:** runtime / preflight · **Size:** M

### Summary
Workflow preflight (`requires:`) is fixed to three hardcoded check types, all presence-only, with no extension point and no model-call capability. Workflows cannot ship custom checks, and there is no way to express a content-based or semantic precondition (e.g. "the upstream workflow's published artifact is not stale vs. the live source"). This is a **core engine change**, not a workflow-level fix.

### Current behaviour
- Three hardcoded check types in `core/ui/modules/ProductAPI.psm1:371-423`:
  - `env_var` — `.env.local` regex `^VAR=<non-empty>` (`:375-383`)
  - `mcp_server` — name lookup in `.mcp.json` + regex on `claude mcp list` (`:393-411`)
  - `cli_tool` — `Get-Command $name` PATH lookup (`:419`)
- All three are presence-only; nothing connects, parses, validates content, or runs the binary.
- The check loop is a closed `if/elseif` chain (`:365-434`); an unknown `type` silently fails with `passed = $false` and no diagnostic. No plugin discovery, no `requires/preflight/*.ps1` convention, no `requires.scripts:` block.
- No code path in `Get-PreflightResults`, `Convert-ManifestRequiresToPreflightChecks`, or anywhere they call delegates to a model. There is no LLM-driven preflight.
- Manifest schema mirrors the hardcoded triple 1:1 (`workflow-manifest.ps1:43`; converter at `:376-453`).

### W2 diagram reference
- 2.1 *Drift preflight* — compares TAD-referenced REQs vs. current backlog / CRD versions in ADO. This is inherently content-based (semantic comparison of an upstream workflow's published artifact against a live source) and feeds 2.2's routing decision. No expressible form today.
- Reinforces Issue 4 (MCP-server preflight is presence-only): both are symptoms of the same fixed-registry, presence-only design.

### Why it matters
Real preflight conditions are often semantic: "the published TAD's REQs match the live ADO backlog within tolerance," "this branch is rebased on the latest base," "the briefing folder contains all required sections." None of these are expressible today, and there is no way for a workflow author to add one without forking the engine. Any precondition more interesting than "is this string present somewhere" forces preflight to be reinvented inside the workflow as a regular task — which defeats the point of a preflight (running before the workflow commits to a run).

### Proposed direction (non-prescriptive)
- Open the preflight check-type registry: allow workflows to declare a `script` check (a `.ps1` whose exit code determines pass/fail with an actionable message) and an `llm` check (a prompt + an expected boolean/JSON contract).
- Extend the manifest schema accordingly; route to a generic `Invoke-PreflightCheck` dispatcher.
- `scripts/doctor.ps1` can optionally reuse the same registry for ad-hoc validation.

### Acceptance criteria
- [ ] A workflow can ship a custom preflight check (script and/or LLM-backed) that fails with an actionable message.
- [ ] An LLM-driven check produces a structured pass/fail result; failures surface in the preflight UI.
- [ ] The existing three built-in types continue to work unchanged.

---

## Issue 15 — No on-demand external task/workflow trigger that feeds evidence into an in-flight task

**Type:** Enhancement · **Area:** runtime / task IO + orchestration · **Size:** M–L

### Summary
There is no way to invoke an ad-hoc task or workflow from outside the running DAG and inject its output as evidence into a specific in-flight task. The closest mechanisms either spawn brand-new tasks (`InboxWatcher`) or only attach to a task that has already paused itself (`task-answer-question` with attachments, on `needs-input/` only). Once a task's child process is launched, its context is effectively sealed; the only mid-flight interrupt is a string-only steering whisper.

### Current behaviour
- `task-get-context` (`core/mcp/tools/task-get-context/script.ps1:1-164`) returns only the task's own analysis payload — never upstream task artifacts or out-of-band evidence.
- Briefing folder (`workspace/product/briefing/`) is read **only between tasks** in `Get-WorkflowPromptContext` (`Invoke-WorkflowProcess.ps1:425-454`). A file dropped mid-execution is not pushed into the running session; only the next task sees it.
- Steering whisper / heartbeat payload (`core/mcp/tools/steering-heartbeat/script.ps1:79-106`) is `{ instruction, priority, timestamp }` — string instructions only; no attachments, no file paths.
- `task-answer-question` accepts `attachments[]` (`metadata.yaml:30-41`) and writes them to `workspace/product/attachments/$qId/` (`InterviewLoop.ps1:205-209`) — but only operates on tasks already in `needs-input/` (`script.ps1:117-138` throws otherwise). Requires the running task to first park itself.
- `InboxWatcher` ingests new files and launches a new `task-creation` child process (`core/ui/modules/InboxWatcher.psm1:194-237`). Spawns new tasks; does not enrich existing ones.
- No `task-update-context` / `task-append-evidence` / `task-attach` MCP tool exists in the 35-tool set.

### W2 diagram reference
- Top *"Exploratory testing — on-demand"* band: paired-mode session can run at any moment outside the workflow; findings *"feed back into the relevant workflow phase as additional evidence."*
- 2.3 *Exploratory testing (optional)* — same skill, in-flow.
- Bottom *"Side flow — On-demand exploratory testing (workflow-independent)."*

### Why it matters
Many workflows benefit from ad-hoc, side-channel evidence that a human or a one-off agent gathers and hands to the currently running task — an exploratory finding, an additional spec PDF an operator notices, a fresh log from a flaky environment. Forcing the task to first park itself in `needs-input` to receive evidence is a workaround, not a primitive: it requires the task's cooperation and converts a side-channel input into a synchronous gate.

### Proposed direction (non-prescriptive)
- A `task-append-evidence` MCP tool that adds a structured artifact (file path + label + optional shape contract) to a specific task's context, working on any in-flight or queued state — not only `needs-input/`.
- The running task can re-poll its context (or be whispered to do so) and pick up the new evidence.
- An on-demand task/workflow trigger primitive so the side-channel agent itself can be a first-class engine action (pairs with the cross-workflow trigger thread inherent to W1→W2 drift handling, and complements Issues 11/13).

### Acceptance criteria
- [ ] An ad-hoc agent (or operator) can attach evidence to a specific in-flight task without requiring the task to park itself.
- [ ] The receiving task can read the new evidence as part of its context.
- [ ] Existing `task-answer-question` + `InboxWatcher` semantics are unchanged.

---

## Issue 16 — Multi-repo / cross-repo targets are not a first-class engine concept

**Type:** Enhancement · **Area:** runtime / git + worktree + settings · **Size:** L–XL

### Summary
The engine is architecturally tied to exactly one project repo. Tasks cannot commit / push / PR to any repo other than the dotbot project repo. Cross-repo push and PR creation exist today only as prompt-level bash in one workflow (ADO-only). This issue promotes the multi-repo theme — previously noted in Issue 10's sequencing as "subsumed" — to a standalone item, because it is a precondition for multiple credible workflow classes, not a sub-aspect of PR integration.

### Current behaviour
- Single `$global:DotbotProjectRoot`, anchored on one `git-common-dir` (`core/mcp/Resolve-ProjectRoot.ps1:23-100`, line 39 `git rev-parse --git-common-dir`). The MCP server, all 35 tools, and the runtime see exactly one repo.
- All worktree operations take one `$ProjectRoot` and run `git -C $ProjectRoot ...` (`core/runtime/modules/WorktreeManager.psm1:423,612,904`). The completion push is `git push origin $baseBranch` against that one repo (`:843`).
- `external_repo` / `working_dir` task fields are persisted (`TaskIndexCache.psm1:485-486`, `Invoke-WorkflowProcess.ps1:1477`) but their **only** engine effect is to skip the worktree; no commit / merge / push is performed against the external repo.
- No git / target-repo keys in `core/settings/settings.default.json` (no `targets`, `repos`, `base_branch`, `default_branch`, `branch_prefix`). The only branch/repo config that exists anywhere is workflow-scoped (`workflows/start-from-jira/workflow.yaml:60-61`).
- Cross-repo push and PR exist only in prompts: `cd repos/{RepoName}; git push ...` and `az repos pr create ...` in `start-from-jira` (`workflows/start-from-jira/recipes/prompts/09-implement-changes.md:40-47`, `11-draft-system-docs.md:185-206`).

### W2 diagram reference
- 2.8 *"For existing TCs (legacy): update automation code in legacy repo"* — the engine must write into a repo that is not the dotbot project repo.
- 2.16 *"Cross-repo PR push → automation-repo · locators.ts · page.ts · spec.ts pushed cross-repo"* — at least one push target is cross-repo regardless of where the workflow runs.

### Why it matters
Many delivery patterns span multiple repos: code in one repo, tests in another, generated artifacts in a third. Today every cross-repo step is hand-rolled per-workflow and per-provider (ADO only, in prompts). Making targets first-class lets the engine own commit / push / PR mechanics for all of them with per-target conventions (PR target, base branch, branch naming) — and turns the "branch convention" config that today only `start-from-jira` knows about into a shared primitive.

### Proposed direction (non-prescriptive)
- A `targets:` settings concept enumerating named repos with per-target attributes (path or URL, PR target, base branch — generalising Issue 9 to per-target, branch naming convention, push remote).
- Worktree, commit, push, and PR operations parametrised by a target name; the project repo is the default named target.
- The existing `external_repo` / `working_dir` task fields evolve into a `target:` reference.
- Pairs with Issue 10 (PR primitive): the PR primitive accepts a target name and uses the per-target attributes.

### Acceptance criteria
- [ ] A workflow can declare ≥ 2 targets, and a task can choose which target to write to.
- [ ] Worktree, commit, push, and PR work against any declared target (not only the project repo).
- [ ] Per-target base branch and PR target are honoured (depends on Issue 9 / extends Issue 10).
- [ ] The single-target default is unchanged for existing workflows.

---

## Issue 17 — No external (non-Claude) job invocation + await/ingest primitive

**Type:** Enhancement · **Area:** runtime / process types · **Size:** M

### Summary
The runtime can only spawn Claude CLI processes. There is no generic primitive to trigger a non-Claude external long-running job (a CI pipeline, an external test runner, an upstream system action) and await + ingest its structured result as part of a task. The closest construct, the `script` task type, runs a synchronous local PowerShell script with an exit-code check — not an async invoke-and-await primitive.

### Current behaviour
- Four process types in `core/runtime/launch-process.ps1:60` (ValidateSet): `task-runner`, `planning`, `commit`, `task-creation`. All four are Claude-CLI-backed (`Invoke-PromptProcess.ps1`, `Invoke-WorkflowProcess.ps1`).
- Within a task, the type switch (`Invoke-WorkflowProcess.ps1:959-994`) has non-Claude entries: `script` (line 960 — synchronous `& $resolvedScript`, blocking, exit-code only), `mcp` (line 969 — local MCP tool in-process), `task_gen`, `barrier`.
- No async / job / poll machinery: a search of `core/runtime` for `Start-Job` / `Start-ThreadJob` / `Wait-Job` / `Receive-Job` / `Register-ObjectEvent` returns zero matches. The only "wait for external input" pattern is the clarification poll loop — human input, not external job.

### W2 diagram reference
- 2.10 *Legacy framework sub-flow* — *"New orchestration adapter that triggers EP's existing legacy framework runner (CI job invocation), awaits results, fetches output."*
- 2.11 *Run existing regression suite* — invokes the same legacy path for regression scope.

### Why it matters
Many real workflows orchestrate work that does not live inside Claude — an existing CI pipeline, a legacy test runner, an external batch job, a sign-off system. Without a primitive that triggers and awaits these, the workflow either fakes it with a synchronous local script (blocks the runner for the job's duration) or parks the task on a human gate. Neither is a real engine concept for "trigger external work, resume when it lands."

### Proposed direction (non-prescriptive)
- An `external_job` task type (or a generic `await` primitive): declare invocation (command / webhook / CI trigger), an await contract (poll endpoint, timeout, success predicate), and a result-ingest path (where the structured result lands for downstream tasks).
- The runner does not block on the awaiting task — it parks and resumes when the job completes.
- Pairs with Issue 14 (the external job's status could be a preflight or a `condition` source) and Issue 13 (the ingested result becomes a declared input of a downstream task).

### Acceptance criteria
- [ ] A task can trigger an external (non-Claude) job, park while it runs, and resume with the job's structured result.
- [ ] The runner does not block other workflow progress while the external job is awaited.
- [ ] Existing synchronous `script` behaviour is preserved as a separate type.

---

## Considered but not filed (workflow-specific or already roadmapped)

These came up during the analysis but are either achievable today by composition on existing primitives, or already tracked on the roadmap — so filing them as new core gaps would not make sense to a maintainer.

- **"Publish on approval" (hold all external writes until a review gate approves).** Not a core gap: dotbot already provides the review gate (`needs-review`), the approval transition, and the dependency DAG, so a workflow expresses this as "produce → review gate → publish", with the publish step gated on approval via `depends_on`. The external publish itself is a recipe step (e.g. an MCP call). Core's own "publish on approval" is the git squash-merge that runs on approval (`Complete-TaskWorktree`). The one thing core does *not* provide is **enforced staging/transaction** of external side-effects — nothing structurally prevents an earlier task from firing an external write before approval — but that is handled by prompt discipline + DAG arrangement, and turning it into a core feature would be speculative. Kept in workflow content.
- **Multi-channel / per-recipient notification routing.** Today a single channel is selected (`mothership.channel` is a scalar) and all recipients/events use it. Fanning out to several channels at once, or routing per-event/per-recipient, is already on the roadmap (`docs/roadmap/DOTBOT-V4-phase-13-multi-channel-qa.md`), so it is not re-filed here. (Note: the delivery server already appears able to deliver to multiple channels — the binding constraint is the scalar client-side config in `core/mcp/modules/NotificationClient.psm1`.)

---

## Notes on sequencing (informational)

- Issues 1 and 2 are tightly related (output disposition + the unsafe defaults that route document tasks through a worktree); they could be addressed together.
- Issue 4 is a small, self-contained hardening; Issue 5 is mostly wiring on top of the existing #391 park pattern; Issue 8 is a small notification gap in the same family. All three improve robustness/visibility for any review-gated or external-MCP-dependent workflow.
- Issues 3 and 7 are the **same capability at two scopes**: Issue 3 is the *task-level* modification re-run (feedback-driven, modify a single task's prior output); Issue 7 is the *workflow-level* modification re-run (the whole completed pipeline updates its already-published artifacts instead of today's `fresh` from-scratch rebuild). Issue 7 builds on Issue 3's primitives applied across the DAG. How a re-run is *triggered* is deliberately out of scope (manual trigger already works).
- Issues 9 and 10 are about single-repo git integration and pair up: Issue 9 (configurable base branch) is a small prerequisite that Issue 10 (PR-based integration) builds on. The multi-repo / cross-repo dimension was previously noted here as "subsumed by Issue 10"; it is now split out as a standalone item (Issue 16, W2-derived), which builds on both — per-target base branches generalise Issue 9, per-target PR push generalises Issue 10.
- Issue 6 is independent of the rest.
- Issues 11 and 12 are the **control-flow pair**: both extend the same forward-only DAG execution model with richer routing — 11 (cycles / back-edges) lets review-reject and failure paths return to an earlier phase; 12 (runtime-value branching) lets a route be chosen by a prior task's output. Together they make real failure-handling and decision-gated pipelines expressible; addressing one without the other leaves half the W2 diagram inexpressible.
- Issues 13 and 14 are the **entry-validation pair**: 13 validates artifacts at consumer-task entry (the producer-exit `Test-TaskOutput` is the only check today and is too weak — file presence / file count only); 14 validates conditions at workflow entry (the three built-in preflight check types are equally presence-only, with no extension or LLM hook). Both share the "check before run, fail with an actionable reason" pattern and could share infrastructure (a check-result schema, a `needs-input` escalation path on fail).
- Issue 15 is independent but in the same family as Issue 8 (notification on `needs-review`): both improve the workflow's porosity to the outside world (operator notifications inbound; ad-hoc evidence inbound) without changing the core DAG.
- Issue 16 (multi-repo / cross-repo targets) builds on Issues 9 (configurable base branch) and 10 (PR primitive) — see Issue 10 / 9 sequencing note above. It is the W2-derived item with the most direct dependency on the existing Issues 1–10.
- Issue 17 (external job invocation) is independent; it pairs cleanly with Issue 13 (the external job's structured result becomes a declared input of a downstream task) and with Issue 14 (the job's status is a candidate preflight or `condition` source).
