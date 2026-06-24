<#
.SYNOPSIS
    DR Failback — Disable CUS, Resync ANF, Re-enable EU2.

.DESCRIPTION
    Orchestrates the 4-step ANF DR failback workflow.
    Run this ONLY after the application team confirms DR testing is complete.

      Step 1  Disable CUS  : Take CUS DR DFS target offline (auto-detected).
      Step 2  Resync ANF   : Re-establish CRR replication (EU2 as source).
                             *** ALL DATA WRITTEN TO DR VOLUME DURING TEST WILL BE LOST ***
      Step 3  Enable EU2   : Bring EU2 source DFS target back online (Failback auto-detected).
      Step 4  Verify       : Confirm DFS and ANF are back to steady state.

.PARAMETER Environment
    Target environment: 'Production' (default) or 'Test'.

.PARAMETER Force
    Suppresses all confirmation prompts (passes -Force to ANF replication script).

.EXAMPLE
    .\Invoke-DR-Failback.ps1 -Environment Production
    .\Invoke-DR-Failback.ps1 -Environment Test -Force
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
$ScriptDir  = $PSScriptRoot
$DFSScript  = Join-Path $ScriptDir 'Manage-DFSPath.ps1'
$ANFScript  = Join-Path $ScriptDir 'Manage-ANFReplication.ps1'
$ConfigFile = Join-Path $ScriptDir 'ANF_DR_Config.csv'
$LogDir     = Join-Path $ScriptDir 'Logs'
$Timestamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$LogFile    = Join-Path $LogDir "DR-Failback-${Environment}-${Timestamp}.log"

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }

# ─── Logging ─────────────────────────────────────────────────────────────────
function Write-LogMessage {
    param([string]$Level, [string]$Message)
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    Write-Information $line -InformationAction Continue
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
        $output | ForEach-Object { Write-Information "    $($_.ToString())" -InformationAction Continue }
        Write-LogMessage 'ERROR' "STEP $Step FAILED (exit code $exitCode). Failback aborted. See log: $LogFile"
        exit 1
    }

    # Surface only WARN lines to console (errors already handled above)
    $output | Where-Object { $_ -match '\[WARN\]' } | ForEach-Object {
        Write-Information "    $($_.ToString())" -InformationAction Continue
    }

    Write-LogMessage 'SUCCESS' "Step $Step complete."
}

# ─── Read CSV ────────────────────────────────────────────────────────────────
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

Write-Banner "ANF DR — FAILBACK PHASE 2  |  Environment: $Environment"
Write-LogMessage 'INFO' "Log file : $LogFile"
Write-LogMessage 'INFO' "Started  : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

$config     = Get-Config
$sourceUNC  = $config[0].SourceTarget   # e.g. \\anf-9434.gmo.tld\eu2-dr-test
$drUNC      = $config[0].DRTarget       # e.g. \\anf-63d0.gmo.tld\eu2-dr-test

Write-LogMessage 'INFO' ''
Write-LogMessage 'INFO' "DFS Folder   : $($config[0].DFSFolderPath)"
Write-LogMessage 'INFO' "Source (EU2) : $sourceUNC"
Write-LogMessage 'INFO' "DR (CUS)     : $drUNC"
Write-LogMessage 'WARN' ''
Write-LogMessage 'WARN' "*** WARNING: Resyncing replication will DISCARD all data"
Write-LogMessage 'WARN' "    written to the DR volume during the test period. ***"
Write-LogMessage 'WARN' "    Ensure the app team has completed testing before continuing."
Write-LogMessage 'WARN' ''

if (-not $Force) {
    $confirm = Read-Host "Type 'yes' to confirm app team testing is COMPLETE and proceed with failback"
    if ($confirm -ne 'yes') {
        Write-LogMessage 'INFO' "Failback cancelled by user."
        exit 0
    }
}

# ─── Step 1: Disable CUS DR target ───────────────────────────────────────────
Invoke-Step -Step 1 -Description 'Disable CUS DR DFS target (auto-detected)' `
    -ScriptPath $DFSScript `
    -Arguments @('-Action', 'Disable', '-Environment', $Environment)

# ─── Step 2: Resync ANF replication ──────────────────────────────────────────
$anfResyncArgs = @('-Action', 'ResyncReplication', '-Environment', $Environment)
if ($Force) { $anfResyncArgs += '-Force' }

Invoke-Step -Step 2 -Description 'Resync ANF CRR replication (DR volume → read-only replica)' `
    -ScriptPath $ANFScript `
    -Arguments $anfResyncArgs

# ─── Step 3: Re-enable EU2 source ────────────────────────────────────────────
Invoke-Step -Step 3 -Description 'Re-enable EU2 source DFS target (auto-detect: Failback → EU2)' `
    -ScriptPath $DFSScript `
    -Arguments @('-Action', 'Enable', '-Environment', $Environment)

# ─── Step 4: Final verification ──────────────────────────────────────────────
Write-StepBanner -Step 4 -Description 'Final verification — DFS & ANF steady state'

