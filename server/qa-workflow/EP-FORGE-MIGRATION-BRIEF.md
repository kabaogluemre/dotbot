# EP-Forge Migration Brief
## For: Jeff Claudon | Author: QA AI Ecosystem team
## Date: 2026-04-27

---

## Overview

Two QA AI repos — QA AI Ecosystem and EP-Forge — are being converged onto **dotbot** as a unified local platform. In the near term, both tools are being distributed to the QA team as **bridge tooling** while dotbot is built (roughly 17 weeks). This document covers:

1. The scope boundary between the two tools
2. Immediate changes needed in EP-Forge before distribution
3. New capability to add: **Paired Testing (explore-application)**
4. Credential/config migration
5. Longer-term dotbot migration context

---

## 1. Scope Boundary — What EP-Forge Owns

The QA lifecycle is split at a clear phase boundary:

```
GROOMING PHASE  →  QA AI Ecosystem
  Work Item → CRD → TAD → proposed-test-cases.md
  (Markdown docs only. No ADO artifacts created yet.)

DEVELOPMENT / TESTING PHASE  →  EP-Forge
  Exploratory testing via Playwright
    → establishes actual test cases from real findings
    → creates ADO artifacts (test cases, test runs)
    → codegen (locators, page objects, specs)
    → publishes results to ADO
    → creates PR with generated code
```

**QA feedback driving this boundary:** ADO artifact creation belongs in the Development/Testing phase, not Grooming. Proposed test cases during Grooming are for estimation and scope discussion only. Real test cases are established through exploratory testing, not theoretical planning from a TAD.

**EP-Forge is not a test planning tool.** It is an execution and automation tool. Planning happens in QA AI Ecosystem.

---

## 2. Immediate Changes Before Distribution

### 2.1 — Remove `test-plan` command entirely

**Delete these two files:**
- `.claude/commands/test-plan.md`
- `.github/skills/test-plan/SKILL.md` (and the `test-plan/` folder)

**Why:** The 6-step test-plan workflow (extract work item → build BoK → extract requirements → clarifications → generate test plan → generate test cases) duplicates QA AI Ecosystem's CRD and TAD pipeline. Having both tools claim to do planning will confuse the team. EP-Forge's entry point is exploratory testing, not planning.

The ADO test case creation step (Step 6) also no longer belongs here — test cases are created after exploratory testing establishes what the real cases are, not from a theoretical TAD analysis.

### 2.2 — Resolve execution branch state

When EP-Forge main was refreshed, the execution capabilities (execute-tests, retrieve-tests, update-ado, create-pr, generate-locators, generate-page-objects, generate-spec) were **not on main** — they were on a feature branch. Before distribution:

- Confirm which branch holds the complete automation suite
- Merge or cut a clean distribution branch that includes all execution commands
- Verify the branch is stable (not mid-development)
- Confirm commands run end-to-end against at least one real test case

### 2.3 — Update `.claude/CLAUDE.md`

Update the workspace instructions to reflect EP-Forge's actual entry point and scope. The team needs to understand:

- EP-Forge starts with **exploratory testing** — not test planning
- The exploratory session establishes what the real test cases are
- ADO test case creation happens after exploratory testing, from real findings
- EP-Forge does NOT produce CRDs, TADs, or requirements documents — those come from QA AI Ecosystem

Suggested framing for CLAUDE.md:

> EP-Forge is the QA execution and automation platform. It is used during the Development/Testing phase after a feature has been planned in QA AI Ecosystem.
>
> **Typical workflow:**
> 1. Run exploratory testing against the staging environment (`/execute-tests` or `/paired-testing`)
> 2. From findings, establish ADO test case records (`/update-ado`)
> 3. Generate automation code from the session (`/generate-locators` → `/generate-page-objects` → `/generate-spec`)
> 4. Publish test run results to ADO (`/update-ado`)
> 5. Create PR with generated code (`/create-pr`)

### 2.4 — Write a team setup guide

