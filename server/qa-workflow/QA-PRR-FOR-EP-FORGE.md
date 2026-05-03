# QA Pull Request Review (QA-PRR) — EP Forge Integration Spec
## For: Jeff Claudon | From: QA AI Ecosystem team

---

## Why This Is Moving to EP Forge

The QA-PRR agent reviews code against requirements. Its trigger is a PR event — a development artifact — not a grooming milestone. It belongs in the code-delivery phase with EP Forge, not in the grooming phase of the QA AI Ecosystem.

It is particularly valuable for **fast-track items** that bypass the full grooming cycle: when there is no TAD, the QA-PRR is often the only QA lens on the code before it ships. That makes it a natural fit for EP Forge, where fast-track items land.

---

## What It Does

The QA-PRR reads:
- The **CRD** published by QA AI Ecosystem (from ADO wiki — always available post-Gate 1)
- The **PR file diff** (via ADO MCP)
- The **TAD** (optional — improves automation section if available)

It produces:
- A structured requirement coverage assessment (every REQ-XX mapped to implementation status)
- A unit test coverage assessment
- A scope and regression surface analysis
- A QA Recommendation (Clear / Concerns / Hold)

It publishes:
- A comment on the PR thread (QA Recommendation summary + wiki link)
- A full QA-PRR wiki page under the feature's wiki folder

**Nothing is posted without explicit user approval.**

---

## Dependencies — Skills to Port

Three skills from QA AI Ecosystem are required. Port these into EP Forge's skill file pattern:

| Skill | Source file in QA AI Ecosystem | Notes |
|---|---|---|
| `read-crd` | `skills/read-crd.skill.md` | Locates and reads the CRD wiki page from a work item's relations. Returns the full requirements map and open items list. Port verbatim. |
| `triage-pr-files` | `skills/triage-pr-files.skill.md` | Classifies PR file changes by domain and risk tier without reading content. Produces a prioritized read list within a hard budget. Port verbatim. |
| `wiki` | `skills/wiki.skill.md` | ADO wiki read and publish operations. Port verbatim — QA AI Ecosystem and EP Forge share the same ADO instance. |

Unlike Paired Testing, the QA-PRR does **not** require Playwright or browser automation. It is a purely ADO-based workflow.

---

## EP Forge Integration Points

### Where it fits in the EP Forge workflow

```
[Code arrives / PR opens]
        │
        ▼
  QA-PRR (/qa-prr {workItemId})
        │  reads: CRD from wiki, PR diff from ADO, TAD from wiki (optional)
        │  produces: requirement coverage map, unit test gaps, regression surface
        │  posts: PR thread comment (QA Recommendation)
        │  publishes: wiki page under /Feature-{id} — {Title}/QA-PRR-{id}
        │
        ▼
  [QA recommendation recorded — tester uses Items for QA Focus during Paired Testing]
```

The QA-PRR runs **before** Paired Testing. Its "Items for QA Focus" section directly informs which areas the tester should prioritize during the live session.

### Fast-Track Items

When a feature has no TAD (fast-tracked through the SDLC), the QA-PRR still runs — it skips the TAD automation comparison section and notes that no TAD was available. The CRD is always the minimum input.

---

## Full Workflow Specification

### Command file: `.claude/commands/qa-prr.md`

Port the following workflow into EP Forge's command file pattern.

---

**Mission**

Produce a QA Pull Request Review for a Feature or Story. Assess the PR's code changes against the CRD's requirements: is the implementation complete, in-scope, and adequately covered by unit tests? Is the regression surface understood?

This is not a code quality review. It is a functional and scope review: does the code do what the CRD says, does it do anything the CRD does not say, and is the regression surface understood?

**Argument:** ADO work item ID (Feature or Story). CRD must exist on the wiki before this command runs.

---

**Non-Negotiable Rules**

1. Read the CRD first. Always. Every finding references a REQ-XX ID or flags the absence of one.
2. Anti-fabrication. Every concern is evidenced by a specific file, diff section, or requirement. Never invent gaps.
3. QA scope only. Do not comment on code style, naming conventions, or architecture unless a CRD requirement explicitly covers it.
4. Map every CRD requirement. Every REQ-XX is assessed: implemented, partially implemented, not found, not applicable to this PR, or not reviewed.
5. Unit test coverage is assessed, not mandated. Report what is present and absent. Flag gaps for requirements with high complexity or business risk.
6. Never post a PR comment or publish to wiki without explicit user approval.
7. Fixed document structure. Every QA-PRR uses the same sections in the same order.
8. Coverage confidence must be stated honestly. If the read budget was reached before all high-risk files were reviewed, say so. Never claim full coverage on a partial review.

