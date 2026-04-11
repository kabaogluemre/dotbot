function Test-ManifestCondition {
    <#
    .SYNOPSIS
    Evaluate a gitignore-style path condition against the project root.

    .DESCRIPTION
    Conditions are path patterns resolved from the project root (parent of .bot/).
    - Path present = must exist: ".bot/workspace/product/mission.md"
    - ! prefix = must NOT exist: "!.bot/workspace/product/mission.md"
    - Glob * = directory has matching files: ".git/refs/heads/*"
    - Single string = one condition. Array = AND (all must match).
    - Legacy file_exists: prefix = backward-compat alias (resolves under .bot/).
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ProjectRoot,

        [Parameter()]
        [object]$Condition
    )

    if (-not $Condition) { return $true }

    # Normalize to array
    $rules = if ($Condition -is [array]) { $Condition }
             elseif ($Condition -is [string]) { @($Condition) }
             else { return $true }

    $resolvedRoot = [System.IO.Path]::GetFullPath($ProjectRoot)

    foreach ($rule in $rules) {
        $rule = "$rule".Trim()
        if (-not $rule) { continue }

        # Legacy compat: strip file_exists: prefix -> resolve under .bot/
        if ($rule -match '^file_exists:(.+)$') {
            $rule = ".bot/$($Matches[1])"
        }

        $negate = $rule.StartsWith('!')
        if ($negate) { $rule = $rule.Substring(1) }

        $fullPath = Join-Path $ProjectRoot $rule

        # Path traversal guard: resolved path must stay within project root.
        $resolvedFull = [System.IO.Path]::GetFullPath($fullPath)
        if (-not $resolvedFull.StartsWith($resolvedRoot)) {
            if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) {
                Write-BotLog -Level Warn -Message "[ManifestCondition] Path traversal blocked: '$rule' resolves outside project root."
            }
            return $false
        }

        $exists = if ($rule -match '\*') {
            @(Resolve-Path $fullPath -ErrorAction SilentlyContinue).Count -gt 0
        } else {
            Test-Path $fullPath
        }

        if ($negate -eq $exists) { return $false }
    }

    return $true
}

Export-ModuleMember -Function 'Test-ManifestCondition'
