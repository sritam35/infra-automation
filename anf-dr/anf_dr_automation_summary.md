# ANF DR Automation — Project Summary

**Authors:** Storage Team
**Period:** February 19 – March 4, 2026
**Scope:** Azure NetApp Files Cross-Region Replication DR Automation + End-to-End DR Failover/Failback Test + Script Hardening & Automation (March 3)

---

## 1. Objective

Design and implement a fully automated, auditable set of PowerShell scripts to manage Disaster Recovery (DR) operations for Azure NetApp Files (ANF) cross-region replication between East US 2 (primary) and Central US (DR). The automation must:

- Disable the primary DFS namespace target before breaking replication (prevents client access to a stale volume)
- Break ANF replication to promote the DR volume to writable
- Enable the DR DFS namespace target so users/apps can failover to CUS
- On failback: reverse the DFS changes, resync replication back to source, restore client access
- Produce structured logs for every operation
- Require explicit confirmation before any destructive operation (resync)
- Be fully non-interactive when called from a pipeline (`-Force`)

---

## 2. Infrastructure Overview

### Azure Subscription
| Field | Value |
|---|---|
| Subscription Name | gmo-primary |
| Subscription ID | `<your-subscription-id>` |
| Tenant ID | `<your-tenant-id>` |

### Production Environment
| Role | Account | Resource Group | Pool |
|---|---|---|---|
| Source (EU2) | `anf-primary-account` | `eastus2-anf-primary-account-rg` | `quant_standard` |
| DR (CUS) | `anf-dr-account` | `centralus-anf-dr-account-rg` | `quant_standard` |

### Test Environment (used for DR test)
| Role | Account | Resource Group | Pool | QoS Type |
|---|---|---|---|---|
| Source (EU2) | `anf-primary-test-account` | `eastus2-anf-primary-test-account-rg` | `test_pool` | Manual |
| DR (CUS) | `anf-dr-test-account` | `centralus-anf-dr-test-account-rg` | `test` | **Auto** |

### DFS Namespace
| Field | Value |
|---|---|
| Namespace Server | `\\corp.example.com\TS2` (Domain V2, 5 root targets: AUE, ASH, MAR, EU2, CUS) |
| Test Folder | `\\corp.example.com\TS2\DR_Test` |
| EU2 Target | `\\anf-source.corp.example.com\eu2-dr-test` → IP `10.x.x.x` |
| CUS Target | `\\anf-dr.corp.example.com\cus-dr-test` → IP `100.x.x.x` |

### Stored Credential File
| Field | Value |
|---|---|
| Path | `~\.gmo_admin_cred.xml` (per-user) |
| Encryption | Windows DPAPI — tied to `smohanty` account on this machine only |
| Used by | `Manage-DFSPath.ps1` Enable/Disable actions (auto-loaded, no prompt) |
| Refresh command | `Get-Credential -UserName 'gmo\admin-username' \| Export-Clixml -Path "$env:USERPROFILE\.gmo_admin_cred.xml"` |

### Config CSV
| Field | Value |
|---|---|
| File | `ANF\DR\ANF_DR_Config.csv` |
| Columns | `Environment, DFSFolderPath, SourceTarget, DRTarget, VolumeName` |
| Purpose | Single source of truth — both Manage scripts read from this file when `-Environment` is passed |

### Permission Model Discovered During Testing
| Operation | Account Required | Reason |
|---|---|---|
| DFS target enable/disable | `gmo\admin-username` (via stored cred + local Start-Process) | `gmo\smohanty` lacks write delegation on DFS namespace |
| ANF BreakReplication / ResyncReplication | Elevated RBAC (Contributor or NetApp Account Contributor on `centralus-anf-dr-test-account-rg`) | Standard user lacks `breakReplication/action` on the DR resource group |
| DFS GetStatus | `gmo\smohanty` (current session) | Read-only; native RPC works without elevated rights |

---

## 3. Scripts Created

