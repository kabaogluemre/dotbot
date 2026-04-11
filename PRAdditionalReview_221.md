## Follow-up after further investigation

Did a deeper pass through the code and cross-referenced section 7.2 of the originating design doc. A few things in the original description need tightening before implementation starts, and several decisions that the description (and the doc's explicit "discussion point") left open should be written down so the implementer doesn't have to guess. Posting them here for visibility.

### Resolving the doc's "discussion point": inline adjustment, not a follow-up task
Doc 7.2 explicitly flags this as the hardest call: the adjustment pass can be implemented as **(a)** an auto-generated follow-up task that goes through normal dispatch, or **(b)** an inline Claude invocation from the post-completion handler. Going with **(b) — inline**.

Reasons:
- The kickstart engine already does exactly this inline at `Invoke-KickstartProcess.ps1:529-572`, using `Invoke-ProviderStream` with the `adjust-after-answers.md` prompt. Copy-paste-adapt is the lowest-risk path and gets us parity without introducing a new pattern.
- Semantically the adjust pass is "finishing the original task's work after new info arrived" — not a new unit of work. Modeling it as a separate task would force the user to mentally connect two rows in the UI ("what is this task, where did it come from?") for no benefit.
- Option (a) would need a new answer to "what does the follow-up task's `depends_on` look like, when does it get enqueued, does it appear on the workflow graph?" — dependency resolution is one of the task-runner's more delicate areas and we shouldn't expand its surface area unless there is a real upside. There isn't one here.
- With (b), progress surfaces as activity events on the originating task (`Write-ProcessActivity`), which is what the UI already renders.

**Consequence on worktree lifecycle:** because the adjust pass is inline, the originating task's transition to `done` is deferred until the adjust pass completes. Everything happens inside the same worktree and lands as a single squash-merged commit. The visible task lifecycle becomes: `in-progress → needs-input → in-progress (adjusting) → done`.

### Schema: `pending_question` (singular) → `pending_questions[]` (array)
The description leaves "`pending_question` or batched `pending_questions[]`" as an either/or. Going with **array only**, because Claude writes the clarification file with multiple questions in a single pass and the UI/Teams rendering should be one batch, not N re-renders.

This is a schema migration that must land in a single PR — every reader and writer of the current `pending_question` field needs to be updated at the same time:
- `workflows/default/systems/mcp/tools/task-mark-needs-input/script.ps1` (writer — writes a single-element array instead of the scalar)
- `Invoke-WorkflowProcess.ps1:929-935` (merge conflict escalation writer)
- Web UI task-detail panel (reader/renderer)
- `NotificationClient.psm1` / `Send-TaskNotification` (Teams integration currently takes `-PendingQuestion`; extend to handle the array by sending one notification per element, matching the kickstart pattern at `Invoke-KickstartProcess.ps1:408-426`)

No backward-compat bridge for the scalar field — it's internal state, nothing outside dotbot reads it.

### Clarification file path — designer-declared per task, opt-in
The kickstart engine uses a single hard-coded path (`.bot/workspace/product/clarification-questions.json`). This works for kickstart because it's a single process. The task-runner runs tasks in parallel, so a shared fixed path would cause cross-task contamination.

Going with a per-task manifest-declared path, matching the `#220` pattern:
```yaml
- name: "Generate Mission"
  type: prompt_template
  prompt: "generate-mission.md"
  clarification_file: "clarifications/mission.json"   # new field, optional
```
- If `clarification_file` is set, the task-runner injects an instruction into the prompt telling Claude where to write clarification questions, and runs detection against that path after the task completes.
- If the field is absent, detection is skipped entirely — this keeps the feature **opt-in**, so random prompt tasks don't pay any overhead.
- Path is resolved relative to `.bot/workspace/`.

### Scope: only `prompt` / `prompt_template` tasks trigger detection
Detection should not fire on non-Claude task types (`script`, `mcp`, `task_gen`, `barrier`) because they can't write the clarification file.

**Explicit edge case: `interview` tasks (from #220) must be skipped.** Interview tasks use their own internal clarification files as part of `Invoke-InterviewLoop`. If post-phase detection fires after an interview task completes, it would immediately re-trigger another question flow, creating a loop. The dispatch path must explicitly skip detection for `type: interview`.

This is a second reason this issue should land **after** #220 — the skip condition can't be written until the interview type exists.

### Adjust pass scope: `.bot/workspace/product/` only
Matching the kickstart engine convention. Workflows that produce artifacts outside `product/` will not benefit from the holistic re-read — that is an intentional, documented limitation to keep token cost and latency bounded. If a workflow wants the adjust pattern, it writes to `product/`.

### Task-runner does not currently track `clarification-questions.json` at all
Confirming the issue's claim: `Invoke-WorkflowProcess.ps1` has zero references to `clarification-questions` — I grepped. The detection + ask + adjust block needs to be added from scratch, adapted from `Invoke-KickstartProcess.ps1:339-572`. It is ~230 lines in kickstart; the task-runner version will be comparable.

### Relationship with existing `task_mark_needs_input`
`task_mark_needs_input` is an orthogonal mechanism — it's Claude-initiated during analysis (active tool call, single question) while post-phase detection is passive (file side channel, batched). Both need to coexist.

**They should share the same `pending_questions[]` schema and the same UI/Teams rendering path.** The user shouldn't have to know the difference — in both cases they see "this task has pending questions, answer them." This falls out naturally once the schema migration in the previous section is done.

### Small corrections to the issue
- **Test step 1** says "write a prompt task that instructs Claude to produce `mission.md` and also write `clarification-questions.json`". This would be a flaky test as written — Claude's output is non-deterministic. The prompt template must **explicitly instruct** Claude to write the clarification file with hard-coded content for the test. Otherwise layer 3 will be unstable.
- **Severity** is set to `low`, but the originating doc frames this as the "second-largest HITL parity gap." `medium` or `high` is more accurate; I'll go with `high` for consistency with the doc's wording.
- **Label** `type:bug` → `type:enhancement`. This is a missing capability, not a defect.

### Consolidated files to modify
- `workflows/default/systems/runtime/modules/ProcessTypes/Invoke-WorkflowProcess.ps1` — post-completion detection block + ask loop + inline adjust pass invocation, adapted from `Invoke-KickstartProcess.ps1:339-572`.
- Task schema — add `pending_questions[]`, remove `pending_question`.
- `workflows/default/systems/mcp/tools/task-mark-needs-input/script.ps1` — write to `pending_questions` as a single-element array; keep the single-question tool call shape (it's a Claude-facing API, not internal state).
- `workflows/default/systems/mcp/modules/NotificationClient.psm1` / `Send-TaskNotification` — support sending one notification per element in `pending_questions[]`.
- Web UI task-detail panel — render `pending_questions[]` as a batch form.
- Workflow manifest schema — new optional `clarification_file` field on prompt-type tasks.
- Tests: layer 2 test for the schema migration, layer 3 test that stubs a prompt task writing a fixed clarification file and verifies the adjust pass runs.

### Sequencing
This issue depends on #220 landing first: (a) the "skip interview tasks" edge case can't be written until the interview task type exists, and (b) the UI's pending-questions rendering can be reused across both issues if #220 goes first.

Detailed implementation notes (including why each decision was made so the implementer doesn't re-litigate) are captured at `docs/issue-221-post-phase-questions.md` in the worktree.
