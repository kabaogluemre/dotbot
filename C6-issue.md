# C6 — Configurable base branch + push integration mode (provider-agnostic core)

> **Status:** Draft issue — not yet filed on GitHub
> **Labels:** `enhancement` · `proposal` · `needs-triage`
> **Source:** Dotbot Product Backlog — item C6, Consolidated (Gap 7 + Gap 3), Priority High, Weight 6/10

---

## Summary

Dotbot integrates completed task work by squash-merging **directly to the base branch** and pushing it. This is rejected on protected branches — the enterprise norm — and the base branch is hard-coded to `main`/`master`, so teams on `develop`/`trunk`/release lines cannot use dotbot without renaming their trunk.

This issue makes the integration **provider-agnostic and protected-branch friendly** with two small, focused core changes:

1. A **configurable base branch** (`git.base_branch`).
2. A new **`push` integration mode** that pushes the task branch and preserves it instead of merging — so the PR/review/CI flow that already protects the branch can take over.

> **Scope decision:** Core stays provider-agnostic. Automatic PR creation (`gh` / `az repos`) is **explicitly out of scope** here — it belongs to the workflow/skill/CI layer, where provider integration already lives (e.g. `start-from-jira` already opens ADO PRs via `az`). Core's only integration mechanism remains raw `git`.

---

## Problem Statement

- `Complete-TaskWorktree` squash-replays the task branch onto the base and runs `git push origin <base>` — rejected immediately on protected branches.
  - `src/runtime/Modules/Dotbot.Worktree/Dotbot.Worktree.psm1` (replay ~L1690, `git push origin $baseBranch` ~L1793)
- The base branch is hard-coded. Both resolvers loop only over `@('main','master')`:
  - `Resolve-MainBranch` — `src/runtime/Modules/Dotbot.Worktree/Dotbot.Worktree.psm1:147`
  - `Resolve-WorkflowMainBranch` — `src/runtime/Modules/Dotbot.Worktree/Private/Worktree.psm1:136`
- No `git.base_branch` (or any `git.*`) setting exists anywhere. Default settings (`content/settings/settings.default.json`) have no `git` section.

> Pilot evidence: *"Too much time lost because someone from one system has to make a PR on a system they don't know well."* — R11, AI Engineer

---

## Scope (locked)

**In scope (core, provider-agnostic):**

- `git.base_branch` — configurable target branch (per-project + per-user, via `Get-MergedSettings`).
- `git.integration_mode` — `merge` (default, unchanged) | `push` (push task branch, preserve it, do **not** merge / do **not** open PR).

**Out of scope (descoped from the original backlog item):**

- ~~PR primitive for GitHub (`gh`) and Azure DevOps (`az repos`)~~ — left to workflow / skill / CI.
- ~~Per-workflow PR title / body / draft / reviewers~~ — N/A once core does not open PRs.

These two are deliberately delegated so core takes on **zero** GitHub/ADO/MCP dependency. They can be revisited later as an opt-in adapter layer if needed.

---

## Acceptance Criteria

- [ ] A `git.base_branch` setting is configurable per-project and per-user; empty value falls back to the existing `main`/`master` auto-detection.
- [ ] Base-branch resolution reads the configured value and verifies it (`git rev-parse --verify`); a configured-but-missing branch **fails fast with an actionable message** (no silent fallback to `main`).
- [ ] Worktree creation, the `base_branch` record in `worktree-map.json`, and `Complete-TaskWorktree` all honour the configured value.
- [ ] A repo on `develop` works end-to-end without renaming its trunk.
- [ ] A new `git.integration_mode: push` mode pushes the task branch to `origin` (with `-u`), **preserves the branch**, removes the worktree, and does **not** touch the base branch — as an alternative to direct squash-merge.
- [ ] In `push` mode, the completion message / activity log surfaces the **branch name and remote URL** so a human / CI / workflow step can open the PR.
- [ ] The existing direct squash-merge mode (`merge`) remains the **default** and is byte-for-byte unaffected.

---

## Proposed Implementation

**1. Single base-branch resolver** — `Resolve-DotbotBaseBranch -ProjectRoot -BotRoot`:
- Read `git.base_branch` via `Get-MergedSettings`.
- If set → `git rev-parse --verify`; verified → use it; unverifiable → **fail fast** (actionable error). No silent fallback when a value is configured.
- If empty → existing `main` → `master` loop.
- `Resolve-MainBranch` / `Resolve-WorkflowMainBranch` keep their signatures, gain an optional `-BotRoot`, and delegate to this. All three call sites (`New-TaskWorktree`, `Complete-TaskWorktree`, `New-RunWorktree`) already have `$BotRoot` in scope.

**2. Integration mode branch in `Complete-TaskWorktree`** — branch right after the existing auto-commit (the task branch already contains all the work at that point):
- `merge` → existing replay-to-base + push path, unchanged.
- `push` → `git push -u origin <branch>`, preserve branch (no `git branch -D`), clean up the worktree (junction cleanup as today). No base mutation. Push failure escalates via the existing merge-failure → `needs-input` pattern (`Invoke-WorkflowProcess.ps1` ~L1505). No remote configured → preserve branch locally, skip push, note it in the message.

**3. Settings** — add to `content/settings/settings.default.json`:
```json
"git": {
  "base_branch": null,
  "integration_mode": "merge"
}
```
Plus `Get-GitConfig` / `Set-GitConfig` in `src/ui/modules/SettingsAPI.psm1` (mirrors `Set-AnalysisConfig`, persists to `.control/settings.json` via `Save-OverrideSection`).

### Files touched
| File | Change |
|---|---|
| `src/runtime/Modules/Dotbot.Worktree/Dotbot.Worktree.psm1` | `Resolve-DotbotBaseBranch`; `Resolve-MainBranch` delegate; `push` branch in `Complete-TaskWorktree` |
| `src/runtime/Modules/Dotbot.Worktree/Private/Worktree.psm1` | `Resolve-WorkflowMainBranch` delegate |
| `content/settings/settings.default.json` | new `git` section |
| `src/ui/modules/SettingsAPI.psm1` | `Get/Set-GitConfig` |
| `src/runtime/Scripts/Invoke-WorkflowProcess.ps1` | surface branch + remote in completion / activity log |

---

## Open Question (follow-up)

The per-task worktree model produces **one `task/...` branch per task**, so `push` mode yields **many branches → many PRs** for a multi-task workflow. If a single consolidated PR per workflow run is desired, the **run-level** branch — already preserved by `Complete-RunWorktree` (`src/runtime/Modules/Dotbot.Worktree/Private/Worktree.psm1:367`) — is the natural vehicle. Decide during triage whether `push` mode should also (or instead) operate at the run level.

---

## Notes

This issue narrows C6 to its provider-agnostic core; the PR-creation half (original AC6/AC7) is intentionally descoped to the workflow/CI layer.
