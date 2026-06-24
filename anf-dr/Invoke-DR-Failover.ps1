<#
.SYNOPSIS
    DR Failover Phase 1 — Disable EU2, Break ANF replication, Enable CUS DR target.

.DESCRIPTION
    Orchestrates Steps 1-4 of the ANF DR workflow:
      Step 1  Pre-check   : Verify current DFS and ANF replication state.
      Step 2  Disable EU2 : Take EU2 source DFS target offline (auto-detected).
      Step 3  Break ANF   : Break CRR replication — DR volume becomes read/write.
      Step 4  Enable CUS  : Bring CUS DR DFS target online so users/apps connect.

    After this script completes, the application team can begin DR testing.
    Run Invoke-DR-Failback.ps1 when testing is complete.

.PARAMETER Environment
    Target environment: 'Production' (default) or 'Test'.

.PARAMETER Force
    Suppresses all confirmation prompts (passes -Force to ANF replication script).

.EXAMPLE
    .\Invoke-DR-Failover.ps1 -Environment Production
    .\Invoke-DR-Failover.ps1 -Environment Test -Force
#>

[CmdletBinding()]
param(
    [ValidateSet('Production', 'Test')]
    [string]$Environment = 'Production',

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─── Paths ───────────────────────────────────────────────────────────────────
$ScriptDir      = $PSScriptRoot
$DFSScript      = Join-Path $ScriptDir 'Manage-DFSPath.ps1'
$ANFScript      = Join-Path $ScriptDir 'Manage-ANFReplication.ps1'
$ConfigFile     = Join-Path $ScriptDir 'ANF_DR_Config.csv'
$LogDir         = Join-Path $ScriptDir 'Logs'
$Timestamp      = Get-Date -Format 'yyyyMMdd-HHmmss'
$LogFile        = Join-Path $LogDir "DR-Failover-${Environment}-${Timestamp}.log"

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }

# ─── Logging ─────────────────────────────────────────────────────────────────
function Write-LogMessage {
    param([string]$Level, [string]$Message)
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    switch ($Level) {
        'SUCCESS' { Write-Information -MessageData $line -InformationAction Continue }
        'ERROR'   { Write-Information -MessageData $line -InformationAction Continue }
        'WARN'    { Write-Information -MessageData $line -InformationAction Continue }
        default   { Write-Information -MessageData $line -InformationAction Continue }
    }
    Add-Content -Path $LogFile -Value $line
}

function Write-Banner {
    param([string]$Text)
    $sep = '=' * 60
    Write-LogMessage 'INFO' $sep
    Write-LogMessage 'INFO' "  $Text"
    Write-LogMessage 'INFO' $sep
}

function Write-StepBanner {
    param([int]$Step, [string]$Description)
    Write-LogMessage 'INFO' ''
    Write-LogMessage 'INFO' ('-' * 60)
    Write-LogMessage 'INFO' "  STEP $Step : $Description"
    Write-LogMessage 'INFO' ('-' * 60)
}

# ─── Step runner ─────────────────────────────────────────────────────────────
# Full sub-script output goes to log file only.
# WARN/ERROR lines are surfaced to console. Full output printed on failure.
function Invoke-Step {
    param(
        [int]     $Step,
        [string]  $Description,
        [string]  $ScriptPath,
        [string[]]$Arguments
    )

    Write-StepBanner -Step $Step -Description $Description

    $argString = ($Arguments | ForEach-Object { if ($_ -match '^-') { $_ } else { "'$_'" } }) -join ' '
    $cmd       = "& '$ScriptPath' $argString"
    $output    = pwsh -NoProfile -Command $cmd 2>&1
    $exitCode  = $LASTEXITCODE

    # Always write full output to log
    $output | ForEach-Object { Add-Content -Path $LogFile -Value "    $($_.ToString())" }

    if ($exitCode -ne 0) {
        # On failure dump full output so user can see why
        $output | ForEach-Object { Write-Information -MessageData "    $($_.ToString())" -InformationAction Continue }
        Write-LogMessage 'ERROR' "STEP $Step FAILED (exit code $exitCode). Failover aborted. See log: $LogFile"
        exit 1
    }

    # Surface only WARN lines to console
    $output | Where-Object { $_ -match '\[WARN\]' } | ForEach-Object {
        Write-Information -MessageData "    $($_.ToString())" -InformationAction Continue
    }

    Write-LogMessage 'SUCCESS' "Step $Step complete."
}

