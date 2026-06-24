<#
.SYNOPSIS
    Create ANF volumes in source (EU2) and DR (CUS) regions.
    The DR volume is created as a DataProtection volume with replication config.

.DESCRIPTION
    This script creates:
      1. A source volume in East US 2 (anf-primary-test-account)
      2. A DR (DataProtection) volume in Central US (anf-dr-test-account) linked to the source

    After both volumes are created, run Establish-ANFReplication.ps1 to authorize
    and start the replication from the source side.

.PARAMETER SubscriptionId
    Azure subscription ID. Defaults to gmo-primary.

.PARAMETER SourceVolumeName
    Name of the source volume in EU2.

.PARAMETER DRVolumeName
    Name of the DR volume in CUS.

.PARAMETER SizeInGiB
    Volume size in GiB.

.PARAMETER ServiceLevel
    Service level: Standard, Premium, or Ultra.

.PARAMETER ThroughputMiBps
    Manual throughput in MiB/s.

.PARAMETER PoolName
    Capacity pool name (must exist in both accounts).

.PARAMETER ReplicationSchedule
    Replication frequency: _10minutely, hourly, or daily.

.PARAMETER SourceResourceGroup
    Resource group for the source ANF account.

.PARAMETER SourceAccountName
    Source NetApp account name.

.PARAMETER DRResourceGroup
    Resource group for the DR ANF account.

.PARAMETER DRAccountName
    DR NetApp account name.

.EXAMPLE
    .\Create-ANFVolumes.ps1 -SourceVolumeName "eu2-dr-test" -DRVolumeName "cus-dr-test"

.EXAMPLE
    .\Create-ANFVolumes.ps1 -SourceVolumeName "eu2-dr-test" -DRVolumeName "cus-dr-test" -SizeInGiB 100 -ServiceLevel Premium

.NOTES
    Author     : Storage Team
    CreatedOn  : 02/19/2026
    Requires   : Az.NetAppFiles, Az.Accounts modules
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId = "<your-subscription-id>",

    [Parameter(Mandatory = $false)]
    [string]$SourceVolumeName = "eu2-dr-test",

    [Parameter(Mandatory = $false)]
    [string]$DRVolumeName = "cus-dr-test",

    [Parameter(Mandatory = $false)]
    [int]$SizeInGiB = 50,

    [Parameter(Mandatory = $false)]
    [ValidateSet("Standard", "Premium", "Ultra")]
    [string]$ServiceLevel = "Standard",

    [Parameter(Mandatory = $false)]
    [int]$ThroughputMiBps = 25,

    [Parameter(Mandatory = $false)]
    [string]$SourcePoolName = "test_pool",

    [Parameter(Mandatory = $false)]
    [string]$DRPoolName = "test",

    [Parameter(Mandatory = $false)]
    [ValidateSet("_10minutely", "hourly", "daily")]
    [string]$ReplicationSchedule = "hourly",

    # --- Source (EU2) ---
    [Parameter(Mandatory = $false)]
    [string]$SourceResourceGroup = "eastus2-anf-primary-test-account-rg",

    [Parameter(Mandatory = $false)]
    [string]$SourceAccountName = "anf-primary-test-account",

    [Parameter(Mandatory = $false)]
    [string]$SourceLocation = "eastus2",

    [Parameter(Mandatory = $false)]
    [string]$SourceSubnetId = "/subscriptions/<your-subscription-id>/resourceGroups/eastus2-network-rg/providers/Microsoft.Network/virtualNetworks/eastus2-vnet/subnets/anf.subnet",

    # --- DR (CUS) ---
    [Parameter(Mandatory = $false)]
    [string]$DRResourceGroup = "centralus-anf-dr-test-account-rg",

    [Parameter(Mandatory = $false)]
    [string]$DRAccountName = "anf-dr-test-account",

    [Parameter(Mandatory = $false)]
    [string]$DRLocation = "centralus",

    [Parameter(Mandatory = $false)]
    [string]$DRSubnetId = "/subscriptions/<your-subscription-id>/resourceGroups/centralus-network-rg/providers/Microsoft.Network/virtualNetworks/centralus-vnet/subnets/anf.subnet",

    [Parameter(Mandatory = $false)]
    [string]$LogPath = (Join-Path $PSScriptRoot "Logs")
)

