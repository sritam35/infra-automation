# NAS & SAN Management Reference

## PreBackup Health Check (NAS/PreBackup-HealthCheck.ps1)
```powershell
# NIC & SMB session check before weekly SQL backup (run 15-30 min before)
$NIC     = "Ethernet 3"
$LIF_IP  = "10.201.29.211"
$Share   = "marprdbkp32_ha2a_smb\sqlbkp_prd03_sh$"

# Check 1: NIC Receive Buffer (target ≥ 4096)
$rxBuffer = (Get-NetAdapterAdvancedProperty -Name $NIC -RegistryKeyword "*ReceiveBuffers").RegistryValue
if ($rxBuffer -lt 4096) {
    Set-NetAdapterAdvancedProperty -Name $NIC -RegistryKeyword "*ReceiveBuffers" -RegistryValue 4096
}

# Check 2: NIC RxDrops (alert if > 500)
$rxDrops = (Get-NetAdapterStatistics -Name $NIC).ReceivedDiscardedPackets
if ($rxDrops -gt 500) { Write-Warning "RxDrops high: $rxDrops" }

# Check 3: SMB Session timing (drop and reconnect if > 5000ms or timeout)
$timer = [Diagnostics.Stopwatch]::StartNew()
try { $null = Test-Path "\\$LIF_IP\$Share" -ErrorAction Stop }
catch { $tooSlow = $true }
$timer.Stop()
if ($timer.ElapsedMilliseconds -gt 5000 -or $tooSlow) {
    Get-SmbMapping -RemotePath "\\$LIF_IP\*" | Remove-SmbMapping -Force
    ipconfig /flushDns; arp -d *
    New-SmbMapping -RemotePath "\\$LIF_IP\$Share"
}
```

## DFS Path Validation (NAS/DFS_Path_Validation/)
```powershell
# Test-DFSPath-New.ps1 — validates UNC path file I/O
$paths = Get-Content "C:\Temp\Pathlist.txt"
$results = foreach ($path in $paths) {
    [PSCustomObject]@{
        DFSPath      = $path
        IsAccessible = Test-Path $path
        CreateAction = try { New-Item "$path\TestFile.txt" -Force; $true } catch { $false }
        WriteAction  = try { "Test Write to File" | Out-File "$path\TestFile.txt"; $true } catch { $false }
        ReadAction   = try { Get-Content "$path\TestFile.txt"; $true } catch { $false }
        RemoveAction = try { Remove-Item "$path\TestFile.txt" -Force; $true } catch { $false }
    }
}
$results | Export-Csv "C:\Temp\PathlistResult.csv" -NoTypeInformation

# Input files per environment
# Pathlist.txt     — primary
# Pathlist_bed.txt — BED-NAS specific
# Pathlist_mar.txt — MAR-NAS specific
```

## Home Directory Provisioning (NAS/HomeDirectories/)
```powershell
# CreateHomeDirectories.ps1 — standard (AD-backed)
$shareRoot = "\\gmo\data\UserHome"
$users = Import-Csv "Users.csv"  # UPN per row

foreach ($user in $users) {
    $adUser = Get-ADUser -Filter "UserPrincipalName -eq '$($user.UPN)'" -Properties SamAccountName
    if (-not $adUser) { Write-Log "User not found: $($user.UPN)"; continue }

    $sam = $adUser.SamAccountName.ToLower()
    $homeDir = "$shareRoot\$sam"
    New-Item -Path $homeDir -ItemType Directory -Force

    # Grant user Modify permission
    $acl = Get-Acl $homeDir
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $adUser.SamAccountName, "Modify",
        "ContainerInherit,ObjectInherit", "None", "Allow"
    )
    $acl.AddAccessRule($rule)
    Set-Acl -Path $homeDir -AclObject $acl

    Write-Log "$($user.UPN),$sam,$homeDir,Success"
}

# CreateFoldersCustom.ps1 — enhanced with -Custom switch
# -Custom : bypass AD, create folders directly from name list
# -ConfigPath : input CSV (default: .\Users.csv)
# -SharePath  : target share (default: \\gmo\data\UserHome)
```

## NFS Validation (NAS/NFS_Validation/)
```bash
# BED_NAS/nfs_vol.sh — validate NFS volumes on BED cluster
while IFS= read -r vol; do
    mount_point="/mnt/${vol}"
    if mountpoint -q "$mount_point"; then
        df -h "$mount_point"
    else
        echo "NOT MOUNTED: $mount_point"
    fi
done < nfs_vol.txt

# MAR_NAS/mar_nfs_vol.sh — same pattern for Melbourne
```