# ─── Read CSV for summary display ────────────────────────────────────────────
function Get-Config {
    $rows = Import-Csv $ConfigFile | Where-Object { $_.Environment -eq $Environment }
    if (-not $rows) {
        Write-LogMessage 'ERROR' "No rows found in config for Environment '$Environment'. Check $ConfigFile"
        exit 1
    }
    return $rows
}

# ═════════════════════════════════════════════════════════════════════════════
#  MAIN
# ═════════════════════════════════════════════════════════════════════════════

Write-Banner "ANF DR — FAILOVER PHASE 1  |  Environment: $Environment"
Write-LogMessage 'INFO' "Log file : $LogFile"
Write-LogMessage 'INFO' "Started  : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

$config = Get-Config
Write-LogMessage 'INFO' ''
Write-LogMessage 'INFO' "DFS Folder   : $($config[0].DFSFolderPath)"
Write-LogMessage 'INFO' "Source (EU2) : $($config[0].SourceTarget)"
Write-LogMessage 'INFO' "DR (CUS)     : $($config[0].DRTarget)"

# ─── Step 1: Pre-check ───────────────────────────────────────────────────────
Invoke-Step -Step 1 -Description 'Pre-check: DFS state' `
    -ScriptPath $DFSScript `
    -Arguments @('-Action', 'GetStatus', '-Environment', $Environment)

Invoke-Step -Step 1 -Description 'Pre-check: ANF replication state' `
    -ScriptPath $ANFScript `
    -Arguments @('-Action', 'GetStatus', '-Environment', $Environment)

# ─── Step 2: Disable EU2 ─────────────────────────────────────────────────────
Invoke-Step -Step 2 -Description 'Disable EU2 source DFS target (auto-detected)' `
    -ScriptPath $DFSScript `
    -Arguments @('-Action', 'Disable', '-Environment', $Environment)

# ─── Step 3: Break ANF replication ───────────────────────────────────────────
$anfBreakArgs = @('-Action', 'BreakReplication', '-Environment', $Environment)
if ($Force) { $anfBreakArgs += '-Force' }

Invoke-Step -Step 3 -Description 'Break ANF CRR replication (DR volume → read/write)' `
    -ScriptPath $ANFScript `
    -Arguments $anfBreakArgs

# ─── Step 4: Enable CUS DR + visual final summary ────────────────────────────
Invoke-Step -Step 4 -Description 'Enable CUS DR DFS target (auto-detect: Failover → CUS)' `
    -ScriptPath $DFSScript `
    -Arguments @('-Action', 'Enable', '-Environment', $Environment)

# Collect post-failover status silently (full output to log)
$dfsRaw = pwsh -NoProfile -Command "& '$DFSScript' -Action 'GetStatus' -Environment '$Environment'" 2>&1
$dfsRaw | ForEach-Object { Add-Content -Path $LogFile -Value "    $($_.ToString())" }

$anfRaw = pwsh -NoProfile -Command "& '$ANFScript' -Action 'GetStatus' -Environment '$Environment'" 2>&1
$anfRaw | ForEach-Object { Add-Content -Path $LogFile -Value "    $($_.ToString())" }

$allPassed = $true

# ── DFS Summary ───────────────────────────────────────────────────────────────
Write-Information -MessageData '' -InformationAction Continue
Write-Information -MessageData '  DFS Target Status' -InformationAction Continue
Write-Information -MessageData "  $('─' * 72)" -InformationAction Continue

