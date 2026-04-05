<#
.SYNOPSIS
    Structured logging module for dotbot.

.DESCRIPTION
    Provides centralized, structured JSONL logging with levels (Debug, Info, Warn, Error, Fatal),
    automatic log rotation, and backward-compatible activity log integration.

    Output: .bot/.control/logs/dotbot-{date}.jsonl
    Each line: {ts, level, msg, correlation_id, process_id, task_id, phase, pid, error, stack}

    Info+ events are also written to activity.jsonl for UI oscilloscope backward compat.
#>

# Import PathSanitizer for stripping absolute paths from log messages
# DotBotLog lives at systems/runtime/modules/ — PathSanitizer at systems/mcp/modules/
$script:PathSanitizerPath = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) "systems\mcp\modules\PathSanitizer.psm1"
if (Test-Path $script:PathSanitizerPath) {
    Import-Module $script:PathSanitizerPath -Force
}

#region Module State

$script:LogDir = $null
$script:ControlDir = $null
$script:MinFileLevel = 'Debug'
$script:MinConsoleLevel = 'Info'
$script:RetentionDays = 7
$script:MaxFileSizeMB = 50
$script:Initialized = $false

# Level ordinals — hashtable to avoid PowerShell enum type-cache issues on -Force reimport
$script:LevelOrdinal = @{
    'Debug' = 0
    'Info'  = 1
    'Warn'  = 2
    'Error' = 3
    'Fatal' = 4
}

# Map log levels to activity log type names for backward compat
$script:LevelToActivityType = @{
    'Info'  = 'info'
    'Warn'  = 'warning'
    'Error' = 'error'
    'Fatal' = 'fatal'
}

#endregion

#region Public Functions

function Initialize-DotBotLog {
    <#
    .SYNOPSIS
        Initializes the structured logging system with configuration.
    .PARAMETER LogDir
        Directory for structured JSONL log files (.bot/.control/logs/).
    .PARAMETER MinFileLevel
        Minimum level to write to log files. Default: Debug.
    .PARAMETER MinConsoleLevel
        Minimum level for console output. Default: Info.
    .PARAMETER RetentionDays
        Days to retain log files before rotation deletes them. Default: 7.
    .PARAMETER MaxFileSizeMB
        Maximum size per log file in MB before rollover. Default: 50.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$LogDir,

        [ValidateSet('Debug','Info','Warn','Error','Fatal')]
        [string]$MinFileLevel = 'Debug',

        [ValidateSet('Debug','Info','Warn','Error','Fatal')]
        [string]$MinConsoleLevel = 'Info',

        [int]$RetentionDays = 7,

        [int]$MaxFileSizeMB = 50
    )

    $script:LogDir = $LogDir
    $script:ControlDir = Split-Path -Parent $LogDir
    $script:MinFileLevel = $MinFileLevel
    $script:MinConsoleLevel = $MinConsoleLevel
    $script:RetentionDays = $RetentionDays
    $script:MaxFileSizeMB = $MaxFileSizeMB

    # Create log directory lazily
    if (-not (Test-Path $script:LogDir)) {
        New-Item -Path $script:LogDir -ItemType Directory -Force | Out-Null
    }

    $script:Initialized = $true
}

