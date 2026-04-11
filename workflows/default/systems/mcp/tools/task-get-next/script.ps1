# Import task index module
$indexModule = Join-Path $global:DotbotProjectRoot ".bot\systems\mcp\modules\TaskIndexCache.psm1"
if (-not (Get-Module TaskIndexCache)) {
    Import-Module $indexModule -Force
}

# Import task store (for Move-TaskState, used when skipping tasks whose condition is unmet)
$taskStoreModule = Join-Path $global:DotbotProjectRoot ".bot\systems\mcp\modules\TaskStore.psm1"
if (-not (Get-Module TaskStore)) {
    Import-Module $taskStoreModule -Force
}

# Dot-source workflow-manifest.ps1 to get Test-ManifestCondition.
# NOTE: matches the existing project convention (also used by Invoke-KickstartProcess.ps1,
# ProductAPI.psm1, and ui/server.ps1). Pulls every function from workflow-manifest.ps1 into
# scope, not just Test-ManifestCondition. TODO: extract Test-ManifestCondition into its own
# .psm1 with Export-ModuleMember to shrink the imported surface area.
$runtimeManifest = Join-Path $global:DotbotProjectRoot ".bot\systems\runtime\modules\workflow-manifest.ps1"
if ((Test-Path $runtimeManifest) -and -not (Get-Command Test-ManifestCondition -ErrorAction SilentlyContinue)) {
    . $runtimeManifest
}

# Fail loudly if Test-ManifestCondition is still unavailable. A silent fallback here would
# reintroduce issue #226 (frozen-at-creation conditions) without any visible signal.
# We use [Console]::Error.WriteLine (matching dotbot-mcp.ps1:103) rather than Write-BotLog
# because this script is dot-sourced during MCP tool discovery; if DotBotLog initialization
# was skipped (missing module / failed import), calling Write-BotLog here would throw and
# prevent task-get-next from registering at all.
if (-not (Get-Command Test-ManifestCondition -ErrorAction SilentlyContinue)) {
    [Console]::Error.WriteLine("WARN: [task-get-next] Test-ManifestCondition not available after dot-sourcing '$runtimeManifest' - runtime condition checks DISABLED. Tasks with conditions will not be re-evaluated. This typically means workflow-manifest.ps1 is missing or out of date - re-run 'pwsh install.ps1' or 'dotbot init'.")
}

# Initialize index on first use
$tasksBaseDir = Join-Path $global:DotbotProjectRoot ".bot\workspace\tasks"
Initialize-TaskIndex -TasksBaseDir $tasksBaseDir