All scripts live in `ANF\DR\` and write structured logs to `ANF\DR\Logs\`.

---

### 3.1 `Get-DFSTargets.ps1`
**Purpose:** Read-only. Lists all DFS folder targets with their current Online/Offline state and attempts to show their AD site association.

**Key Notes:**
- Site column shows `(No site association)` for ANF endpoints — expected, ANF FQDN hostnames are not registered in AD Sites & Services. This is decorative only and not used for logic.
- Uses `dfsutil target` for site resolution then falls back gracefully.
- No changes made to DFS; purely informational.

**Usage:**
```powershell
.\Get-DFSTargets.ps1 -DFSFolderPath "\\corp.example.com\DR\test"
```

---

### 3.2 `Manage-DFSPath.ps1`
**Purpose:** Manage DFS folder targets — get status, enable, or disable. Used at every DFS step in both failover and failback. Get-DFSTargets.ps1 functionality was merged into this script as the `GetStatus` action (March 3).

**Design Decision (Site-Based → Direct Path):**
Initial design used site-based filtering. Abandoned because ANF FQDNs are not registered in AD Sites. Rewritten to use explicit target paths via `-TargetPaths`.

**Design Decision (Invoke-Command → Start-Process, March 3):**
DFS write operations require `admin-username` credentials. `Invoke-Command -ComputerName corp.example.com -Credential` and `New-CimSession` (both WinRM and DCOM) all return "Access is denied" due to WinRM restrictions in the environment. The GUI (DFS Management MMC) works because it uses native RPC/DCOM from the local process token. Solution: `Start-Process pwsh -Credential $adminCred` spawns a local PowerShell process running as `admin-username` — identical auth path to the GUI. An inner `.ps1` script is written to the Logs folder and executed by the spawned process.

**Credential Auto-Load (March 3):**
Credentials for `admin-username` are stored once via DPAPI (`Export-Clixml`) to `~\.gmo_admin_cred.xml`. The script auto-loads them on Enable/Disable — no interactive prompt needed. Falls back to `Get-Credential` if the file is missing.

**Key Parameters:**
| Parameter | Description |
|---|---|
| `-Action` | `GetStatus`, `Enable`, or `Disable` |
| `-Environment` | `Test` or `Production` — loads DFSFolderPath and DRTarget from `ANF_DR_Config.csv` (recommended) |
| `-ConfigFile` | Path to CSV config (default: script dir\`ANF_DR_Config.csv`) |
| `-DFSFolderPath` | Explicit UNC path to DFS folder (explicit mode, overrides CSV) |
| `-TargetPaths` | Explicit UNC target path(s) (explicit mode, required for Enable/Disable if no `-Environment`) |
| `-Credential` | PSCredential for Enable/Disable (auto-loaded from stored file if omitted) |
| `-Help` | Shows full colored help with DR workflow steps |

**Logging:** 4-step process per folder: retrieve targets → validate → apply via Start-Process → validate result.

**Usage (CSV mode — recommended):**
```powershell
# Get status of all Test environment DFS targets
.\Manage-DFSPath.ps1 -Action GetStatus -Environment Test

# Enable DR target (no credential prompt — auto-loaded)
.\Manage-DFSPath.ps1 -Action Enable -Environment Test

# Disable DR target
.\Manage-DFSPath.ps1 -Action Disable -Environment Production
```

**Usage (explicit mode):**
```powershell
.\Manage-DFSPath.ps1 -Action Enable -DFSFolderPath "\\corp.example.com\TS2\DR_Test" -TargetPaths "\\anf-dr.corp.example.com\cus-dr-test"
```

---

### 3.3 `Manage-ANFReplication.ps1`
**Purpose:** Core DR script. Manages ANF cross-region replication — get status, break (failover), or resync (failback).

**Key Parameters:**
| Parameter | Description |
|---|---|
| `-Action` | `GetStatus`, `BreakReplication`, or `ResyncReplication` |
| `-Environment` | `Production` (default) or `Test` — auto-sets account/RG/pool |
| `-VolumeNames` | Array of DR (destination) volume names |
| `-Force` | Skip interactive CONFIRM-RESYNC prompt (for pipeline/automation use) |
| `-WaitForCompletion` | Poll until resync reaches Mirrored state |
| `-MaxWaitMinutes` | Timeout for wait loop (default 120 min) |

