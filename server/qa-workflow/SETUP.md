# QA Ecosystem — Setup Guide

Estimated first-time setup: **15–20 minutes**.

---

## What You're Setting Up

This ecosystem uses two AI tool integrations that must be running before any agent works:

| Integration | What it does | Where it runs |
|---|---|---|
| **ADO MCP server** | Gives Claude live access to work items, wiki pages, and PRs in TFS | Kubernetes — `https://ado-mcp.dvutil.eprod.com` |
| **Playwright MCP server** | Gives Claude control of a real browser for live testing sessions | Your machine (started automatically by Claude Code) |

Both are registered in config files that Claude Code reads at startup. If either is missing or has an expired token, Claude will tell you it can't call ADO tools or browser tools — setup is what wires them in.

---

## Prerequisites

Install these before running setup:

| Requirement | How to get it |
|---|---|
| **VS Code** | [code.visualstudio.com](https://code.visualstudio.com) |
| **Claude Code extension** | VS Code → Extensions (`Ctrl+Shift+X`) → search **Claude Code** → Install |
| **Git** | [git-scm.com](https://git-scm.com) — required to clone the repo |
| **Node.js LTS (18+)** | [nodejs.org](https://nodejs.org) |
| **ENTERPRISE\ domain account** | For ADO MCP login |
| **Estream project permissions** | Read/write on work items and wiki — contact QA Lead if needed |

---

## Setup Steps

### 1. Clone and open the workspace

```powershell
git clone http://tfs/LS/Estream/_git/qa-ai-ecosystem
```

Open VS Code with the workspace file:

**VS Code → File → Open Workspace from File → select:**
```
qa-ai-ecosystem/QA Ecosystem.code-workspace
```

> **Why the workspace file?** It wires up a startup readiness check that runs automatically each time you open VS Code. If your ADO token is expired or Playwright isn't registered, VS Code will tell you immediately — before you start a session.

### 2. Run setup

```powershell
cd framework
npm run setup
```

What this does, in order:

1. Validates Node.js is installed
2. Installs npm packages (Playwright, etc.)
3. Installs Playwright Chromium browser
4. Configures the `@eprod` npm registry scope
5. **Opens a browser — log in with your ENTERPRISE\ domain credentials.** This authenticates you to the ADO MCP server and writes tokens to your local config files.
6. Registers the Playwright MCP server in `~/.claude/.mcp.json`
7. Pulls shared test credentials from the ADO Variable Group into Windows Credential Manager

> **Browser didn't open, or login errored?** Run `npm run setup:force-login` to force a fresh auth flow.

> **"Variable Group not found" warning?** Setup will continue. Contact the QA Lead to be added to the ADO Variable Group, then run `npm run refresh-creds`.

### 3. Create your config file

```powershell
copy config\config.template.json config\config.json
```

Open `config/config.json` and fill in:

| Field | What to set |
|---|---|
| `profiles.default.baseUrl` | Your staging URL — e.g. `https://staging18ua.eprod.com` |
| `profiles.default.testAccount.requiredRole` | Role to select after login — e.g. `QA Analyst` |

Remove or rename the `_example-second-profile` entry unless you need it.

### 4. Restart VS Code

**This step is required.** MCP servers load when VS Code starts — changes to config files are not picked up mid-session. Close and fully reopen VS Code.

### 5. Verify the setup

Run the health check and smoke session from `framework/`:

```powershell
npm run health
npm run test:session
```

A passing smoke session confirms Node, credentials, and environment config are all working.

Then open a Claude Code session in the workspace and run a quick MCP check:

```powershell
npx @eprod/ado-mcp doctor
```

Healthy output looks like:

```
✅ Access token valid  (expires in ~23h)
✅ Refresh token valid (expires in ~6d 22h)
✅ TFS reachable
✅ MCP endpoint reachable
```

If it shows warnings or errors, see the troubleshooting section below.

---

## Understanding the ADO MCP Token Lifecycle

When the startup check runs, you'll see two token lines:

```
✅ ADO MCP token    valid (6h remaining)
✅ ADO refresh token present (opaque)
```

These are two different things and they work together:

| What you see | Plain English | TTL |
|---|---|---|
| **ADO MCP token** | The key Claude uses to make every ADO API call. Short-lived. | ~8–24 hours |
| **ADO refresh token** | A long-lived credential used to mint a new MCP token when the current one expires. You never use it directly. | 7 days |

Think of it like a parking garage: the **MCP token** is your day pass — it gets you in, but expires tonight. The **refresh token** is your account on file — it lets the system print you a new day pass automatically, without you having to re-register.

**Normal daily operation — nothing to do.** When the MCP token expires, the next agent call automatically exchanges the refresh token for a fresh one. You won't notice.

**If the MCP token is expiring soon and you want to avoid a mid-session interruption**, refresh it proactively:

```powershell
npm run refresh-creds
```

**After a long break (>7 days without any ADO MCP usage)**, the refresh token itself expires. Automatic renewal no longer works and agent calls will fail with auth errors. Fix:

```powershell
npm run setup:force-login
```

Then restart VS Code.

**When to check:** If an agent call fails with an auth error, run `doctor` first — it tells you exactly which token is the problem before you do anything else:

```powershell
npx @eprod/ado-mcp doctor
```

---

## Troubleshooting — ADO MCP Server

### Step 1: Run the doctor command

```powershell
npx @eprod/ado-mcp doctor
```

This is your first diagnostic step for any ADO MCP issue. It checks access token validity, refresh token validity, TFS reachability, and the MCP endpoint itself.

### "Access token expired" (doctor output)

Normal — will auto-rotate on the next tool call. If it doesn't rotate:

```powershell
npm run setup:force-login
```

Restart VS Code.

### "Refresh token expired" (doctor output)

Full re-authentication required:

```powershell
npm run setup:force-login
```

A browser will open — log in with your domain credentials. Restart VS Code when done.

### Agent calls fail with "unauthorized" or "401" in Claude Code

1. Run `npx @eprod/ado-mcp doctor` — check which token is the problem
2. If access token expired and didn't auto-rotate: `npm run setup:force-login`
3. Verify your config file has an `ado` entry:

```powershell
cat "$env:USERPROFILE\.claude\.mcp.json"
```

You should see an `ado` server with a non-empty `Authorization` header and a `_refreshToken` field. If the file is missing the `ado` entry entirely, re-run `npm run setup:force-login`.

### ADO MCP server shows as disconnected in Claude Code

Claude Code shows MCP server status in the status bar. If `ado` is disconnected:

1. Check `~/.claude/.mcp.json` has the server entry (see above)
2. Restart VS Code — servers connect at startup
3. Run `doctor` to confirm the server itself is reachable
4. If on a network where `ado-mcp.dvutil.eprod.com` is not accessible, confirm VPN is connected

### "TFS unreachable" in doctor output

You're likely off-network. Connect to VPN and retry.

---

## Troubleshooting — Playwright MCP Server

The Playwright MCP server runs locally — Claude Code starts it automatically as a subprocess when it's needed. No separate process to manage.

### How to confirm Playwright MCP is registered

Check `~/.claude/.mcp.json`:

```powershell
cat "$env:USERPROFILE\.claude\.mcp.json"
```

You should see a `playwright` entry:

```json
"playwright": {
  "command": "npx",
  "args": ["@playwright/mcp@latest"]
}
```

If it's missing, add it manually and restart VS Code. Or re-run setup — it will add it.

### Claude says "browser tool not found" or "playwright tool not available"

1. Confirm `playwright` is in `~/.claude/.mcp.json` (above)
2. Restart VS Code — the server registers at startup
3. Confirm Playwright Chromium is installed:

```powershell
cd framework
npx playwright install chromium
```

4. Open a Claude Code session and ask: *"Is the playwright MCP server connected?"* — Claude will tell you what it sees.

### Browser opens but immediately closes, or navigation fails

Chromium may not be installed. Run:

```powershell
cd framework
npx playwright install chromium
```

---

## Troubleshooting — Test Credentials

### Access-denied error during a Paired Testing session

The agent stops immediately on an auth failure — it will not retry (a wrong password can lock the test account). Before starting a live session:

```powershell
npm run check-creds    # compares local vs. ADO Variable Group
npm run refresh-creds  # pulls latest from Variable Group if stale
```

### Credentials are out of date

Test account passwords rotate periodically. Refresh:

```powershell
npm run refresh-creds
```

This pulls the current password from the ADO Variable Group into Windows Credential Manager. No config file changes needed.

### "Variable Group not found" during refresh

You don't have access to the Variable Group. Contact the QA Lead. Once granted:

```powershell
npm run refresh-creds
```

---

## Daily Startup Checklist

Before starting a session that uses live browser testing:

1. **Credentials fresh?** `npm run check-creds` — auto-refreshes if stale
2. **Right staging environment?** Confirm `profiles.default.baseUrl` in `config/config.json`
3. **MCP tokens healthy?** `npx @eprod/ado-mcp doctor` — takes 5 seconds, saves debugging time

For document work only (CRD, TAD — no browser):

1. Open workspace in VS Code
2. Start a Claude Code session
3. Invoke the agent

---

## Quick Reference

| Task | Command |
|---|---|
| First-time setup | `npm run setup` |
| Force re-login to ADO MCP | `npm run setup:force-login` |
| Check ADO MCP token health | `npx @eprod/ado-mcp doctor` |
| Refresh test credentials | `npm run refresh-creds` |
| Compare local vs. shared creds | `npm run check-creds` |
| Health check | `npm run health` |
| Smoke session | `npm run test:session` |
