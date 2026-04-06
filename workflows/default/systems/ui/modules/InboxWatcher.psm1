<#
.SYNOPSIS
File system listener that triggers task-creation when new files appear in configured workspace folders.

.DESCRIPTION
Monitors folders defined in settings.default.json under file_listener.watchers.
When a matching file is created or updated, launches a task-creation process
(91-new-tasks.md) with the file path as context so Claude can review the new
document against existing tasks and product docs and create appropriate tasks.

Architecture note: Register-ObjectEvent action blocks run in a restricted PowerShell
event context where module-private function calls fail silently. Following the
NotificationPoller pattern, event handlers only enqueue file paths to a thread-safe
queue; a System.Threading.Timer drains the queue every 2 seconds and does the actual
work (where module functions are fully accessible).
#>

# Module-scope state
$script:Watchers      = @()                                                            # System.IO.FileSystemWatcher instances
$script:PendingEvents = [System.Collections.Concurrent.ConcurrentQueue[object]]::new() # thread-safe event queue; shared with worker runspace
$script:WorkerPS      = $null                                                          # [powershell] instance running the drain loop
$script:BotRoot       = $null
$script:WorkspaceRoot = $null

function Initialize-InboxWatcher {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BotRoot
    )

    $script:BotRoot = $BotRoot
    $script:WorkspaceRoot = Join-Path $BotRoot "workspace"

    # Read file_listener config from settings
    $settingsPath = Join-Path $BotRoot "settings\settings.default.json"
    if (-not (Test-Path $settingsPath)) {
        Write-Verbose "[InboxWatcher] settings.default.json not found, skipping"
        return
    }

    try {
        $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
    } catch {
        Write-Warning "[InboxWatcher] Failed to parse settings.default.json: $_"
        return
    }

    $listenerConfig = $settings.file_listener
    if (-not $listenerConfig -or $listenerConfig.enabled -ne $true) {
        Write-Verbose "[InboxWatcher] File listener disabled or not configured"
        return
    }

    $watcherDefs = @($listenerConfig.watchers)
    if ($watcherDefs.Count -eq 0) {
        Write-Verbose "[InboxWatcher] No watchers configured"
        return
    }

    foreach ($watcherDef in $watcherDefs) {
        $folder = $watcherDef.folder
        if (-not $folder) {
            Write-Warning "[InboxWatcher] Watcher config missing 'folder' field, skipping"
            continue
        }

        $resolvedPath = Join-Path $script:WorkspaceRoot $folder
        if (-not (Test-Path $resolvedPath)) {
            Write-Warning "[InboxWatcher] Watched folder not found, skipping: $resolvedPath"
            continue
        }

        $filter = if ($watcherDef.filter) { $watcherDef.filter } else { '*' }
        $events = if ($watcherDef.events) { @($watcherDef.events) } else { @('created') }

        try {
            $watcher = New-Object System.IO.FileSystemWatcher
            $watcher.Path = $resolvedPath
            $watcher.Filter = $filter
            $watcher.NotifyFilter = [System.IO.NotifyFilters]::LastWrite -bor
                                    [System.IO.NotifyFilters]::FileName -bor
                                    [System.IO.NotifyFilters]::CreationTime
            $watcher.InternalBufferSize = 65536
            $watcher.EnableRaisingEvents = $true

            # Capture queue reference via GetNewClosure() — $script: scope is unavailable in
            # the restricted event runspace, so we must close over a local variable instead.
            $capturedQueue = $script:PendingEvents
            if ('created' -in $events) {
                $createdAction = {
                    $capturedQueue.Enqueue([PSCustomObject]@{
                        FilePath = $Event.SourceEventArgs.FullPath
                        Config   = $Event.MessageData
                    })
                }.GetNewClosure()
                Register-ObjectEvent -InputObject $watcher -EventName Created -MessageData $watcherDef -Action $createdAction | Out-Null
            }

            if ('updated' -in $events) {
                $changedAction = {
                    $capturedQueue.Enqueue([PSCustomObject]@{
                        FilePath = $Event.SourceEventArgs.FullPath
                        Config   = $Event.MessageData
                    })
                }.GetNewClosure()
                Register-ObjectEvent -InputObject $watcher -EventName Changed -MessageData $watcherDef -Action $changedAction | Out-Null
            }

            $script:Watchers += $watcher
            Write-Verbose "[InboxWatcher] Watching: $resolvedPath (filter: $filter, events: $($events -join ', '))"
        } catch {
            Write-Warning "[InboxWatcher] Failed to create watcher for $resolvedPath : $_"
        }
    }

    if ($script:Watchers.Count -gt 0) {
        # Use a dedicated runspace with a sleep loop — avoids the System.Threading.Timer
        # runspace issue where TimerCallback scriptblocks have no PowerShell runspace.
        # The ConcurrentQueue is a reference type and is shared safely across runspaces.
        $workerRunspace = [runspacefactory]::CreateRunspace()
        $workerRunspace.Open()
        $workerRunspace.SessionStateProxy.SetVariable('Queue', $script:PendingEvents)
        $workerRunspace.SessionStateProxy.SetVariable('BotRoot', $script:BotRoot)

        $script:WorkerPS = [powershell]::Create()
        $script:WorkerPS.Runspace = $workerRunspace
        $null = $script:WorkerPS.AddScript({
            $recentlyProcessed = @{}
            while ($true) {
                Start-Sleep -Seconds 2
                $item = $null
                while ($Queue.TryDequeue([ref]$item)) {
                    try {
                        $filePath = $item.FilePath
                        $config   = $item.Config

                        # Skip directories
                        if (Test-Path $filePath -PathType Container) { continue }

                        # Debounce: skip if same file processed within last 5 seconds
                        $now = [DateTime]::UtcNow
                        if ($recentlyProcessed.ContainsKey($filePath)) {
                            if (($now - $recentlyProcessed[$filePath]).TotalSeconds -lt 5) { continue }
                        }
                        $recentlyProcessed[$filePath] = $now

                        # Purge stale debounce entries (older than 60s)
                        $stale = @($recentlyProcessed.Keys | Where-Object {
                            ($now - $recentlyProcessed[$_]).TotalSeconds -gt 60
                        })
                        foreach ($key in $stale) { $recentlyProcessed.Remove($key) }

                        # Build context prompt
                        $fileName    = Split-Path $filePath -Leaf
                        $folderLabel = if ($config.description) { $config.description } else { "watched folder ($($config.folder))" }
                        $contextPrompt = "A new file '$fileName' has been added to $folderLabel (path: $filePath). Read this file using your available tools, review its contents against the existing product documentation and task list, and create any new tasks needed to address the changes, requirements, or decisions it represents."
                        $description = "Review new file: $fileName"

                        # Locate launcher
                        $launcherPath = Join-Path $BotRoot "systems\runtime\launch-process.ps1"
                        if (-not (Test-Path $launcherPath)) { continue }

                        $escapedPrompt = $contextPrompt -replace '"', '\"'
                        $escapedDesc   = $description -replace '"', '\"'
                        $launchArgs = @(
                            "-File", "`"$launcherPath`"",
                            "-Type", "task-creation",
                            "-Prompt", "`"$escapedPrompt`"",
                            "-Description", "`"$escapedDesc`""
                        )

                        $startParams = @{ ArgumentList = $launchArgs }
                        if ($IsWindows) { $startParams.WindowStyle = 'Normal' }
                        Start-Process pwsh @startParams
                    } catch {
                        # Per-item errors are non-fatal
                    }
                }
            }
        })
        $null = $script:WorkerPS.BeginInvoke()
        Write-Verbose "[InboxWatcher] Initialization complete. $($script:Watchers.Count) watcher(s) active"
    }
}


function Stop-InboxWatcher {
    Write-Verbose "[InboxWatcher] Stopping all inbox watchers"

    if ($script:WorkerPS) {
        try {
            $script:WorkerPS.Stop()
            $script:WorkerPS.Runspace.Close()
            $script:WorkerPS.Dispose()
        } catch {}
        $script:WorkerPS = $null
    }

    foreach ($w in $script:Watchers) {
        try {
            $w.EnableRaisingEvents = $false
            $w.Dispose()
        } catch {
            Write-Warning "[InboxWatcher] Error disposing watcher: $_"
        }
    }
    $script:Watchers = @()
    Write-Verbose "[InboxWatcher] All inbox watchers stopped"
}

Export-ModuleMember -Function @(
    'Initialize-InboxWatcher',
    'Stop-InboxWatcher'
)
