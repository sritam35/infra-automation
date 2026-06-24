<#
.SYNOPSIS
    Manage DFS Namespace folder targets for ANF DR failover/failback.
    Get status, enable, or disable DFS folder targets by target path.

.DESCRIPTION
    This script manages DFS namespace folder targets during ANF DR operations.
    It can:
      - Get status of all targets under a DFS folder (site, state, priority)
      - Disable source DFS target paths (before breaking replication)
      - Enable DR target DFS paths (after breaking replication)
      - Disable DR target DFS paths (after DR testing)
      - Enable source DFS target paths (after resync completes)

    GetStatus runs natively with the current user — no credential prompt.
    Enable/Disable run as gmo\admin-username via Invoke-Command to the
    DFS namespace server.

.PARAMETER Action
    The action to perform: 'GetStatus', 'Enable', or 'Disable'

.PARAMETER DFSFolderPath
    The DFS namespace folder path containing the targets.
    Example: "\\corp.example.com\DR\test"

.PARAMETER TargetPaths
    One or more UNC target paths to enable/disable.
    Required for Enable and Disable. Not used for GetStatus.
    Example: @("\\anf-source.corp.example.com\eu2-dr-test", "\\anf-dr.corp.example.com\cus-dr-test")

.PARAMETER Credential
    Credentials to use for Enable/Disable operations.
    Defaults to prompting for gmo\admin-username.
    Not used for GetStatus.

.PARAMETER LogPath
    Path to write the log file. Defaults to script directory\Logs.

.EXAMPLE
    # Get status of all targets
    .\Manage-DFSPath.ps1 -Action GetStatus -DFSFolderPath "\\corp.example.com\TS2\DR_Test"

.EXAMPLE
    # Disable source target before DR failover
    .\Manage-DFSPath.ps1 -Action Disable -DFSFolderPath "\\corp.example.com\DR\test" -TargetPaths "\\anf-source.corp.example.com\eu2-dr-test"

.EXAMPLE
    # Enable DR target after breaking replication
    .\Manage-DFSPath.ps1 -Action Enable -DFSFolderPath "\\corp.example.com\DR\test" -TargetPaths "\\anf-dr.corp.example.com\cus-dr-test"

.EXAMPLE
    # Disable multiple targets at once
    .\Manage-DFSPath.ps1 -Action Disable -DFSFolderPath "\\corp.example.com\prd_eu2\Opr" -TargetPaths @("\\anf-72b8.corp.example.com\eu2-b-prdopr", "\\anf-8dcf.corp.example.com\cus-b-prdopr")

.EXAMPLE
    # Preview changes without applying
    .\Manage-DFSPath.ps1 -Action Disable -DFSFolderPath "\\corp.example.com\DR\test" -TargetPaths "\\anf-source.corp.example.com\eu2-dr-test" -WhatIf

.NOTES
    Author     : Storage Team
    CreatedOn  : 02/20/2026
    UpdatedOn  : 03/03/2026
    Requires   : DFS Namespace PowerShell module (RSAT)
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter(Mandatory = $false)]
    [ValidateSet("GetStatus", "Enable", "Disable")]
    [string]$Action,

    # CSV mode: specify environment to load all targets from ANF_DR_Config.csv
    [Parameter(Mandatory = $false)]
    [ValidateSet("Test", "Production")]
    [string]$Environment,

    # Path to the CSV config file
    [Parameter(Mandatory = $false)]
    [string]$ConfigFile = (Join-Path $PSScriptRoot "ANF_DR_Config.csv"),

    # Explicit mode: specify folder path and target paths directly (overrides CSV)
    [Parameter(Mandatory = $false)]
    [string]$DFSFolderPath,

    [Parameter(Mandatory = $false)]
    [string[]]$TargetPaths,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.PSCredential]
    $Credential,

    [Parameter(Mandatory = $false)]
    [string]$LogPath = (Join-Path $PSScriptRoot "Logs"),

    [Parameter(Mandatory = $false)]
    [switch]$Help
)

#region --- Functions ---