function Write-BotLog {
    <#
    .SYNOPSIS
        Writes a structured log entry to the JSONL log file.
    .PARAMETER Level
        Log severity: Debug, Info, Warn, Error, Fatal.
    .PARAMETER Message
        The log message.
    .PARAMETER Context
        Optional hashtable of additional context fields merged into the log entry.
    .PARAMETER Exception
        Optional ErrorRecord to include error message and stack trace.
    .PARAMETER ProcessId
        Optional process ID override. Defaults to $env:DOTBOT_PROCESS_ID.
    .PARAMETER CorrelationId
        Optional correlation ID override. Defaults to $env:DOTBOT_CORRELATION_ID.
        Threads through the entire task lifecycle for end-to-end tracing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Debug','Info','Warn','Error','Fatal')]
        [string]$Level,

        [Parameter(Mandatory)]
        [string]$Message,

        [hashtable]$Context,

        [System.Management.Automation.ErrorRecord]$Exception,

        [string]$ProcessId,

        [string]$CorrelationId
    )

    # Auto-initialize if not yet initialized
    if (-not $script:Initialized) {
        $autoControlDir = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) ".control"
        $autoLogDir = Join-Path $autoControlDir "logs"
        Initialize-DotBotLog -LogDir $autoLogDir
    }

    # Check thresholds — skip entirely if below both file and console levels
    $levelOrd = $script:LevelOrdinal[$Level]
    $meetsFileLevel = $levelOrd -ge $script:LevelOrdinal[$script:MinFileLevel]
    $meetsConsoleLevel = $levelOrd -ge $script:LevelOrdinal[$script:MinConsoleLevel]
    if (-not $meetsFileLevel -and -not $meetsConsoleLevel) {
        return
    }

    # Sanitize message (strip absolute paths)
    $sanitizedMessage = if (Get-Command Remove-AbsolutePaths -ErrorAction SilentlyContinue) {
        Remove-AbsolutePaths -Text $Message -ProjectRoot $global:DotbotProjectRoot
    } else {
        $Message
    }

    # Resolve process ID and correlation ID
    $effectiveProcessId = if ($ProcessId) { $ProcessId } else { $env:DOTBOT_PROCESS_ID }
    $effectiveCorrelationId = if ($CorrelationId) { $CorrelationId } else { $env:DOTBOT_CORRELATION_ID }

    # Build structured log entry
    $entry = [ordered]@{
        ts             = (Get-Date).ToUniversalTime().ToString("o")
        level          = $Level
        msg            = $sanitizedMessage
        correlation_id = $effectiveCorrelationId
        process_id     = $effectiveProcessId
        task_id        = $env:DOTBOT_CURRENT_TASK_ID
        phase          = $env:DOTBOT_CURRENT_PHASE
        pid            = $PID
    }

    # Add exception details
    if ($Exception) {
        $entry.error = $Exception.Exception.Message
        $entry.stack = $Exception.ScriptStackTrace
    }

    # Merge context
    if ($Context) {
        foreach ($key in $Context.Keys) {
            if (-not $entry.Contains($key)) {
                $entry[$key] = $Context[$key]
            }
        }
    }

    $jsonLine = $entry | ConvertTo-Json -Compress

    # Write to structured log file (with size-based rollover)
    if ($meetsFileLevel) {
        $logFilePath = Get-CurrentLogFilePath
        Write-JsonlLine -Path $logFilePath -Line $jsonLine
    }

    # Console output gated by console level (Warn+ to stderr via Write-Warning, Debug/Info via Write-Verbose)
    if ($meetsConsoleLevel) {
        $prefix = switch ($Level) {
            'Debug' { "[DBG]"  }
            'Info'  { "[INF]"  }
            'Warn'  { "[WRN]"  }
            'Error' { "[ERR]"  }
            'Fatal' { "[FTL]"  }
        }
        $consoleMsg = "$prefix $sanitizedMessage"
        if ($Exception) { $consoleMsg += " -- $($Exception.Exception.Message)" }
        if ($levelOrd -ge $script:LevelOrdinal['Warn']) {
            Write-Warning $consoleMsg
        } else {
            Write-Verbose $consoleMsg
        }
    }

    # Backward compat: Info+ events also go to activity.jsonl and per-process activity log
    if ($levelOrd -ge $script:LevelOrdinal['Info']) {
        $activityType = if ($Context -and $Context.activity_type) { $Context.activity_type } else { $script:LevelToActivityType[$Level] }
        $effectivePhase = if ($Context -and $Context.phase_override) { $Context.phase_override } elseif ($env:DOTBOT_CURRENT_PHASE) { $env:DOTBOT_CURRENT_PHASE } else { $null }

        $activityEntry = @{
            timestamp      = $entry.ts
            type           = $activityType
            message        = $sanitizedMessage
            correlation_id = $effectiveCorrelationId
            task_id        = $env:DOTBOT_CURRENT_TASK_ID
            phase          = $effectivePhase
        } | ConvertTo-Json -Compress

        # Global activity.jsonl
        $activityPath = Join-Path $script:ControlDir "activity.jsonl"
        Write-JsonlLine -Path $activityPath -Line $activityEntry

        # Per-process activity log
        if ($effectiveProcessId) {
            $processActivityPath = Join-Path $script:ControlDir "processes\$effectiveProcessId.activity.jsonl"
            Write-JsonlLine -Path $processActivityPath -Line $activityEntry
        }
    }
}

