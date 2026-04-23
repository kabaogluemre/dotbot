<#
.SYNOPSIS
    Opens a GitHub pull request for the issue-driven workflow's shared feature branch.
.DESCRIPTION
    Reads the shared branch name and issue number from the dotbot control files,
    then calls `gh pr create` to open a PR against the configured base branch.
    Skips if a PR already exists for the branch.
    Called as a `type: script` task by the issue-driven workflow after all test phases complete.
.PARAMETER BotRoot
    Path to the .bot directory (always passed by the task-runner).
.PARAMETER ProcessId
    Dotbot process ID (always passed by the task-runner).
#>
param(
    [Parameter(Mandatory)]
    [string]$BotRoot,

    [Parameter(Mandatory)]
    [string]$ProcessId
)

$ErrorActionPreference = 'Stop'

# ── Load helpers ──────────────────────────────────────────────────────────────
Import-Module (Join-Path $BotRoot "systems\runtime\modules\DotBotTheme.psm1") -Force -DisableNameChecking

if (-not (Get-Module SettingsLoader)) {
    Import-Module (Join-Path $BotRoot "systems\runtime\modules\SettingsLoader.psm1") -DisableNameChecking -Global
}
. (Join-Path $BotRoot "systems\runtime\modules\workflow-manifest.ps1")

$projectRoot = Split-Path -Parent $BotRoot
$controlDir  = Join-Path $BotRoot ".control"

# ── Resolve issue number from kickstart prompt ─────────────────────────────
$promptFile  = Join-Path $controlDir "launchers\kickstart-prompt.txt"
$issueNumber = $null
if (Test-Path $promptFile) {
    $promptText  = (Get-Content $promptFile -Raw -ErrorAction SilentlyContinue).Trim()
    $issueNumber = $promptText -replace '\D', ''
}
if (-not $issueNumber) {
    Write-Status "Cannot resolve issue number — kickstart-prompt.txt missing or contains no digits." -Type Error
    exit 1
}

# ── Resolve shared branch name ─────────────────────────────────────────────
# Read the actual branch from this run's state file — Invoke-WorkflowProcess
# appends a per-run suffix (e.g. `-fe154c`) so reruns don't collide with an
# earlier run's branch/PR. Resolving from the manifest template would give the
# unsuffixed base name and incorrectly match an older PR.
$activeWf = Get-ActiveWorkflowManifest -BotRoot $BotRoot
if (-not $activeWf -or -not $activeWf.shared_branch) {
    Write-Status "No shared_branch configured in workflow manifest. Cannot open PR." -Type Error
    exit 1
}

$sharedBranch = $null
$runStateFile = Join-Path $controlDir "workflow-runs\$($activeWf.name).json"
if (Test-Path $runStateFile) {
    try {
        $runState = Get-Content $runStateFile -Raw | ConvertFrom-Json
        if ($runState -and $runState.shared_branch) {
            $sharedBranch = [string]$runState.shared_branch
        }
    } catch {
        Write-Status "Could not parse run state file: $runStateFile" -Type Warn
    }
}

if (-not $sharedBranch) {
    Write-Status "No active shared branch recorded in $runStateFile. Cannot open PR." -Type Error
    exit 1
}

Write-Status "Opening PR for branch: $sharedBranch (issue #$issueNumber)" -Type Process

# ── Settings: base branch ────────────────────────────────────────────────────
$settings     = Get-MergedSettings -BotRoot $BotRoot
$baseBranch   = if ($settings.issue_driven.pr_target) { $settings.issue_driven.pr_target } else { "main" }

# ── Check if PR already exists ─────────────────────────────────────────────
$existingPr = gh pr list --head $sharedBranch --json number,url 2>$null | ConvertFrom-Json
if ($existingPr -and $existingPr.Count -gt 0) {
    $prUrl = $existingPr[0].url
    Write-Status "PR already exists: $prUrl — skipping creation." -Type Info
    Write-Label "PR" $prUrl -ValueColor Cyan
    exit 0
}

# ── Build PR title and body ─────────────────────────────────────────────────
$prTitle = "feat: implement issue #$issueNumber"
$prBody  = @"
## Summary

Implements GitHub issue #$issueNumber end-to-end via the dotbot issue-driven workflow:

1. **Design Issue** — technical design document written
2. **Design Test Cases** — structured test cases authored
3. **Implement Issue** — production code written
4. **Unit Tests** — unit tests added
5. **Integration Tests** — integration tests added (if applicable)

## Changes

See commits on this branch for the full diff.

## Testing

- [x] All existing tests pass
- [x] Build succeeds with no warnings
- [x] Unit tests added by `/unit-test-pr`
- [x] Integration tests added by `/integration-test-pr`

Closes #$issueNumber
"@

# ── Create PR ─────────────────────────────────────────────────────────────
$prUrl = gh pr create `
    --title $prTitle `
    --body  $prBody `
    --base  $baseBranch `
    --head  $sharedBranch 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Status "gh pr create failed: $prUrl" -Type Error
    exit 1
}

Write-Status "PR opened: $prUrl" -Type Success
Write-Label "PR URL" $prUrl -ValueColor Green
Write-Label "Branch" $sharedBranch
Write-Label "Base" $baseBranch

exit 0