foreach ($row in $config) {
    $targets = @(
        @{ UNC = $row.SourceTarget; Role = 'EU2 Source'; Expected = 'Offline' },
        @{ UNC = $row.DRTarget;     Role = 'CUS DR    '; Expected = 'Online'  }
    )
    foreach ($t in $targets) {
        $matchLine = $dfsRaw | Where-Object { $_ -match [regex]::Escape($t.UNC) -and $_ -match '(Online|Offline)' } | Select-Object -First 1
        $state     = if ($matchLine -match '(Online|Offline)') { $matches[1] } else { 'Unknown' }
        $ok        = ($state -eq $t.Expected)
        if (-not $ok) { $allPassed = $false }
        $symbol    = if ($ok) { '[v]' } else { '[X]' }
        $suffix    = if (-not $ok) { "  (expected: $($t.Expected))" } else { '' }
        Write-Information -MessageData ("  {0} {1,-12} {2,-46} {3}{4}" -f $symbol, $t.Role, $t.UNC, $state, $suffix) -InformationAction Continue
        Add-Content -Path $LogFile -Value "  $symbol $($t.Role) $($t.UNC) $state$suffix"
    }
}

# ── ANF Replication Summary ───────────────────────────────────────────────────
Write-Information -MessageData '' -InformationAction Continue
Write-Information -MessageData '  ANF Replication Status' -InformationAction Continue
Write-Information -MessageData "  $('─' * 72)" -InformationAction Continue

$volNameLines  = @($anfRaw | Where-Object { $_ -match 'Processing volume:\s*(.+)' })
$stateRawLines = @($anfRaw | Where-Object { $_ -match 'MirrorState=' })
$summaryLines  = @($anfRaw | Where-Object { $_ -match '^\s+(True|False)\s+\w+\s+(Mirrored|Broken|Resyncing)' })

for ($i = 0; $i -lt $volNameLines.Count; $i++) {
    $volName      = if ($volNameLines[$i]  -match 'Processing volume:\s*(.+)')              { $matches[1].Trim() } else { 'Unknown' }
    $mirrorState  = if ($i -lt $stateRawLines.Count -and $stateRawLines[$i]  -match 'MirrorState=(\w+)')   { $matches[1] } else { 'Unknown' }
    $relationship = if ($i -lt $stateRawLines.Count -and $stateRawLines[$i]  -match 'Relationship=(\w+)') { $matches[1] } else { 'Unknown' }
    $healthy      = if ($i -lt $summaryLines.Count  -and $summaryLines[$i]   -match '^\s+(True|False)')    { $matches[1] } else { 'Unknown' }

    # After failover: Broken is the expected/correct state (DR volume is now read/write)
    $ok     = ($mirrorState -eq 'Broken')
    if (-not $ok) { $allPassed = $false }
    $symbol = if ($ok) { '[v]' } else { '[X]' }
    $detail = "MirrorState=$mirrorState  Relationship=$relationship  Healthy=$healthy"
    $suffix = if (-not $ok) { '  (expected: Broken — DR volume should be read/write)' } else { '' }
    Write-Information -MessageData ("  {0} Volume: {1,-30} {2}{3}" -f $symbol, $volName, $detail, $suffix) -InformationAction Continue
    Add-Content -Path $LogFile -Value "  $symbol Volume: $volName $detail$suffix"
}

# ─── Done ────────────────────────────────────────────────────────────────────
Write-LogMessage 'INFO' ''
if ($allPassed) {
    Write-Banner "FAILOVER COMPLETE — APP TEAM CAN BEGIN TESTING"
    Write-Information -MessageData "  [v] All checks passed. DR volume is live and accessible." -InformationAction Continue
} else {
    Write-Banner "FAILOVER COMPLETE — BUT SOME CHECKS FAILED"
    Write-Information -MessageData "  [X] One or more checks failed. Review log: $LogFile" -InformationAction Continue
}
Write-LogMessage 'INFO' ''
Write-LogMessage 'INFO' "  DR Volume (read/write) : $($config[0].DRTarget)"
Write-LogMessage 'INFO' "  EU2 Source (offline)   : $($config[0].SourceTarget)"
Write-LogMessage 'INFO' ''
Write-LogMessage 'INFO' "  When the app team confirms testing is DONE, run:"
Write-LogMessage 'INFO' "    .\Invoke-DR-Failback.ps1 -Environment $Environment"
Write-LogMessage 'INFO' ''
Write-LogMessage 'SUCCESS' "Log file: $LogFile"
Write-LogMessage 'INFO' "Finished : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