**Environment Auto-Resolution (added Feb 25):**
A single `-Environment` switch sets the correct account, RG, and pool. Individual parameters still override if passed explicitly.

| `-Environment` | Source Account | DR Account | DR Pool |
|---|---|---|---|
| `Production` (default) | `anf-primary-account` | `anf-dr-account` | `quant_standard` |
| `Test` | `anf-primary-test-account` | `anf-dr-test-account` | `test` |

**CSV Auto-Load for VolumeNames (added March 3):**
When `-VolumeNames` is not passed, the script reads volume names from `ANF_DR_Config.csv` filtered by `-Environment`. This means no parameters other than `-Action` and `-Environment` are needed for standard operations.

**Help Switch (added March 3):**
`-Help` displays full colored help including syntax, parameters, environment defaults, examples, and the 6-step DR workflow. `-Action` and `-VolumeNames` are optional when `-Help` is used.

**Az.NetAppFiles Module Note (discovered March 3):**
Az.NetAppFiles v1.0.0 (installed during March 3 session) requires Az.Accounts 5.3.2+, which conflicts with the system-installed Az 12.5.0 already loaded in a running session. Workaround: always run this script in a **fresh `pwsh -NoProfile` subprocess** or a new terminal — do not run it in a session where the full Az module set is already loaded.

**Safety Design:**
- `GetStatus` and `BreakReplication` — no prompt, fire immediately
- `ResyncReplication` — requires typing `CONFIRM-RESYNC` at the prompt unless `-Force` is passed

**Usage (CSV mode — recommended, March 3+):**
```powershell
# Status check — no VolumeNames needed
.\Manage-ANFReplication.ps1 -Action GetStatus -Environment Test
.\Manage-ANFReplication.ps1 -Action GetStatus -Environment Production

# Break replication
.\Manage-ANFReplication.ps1 -Action BreakReplication -Environment Test

# Resync with -Force
.\Manage-ANFReplication.ps1 -Action ResyncReplication -Environment Test -Force
```

**Usage (explicit mode):**
```powershell
.\Manage-ANFReplication.ps1 -Action GetStatus -VolumeNames @("cus-b-prdopr")
.\Manage-ANFReplication.ps1 -Action BreakReplication -VolumeNames @("cus-b-prdopr")
.\Manage-ANFReplication.ps1 -Action ResyncReplication -VolumeNames @("cus-dr-test") -Force
```

---

### 3.4 `Create-ANFVolumes.ps1`
**Purpose:** Create test volumes — a standard source volume in EU2 and a DataProtection (replication destination) volume in CUS. Used once to set up the test environment.

**Key Design Fixes During Development:**
- **Auto QoS pool detection:** The CUS `test` pool is Auto QoS. Passing `-ThroughputMibps` to `New-AzNetAppFilesVolume` against an Auto QoS pool causes an error. The script detects pool QoS type and skips that parameter automatically.
- **Separate pool name parameters:** `SourcePoolName` and `DRPoolName` are separate parameters because the source pool (`test_pool`) and DR pool (`test`) have different names.
- **ExportPolicy type:** Must be wrapped in a `PSNetAppFilesVolumeExportPolicy` object, not passed as an array directly.
- **DataProtection volume:** Must use `-VolumeType "DataProtection"` plus a `-ReplicationObject` parameter (not `-DataProtection` as initially attempted).

**Usage:**
```powershell
.\Create-ANFVolumes.ps1 `
    -SourceResourceGroup "eastus2-anf-primary-test-account-rg" -SourceAccountName "anf-primary-test-account" -SourcePoolName "test_pool" `
    -DRResourceGroup "centralus-anf-dr-test-account-rg" -DRAccountName "anf-dr-test-account" -DRPoolName "test"
```

---

### 3.5 `Establish-ANFReplication.ps1`
**Purpose:** Authorize and establish cross-region replication from the source side after volumes are created. The source volume must authorize the destination before traffic flows.

