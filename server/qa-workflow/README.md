# QA Ecosystem

Three AI agents that support QA planning and execution directly from ADO work items — producing a Consolidated Requirements Document, a Test Approach Document, and a QA Pull Request Review — and publishing each to the ADO Wiki.

---

## What's Included

| Agent | File | Purpose |
|---|---|---|
| CRD Agent | `agents/crd/crd.agent.md` | Reads a Feature or Story work item and all linked content; re-interprets BA/Support requirements into a numbered, testable engineering document; publishes to ADO Wiki |
| TAD Agent | `agents/tad/tad.agent.md` | Reads the CRD; evaluates existing ADO test cases; produces a combined test plan, test inventory (with shared steps and parameterized cases), and automation recommendation; publishes to ADO Wiki |
| Paired Testing Agent | `agents/paired-testing/paired-testing.agent.md` | Runs a live browser-based testing session against a deployed environment — Claude drives while the human watches, or the human drives while Claude watches. Produces a structured session findings report with evidence; optionally logs defects to ADO. |

> **QA Pull Request Review (QA-PRR):** The PR review agent has moved to **EP Forge**. It operates in the code-delivery phase (triggered by a PR) and reads CRD artifacts published by this ecosystem. See the EP Forge repo for usage.

### Typical Workflow

```
Feature work item ready
        │
        ▼
   CRD Agent (work item ID)
        │  reads: work item, linked items, linked wiki pages
        │  produces: Consolidated Requirements Document
        │  publishes: /Feature-{id} — {Title}/CRD-{id}
        │
        ▼
  [Gate 1 approval: EM + PO]
        │
        ▼
  TAD Agent (work item ID)
        │  reads: CRD, existing test cases
        │  produces: Test Approach + Test Inventory + Automation recommendation
        │  publishes: TAD-{id}
        │
        ▼
  [Gate 3 approval: TL + QA Lead]
        │
        ▼
  Groomed Backlog — feature scheduled for development
        │
        ▼
  [Code arrives / PR opens]
        │  → QA-PRR Agent (EP Forge) reads CRD from wiki and reviews the PR
        │
        ▼
  Paired Testing Agent (staging URL + scope)
        │  authenticates via standard login sequence
        │  Claude drives or Human drives (switchable mid-session)
        │  produces: session findings report — pass/fail/anomaly per scenario
        │  optionally logs: ADO Bug work items for defect candidates
        │  publishes: /Feature-{id} — {Title}/Testing-Session-{date}
        │
        ▼
     Test execution complete
```

---

## Prerequisites

### 1. ADO MCP Server

The agents use live ADO connectivity via the `@eprod/ado-mcp` package. This must be installed and authenticated before either agent can access work items or publish wiki pages.

All distributed agent files in this repository use the shared MCP tool prefix: `mcp_ado_...`.

Setup defaults to local stored MCP credentials/config when present and skips re-auth browser flow. To force re-auth, run `npm run setup:force-login`.

**Option A — PowerShell one-command setup (recommended, no Node.js required):**

1. Go to **https://ado-mcp.dvutil.eprod.com** and log in with your credentials
2. Copy the **Quick Setup** command shown after login
3. Paste into PowerShell — it auto-detects Claude Code and VS Code and writes the config for you

To refresh an expired token later:
```powershell
irm https://ado-mcp.dvutil.eprod.com/setup.ps1 | iex
```

**Option B — npm install:**

```powershell
npm config set "@eprod:registry" "https://artifactory-prd.eprod.com/artifactory/api/npm/rm-npm-dev/"
npx @eprod/ado-mcp login --server https://ado-mcp.dvutil.eprod.com
```

**Restart VS Code after setup.** MCP servers load at session start, not mid-session.