function Show-Help {
    Write-Information ""
    Write-Information "========================================================================" -InformationAction Continue
    Write-Information "  Manage-DFSPath.ps1  |  ANF DR - DFS Namespace Management" -InformationAction Continue
    Write-Information "========================================================================" -InformationAction Continue
    Write-Information ""
    Write-Information "SYNOPSIS" -InformationAction Continue
    Write-Information "  Get status, enable, or disable DFS folder targets for ANF DR."
    Write-Information "  GetStatus  : No credential required. Native DFS query."
    Write-Information "  Enable/Disable : Runs as gmo\admin-username via Invoke-Command."
    Write-Information ""
    Write-Information "SYNTAX" -InformationAction Continue
    Write-Information "  .\Manage-DFSPath.ps1 -Action <GetStatus|Enable|Disable>"
    Write-Information "                       -DFSFolderPath <\\server\namespace\folder>"
    Write-Information "                      [-TargetPaths <string[]>]"
    Write-Information "                      [-Credential <PSCredential>]"
    Write-Information "                      [-LogPath <path>]"
    Write-Information "                      [-WhatIf]"
    Write-Information ""
    Write-Information "PARAMETERS" -InformationAction Continue
    Write-Information "  -Action          GetStatus | Enable | Disable  (required)"
    Write-Information "  -DFSFolderPath   UNC path to the DFS namespace folder  (required)"
    Write-Information "  -TargetPaths     UNC target path(s) to enable/disable  (required for Enable/Disable)"
    Write-Information "  -Credential      PSCredential for Enable/Disable  (prompts for gmo\admin-username if omitted)"
    Write-Information "  -LogPath         Log file directory  (default: script dir\Logs)"
    Write-Information "  -WhatIf          Preview changes without applying"
    Write-Information "  -Help            Show this help"
    Write-Information ""
    Write-Information "EXAMPLES" -InformationAction Continue
    Write-Information "  # Get status of all targets"
    Write-Information "  .\Manage-DFSPath.ps1 -Action GetStatus -DFSFolderPath `"\\corp.example.com\TS2\DR_Test`""
    Write-Information ""
    Write-Information "  # Disable EU2 source target (step 1 of failover)"
    Write-Information "  .\Manage-DFSPath.ps1 -Action Disable -DFSFolderPath `"\\corp.example.com\TS2\DR_Test`" -TargetPaths `"\\anf-source.corp.example.com\eu2-dr-test`""
    Write-Information ""
    Write-Information "  # Enable CUS DR target (step 2 of failover)"
    Write-Information "  .\Manage-DFSPath.ps1 -Action Enable -DFSFolderPath `"\\corp.example.com\TS2\DR_Test`" -TargetPaths `"\\anf-dr.corp.example.com\cus-dr-test`""
    Write-Information ""
    Write-Information "  # Disable multiple targets"
    Write-Information "  .\Manage-DFSPath.ps1 -Action Disable -DFSFolderPath `"\\corp.example.com\prd_eu2\Opr`" -TargetPaths @(`"\\anf-72b8.corp.example.com\eu2-b-prdopr`", `"\\anf-8dcf.corp.example.com\cus-b-prdopr`")"
    Write-Information ""
    Write-Information "  # Preview without applying"
    Write-Information "  .\Manage-DFSPath.ps1 -Action Disable -DFSFolderPath `"\\corp.example.com\DR\test`" -TargetPaths `"\\anf-source.corp.example.com\eu2-dr-test`" -WhatIf"
    Write-Information ""
    Write-Information "DR WORKFLOW" -InformationAction Continue
    Write-Information "  FAILOVER (EU2 -> CUS):"
    Write-Information "    1. Manage-DFSPath.ps1 -Action Disable  (take EU2 target offline)"
    Write-Information "    2. Manage-ANFReplication.ps1 -Action BreakReplication"
    Write-Information "    3. Manage-DFSPath.ps1 -Action Enable   (bring CUS target online)"
    Write-Information "  FAILBACK (CUS -> EU2):"
    Write-Information "    4. Manage-DFSPath.ps1 -Action Disable  (take CUS target offline)"
    Write-Information "    5. Manage-ANFReplication.ps1 -Action ResyncReplication"
    Write-Information "    6. Manage-DFSPath.ps1 -Action Enable   (bring EU2 target back online)"
    Write-Information ""
    Write-Information "NOTES" -InformationAction Continue
    Write-Information "  Author   : Storage Team"
    Write-Information "  Updated  : 03/03/2026"
    Write-Information "  Requires : DFS Namespace PowerShell module (RSAT)"
    Write-Information "========================================================================" -InformationAction Continue
    Write-Information ""
}