Write a setup guide covering:
- Prerequisites: Node.js, npm install, Claude Code CLI, Playwright MCP
- Credential setup: Windows Credential Manager entries required (see Section 4)
- Config setup: `config.json` from template, environment profiles
- First run verification
- Quick reference: which command does what

---

## 3. New Capability: Paired Testing (Explore Application)

Add the Paired Testing capability to EP-Forge. This is the exploratory browser testing workflow and is the **primary entry point** for EP-Forge users.

### What it is

A live browser-based testing session against a deployed environment. Two modes:

- **Claude Drives / Human Watches** — Claude navigates methodically through scenarios; human watches and redirects. Best for: stepping through known test cases; smoke checks.
- **Human Drives / Claude Watches** — Human navigates; Claude observes, records console/network, and documents. Best for: unscripted exploration; investigating suspected defects.

Switching modes mid-session is supported and expected. The session log is continuous.

### Files to create

#### A. `skills/estream-auth/SKILL.md` (or `.claude/commands/estream-auth.md`)

The complete estream-auth skill is in the QA AI Ecosystem repo at:
`skills/estream-auth.skill.md`

Copy and adapt for EP-Forge's credential approach (see Section 4 — credential migration). The procedure, rules, and tool calls are identical; only the credential source changes.

**Key rules (do not change these):**
- Never retry authentication on failure — a wrong password locks the account
- Never display credentials in responses
- Never skip role selection
- Stop immediately if authentication fails — do not proceed to test steps

#### B. `skills/explore-application/SKILL.md` (or `.claude/commands/explore-application.md`)

The complete explore-application skill is in the QA AI Ecosystem repo at:
`skills/explore-application.skill.md`

This skill is application-agnostic — copy it verbatim. It handles:
- Autonomous mode (Claude navigates based on scope)
- Observe mode (human navigates; Claude snapshots and records)
- The observation loop (snapshot → console → network after every interaction)
- Four output modes: `test-steps`, `page-model`, `functional-design`, `session-log`

For Paired Testing, the calling agent/command uses `outputMode: session-log`.

#### C. `.claude/commands/paired-testing.md`

The complete Paired Testing agent workflow is in the QA AI Ecosystem repo at:
`agents/paired-testing/paired-testing.agent.md`

Port this workflow into EP-Forge's command file pattern. The full workflow is:

**Step 1 — Gather inputs**
Collect from the user: environment URL, scope (test case IDs or feature area), mode (Claude drives / Human drives), optional work item ID, optional config profile.

**Step 2 — Load TAD (if work item ID provided)**
Read work item relations to locate TAD wiki link. Fetch the TAD via `mcp_ado_wiki_get_page`. Extract test case steps and preconditions for the scoped TC IDs. If no TAD, proceed with user-provided scope.

**Step 3 — Authenticate**
Invoke `estream-auth` skill with the environment URL and active profile.

> For non-Estream applications: substitute the appropriate auth skill. The rest of the workflow is application-agnostic.

Stop if authentication fails. Do not proceed without a confirmed, role-selected session.

**Step 4 — Confirm scope and start**
Summarize to the user: environment URL, server node, authenticated user, active role, session mode, scenario list. Confirm before proceeding.

**Step 5 — Run the session**
Invoke `explore-application` with:
- `startUrl`: first URL post-auth
- `scope`: confirmed scenario list or area description
- `sessionMode`: `autonomous` (Claude drives) or `observe` (human drives)
- `outputMode`: `session-log`

**Step 6 — Apply findings classification**

| Verdict | Meaning |
|---|---|
| ✅ Pass | Behavior matches expected result |
| ❌ Fail | Behavior does not match — evidence required |
| ⚠️ Anomaly | Unexpected behavior — needs confirmation |
| 🔲 Not tested | In scope but not reached this session |

Defect candidates = Fail or Anomaly findings with clear evidence. Identify but do not log to ADO without user approval.

**Step 7 — Write draft findings report and present**

Output path: `{project folder}/sessions/Session-{YYYY-MM-DD}-{workItemId or area}.md`

