<#
.SYNOPSIS
    Authorize and establish ANF cross-region replication from the source volume.

.DESCRIPTION
    After creating both the source volume (EU2) and DR volume (CUS) using
    Create-ANFVolumes.ps1, run this script to authorize the replication
    from the source side. This completes the replication setup and starts
    the initial baseline transfer.

    Flow:
      1. Verify both source and DR volumes exist
      2. Authorize replication on the source volume
      3. Wait for replication to reach 'Mirrored' state

.PARAMETER SubscriptionId
    Azure subscription ID. Defaults to gmo-primary.

.PARAMETER SourceVolumeName
    Name of the source volume in EU2.

.PARAMETER DRVolumeName
    Name of the DR (destination) volume in CUS.

.PARAMETER PoolName
    Capacity pool name.

.PARAMETER WaitForMirrored
    If specified, polls until replication reaches Mirrored state.

.PARAMETER MaxWaitMinutes
    Maximum time to wait for initial sync. Default: 60.

.EXAMPLE
    .\Establish-ANFReplication.ps1 -SourceVolumeName "eu2-dr-test" -DRVolumeName "cus-dr-test" -WaitForMirrored

.NOTES
    Author     : Storage Team
    CreatedOn  : 02/19/2026
    Requires   : Az.NetAppFiles, Az.Accounts modules
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId = "c303bd32-eddf-42ca-9946-d679e0b1e1f3",

    [Parameter(Mandatory = $false)]
    [string]$SourceVolumeName = "eu2-dr-test",

    [Parameter(Mandatory = $false)]
    [string]$DRVolumeName = "cus-dr-test",

    [Parameter(Mandatory = $false)]
    [string]$SourcePoolName = "test_pool",

    [Parameter(Mandatory = $false)]
    [string]$DRPoolName = "test",

    # --- Source (EU2) ---
    [Parameter(Mandatory = $false)]
    [string]$SourceResourceGroup = "eastus2-eu2tstanf01-rg",

    [Parameter(Mandatory = $false)]
    [string]$SourceAccountName = "eu2tstanf01",

    # --- DR (CUS) ---
    [Parameter(Mandatory = $false)]
    [string]$DRResourceGroup = "centralus-custstanf01-rg",

    [Parameter(Mandatory = $false)]
    [string]$DRAccountName = "custstanf01",

    [Parameter(Mandatory = $false)]
    [switch]$WaitForMirrored,

    [Parameter(Mandatory = $false)]
    [int]$MaxWaitMinutes = 60,

    [Parameter(Mandatory = $false)]
    [string]$LogPath = (Join-Path $PSScriptRoot "Logs")
)

#region --- Functions ---

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

function Connect-ToAzure {
    param (
        [string]$SubId
    )
    try {
        $context = Get-AzContext
        if (-not $context -or $context.Subscription.Id -ne $SubId) {
            Write-LogMessage "Connecting to Azure with subscription: $SubId..."
            Connect-AzAccount -SubscriptionId $SubId -ErrorAction Stop | Out-Null
            $context = Get-AzContext
        }
        Write-LogMessage "Connected to Azure | Subscription: $($context.Subscription.Name) ($SubId)" -Level "SUCCESS"
        return $true
    }
    catch {
        Write-LogMessage "Failed to connect to Azure: $_" -Level "ERROR"
        return $false
    }
}

#endregion

#region --- Main Execution ---

# Setup logging
if (-not (Test-Path $LogPath)) {
    New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
}
$script:LogFile = Join-Path $LogPath "ANF-Replication-Establish-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

Write-LogMessage "=========================================="
Write-LogMessage "ANF Replication - Establish"
Write-LogMessage "=========================================="
Write-LogMessage "Source Volume  : $SourceVolumeName ($SourceAccountName)"
Write-LogMessage "DR Volume      : $DRVolumeName ($DRAccountName)"
Write-LogMessage "Source Pool     : $SourcePoolName"
Write-LogMessage "DR Pool        : $DRPoolName"
Write-LogMessage "=========================================="

