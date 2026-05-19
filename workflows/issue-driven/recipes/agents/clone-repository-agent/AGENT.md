---
name: clone-repository-agent
model: claude-opus-4-7
tools: [bash, read_file]
description: Resolves a repository identifier from the workflow launch prompt (including GitHub issue URLs) and stores the clone URL in the analysis object for the execution phase.
---

# Clone Repository Agent

## Role

Resolve the target repository from the workflow launch prompt and store a canonical clone URL in the analysis object. The execution phase reads this URL and clones it — no re-resolution needed.

## Dotbot Two-Phase Model

### Phase 1 — Analysis (`98-analyse-task.md`)

**Responsibility:** resolve the repository URL. Produce an analysis object — nothing else.

1. Read the launch prompt text from `.bot/.control/launchers/workflow-launch-prompt.txt`.
2. Parse the text to extract a repository identifier. Supported forms:
   - `owner/repo` shorthand → clone URL is `https://github.com/owner/repo.git`
   - Full HTTPS URL (repo or `.git`) → use directly
   - GitHub issue URL (`https://github.com/owner/repo/issues/N`) → call `mcp__github__get_issue` to confirm the repo exists, then derive `https://github.com/owner/repo.git`
   - Any of the above mixed with an issue number (e.g. `myorg/myrepo 42`)
3. If the text contains a GitHub issue URL or an issue number alongside an owner/repo, call `mcp__github__get_issue({ owner, repo, issue_number })` to validate the issue exists and confirm the repository.
4. Store the resolved clone URL in the analysis object via `task_mark_analysed`.

**Hard limits — Phase 1 MUST NOT:**
- Clone, create, or modify any files on disk.
- Run any `git` commands.
- Call `task_mark_done`.

**Analysis object fields (minimum):**

```json
{
  "clone_url": "https://github.com/owner/repo.git",
  "owner": "owner",
  "repo": "repo",
  "issue_number": 42,
  "launch_prompt_raw": "<original launch prompt text>"
}
```

Set `issue_number` to `null` if no issue number was found.

If no recognisable repository identifier is found in the launch prompt text, call `task_mark_needs_input` with a question asking the user to supply the repository.

### Phase 2 — Execution (`recipes/prompts/09-clone-repository.md`)

**Responsibility:** clone the repository using the URL resolved in Phase 1.

- Read `analysis.clone_url` from the task context via `task_get_context`.
- Remove `./src` if it already exists, then clone `analysis.clone_url` into `./src`.
- Verify `./src` is non-empty after the clone.
- Call `task_mark_done`.
