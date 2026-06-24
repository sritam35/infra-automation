<#
.SYNOPSIS
    Manage ANF Cross-Region Replication for DR failover/failback.
    Breaks or resyncs replication between source (EU2) and DR (CUS) volumes.

.DESCRIPTION
    This script manages Azure NetApp Files cross-region replication during DR operations.
    It can:
      - Check current replication status
      - Break replication (for DR failover - makes DR volume read/write)
      - Resync replication (for failback - re-establishes replication)

    WARNING: Resyncing replication will revert the DR volume to a read-only replica
    of the source. ALL DATA WRITTEN TO THE DR VOLUME DURING THE BREAK PERIOD WILL
    BE LOST. Ensure any DR data has been migrated back to source before resyncing.

    Environments:
      PRODUCTION
        Source (Primary)  : East US 2  | Account: anf-primary-account  | RG: eastus2-anf-primary-account-rg  | Pool: quant_standard
        DR (Secondary)    : Central US | Account: anf-dr-account  | RG: centralus-anf-dr-account-rg | Pool: quant_standard
      TEST
        Source (Primary)  : East US 2  | Account: anf-primary-test-account  | RG: eastus2-anf-primary-test-account-rg  | Pool: test_pool
        DR (Secondary)    : Central US | Account: anf-dr-test-account  | RG: centralus-anf-dr-test-account-rg | Pool: test
      Subscription      : <your-subscription-id>

.PARAMETER Environment
    Target environment: 'Production' (default) or 'Test'.
    When specified, automatically sets the correct Source/DR account, resource group, and pool name.
    Individual parameters (-SourceResourceGroup, -DRAccountName, etc.) override Environment defaults.

.PARAMETER Action
    The action to perform: 'BreakReplication', 'ResyncReplication', or 'GetStatus'

.PARAMETER SubscriptionId
    Azure subscription ID. Defaults to the GMO ANF subscription.

.PARAMETER SourceResourceGroup
    Resource group of the source (primary) ANF account.

.PARAMETER SourceAccountName
    NetApp account name for the source (primary) region.

.PARAMETER DRResourceGroup
    Resource group of the DR (secondary) ANF account.

.PARAMETER DRAccountName
    NetApp account name for the DR (secondary) region.

.PARAMETER DRPoolName
    Capacity pool name on the DR account where replicated volumes reside.

.PARAMETER VolumeNames
    Name(s) of the DR (destination) volume(s) to manage.
    Example: @("cus-b-prdopr")

.PARAMETER WaitForCompletion
    If specified, waits for resync to complete (polls replication status).

.PARAMETER MaxWaitMinutes
    Maximum time (in minutes) to wait for resync completion. Default: 120

.PARAMETER LogPath
    Path to write the log file. Defaults to script directory.

.PARAMETER Force
    Skip the interactive confirmation prompt for resync operations.
    USE WITH CAUTION: Resync will delete all data written to the DR volume during the break.

.EXAMPLE
    # Check replication status - PRODUCTION
    .\Manage-ANFReplication.ps1 -Action GetStatus -VolumeNames @("cus-b-prdopr")

.EXAMPLE
    # Check replication status - TEST
    .\Manage-ANFReplication.ps1 -Action GetStatus -Environment Test -VolumeNames @("cus-dr-test")

.EXAMPLE
    # Break replication for DR failover - PRODUCTION
    .\Manage-ANFReplication.ps1 -Action BreakReplication -VolumeNames @("cus-b-prdopr")

.EXAMPLE
    # Break replication for DR failover - TEST
    .\Manage-ANFReplication.ps1 -Action BreakReplication -Environment Test -VolumeNames @("cus-dr-test")

.EXAMPLE
    # Resync replication after failback - PRODUCTION (will prompt for confirmation)
    .\Manage-ANFReplication.ps1 -Action ResyncReplication -VolumeNames @("cus-b-prdopr") -WaitForCompletion

.EXAMPLE
    # Resync replication after failback - TEST (skip prompt with -Force)
    .\Manage-ANFReplication.ps1 -Action ResyncReplication -Environment Test -VolumeNames @("cus-dr-test") -Force