function Rotate-DotBotLog {
    <#
    .SYNOPSIS
        Removes structured log files older than the configured retention period.
    #>
    [CmdletBinding()]
    param()

    if (-not $script:Initialized -or -not $script:LogDir -or -not (Test-Path $script:LogDir)) {
        return
    }

    try {
        $cutoff = (Get-Date).AddDays(-$script:RetentionDays)
        Get-ChildItem -Path $script:LogDir -Filter "dotbot-*.jsonl" -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff } |
            ForEach-Object {
                try { Remove-Item $_.FullName -Force } catch { Write-Warning "Log rotation: failed to remove $($_.FullName) - $($_.Exception.Message)" }
            }

        # Also clean legacy diag files in .control
        if ($script:ControlDir -and (Test-Path $script:ControlDir)) {
            Get-ChildItem -Path $script:ControlDir -Filter "diag-*.log" -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -lt $cutoff } |
                ForEach-Object {
                    try { Remove-Item $_.FullName -Force } catch { Write-Warning "Log rotation: failed to remove legacy diag $($_.FullName) - $($_.Exception.Message)" }
                }
        }
    } catch {
        Write-Warning "Log rotation failed: $($_.Exception.Message)"
    }
}

#endregion

#region Private Functions

function Get-CurrentLogFilePath {
    <#
    .SYNOPSIS
        Returns the current log file path, rolling over when max size is exceeded.
    #>
    $dateStamp = Get-Date -Format 'yyyy-MM-dd'
    $baseName = "dotbot-$dateStamp"
    $basePath = Join-Path $script:LogDir "$baseName.jsonl"

    # If no size limit or base file is under limit, use it
    $maxBytes = $script:MaxFileSizeMB * 1MB
    if ($maxBytes -le 0 -or -not (Test-Path $basePath) -or (Get-Item $basePath).Length -lt $maxBytes) {
        return $basePath
    }

    # Find the next available rollover suffix
    for ($i = 1; $i -lt 100; $i++) {
        $rollPath = Join-Path $script:LogDir "$baseName.$i.jsonl"
        if (-not (Test-Path $rollPath) -or (Get-Item $rollPath).Length -lt $maxBytes) {
            return $rollPath
        }
    }

    # Fallback: write to base file anyway
    return $basePath
}

function Write-JsonlLine {
    <#
    .SYNOPSIS
        Appends a single line to a JSONL file with FileStream retry logic.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Line
    )

    # Ensure parent directory exists
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }

    $maxRetries = 3
    $retryBaseMs = 50
    for ($r = 0; $r -lt $maxRetries; $r++) {
        try {
            $fs = [System.IO.FileStream]::new(
                $Path,
                [System.IO.FileMode]::Append,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::ReadWrite
            )
            $sw = [System.IO.StreamWriter]::new($fs, [System.Text.Encoding]::UTF8)
            $sw.WriteLine($Line)
            $sw.Close()
            $fs.Close()
            break
        } catch {
            if ($r -lt ($maxRetries - 1)) {
                Start-Sleep -Milliseconds ($retryBaseMs * ($r + 1))
            }
            # Final retry failure is silently ignored (non-critical logging)
        }
    }
}

#endregion

#region Compatibility Wrappers

function Write-Diag {
    <#
    .SYNOPSIS
        Thin backward-compat wrapper — delegates to Write-BotLog -Level Debug.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [hashtable]$Context,

        [System.Management.Automation.ErrorRecord]$Exception
    )

    Write-BotLog -Level Debug -Message $Message -Context $Context -Exception $Exception
}

#endregion

Export-ModuleMember -Function @('Initialize-DotBotLog', 'Write-BotLog', 'Rotate-DotBotLog', 'Write-Diag')