---

**Phase 1 — Locate the Pull Request**

```
mcp_ado_wit_get_work_item
  id: {workItemId}
  project: {project}
  expand: relations
```

Extract: all linked PR IDs and repositories, the linked CRD wiki artifact, the linked TAD wiki artifact (if present), any linked child stories with their own PRs.

- If no PR is linked: stop and report.
- If multiple PRs: list all and confirm which to review (or review all if approved).

**Phase 2 — Read the CRD and PR Metadata**

Invoke `read-crd` to load the full requirements map and open items list.

```
mcp_ado_repo_get_pull_request_by_id
  pullRequestId: {prId}
  project: {project}

mcp_ado_repo_get_pull_request_changes
  pullRequestId: {prId}
  project: {project}
```

Invoke `triage-pr-files` with the file change list and CRD functional areas from `read-crd`.
- Small PRs (≤ 30 files): triage returns immediately, no user confirmation needed.
- Large / Oversized PRs: present triage table to user; wait for confirmation before reading files.

**Phase 3 — Targeted File Review**

Read only the files on the confirmed triage list. For each file:
- Which REQ-XX does this implement?
- Is the implementation consistent with the requirement?
- Does it implement behavior with no corresponding REQ-XX?

Do not read: lock files, generated files (`*.generated.ts`, swagger output).
If a file is too large to read in full: read top-level structure (class/method names, imports) and assess from that. Do not fabricate findings about unread code.

**Phase 4 — Requirement Coverage Assessment**

For every REQ-XX in the CRD:

| Status | Meaning |
|---|---|
| Implemented | One or more reviewed files clearly implement this requirement |
| Partially implemented | Some aspects present; others absent or unclear |
| Not found | No reviewed file corresponds to this requirement |
| Not applicable to this PR | Covered by a linked child story's separate PR — note the story ID |
| Implemented beyond scope | Code goes further than the requirement — flag for QA awareness |
| Not reviewed | Relevant files were outside the read budget |

Also assess CRD open items (OI-XX): was each resolved in code, left unresolved, or resolved differently than implied?

**Phase 5 — Unit Test Coverage Assessment**

Review all test files in the confirmed read list:
1. Coverage by requirement: which REQ-XX items have test coverage?
2. Net-new vs. updated tests.
3. Removed or disabled tests (`[Ignore]`, `skip`) — why?
4. Gap identification: flag requirements with business risk (financial, security, data integrity) that have no test coverage.

Do not calculate percentage coverage. Assess whether intent is covered.

**Phase 6 — Scope and Regression Analysis**

- **Scope creep:** Files outside the CRD functional areas — incidental dependency, undocumented enhancement, or escalate?
- **Regression surface:** Existing behaviors touched. Does the TAD automation impact section still match the actual diff?
- **Database / schema changes:** Additive-only (safe) or destructive/breaking?
- **Security / permission changes:** Map to REQ-XX or flag as undocumented.

If a security or financial calculation change is found with no corresponding CRD requirement: **always escalate**, regardless of apparent intent.

**Phase 7 — Draft and Present**

Write the draft QA-PRR to EP Forge's session output folder. Present to user. Iterate on findings and wording. Do not post or publish until approved.

**Phase 8 — Publish**

On user approval:
1. Post PR comment via `mcp_ado_repo_create_pull_request_thread` — include QA Recommendation and wiki link.
2. Publish wiki page via `wiki` skill — document type: `QA-PRR` (or `QA-PRR-PR{prId}` for multiple PRs).
3. Report PR comment URL and wiki page URL.

---

**Required Output Structure**

