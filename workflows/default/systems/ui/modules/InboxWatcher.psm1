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
$script:Watchers          = @()                                                            # System.IO.FileSystemWatcher instances
$script:PendingEvents     = [System.Collections.Concurrent.ConcurrentQueue[object]]::new() # thread-safe event queue
$script:ProcessingTimer   = $null                                                          # System.Threading.Timer
$script:RecentlyProcessed = @{}                                                            # filePath → [DateTime] for debounce
$script:BotRoot           = $null
$script:WorkspaceRoot     = $null

function Initialize-InboxWatcher {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BotRoot
    )

    $script:BotRoot = $BotRoot
    $script:WorkspaceRoot = Join-Path $BotRoot "workspace"

    # Read file_listener config from settings
    $settingsPath = Join-Path $BotRoot "defaults\settings.default.json"
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

            # Action blocks only enqueue — no function calls (they fail silently in event context)
            if ('created' -in $events) {
                Register-ObjectEvent -InputObject $watcher -EventName Created -MessageData $watcherDef -Action {
                    $script:PendingEvents.Enqueue([PSCustomObject]@{
                        FilePath = $Event.SourceEventArgs.FullPath
                        Config   = $Event.MessageData
                    })
                } | Out-Null
            }

            if ('updated' -in $events) {
                Register-ObjectEvent -InputObject $watcher -EventName Changed -MessageData $watcherDef -Action {
                    $script:PendingEvents.Enqueue([PSCustomObject]@{
                        FilePath = $Event.SourceEventArgs.FullPath
                        Config   = $Event.MessageData
                    })
                } | Out-Null
            }

            $script:Watchers += $watcher
            Write-Verbose "[InboxWatcher] Watching: $resolvedPath (filter: $filter, events: $($events -join ', '))"
        } catch {
            Write-Warning "[InboxWatcher] Failed to create watcher for $resolvedPath : $_"
        }
    }

    if ($script:Watchers.Count -gt 0) {
        # Timer drains the queue every 2 seconds — timer callbacks CAN call module functions
        $timerCallback = {
            try {
                $item = $null
                while ($script:PendingEvents.TryDequeue([ref]$item)) {
                    Invoke-FileListenerEvent -FilePath $item.FilePath -Config $item.Config
                }
            } catch {
                Write-Verbose "[InboxWatcher] Timer error: $_"
            }
        }
        $script:ProcessingTimer = [System.Threading.Timer]::new($timerCallback, $null, 2000, 2000)
        Write-Verbose "[InboxWatcher] Initialization complete. $($script:Watchers.Count) watcher(s) active"
    }
}

function Invoke-FileListenerEvent {
    param(
        [string]$FilePath,
        [object]$Config
    )

    # Skip directories
    if (Test-Path $FilePath -PathType Container) { return }

    # Debounce: skip if same file was processed within the last 5 seconds
    $now = [DateTime]::UtcNow
    if ($script:RecentlyProcessed.ContainsKey($FilePath)) {
        if (($now - $script:RecentlyProcessed[$FilePath]).TotalSeconds -lt 5) {
            Write-Verbose "[InboxWatcher] Debounced: $FilePath"
            return
        }
    }

    # Mark as processed
    $script:RecentlyProcessed[$FilePath] = $now

    # Purge stale debounce entries (older than 60s)
    $stale = @($script:RecentlyProcessed.Keys | Where-Object {
        ($now - $script:RecentlyProcessed[$_]).TotalSeconds -gt 60
    })
    foreach ($key in $stale) { $script:RecentlyProcessed.Remove($key) }

    # Build context prompt — pass file path so Claude reads it via tools
    $fileName    = Split-Path $FilePath -Leaf
    $folderLabel = if ($Config.description) { $Config.description } else { "watched folder ($($Config.folder))" }
    $contextPrompt = "A new file '$fileName' has been added to $folderLabel (path: $FilePath). Read this file using your available tools, review its contents against the existing product documentation and task list, and create any new tasks needed to address the changes, requirements, or decisions it represents."

    $description = "Review new file: $fileName"

    # Locate launcher
    $launcherPath = Join-Path $script:BotRoot "systems\runtime\launch-process.ps1"
    if (-not (Test-Path $launcherPath)) {
        Write-Warning "[InboxWatcher] Launcher not found: $launcherPath"
        return
    }

    # Build argument list — match the pattern in ProcessAPI.psm1
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

    try {
        Start-Process pwsh @startParams
        Write-Verbose "[InboxWatcher] Triggered task-creation for: $fileName"
    } catch {
        Write-Warning "[InboxWatcher] Failed to launch task-creation for '$fileName': $_"
    }
}

function Stop-InboxWatcher {
    Write-Verbose "[InboxWatcher] Stopping all inbox watchers"

    if ($script:ProcessingTimer) {
        try { $script:ProcessingTimer.Dispose() } catch {}
        $script:ProcessingTimer = $null
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
