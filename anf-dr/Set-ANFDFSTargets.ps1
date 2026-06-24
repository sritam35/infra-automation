<#
.SYNOPSIS
    Standalone script to enable or disable DFS targets for ANF volumes listed
    in ANF_DR_Config.csv. Completely independent of the DR orchestration scripts.

.DESCRIPTION
    Reads ANF_DR_Config.csv and operates on the DFS targets defined there.
    Use this before a DR event to take all ANF DFS paths offline, or after
    a DR event to bring them back online — regardless of DR state.

    Actions:
      GetStatus  — Show current Online/Offline state of all targets (read-only).
      DisableAll — Disable ALL targets (Source and DR) for the environment.
      EnableAll  — Enable ALL targets (Source and DR) for the environment.

    This script has no awareness of replication state or failover direction.
    It simply sets the DFS targets to the requested state.

.PARAMETER Environment
    The environment to operate on: 'Production' or 'Test'.

.PARAMETER Action
    GetStatus  — Read-only status display.
    DisableAll — Set all matching DFS targets to Offline.
    EnableAll  — Set all matching DFS targets to Online.

.PARAMETER ConfigFile
    Path to the CSV config. Defaults to ANF_DR_Config.csv in the same folder.

.EXAMPLE
    # Check current state:
    .\Set-ANFDFSTargets.ps1 -Environment Production -Action GetStatus

.EXAMPLE
    # Disable ALL ANF DFS targets before DR (preview first with -WhatIf):
    .\Set-ANFDFSTargets.ps1 -Environment Production -Action DisableAll -WhatIf
    .\Set-ANFDFSTargets.ps1 -Environment Production -Action DisableAll

.EXAMPLE
    # Re-enable ALL ANF DFS targets after DR is complete:
    .\Set-ANFDFSTargets.ps1 -Environment Production -Action EnableAll

.NOTES
    Author    : Storage Team
    CreatedOn : 2026-03-19
    This script is standalone. It does not interact with Invoke-DR-Failover.ps1,
    Invoke-DR-Failback.ps1, or Manage-DFSPath.ps1 in any way.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('Production', 'Test')]
    [string]$Environment,

    [Parameter(Mandatory = $false)]
    [ValidateSet('GetStatus', 'DisableAll', 'EnableAll')]
    [string]$Action,

    [string]$ConfigFile = (Join-Path $PSScriptRoot 'ANF_DFS_Targets.csv'),

    [System.Management.Automation.PSCredential]$Credential,

    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─── Help ────────────────────────────────────────────────────────────────────