$allPassed = $true

# Collect DFS status silently (full output to log)
$dfsRaw = pwsh -NoProfile -Command "& '$DFSScript' -Action 'GetStatus' -Environment '$Environment'" 2>&1
$dfsRaw | ForEach-Object { Add-Content -Path $LogFile -Value "    $($_.ToString())" }

# Collect ANF status silently (full output to log)
$anfRaw = pwsh -NoProfile -Command "& '$ANFScript' -Action 'GetStatus' -Environment '$Environment'" 2>&1
$anfRaw | ForEach-Object { Add-Content -Path $LogFile -Value "    $($_.ToString())" }

# ── DFS Summary ───────────────────────────────────────────────────────────────
Write-Information '' -InformationAction Continue
Write-Information '  DFS Target Status' -InformationAction Continue
Write-Information "  $('─' * 72)" -InformationAction Continue

foreach ($row in $config) {
    $targets = @(
        @{ UNC = $row.SourceTarget; Role = 'EU2 Source'; Expected = 'Online'  },
        @{ UNC = $row.DRTarget;     Role = 'CUS DR    '; Expected = 'Offline' }
    )
    foreach ($t in $targets) {
        $matchLine = $dfsRaw | Where-Object { $_ -match [regex]::Escape($t.UNC) -and $_ -match '(Online|Offline)' } | Select-Object -First 1
        $state     = if ($matchLine -match '(Online|Offline)') { $matches[1] } else { 'Unknown' }
        $ok        = ($state -eq $t.Expected)
        if (-not $ok) { $allPassed = $false }
        $symbol    = if ($ok) { '[v]' } else { '[X]' }
        $suffix    = if (-not $ok) { "  (expected: $($t.Expected))" } else { '' }
        Write-Information ("  {0} {1,-12} {2,-46} {3}{4}" -f $symbol, $t.Role, $t.UNC, $state, $suffix) -InformationAction Continue
        Add-Content -Path $LogFile -Value "  $symbol $($t.Role) $($t.UNC) $state$suffix"
    }
}

# ── ANF Replication Summary ───────────────────────────────────────────────────
Write-Information '' -InformationAction Continue
Write-Information '  ANF Replication Status' -InformationAction Continue
Write-Information "  $('─' * 72)" -InformationAction Continue

$volNameLines   = @($anfRaw | Where-Object { $_ -match 'Processing volume:\s*(.+)' })
$stateRawLines  = @($anfRaw | Where-Object { $_ -match 'MirrorState=' })
$summaryLines   = @($anfRaw | Where-Object { $_ -match '^\s+(True|False)\s+\w+\s+(Mirrored|Broken|Resyncing)' })

for ($i = 0; $i -lt $volNameLines.Count; $i++) {
    $volName     = if ($volNameLines[$i]  -match 'Processing volume:\s*(.+)')  { $matches[1].Trim() } else { 'Unknown' }
    $mirrorState = if ($i -lt $stateRawLines.Count  -and $stateRawLines[$i]  -match 'MirrorState=(\w+)')   { $matches[1] } else { 'Unknown' }
    $relationship= if ($i -lt $stateRawLines.Count  -and $stateRawLines[$i]  -match 'Relationship=(\w+)') { $matches[1] } else { 'Unknown' }
    $healthy     = if ($i -lt $summaryLines.Count    -and $summaryLines[$i]   -match '^\s+(True|False)')   { $matches[1] } else { 'Unknown' }

    $ok     = ($mirrorState -eq 'Mirrored' -and $healthy -eq 'True')
    if (-not $ok) { $allPassed = $false }
    $symbol = if ($ok) { '[v]' } else { '[X]' }
    $detail = "MirrorState=$mirrorState  Relationship=$relationship  Healthy=$healthy"
    $suffix = if (-not $ok) { '  (expected: Mirrored / True)' } else { '' }
    Write-Information ("  {0} Volume: {1,-30} {2}{3}" -f $symbol, $volName, $detail, $suffix) -InformationAction Continue
    Add-Content -Path $LogFile -Value "  $symbol Volume: $volName $detail$suffix"
}

# ─── Done ────────────────────────────────────────────────────────────────────
Write-LogMessage 'INFO' ''
if ($allPassed) {
    Write-Banner "FAILBACK COMPLETE — EU2 IS BACK IN SERVICE"
    Write-Information "  [v] All checks passed. System is back to steady state." -InformationAction Continue
} else {
    Write-Banner "FAILBACK COMPLETE — BUT SOME CHECKS FAILED"
    Write-Information "  [X] One or more checks failed. Review log: $LogFile" -InformationAction Continue
}
Write-LogMessage 'INFO' ''
Write-LogMessage 'INFO' "  EU2 Source (online)     : $sourceUNC"
Write-LogMessage 'INFO' "  CUS DR (offline/mirror) : $drUNC"
Write-LogMessage 'INFO' ''
Write-LogMessage 'SUCCESS' "Log file: $LogFile"
Write-LogMessage 'INFO' "Finished : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