.NOTES
    Author     : Storage Team
    CreatedOn  : 02/19/2026
    Requires   : Az.NetAppFiles module, Az.Accounts module
    Permissions: Contributor or NetApp Account Operator on the ANF resources
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [ValidateSet("BreakReplication", "ResyncReplication", "GetStatus")]
    [string]$Action,

    [Parameter(Mandatory = $false)]
    [ValidateSet("Production", "Test")]
    [string]$Environment = "Production",

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId = "<your-subscription-id>",

    [Parameter(Mandatory = $false)]
    [string]$SourceResourceGroup,

    [Parameter(Mandatory = $false)]
    [string]$SourceAccountName,

    [Parameter(Mandatory = $false)]
    [string]$DRResourceGroup,

    [Parameter(Mandatory = $false)]
    [string]$DRAccountName,

    [Parameter(Mandatory = $false)]
    [string]$DRPoolName,

    [Parameter(Mandatory = $false)]
    [string[]]$VolumeNames,

    [Parameter(Mandatory = $false)]
    [switch]$WaitForCompletion,

    [Parameter(Mandatory = $false)]
    [int]$MaxWaitMinutes = 120,

    [Parameter(Mandatory = $false)]
    [switch]$Force,

    [Parameter(Mandatory = $false)]
    [string]$LogPath = (Join-Path $PSScriptRoot "Logs"),

    # Path to the shared CSV config file (used to derive VolumeNames when not specified)
    [Parameter(Mandatory = $false)]
    [string]$ConfigFile = (Join-Path $PSScriptRoot "ANF_DR_Config.csv"),

    [Parameter(Mandatory = $false)]
    [switch]$Help
)

#region --- Environment Resolution ---

