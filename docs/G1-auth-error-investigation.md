# G1 — Auth Expiry / AuthError Classification Dead Code

**Type:** Bug · **Priority:** High · **Source:** Gap Doc Only · **Weight:** 4/10
**Status:** Investigation complete — proposed fix ready, pending GitHub issue creation
**Investigated against:** `main` (v4) · **Date:** 2026-06-05

---

## 1. Business Summary (non-technical)

**Today's problem.** When dotbot runs a task and a background access token / session
expires mid-run — e.g. an MCP connection (Jira, etc.) or the Claude session times out —
dotbot does **not** recognise it as a distinct situation. It treats it like an ordinary
"it failed, retry" error. As a result:

- It silently retries the same task 2–3 times, hitting the same auth wall each time.
- It eventually marks the task "skipped" with no clear reason.
- **No signal reaches the operator.** Nobody knows why the run stalled until they happen
  to look at the dashboard — and they usually restart the whole run from scratch.

**What we are building (in three sentences).**

1. Dotbot will now **recognise** "this is an authentication / access error" (the ability
   to detect this already exists in the code but is disconnected — dead — and we are
   wiring it up).
2. Instead of retrying blindly, it will **pause** the task (`needs-input`) and show the
   operator a clear, actionable **"please re-authenticate"** prompt.
3. Once the operator re-authenticates and confirms, the task **resumes from where it
   parked** — work done so far (code, files in the worktree) is preserved; no restart.

**Business value.** Eliminates wasted retries and time, removes the "why did it stop?"
uncertainty, and avoids losing a whole run to a restart. Low cost, clearly noticeable
improvement to the operator experience.

---

## 2. Root-Cause Chain (verified in code)

When an MCP/provider auth token expires mid-run:

1. **The adapter swallows the error.** In the Claude adapter, when a stream-json `error`
   event arrives it only writes to `[Console]::Error` + `Write-ActivityLog -Type "error"`
   then `return`s — **no throw, no exit code, no text returned to the caller**.
   → `src/runtime/Modules/Dotbot.Harness/Adapters/ClaudeCodeAdapter.ps1:334-363`

2. **The stream result never reaches the caller.** `Invoke-HarnessStream` passes the
   adapter return through, but the Claude adapter returns nothing; worse, the consumer
   ignores the return entirely and hard-sets `$exitCode = 0` when no exception is thrown.
   → `src/runtime/Modules/Dotbot.Harness/Dotbot.Harness.psm1:96`
   → `src/runtime/Scripts/Invoke-WorkflowProcess.ps1:1772-1776`

3. **The classifier is called with empty text.** The sole consumer:
   ```powershell
   $failureReason = Get-FailureReason -ExitCode $exitCode -Stdout "" -Stderr "" -TimedOut $false
   if (-not $failureReason.recoverable) { ... }   # only .recoverable is read
   ```
   With empty `Stdout`/`Stderr`, **no text rule can ever match** → always falls through to
   the default `Crash` (recoverable=`$true`). And `.type` is never branched on.
   → `src/runtime/Scripts/Invoke-WorkflowProcess.ps1:1846-1847`
   → `src/runtime/Modules/Dotbot.Harness/Private/Failure.ps1:75-86`

4. **Result:** the run silently retries (`maxRetriesPerTask = 2`), hits the same auth wall
   each attempt, then gets skipped with `max-retries`. The operator gets no re-auth prompt.
   `AuthError` is dead code — it appears only at its own definition.
   → `src/runtime/Scripts/Invoke-WorkflowProcess.ps1:1737` (retry loop)
   → `src/runtime/Modules/Dotbot.Harness/Private/Failure.ps1:18-24` (AuthError rule)

> The backlog framed this as "twofold". In reality there are **three** layers: at the
> deepest level the adapter never surfaces the signal at all. The **Codex** path is
> similarly incomplete: `CodexAdapter.ps1:309-312` throws on a non-zero exit but **does
> not carry the error text** (stderr is only drained), so the classifier still receives
> empty text.

---

## 3. Proposed Fix — 3 Layers (gap-free)

### Layer 1 — Adapter surfaces the signal (both providers)

**Claude** (`ClaudeCodeAdapter.ps1`): add `lastError=''` / `errorCount=0` to `$state`
(`:76`); in the error-event branch (`:361`) set `$state.lastError = $errorMsg;
$state.errorCount++`. The Stream function (currently returns nothing) returns a standard
object:
```powershell
return [pscustomobject]@{ ExitCode = $claudeProc.ExitCode; StopRequested = $stopRequested; ErrorText = $state.lastError }
```

**Codex** (`CodexAdapter.ps1`): in `Invoke-CodexLineHandler` record error/stderr text into
`$state.lastError`; include it in the throw message
(`throw "Codex CLI exited with code $nativeExitCode. $($state.lastError)"`) **and** return
the same result object. Both paths (throwing Codex / silent Claude) now propagate text up.

### Layer 2 — Classifier fed with real text

