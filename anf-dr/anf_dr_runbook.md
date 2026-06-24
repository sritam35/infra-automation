# Azure NetApp Files — DR Failover & Failback Runbook

---

## Table of Contents

1. [Document History](#document-history)
2. [Introduction](#introduction)
3. [Prerequisites](#prerequisites)
4. [Architecture Overview](#architecture-overview)
5. [Checking DR Status (At Any Time)](#checking-dr-status-at-any-time)
6. [DR Failover — Phase 1](#dr-failover--phase-1)
   - [Using the Automated Script](#failover-using-the-automated-script)
   - [Using Azure Portal + Manual PowerShell](#failover-using-azure-portal--manual-powershell)
7. [DR Failback — Phase 2](#dr-failback--phase-2)
   - [Using the Automated Script](#failback-using-the-automated-script)
   - [Using Azure Portal + Manual PowerShell](#failback-using-azure-portal--manual-powershell)
8. [Notes & Limitations](#notes--limitations)
9. [Useful Links](#useful-links)

---

## Document History

| Date        | Version | Description      | Author          |
|-------------|---------|------------------|-----------------|
| 18 Mar 2026 | v1.0    | Initial creation | Sritam Mohanty  |

---

## Introduction

This document details the process of failing over Azure NetApp Files (ANF) volumes from the primary write region (East US 2) to the DR region (Central US) in the event of a regional failure or for planned DR testing. It also covers the failback process to restore normal operations.

ANF uses **Cross-Region Replication (CRR)** to asynchronously replicate volumes from a source region to a destination (DR) region. During normal operation the DR volume is read-only. During a DR event the replication is broken to promote the DR volume to read/write, and DFS namespace targets are updated so users and applications transparently connect to the DR volume.

The automation scripts in this folder orchestrate all steps in the correct sequence, with structured logging and visual output.

> **NOTE:** Resyncing replication during failback will permanently discard any data written to the DR volume during the break period. Ensure the application team has completed all testing and migrated any required data back to the source before initiating failback.

---

## Prerequisites

- PowerShell 7 (`pwsh`) installed on the machine running the scripts
- `Az` PowerShell module installed (`Install-Module Az`)
- DFS Management RSAT tools installed on the machine
- Stored credential file `~\.admin_cred.xml` present (see setup note below)
- Azure login context present (`Connect-AzAccount` run at least once)
- Network access to Azure APIs and the DFS/ANF UNC paths
- Contributor or Owner role on the ANF subscription
- DFS admin rights (`corp\admin-<username>`)

**One-time credential setup (per user, per machine):**

```powershell
# Save DFS admin credential (only needs to be done once per machine)
Get-Credential -Message "Enter corp\admin-<username>" |
    Export-Clixml -Path "$HOME\.admin_cred.xml"

# Save Azure login context
Connect-AzAccount
```

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                    DFS Namespace: \\corp.example.com\TS2                 │
│                                                                 │
│   \\corp.example.com\TS2\<FolderName>                                    │
│        │                                                        │
│        ├── \\anf-XXXX.corp.example.com\<volume>  (EU2 Source)  ◄──────┐ │
│        └── \\anf-XXXX.corp.example.com\<volume>  (CUS DR)             │ │
└──────────────────────────────────────────────────────────────│─┘
                                                               │
┌─────────────────────────┐      CRR Replication      ┌───────┴───────────────┐
│   East US 2 (Primary)   │ ─────────────────────────► │  Central US (DR)      │
│                         │                            │                       │
│   ANF Account: eu2*anf  │                            │   ANF Account: cus*anf│
│   Pool / Volume         │                            │   Pool / Volume       │
│   (Read/Write)          │                            │   (Read-Only mirror)  │
└─────────────────────────┘                            └───────────────────────┘
```

**Steady state:** EU2 DFS target is Online, CUS DFS target is Offline, ANF replication is Mirrored.

**During DR:** EU2 DFS target is Offline, CUS DFS target is Online, ANF replication is Broken (DR volume is read/write).

### Config File

All environments, DFS folders, and volume mappings are defined in a single CSV:

```
ANF\DR\ANF_DR_Config.csv
```

| Column         | Description                                    |
|----------------|------------------------------------------------|
| `Environment`  | `Production` or `Test`                         |
| `DFSFolderPath`| UNC path to the DFS namespace folder           |
| `SourceTarget` | UNC path to the EU2 (primary) DFS share        |
| `DRTarget`     | UNC path to the CUS (DR) DFS share             |

> The volume name is derived automatically from the last segment of `DRTarget`.

### Scripts

| Script                     | Purpose                                              |
|----------------------------|------------------------------------------------------|
| `Get-DR-Status.ps1`        | Read-only dashboard — DFS and ANF status at a glance |
| `Invoke-DR-Failover.ps1`   | Phase 1: Pre-check → Disable EU2 → Break ANF → Enable CUS |
| `Invoke-DR-Failback.ps1`   | Phase 2: Disable CUS → Resync ANF → Enable EU2 → Verify |
| `Manage-DFSPath.ps1`       | Low-level DFS enable/disable with auto-detect        |
| `Manage-ANFReplication.ps1`| Low-level ANF break/resync/status                    |

---

## Checking DR Status (At Any Time)

Run this at any point to see a visual dashboard of current DFS target states and ANF replication health across all configured environments.

```powershell
cd C:\Azure_Devops\Storage\ANF\DR

# All environments:
.\Get-DR-Status.ps1

# Specific environment:
.\Get-DR-Status.ps1 -Environment Production
.\Get-DR-Status.ps1 -Environment Test
```

**Example output (steady state):**

```
  ╔══════════════════════════════════════════════════════════════════════════╗
  ║           ANF DR STATUS DASHBOARD                                       ║
  ║           2026-03-18 10:00:00                                            ║
  ╚══════════════════════════════════════════════════════════════════════════╝

  ══════════════════════════════════════════════════════════════════════════
                          Environment: Production
  ══════════════════════════════════════════════════════════════════════════

  DFS Namespace Targets
  ──────────────────────────────────────────────────────────────────────────
  St    Role         UNC Path                                   State      Serving Traffic?
  ──────────────────────────────────────────────────────────────────────────
  [v]   EU2 Source   \\anf-XXXX.corp.example.com\<volume>               Online     YES  <--
  [ ]   CUS DR       \\anf-XXXX.corp.example.com\<volume>               Offline    no

  ANF Replication
  ──────────────────────────────────────────────────────────────────────────
  St    Volume                       MirrorState    Relationship   Healthy  Note
  ──────────────────────────────────────────────────────────────────────────
  [v]   <volume>                     Mirrored       Idle           True     Steady state — replicating

  [v] Production — All checks OK
```

**Status indicators:**

| Symbol | Colour | Meaning                                          |
|--------|--------|--------------------------------------------------|
| `[v]`  | Green  | Healthy / expected state                         |
| `[ ]`  | Gray   | Offline (normal for DR standby volume)           |
| `[!]`  | Yellow | ANF Broken — DR is active, volume is read/write  |
| `[?]`  | Yellow | State could not be determined                    |
| `[X]`  | Red    | Unexpected state — requires attention            |

> **[Screenshot placeholder — steady state dashboard output]**

---

## DR Failover — Phase 1

Failover takes the EU2 source offline, promotes the CUS DR volume to read/write, and updates DFS so users connect to CUS. After this phase the application team can begin DR testing.

### Failover — Steps Overview

| Step | Action                                | Script               |
|------|---------------------------------------|----------------------|
| 1    | Pre-check: verify DFS and ANF state   | auto                 |
| 2    | Disable EU2 DFS target (auto-detected)| `Manage-DFSPath.ps1` |
| 3    | Break ANF CRR replication             | `Manage-ANFReplication.ps1` |
| 4    | Enable CUS DR DFS target + verify     | `Manage-DFSPath.ps1` |

### Failover — Using the Automated Script

```powershell
cd C:\Azure_Devops\Storage\ANF\DR

# Production (prompts for confirmation before breaking replication):
.\Invoke-DR-Failover.ps1 -Environment Production

# Test (suppress prompts):
.\Invoke-DR-Failover.ps1 -Environment Test -Force
```

The script will print clean step progress and a visual summary at the end:

```
  DFS Target Status
  ──────────────────────────────────────────────────────────────────────────
  [v]   EU2 Source   \\anf-XXXX.corp.example.com\<volume>               Offline
  [v]   CUS DR       \\anf-XXXX.corp.example.com\<volume>               Online

  ANF Replication
  ──────────────────────────────────────────────────────────────────────────
  [v]   Volume: <volume>   MirrorState=Broken  Relationship=Idle  Healthy=True

  FAILOVER COMPLETE — APP TEAM CAN BEGIN TESTING
  [v] All checks passed. DR volume is live and accessible.
```

> `MirrorState=Broken` is the **expected and correct** state after failover — it means the DR volume is read/write and independent of the source.

> **[Screenshot placeholder — failover script console output]**

When the script completes, hand off to the application team. When they confirm testing is done, proceed to Phase 2.

Logs are written to: `ANF\DR\Logs\DR-Failover-<Environment>-<timestamp>.log`

---

### Failover — Using Azure Portal + Manual PowerShell

Use this as a fallback if the automated script cannot be run.

#### Step 1 — Verify pre-state (PowerShell)

```powershell
# Check DFS targets
.\Manage-DFSPath.ps1 -Action GetStatus -Environment Production

# Check ANF replication
pwsh -NoProfile -Command "& '.\Manage-ANFReplication.ps1' -Action GetStatus -Environment Production"
```

Confirm EU2 is Online and ANF is Mirrored before proceeding.

#### Step 2 — Disable EU2 DFS target (PowerShell)

```powershell
.\Manage-DFSPath.ps1 -Action Disable -Environment Production
```

The script auto-detects which target is Online and disables it.

#### Step 3 — Break ANF replication (Azure Portal)

> **[Screenshot placeholder — ANF volume CRR blade]**

1. In the Azure Portal, navigate to the **ANF DR account** (Central US)
2. Select the **Capacity Pool** → open the **replicated volume**
3. Under **Replication**, click **Break Peering**
4. Read and accept the warning — the DR volume will become read/write and will stop receiving updates from the source
5. Click **OK**
6. Wait for the volume status to show **Broken** (usually under 2 minutes)

> **[Screenshot placeholder — Break Peering confirmation dialog]**

Alternatively via PowerShell:

```powershell
pwsh -NoProfile -Command "& '.\Manage-ANFReplication.ps1' -Action BreakReplication -Environment Production"
```

#### Step 4 — Enable CUS DR DFS target (PowerShell)

```powershell
.\Manage-DFSPath.ps1 -Action Enable -Environment Production
```

The script reads the state file written in Step 2 and automatically enables the correct target (CUS DR).

---

## DR Failback — Phase 2

Failback takes the CUS DR volume offline, re-establishes replication back to EU2, and restores user access to the EU2 source. Run this only after the application team confirms DR testing is complete.

> ⚠️ **WARNING:** Resyncing replication will permanently discard all data written to the DR volume during the break period. Ensure the application team has finished testing and any required data has been migrated back to EU2 before proceeding.

### Failback — Steps Overview

| Step | Action                                     | Script               |
|------|--------------------------------------------|----------------------|
| 1    | Disable CUS DR DFS target (auto-detected)  | `Manage-DFSPath.ps1` |
| 2    | Resync ANF CRR replication (DR → read-only)| `Manage-ANFReplication.ps1` |
| 3    | Enable EU2 DFS target (Failback auto-detected) | `Manage-DFSPath.ps1` |
| 4    | Final verification — DFS & ANF steady state| auto                 |

### Failback — Using the Automated Script

```powershell
cd C:\Azure_Devops\Storage\ANF\DR

# Production (prompts "Type 'yes' to confirm" before resync):
.\Invoke-DR-Failback.ps1 -Environment Production

# Test (suppress prompts):
.\Invoke-DR-Failback.ps1 -Environment Test -Force
```

The script prints clean step progress and a final verification summary:

```
  DFS Target Status
  ──────────────────────────────────────────────────────────────────────────
  [v]   EU2 Source   \\anf-XXXX.corp.example.com\<volume>               Online
  [v]   CUS DR       \\anf-XXXX.corp.example.com\<volume>               Offline

  ANF Replication
  ──────────────────────────────────────────────────────────────────────────
  [v]   Volume: <volume>   MirrorState=Mirrored  Relationship=Idle  Healthy=True

  FAILBACK COMPLETE — EU2 IS BACK IN SERVICE
  [v] All checks passed. System is back to steady state.
```

> **[Screenshot placeholder — failback script console output]**

Logs are written to: `ANF\DR\Logs\DR-Failback-<Environment>-<timestamp>.log`

---

### Failback — Using Azure Portal + Manual PowerShell

Use this as a fallback if the automated script cannot be run.

#### Step 1 — Disable CUS DR DFS target (PowerShell)

```powershell
.\Manage-DFSPath.ps1 -Action Disable -Environment Production
```

Auto-detects which target is currently Online (CUS) and disables it.

#### Step 2 — Resync ANF replication (Azure Portal)

> ⚠️ This step will discard all data written to the DR volume during the break. Confirm with the app team before proceeding.

> **[Screenshot placeholder — ANF volume Replication blade showing Broken state]**

1. In the Azure Portal, navigate to the **ANF DR account** (Central US)
2. Select the **Capacity Pool** → open the **replicated volume**
3. Under **Replication**, click **Resync**
4. Read and accept the warning
5. Click **OK**
6. The replication state will move from **Broken** → **Resyncing** → **Mirrored**

> **[Screenshot placeholder — Resync confirmation dialog]**

> The resync is submitted asynchronously. For small volumes (< 1 TB) it typically completes within a few minutes. For large volumes it may take longer. Monitor via `Get-DR-Status.ps1` or the portal.

Alternatively via PowerShell:

```powershell
pwsh -NoProfile -Command "& '.\Manage-ANFReplication.ps1' -Action ResyncReplication -Environment Production"
```

#### Step 3 — Enable EU2 DFS target (PowerShell)

```powershell
.\Manage-DFSPath.ps1 -Action Enable -Environment Production
```

The script reads the state file written in Step 1 and automatically determines this is a Failback, enabling the EU2 source target (not the CUS DR target).

#### Step 4 — Verify final state (PowerShell)

```powershell
.\Get-DR-Status.ps1 -Environment Production
```

Confirm:
- EU2 Source = Online, `YES <--` (serving traffic)
- CUS DR = Offline
- ANF MirrorState = Mirrored, Healthy = True

---

## Notes & Limitations

- **Resync wait time:** The script submits the resync and does not wait for completion before re-enabling EU2. This is intentional — the resync happens in the background in Azure and enabling the EU2 DFS target is safe immediately after submission (EU2 is the source of truth, it was never modified during DR). Monitor progress via `Get-DR-Status.ps1`.

- **State file dependency:** `Manage-DFSPath.ps1` writes a state file (`dr_state_<environment>.json`) when a Disable action is performed. This file is used during Enable to determine whether to perform a Failover (enable CUS) or a Failback (enable EU2). Do not delete this file between Phase 1 and Phase 2.

- **Multiple volumes:** The config CSV supports multiple volume rows per environment. All scripts process every row for the specified environment in sequence.

- **Credential binding:** The stored credential (`~\.admin_cred.xml`) is encrypted with Windows DPAPI and is tied to the user and machine it was created on. It must be re-created on any new machine or for any new user who needs to run the scripts.

- **Az module isolation:** ANF script steps are always run in a child `pwsh -NoProfile` process to avoid Az module version conflicts with the calling session.

---

## Useful Links

- [Azure NetApp Files documentation](https://learn.microsoft.com/en-us/azure/azure-netapp-files/)
- [Cross-region replication of ANF volumes](https://learn.microsoft.com/en-us/azure/azure-netapp-files/cross-region-replication-introduction)
- [Requirements and considerations for ANF CRR](https://learn.microsoft.com/en-us/azure/azure-netapp-files/cross-region-replication-requirements-considerations)
- [Manage ANF disaster recovery — Microsoft docs](https://learn.microsoft.com/en-us/azure/azure-netapp-files/cross-region-replication-manage-disaster-recovery)
- [DFS Namespaces overview](https://learn.microsoft.com/en-us/windows-server/storage/dfs-namespaces/dfs-overview)