Present to user. Iterate on findings and wording.

**Step 8 — Act on approval**
On explicit approval:
- Publish session report to ADO Wiki (optional — if work item ID was provided)
- Log defect candidates as **Dev Bug** work items (Task level) under the relevant PBI — see Defect Logging below

### Required output structure

The session report format from QA AI Ecosystem should be preserved exactly — it was designed with QA Lead review in mind. See `agents/paired-testing/paired-testing.agent.md` for the full Required Output Structure and Defect Logging sections.

### Defect logging — work item type

**Work item hierarchy:**
```
Feature / Bug  (top-level — production-leaked bugs requiring planning, equivalent to Feature)
  └── PBI
        └── Task / Dev Bug  ← this is what Paired Testing creates
```

**Dev Bug** is a Task-level work item — a fix task under a PBI. **Do not create `Bug` work items** from testing sessions. `Bug` is a first-class backlog item used only for production-leaked defects that require planning (equivalent to a Feature).

**Determining the parent PBI:**
1. Try programmatically — read the work item's relations for a `System.LinkTypes.Hierarchy-Reverse` parent. If the parent is a Feature/Bug, traverse one level further to find the PBI.
2. If not determinable: prompt the user — *"Which PBI should these Dev Bugs be linked under?"*

**Creating the Dev Bug:**
```
mcp_ado_wit_create_work_item
  type: Dev Bug
  title: {DC title}
  description: {steps to reproduce + expected + actual + environment}
  area: {area path}
  tags: paired-testing

mcp_ado_wit_work_items_link
  sourceId: {parentPbiId}
  targetId: {newDevBugId}
  linkType: System.LinkTypes.Hierarchy-Forward
```

### Non-negotiable rules (carry forward unchanged)

1. Authenticate before any test steps. Never skip or shortcut.
2. Never display credentials in responses.
3. Do not retry authentication on failure. A wrong password locks the account. Stop and report.
4. Evidence first. Every finding must reference a screenshot, snapshot, console log, or network request.
5. Distinguish signal from noise. SignalR connection errors on staging are pre-existing. Flag once per session, do not re-report.
6. Never post to ADO without explicit user approval.

### Wiring it up

Add to `.claude/CLAUDE.md`:
```
/paired-testing  → follow .claude/commands/paired-testing.md
```

Add `.github/skills/paired-testing/SKILL.md`:
```yaml
name: paired-testing
description: Run a live paired browser testing session. Claude drives or human drives. Source of truth is .claude/commands/paired-testing.md.
```
Follow `.claude/commands/paired-testing.md`.

---

## 4. Credential / Config Migration

**Current EP-Forge approach:** Windows Credential Manager (`ado-mcp`, `anthropic-api-key`) — correct, keep this.

**QA AI Ecosystem's estream-auth** currently reads credentials from `framework/config/config.json` + `.env`. When porting `estream-auth` to EP-Forge, update the credential source to match EP-Forge's Windows Credential Manager approach.

The credential key for estream should follow the existing pattern. Suggested entries:
- `estream-{profile}` or `estream-staging` — estream username + password per environment
- Profile config (environment URL, required role, MFA settings) stays in `config.json` per existing EP-Forge pattern

**Important:** Never use `.env` files for credentials in EP-Forge. Windows Credential Manager is the single credential store.

---

## 5. Longer-Term: dotbot Migration

EP-Forge will migrate to dotbot as part of the unified QA platform. Timeline: ~15 weeks from now. Key things to know:

**The TypeScript app (`src/`) will be retired.** dotbot's web dashboard (PowerShell, port 8686) replaces it as the UI layer. Do not invest in new app features. Bug fixes only.

**The command files become skill source material.** dotbot uses `SKILL.md` files with YAML frontmatter and `workflow.yaml` for agent orchestration. EP-Forge's `.claude/commands/*.md` files are the primary source of truth for building those skills. The richer and more complete those command files are now, the easier the migration.