# Connect to Azure
if (-not (Connect-ToAzure -SubId $SubscriptionId)) {
    Write-LogMessage "Cannot proceed without Azure connection. Exiting." -Level "ERROR"
    exit 1
}

Import-Module Az.NetAppFiles -ErrorAction Stop
Write-LogMessage "Az.NetAppFiles module loaded."

# ==========================================
# STEP 1: Verify source volume exists
# ==========================================
Write-LogMessage ""
Write-LogMessage ">>> STEP 1: Verifying source volume..."

try {
    $sourceVolume = Get-AzNetAppFilesVolume `
        -ResourceGroupName $SourceResourceGroup `
        -AccountName $SourceAccountName `
        -PoolName $SourcePoolName `
        -Name $SourceVolumeName `
        -ErrorAction Stop

    Write-LogMessage "Source volume found: $($sourceVolume.Name) (State: $($sourceVolume.ProvisioningState))" -Level "SUCCESS"
    Write-LogMessage "  Resource ID: $($sourceVolume.Id)"
}
catch {
    Write-LogMessage "Source volume '$SourceVolumeName' not found in $($SourceAccountName)/$($SourcePoolName): $($_)" -Level "ERROR"
    Write-LogMessage "Run Create-ANFVolumes.ps1 first to create the volumes." -Level "ERROR"
    exit 1
}

# ==========================================
# STEP 2: Verify DR volume exists
# ==========================================
Write-LogMessage ""
Write-LogMessage ">>> STEP 2: Verifying DR volume..."

try {
    $drVolume = Get-AzNetAppFilesVolume `
        -ResourceGroupName $DRResourceGroup `
        -AccountName $DRAccountName `
        -PoolName $DRPoolName `
        -Name $DRVolumeName `
        -ErrorAction Stop

    Write-LogMessage "DR volume found: $($drVolume.Name) (State: $($drVolume.ProvisioningState), Type: $($drVolume.VolumeType))" -Level "SUCCESS"
    Write-LogMessage "  Resource ID: $($drVolume.Id)"

    if ($drVolume.VolumeType -ne "DataProtection") {
        Write-LogMessage "DR volume is not of type 'DataProtection'. It must be created as a DP volume with replication config." -Level "ERROR"
        exit 1
    }
}
catch {
    Write-LogMessage "DR volume '$DRVolumeName' not found in $($DRAccountName)/$($DRPoolName): $($_)" -Level "ERROR"
    Write-LogMessage "Run Create-ANFVolumes.ps1 first to create the volumes." -Level "ERROR"
    exit 1
}

# ==========================================
# STEP 3: Authorize replication from source
# ==========================================
Write-LogMessage ""
Write-LogMessage ">>> STEP 3: Authorizing replication from source volume..."

try {
    if ($PSCmdlet.ShouldProcess("$SourceAccountName/$PoolName/$SourceVolumeName", "Authorize Replication to $DRVolumeName")) {
        Approve-AzNetAppFilesReplication `
            -ResourceGroupName $SourceResourceGroup `
            -AccountName $SourceAccountName `
            -PoolName $SourcePoolName `
            -Name $SourceVolumeName `
            -DataProtectionVolumeId $drVolume.Id `
            -ErrorAction Stop

        Write-LogMessage "Replication authorization submitted from source." -Level "SUCCESS"
    }
}
catch {
    # Check if replication is already authorized
    if ($_.Exception.Message -match "already authorized|already exists|replication already") {
        Write-LogMessage "Replication appears to already be authorized." -Level "WARN"
    }
    else {
        Write-LogMessage "Failed to authorize replication: $_" -Level "ERROR"
        exit 1
    }
}

# ==========================================
# STEP 4: Verify replication status
# ==========================================
Write-LogMessage ""
Write-LogMessage ">>> STEP 4: Checking replication status on DR volume..."

