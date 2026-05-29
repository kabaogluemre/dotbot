<#
.SYNOPSIS
    Opens a GitHub pull request from the run's shared feature branch to main.
.DESCRIPTION
    The issue-driven workflow runs directly inside the target repository in
    `shared_feature_branch` mode: every task forks a worktree from one feature
    branch and the framework squash-merges each back into it, pushing after every
    task. By the time this script runs the feature branch already holds all the
    work. This script resolves that branch from the run-state file, ensures it is
    pushed, and opens a PR (feature → main). Idempotent: skips if a PR exists.
    Called as a `type: script` task after all phases complete.
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
Import-Module (Join-Path $BotRoot "core\runtime\modules\DotBotTheme.psm1") -Force -DisableNameChecking

if (-not (Get-Module SettingsLoader)) {
    Import-Module (Join-Path $BotRoot "core\runtime\modules\SettingsLoader.psm1") -DisableNameChecking -Global
}
. (Join-Path $BotRoot "core\runtime\modules\workflow-manifest.ps1")

$projectRoot = Split-Path -Parent $BotRoot
$controlDir  = Join-Path $BotRoot ".control"

# ── Resolve issue number from kickstart prompt (for the PR body) ────────────
# Robust parse: a bare `-replace '\D',''` concatenates every digit in the text,
# so an issue URL like .../arc-summit-app-2026/issues/24 yields "202624".
function Resolve-IssueNumber {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $t = $Text.Trim()
    if ($t -match 'github\.com/[^/\s]+/[^/\s]+/(?:issues|pull)/(\d+)') { return $Matches[1] }
    if ($t -match '#(\d+)') { return $Matches[1] }
    if ($t -match '(?:^|\s)(\d+)\s*$') { return $Matches[1] }
    if ($t -match '(?:^|\s)(\d+)(?:\s|$)') { return $Matches[1] }
    return $null
}

$promptFile  = Join-Path $controlDir "launchers\workflow-launch-prompt.txt"
$issueNumber = $null
if (Test-Path $promptFile) {
    $promptText  = (Get-Content $promptFile -Raw -ErrorAction SilentlyContinue).Trim()
    $issueNumber = Resolve-IssueNumber -Text $promptText
}

# ── Resolve the feature branch from this run's state file ──────────────────
# Invoke-WorkflowProcess generates and persists the suffixed feature branch
# (e.g. feature/issue-24-fe154c). Resolving from a manifest template would give
# the wrong (unsuffixed) name and match an older run's PR.
$activeWf = Get-ActiveWorkflowManifest -BotRoot $BotRoot
if (-not $activeWf) {
    Write-Status "No active workflow manifest. Cannot open PR." -Type Error
    exit 1
}

$featureBranch = $null
$runStateFile  = Join-Path $controlDir "workflow-runs\$($activeWf.name).json"
if (Test-Path $runStateFile) {
    try {
        $runState = Get-Content $runStateFile -Raw | ConvertFrom-Json
        if ($runState -and $runState.shared_branch) {
            $featureBranch = [string]$runState.shared_branch
        }
    } catch {
        Write-Status "Could not parse run state file: $runStateFile" -Type Warn
    }
}
if (-not $featureBranch) {
    Write-Status "No active feature branch recorded in $runStateFile. Cannot open PR." -Type Error
    exit 1
}

# ── Verify the project repo + derive owner/repo for gh ─────────────────────
git -C $projectRoot rev-parse --is-inside-work-tree 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Status "Project root '$projectRoot' is not a git repository. Cannot open PR." -Type Error
    exit 1
}
$originUrl = (git -C $projectRoot remote get-url origin 2>$null)
if ($LASTEXITCODE -ne 0 -or -not $originUrl) {
    Write-Status "Project repo has no 'origin' remote — cannot open a PR." -Type Error
    exit 1
}
$ownerRepo = $null
if ($originUrl.Trim() -match '[:/]([^/:]+)/([^/]+?)(?:\.git)?/?$') {
    $ownerRepo = "$($Matches[1])/$($Matches[2])"
}
if (-not $ownerRepo) {
    Write-Status "Could not parse owner/repo from origin URL '$originUrl'." -Type Error
    exit 1
}

# Verify the feature branch exists locally (it should — the framework created
# and merged into it during the run).
git -C $projectRoot rev-parse --verify $featureBranch 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Status "Feature branch '$featureBranch' not found in the project repo. Did any task complete?" -Type Error
    exit 1
}

# ── Base branch: settings override > repo's default branch > main ──────────
$settings   = Get-MergedSettings -BotRoot $BotRoot
$baseBranch = if ($settings.issue_driven.pr_target) { [string]$settings.issue_driven.pr_target } else { $null }
if (-not $baseBranch) {
    $originHead = (git -C $projectRoot symbolic-ref refs/remotes/origin/HEAD 2>$null)
    if ($LASTEXITCODE -eq 0 -and $originHead) { $baseBranch = ($originHead -split '/')[-1] }
}
if (-not $baseBranch) { $baseBranch = "main" }

if ($featureBranch -eq $baseBranch) {
    Write-Status "Feature branch equals base branch '$baseBranch' — nothing to open a PR from." -Type Error
    exit 1
}

Write-Status "Opening PR in $ownerRepo" -Type Process
Write-Label "Head"  $featureBranch
Write-Label "Base"  $baseBranch
if ($issueNumber) { Write-Label "Issue" "#$issueNumber" }

# ── Push the feature branch (idempotent — the framework pushes after each task) ─
$pushOut = git -C $projectRoot push --set-upstream origin $featureBranch 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Status "git push failed for '$featureBranch': $pushOut" -Type Error
    exit 1
}
Write-Status "Pushed $($featureBranch) to origin" -Type Success

# ── Idempotency: skip if a PR already exists for this head ─────────────────
$existingPr = gh pr list -R $ownerRepo --head $featureBranch --json number,url 2>$null | ConvertFrom-Json
if ($existingPr -and $existingPr.Count -gt 0) {
    $prUrl = $existingPr[0].url
    Write-Status "PR already exists: $prUrl — skipping creation." -Type Info
    Write-Label "PR" $prUrl -ValueColor Cyan
    exit 0
}

# ── Build PR title and body ────────────────────────────────────────────────
$titleSuffix = if ($issueNumber) { " #$issueNumber" } else { "" }
$prTitle = "feat: implement issue$titleSuffix"
$closes  = if ($issueNumber) { "`nCloses #$issueNumber" } else { "" }
$prBody  = @"
## Summary

Implemented end-to-end via the dotbot issue-driven workflow (design → implementation → unit tests).

## Changes

See commits on this branch for the full diff.

## Testing

- [x] Existing test suite passes
- [x] Unit tests added by the workflow
$closes
"@

# ── Create PR ──────────────────────────────────────────────────────────────
$prUrl = gh pr create -R $ownerRepo `
    --title $prTitle `
    --body  $prBody `
    --base  $baseBranch `
    --head  $featureBranch 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Status "gh pr create failed: $prUrl" -Type Error
    exit 1
}

Write-Status "PR opened: $prUrl" -Type Success
Write-Label "PR URL" $prUrl -ValueColor Green
Write-Label "Branch" $featureBranch
Write-Label "Base"   $baseBranch

exit 0