```markdown
# Feature {workItemId} – QA Pull Request Review (QA-PRR)
## {Feature Title}

| Field | Value |
|---|---|
| Work Item | [Feature {workItemId}]({ADO URL}) |
| Pull Request | [PR #{prId} — {PR Title}]({PR URL}) |
| CRD Reference | [CRD-{workItemId}]({wiki URL}) |
| TAD Reference | [TAD-{workItemId}]({wiki URL}) — or: *TAD not available* |
| PR Author | {author} |
| Target Branch | {branch} |
| Review Date | {date} |

---

## QA Recommendation

| Field | Value |
|---|---|
| Overall Status | ✅ Clear to test / ⚠️ Proceed with noted concerns / 🚫 Hold — gaps require resolution |
| Requirement Coverage | {X of Y implemented; Z not found; W partial} |
| Unit Test Coverage | Adequate / Gaps noted / Significant gaps |
| Scope | Clean / Minor incidental / Scope creep noted |
| Coverage Confidence | Full / Partial — {n} of {n} flagged files reviewed / Sampled — oversized PR |

**Summary:** {2–4 sentences. What was found, what concerns exist, what QA should focus on during test execution.}

---

## Pull Request Overview

| Field | Value |
|---|---|
| Total files changed | {n} |
| PR size classification | Small / Large / Oversized |
| Angular / client files | {n} |
| Backend / service files | {n} |
| Database / schema files | {n} |
| Test files | {n} |
| Configuration files | {n} |
| Other / dependency files | {n} |

**PR Description summary:** {one paragraph}

**Files not reviewed:** {list High-tier files excluded from read budget, or "All flagged files reviewed"}

---

## File Triage

| File | Domain | Change | Tier | Action |
|---|---|---|---|---|

---

## CRD Requirement Coverage

| REQ # | Title | Status | Evidence |
|---|---|---|---|
| REQ-XX | {title} | Implemented / Partially / Not Found / Not Applicable / Beyond Scope / Not Reviewed | {file(s) or explanation} |

**OI Status in Code:**

| OI # | Item | Code Status | Evidence |
|---|---|---|---|
| OI-X | {title} | Resolved / Unresolved / Resolved differently | {explanation} |

---

## Unit Test Coverage

| Requirement | Test Coverage | Notes |
|---|---|---|
| REQ-XX | Present / Absent / Partial | {what is tested or missing} |

**Test files reviewed:** {list}

**Removed or disabled tests:** {list with reason, or "None identified"}

**Coverage gaps of note:** {requirements with business risk lacking coverage, or "No significant gaps"}

---

## Scope Analysis

### Files Within Expected Scope
{Summary of file categories aligning with CRD functional areas.}

### Files Outside Expected Scope

| File | Domain | Assessment |
|---|---|---|
| {path} | {area} | Incidental dependency / Undocumented enhancement / Escalate |

---

## Regression Surface

**What else is touched:** {existing behaviors affected beyond the feature's requirements}

**Automated test impact (vs. TAD):** {TAD prediction vs. actual PR changes — omit if no TAD}

**Database / schema changes:** {additive vs. breaking}

**Security / permission changes:** {map to REQ or flag as undocumented}

---

## Items for QA Focus During Test Execution

{Bulleted list of specific areas, edge cases, or requirements identified as higher-risk. Written as actionable direction for the tester during Paired Testing.}
```

---

**QA Recommendation Levels**

| Status | Meaning |
|---|---|
| ✅ Clear to test | All requirements found; no significant gaps or scope concerns |
| ⚠️ Proceed with noted concerns | Most requirements present; minor gaps. Testers focus on flagged areas; dev acknowledges concerns |
| 🚫 Hold — gaps require resolution | Critical requirements missing; significant scope creep; or a security/data change with no corresponding requirement |

---

**Guardrails**

- No PR linked: stop and report.
- Multiple PRs: list all and confirm which to review.
- CRD unavailable: stop. Requirement coverage cannot be assessed without it.
- Requirement "Not Found" with plausible explanation (child story, separate PR): mark as "Not Applicable to this PR."
- File too large to read in full: read top-level structure only; do not fabricate findings.
- TAD unavailable: complete the review; note that automation impact comparison was skipped.
- Security or financial calculation change with no CRD requirement: always escalate.
- Read budget exhausted before all High-tier files reviewed: stop reading; list unreviewed files explicitly; set Coverage Confidence to Partial.
- Oversized PRs (80+ files): surface scope as a risk before reviewing; recommend splitting by CRD functional area.
- Never post PR comment or publish wiki page without explicit user approval.

---

## EP Forge Checklist for QA-PRR

- [ ] Add `skills/read-crd/SKILL.md` — copy from `skills/read-crd.skill.md` in QA AI Ecosystem
- [ ] Add `skills/triage-pr-files/SKILL.md` — copy from `skills/triage-pr-files.skill.md`
- [ ] Add `skills/wiki/SKILL.md` — copy from `skills/wiki.skill.md` (if not already present from Paired Testing addition)
- [ ] Add `.claude/commands/qa-prr.md` — using the workflow above
- [ ] Add `.github/skills/qa-prr/SKILL.md` — thin wrapper pointing to the command file
- [ ] Update `.claude/CLAUDE.md` to include `/qa-prr`
- [ ] Validate end-to-end: work item with linked PR + published CRD → run QA-PRR → post PR comment → publish wiki page