**Key Design Fixes During Development:**
- **`Write-Log` → `Write-LogMessage`:** PowerShell Core has a built-in `Write-Log` command. Renamed to avoid conflict.
- **Variable parsing (colons in strings):** `"$SourcePoolName:"` was parsed incorrectly — fixed by using `$($SourcePoolName)` subexpressions.
- **Separate pool names:** Same as Create script — `SourcePoolName` and `DRPoolName` separated.
- **`-SubId` param for `Connect-ToAzure`:** Subscription ID passed explicitly to avoid interactive subscription picker.

**Usage:**
```powershell
.\Establish-ANFReplication.ps1 `
    -SourceResourceGroup "eastus2-anf-primary-test-account-rg" -SourceAccountName "anf-primary-test-account" -SourcePoolName "test_pool" `
    -DRResourceGroup "centralus-anf-dr-test-account-rg" -DRAccountName "anf-dr-test-account" -DRPoolName "test" `
    -VolumeNames @("eu2-dr-test")
```

---

## 4. Issues Encountered & Resolved

| # | Issue | Root Cause | Fix |
|---|---|---|---|
| 1 | Site-based DFS filtering unreliable | ANF FQDNs not registered in AD Sites & Services; `dfsutil` cannot resolve them | Removed site logic entirely; switched to direct `-TargetPaths` |
| 2 | Auto QoS pool rejects `-ThroughputMibps` | CUS `test` pool is Auto QoS — throughput is managed automatically | Added pool QoS detection; skip parameter for Auto QoS pools |
| 3 | Wrong pool names passed to DR | Source pool (`test_pool`) and DR pool (`test`) have different names | Split into `-SourcePoolName` and `-DRPoolName` parameters in all scripts |
| 4 | `Write-Log` cmdlet conflict | PowerShell Core has a built-in `Write-Log`; Establish script function shadowed it incorrectly | Renamed internal function to `Write-LogMessage` |
| 5 | Variable parsing error (`$PoolName:`) | PowerShell treats `:` as scope separator in `"$VarName:"` strings | Changed to `$($VarName)` subexpression syntax |
| 6 | Azure interactive subscription picker | `Connect-AzAccount` without `-SubscriptionId` shows a menu | Added `-SubscriptionId` to `Connect-AzAccount` call |
| 7 | `-DataProtection` parameter doesn't exist | API changed — `New-AzNetAppFilesVolume` uses `-VolumeType "DataProtection"` + `-ReplicationObject` | Fixed parameter names |
| 8 | `ExportPolicy` type mismatch | Must pass a `PSNetAppFilesVolumeExportPolicy` wrapper object, not a raw array | Constructed proper typed object |
| 9 | `Suspend/Resume-AzNetAppFilesReplication` prompts "yes" in portal or low `$ConfirmPreference` | Azure cmdlets have built-in `ShouldProcess` with high-impact confirmation | Added `-Confirm:$false` to both cmdlets |
| 10 | `ShouldProcess` in internal functions caused mid-automation prompts | Internal helper functions inherited parent script's `SupportsShouldProcess`; if `$ConfirmPreference` was low, they would prompt | Removed `ShouldProcess` wrappers from internal functions entirely |
| 11 | `gmo\smohanty` cannot change DFS target state | Account lacks write delegation on `\\corp.example.com\DR` namespace | Must use `service-Backup` / `admin-username` session for all DFS changes |
| 12 | `gmo\smohanty` cannot break ANF replication | Lacks `breakReplication/action` RBAC on `centralus-anf-dr-test-account-rg` | Elevated role (Contributor/NetApp Account Contributor) via PIM required |
| 13 | DNS not resolving `anf-source.corp.example.com` from workstation | Workstation DNS set to public resolvers (`75.75.75.75`) not Infoblox | Registered A record in Infoblox; corporate machines resolve correctly. Workstation resolved via Comcast DNS cache after flush |
| 14 | Inconsistent script defaults (mixed test/prod) | `DRResourceGroup` pointed to test RG but `DRAccountName` was production account | Added `-Environment` switch with proper per-environment defaults; `$PSBoundParameters` used to allow individual overrides |
| 15 | Resync aborted — typed `yes` instead of `CONFIRM-RESYNC` | Script requires exact string to prevent accidental data loss | Re-ran with `-Force` flag |
| 16 | `Invoke-Command -ComputerName corp.example.com -Credential admin-username` → "Access is denied" | WinRM is restricted in the environment; outbound WinRM to domain controllers/DFS servers is blocked for standard accounts | Replaced with `Start-Process pwsh -Credential` — spawns local process as admin-username using native RPC (identical to DFS Management GUI) |
| 17 | `New-CimSession -Protocol Dcom -Credential admin-username` → "Access is denied" | DCOM also blocked for explicit credentials across the network in this environment | Same fix as #16 — local Start-Process |
| 18 | Az.NetAppFiles v1.0.0 conflicts with system Az 12.5.0 in running session | Az.NetAppFiles 1.0.0 requires Az.Accounts 5.3.2+; Az 12.5.0 already loaded in session pins older Az.Accounts | Run Manage-ANFReplication.ps1 in a fresh `pwsh -NoProfile` subprocess — no conflicting modules pre-loaded |
| 19 | Az.NetAppFiles module not installed | Module absent from system | `Install-Module Az.NetAppFiles -Force -AllowClobber -Scope CurrentUser` — installed v1.0.0 |
| 20 | `Set-DfsnFolderTarget` as `smohanty` → "Access to a CIM resource was not available" | `smohanty` lacks DFS namespace write delegation | Must run DFS writes as `admin-username` — stored credential + Start-Process approach |
| 21 | Manage-DFSPath.ps1 not on disk after editing in VS Code | File existed only in VS Code editor buffer; `workbench.action.files.saveAll` did not persist it to disk | Recreated via `create_file` tool — file now on disk and tracked by git |

---

## 5. DR Failover/Failback Test — February 20, 2026

### Test Setup
- Source volume: `eu2-dr-test` on `anf-primary-test-account/test_pool` (EU2)
- DR volume: `cus-dr-test` on `anf-dr-test-account/test` (CUS) — DataProtection type
- DFS folder: `\\corp.example.com\DR\test` with both targets registered
- DNS: `anf-source.corp.example.com` → `10.x.x.x` registered in Infoblox
- Test file pre-written to EU2 source: `DR-Test-File.txt` (79 bytes)
- Replication established via `Establish-ANFReplication.ps1`; reached **Mirrored** state in ~5.5 minutes

---

### Step-by-Step Execution

#### Step 1 — GetStatus (Pre-Check)
```
MirrorState: Mirrored | RelationshipStatus: Idle | Healthy: True | TotalProgress: 87,852 bytes
```
✅ Healthy, ready for failover.

---

#### Step 2 — Disable Source DFS Target
Action: Set `\\anf-source.corp.example.com\eu2-dr-test` to Offline
Run from: `service-Backup` session (gmo\smohanty lacks DFS delegation)
```powershell
Set-DfsnFolderTarget -Path "\\corp.example.com\DR\test" -TargetPath "\\anf-source.corp.example.com\eu2-dr-test" -State Offline
```
✅ EU2 target Offline — clients can no longer reach primary volume.

---

#### Step 3 — Break Replication
```powershell
.\Manage-ANFReplication.ps1 -Action BreakReplication -Environment Test -VolumeNames @('cus-dr-test')
```
**First attempt failed** — `gmo\smohanty` did not have `breakReplication/action` RBAC. Re-ran after elevating role via PIM (~2 minute propagation + reconnect).
```
PreState: Mirrored → PostState: Broken | Status: Success
```
✅ CUS volume is now writable (no longer a read-only replica).

---

#### Step 4 — Enable DR DFS Target
Action: Set `\\anf-dr.corp.example.com\cus-dr-test` to Online
Run from: `service-Backup` session
```powershell
Set-DfsnFolderTarget -Path "\\corp.example.com\DR\test" -TargetPath "\\anf-dr.corp.example.com\cus-dr-test" -State Online
```
✅ CUS target Online — clients now route to DR volume.

---

#### Step 5 — Verify Replicated Data on DR Volume
```powershell
Get-ChildItem "\\anf-dr.corp.example.com\cus-dr-test" | Format-Table Name, Length, LastWriteTime -AutoSize
Get-Content "\\anf-dr.corp.example.com\cus-dr-test\DR-Test-File.txt"
```
```
Name             Length LastWriteTime
DR-Test-File.txt     79 2/20/2026 12:29:52 PM