function Show-Help {
    $w = 70
    Write-Host ''
    Write-Host ('=' * $w) -ForegroundColor Cyan
    Write-Host '  Set-ANFDFSTargets.ps1  |  ANF DFS Bulk Target Manager' -ForegroundColor Cyan
    Write-Host ('=' * $w) -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'SYNOPSIS' -ForegroundColor Yellow
    Write-Host '  Enable or disable ALL DFS targets listed in ANF_DFS_Targets.csv for a'
    Write-Host '  given environment. Completely independent of the DR orchestration scripts.'
    Write-Host '  Use this as a pre/post DR safety step to bulk-control DFS target state.'
    Write-Host ''
    Write-Host 'SYNTAX' -ForegroundColor Yellow
    Write-Host '  .\Set-ANFDFSTargets.ps1 -Environment <Production|Test>'
    Write-Host '                          -Action <GetStatus|DisableAll|EnableAll>'
    Write-Host '                         [-ConfigFile <path>]'
    Write-Host '                         [-WhatIf]'
    Write-Host '                         [-Help]'
    Write-Host ''
    Write-Host 'PARAMETERS' -ForegroundColor Yellow
    Write-Host '  -Environment   ' -ForegroundColor Green -NoNewline; Write-Host 'Required. Production or Test'
    Write-Host '  -Action        ' -ForegroundColor Green -NoNewline; Write-Host 'Required. One of:'
    Write-Host '                   GetStatus  — Read-only. Shows current Online/Offline state of'
    Write-Host '                                all Source and DR targets. No credential needed.'
    Write-Host '                   DisableAll — Sets all targets in the CSV to Offline.'
    Write-Host '                                Runs as stored DFS admin credential.'
    Write-Host '                   EnableAll  — Sets all targets in the CSV to Online.'
    Write-Host '                                Runs as stored DFS admin credential.'
    Write-Host '  -ConfigFile    ' -ForegroundColor Green -NoNewline; Write-Host 'Optional. Path to CSV. Default: ANF_DFS_Targets.csv'
    Write-Host '                   CSV columns: Environment, DFSFolderPath, SourceTarget, DRTarget'
    Write-Host '  -WhatIf        ' -ForegroundColor Green -NoNewline; Write-Host 'Preview which targets would be changed. No changes made.'
    Write-Host '  -Help          ' -ForegroundColor Green -NoNewline; Write-Host 'Show this help.'
    Write-Host ''
    Write-Host 'CREDENTIAL' -ForegroundColor Yellow
    Write-Host '  Enable/Disable actions auto-load from ~\.gmo_admin_cred.xml.'
    Write-Host '  Create once with:'
    Write-Host '    Get-Credential | Export-Clixml -Path "$env:USERPROFILE\.gmo_admin_cred.xml"' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host 'EXAMPLES' -ForegroundColor Yellow
    Write-Host '  # Check current state:' -ForegroundColor DarkGray
    Write-Host '  .\Set-ANFDFSTargets.ps1 -Environment Production -Action GetStatus'
    Write-Host ''
    Write-Host '  # Preview what would be disabled (no changes):' -ForegroundColor DarkGray
    Write-Host '  .\Set-ANFDFSTargets.ps1 -Environment Production -Action DisableAll -WhatIf'
    Write-Host ''
    Write-Host '  # Disable all ANF DFS targets before DR:' -ForegroundColor DarkGray
    Write-Host '  .\Set-ANFDFSTargets.ps1 -Environment Production -Action DisableAll'
    Write-Host ''
    Write-Host '  # Re-enable all ANF DFS targets after DR:' -ForegroundColor DarkGray
    Write-Host '  .\Set-ANFDFSTargets.ps1 -Environment Production -Action EnableAll'
    Write-Host ''
    Write-Host 'NOTES' -ForegroundColor Yellow
    Write-Host '  - Edit ANF_DFS_Targets.csv before running — add every volume you want to'
    Write-Host '    control. One row per DFS folder per environment.'
    Write-Host '  - This script does NOT interact with Invoke-DR-Failover/Failback or'
    Write-Host '    Manage-DFSPath.ps1 in any way.'
    Write-Host '  - Logs written to: .\Logs\DFS-Bulk-<Environment>-<timestamp>.log'
    Write-Host ''
    Write-Host ('=' * $w) -ForegroundColor Cyan
    Write-Host ''
}

if ($Help -or (-not $Environment -and -not $Action)) {
    Show-Help
    exit 0
}

if (-not $Environment) { Write-Information '[ERROR] -Environment is required. Use -Help for usage.' -InformationAction Continue; exit 1 }
if (-not $Action) { Write-Information '[ERROR] -Action is required. Use -Help for usage.' -InformationAction Continue; exit 1 }

# ─── Logging ─────────────────────────────────────────────────────────────────
$LogDir = Join-Path $PSScriptRoot 'Logs'
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
$LogFile = Join-Path $LogDir "DFS-Bulk-${Environment}-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

function Write-LogMessage {
    param([string]$Level = 'INFO', [string]$Message)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    switch ($Level) {
        'SUCCESS' { Write-Information -MessageData $line -InformationAction Continue }
        'ERROR' { Write-Information -MessageData $line -InformationAction Continue }
        'WARN' { Write-Information -MessageData $line -InformationAction Continue }
        default { Write-Information -MessageData $line -InformationAction Continue }
    }
    Add-Content -Path $LogFile -Value $line
}

# ─── Load config ─────────────────────────────────────────────────────────────
if (-not (Test-Path $ConfigFile)) {
    Write-LogMessage -Level 'ERROR' -Message "Config file not found: $ConfigFile"
    exit 1
}
$rows = Import-Csv $ConfigFile | Where-Object { $_.Environment -eq $Environment }
if (-not $rows) {
    Write-LogMessage -Level 'ERROR' -Message "No rows found for Environment '$Environment' in $ConfigFile"
    exit 1
}