Start-Sleep -Seconds 15  # Brief wait for Azure to process

try {
    $replStatus = Get-AzNetAppFilesReplicationStatus `
        -ResourceGroupName $DRResourceGroup `
        -AccountName $DRAccountName `
        -PoolName $DRPoolName `
        -Name $DRVolumeName `
        -ErrorAction Stop

    Write-LogMessage "Replication Status:"
    Write-LogMessage "  Mirror State       : $($replStatus.MirrorState)"
    Write-LogMessage "  Relationship Status: $($replStatus.RelationshipStatus)"
    Write-LogMessage "  Healthy            : $($replStatus.Healthy)"
    Write-LogMessage "  Total Progress     : $($replStatus.TotalProgress) bytes"

    if ($replStatus.ErrorMessage) {
        Write-LogMessage "  Error: $($replStatus.ErrorMessage)" -Level "ERROR"
    }
}
catch {
    Write-LogMessage "Could not retrieve replication status yet (may still be initializing): $_" -Level "WARN"
}

# ==========================================
# STEP 5: Wait for Mirrored state (optional)
# ==========================================
if ($WaitForMirrored) {
    Write-LogMessage ""
    Write-LogMessage ">>> STEP 5: Waiting for replication to reach 'Mirrored' state..."

    $startTime = Get-Date
    $timeout = New-TimeSpan -Minutes $MaxWaitMinutes
    $pollInterval = 30  # seconds

    while ((Get-Date) - $startTime -lt $timeout) {
        Start-Sleep -Seconds $pollInterval

        try {
            $status = Get-AzNetAppFilesReplicationStatus `
                -ResourceGroupName $DRResourceGroup `
                -AccountName $DRAccountName `
                -PoolName $DRPoolName `
                -Name $DRVolumeName `
                -ErrorAction Stop

            $elapsed = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)
            Write-LogMessage "  [$elapsed min] Mirror: $($status.MirrorState) | Relationship: $($status.RelationshipStatus) | Healthy: $($status.Healthy)"

            if ($status.MirrorState -eq "Mirrored" -and $status.RelationshipStatus -eq "Idle") {
                Write-LogMessage "Replication is fully established and mirrored!" -Level "SUCCESS"
                break
            }

            if ($status.ErrorMessage) {
                Write-LogMessage "Replication error: $($status.ErrorMessage)" -Level "ERROR"
                exit 1
            }
        }
        catch {
            Write-LogMessage "  Status not yet available, retrying..." -Level "WARN"
        }
    }

    if ((Get-Date) - $startTime -ge $timeout) {
        Write-LogMessage "Timeout after $MaxWaitMinutes minutes. Initial sync may still be in progress." -Level "WARN"
        Write-LogMessage "Use Manage-ANFReplication.ps1 -Action GetStatus to check later." -Level "INFO"
    }
}

# ==========================================
# Summary
# ==========================================
Write-LogMessage ""
Write-LogMessage "=========================================="
Write-LogMessage "Replication Establishment Summary"
Write-LogMessage "=========================================="
Write-LogMessage "Source: $SourceVolumeName ($SourceAccountName) --> DR: $DRVolumeName ($DRAccountName)" -Level "SUCCESS"
Write-LogMessage "Replication has been authorized and initial sync is in progress."
Write-LogMessage ""
Write-LogMessage "To monitor: .\Manage-ANFReplication.ps1 -Action GetStatus -VolumeNames @('$DRVolumeName')"
Write-LogMessage "To break:   .\Manage-ANFReplication.ps1 -Action BreakReplication -VolumeNames @('$DRVolumeName')"
Write-LogMessage "To resync:  .\Manage-ANFReplication.ps1 -Action ResyncReplication -VolumeNames @('$DRVolumeName')"
Write-LogMessage "=========================================="
Write-LogMessage "Log file: $($script:LogFile)"

exit 0

#endregion
