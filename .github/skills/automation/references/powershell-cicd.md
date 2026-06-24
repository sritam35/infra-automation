# PowerShell Modules & CI/CD Reference

## Module Family
| Module | Version | Purpose |
|--------|---------|---------|
| `CorpMaintenance` | 1.8/1.9 | SCCM maintenance, package deployments |
| `CorpMaintV2` | 2.0 | Enhanced computer info + maintenance |
| `CorpComputerInfo` | 2.3.3/2.4.3 | Computer inventory + update management |

## CorpComputerInfo — Get-CorpComputerInfo Parameters
```powershell
Get-CorpComputerInfo `
    -ComputerList "file.txt|computerName|CollectionID" ` # Mandatory, pipeline-enabled
    -GetUserLastActiveDate (PrimaryUser|AdminUser|AnyUser) `
    -GetLastPatchDate `           # Switch; slow — warns user
    -CheckRequiredKB "KB1234567" `
    -CheckInstalledKB "KB1234567" ` # Slow — warns user
    -InstallMissingUpdates `       # Switch; triggers WMI install method
    -GetCDriveFreeSpace $true `    # Default $true
    -OutputFile `                  # Switch; export to CSV
    -OutPath "C:\Temp\CorpComputerInfo"

# CollectionID pattern: ^[A-Z]{3}\w{5}$  (e.g., CORP00001)
```

## CorpComputerInfo — Information Collected
```powershell
# Returns PSObject with:
[PSCustomObject]@{
    ComputerName    = $computer
    Enabled         = $adUser.Enabled      # AD enabled status
    LastUserLogon   = $adUser.LastLogonDate
    LastADChange    = $adUser.WhenChanged
    CanonicalName   = $adUser.CanonicalName
    OperatingSystem = $adUser.OperatingSystem
    PingStatus      = $pingResult
    Uptime          = $uptimeHours
    PendingReboot   = $pendingReboot
    MissingUpdates  = $missingCount        # from SCCM WMI
    CDriveSizeGB    = $cDriveSize
    CDriveFreeGB    = $cDriveFree
    LastPatchDate   = $lastPatch           # if -GetLastPatchDate
}
```

## CorpMaintenance — Install-CorpCMPackageOnDemand
```powershell
Install-CorpCMPackageOnDemand `
    -PackageID "CORP00001" `              # Mandatory
    -CollectionID "CORP00002" `           # Mandatory
    -ProgramName "Install" `             # Mandatory
    -DeletionTimeoutSec 300 `            # Default: 300s
    -InvokeCMActionPauseSec 60           # Default: 60s

# Lifecycle:
# 1. New-CMPackageDeployment (starts in 1 min, expires in 10h, Purpose=Required)
# 2. Invoke-CMClientAction (ClientNotificationRequestMachinePolicyNow)
# 3. Sleep DeletionTimeoutSec
# 4. Remove-CMPackageDeployment (auto-cleanup)
```

## SCCM ConfigMgr Module Import Pattern
```powershell
$cmPath = Join-Path $env:SMS_ADMIN_UI_PATH "..\ConfigurationManager.psd1"
if (Test-Path $cmPath) {
    Import-Module $cmPath -Force
    Set-Location "${env:CMSiteName}:\"
}
$Script:CMSiteServer = "bosinfprdmsc101.corp.example.com"
$Script:CMSiteName   = "CORP"
```

## Module Manifest Conventions (*.psd1)
```powershell
@{
    ModuleVersion     = '1.8.0'        # Replaced by CI: ReplaceVersion.ps1 → $env:BUILD_BUILDNUMBER
    GUID              = '20a6b573-...' # Fixed per module
    Author            = 'Matthew Johnston'
    CompanyName       = 'Your Company, LLC'
    ProcessorArchitecture = 'AMD64'
    PowerShellVersion = '3.0'
    RootModule        = 'CorpMaintenance.psm1'
    FunctionsToExport = '*'
    AliasesToExport   = @('KillDeployment', 'gwmisize', 'getdlsize')
    Tags              = @('Maintenance', 'SCCM', 'LocalGroup')
}
```

## ReplaceVersion.ps1 (CI version injection)
```powershell
# Pattern used in ALL modules
$file = "$PSScriptRoot\ModuleName.psd1"
(Get-Content $file) -replace "1.8.0", "$env:BUILD_BUILDNUMBER" | Out-File $file
# Placeholder: "1.8.0" in CorpMaintenance, "2.3.3" in CorpComputerInfo
```