# Build flat list of all unique (Folder, Target) pairs
$allTargets = foreach ($row in $rows) {
    [PSCustomObject]@{ Folder = $row.DFSFolderPath; TargetPath = $row.SourceTarget; Role = 'Source' }
    [PSCustomObject]@{ Folder = $row.DFSFolderPath; TargetPath = $row.DRTarget; Role = 'DR' }
}

# ─── Credential (not needed for GetStatus) ───────────────────────────────────
$credFile = Join-Path $env:USERPROFILE '.gmo_admin_cred.xml'
if ($Action -ne 'GetStatus' -and -not $Credential) {
    if (Test-Path $credFile) {
        $Credential = Import-Clixml -Path $credFile
        Write-LogMessage -Message "Loaded stored credential: $($Credential.UserName)"
    } else {
        Write-LogMessage -Level 'WARN' -Message "No stored credential found at '$credFile'. Prompting..."
        $Credential = Get-Credential -Message 'Enter DFS admin credentials'
    }
}

# ─── Header ──────────────────────────────────────────────────────────────────
Write-LogMessage -Message ('=' * 68)
Write-LogMessage -Message "  ANF DFS Bulk Target Manager  |  Environment: $Environment"
Write-LogMessage -Message ('=' * 68)
Write-LogMessage -Message "Action      : $Action"
Write-LogMessage -Message "Config      : $ConfigFile"
Write-LogMessage -Message "Targets     : $($allTargets.Count) ($(($rows | Measure-Object).Count) volume(s), Source + DR each)"
if ($Credential) { Write-LogMessage -Message "Run As      : $($Credential.UserName)" }
Write-LogMessage -Message "Log         : $LogFile"
if ($WhatIfPreference) { Write-LogMessage -Level 'WARN' -Message '*** WHATIF MODE — no changes will be made ***' }
Write-LogMessage -Message ('=' * 68)

# ─── GetStatus ───────────────────────────────────────────────────────────────
if ($Action -eq 'GetStatus') {
    Write-Information ''
    Write-Information ('  {0,-6} {1,-10} {2,-46} {3}' -f 'State', 'Role', 'Target UNC', 'DFS Folder') -InformationAction Continue
    Write-Information "  $('─' * 72)" -InformationAction Continue

    foreach ($t in $allTargets) {
        try {
            $current = Get-DfsnFolderTarget -Path $t.Folder -TargetPath $t.TargetPath -ErrorAction Stop
            $state = $current.State
        } catch {
            $state = 'Unknown'
        }
        $symbol = if ($state -eq 'Online') { '[v]' } elseif ($state -eq 'Offline') { '[ ]' } else { '[?]' }
        $line = '  {0,-6} {1,-10} {2,-46} {3}' -f $symbol, $t.Role, $t.TargetPath, $t.Folder
        Write-Information $line -InformationAction Continue
        Add-Content -Path $LogFile -Value $line
    }

    Write-LogMessage -Message ''
    Write-LogMessage -Message "Log: $LogFile"
    exit 0
}

# ─── DisableAll / EnableAll ───────────────────────────────────────────────────
$targetState = if ($Action -eq 'EnableAll') { 'Online' } else { 'Offline' }
$ts = Get-Date -Format 'yyyyMMddHHmmss'
$results = [System.Collections.Generic.List[PSCustomObject]]::new()
$anyError = $false

# Get current live state for each target, filter to only those that need changing
$toChange = foreach ($t in $allTargets) {
    try {
        $current = Get-DfsnFolderTarget -Path $t.Folder -TargetPath $t.TargetPath -ErrorAction Stop
        if ($current.State -ne $targetState) {
            [PSCustomObject]@{ Folder = $t.Folder; TargetPath = $t.TargetPath; Role = $t.Role; CurrentState = $current.State }
        } else {
            Write-Log -Message "  Already $targetState — skipping: $($t.TargetPath)"
        }
    } catch {
        Write-Log -Level 'WARN' -Message "  Could not query: $($t.TargetPath) — $_"
    }
}

