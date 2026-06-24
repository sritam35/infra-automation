<#
.SYNOPSIS
    Get current DFS and ANF replication status for all DR volumes in the config.

.DESCRIPTION
    Reads ANF_DR_Config.csv and displays a clear visual dashboard showing:
      - DFS target states (Online/Offline) for each folder
      - Which site is currently serving traffic
      - ANF replication state (Mirrored/Broken/Resyncing) per volume
      - Overall health indicator per environment

    Can be run at any time — read-only, makes no changes.

.PARAMETER Environment
    Filter to a specific environment ('Production' or 'Test').
    If omitted, shows all environments in the CSV.

.EXAMPLE
    .\Get-DR-Status.ps1
    .\Get-DR-Status.ps1 -Environment Test
    .\Get-DR-Status.ps1 -Environment Production
#>

[CmdletBinding()]
param(
    [ValidateSet('Production', 'Test')]
    [string]$Environment
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir  = $PSScriptRoot
$DFSScript  = Join-Path $ScriptDir 'Manage-DFSPath.ps1'
$ANFScript  = Join-Path $ScriptDir 'Manage-ANFReplication.ps1'
$ConfigFile = Join-Path $ScriptDir 'ANF_DR_Config.csv'

# ─── Read config ─────────────────────────────────────────────────────────────
$allRows = Import-Csv $ConfigFile
if ($Environment) {
    $allRows = $allRows | Where-Object { $_.Environment -eq $Environment }
}
if (-not $allRows) {
    Write-Output "No entries found in config$(if ($Environment) { " for Environment '$Environment'" })."
    exit 1
}

$environments = $allRows | Select-Object -ExpandProperty Environment -Unique

# ─── Helpers ─────────────────────────────────────────────────────────────────
function Get-StateColor {
    param([string]$State, [string]$Expected)
    if ($State -eq $Expected)   { return 'Green'  }
    if ($State -eq 'Unknown')   { return 'Yellow' }
    return 'Red'
}

function Get-CheckMark {
    param([string]$State, [string]$Expected)
    if ($State -eq $Expected) { return '[v]' }
    if ($State -eq 'Unknown') { return '[?]' }
    return '[X]'
}

function Write-SectionHeader {
    param([string]$Text)
    $width = 74
    $pad   = [math]::Max(0, ($width - $Text.Length - 2) / 2)
    $line  = ' ' * [math]::Floor($pad) + $Text + ' ' * [math]::Ceiling($pad)
    Write-Output ''
    Write-Output "  $('═' * $width)"
    Write-Output "  $line"
    Write-Output "  $('═' * $width)"
}

# ─── Main ────────────────────────────────────────────────────────────────────
$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

Write-Output ''
Write-Output "  ╔══════════════════════════════════════════════════════════════════════════╗"
Write-Output "  ║           ANF DR STATUS DASHBOARD                                       ║"
Write-Output "  ║           $timestamp                                       ║"
Write-Output "  ╚══════════════════════════════════════════════════════════════════════════╝"

foreach ($env in $environments) {

    $rows = $allRows | Where-Object { $_.Environment -eq $env }

    Write-SectionHeader "Environment: $env"

    # ── Collect DFS status ────────────────────────────────────────────────────
    Write-Output "  Querying DFS status..."
    $dfsRaw = pwsh -NoProfile -Command "& '$DFSScript' -Action 'GetStatus' -Environment '$env'" 2>&1

    # ── Collect ANF status ────────────────────────────────────────────────────
    Write-Output "  Querying ANF replication status..."
    $anfRaw = pwsh -NoProfile -Command "& '$ANFScript' -Action 'GetStatus' -Environment '$env'" 2>&1

    # ─── DFS Section ──────────────────────────────────────────────────────────
    Write-Output ''
    Write-Output "  DFS Namespace Targets"
    Write-Output "  $('─' * 74)"
    Write-Output ("  {0,-5} {1,-12} {2,-48} {3,-10} {4}" -f 'St', 'Role', 'UNC Path', 'State', 'Serving Traffic?')
    Write-Output "  $('─' * 74)"

    $envHealthy = $true

    foreach ($row in $rows) {
        $dfsFolder  = $row.DFSFolderPath
        $targets = @(
            @{ UNC = $row.SourceTarget; Role = 'EU2 Source' },
            @{ UNC = $row.DRTarget;     Role = 'CUS DR'     }
        )

        foreach ($t in $targets) {
            $matchLine = $dfsRaw | Where-Object {
                $_ -match [regex]::Escape($t.UNC) -and $_ -match '(Online|Offline)'
            } | Select-Object -First 1

            $state   = if ($matchLine -match '\b(Online|Offline)\b') { $matches[1] } else { 'Unknown' }
            $serving = if ($state -eq 'Online') { 'YES  <--' } else { 'no' }
            $symbol = switch ($state) {
                'Online'  { '[v]' }
                'Offline' { '[ ]' }
                default   { '[?]' }
            }
            if ($state -eq 'Unknown') { $envHealthy = $false }

            Write-Output ("  {0,-5} {1,-12} {2,-48} {3,-10} {4}" -f `
                $symbol, $t.Role, $t.UNC, $state, $serving)
        }

        # Show which folder this covers
        Write-Output "        DFS Folder: $dfsFolder"
    }

    # ─── ANF Section ──────────────────────────────────────────────────────────
    Write-Output ''
    Write-Output "  ANF Replication"
    Write-Output "  $('─' * 74)"
    Write-Output ("  {0,-5} {1,-28} {2,-14} {3,-14} {4,-8} {5}" -f `
        'St', 'Volume', 'MirrorState', 'Relationship', 'Healthy', 'Note')
    Write-Output "  $('─' * 74)"

    $volNameLines  = @($anfRaw | Where-Object { $_ -match 'Processing volume:\s*(.+)' })
    $stateLines    = @($anfRaw | Where-Object { $_ -match 'MirrorState=' })
    $summaryLines  = @($anfRaw | Where-Object { $_ -match '^\s+(True|False)\s+\w+\s+(Mirrored|Broken|Resyncing|Uninitialized)' })

    if ($volNameLines.Count -eq 0) {
        Write-Output "  [?] Could not retrieve ANF replication status."
        $envHealthy = $false
    }

    for ($i = 0; $i -lt $volNameLines.Count; $i++) {
        $volName      = if ($volNameLines[$i] -match 'Processing volume:\s*(.+)')             { $matches[1].Trim() } else { 'Unknown' }
        $mirrorState  = if ($i -lt $stateLines.Count -and $stateLines[$i] -match 'MirrorState=(\w+)')   { $matches[1] } else { 'Unknown' }
        $relationship = if ($i -lt $stateLines.Count -and $stateLines[$i] -match 'Relationship=(\w+)') { $matches[1] } else { 'Unknown' }
        $healthy      = if ($i -lt $summaryLines.Count -and $summaryLines[$i] -match '^\s+(True|False)') { $matches[1] } else { 'Unknown' }

        $note = switch ($mirrorState) {
            'Mirrored'      { 'Steady state — replicating'   }
            'Broken'        { 'DR active — volume read/write' }
            'Resyncing'     { 'Resync in progress...'         }
            'Uninitialized' { 'Not yet initialised'           }
            default         { ''                              }
        }

        $ok     = ($mirrorState -eq 'Mirrored' -and $healthy -eq 'True')
        $isDR   = ($mirrorState -eq 'Broken')   # broken is valid during DR
        $symbol = if ($ok -or $isDR) { if ($ok) { '[v]' } else { '[!]' } } else { '[X]' }

        if (-not $ok -and -not $isDR) { $envHealthy = $false }

        Write-Output ("  {0,-5} {1,-28} {2,-14} {3,-14} {4,-8} {5}" -f `
            $symbol, $volName, $mirrorState, $relationship, $healthy, $note)
    }

    # ─── Environment summary line ─────────────────────────────────────────────
    Write-Output ''
    if ($envHealthy) {
        Write-Output "  [v] $env — All checks OK"
    } else {
        Write-Output "  [X] $env — One or more items need attention"
    }
}

Write-Output ''
Write-Output "  $('─' * 74)"
Write-Output "  Status as of: $timestamp"
Write-Output ''