## Pester Test Pattern (all modules use this)
```powershell
# tests/general.tests.ps1
Import-Module "$PSScriptRoot\..\modules\PSScriptAnalyzer" -Force

$files = Get-ChildItem -Path "$PSScriptRoot\.." -Recurse |
    Where-Object { $_.Extension -in '.psd1', '.psm1', '.ps1' }

foreach ($file in $files) {
    $type = switch ($file.Extension) {
        '.psd1' { 'Manifest' }
        '.psm1' { 'Module'   }
        '.ps1'  { 'Script'   }
    }
    Describe "$type: $($file.Name)" {
        $rules = Get-ScriptAnalyzerRule | Select-Object -ExpandProperty RuleName
        foreach ($rule in $rules) {
            It "passes rule: $rule" {
                $result = Invoke-ScriptAnalyzer -Path $file.FullName -IncludeRule $rule `
                          -ExcludeRule 'PSUseShouldProcessForStateChangingFunctions'
                $result.Count | Should -Be 0
            }
        }
    }
}
```

## Psake Build (Build/psakeBuild.ps1)
```powershell
Task Default -Depends Analyze, Test

Task Analyze {
    try {
        $results = Invoke-ScriptAnalyzer -Path $script -Severity @('Error','Warning') `
                   -Recurse -ExcludeRule 'PSReviewUnusedParameter'
        if ($results.Count -gt 0) {
            Write-Host "##vso[task.complete result=Failed;]DONE"
            throw "ScriptAnalyzer found $($results.Count) issues"
        }
    } catch { Write-Error $_; throw }
}

Task Test {
    try {
        $result = Invoke-Pester -Script @{
            Path       = $PSScriptRoot
            Parameters = @{ scriptname = $script }
        }
        if ($result.FailedCount -gt 0) {
            Write-Host "##vso[task.complete result=Failed;]DONE"
            throw "$($result.FailedCount) test(s) failed"
        }
    } catch { Write-Error $_; throw }
}
```

## Build Bootstrap (Build/build.ps1)
```powershell
# Ensure TLS 1.2 for NuGet/PSGallery
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not (Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue)) {
    Register-PSRepository -Default
}

foreach ($module in @('PSScriptAnalyzer', 'Pester', 'psake')) {
    if (-not (Get-Module -ListAvailable $module)) {
        Install-Module $module -Scope CurrentUser -Force
    }
}

Invoke-psake -buildFile "$SourceDir\build\psakeBuild.ps1" -taskList $Task
```

## Azure DevOps Pipeline Patterns
```yaml
# storage-automation-pipeline.yml
trigger:
  branches: { include: [master] }
  paths: { include: ['Automation/*'] }

steps:
- task: CopyFiles@2
  inputs:
    SourceFolder: Automation
    Contents: '**'
    TargetFolder: '\\fileserver\Build\DevOps\$(Build.DefinitionName)\$(Build.BuildNumber)'

- task: PublishBuildArtifacts@1
  inputs:
    ArtifactName: BuildDrop
```

## Azure VM Snapshot (DevOps_Maintenance/Azure/)
```powershell
# Create snapshot from OS disk
.\Manage-AZVMSnapshot -SubscriptionName CorpPrimary `
    -VMName Apawar-EU2 `
    -SnapshotName Snapshot-apawar-eu2 `
    -SnapshotResourceGroupName Snapshots-rg `
    -CreateSnapshot -Duration 10   # Max 14 days

# Internal: New-AzSnapshotConfig with -SourceUri from VM.StorageProfile.OsDisk.ManagedDisk.Id
# Parameter sets: CreateSnapshot | RestoreSnapshot | DeleteSnapshot
```

## Azure PIM Role Report (Azure/Get-AzPIMRoleAssignments.ps1)
```powershell
# Requires: Install-Module AzureADPreview -Force
Connect-AzureAD

$resources = Get-AzureADMSPrivilegedResource -ProviderId aadRoles
foreach ($resource in $resources) {
    $assignments = Get-AzureADMSPrivilegedRoleAssignment -ProviderId aadRoles -ResourceId $resource.Id
    foreach ($assignment in $assignments) {
        # Resolve subject type (User/Group/ServicePrincipal)
        $subject = Get-AzSubjectName -subjectid $assignment.SubjectId
        $roleName = Get-AzRoleName -resourceId $resource.Id -RoleDefinationId $assignment.RoleDefinitionId

        [PSCustomObject]@{
            Resource   = $resource.DisplayName
            Role       = $roleName
            Subject    = $subject
            Status     = $assignment.AssignmentState  # Active/Eligible
        }
    }
}
# Output: PIMRoleAssignments-{timestamp}.log (CSV)
```

## Module Aliases Reference
| Alias | Function | Module |
|-------|----------|--------|
| `KillDeployment` | Remove-SCCMDeployment | CorpMaintenance |
| `gwmisize` | Get-WMIObjectSize | CorpMaintenance |
| `getdlsize` | Get-DownloadSize | CorpMaintenance |
| `corpcomps` | Get-CorpComputerInfo | CorpComputerInfo |

## Exported Functions per Module
**CorpComputerInfo:** Get-CorpComputerInfo, Get-CorpMachineKBInfo, Get-CorpUserLogonStatus, Get-CorpPostProvisionValidation, Get-CorpCloudDesktopDeploymentInfo, Get-CorpWin7CompsFromEmail
