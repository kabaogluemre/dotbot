# Issue #221 — Post-Phase Question Detection + Adjustment Pass: Implementation Notes

**Status:** Scope clarifications agreed. Read this before starting implementation — do not re-derive decisions.

This document captures the decisions reached during review of GitHub issue #221 ("Add post-phase question detection and adjustment pass to task-runner"). It exists so the implementation agent has a single source of truth for every judgment call that would otherwise require guessing or re-litigating.

**Prerequisite: issue #220 must land first.** See section 11.

---

## 1. Business context

Dotbot has two HITL (Human-in-the-Loop) patterns for gathering information from the user mid-workflow. Issue #220 addresses the first pattern (explicit interview task type — designer-declared, proactive). This issue (#221) addresses the second pattern — the **"Generate → Ask → Adjust"** flow, which is reactive and Claude-initiated.

**The pattern, as implemented in the kickstart engine:**

1. **Generate:** An LLM phase runs and produces artifacts (e.g. `mission.md`). During its prompt, Claude may realize it lacks information and write a side-channel file (`clarification-questions.json`) listing the questions it needs answered.
2. **Ask:** The engine detects that file after the phase finishes, moves the process to `needs-input`, and waits for the user to answer (via UI or Teams). Multiple questions can be batched in one wait cycle.
3. **Adjust:** Once answers arrive, the engine invokes Claude a **second time** with the `adjust-after-answers.md` prompt template. In this pass Claude re-reads **all** product artifacts and corrects them holistically based on the new information — not just the field it originally asked about, but anything else the new answer transitively affects.

**Why the holistic adjust pass matters:** If Claude asks "what's your target database?" while writing `mission.md`, the answer affects `tech-stack.md`, `decisions.md`, and possibly `roadmap.md` as well. A per-task question-answer loop would only patch the one field in one file. The adjust pass catches the cross-artifact propagation.

**Current task-runner state:** None of this exists. `Invoke-WorkflowProcess.ps1` has zero references to `clarification-questions` — confirmed by grep. `task_mark_needs_input` is the closest existing mechanism and it's a different thing (active tool call, single question, no adjust pass).

**Kickstart reference implementation:** `Invoke-KickstartProcess.ps1:339-572` (~230 lines). This is what we're adapting.

---

## 2. Relationship with #220 and other existing mechanisms