if (-not $toChange) {
    Write-LogMessage -Level 'WARN' -Message "All targets are already '$targetState'. Nothing to do."
    exit 0
}

Write-LogMessage -Message ''
Write-LogMessage -Message "Will set $($toChange.Count) target(s) → $targetState :"
foreach ($t in $toChange) {
    Write-LogMessage -Message "  $($t.Role.PadRight(8)) $($t.TargetPath)"
}
Write-LogMessage -Message ''

if ($WhatIfPreference) {
    Write-LogMessage -Level 'WARN' -Message 'WhatIf: no changes made.'
    exit 0
}

# Apply changes grouped by folder (one pwsh process per folder)
$byFolder = $toChange | Group-Object -Property Folder

foreach ($group in $byFolder) {
    $folderPath = $group.Name
    $innerScript = Join-Path $LogDir "_inner_$ts.ps1"
    $innerError = Join-Path $LogDir "_error_$ts.txt"

    $lines = @('try {')
    foreach ($t in $group.Group) {
        $lines += "    Set-DfsnFolderTarget -Path '$folderPath' -TargetPath '$($t.TargetPath)' -State $targetState -ErrorAction Stop"
    }
    $lines += '} catch {'
    $lines += "    Set-Content -Path '$innerError' -Value `$_.ToString() -Encoding utf8"
    $lines += '}'
    Set-Content -Path $innerScript -Value ($lines -join "`n") -Encoding utf8

    if ($PSCmdlet.ShouldProcess("$($group.Group.Count) target(s) in '$folderPath'", "Set to $targetState")) {
        Write-LogMessage -Message "Applying changes for folder: $folderPath"
        Start-Process -FilePath 'pwsh' `
            -ArgumentList '-NoProfile', '-NonInteractive', '-File', $innerScript `
            -Credential $Credential -Wait -PassThru -WindowStyle Hidden | Out-Null

        $errContent = if (Test-Path $innerError) { Get-Content $innerError -Raw -ErrorAction SilentlyContinue } else { $null }

        foreach ($t in $group.Group) {
            if ($errContent) {
                Write-LogMessage -Level 'ERROR' -Message "  FAILED: $($t.TargetPath) — $errContent"
                $results.Add([PSCustomObject]@{ Role = $t.Role; TargetPath = $t.TargetPath; OldState = $t.CurrentState; NewState = 'N/A'; Status = 'Failed' })
                $anyError = $true
            } else {
                Write-LogMessage -Level 'SUCCESS' -Message "  OK: $($t.TargetPath) → $targetState"
                $results.Add([PSCustomObject]@{ Role = $t.Role; TargetPath = $t.TargetPath; OldState = $t.CurrentState; NewState = $targetState; Status = 'Success' })
            }
        }
    }
    Remove-Item $innerScript, $innerError -Force -ErrorAction SilentlyContinue
}

# ─── Summary ─────────────────────────────────────────────────────────────────
Write-LogMessage -Message ''
Write-LogMessage -Message ('=' * 68)
Write-LogMessage -Message '  Summary'
Write-LogMessage -Message ('=' * 68)

Write-Output ('  {0,-5} {1,-10} {2,-46} {3}' -f 'St', 'Role', 'Target UNC', 'Result')
Write-Output "  $('─' * 68)"

foreach ($r in $results) {
    $ok = ($r.Status -eq 'Success')
    $symbol = if ($ok) { '[v]' } else { '[X]' }
    $line = '  {0,-5} {1,-10} {2,-46} {3}' -f $symbol, $r.Role, $r.TargetPath, "$($r.OldState) → $($r.NewState)"
    Write-Information $line -InformationAction Continue
    Add-Content -Path $LogFile -Value $line
}

Write-LogMessage -Message ''
if ($anyError) {
    Write-LogMessage -Level 'WARN' -Message "Completed with errors. Review log: $LogFile"
    exit 1
} else {
    Write-LogMessage -Level 'SUCCESS' -Message "All $($results.Count) target(s) successfully set to '$targetState'."
    Write-LogMessage -Message "Log: $LogFile"
    exit 0
}