#region --- Functions ---

function Write-LogMessage {
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
    try {
        $context = Get-AzContext
        if (-not $context -or $context.Subscription.Id -ne $SubscriptionId) {
        Write-LogMessage "Connecting to Azure with subscription: $SubscriptionId..."
            Connect-AzAccount -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
            Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
            $context = Get-AzContext
        }
        Write-LogMessage "Connected to Azure | Subscription: $($context.Subscription.Name) ($($context.Subscription.Id))" -Level 'SUCCESS'
        return $true
    }
    catch {
        Write-LogMessage "Failed to connect to Azure: $_" -Level 'ERROR'
        return $false
    }
}

function Wait-ForVolumeProvisioning {
    param (
        [string]$ResourceGroupName,
        [string]$AccountName,
        [string]$PoolName,
        [string]$VolumeName,
        [int]$TimeoutMinutes = 15,
        [int]$PollIntervalSeconds = 15
    )
    $startTime = Get-Date
    $timeout = New-TimeSpan -Minutes $TimeoutMinutes

    Write-LogMessage "Waiting for volume '$VolumeName' to be provisioned (timeout: $TimeoutMinutes min)..."

    while ((Get-Date) - $startTime -lt $timeout) {
        try {
            $volume = Get-AzNetAppFilesVolume `
                -ResourceGroupName $ResourceGroupName `
                -AccountName $AccountName `
                -PoolName $PoolName `
                -Name $VolumeName `
                -ErrorAction Stop

            $state = $volume.ProvisioningState
            $elapsed = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 0)
            Write-LogMessage "  [${elapsed}s] Provisioning State: $state"

            if ($state -eq 'Succeeded') {
                Write-LogMessage "Volume '$VolumeName' provisioned successfully." -Level 'SUCCESS'
                return $volume
            }
            if ($state -eq 'Failed') {
                Write-LogMessage "Volume '$VolumeName' provisioning failed." -Level 'ERROR'
                return $null
            }
        }
        catch {
            Write-LogMessage "  Waiting for volume to appear..." -Level 'INFO'
        }
        Start-Sleep -Seconds $PollIntervalSeconds
    }

    Write-LogMessage "Timeout waiting for volume '$VolumeName' to provision." -Level 'ERROR'
    return $null
}

#endregion

#region --- Main Execution ---

# Setup logging
if (-not (Test-Path $LogPath)) {
    New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
}
$script:LogFile = Join-Path $LogPath "ANF-VolumeCreation-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

# Convert size to bytes (ANF expects bytes)
$sizeInBytes = [int64]$SizeInGiB * 1073741824

# Export policy rules (same as existing production volumes)
$exportPolicyRules = @(
    @{
        RuleIndex        = 1
        UnixReadOnly     = $false
        UnixReadWrite    = $true
        Cifs             = $false
        Nfsv3            = $false
        Nfsv41           = $true
        AllowedClients   = "10.x.x.x/24,10.x.x.x/24"
        Kerberos5ReadOnly  = $false
        Kerberos5ReadWrite = $false
        Kerberos5iReadOnly  = $false
        Kerberos5iReadWrite = $false
        Kerberos5pReadOnly  = $false
        Kerberos5pReadWrite = $false
        HasRootAccess    = $false
        ChownMode        = "Restricted"
    },
    @{
        RuleIndex        = 2
        UnixReadOnly     = $false
        UnixReadWrite    = $true
        Cifs             = $false
        Nfsv3            = $false
        Nfsv41           = $true
        AllowedClients   = "10.x.x.x,10.x.x.x"
        Kerberos5ReadOnly  = $false
        Kerberos5ReadWrite = $false
        Kerberos5iReadOnly  = $false
        Kerberos5iReadWrite = $false
        Kerberos5pReadOnly  = $false
        Kerberos5pReadWrite = $false
        HasRootAccess    = $true
        ChownMode        = "Restricted"
    },
    @{
        RuleIndex        = 3
        UnixReadOnly     = $false
        UnixReadWrite    = $true
        Cifs             = $false
        Nfsv3            = $false
        Nfsv41           = $true
        AllowedClients   = "10.0.0.0/8"
        Kerberos5ReadOnly  = $false
        Kerberos5ReadWrite = $false
        Kerberos5iReadOnly  = $false
        Kerberos5iReadWrite = $false
        Kerberos5pReadOnly  = $false
        Kerberos5pReadWrite = $false
        HasRootAccess    = $true
        ChownMode        = "Restricted"
    }
)

Write-LogMessage "=========================================="
Write-LogMessage "ANF Volume Creation"
Write-LogMessage "=========================================="
Write-LogMessage "Subscription ID    : $SubscriptionId"
Write-LogMessage "Source Volume      : $SourceVolumeName ($SourceLocation)"
Write-LogMessage "  Account          : $SourceAccountName / $SourcePoolName"
Write-LogMessage "  Resource Group   : $SourceResourceGroup"
Write-LogMessage "DR Volume          : $DRVolumeName ($DRLocation)"
Write-LogMessage "  Account          : $DRAccountName / $DRPoolName"
Write-LogMessage "  Resource Group   : $DRResourceGroup"
Write-LogMessage "Size               : $SizeInGiB GiB ($sizeInBytes bytes)"
Write-LogMessage "Service Level      : $ServiceLevel"
Write-LogMessage "Throughput         : $ThroughputMiBps MiB/s (applied only to Manual QoS pools)"
Write-LogMessage "Protocol           : NFSv4.1 + CIFS (dual)"
Write-LogMessage "Security Style     : Ntfs"
Write-LogMessage "LDAP               : Enabled"
Write-LogMessage "Replication Schedule: $ReplicationSchedule"
Write-LogMessage "=========================================="

# Connect to Azure
if (-not (Connect-ToAzure)) {
    Write-LogMessage "Cannot proceed without Azure connection. Exiting." -Level 'ERROR'
    exit 1
}

Import-Module Az.NetAppFiles -ErrorAction Stop
Write-LogMessage "Az.NetAppFiles module loaded."

# Build export policy object (must be after Import-Module so types are available)
$exportPolicyRuleObjects = foreach ($rule in $exportPolicyRules) {
    New-Object -TypeName "Microsoft.Azure.Commands.NetAppFiles.Models.PSNetAppFilesExportPolicyRule" -Property $rule
}
$exportPolicy = New-Object -TypeName "Microsoft.Azure.Commands.NetAppFiles.Models.PSNetAppFilesVolumeExportPolicy"
$exportPolicy.Rules = $exportPolicyRuleObjects
Write-LogMessage "Export policy built ($($exportPolicyRuleObjects.Count) rules)."

# ==========================================
# Detect Pool QoS Types
# ==========================================
Write-LogMessage ""
Write-LogMessage "Checking QoS type for source pool '$SourcePoolName'..."
$sourcePool = Get-AzNetAppFilesPool -ResourceGroupName $SourceResourceGroup -AccountName $SourceAccountName -PoolName $SourcePoolName -ErrorAction Stop
$sourceQoS = $sourcePool.QosType  # "Auto" or "Manual"
Write-LogMessage "  Source pool '$SourcePoolName' QoS type: $sourceQoS"

Write-LogMessage "Checking QoS type for DR pool '$DRPoolName'..."
$drPool = Get-AzNetAppFilesPool -ResourceGroupName $DRResourceGroup -AccountName $DRAccountName -PoolName $DRPoolName -ErrorAction Stop
$drQoS = $drPool.QosType  # "Auto" or "Manual"
Write-LogMessage "  DR pool '$DRPoolName' QoS type: $drQoS"

if ($sourceQoS -eq 'Auto' -and $ThroughputMiBps -gt 0) {
    Write-LogMessage "  Source pool uses Auto QoS - ThroughputMibps will NOT be set (managed by pool)." -Level 'WARN'
}
if ($drQoS -eq 'Auto' -and $ThroughputMiBps -gt 0) {
    Write-LogMessage "  DR pool uses Auto QoS - ThroughputMibps will NOT be set (managed by pool)." -Level 'WARN'
}

# ==========================================
# STEP 1: Create Source Volume in EU2
# ==========================================
Write-LogMessage ""
Write-LogMessage ">>> STEP 1: Creating source volume '$SourceVolumeName' in $SourceLocation..."

try {
    # Check if source volume already exists
    $existingSource = Get-AzNetAppFilesVolume `
        -ResourceGroupName $SourceResourceGroup `
        -AccountName $SourceAccountName `
                -PoolName $SourcePoolName `
                -Name $SourceVolumeName `
                -ErrorAction SilentlyContinue

    if ($existingSource) {
        Write-LogMessage "Source volume '$SourceVolumeName' already exists (State: $($existingSource.ProvisioningState))." -Level 'WARN'
        $sourceVolume = $existingSource
    }
    else {
        if ($PSCmdlet.ShouldProcess("$SourceAccountName/$SourcePoolName/$SourceVolumeName", "Create Source Volume")) {
            # Build splatted parameters
            $sourceParams = @{
                ResourceGroupName = $SourceResourceGroup
                AccountName       = $SourceAccountName
                PoolName          = $SourcePoolName
                Name              = $SourceVolumeName
                Location          = $SourceLocation
                CreationToken     = $SourceVolumeName
                UsageThreshold    = $sizeInBytes
                ServiceLevel      = $ServiceLevel
                SubnetId          = $SourceSubnetId
                ProtocolType      = @('NFSv4.1', 'CIFS')
                SecurityStyle     = 'Ntfs'
                LdapEnabled       = $true
                NetworkFeature    = 'Standard'
                ExportPolicy      = $exportPolicy
                Tag               = @{
                    appIdOrProjectName = 'APP0000426'
                    appDepartment      = 'IT-Infrastructure'
                    environment        = 'TST'
                    appName            = 'NetApp OnTap'
                }
                ErrorAction       = 'Stop'
            }
            # Only set ThroughputMibps for Manual QoS pools
            if ($sourceQoS -eq 'Manual' -and $ThroughputMiBps -gt 0) {
                $sourceParams['ThroughputMibps'] = $ThroughputMiBps
                Write-LogMessage "  Setting ThroughputMibps = $ThroughputMiBps (Manual QoS)."
            } else {
                Write-LogMessage "  Skipping ThroughputMibps (Auto QoS - managed by pool)."
            }

            $sourceVolume = New-AzNetAppFilesVolume @sourceParams

            Write-LogMessage "Source volume creation command submitted." -Level 'SUCCESS'
        }
    }
}
catch {
    Write-LogMessage "Failed to create source volume: $_" -Level 'ERROR'
    exit 1
}

# Wait for source volume to be ready
if (-not $existingSource) {
    $sourceVolume = Wait-ForVolumeProvisioning `
        -ResourceGroupName $SourceResourceGroup `
        -AccountName $SourceAccountName `
        -PoolName $SourcePoolName `
        -VolumeName $SourceVolumeName

    if (-not $sourceVolume) {
        Write-LogMessage "Source volume creation failed. Cannot proceed with DR volume." -Level 'ERROR'
        exit 1
    }
}

$sourceVolumeId = $sourceVolume.Id
Write-LogMessage "Source Volume Resource ID: $sourceVolumeId"

# ==========================================
# STEP 2: Create DR (DataProtection) Volume in CUS
# ==========================================
Write-LogMessage ""
Write-LogMessage ">>> STEP 2: Creating DR volume '$DRVolumeName' in $DRLocation (DataProtection)..."

try {
    # Check if DR volume already exists
    $existingDR = Get-AzNetAppFilesVolume `
        -ResourceGroupName $DRResourceGroup `
        -AccountName $DRAccountName `
        -PoolName $DRPoolName `
        -Name $DRVolumeName `
        -ErrorAction SilentlyContinue

    if ($existingDR) {
        Write-LogMessage "DR volume '$DRVolumeName' already exists (State: $($existingDR.ProvisioningState))." -Level 'WARN'
    }
    else {
        # Build replication object for the DR volume
        $replicationObject = New-Object -TypeName "Microsoft.Azure.Commands.NetAppFiles.Models.PSNetAppFilesReplicationObject" -Property @{
            EndpointType           = 'Dst'
            RemoteVolumeResourceId = $sourceVolumeId
            ReplicationSchedule    = $ReplicationSchedule
        }

        if ($PSCmdlet.ShouldProcess("$DRAccountName/$DRPoolName/$DRVolumeName", "Create DR Volume")) {
            # Build splatted parameters
            $drParams = @{
                ResourceGroupName = $DRResourceGroup
                AccountName       = $DRAccountName
                PoolName          = $DRPoolName
                Name              = $DRVolumeName
                Location          = $DRLocation
                CreationToken     = $DRVolumeName
                UsageThreshold    = $sizeInBytes
                ServiceLevel      = $ServiceLevel
                SubnetId          = $DRSubnetId
                ProtocolType      = @('NFSv4.1', 'CIFS')
                SecurityStyle     = 'Ntfs'
                LdapEnabled       = $true
                NetworkFeature    = 'Standard'
                VolumeType        = 'DataProtection'
                ReplicationObject = $replicationObject
                ExportPolicy      = $exportPolicy
                Tag               = @{
                    appIdOrProjectName = 'APP0000426'
                    appDepartment      = 'IT-Infrastructure'
                    environment        = 'TST'
                    appName            = 'NetApp OnTap'
                }
                ErrorAction       = 'Stop'
            }
            # Only set ThroughputMibps for Manual QoS pools
            if ($drQoS -eq 'Manual' -and $ThroughputMiBps -gt 0) {
                $drParams['ThroughputMibps'] = $ThroughputMiBps
                Write-LogMessage "  Setting ThroughputMibps = $ThroughputMiBps (Manual QoS)."
            } else {
                Write-LogMessage "  Skipping ThroughputMibps for DR volume (Auto QoS - managed by pool)."
            }

            $drVolume = New-AzNetAppFilesVolume @drParams

            Write-LogMessage "DR volume creation command submitted." -Level 'SUCCESS'
        }
    }
}
catch {
    Write-LogMessage "Failed to create DR volume: $_" -Level 'ERROR'
    exit 1
}

# Wait for DR volume to be ready
if (-not $existingDR) {
    $drVolume = Wait-ForVolumeProvisioning `
        -ResourceGroupName $DRResourceGroup `
        -AccountName $DRAccountName `
        -PoolName $DRPoolName `
        -VolumeName $DRVolumeName

    if (-not $drVolume) {
        Write-LogMessage "DR volume creation failed." -Level 'ERROR'
        exit 1
    }
}

# ==========================================
# Summary
# ==========================================
Write-LogMessage ""
Write-LogMessage "=========================================="
Write-LogMessage "Volume Creation Summary"
Write-LogMessage "=========================================="
Write-LogMessage "Source Volume: $SourceVolumeName ($SourceLocation) - CREATED" -Level 'SUCCESS'
Write-LogMessage "  Resource ID: $sourceVolumeId"
Write-LogMessage "DR Volume   : $DRVolumeName ($DRLocation) - CREATED" -Level 'SUCCESS'
Write-LogMessage ""
Write-LogMessage "NEXT STEP: Run Establish-ANFReplication.ps1 to authorize replication from source."
Write-LogMessage "=========================================="
Write-LogMessage "Log file: $($script:LogFile)"

exit 0

#endregion