function Write-LogMessage {
    param (
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS")]
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    Write-Output $logEntry
    Add-Content -Path $script:LogFile -Value $logEntry
}

function Get-TargetSite {
    param ([string]$DFSPath, [string]$TargetPath)
    try {
        $result = (dfsutil target $DFSPath $TargetPath 2>&1) -join ' '
        if ($result -match '\[Site:\s*(.+?)\]') { return $Matches[1].Trim() }
        return "Unknown"
    }
    catch { return "Unknown" }
}

#endregion

#region --- Validation ---

# Show help and exit if -Help specified
if ($Help) {
    Show-Help
    exit 0
}

# Enforce required params
if (-not $Action) {
    Write-Error "-Action is required. Use -Help to see usage."
    exit 1
}

# ==========================================
# Build work item list from CSV or explicit params
# Each work item: DFSFolderPath + TargetPath to act on
# ==========================================
$workItems = @()

if ($Environment) {
    # CSV mode: load all rows for this environment
    if (-not (Test-Path $ConfigFile)) {
        Write-Error "Config file not found: '$ConfigFile'. Update -ConfigFile or use -DFSFolderPath/-TargetPaths directly."
        exit 1
    }
    $csvRows = Import-Csv -Path $ConfigFile | Where-Object { $_.Environment -ieq $Environment }
    if ($csvRows.Count -eq 0) {
        Write-Error "No rows found in '$ConfigFile' for Environment='$Environment'."
        exit 1
    }
    Write-Information "[INFO] Loaded $($csvRows.Count) row(s) from config for Environment '$Environment'" -InformationAction Continue
    foreach ($row in $csvRows) {
        $workItems += [PSCustomObject]@{
            DFSFolderPath = $row.DFSFolderPath
            SourceTarget  = $row.SourceTarget
            DRTarget      = $row.DRTarget
            TargetPath    = $null  # resolved dynamically in main loop based on current DFS state
        }
    }
} elseif ($DFSFolderPath) {
    # Explicit mode: use provided params
    if ($Action -ne "GetStatus" -and (-not $TargetPaths -or $TargetPaths.Count -eq 0)) {
        Write-Error "-TargetPaths is required when Action is '$Action' and -Environment is not specified."
        exit 1
    }
    $tps = if ($TargetPaths) { $TargetPaths } else { @($null) }
    foreach ($tp in $tps) {
        $workItems += [PSCustomObject]@{ DFSFolderPath = $DFSFolderPath; TargetPath = $tp }
    }
} else {
    Write-Error "Specify -Environment <Test|Production> (CSV mode) or -DFSFolderPath (explicit mode). Use -Help for usage."
    exit 1
}

# Load admin credential for Enable/Disable (auto-load stored, prompt if missing)
$credFile = Join-Path $env:USERPROFILE '.gmo_admin_cred.xml'
if ($Action -ne "GetStatus" -and -not $Credential) {
    if (Test-Path $credFile) {
        $Credential = Import-Clixml -Path $credFile
        Write-Information "[INFO] Loaded stored credential for $($Credential.UserName)" -InformationAction Continue
    } else {
        Write-Information "[INFO] No stored credential at '$credFile'. Prompting..." -InformationAction Continue
        Write-Information "[TIP]  Store once: Get-Credential -UserName 'gmo\admin-username' | Export-Clixml -Path '$credFile'" -InformationAction Continue
        $Credential = Get-Credential -UserName "gmo\admin-username" -Message "Enter admin-username credentials for DFS $Action operation"
    }
}

#endregion

#region --- Main Execution ---

# Setup logging
if (-not (Test-Path $LogPath)) {
    New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
}
$script:LogFile = Join-Path $LogPath "DFS-DR-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

Write-LogMessage "=========================================="
Write-LogMessage "ANF DR - DFS Path Management"
Write-LogMessage "=========================================="
Write-LogMessage "Action           : $Action"
if ($Environment) { Write-LogMessage "Environment      : $Environment" }
if ($Action -ne "GetStatus") { Write-LogMessage "Run As (DFS)     : $($Credential.UserName)" }
Write-LogMessage "Config File      : $ConfigFile"
Write-LogMessage "Processing Items : $($workItems.Count)"
Write-LogMessage "=========================================="

$globalResults = @()
$globalErrors  = $false

# Process each unique DFSFolderPath
$uniqueFolders = $workItems | Select-Object -ExpandProperty DFSFolderPath -Unique

foreach ($folderPath in $uniqueFolders) {
    # For explicit mode, TargetPath is pre-set; for CSV mode it is resolved after reading current DFS state
    $folderTargetPaths = $workItems |
        Where-Object { $_.DFSFolderPath -eq $folderPath -and $_.TargetPath } |
        ForEach-Object { $_.TargetPath }

    Write-LogMessage ""
    Write-LogMessage "--- Folder: $folderPath ---"

    # ==========================================
    # STEP 1: Retrieve all current targets
    # ==========================================
    Write-LogMessage ">>> STEP 1: Retrieving DFS folder targets..."
    try {
        $allTargets = Get-DfsnFolderTarget -Path $folderPath -ErrorAction Stop
        Write-LogMessage "  $($allTargets.Count) target(s):"
        foreach ($t in $allTargets) {
            Write-LogMessage "    $($t.TargetPath) = $($t.State)"
        }
    }
    catch {
        Write-LogMessage "Failed to retrieve targets for '$folderPath': $_" -Level "ERROR"
        $globalErrors = $true
        continue
    }

    # ==========================================
    # GetStatus — resolve site info and display
    # ==========================================
    if ($Action -eq "GetStatus") {
        Write-LogMessage ">>> STATUS: Resolving AD site for each target..."
        $statusOutput = foreach ($target in $allTargets) {
            $site = Get-TargetSite -DFSPath $target.Path -TargetPath $target.TargetPath
            [PSCustomObject]@{
                Folder     = $target.Path
                TargetPath = $target.TargetPath
                Site       = $site
                State      = $target.State
                Priority   = $target.ReferralPriorityClass
            }
        }
        $statusOutput | Format-Table -AutoSize | Out-String -Stream |
            Where-Object { $_.Trim() } | ForEach-Object { Write-LogMessage $_ }
        continue
    }

    # ==========================================
    # CSV mode: auto-detect which target to act on based on current DFS state
    # ==========================================
    if ($Environment) {
        $csvConfig  = $workItems | Where-Object { $_.DFSFolderPath -eq $folderPath } | Select-Object -First 1
        $stateFile  = Join-Path $PSScriptRoot "dr_state_$($Environment.ToLower()).json"

        $sourceTarget  = $csvConfig.SourceTarget
        $drTarget      = $csvConfig.DRTarget
        $sourceOnline  = $allTargets | Where-Object { $_.TargetPath -ieq $sourceTarget -and $_.State -eq 'Online' }
        $drOnline      = $allTargets | Where-Object { $_.TargetPath -ieq $drTarget     -and $_.State -eq 'Online' }
        $sourceOffline = $allTargets | Where-Object { $_.TargetPath -ieq $sourceTarget -and $_.State -eq 'Offline' }
        $drOffline     = $allTargets | Where-Object { $_.TargetPath -ieq $drTarget     -and $_.State -eq 'Offline' }

        if ($Action -eq 'Disable') {
            if ($sourceOnline) {
                $folderTargetPaths = @($sourceTarget)
                Write-LogMessage "  [AUTO-DETECT] Source target is Online -> will Disable: $sourceTarget"
            } elseif ($drOnline) {
                $folderTargetPaths = @($drTarget)
                Write-LogMessage "  [AUTO-DETECT] DR target is Online -> will Disable: $drTarget"
            } else {
                Write-LogMessage "  Both targets are already Offline — nothing to disable." -Level "WARN"
                continue
            }
            # Save state so Enable knows which target was last disabled
            @{ DisabledTarget = $folderTargetPaths[0]; Timestamp = (Get-Date -Format 'o') } |
                ConvertTo-Json | Set-Content -Path $stateFile -Encoding utf8
        }
        elseif ($Action -eq 'Enable') {
            if ($sourceOnline -or $drOnline) {
                # One already Online — enable the Offline one
                if ($drOffline) {
                    $folderTargetPaths = @($drTarget)
                    Write-LogMessage "  [AUTO-DETECT] DR target is Offline -> will Enable: $drTarget"
                } elseif ($sourceOffline) {
                    $folderTargetPaths = @($sourceTarget)
                    Write-LogMessage "  [AUTO-DETECT] Source target is Offline -> will Enable: $sourceTarget"
                } else {
                    Write-LogMessage "  Both targets are already Online — nothing to enable." -Level "WARN"
                    continue
                }
            } else {
                # Both Offline — consult state file to determine which to enable next
                if (Test-Path $stateFile) {
                    $lastState = Get-Content $stateFile -Raw | ConvertFrom-Json
                    Write-LogMessage "  [AUTO-DETECT] Both Offline. Last disabled: $($lastState.DisabledTarget)"
                    if ($lastState.DisabledTarget -ieq $sourceTarget) {
                        # Source was disabled for failover -> enable DRTarget next
                        $folderTargetPaths = @($drTarget)
                        Write-LogMessage "  [AUTO-DETECT] Failover phase -> will Enable DR target: $drTarget"
                    } else {
                        # DRTarget was disabled for failback -> re-enable SourceTarget
                        $folderTargetPaths = @($sourceTarget)
                        Write-LogMessage "  [AUTO-DETECT] Failback phase -> will Enable Source target: $sourceTarget"
                    }
                } else {
                    # No state file: default to enabling DRTarget
                    $folderTargetPaths = @($drTarget)
                    Write-LogMessage "  [AUTO-DETECT] No state file found. Defaulting to DRTarget: $drTarget" -Level "WARN"
                }
            }
        }
    }

    # ==========================================
    # STEP 2: Validate requested targets exist
    # ==========================================
    Write-LogMessage ">>> STEP 2: Validating requested target paths..."
    $existingTargetPaths = $allTargets | ForEach-Object { $_.TargetPath.ToLower() }
    $validTargets = @()
    $hasErrors    = $false

    foreach ($tp in $folderTargetPaths) {
        if ($existingTargetPaths -contains $tp.ToLower()) {
            $cur = $allTargets | Where-Object { $_.TargetPath -ieq $tp }
            Write-LogMessage "  [OK] $tp (current: $($cur.State))"
            $validTargets += $cur
        } else {
            Write-LogMessage "  [NOT FOUND] $tp not in '$folderPath'" -Level "ERROR"
            $hasErrors = $true; $globalErrors = $true
        }
    }

    if ($validTargets.Count -eq 0) {
        Write-LogMessage "No valid targets for '$folderPath'. Skipping." -Level "ERROR"
        $globalErrors = $true; continue
    }
    if ($hasErrors) {
        Write-LogMessage "Some targets not found. Continuing with $($validTargets.Count) valid target(s)." -Level "WARN"
    }

    # ==========================================
    # STEP 3: Apply state changes as admin-username (local Start-Process, no WinRM)
    # ==========================================
    Write-LogMessage ">>> STEP 3: Applying state changes as '$($Credential.UserName)'..."
    $targetState     = if ($Action -eq "Enable") { "Online" } else { "Offline" }
    $ts              = Get-Date -Format 'yyyyMMddHHmmss'
    $innerScriptPath = Join-Path $LogPath "_dfs_inner_$ts.ps1"
    $innerErrorPath  = Join-Path $LogPath "_dfs_error_$ts.txt"

    foreach ($target in $validTargets) {
        if ($target.State -eq $targetState) {
            Write-LogMessage "  $($target.TargetPath) already '$targetState'. No change needed."
            $globalResults += [PSCustomObject]@{
                Folder     = $folderPath; TargetPath = $target.TargetPath
                OldState   = $target.State; NewState = $targetState
                Changed    = $false; Status = "Already $targetState"
            }
        }
    }

    $targetsToChange = $validTargets | Where-Object { $_.State -ne $targetState }
    if ($targetsToChange.Count -gt 0) {
        foreach ($t in $targetsToChange) {
            Write-LogMessage "  Will set: $($t.TargetPath)  $($t.State) -> $targetState"
        }

        # Write a temp inner script to avoid escaping issues with -Command
        $innerLines = @('try {')
        foreach ($t in $targetsToChange) {
            $innerLines += "    Set-DfsnFolderTarget -Path '$folderPath' -TargetPath '$($t.TargetPath)' -State $targetState -ErrorAction Stop"
        }
        $innerLines += "} catch {"
        $innerLines += "    Set-Content -Path '$innerErrorPath' -Value `$_.ToString() -Encoding utf8"
        $innerLines += "}"
        Set-Content -Path $innerScriptPath -Value ($innerLines -join "`n") -Encoding utf8

        if ($PSCmdlet.ShouldProcess("$($targetsToChange.Count) target(s) in $folderPath", "Set state to $targetState as $($Credential.UserName)")) {
            Write-LogMessage "  Launching pwsh as $($Credential.UserName) (local RPC, no WinRM)..."
            $proc = Start-Process -FilePath 'pwsh' `
                -ArgumentList '-NoProfile', '-NonInteractive', '-File', $innerScriptPath `
                -Credential $Credential -Wait -PassThru -WindowStyle Hidden
            Write-LogMessage "  Process exit code: $($proc.ExitCode)"

            $errContent = if (Test-Path $innerErrorPath) { Get-Content $innerErrorPath -Raw -ErrorAction SilentlyContinue } else { $null }
            if ($errContent) {
                Write-LogMessage "  Error: $errContent" -Level "ERROR"
                $globalErrors = $true
                foreach ($t in $targetsToChange) {
                    $globalResults += [PSCustomObject]@{
                        Folder = $folderPath; TargetPath = $t.TargetPath
                        OldState = $t.State; NewState = $targetState
                        Changed = $false; Status = "Failed"
                    }
                }
            } else {
                foreach ($t in $targetsToChange) {
                    Write-LogMessage "  $($t.TargetPath) -> '$targetState'" -Level "SUCCESS"
                    $globalResults += [PSCustomObject]@{
                        Folder = $folderPath; TargetPath = $t.TargetPath
                        OldState = $t.State; NewState = $targetState
                        Changed = $true; Status = "Success"
                    }
                }
            }
        }
        Remove-Item $innerScriptPath, $innerErrorPath -Force -ErrorAction SilentlyContinue
    }

    # ==========================================
    # STEP 4: Validate state changes
    # ==========================================
    Write-LogMessage ">>> STEP 4: Validating state changes..."
    $updatedTargets = Get-DfsnFolderTarget -Path $folderPath -ErrorAction SilentlyContinue
    foreach ($target in $updatedTargets) {
        $wasRequested = $folderTargetPaths | Where-Object { $_ -ieq $target.TargetPath }
        $marker = if ($wasRequested) { "[CHANGED]" } else { "[UNCHANGED]" }
        Write-LogMessage "  $marker $($target.TargetPath) = $($target.State)"
        if ($wasRequested -and $target.State -ne $targetState) {
            Write-LogMessage "  VALIDATION FAILED: Expected '$targetState' but got '$($target.State)'" -Level "ERROR"
            $globalErrors = $true
        }
    }
}

# ==========================================
# Final Summary
# ==========================================
if ($Action -ne "GetStatus" -and $globalResults.Count -gt 0) {
    Write-LogMessage ""
    Write-LogMessage "=========================================="
    Write-LogMessage "Summary"
    Write-LogMessage "=========================================="
    $globalResults | Format-Table -AutoSize | Out-String -Stream |
        Where-Object { $_.Trim() } | ForEach-Object { Write-LogMessage $_ }
}

if ($globalErrors) {
    Write-LogMessage "Completed with errors. Review log: $($script:LogFile)" -Level "WARN"
    exit 1
} else {
    Write-LogMessage "All DFS target operations completed successfully." -Level "SUCCESS"
    Write-LogMessage "Log file: $($script:LogFile)"
    exit 0
}

#endregion