This is a DR test file created on 2026-02-20 12:29:51 from EU2 source volume.
```
✅ Replicated data confirmed present on CUS DR volume.

---

#### Data Loss Proof — Write Post-Break File to DR Volume
To demonstrate that data written to the DR volume during the break period is lost on resync:
```powershell
"This file was written to the DR volume (CUS) on 2026-02-20 13:08:22 AFTER replication break. This will be DELETED after resync." | Set-Content "\\anf-dr.corp.example.com\cus-dr-test\DR-Only-File.txt"
```
```
Name             Length LastWriteTime
DR-Only-File.txt    129 2/20/2026 1:08:22 PM
DR-Test-File.txt     79 2/20/2026 12:29:52 PM
```

---

#### Step 6 — Disable DR DFS Target (Failback begins)
Run from: `service-Backup` session
```powershell
Set-DfsnFolderTarget -Path "\\corp.example.com\DR\test" -TargetPath "\\anf-dr.corp.example.com\cus-dr-test" -State Offline
```
✅ CUS target Offline — clients disconnected from DR volume before resync.

---

#### Step 7 — Resync Replication
**First attempt:** Typed `yes` instead of `CONFIRM-RESYNC` → script correctly aborted.
**Second attempt:** Used `-Force` flag to bypass prompt.
```powershell
.\Manage-ANFReplication.ps1 -Action ResyncReplication -Environment Test -VolumeNames @('cus-dr-test') -Force
```
```
PreState: Broken → PostState: Mirrored | Status: Success
TotalProgress: 121,568 bytes
```
✅ Resync complete. CUS volume is back to a read-only replica of EU2 source.

---

#### Data Loss Confirmed
```powershell
Get-ChildItem "\\anf-dr.corp.example.com\cus-dr-test" | Format-Table Name, Length, LastWriteTime -AutoSize
```
```
Name             Length LastWriteTime
DR-Test-File.txt     79 2/20/2026 12:29:52 PM
```
`DR-Only-File.txt` (the file written during the break) is **gone** — overwritten by the resync from EU2 source. This proves that any data written to the DR volume during the break period is permanently lost when replication resync occurs.

---

#### Step 8 — Re-enable Source DFS Target
Run from: `service-Backup` session
```powershell
Set-DfsnFolderTarget -Path "\\corp.example.com\DR\test" -TargetPath "\\anf-source.corp.example.com\eu2-dr-test" -State Online
```
```
Path              TargetPath                     State  ReferralPriorityClass
\\corp.example.com\DR\test \\anf-source.corp.example.com\eu2-dr-test Online sitecost-normal
```
✅ EU2 source restored. Clients back to primary volume. DR test complete.

---

### Test Result Summary

| Step | Action | Tool / Account | Result |
|---|---|---|---|
| 1 | GetStatus | Manage-ANFReplication.ps1 | Mirrored, Healthy ✅ |
| 2 | Disable source DFS (EU2) | service-Backup session | Offline ✅ |
| 3 | Break replication | Manage-ANFReplication.ps1 (elevated) | Broken ✅ |
| 4 | Enable DR DFS (CUS) | service-Backup session | Online ✅ |
| 5 | Verify data on DR volume | Direct UNC access | DR-Test-File.txt present ✅ |
| — | Write DR-Only-File.txt | Direct UNC write | 129 bytes written ✅ |
| 6 | Disable DR DFS (CUS) | service-Backup session | Offline ✅ |
| 7 | Resync replication | Manage-ANFReplication.ps1 -Force | Mirrored ✅ |
| — | Verify data loss | Direct UNC access | DR-Only-File.txt gone ✅ |
| 8 | Re-enable source DFS (EU2) | service-Backup session | Online ✅ |

**Total failover-to-failback duration:** ~55 minutes (including permission troubleshooting and manual steps; actual automation runtime ~3–5 minutes per step)

---

## 6. Script Improvements Made Over Time

| Date | Script | Change |
|---|---|---|
| Feb 19 | Manage-DFSPath.ps1 | Rewrote from site-based filtering to direct `-TargetPaths` |
| Feb 19 | Manage-ANFReplication.ps1 | Added `-Confirm:$false` to `Suspend-` and `Resume-AzNetAppFilesReplication` |
| Feb 19 | Establish-ANFReplication.ps1 | Renamed `Write-Log` → `Write-LogMessage`; fixed `$()` subexpressions; separated pool name params |
| Feb 19 | Create-ANFVolumes.ps1 | Added Auto QoS pool detection; splatted params; fixed ExportPolicy type |
| Feb 20 | Manage-ANFReplication.ps1 | Removed `ShouldProcess` wrappers from `Invoke-BreakReplication` and `Invoke-ResyncReplication`; removed `SupportsShouldProcess` from `[CmdletBinding]` |
| Feb 25 | Manage-ANFReplication.ps1 | Added `-Environment` switch (Test/Production); fixed inconsistent defaults; added `Environment` line to log banner |
| Mar 3 | Manage-DFSPath.ps1 | Merged `Get-DFSTargets.ps1` functionality as `GetStatus` action; `-DFSFolderPath` and `-TargetPaths` no longer mandatory at param level (validated in body) |
| Mar 3 | Manage-DFSPath.ps1 | Replaced `Invoke-Command -ComputerName` with `Start-Process pwsh -Credential` approach (local process impersonation) to bypass WinRM restrictions |
| Mar 3 | Manage-DFSPath.ps1 | Added `-Help` switch with full colored help output and DR workflow steps |
| Mar 3 | Manage-DFSPath.ps1 | Added `-Environment` and `-ConfigFile` parameters; script now reads `DFSFolderPath` and `DRTarget` from `ANF_DR_Config.csv` when `-Environment` is passed |
| Mar 3 | Manage-DFSPath.ps1 | Added DPAPI stored credential auto-load from `~\.gmo_admin_cred.xml`; falls back to `Get-Credential` prompt if file absent |
| Mar 3 | Manage-ANFReplication.ps1 | Added `-Help` switch with full colored help; `-Action` and `-VolumeNames` made optional at param level |
| Mar 3 | Manage-ANFReplication.ps1 | Added `-ConfigFile` parameter; auto-loads `VolumeNames` from `ANF_DR_Config.csv` when not explicitly passed |
| Mar 3 | ANF_DR_Config.csv | Created new config file with 5 columns: `Environment, DFSFolderPath, SourceTarget, DRTarget, VolumeName` — single source of truth for all DR target/volume mappings |
| Mar 3 | All scripts | Live-tested Enable/Disable/GetStatus (DFS) and GetStatus (ANF) successfully against Test environment |

---

## 7. Operational Runbook — DR Failover

### Prerequisites
- Stored credential at `~\.gmo_admin_cred.xml` (run once: `Get-Credential -UserName 'gmo\admin-username' | Export-Clixml -Path "$env:USERPROFILE\.gmo_admin_cred.xml"`)
- Elevated RBAC on `centralus-anf-dr-account-rg` for ANF break/resync (via PIM if needed)
- `Az.NetAppFiles` module installed: `Get-Module -ListAvailable Az.NetAppFiles`
- Run ANF scripts in a **fresh terminal** (avoid sessions with Az 12.5.0 pre-loaded)
- CSV config up to date: `ANF\DR\ANF_DR_Config.csv`

### Failover (Primary EU2 → DR CUS)
```powershell
# 1. Pre-check replication status
.\Manage-ANFReplication.ps1 -Action GetStatus -Environment Production