# Show help and exit if -Help specified
if ($Help) {
    Write-Output ''
    Write-Output '========================================================================' | ForEach-Object { Write-Information $_ -InformationAction Continue }
    Write-Output '  Manage-ANFReplication.ps1  |  ANF DR - Cross-Region Replication' | ForEach-Object { Write-Information $_ -InformationAction Continue }
    Write-Output '========================================================================' | ForEach-Object { Write-Information $_ -InformationAction Continue }
    Write-Output ''
    Write-Output 'SYNOPSIS' | ForEach-Object { Write-Information $_ -InformationAction Continue }
    Write-Output '  Manage Azure NetApp Files cross-region replication for DR failover/failback.'
    Write-Output '  Supports status checks, breaking replication (failover), and resyncing (failback).'
    Write-Output ''
    Write-Output 'SYNTAX' | ForEach-Object { Write-Information $_ -InformationAction Continue }
    Write-Output '  .\Manage-ANFReplication.ps1 -Action <GetStatus|BreakReplication|ResyncReplication>'
    Write-Output '                              -VolumeNames <string[]>'
    Write-Output '                             [-Environment <Production|Test>]'
    Write-Output '                             [-WaitForCompletion] [-MaxWaitMinutes <int>]'
    Write-Output '                             [-Force] [-LogPath <path>]'
    Write-Output ''
    Write-Output 'PARAMETERS'
    Write-Output '  -Action              GetStatus | BreakReplication | ResyncReplication  (required)'
    Write-Output '  -VolumeNames         DR volume name(s) to manage, e.g. @(''cus-b-prdopr'')  (required)'
    Write-Output '  -Environment         Production (default) | Test  -- auto-sets account/RG/pool'
    Write-Output '  -WaitForCompletion   Wait for resync to reach Mirrored state'
    Write-Output '  -MaxWaitMinutes      Max wait time in minutes  (default: 120)'
    Write-Output '  -Force               Skip confirmation prompt for ResyncReplication  (CAUTION: data loss)'
    Write-Output '  -LogPath             Log directory  (default: script dir\Logs)'
    Write-Output '  -Help                Show this help'
    Write-Output ''
    Write-Output 'ENVIRONMENTS' | ForEach-Object { Write-Information $_ -InformationAction Continue }
    Write-Output '  Production (default)'
    Write-Output '    Source : anf-primary-account  (eastus2-anf-primary-account-rg)  Pool: quant_standard'
    Write-Output '    DR     : anf-dr-account  (centralus-anf-dr-account-rg) Pool: quant_standard'
    Write-Output '  Test'
    Write-Output '    Source : anf-primary-test-account  (eastus2-anf-primary-test-account-rg)  Pool: test_pool'
    Write-Output '    DR     : anf-dr-test-account  (centralus-anf-dr-test-account-rg) Pool: test'
    Write-Output ''
    Write-Output 'EXAMPLES' | ForEach-Object { Write-Information $_ -InformationAction Continue }
    Write-Output '  # Check replication status - PRODUCTION' | ForEach-Object { Write-Information $_ -InformationAction Continue }
    Write-Output '  .\Manage-ANFReplication.ps1 -Action GetStatus -VolumeNames @(''cus-b-prdopr'')'
    Write-Output ''
    Write-Output '  # Check replication status - TEST' | ForEach-Object { Write-Information $_ -InformationAction Continue }
    Write-Output '  .\Manage-ANFReplication.ps1 -Action GetStatus -Environment Test -VolumeNames @(''cus-dr-test'')'
    Write-Output ''
    Write-Output '  # Break replication for failover - PRODUCTION' | ForEach-Object { Write-Information $_ -InformationAction Continue }
    Write-Output '  .\Manage-ANFReplication.ps1 -Action BreakReplication -VolumeNames @(''cus-b-prdopr'')'
    Write-Output ''
    Write-Output '  # Break replication for failover - TEST' | ForEach-Object { Write-Information $_ -InformationAction Continue }
    Write-Output '  .\Manage-ANFReplication.ps1 -Action BreakReplication -Environment Test -VolumeNames @(''cus-dr-test'')'
    Write-Output ''
    Write-Output '  # Resync replication after failback - PRODUCTION (prompts confirmation)' | ForEach-Object { Write-Information $_ -InformationAction Continue }
    Write-Output '  .\Manage-ANFReplication.ps1 -Action ResyncReplication -VolumeNames @(''cus-b-prdopr'') -WaitForCompletion'
    Write-Output ''
    Write-Output '  # Resync replication after failback - TEST (skip prompt)' | ForEach-Object { Write-Information $_ -InformationAction Continue }
    Write-Output '  .\Manage-ANFReplication.ps1 -Action ResyncReplication -Environment Test -VolumeNames @(''cus-dr-test'') -Force'
    Write-Output ''
    Write-Output 'DR WORKFLOW' | ForEach-Object { Write-Information $_ -InformationAction Continue }
    Write-Output '  FAILOVER (EU2 source -> CUS DR):'
    Write-Output '    1. ' -NoNewline | ForEach-Object { Write-Information $_ -InformationAction Continue -NoNewline }; Write-Output 'Manage-DFSPath.ps1       -Action Disable  (take EU2 DFS target offline)'
    Write-Output '    2. ' -NoNewline | ForEach-Object { Write-Information $_ -InformationAction Continue -NoNewline }; Write-Output 'Manage-ANFReplication.ps1 -Action BreakReplication  (make CUS volume R/W)'
    Write-Output '    3. ' -NoNewline | ForEach-Object { Write-Information $_ -InformationAction Continue -NoNewline }; Write-Output 'Manage-DFSPath.ps1       -Action Enable   (bring CUS DFS target online)'
    Write-Output '  FAILBACK (CUS DR -> EU2 source):'
    Write-Output '    4. ' -NoNewline | ForEach-Object { Write-Information $_ -InformationAction Continue -NoNewline }; Write-Output 'Manage-DFSPath.ps1       -Action Disable  (take CUS DFS target offline)'
    Write-Output '    5. ' -NoNewline | ForEach-Object { Write-Information $_ -InformationAction Continue -NoNewline }; Write-Output 'Manage-ANFReplication.ps1 -Action ResyncReplication  (re-mirror from EU2)'
    Write-Output '    6. ' -NoNewline | ForEach-Object { Write-Information $_ -InformationAction Continue -NoNewline }; Write-Output 'Manage-DFSPath.ps1       -Action Enable   (bring EU2 DFS target back online)'
    Write-Output ''
    Write-Output '  WARNING: ResyncReplication permanently deletes data written to the DR' | ForEach-Object { Write-Information $_ -InformationAction Continue }
    Write-Output '           volume during the break period. Always use -WhatIf first.' | ForEach-Object { Write-Information $_ -InformationAction Continue }
    Write-Output ''
    Write-Output 'NOTES' | ForEach-Object { Write-Information $_ -InformationAction Continue }
    Write-Output '  Author      : Storage Team'
    Write-Output '  Created     : 02/19/2026'
    Write-Output '  Requires    : Az.NetAppFiles, Az.Accounts PowerShell modules'
    Write-Output '  Permissions : Contributor or NetApp Account Operator on the ANF resources'
    Write-Output '========================================================================' | ForEach-Object { Write-Information $_ -InformationAction Continue }
    Write-Output ''
    exit 0
}