In the consumer:
```powershell
$streamResult = Invoke-HarnessStream @streamArgs   # :1772 — capture the return
$exitCode = 0
} catch {
    $execErrorText = $_.Exception.Message            # captures the Codex throw
    $exitCode = 1
}
...
$harnessErrText = @($streamResult.ErrorText, $execErrorText) -join "`n"
$failureReason = Get-FailureReason -ExitCode $exitCode -Stdout $harnessErrText -Stderr $harnessErrText -TimedOut $false  # :1846
```

**Bonus gap closed:** this also revives `VerificationFailed` / `CodeError` / `TaskError` /
`MaxIterations` — all currently dead for the same empty-text reason.

### Layer 3 — Type-aware branch + needs-input park

Right after `$failureReason` is set, **before** the recoverable / max-retries checks:
```powershell
if ($failureReason.type -eq 'AuthError') {
    $ctx = "$($failureReason.description). $($failureReason.suggested_action). Detail: $harnessErrText"
    Set-WorkflowTaskNeedsInput -Task $task -RunDir $runDir `
        -QuestionId "auth-expiry-$($task.id)" `
        -Question "Re-authentication required for task '$($task.name)'" `
        -Context $ctx | Out-Null
    $taskParked = $true
    break
}
```

This reuses the existing **parked** path (`Invoke-WorkflowProcess.ps1:1990`): worktree
retained, no merge, `consecutive_failures` not bumped, retry budget **not consumed**.
`Set-WorkflowTaskNeedsInput` (`:207-253`) already produces the `pending_question` +
handoff. `AuthError` is now consumed → dead code removed.

**Resume.** When the operator answers, the existing needs-input machinery moves the task
back to `todo`, the picker re-selects it, and the worktree is **reused** (no work lost) —
so "resume from the park, not the beginning" holds at the worktree/commit level. (A fresh
provider session is opened; consistent with every other needs-input park. True
provider-session resume is out of scope — see §6.)

---

## 4. Architecture Fit — does it fit dotbot core?

**Yes — strongly.** This wires up parts that already exist rather than adding a new
concept.

1. **The classifier already knows `AuthError`.** `Failure.ps1:18-24` defines the auth
   category; it was designed to be used but never connected. We connect it.
2. **"Pause → ask operator → resume" is the core's backbone.** Dotbot already uses
   `needs-input` + handoff + worktree retention for merge conflicts, verification
   failures, etc. We route auth errors through the **same** built-in flow
   (`Set-WorkflowTaskNeedsInput`) — no new mechanism, honouring the "one right way"
   principle.
3. **Provider-agnosticism preserved.** The classifier is designed to inspect text only,
   regardless of provider. Surfacing error text in both the Claude and Codex adapters
   **completes** that design rather than breaking it.

**Low risk, natural fit, completes existing design.**

---

## 5. Edge Cases / Gaps Explicitly Addressed

| # | Risk | Handling |
|---|---|---|
| 1 | Claude: exit code 0 + error event (main scenario) | Layer 1 returns `ErrorText` independent of exit code |
| 2 | Codex: error text lost | `$state.lastError` added to throw message + result |
| 3 | Auth error silently burning retry budget | Layer 3 `break`s immediately into the park |
| 4 | Busy-loop after parking | `needs-input → todo` requires a human answer; no loop |
| 5 | Real-world auth messages missed | Broaden substring set: `oauth token`, `token expired`, `authentication_error`, `please run /login`, `re-authenticate`, `session expired`, `credentials`. For `401`, use a word-bounded regex to avoid false positives |
| 6 | Timeout vs auth precedence | `Get-FailureReason` checks `TimedOut` first; auth fails fast, so no practical conflict — note it |
| 7 | External notification of the re-auth prompt | In-app contract = `pending_question` + handoff; external Teams/Slack delivery is **G2** scope (declare as dependency) |

---

## 6. Out of Scope (explicit, to set expectations)

- **True provider-session resume** (continuing the *same* provider session rather than a
  fresh one). The worktree/commits are preserved, but the agent re-reads context — same as
  all existing needs-input parks. Tracking a deeper session-resume is a separate, larger
  change (tied to `PersistSession`).
- **External notification delivery** for the re-auth prompt — covered by **G2**
  (needs-review / needs-input notification wiring).

---

## 7. Test Plan

Framework: existing custom `Assert-*` harness, `Test-*.ps1` (not Pester). `Get-FailureReason`
currently has **no** unit tests — a gap. Add:

- **Classifier unit:** representative text matches each type (incl. broadened auth
  strings); empty input → `Crash`; timeout precedence.
- **Adapter contract:** simulated error event → result `ErrorText` populated (Claude +
  Codex).
- **Integration:** `AuthError` → `Set-WorkflowTaskNeedsInput` called with `auth-expiry-*`
  question id, `$taskParked = $true`, worktree retained, retries not consumed.
- **Regression:** non-auth recoverable / max-retries / skip paths unchanged.

---

## 8. Acceptance Criteria Mapping

- **AC1** (auth detected distinctly from generic failures) → Layers 1+2 (real text) +
  broadened auth rule
- **AC2** (run parks to `needs-input` with actionable re-auth prompt) → Layer 3
  `Set-WorkflowTaskNeedsInput`
- **AC3** (resume from park, not from the beginning) → existing `needs-input → todo` +
  worktree reuse (no work lost)
- **AC4** (`AuthError` wired to a handler; dead-code path removed) → Layer 3 `.type`
  branch consumes `AuthError`

---

## 9. Touch List (files to change)

| File | Change |
|---|---|
| `src/runtime/Modules/Dotbot.Harness/Adapters/ClaudeCodeAdapter.ps1` | `$state.lastError/errorCount`; return result object with `ErrorText` |
| `src/runtime/Modules/Dotbot.Harness/Adapters/CodexAdapter.ps1` | record error text; add to throw + return result object |
| `src/runtime/Modules/Dotbot.Harness/Private/Failure.ps1` | broaden `AuthError` substrings/regex |
| `src/runtime/Scripts/Invoke-WorkflowProcess.ps1` | capture stream result; feed real text to `Get-FailureReason`; add `AuthError → park` branch |
| `tests/Test-*.ps1` (new) | classifier unit + adapter contract + integration + regression |