# 2. Disable source DFS target (no credential prompt — uses stored cred)
.\Manage-DFSPath.ps1 -Action Disable -Environment Production

# 3. Break replication (makes CUS volume writable)
.\Manage-ANFReplication.ps1 -Action BreakReplication -Environment Production

# 4. Enable DR DFS target
.\Manage-DFSPath.ps1 -Action Enable -Environment Production

# 5. Verify DFS state and data on DR
.\Manage-DFSPath.ps1 -Action GetStatus -Environment Production
```

### Failback (DR CUS → Primary EU2)
```powershell
# 6. Disable DR DFS target
.\Manage-DFSPath.ps1 -Action Disable -Environment Production

# 7. Resync replication — WARNING: data written to DR during break is PERMANENTLY LOST
.\Manage-ANFReplication.ps1 -Action ResyncReplication -Environment Production
# Type CONFIRM-RESYNC at prompt, or add -Force for pipeline use

# 8. Re-enable source DFS target
.\Manage-DFSPath.ps1 -Action Enable -Environment Production

# 9. Confirm final state
.\Manage-ANFReplication.ps1 -Action GetStatus -Environment Production
.\Manage-DFSPath.ps1 -Action GetStatus -Environment Production
```

### Config File — `ANF_DR_Config.csv`
Update this file to add new DR volume pairs. No script changes needed.

```csv
Environment,DFSFolderPath,SourceTarget,DRTarget,VolumeName
Test,\\corp.example.com\TS2\DR_Test,\\anf-source.corp.example.com\eu2-dr-test,\\anf-dr.corp.example.com\cus-dr-test,cus-dr-test
Production,\\corp.example.com\<namespace>\<folder>,\\<eu2-anf>\<share>,\\<cus-anf>\<share>,<volume-name>
```

**Column guide:**
| Column | Description |
|---|---|
| `Environment` | `Test` or `Production` — matched by `-Environment` param |
| `DFSFolderPath` | UNC path to the DFS namespace folder |
| `SourceTarget` | EU2 (primary) DFS target UNC — referenced for documentation/GetStatus |
| `DRTarget` | CUS (DR) DFS target UNC — this is what Enable/Disable acts on |
| `VolumeName` | ANF DR volume name — loaded by `Manage-ANFReplication.ps1` |

---

## 8. Important Notes & Warnings

> **DATA LOSS WARNING:** Resyncing replication overwrites the DR volume with a fresh copy from the source. Any data written to the DR volume after the replication break is **permanently deleted**. Before running ResyncReplication, ensure all critical data has been exported or migrated back to the source volume.

> **DFS Permission Requirement:** DFS write operations (Enable/Disable) require `gmo\admin-username`. The script auto-loads the stored DPAPI credential from `~\.gmo_admin_cred.xml` — no interactive prompt. Internally, it spawns a local `pwsh` process as `admin-username` using `Start-Process -Credential` (native RPC, same as DFS Management GUI). `Invoke-Command` and `CimSession` are not used — both are blocked by WinRM restrictions in this environment.

> **RBAC Requirement:** Breaking and resyncing ANF replication requires `Microsoft.NetApp/netAppAccounts/capacityPools/volumes/breakReplication/action` on the DR resource group. If not already assigned, activate via PIM and wait ~2 minutes before reconnecting (`Connect-AzAccount`).

> **Az Module Conflict:** `Az.NetAppFiles` v1.0.0 requires `Az.Accounts` 5.3.2+. The system Az 12.5.0 bundle pins an older version. Always run `Manage-ANFReplication.ps1` in a fresh `pwsh -NoProfile` terminal. Do not run it in a session where the full Az module suite is already loaded.

> **Stored Credential Refresh:** If `admin-username` password changes, refresh the stored credential: `Get-Credential -UserName 'gmo\admin-username' | Export-Clixml -Path "$env:USERPROFILE\.gmo_admin_cred.xml"`. The file is DPAPI-encrypted — only `smohanty` on this machine can read it.

> **DNS Note:** ANF volume FQDNs (e.g. `anf-source.corp.example.com`) are registered in Infoblox. Workstations using public DNS resolvers (Comcast: `75.75.75.75`) may not resolve them. Corporate machines using Infoblox (`10.200.249.10`) resolve correctly. DFS path access via `\\corp.example.com\TS2\...` works regardless as the DFS server handles resolution.

> **CSV Config:** Both manage scripts load their targets/volumes from `ANF_DR_Config.csv` when `-Environment` is passed. Keep this file up to date as new DR volume pairs are provisioned. The ANF account/RG/pool details remain hardcoded in the scripts' environment defaults — only path/volume mappings go in the CSV.
