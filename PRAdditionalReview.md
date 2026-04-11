## Follow-up after further investigation

Did a deeper pass through the code and cross-referenced section 7.1 of the originating design doc. A few things in the original description need tightening before implementation starts, and a handful of decisions that the description left implicit should be written down explicitly so the implementer doesn't have to guess. Posting them here for visibility.

### Dispatch types in the description are slightly off
The description says `Invoke-WorkflowProcess.ps1:325-357` dispatches `script`, `mcp`, `task_gen`, `barrier`, `prompt`. In the actual code, `prompt` is not a dispatched type — it's the default fall-through that runs the normal Claude analysis + execution path (see the guard at ~line 290: `if ($taskTypeVal -notin @('prompt'))`). The real dispatched types are `script`, `mcp`, `task_gen`, `barrier`. `prompt_template` is normalized to `prompt` at lines 273-289 and also falls through.

This matters because implementation needs to touch **two** places, not just the switch:
- Add `interview` to the pre-dispatch guard at line 290 so interview tasks skip the analysis phase.
- Add the `interview` case to the switch at 325-357 that calls `Invoke-InterviewLoop`.

### Summary file path convention should be stated explicitly
`summary_file: "interview-summary.md"` in the manifest needs an anchor. Going with **paths relative to `product/`**, matching the kickstart engine convention. The `Invoke-InterviewLoop` function currently hard-codes its three output filenames at `InterviewLoop.ps1:46-48` under `$ProductDir` — those will be parameterized for this issue so task-runner can pass in per-task filenames. The kickstart call site keeps its current behavior via parameter defaults, so there should be no regression there.

### Multiple interviews in one workflow — designer handles uniqueness via manifest
The description requires multiple interview tasks in a workflow, but `Invoke-InterviewLoop` today writes to fixed filenames which would clobber. Going with **explicit uniqueness via the manifest**: every interview task declares its own `summary_file`, and the doc's second example (`architecture-decisions.md`) already illustrates this. No task-id-based automatic uniqueness — keeping the schema honest about where files land.

### How downstream tasks consume the summary — convention, not injection
The description says "via standard file references and prompt injection." Worth being explicit about what that means in practice, because there is no automatic output→input injection mechanism in the task-runner today. I checked — `outputs` is only used by the kickstart engine for file-existence validation (`Invoke-KickstartProcess.ps1:587-589`); `Invoke-WorkflowProcess.ps1` doesn't read it at all.

So the mechanism is convention-based and already works:
1. The downstream task is typically a `prompt_template` task.
2. Its prompt template file contains a **static reference** to the summary path (e.g. "Before starting, read `product/interview-summary.md` for user-provided requirements").
3. `depends_on` guarantees ordering; at runtime Claude reads the template, sees the path, opens the file.

**Automatic output→input injection is out of scope for this issue.** If it's wanted later, it should be a separate framework-wide change because it affects all task types, not just interview.

### Parallelism — going with soft barrier via `depends_on`
The description doesn't address what happens to parallel tasks while an interview is waiting on the user. Going with the **soft barrier** model: only tasks that have the interview in their `depends_on` chain wait; independent branches continue executing. This is just the existing `depends_on` semantics — no special case needed. If a hard-barrier variant is ever desired, it can be added later as a flag or separate type.

### Runtime UI wiring is missing from doc 7.1 — adding it to the scope
Doc 7.1 lists "Studio workflow editor" — that covers the **design-time** form (`studio-ui/src/client/components/PropertiesPanel.tsx`, where the user sets `prompt_file` / `summary_file`). But there's a second piece the doc skipped: the **runtime** web UI that actually shows the questions to the user while the interview executes.

Good news: the kickstart interview panel already exists and handles this. `Invoke-InterviewLoop` already emits `Write-ProcessActivity` events and writes to the shared process registry, so most plumbing is done. The missing piece is a branch in `workflows/default/systems/ui/modules/ProductAPI.psm1` — it currently routes to the interview panel only for kickstart processes. That branch needs to extend to task-runner processes whose currently-executing task is `type: interview`. No new panel or React components — just reuse.

Adding this to the scope explicitly because without it the feature doesn't actually work end-to-end.

### Relationship to doc 7.2 — keeping this issue narrow
Doc 7.2 (post-phase question detection + adjustment pass) is the other half of full kickstart HITL parity, and it's worth flagging that it is **not** part of this issue. If it's wanted, it should be tracked separately so the scope of #220 stays focused on the interview task type itself.

### Small corrections
- Label: `type:bug` → `type:enhancement`. This is a missing capability, not a defect.
- Test step 7 in the description: `type: prompt` → `type: prompt_template`. `prompt` is not an explicit manifest type, it's the default fall-through, so adding a "second prompt task" is ambiguous.

### Consolidated files to modify
- `workflows/default/systems/runtime/modules/InterviewLoop.ps1` — parameterize output filenames and interview prompt path; defaults preserve current kickstart behavior.
- `workflows/default/systems/runtime/modules/ProcessTypes/Invoke-WorkflowProcess.ps1` — new `interview` dispatch case + pre-dispatch guard update.
- Task type ValidateSet + `New-WorkflowTask` MCP tool — recognize the new type and its `interview` block.
- `workflows/default/systems/ui/modules/ProductAPI.psm1` — route task-runner interview processes to the existing kickstart interview panel.
- `studio-ui/src/client/components/PropertiesPanel.tsx` — design-time form fields for `interview.prompt_file` and `interview.summary_file`.
- Tests: Layer 2 dispatch test + manifest validation test for `type: interview`.

Detailed notes for the implementer (including why each decision was made so they don't re-litigate) are captured at `docs/issue-220-interview-task-type.md` in the worktree.