# Enforce required params when not using -Help
if (-not $Action) {
    Write-Error "-Action is required. Use -Help to see usage."
    exit 1
}

# Derive VolumeNames from CSV if not explicitly provided
if (-not $VolumeNames -or $VolumeNames.Count -eq 0) {
    if (Test-Path $ConfigFile) {
        $csvRows = Import-Csv -Path $ConfigFile | Where-Object { $_.Environment -ieq $Environment }
        if ($csvRows.Count -gt 0) {
            # Derive volume name from DRTarget UNC share name (last path segment).
            # Source and DR volumes always share the same name in production,
            # so DRTarget is the canonical source — no separate VolumeName column needed.
            $VolumeNames = $csvRows | ForEach-Object {
                ($_.DRTarget -split '\\' | Where-Object { $_ } | Select-Object -Last 1)
            } | Where-Object { $_ }
            Write-Information "[INFO] Loaded $($VolumeNames.Count) volume(s) from config for Environment '$Environment': $($VolumeNames -join ', ')" -InformationAction Continue
        }
    }
    if (-not $VolumeNames -or $VolumeNames.Count -eq 0) {
        Write-Error "-VolumeNames is required (or add volumes to ANF_DR_Config.csv). Use -Help to see usage."
        exit 1
    }
}

# Set defaults based on -Environment, then allow individual params to override
$envDefaults = if ($Environment -eq "Test") {
    @{
        SourceResourceGroup = "eastus2-anf-primary-test-account-rg"
        SourceAccountName   = "anf-primary-test-account"
        DRResourceGroup     = "centralus-anf-dr-test-account-rg"
        DRAccountName       = "anf-dr-test-account"
        DRPoolName          = "test"
    }
} else {
    @{
        SourceResourceGroup = "eastus2-anf-primary-account-rg"
        SourceAccountName   = "anf-primary-account"
        DRResourceGroup     = "centralus-anf-dr-account-rg"
        DRAccountName       = "anf-dr-account"
        DRPoolName          = "quant_standard"
    }
}

# Apply defaults only for params not explicitly passed by the caller
if (-not $PSBoundParameters.ContainsKey("SourceResourceGroup")) { $SourceResourceGroup = $envDefaults.SourceResourceGroup }
if (-not $PSBoundParameters.ContainsKey("SourceAccountName"))   { $SourceAccountName   = $envDefaults.SourceAccountName }
if (-not $PSBoundParameters.ContainsKey("DRResourceGroup"))     { $DRResourceGroup     = $envDefaults.DRResourceGroup }
if (-not $PSBoundParameters.ContainsKey("DRAccountName"))       { $DRAccountName       = $envDefaults.DRAccountName }
if (-not $PSBoundParameters.ContainsKey("DRPoolName"))          { $DRPoolName          = $envDefaults.DRPoolName }
#endregion

#region --- Functions ---