## Share Temp Purge (NAS/Share_temp/)
```powershell
# sharetemp_purge.core.ps1 — removes stale files from temp shares
$retentionDays = 7
$tempShares = Get-SmbShare | Where-Object { $_.Name -match 'temp|tmp' }
foreach ($share in $tempShares) {
    Get-ChildItem -Path $share.Path -Recurse |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$retentionDays) } |
    Remove-Item -Force -Recurse
}
```

## SAN — VMware NVMe-oF Path Inventory (SAN/GetVMHostPaths.ps1)
```powershell
# Connect to vCenter and enumerate NVMe-over-Fabrics paths
Connect-VIServer -Server "usvc.gmo.tld"

$report = foreach ($vmhost in Get-VMHost | Where-Object { $_.Name -notmatch 'GDM' }) {
    $esxcli = Get-EsxCli -VMHost $vmhost -V2
    $adapters = $esxcli.storage.core.adapter.list.Invoke() |
                Where-Object { $_.Driver -eq 'nfnic' }

    foreach ($adapter in $adapters) {
        $paths = $esxcli.storage.core.path.list.Invoke(@{adapter = $adapter.HBAName})
        $paths | Group-Object -Property Device | ForEach-Object {
            [PSCustomObject]@{
                VMHost     = $vmhost.Name
                HBA        = $adapter.HBAName
                Device     = $_.Name
                "Path#"    = $_.Count
                PathStatus = ($_.Group.PathState | Sort-Object -Unique) -join ","
            }
        }
    }
}
$report | Export-Csv ".\report.csv" -NoTypeInformation -Delimiter (Get-Culture).TextInfo.ListSeparator
# Note: -UseCulture flag uses pipe delimiter on US-EN systems
```

## SAN — VMware FC Multipath Inventory (SAN/GetVmwareLunPaths.ps1)
```powershell
# Collect Fibre Channel LUN paths
Connect-VIServer -Server "usvc.gmo.tld"

$report = foreach ($vmhost in Get-VMHost) {
    $hbas = $vmhost | Get-VMHostHba -Type FibreChannel
    foreach ($hba in $hbas) {
        $targets = $hba | Get-ScsiLun
        [PSCustomObject]@{
            VMHost  = $vmhost.Name
            HBA     = $hba.Device
            Targets = ($targets | Select-Object -ExpandProperty CanonicalName).Count
            Devices = ($targets | Select-Object -ExpandProperty CanonicalName | Sort-Object -Unique).Count
            Paths   = ($targets | Measure-Object).Count
        }
    }
}
$report | Export-Csv ".\VmwareMultipath.csv" -NoTypeInformation
```

## OCUM NetApp Capacity Reports (NAS/Shell/)
```bash
# netapp_aggregate_capacity_report.sh
for CLUSTER in "${CLUSTERS[@]}"; do
    ssh admin@$CLUSTER "aggr show -fields aggregate,node,size,used,available,percent-used" \
        >> /mnt/global/nfs/storageautomation/outputs/aggr_capacity_$(date +%Y%m%d).csv
done

# netapp_volume_capacity_report.sh
for CLUSTER in "${CLUSTERS[@]}"; do
    ssh admin@$CLUSTER "volume show -fields vserver,volume,size,used,available,percent-used" \
        >> /mnt/global/nfs/storageautomation/outputs/vol_capacity_$(date +%Y%m%d).csv
done
```

## DFS-N + DFSR Deployment (DFS/dfsn-dfsr.ps1)
```powershell
# Full pipeline (create folders, shares, DFS root, DFS folder link, replication)
.\dfsn-dfsr -all `
    -servers "MARDEVTSTSRV001","BOSDEVTSTSRV001" `
    -localpath "C:\Path" `
    -sharename "Path Share" `
    -rootlocalpath "C:\DFSRoots\Path" `
    -rootsharename "Path Root Share" `
    -rootname "\\gmo.tld\Path" `
    -replicationgroup "Path Replication" `
    -stagingquota 30000

# Individual switches: -newFolders, -newShare, -newRoot, -newDfsFolder, -replication
# -distinctLocalPath: prompt for individual path per server
# -logPath: transcript location (default: DFSLog\dfs-{timestamp}.txt)
# Requires minimum 2 servers for replication
```