function Invoke-TaskGetNext {
    param(
        [hashtable]$Arguments
    )

    $verbose = $Arguments['verbose'] -eq $true
    $preferAnalysed = $Arguments['prefer_analysed']
    $workflowFilter = $Arguments['workflow_filter']
    
    # Default to preferring analysed tasks (can be overridden)
    if ($null -eq $preferAnalysed) {
        $preferAnalysed = $true
    }

    Write-BotLog -Level Debug -Message "[task-get-next] Using cached task index (prefer_analysed: $preferAnalysed)"

    $nextTask = $null
    $taskStatus = 'todo'
    $blockedCount = 0
    $conditionSkipCount = 0
    $moveFailures = @()

    # Priority order:
    # 1. Analysed tasks (ready for implementation, already pre-processed)
    # 2. Todo tasks (need analysis first, or legacy mode)
    #
    # Task `condition` fields are re-evaluated here (at selection time) rather than
    # when the task was created. Dependencies guarantee ordering, so by the time we
    # consider a task its prerequisites have already run; if its condition is still
    # unmet we permanently skip it and look for the next eligible task.
    $maxIterations = 50
    for ($iter = 0; $iter -lt $maxIterations; $iter++) {
        $candidate = $null
        $candidateStatus = 'todo'

        if ($preferAnalysed) {
            $analysedResult = Get-NextAnalysedTask -WorkflowFilter $workflowFilter
            # Track the highest blocked count seen across iterations so that after
            # we skip condition-unmet tasks the "no tasks available" message still
            # reports the true number of analysed tasks blocked by dependencies.
            if ($analysedResult.BlockedCount -gt $blockedCount) {
                $blockedCount = $analysedResult.BlockedCount
            }
            if ($analysedResult.Task) {
                $candidate = $analysedResult.Task
                $candidateStatus = 'analysed'
                Write-BotLog -Level Debug -Message "[task-get-next] Found analysed task: $($candidate.id) ($($analysedResult.BlockedCount) blocked by dependencies)"
            } elseif ($analysedResult.BlockedCount -gt 0) {
                Write-BotLog -Level Debug -Message "[task-get-next] All $($analysedResult.BlockedCount) analysed task(s) blocked by unmet dependencies"
            }
        }

        # Fallback:
        # - prefer_analysed = true  -> try analysed first, then todo
        # - prefer_analysed = false -> todo only (used by analysis phase)
        if (-not $candidate) {
            $todoCandidate = Get-NextTask -WorkflowFilter $workflowFilter
            if ($todoCandidate) {
                $candidate = $todoCandidate
                $candidateStatus = 'todo'
            }
        }

        if (-not $candidate) { break }

        # Runtime condition check — re-evaluate against current filesystem state.
        # Test-ManifestCondition availability is asserted at script load above; if it's
        # missing here we deliberately let PowerShell raise rather than silently skipping
        # the check (which would resurrect issue #226).
        if ($candidate.condition) {
            $conditionMet = Test-ManifestCondition -ProjectRoot $global:DotbotProjectRoot -Condition $candidate.condition
            if (-not $conditionMet) {
                $conditionText = if ($candidate.condition -is [array]) { ($candidate.condition -join ', ') } else { "$($candidate.condition)" }
                Write-BotLog -Level Info -Message "[task-get-next] Skipped task '$($candidate.name)' ($($candidate.id)): condition not met ($conditionText)"
                try {
                    Move-TaskState -TaskId $candidate.id `
                        -FromStates @($candidateStatus) `
                        -ToState 'skipped' `
                        -Updates @{
                            skip_reason = 'condition-not-met'
                            skip_detail = "Condition not met at runtime: $conditionText"
                        } | Out-Null
                } catch {
                    Write-BotLog -Level Warn -Message "[task-get-next] Failed to move task $($candidate.id) to skipped" -Exception $_
                    # Record for the caller so a stuck task doesn't masquerade as an
                    # empty queue — the returned status message will flag it.
                    $moveFailures += "$($candidate.id) ($($candidate.name))"
                    # Avoid infinite loop if the move fails — return no task rather than re-picking the same one.
                    break
                }
                $conditionSkipCount++
                # TODO: incrementalise. Update-TaskIndex rescans the entire tasks tree
                # on every skip (O(N·skips)). Acceptable under the 50-iteration cap and
                # typical queue sizes, but a targeted remove/move helper on the index
                # would be cheaper. Tracked alongside the TaskIndexCache refactor.
                Update-TaskIndex
                continue
            }
        }

        $nextTask = $candidate
        $taskStatus = $candidateStatus
        break
    }

    if ($iter -ge $maxIterations) {
        Write-BotLog -Level Warn -Message "[task-get-next] Hit maxIterations cap ($maxIterations) while skipping tasks with unmet conditions; aborting selection. This usually indicates a stuck task in the queue or a Move-TaskState failure — inspect .bot/workspace/tasks/ for orphans."
    }

    $index = Get-TaskIndex

    if (-not $nextTask) {
        # Check if there are tasks in other states that might explain why nothing is available
        $analysingCount = $index.Analysing.Count
        $needsInputCount = $index.NeedsInput.Count

        $statusMessage = "No pending tasks available."
        if ($blockedCount -gt 0) {
            $statusMessage += " $blockedCount analysed task(s) blocked by unmet dependencies."
        }
        if ($analysingCount -gt 0) {
            $statusMessage += " $analysingCount task(s) being analysed."
        }
        if ($needsInputCount -gt 0) {
            $statusMessage += " $needsInputCount task(s) waiting for input."
        }
        if ($conditionSkipCount -gt 0) {
            $statusMessage += " $conditionSkipCount task(s) skipped (condition not met)."
        }
        if ($moveFailures.Count -gt 0) {
            $statusMessage += " WARNING: $($moveFailures.Count) task(s) stuck (Move-TaskState failed): $($moveFailures -join ', '). Inspect logs and .bot/workspace/tasks/."
        }

        Write-BotLog -Level Debug -Message "[task-get-next] No eligible tasks found"
        return @{
            success = $true
            task = $null
            message = $statusMessage
            analysing_count = $analysingCount
            needs_input_count = $needsInputCount
            blocked_count = $blockedCount
            condition_skip_count = $conditionSkipCount
            move_failures = $moveFailures
        }
    }

    Write-BotLog -Level Debug -Message "[task-get-next] Selected task: $($nextTask.id) - $($nextTask.name) (Priority: $($nextTask.priority), Status: $taskStatus)"

    # Return the highest priority task
    if ($verbose) {
        $taskObj = @{
            id = $nextTask.id
            name = $nextTask.name
            status = $taskStatus
            priority = $nextTask.priority
            effort = $nextTask.effort
            category = $nextTask.category
            description = $nextTask.description
            dependencies = $nextTask.dependencies
            acceptance_criteria = $nextTask.acceptance_criteria
            steps = $nextTask.steps
            applicable_agents = $nextTask.applicable_agents
            applicable_standards = $nextTask.applicable_standards
            file_path = $nextTask.file_path
            needs_interview = $nextTask.needs_interview
            questions_resolved = $nextTask.questions_resolved
            working_dir = $nextTask.working_dir
            external_repo = $nextTask.external_repo
            research_prompt = $nextTask.research_prompt
            type = $nextTask.type
            script_path = $nextTask.script_path
            mcp_tool = $nextTask.mcp_tool
            mcp_args = $nextTask.mcp_args
            skip_analysis = $nextTask.skip_analysis
            skip_worktree = $nextTask.skip_worktree
            workflow = $nextTask.workflow
            model = $nextTask.model
        }
    } else {
        $taskObj = @{
            id = $nextTask.id
            name = $nextTask.name
            status = $taskStatus
            priority = $nextTask.priority
            effort = $nextTask.effort
            category = $nextTask.category
            type = $nextTask.type
            script_path = $nextTask.script_path
            mcp_tool = $nextTask.mcp_tool
            mcp_args = $nextTask.mcp_args
            workflow = $nextTask.workflow
            model = $nextTask.model
        }
    }

    $sourceLabel = if ($taskStatus -eq 'analysed') { 'analysed (ready)' } else { 'todo (needs analysis)' }
    
    return @{
        success = $true
        task = $taskObj
        message = "Next task to work on: $($nextTask.name) (Priority: $($nextTask.priority), Effort: $($nextTask.effort), Source: $sourceLabel)"
    }
}