> Full documentation: [GETTINGSTARTED.md](http://tfs.eprod.com/LS/ReleaseManagement/_git/ado-mcp-onprem?path=/docs/GETTINGSTARTED.md)

### 2. ADO Permissions

The account running the agent session needs:
- **Read** access to work items in the target project
- **Read/Write** access to the target ADO Wiki
- **Read** access to any wiki pages linked from work items

### 3. AI Tool — Claude Code or GitHub Copilot

- **Claude Code** (recommended): Full agent support; MCP tools called natively; iterative review and publish flow works as designed.
- **GitHub Copilot**: Supported via Copilot Chat with the agent file used as context (see usage section below). MCP tool calls require Copilot MCP support to be enabled.

### 4. Browser Automation — Playwright MCP (optional, for live environment verification)

The QA-PRR Agent can navigate a live test environment directly when the Playwright MCP server is installed. This enables Claude to verify Angular screen loading, check feature toggles, execute smoke checks, and capture screenshots — without manual browser interaction.

> **Already installed on this machine:** `@playwright/mcp` v0.0.70, Playwright v1.59.1, Chromium v147. Skip Steps 1 and 2.

**Step 1 — Install the Playwright MCP server:**

```powershell
npx @playwright/mcp@latest
```

**Step 2 — Install Playwright browsers:**

```powershell
npx playwright install chromium
```

**Step 3 — Add to Claude Code MCP config:**

Open VS Code Settings → Claude Code → MCP Servers (or edit `.vscode/settings.json` / your Claude Code config file directly) and add:

```json
{
  "mcpServers": {
    "playwright": {
      "command": "npx",
      "args": ["@playwright/mcp@latest"]
    }
  }
}
```

**Step 4 — Restart VS Code.** MCP servers load at session start.

Once active, Claude has access to browser navigation, clicking, form filling, screenshot capture, and page content reading — enabling live environment verification as part of QA test execution.

---

## Usage — Claude Code

Claude Code is the primary tool for these agents. The agents are designed for an interactive session: the agent drafts the document, you review and iterate, then approve publication to the wiki.

### Invoking the CRD Agent

Open the project in Claude Code (VS Code extension or CLI). Start a new conversation and provide the agent file as context:

```
Use the CRD agent at QA Ecosystem/agents/crd/crd.agent.md.
Work item ID: [your Feature or Story ID]
```

The agent will:
1. Read the work item and all linked content from ADO
2. Draft the Consolidated Requirements Document
3. Present the draft for your review
4. Iterate based on feedback
5. Publish to the wiki on your explicit approval

### Invoking the TAD Agent

Once the CRD is published (or at minimum drafted), invoke the TAD Agent:

```
Use the TAD agent at QA Ecosystem/agents/tad/tad.agent.md.
Work item ID: [your Feature or Story ID]
```

The agent will:
1. Locate and read the CRD wiki page from ADO
2. Pull any existing test cases linked to the work item
3. Assess existing TCs (keep, update, consolidate, retire)
4. Draft the Test Approach document
5. Present for review and iterate
6. Publish to the wiki on your explicit approval

### What to Expect

All agents follow a **draft → review → publish** flow. Nothing is written to ADO until you explicitly approve. The agents will surface open items and flag anything requiring your input before proceeding.

---

## Usage — GitHub Copilot

Copilot Chat does not natively invoke agent files the way Claude Code does, but the agents work well as structured prompts with context attached.

### Setup

1. Ensure the shared ADO MCP server is configured in your Copilot MCP settings (workspace or user-level MCP config) and Copilot MCP is enabled for your workspace.
2. Open the relevant agent file in VS Code.

Note: Use dedicated MCP configuration (`mcp.json`) instead of configuring MCP servers in VS Code user settings.

### Invoking the CRD Agent

In Copilot Chat:
1. Attach `agents/crd/crd.agent.md` as context (drag into chat or use `#file:`)
2. Prompt:

```
Follow the instructions in the attached CRD agent file.
Work item ID: [your Feature or Story ID]
```

### Invoking the Test Approach Agent

1. Attach `agents/tad/tad.agent.md` as context
2. If the CRD is already published to the wiki, reference its path. If it's a local draft, attach the CRD file as additional context.
3. Prompt:

```
Follow the instructions in the attached Test Approach agent file.
Work item ID: [your Feature or Story ID]
CRD wiki path: /Feature-{id} — {Title}/CRD-{id}
```

---

## Output — ADO Wiki Pages

Both agents publish under the standard Estream wiki path convention:

```
/Feature-{workItemId} — {Title}/
├── CRD-{workItemId}    ← Consolidated Requirements Document
└── TAD-{workItemId}    ← Test Approach Document
```

**Path encoding note:** ADO Wiki API paths use spaces and literal hyphens directly. The git file path encoding (hyphens for spaces, `%2D` for literal hyphens) is different and must not be passed to the API. The agents handle this automatically.

Each published page includes an **Approval Block** at the top — a status field and approver table that the team fills in as the document moves through its gate.

### Wiki Publishing Process (Lead-Owned)

This process is documented and enforced in each agent file. For CRD and TAD specifically, the expected flow is:

1. Lead runs the agent and provides work item ID.
2. Agent reads source material from ADO via shared `mcp_ado_...` tools.
3. Agent drafts CRD or TAD and presents it for review.
4. Lead iterates with the agent until acceptable.
5. Lead gives explicit publish approval.
6. Agent publishes wiki page (`mcp_ado_wiki_create_or_update_page`).
7. Agent links page artifact back to the work item (`mcp_ado_wit_add_artifact_link`).

Nothing is published until explicit approval is given in the session.

---

## Document Structure

### CRD — Consolidated Requirements Document

| Section | Content |
|---|---|
| Metadata | Work item link, state, area, iteration, requestors |
| Approval | Gate 1 status and approver table |
| Overview | Problem statement and solution summary (engineering audience) |
| Out of Scope | Explicitly excluded items |
| Requirements | Grouped by functional area; REQ-{prefix}{n} IDs (e.g., REQ-C1, REQ-W3) |
| Open Items | Ambiguities and gaps surfaced for resolution before development begins |

### TAD — Test Approach Document

| Section | Content |
|---|---|
| Approval | Gate 3 status and approver table |
| Open Items Affecting Test Scope | CRD open items that block or affect test cases |
| Shared Steps | Reusable step sequences called by multiple test cases (SS-XX) |
| Test Summary | TC ID, title, type, requirements covered, existing ADO TC mapping |
| Test Cases | Standard and parameterized test cases with shared step references |
| Test Plan | Scope, effort estimate, prerequisites |
| Automation | Philosophy applied + single smoke scenario (or thorough coverage plan for financial/security features) + existing automated test impact |
| Existing ADO TC Disposition | Assessment of every previously linked test case (Keep / Update / Consolidate / Retire) |

---

## Automation Philosophy

The Test Approach Agent applies a consistent philosophy to every feature:

- **Automate for regression protection of core behavior** — not for coverage of all permutations.
- For most features: one core smoke-level E2E scenario that proves the feature works on future builds.
- **Financial and security features are an exception** — thorough automation coverage is required. The agent will flag this explicitly and plan coverage accordingly.
- Manual testing is fully adequate for development-time verification of individual scenarios.

---

## Backlog / TODO

- Role-selection hardening: inventory all role-selection pages and exact buttons/selectors by route; replace remaining generic fallback logic with explicit mappings (TBD).

---

## Credential Standard (QA Sessions)

Simple standard for shared QA credentials (for example, EvolveTestUserA):

1. **Store of record:** ADO Variable Group (shared team-managed source).
2. **Local runtime store:** Windows Credential Manager target `QA-Ecosystem-TEST` (or `QA-Ecosystem-{credentialKey}` for multi-profile usage).
3. **Retrieval:** `npm run refresh-creds` pulls current values from the Variable Group using Windows integrated auth and updates Credential Manager.
4. **Pre-session check:** `npm run check-creds` compares local Credential Manager values to the shared source and auto-refreshes when missing/stale.
5. **Session entry:** `npm run test:session` now runs credential check first, then starts the smoke session.
6. **Access denied handling:** if smoke login detects likely auth/access-denied failure, it force-refreshes credentials once and retries automatically.

If the shared Variable Group has not been created yet, setup will continue without local credentials and show a warning. After the group exists, run `npm run refresh-creds`.

Legacy compatibility: `.env` is treated as fallback only. Refresh now removes legacy cleartext `.env` credentials after migrating to Credential Manager.

Optional environment overrides for different projects/groups:

- `QA_TFS_URL`
- `QA_TFS_COLLECTION`
- `QA_TFS_PROJECT`
- `QA_CREDENTIAL_GROUP_NAME`
- `QA_TFS_API_VERSION`

---

## Setup Coverage vs Manual Inputs

`npm run setup` covers machine/bootstrap dependencies and shared auth plumbing:

1. Node/runtime validation
2. npm package install
3. Playwright browser install
4. `@eprod` npm registry configuration
5. ADO MCP authentication (or skip if already present)
6. Shared credential refresh into Windows Credential Manager (when Variable Group exists)

`setup` does **not** know your target test environment details. Those remain manual in `framework/config/config.json`.

### config.json Update Checklist

After first setup, copy `framework/config/config.template.json` to `framework/config/config.json` and update at least:

1. `profiles.default.baseUrl` — real staging URL (replace `stagingXXua` placeholder)
2. `profiles.default.testAccount.requiredRole` — role for the account/session
3. Optional additional profiles — remove `_example-second-profile` or rename it to an active profile name before use
4. Optional `credentialKey` per profile — keep `TEST` unless you intentionally use a different shared credential target

Validation sequence:

1. `npm run health`
2. `npm run test:session`

---

## Credential Lifecycle (User View)

This is how credentials are handled during normal QA usage:

1. `npm run refresh-creds`
2. Script pulls `TEST_USERNAME` / `TEST_PASSWORD` from ADO Variable Group `ETA-UserA`.
3. Credentials are stored locally in Windows Credential Manager as `QA-Ecosystem-TEST`.
4. Legacy cleartext `.env` cache is removed (if present).

### Retrieval Order at Runtime

When automation loads config for login:

1. Windows Credential Manager (`QA-Ecosystem-{credentialKey}`)
2. Environment variable fallback (`{credentialKey}_USERNAME`, `{credentialKey}_PASSWORD`)
3. Legacy `.env` fallback (compatibility only)

### Pre-Session Guard

`npm run test:session` runs `npm run check-creds` first.

`check-creds` compares local credential target against ADO Variable Group values and auto-refreshes when:

1. credential target is missing
2. username differs
3. password differs
4. force refresh is requested

### Access Denied Recovery

During `npm run test:session` smoke execution:

1. If likely auth/access-denied failure is detected, the run triggers forced credential refresh once.
2. The smoke run retries once automatically.
3. If retry still fails, the command exits with failure so the issue is visible to the user.