**EP-Forge's automation pipeline becomes the dotbot `qa` stack's automation layer.** The full lifecycle — exploratory testing → ADO test case creation → execution → codegen → results → PR — all becomes a sequence of dotbot skills orchestrated by `workflow.yaml` files.

**What this means for your work now:**
- Keep command files thorough and accurate — they directly become skill content
- Don't refactor the TS app — it's being retired
- The Paired Testing capability you're adding now will be the first thing that migrates to dotbot's Paired Testing agent

---

## 6. Reference Files

All source material for the Paired Testing addition is in the QA AI Ecosystem repo at `c:\Users\mkittman\qa ai ecosystem\`:

| What you need | Source file |
|---|---|
| Full Paired Testing workflow | `agents/paired-testing/paired-testing.agent.md` |
| Explore Application skill | `skills/explore-application.skill.md` |
| Estream Auth skill | `skills/estream-auth.skill.md` |
| Wiki read/publish skill | `skills/wiki.skill.md` |
| Example agent structure | `agents/crd/crd.agent.md` |
| Example skill structure | `skills/gather-work-item-context.skill.md` |

---

## 7. New Capability: QA Pull Request Review (QA-PRR)

The QA-PRR agent has been moved from QA AI Ecosystem into EP Forge's scope. It reviews PR code changes against the CRD and is particularly valuable for fast-track items that bypass the full grooming cycle — when no TAD exists, the QA-PRR is often the only QA lens on the code before it ships.

Full specification: **[QA-PRR-FOR-EP-FORGE.md](QA-PRR-FOR-EP-FORGE.md)**

That document covers:
- Why it belongs in EP Forge (code-delivery phase, not grooming)
- The three skills to port (`read-crd`, `triage-pr-files`, `wiki`)
- Where it fits in the EP Forge workflow (before Paired Testing; its "Items for QA Focus" section feeds directly into the live testing session)
- The complete workflow spec, output structure, guardrails, and an EP Forge implementation checklist

---

## 8. Summary Checklist

### Before distribution (immediate)
- [ ] Delete `.claude/commands/test-plan.md`
- [ ] Delete `.github/skills/test-plan/SKILL.md`
- [ ] Merge / confirm execution branch state (execute-tests, retrieve-tests, update-ado, create-pr, codegen on a stable branch)
- [ ] Update `.claude/CLAUDE.md` — exploratory testing is the entry point
- [ ] Write team setup guide

### Add Paired Testing capability
- [ ] Add `skills/estream-auth/SKILL.md` (adapted from QA AI Ecosystem, EP-Forge credential pattern)
- [ ] Add `skills/explore-application/SKILL.md` (copy verbatim from QA AI Ecosystem)
- [ ] Add `.claude/commands/paired-testing.md` (ported from QA AI Ecosystem paired-testing agent)
- [ ] Add `.github/skills/paired-testing/SKILL.md` (thin wrapper)
- [ ] Update `.claude/CLAUDE.md` to include `/paired-testing`
- [ ] Validate end-to-end: authenticate → explore → classify findings → produce session report

### Add QA-PRR capability
- [ ] Add `skills/read-crd/SKILL.md` (from `skills/read-crd.skill.md` in QA AI Ecosystem)
- [ ] Add `skills/triage-pr-files/SKILL.md` (from `skills/triage-pr-files.skill.md`)
- [ ] Add `skills/wiki/SKILL.md` if not already added for Paired Testing
- [ ] Add `.claude/commands/qa-prr.md` (workflow in QA-PRR-FOR-EP-FORGE.md)
- [ ] Add `.github/skills/qa-prr/SKILL.md` (thin wrapper)
- [ ] Update `.claude/CLAUDE.md` to include `/qa-prr`
- [ ] Validate end-to-end: work item with linked PR + published CRD → run QA-PRR → post PR comment → publish wiki

### Do not
- [ ] Do not add new features to the TypeScript app — bug fixes only
- [ ] Do not create `.env` files for credentials — Windows Credential Manager only
- [ ] Do not rebuild the test-plan workflow — that belongs to QA AI Ecosystem