| | `task_mark_needs_input` (existing) | Post-phase detection (#221) | Interview task (#220) |
|---|---|---|---|
| Trigger | Active (Claude tool call) | Passive (file side channel) | Declared in manifest |
| When | Mid-analysis | Post-execution | As a dedicated task |
| Question count | Single | Batched (multiple) | Multi-round |
| Follow-up | Re-run analysis | Holistic adjust pass | None (summary file) |
| User visibility in graph | No | No | Yes (explicit task) |

All three must coexist. They are not interchangeable — they solve different information-gathering problems.

**Shared UI/Teams surface:** `task_mark_needs_input` and post-phase detection must share the same task-level `pending_questions[]` schema and the same UI/Teams rendering path, so the user sees a uniform "this task has pending questions, answer them" experience regardless of which mechanism put the questions there. See section 4.

**Interview task skip (critical edge case):** When issue #220 lands, `interview` tasks will run `Invoke-InterviewLoop`, which itself writes and consumes clarification files internally. Post-phase detection **must explicitly skip `type: interview` tasks**, otherwise detection will fire immediately after every interview, creating an infinite question loop. This is why #221 must land after #220 — the skip condition can't be written until the interview type exists.

---

## 3. Adjustment pass strategy: inline, not follow-up task

The doc (section 7.2) flags this as the hardest decision and gives two options:
- **(a)** Auto-generated follow-up task that goes through normal task-runner dispatch.
- **(b)** Inline Claude invocation from the post-completion handler.

**Decision: (b) — inline.**

Reasons:
- The kickstart engine already does exactly this inline at `Invoke-KickstartProcess.ps1:529-572` using `Invoke-ProviderStream` with the `adjust-after-answers.md` prompt template. Copy-paste-adapt is the lowest-risk path and directly gets us HITL parity.
- Semantically the adjust pass is "finishing the original task's work after new info arrived" — not a new unit of work. Modeling it as a separate task would force the user to mentally connect two rows in the UI ("what is this task, where did it come from?") for no benefit.
- Option (a) would open new questions: what `depends_on` does the follow-up task get, when is it enqueued, does it appear on the workflow graph, how does the workflow manifest represent tasks that don't exist until runtime? Task-runner dependency resolution is one of the more delicate areas; expanding its surface area without an upside is a bad trade.
- Progress events during the adjust pass surface as `Write-ProcessActivity` calls on the originating task, which is what the UI already renders — no new UI wiring needed.

**Implementer: do not generate a follow-up task. Do not call `New-WorkflowTask`. The adjust pass is a second `Invoke-ProviderStream` call inside the same post-completion handler, after answers are read.**

---

## 4. Schema migration: `pending_question` → `pending_questions[]`

**Decision: replace the scalar field with an array in a single PR.**

The existing task schema has `pending_question` (singular, nullable object). Post-phase detection needs to carry multiple questions atomically. Rather than living with two fields (one scalar, one array), we migrate to array-only.

**Why array-only instead of keeping both:**
- The scalar field is internal state — no external API contract depends on it.
- Two coexisting fields double the reader/writer surface and create ambiguity ("which one is authoritative?").
- `task_mark_needs_input` can trivially write a single-element array without changing its public tool contract (Claude still calls it with one question; internally it becomes `pending_questions = @($newQ)`).

**Call sites that must update in the same PR** (a half-migration will break single-question flows):

| Role | File | Change |
|---|---|---|
| Writer (Claude-initiated) | `workflows/default/systems/mcp/tools/task-mark-needs-input/script.ps1` (line 40) | Write to `pending_questions` as a single-element array. Tool's Claude-facing API stays `question:` singular. |
| Writer (merge conflict) | `workflows/default/systems/runtime/modules/ProcessTypes/Invoke-WorkflowProcess.ps1:929-935` | Same: write conflict description as a single-element array. |
| Writer (post-phase, new) | Same file, new post-completion block | Writes the batch from `clarification-questions.json`. |
| Reader (UI) | Web UI task-detail panel — grep for `pending_question` usage | Render as a batch form. Single-element array renders identically to one question, so the single-question UX is preserved. |
| Reader (Teams) | `workflows/default/systems/mcp/modules/NotificationClient.psm1` (`Send-TaskNotification`) | Accept the array. Send one notification per element (mirroring kickstart at `Invoke-KickstartProcess.ps1:408-426`). |
| Reader (MCP task queries) | Any `task_list` / `task_get` tool that exposes `pending_question` | Rename the surfaced field to `pending_questions`. |

**No backward-compat bridge.** `pending_question` is removed, not aliased. If the grep catches anything I missed here, it must be migrated in the same PR.

---

## 5. Clarification file path — designer-declared, opt-in

**Problem:** The kickstart engine uses a single hard-coded path (`.bot/workspace/product/clarification-questions.json`). This is safe for kickstart because it's a single process. The task-runner runs tasks in parallel — a shared fixed path would cause cross-task contamination (two tasks writing clarification files into the same slot).

**Decision: add a new optional `clarification_file` field to the task manifest, mirroring the `summary_file` pattern from #220.**

```yaml
- name: "Generate Mission"
  type: prompt_template
  prompt: "generate-mission.md"
  clarification_file: "clarifications/mission.json"    # new optional field
```

Behavior:
- Path is resolved relative to `.bot/workspace/`.
- If `clarification_file` is set:
  - The task-runner injects an instruction into the outgoing prompt telling Claude: "If you need clarification from the user before completing this task, write the questions as JSON to `<resolved absolute path>` in the schema `{ questions: [{ id, question, context, options, recommendation }] }`. Do not ask inline in your response."
  - After the task completes, the post-completion handler checks that exact path. If the file exists and parses as a valid questions object, detection fires.
- If `clarification_file` is absent:
  - Detection is **skipped entirely** for that task. No instruction injection, no post-completion check.
- Collision prevention between parallel tasks is the **designer's responsibility via the manifest** — each task declares its own unique path.

**Why opt-in:** Random prompt tasks that will never need clarification shouldn't pay the cost of the detection instruction bloating their prompt, nor the overhead of a post-completion file check. Designers opt in at the workflow authoring stage, same way they opt in to `outputs` or `post_script` today.

**Clarification schema (JSON that Claude writes):** Matches the kickstart engine's shape exactly — `Invoke-KickstartProcess.ps1:383-388` reads `$phaseQData.questions` as an array of `{ id, question, context, options[], recommendation }`. Do not invent a new shape. The `adjust-after-answers.md` prompt template already expects this shape.

---

## 6. Worktree lifecycle

**Decision: the adjust pass runs inside the originating task's worktree, before its squash-merge. The originating task does not transition to `done` until the adjust pass completes.**

This is not an independent decision — it falls out of choosing inline (section 3). Since the adjust pass is a second `Invoke-ProviderStream` invocation inside the post-completion handler, and the task's worktree hasn't been merged yet at that point, everything just naturally happens in-place.

The visible task lifecycle becomes:
```
in-progress  →  needs-input  →  in-progress (adjusting)  →  done  →  (squash-merged, worktree cleaned up)
```

Everything lands as a **single squash-merged commit** on the main branch. The user does not see two separate commits ("initial generation" and "post-answer adjustment"). This matches how `task_mark_done` + merge works today — we're just delaying the `done` transition until the full Generate→Ask→Adjust cycle finishes.

**Implementer: do not introduce a new worktree state or a second worktree for the adjust pass. Everything happens inside the existing one.**

---

## 7. Scope: which task types trigger detection

**Decision: only `prompt` and `prompt_template` tasks.**

| Task type | Detection fires? | Reason |
|---|---|---|
| `prompt` (default) | Yes, if `clarification_file` is set | Claude runs, can write the file |
| `prompt_template` | Yes, if `clarification_file` is set | Normalized to `prompt` at line 273-289; same behavior |
| `interview` (from #220) | **Explicitly skipped** | Uses its own internal clarification loop — see section 2 |
| `script` | No | No Claude involvement |
| `mcp` | No | No Claude involvement |
| `task_gen` | No | No Claude involvement |
| `barrier` | No | No work performed |

The guard should be explicit and defensive — check `$taskTypeVal -eq 'prompt'` (remembering `prompt_template` has already been normalized to `prompt` by line 288) AND `$task.clarification_file` is non-empty AND the resolved file exists. Three conditions, all must be true.

---

## 8. Adjust pass scope: `.bot/workspace/product/` only

**Decision: the adjust pass re-reads only `.bot/workspace/product/`, matching the kickstart engine.**

Workflows whose artifacts live outside `product/` will not benefit from the holistic re-read. This is an intentional, documented limitation — it keeps the token cost and latency of the adjust pass bounded. If a workflow wants the adjust pattern, it writes its artifacts to `product/`.

**Implementer: do not parameterize the adjust scope. Do not read it from the manifest. It's a hard-coded convention.**

The `adjust-after-answers.md` prompt template at `workflows/default/recipes/includes/adjust-after-answers.md` already encodes this assumption — reuse it as-is.

---

## 9. Teams notification

**Decision: copy the kickstart pattern verbatim — one notification per question, polled independently, aggregated when all answered.**

Kickstart reference: `Invoke-KickstartProcess.ps1:400-483` (the notification send loop, the polling loop for responses, the aggregation into the answers JSON).

The existing `task_mark_needs_input` Teams integration (`task-mark-needs-input/script.ps1:78-100`) only handles a single question. For the batched case, implement it by looping over `pending_questions[]` and calling `Send-TaskNotification` once per element, storing the returned `question_id` / `instance_id` on each question for subsequent polling.

`NotificationClient.psm1` does not need new functions — the existing `Send-TaskNotification` and `Get-TaskNotificationResponse` already handle one-at-a-time. The batching is in the caller.

---

## 10. Ask loop: where does it live in the code flow

The post-completion handler in `Invoke-WorkflowProcess.ps1` currently does (roughly, around the merge/commit block):

1. Claude calls `task_mark_done`
2. Task file moves to `done/`
3. Verification hooks run (`00-privacy-scan.ps1`, etc.)
4. Squash-merge to main
5. Worktree cleaned up

The new post-phase detection inserts **between steps 2 and 3** (before verification hooks, before merge). Pseudo-flow:

```
after task_mark_done:
    if task.type in ('prompt', 'prompt_template') and task.clarification_file is set:
        resolve clarification_file to absolute path
        if that file exists:
            parse it as questions JSON
            if questions[] non-empty:
                write pending_questions[] onto the task
                move task from in-progress/ to needs-input/
                send Teams notifications per question (if configured)
                poll for answers file (or Teams responses), same loop as kickstart
                when answers arrive:
                    append Q&A to interview-summary.md (or a task-local log — see note below)
                    move task back to in-progress/
                    invoke adjust pass (second Invoke-ProviderStream with adjust-after-answers.md)
                    cleanup: remove questions and answers JSON files
    # then continue with verification hooks + merge as usual
```

**Note on Q&A logging:** Kickstart appends Q&A history to `product/interview-summary.md` so subsequent phases have it as context. For the task-runner, the same file is a reasonable target since the adjust pass reads from `product/` anyway. Use the same file, same append pattern as `Invoke-KickstartProcess.ps1:501-527`. If `interview-summary.md` doesn't exist yet (no prior interview ran), create it with the clarification log as the first section.

**Stop signal handling:** The polling loop must honor `Test-ProcessStopSignal` the same way kickstart does (`:438-445`), otherwise stopping a process stuck waiting for answers won't work.

---

## 11. Sequencing: land after #220

This issue has a hard dependency on #220:

1. The "skip detection for interview tasks" edge case in section 2 and section 7 cannot be written until the `interview` task type exists in the ValidateSet and dispatch switch.
2. The UI rendering for batched `pending_questions[]` is a natural extension of the interview panel reuse from #220. Landing #220 first means the UI task-detail panel is already familiar with batched question rendering.
3. The `clarification_file` manifest field parallels `summary_file` from #220. Landing them in order lets the schema feel consistent to workflow authors.

**Do not attempt to implement #221 before #220 is merged.**

---

## 12. Out of scope — do not implement as part of this issue

1. **Automatic output→input injection for the adjust pass.** The adjust pass reads from `product/` by convention; there is no new framework-wide I/O binding mechanism being introduced here.
2. **Per-task adjust prompt override.** Every task that uses post-phase detection shares the same `adjust-after-answers.md` template. No `adjust_prompt:` manifest field.
3. **Multi-round adjustment.** The adjust pass runs once per ask cycle. If the adjust pass itself produces a new `clarification_file`, the task-runner should **not** loop — it commits and moves on. (A rogue prompt template that triggers infinite questions is a designer bug, not something we defend against in the runtime.)
4. **Non-prompt task types triggering detection.** Script/mcp/task_gen/barrier/interview tasks do not participate in this pattern. See section 7.
5. **Changes to the `adjust-after-answers.md` template itself.** Reuse it as-is from `workflows/default/recipes/includes/adjust-after-answers.md`.

---

## 13. File modification list

| File | Change |
|---|---|
| `workflows/default/systems/runtime/modules/ProcessTypes/Invoke-WorkflowProcess.ps1` | New post-completion detection block after `task_mark_done`, before verification hooks. Adapted from `Invoke-KickstartProcess.ps1:339-572`. Also: update merge-conflict escalation writer at :929-935 to write `pending_questions[]` array. |
| `workflows/default/systems/mcp/tools/task-mark-needs-input/script.ps1` | Write to `pending_questions` as a single-element array (line 40). Tool's public API stays the same. |
| Task schema / manifest validator | Add optional `clarification_file` field for prompt-type tasks. Remove `pending_question` from task schema, add `pending_questions[]`. |
| `workflows/default/systems/mcp/modules/NotificationClient.psm1` (or wherever `Send-TaskNotification` is called from the task-runner side) | Loop over `pending_questions[]` to send one notification per element. |
| Web UI task-detail panel | Render `pending_questions[]` as a batch form. Single-element array must render identically to the current single-question experience. |
| MCP task-query tools (`task_list`, `task_get`, and anything else surfacing pending state) | Rename exposed field from `pending_question` to `pending_questions`. |
| `tests/Test-WorkflowManifest.ps1` | Validate the new `clarification_file` field and the new task schema. |
| A new Layer 2 component test | Stub a prompt task that writes a fixed `clarification-questions.json`, drive it through detection, assert the task moves to `needs-input` with the expected batched questions. |
| A new Layer 3 mock-Claude test | End-to-end: mock Claude writes questions, stub answers arrive, verify adjust pass is invoked with the `adjust-after-answers.md` prompt. |

---

## 14. Manual test (from the issue, with corrections)

1. In a test project, write a prompt task **whose prompt template explicitly instructs Claude to write a fixed `clarification-questions.json` with 2-3 hard-coded questions** to the task's `clarification_file` path. (The issue's wording — "instruct Claude to produce mission.md and also write clarification-questions.json" — is flaky because Claude's output is non-deterministic. The template must be explicit.)
2. Run the workflow via the task-runner.
3. Verify the task moves to `needs-input/` with the batched questions visible in the UI.
4. Answer the questions in the UI.
5. Verify the task returns to `in-progress`, runs the adjust pass using the `adjust-after-answers.md` prompt, and updates `mission.md` based on the answers.
6. Verify the task transitions to `done` only after the adjust pass completes, and the resulting commit includes both the original artifact and the adjustment in a single squash-merged commit.
7. Verify Teams notification is sent (if Teams is configured) — one notification per question, aggregated response triggers the adjust pass.
8. Run `pwsh tests/Run-Tests.ps1` layers 1-3.

---

## 15. Metadata corrections for the issue

- Label: `type:bug` → `type:enhancement`. This is a missing capability, not a defect.
- Severity: `low` → `high`. The originating doc (section 7.2) explicitly frames this as the "second-largest HITL parity gap" — `low` is inconsistent with that framing.
- Test step 1 needs rewording (see section 14, item 1).