function Write-LogEntry {
    param (
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS')]
        [string]$Level = 'INFO'
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logEntry = "[$timestamp] [$Level] $Message"
    Write-Output $logEntry
    Add-Content -Path $script:LogFile -Value $logEntry
}

function Connect-ToAzure {
    <#
    .SYNOPSIS
        Ensures connection to Azure and sets the correct subscription context.
    #>
    try {
        $context = Get-AzContext
        if (-not $context -or $context.Subscription.Id -ne $SubscriptionId) {
            Write-LogEntry "Connecting to Azure with subscription: $SubscriptionId..."
            Connect-AzAccount -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
            $context = Get-AzContext
        }

        Write-LogEntry "Connected to Azure | Subscription: $($context.Subscription.Name) ($SubscriptionId)" -Level 'SUCCESS'
        return $true
    }
    catch {
        Write-LogEntry "Failed to connect to Azure: $_" -Level 'ERROR'
        return $false
    }
}

function Get-ANFReplicationStatus {
    <#
    .SYNOPSIS
        Gets the replication status for a DR (destination) volume.
    #>
    param (
        [string]$ResourceGroupName,
        [string]$AccountName,
        [string]$PoolName,
        [string]$VolumeName
    )
    try {
        # Get the volume details to check replication configuration
        $volume = Get-AzNetAppFilesVolume `
            -ResourceGroupName $ResourceGroupName `
            -AccountName $AccountName `
            -PoolName $PoolName `
            -Name $VolumeName `
            -ErrorAction Stop

        # Get replication status
        $replStatus = Get-AzNetAppFilesReplicationStatus `
            -ResourceGroupName $ResourceGroupName `
            -AccountName $AccountName `
            -PoolName $PoolName `
            -Name $VolumeName `
            -ErrorAction Stop

        $statusObj = [PSCustomObject]@{
            VolumeName        = $VolumeName
            VolumeType        = $volume.VolumeType
            MirrorState       = $replStatus.MirrorState
            RelationshipStatus = $replStatus.RelationshipStatus
            HealthyStatus     = $replStatus.Healthy
            TotalProgress     = $replStatus.TotalProgress
            ErrorMessage      = $replStatus.ErrorMessage
        }

        return $statusObj
    }
    catch {
        Write-LogEntry "Failed to get replication status for volume '$VolumeName': $_" -Level 'ERROR'
        return $null
    }
}

function Invoke-BreakReplication {
    <#
    .SYNOPSIS
        Breaks (stops) replication on a DR volume, making it read/write.
        This is performed on the DESTINATION volume.
    #>
    param (
        [string]$ResourceGroupName,
        [string]$AccountName,
        [string]$PoolName,
        [string]$VolumeName
    )
    try {
        Write-LogEntry "Breaking replication for volume '$VolumeName'..."

        # Break the replication on the destination volume
        Suspend-AzNetAppFilesReplication `
            -ResourceGroupName $ResourceGroupName `
            -AccountName $AccountName `
            -PoolName $PoolName `
            -VolumeName $VolumeName `
            -Confirm:$false `
            -ErrorAction Stop

        Write-LogEntry "Break replication command submitted for '$VolumeName'" -Level 'SUCCESS'
        return $true
    }
    catch {
        Write-LogEntry "Failed to break replication for volume '$VolumeName': $_" -Level 'ERROR'
        return $false
    }
}

function Invoke-ResyncReplication {
    <#
    .SYNOPSIS
        Resyncs replication on a DR volume, re-establishing data protection.
        This is performed on the DESTINATION volume.
    #>
    param (
        [string]$ResourceGroupName,
        [string]$AccountName,
        [string]$PoolName,
        [string]$VolumeName
    )
    try {
        Write-LogEntry "Resyncing replication for volume '$VolumeName'..."

        # Resume/resync the replication on the destination volume
        Resume-AzNetAppFilesReplication `
            -ResourceGroupName $ResourceGroupName `
            -AccountName $AccountName `
            -PoolName $PoolName `
            -VolumeName $VolumeName `
            -Confirm:$false `
            -ErrorAction Stop

        Write-LogEntry "Resync replication command submitted for '$VolumeName'" -Level 'SUCCESS'
        return $true
    }
    catch {
        Write-LogEntry "Failed to resync replication for volume '$VolumeName': $_" -Level 'ERROR'
        return $false
    }
}

function Wait-ForReplicationSync {
    <#
    .SYNOPSIS
        Polls replication status until it reaches 'Mirrored' state or times out.
    #>
    param (
        [string]$ResourceGroupName,
        [string]$AccountName,
        [string]$PoolName,
        [string]$VolumeName,
        [int]$TimeoutMinutes = 120,
        [int]$PollIntervalSeconds = 60
    )

    $startTime = Get-Date
    $timeout = New-TimeSpan -Minutes $TimeoutMinutes

    Write-LogEntry "Waiting for replication to reach 'Mirrored' state (timeout: $TimeoutMinutes min)..."

    while ((Get-Date) - $startTime -lt $timeout) {
        Start-Sleep -Seconds $PollIntervalSeconds

        $status = Get-ANFReplicationStatus `
            -ResourceGroupName $ResourceGroupName `
            -AccountName $AccountName `
            -PoolName $PoolName `
            -VolumeName $VolumeName

        if ($null -eq $status) {
            Write-LogEntry "Unable to retrieve status. Retrying in $PollIntervalSeconds seconds..." -Level 'WARN'
            continue
        }

        $elapsed = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)
        Write-LogEntry "  [$elapsed min] Mirror State: $($status.MirrorState) | Relationship: $($status.RelationshipStatus) | Healthy: $($status.HealthyStatus)"

        if ($status.MirrorState -eq 'Mirrored' -and $status.RelationshipStatus -eq 'Idle') {
            Write-LogEntry "Replication for '$VolumeName' has reached 'Mirrored' state." -Level 'SUCCESS'
            return $true
        }

        if ($status.ErrorMessage) {
            Write-LogEntry "Replication error detected: $($status.ErrorMessage)" -Level 'ERROR'
            return $false
        }
    }

    Write-LogEntry "Timeout reached after $TimeoutMinutes minutes. Replication not yet mirrored for '$VolumeName'." -Level 'WARN'
    return $false
}

#endregion

#region --- Main Execution ---

# Setup logging
if (-not (Test-Path $LogPath)) {
    New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
}
$script:LogFile = Join-Path $LogPath "ANF-Replication-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

Write-LogEntry "=========================================="
Write-LogEntry "ANF DR - Replication Management"
Write-LogEntry "=========================================="
Write-LogEntry "Action            : $Action"
Write-LogEntry "Environment       : $Environment"
Write-LogEntry "Subscription      : $SubscriptionId"
Write-LogEntry "Source Account    : $SourceAccountName ($SourceResourceGroup)"
Write-LogEntry "DR Account        : $DRAccountName ($DRResourceGroup)"
Write-LogEntry "DR Pool           : $DRPoolName"
Write-LogEntry "Volume(s)         : $($VolumeNames -join ', ')"
Write-LogEntry "=========================================="

# Step 1: Connect to Azure
if (-not (Connect-ToAzure)) {
    Write-LogEntry "Cannot proceed without Azure connection. Exiting." -Level 'ERROR'
    exit 1
}

# Step 2: Verify required module
if (-not (Get-Module -ListAvailable -Name Az.NetAppFiles)) {
    Write-LogEntry "Az.NetAppFiles module not found. Install with: Install-Module Az.NetAppFiles" -Level 'ERROR'
    exit 1
}
Import-Module Az.NetAppFiles -ErrorAction Stop
Write-LogEntry "Az.NetAppFiles module loaded."

$results = @()
$hasErrors = $false

foreach ($volumeName in $VolumeNames) {
    Write-LogEntry "------------------------------------------"
    Write-LogEntry "Processing volume: $volumeName"
    Write-LogEntry "------------------------------------------"

    # Step 3: Get current replication status (pre-check)
    Write-LogEntry "Retrieving current replication status..."
    $preStatus = Get-ANFReplicationStatus `
        -ResourceGroupName $DRResourceGroup `
        -AccountName $DRAccountName `
        -PoolName $DRPoolName `
        -VolumeName $volumeName

    if ($null -eq $preStatus) {
        Write-LogEntry "Could not retrieve replication status for '$volumeName'. Skipping." -Level 'ERROR'
        $hasErrors = $true
        continue
    }

    Write-LogEntry "  Current State  : MirrorState=$($preStatus.MirrorState), Relationship=$($preStatus.RelationshipStatus), Healthy=$($preStatus.HealthyStatus)"

    # Step 4: Execute the requested action
    switch ($Action) {
        'GetStatus' {
            $results += $preStatus
            Write-LogEntry "Status retrieved for '$volumeName'." -Level 'SUCCESS'
        }

        'BreakReplication' {
            # Validate: Can only break if currently mirrored
            if ($preStatus.MirrorState -eq 'Broken') {
                Write-LogEntry "Replication for '$volumeName' is already broken. No action needed." -Level 'WARN'
                $results += [PSCustomObject]@{
                    VolumeName = $volumeName
                    Action     = 'BreakReplication'
                    PreState   = $preStatus.MirrorState
                    PostState  = 'Broken'
                    Status     = 'Already Broken'
                }
                continue
            }

            $success = Invoke-BreakReplication `
                -ResourceGroupName $DRResourceGroup `
                -AccountName $DRAccountName `
                -PoolName $DRPoolName `
                -VolumeName $volumeName

            if ($success) {
                # Wait briefly for state to update, then verify
                Start-Sleep -Seconds 30
                $postStatus = Get-ANFReplicationStatus `
                    -ResourceGroupName $DRResourceGroup `
                    -AccountName $DRAccountName `
                    -PoolName $DRPoolName `
                    -VolumeName $volumeName

                $results += [PSCustomObject]@{
                    VolumeName = $volumeName
                    Action     = 'BreakReplication'
                    PreState   = $preStatus.MirrorState
                    PostState  = $postStatus.MirrorState
                    Status     = if ($postStatus.MirrorState -eq 'Broken') { 'Success' } else { 'Pending - verify manually' }
                }
            }
            else {
                $hasErrors = $true
                $results += [PSCustomObject]@{
                    VolumeName = $volumeName
                    Action     = 'BreakReplication'
                    PreState   = $preStatus.MirrorState
                    PostState  = 'N/A'
                    Status     = 'Failed'
                }
            }
        }

        'ResyncReplication' {
            # *** DATA LOSS WARNING ***
            # Resyncing makes the DR volume a read-only replica of source again.
            # All data written to the DR volume during the break period will be DELETED.
            Write-LogEntry "WARNING: Resyncing will revert '$volumeName' to a read-only replica of source." -Level 'WARN'
            Write-LogEntry "WARNING: ALL data written to this DR volume during the break period will be LOST." -Level 'WARN'

            if (-not $Force) {
                $confirmation = Read-Host "Type 'CONFIRM-RESYNC' to proceed with resync of '$volumeName' (data on DR will be lost)"
                if ($confirmation -ne 'CONFIRM-RESYNC') {
                    Write-LogEntry "Resync aborted by user for '$volumeName'." -Level 'WARN'
                    $results += [PSCustomObject]@{
                        VolumeName = $volumeName
                        Action     = 'ResyncReplication'
                        PreState   = $preStatus.MirrorState
                        PostState  = 'N/A'
                        Status     = 'Aborted by user'
                    }
                    continue
                }
            }

            # Validate: Can only resync if currently broken
            if ($preStatus.MirrorState -eq 'Mirrored') {
                Write-LogEntry "Replication for '$volumeName' is already mirrored. No action needed." -Level 'WARN'
                $results += [PSCustomObject]@{
                    VolumeName = $volumeName
                    Action     = 'ResyncReplication'
                    PreState   = $preStatus.MirrorState
                    PostState  = 'Mirrored'
                    Status     = 'Already Mirrored'
                }
                continue
            }

            $success = Invoke-ResyncReplication `
                -ResourceGroupName $DRResourceGroup `
                -AccountName $DRAccountName `
                -PoolName $DRPoolName `
                -VolumeName $volumeName

            if ($success -and $WaitForCompletion) {
                $synced = Wait-ForReplicationSync `
                    -ResourceGroupName $DRResourceGroup `
                    -AccountName $DRAccountName `
                    -PoolName $DRPoolName `
                    -VolumeName $volumeName `
                    -TimeoutMinutes $MaxWaitMinutes

                $postStatus = Get-ANFReplicationStatus `
                    -ResourceGroupName $DRResourceGroup `
                    -AccountName $DRAccountName `
                    -PoolName $DRPoolName `
                    -VolumeName $volumeName

                $results += [PSCustomObject]@{
                    VolumeName = $volumeName
                    Action     = 'ResyncReplication'
                    PreState   = $preStatus.MirrorState
                    PostState  = $postStatus.MirrorState
                    Status     = if ($synced) { 'Success' } else { 'Timeout - check replication' }
                }

                if (-not $synced) { $hasErrors = $true }
            }
            elseif ($success) {
                $results += [PSCustomObject]@{
                    VolumeName = $volumeName
                    Action     = 'ResyncReplication'
                    PreState   = $preStatus.MirrorState
                    PostState  = 'Resyncing'
                    Status     = 'Submitted - not waiting'
                }
            }
            else {
                $hasErrors = $true
                $results += [PSCustomObject]@{
                    VolumeName = $volumeName
                    Action     = 'ResyncReplication'
                    PreState   = $preStatus.MirrorState
                    PostState  = 'N/A'
                    Status     = 'Failed'
                }
            }
        }
    }
}

# Summary
Write-LogEntry "=========================================="
Write-LogEntry "Summary"
Write-LogEntry "=========================================="
$results | Format-Table -AutoSize | Out-String | ForEach-Object { Write-LogEntry $_ }

if ($hasErrors) {
    Write-LogEntry "Completed with errors. Review log at: $($script:LogFile)" -Level 'WARN'
    exit 1
}
else {
    Write-LogEntry "All replication operations completed successfully." -Level 'SUCCESS'
    exit 0
}

#endregion
