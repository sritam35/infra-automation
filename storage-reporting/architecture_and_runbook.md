# Storage Volume Reporting — Architecture & Runbook

**Author:** Sritam Mohanty
**Created:** May 2026
**Branch:** `sritam_mohanty_05072026`
**Pipeline file:** `Pipelines/storage-volume-reporting-pipeline.yml`

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Problem Statement](#2-problem-statement)
3. [Architecture Overview](#3-architecture-overview)
4. [Component Deep-Dive](#4-component-deep-dive)
   - 4.1 [config.py](#41-configpy)
   - 4.2 [ontap_volume_collector.py](#42-ontap_volume_collectorpy)
   - 4.3 [anf_volume_collector.py](#43-anf_volume_collectorpy)
   - 4.4 [commvault_volume_mapper.py](#44-commvault_volume_mapperpy)
   - 4.5 [sharepoint_helper.py](#45-sharepoint_helperpy)
   - 4.6 [volume_reporting_main.py](#46-volume_reporting_mainpy)
   - 4.7 [dfs_collector.py](#47-dfs_collectorpy)
   - 4.8 [ontap_aggr_collector.py](#48-ontap_aggr_collectorpy)
5. [Azure DevOps Pipeline](#5-azure-devops-pipeline)
6. [Infrastructure & Credentials Reference](#6-infrastructure--credentials-reference)
7. [SharePoint Storage Layout](#7-sharepoint-storage-layout)
8. [Data Model (CSV Schemas)](#8-data-model-csv-schemas)
9. [Power BI Integration](#9-power-bi-integration)
10. [Issues Encountered and How They Were Fixed](#10-issues-encountered-and-how-they-were-fixed)
11. [Current Status](#11-current-status)
12. [Future Roadmap](#12-future-roadmap)
13. [File Inventory](#13-file-inventory)

---

## 1. Executive Summary

This solution collects daily storage capacity snapshots from two platforms:

- **On-premises NetApp ONTAP** — 6 clusters across multiple data centres, queried over SSH.
- **Azure NetApp Files (ANF)** — 2 accounts (CUS and EU2 regions), queried via Azure REST API.

For each volume it records: provisioned size, used size, available size, percentage used, and whether Commvault backup is configured. In addition, physical aggregate capacity is collected directly from ONTAP (`aggr show -instance`) to provide true disk utilisation data independent of volume-level accounting. The data is written to four CSV files stored on SharePoint Online. Power BI Pro connects to those CSVs to render growth trend dashboards that update automatically every morning before business hours.

The collection runs on an Azure DevOps `SharedBuild` (Windows) agent, scheduled daily at **06:00 UTC**, and can also be triggered by any commit to the `Storage-Reporting/` folder.

All volumes include a `volume_type` field (`RW`, `DP`, or `LS`) to distinguish active data volumes from SnapMirror/replication destination volumes, enabling physical vs logical capacity views in Power BI. A DFS namespace mapping (`dfs_mapping.csv`) is also produced daily, linking DFS paths to their underlying storage volumes.

---

## 2. Problem Statement

Before this solution existed the storage team had no centralised view of:

| Gap | Impact |
|-----|--------|
| Volume capacity trends over time | No early warning before volumes fill |
| Which volumes have Commvault backup | Compliance / SLA blind spot |
| ANF and ONTAP in one report | Manual work across two separate portals |
| Historical growth data | Could not forecast capacity additions |

Existing tools only provided point-in-time health checks (the `netapp_health_check.py` / `netapp_autogrow_check.py` scripts in `Monitoring/`) and reacted to volume-full events rather than predicting them.

---

## 3. Architecture Overview

```
+---------------------------+        SSH (paramiko)         +-----------------+
|  ONTAP Clusters (x6)      |<------------------------------|                 |
|  ashnasclu001             |                               |                 |
|  eu2nasclu001             |                               |  Azure DevOps   |
|  eu2nasclu003             |       Azure REST API          |  SharedBuild    |
|  marbkpclu003             |<------------------------------|  Windows Agent  |
|  marnasclu003             |                               |  (svc-prdtfsbld)|
|  sydnasclu002             |                               |                 |
+---------------------------+                               |                 |
                                                            |  volume_        |
+---------------------------+       Azure REST API          |  reporting_     |
|  Azure NetApp Files (ANF) |<------------------------------|  main.py        |
|  cusprdanf01 (centralus)  |                               |                 |
|  eu2prdanf01 (eastus2)    |  Azure Monitor Metrics API    |                 |
+---------------------------+<------------------------------|                 |
                                                            |                 |
+---------------------------+  UNC file read (CSV reports)  |                 |
|  Commvault Reports        |<------------------------------|                 |
|  (\\gmo\dsl\...\reports)  |                               +--------+--------+
+---------------------------+                                        |
|  bedprdbck001             |          Graph API (HTTPS)             |
|  bedprdbck001             |                            +-----------v---------+
+---------------------------+                            |  SharePoint Online  |
                                                         |  Platform Eng site  |
                                                         |                     |
                                                         |  volume_snapshots   |
                                                         |  .csv  (appended)   |
                                                         |                     |
                                                         |  backup_status      |
                                                         |  .csv  (overwritten)|
                                                         |                     |
                                                         |  dfs_mapping        |
                                                         |  .csv  (overwritten)|
                                                         |                     |
                                                         |  aggr_snapshots     |
                                                         |  .csv  (appended)   |
                                                         +-----------+---------+
                                                                     |
                                                         +-----------v---------+
                                                         |  Power BI Pro        |
                                                         |  (growth dashboards) |
                                                         +---------------------+
```

**Data flow summary:**

1. Azure DevOps pipeline checks out the `Storage-Reporting/` scripts.
2. `volume_reporting_main.py` orchestrates five collectors:
   - `ontap_volume_collector.py` — SSH into each cluster, run `volume show -instance`, parse output. All volume types (RW/DP/LS) are collected with a `volume_type` field.
   - `anf_volume_collector.py` — ARM REST API to list pools/volumes; Azure Monitor for used bytes. All ANF volumes get `volume_type=RW`.
   - `commvault_volume_mapper.py` — reads two scheduled Commvault CSV report exports from a UNC path; matches content paths to volumes.
   - `dfs_collector.py` — SSHes into ONTAP clusters to build a CIFS share→volume map; runs PowerShell `Get-DfsnFolderTarget` to enumerate DFS namespace paths; maps each Online DFS target to its storage volume.
   - `ontap_aggr_collector.py` — SSH into each cluster, run `aggr show -instance`, collect physical aggregate capacity.
3. Results are merged and de-duplicated (idempotent re-runs remove today's rows before appending).
4. `sharepoint_helper.py` uploads all three CSVs to SharePoint via Microsoft Graph API.
5. Power BI Pro scheduled refresh reads the SharePoint CSVs each morning and renders dashboards.

---

## 4. Component Deep-Dive

### 4.1 `config.py`

Central configuration module. **All secrets come from environment variables** — never hardcoded. Static structural values (cluster paths, ANF account names, CSV schemas) are defined here so they are changed in one place only.

**Key configuration blocks:**

| Block | Variables | Purpose |
|-------|-----------|---------|
| ONTAP SSH | `NETAPP_SSH_USER`, `NETAPP_SSH_KEY_PATH`, `NETAPP_SSH_PORT`, `NETAPP_CLUSTERS_FILE` | How to connect to ONTAP clusters |
| ANF | `AZURE_TENANT_ID`, `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, `ANF_SUBSCRIPTION_ID`, `ANF_ACCOUNTS` | ARM REST auth + account list |
| Commvault | `CV_REPORT_DIR` | UNC path to directory containing scheduled CSV report exports |
| SharePoint | `SP_TENANT_ID`, `SP_CLIENT_ID`, `SP_CLIENT_SECRET`, `SHAREPOINT_HOSTNAME`, `SHAREPOINT_SITE_PATH`, `SHAREPOINT_FOLDER` | Graph API auth + upload location |
| CSV schemas | `SNAPSHOT_COLS`, `BACKUP_COLS`, `DFS_MAPPING_COLS`, `AGGR_COLS` | Column order enforcement for all output files |
| DFS output | `CSV_DFS_MAPPING` | Filename for DFS path→volume mapping (`dfs_mapping.csv`) |
| Aggr output | `CSV_AGGR_SNAPSHOTS` | Filename for ONTAP physical aggregate snapshots (`aggr_snapshots.csv`) |

**ANF accounts list (static, curated):**

```python
ANF_ACCOUNTS = [
    { "account_name": "cusprdanf01", "resource_group": "centralus-cusprdanf01-rg",  "region": "centralus", "label": "CUS" },
    { "account_name": "eu2prdanf01", "resource_group": "eastus2-eu2prdanf01-rg",    "region": "eastus2",   "label": "EU2" },
]
```

---

### 4.2 `ontap_volume_collector.py`

Collects volume capacity from all on-premises NetApp ONTAP clusters.

**How it works:**

1. Reads `netapp_clusters.conf` (one hostname per line, `#` = comment).
2. For each cluster: connects via SSH using `paramiko`. Tries the private key file first; falls back to password (`NETAPP_SSH_PASSWORD`) if the key file is absent.
3. Runs `set -rows 0` (disables CLI pager) then `volume show -instance` (verbose per-volume output).
4. Parses the instance output line-by-line using regex patterns that handle multiple ONTAP version label variants (e.g. "Percent Used:", "Percentage of Volume Space Used:").
5. Filters out:
   - `vol0` — system root volume
   - `*_root` — SVM root volumes
6. Converts raw ONTAP size strings (e.g. `"465.7GB"`, `"2.3TB"`) to GB floats using a unit multiplier map.

> **Note (June 2026):** DP and LS volumes are now included (previously filtered out). The `volume_type` field (`RW`/`DP`/`LS`) allows Power BI to distinguish physical disk consumption (RW+DP) from logical data (RW only) via a slicer. DP/LS volumes always receive `backup_configured=NA`.

**Parsed fields per volume:**

| CSV field | Source |
|-----------|--------|
| `cluster` | Cluster hostname |
| `svm` | Vserver Name |
| `volume_name` | Volume Name |
| `volume_type` | Volume Type (`RW`, `DP`, `LS`) |
| `size_gb` | Volume Size |
| `used_gb` | Used Size |
| `avail_gb` | Available Size (or derived from size−used) |
| `pct_used` | Percent Used (or derived from bytes) |

**Result from last successful run:** 347 volumes across 6 clusters (283 RW + 64 DP/LS replicas).

---

### 4.3 `anf_volume_collector.py`

Collects volume capacity from Azure NetApp Files using the Azure Resource Manager REST API and Azure Monitor Metrics API.

**Authentication:** Client credentials flow (service principal) — token cached in-process keyed by resource URI, renewed 60 seconds before expiry.

**How it works:**

1. For each ANF account in `config.ANF_ACCOUNTS`:
   - List capacity pools: `GET /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.NetApp/netAppAccounts/{acct}/capacityPools`
   - For each pool: list volumes via the same ARM path hierarchy.
   - For each volume: read `usageThreshold` from ARM properties (provisioned size in bytes).
   - Query Azure Monitor `VolumeLogicalSize` metric (2-hour window, 1-hour interval, Average aggregation) for actual used bytes.
2. Converts bytes to GB, calculates available and pct_used.
3. Uses `Optional[int]` from the `typing` module (required for Python 3.8 compatibility).

**Key implementation detail — pool name parsing:**

ARM returns pool names in the format `accountName/poolName`. The code strips the account prefix using `.split("/")[-1]` before passing to the volumes API. Without this the volumes API returns HTTP 404.

All ANF volume records include `volume_type=RW` (ANF has no DP/LS concept).

**Result from last successful run:** 55 volumes (26 CUS + 29 EU2).

---

### 4.4 `commvault_volume_mapper.py`

Reads two pre-generated Commvault Command Center CSV report exports from a shared directory and produces a per-volume backup status lookup. **No Commvault API calls are made at runtime.**

> **Design decision:** After multiple failed attempts to use the Commvault REST API reliably from the Windows build agent (see Issues 11–16 in Section 10), the approach was completely rewritten to consume two scheduled CSV exports that Commvault generates daily. This is more reliable, requires no authentication at run-time, and is independent of API endpoint availability.

**Required reports** (both saved to `CV_REPORT_DIR` daily at 05:00 AM):

| Report glob | Key columns | Purpose |
|-------------|-------------|---------|
| `*SubclientConfigInfo_daily*.csv` | Client, Subclient, Content | Maps UNC content paths to subclients |
| `*DataProtectionReport_daily*.csv` | Client, Subclient, Last Backup Start | Provides last backup date per subclient |

Both reports have a 3-line preamble before the real header row. The reader finds the header by looking for a row starting with `"Client"`.

**Matching strategy:**

| Priority | Name | Description |
|----------|------|-------------|
| P1 | Exact path match | Extract the last segment from each UNC content path. e.g. `UNC-NT_anf-63d0.gmo.tld\eu2-x-ats-betas` → volume `eu2-x-ats-betas`. Case-insensitive. First match wins. |
| P2 | Word-level fallback | For ANF volumes not matched by P1, best word-intersection match between volume name and ANF subclient name. |

**`backup_configured` values:** `True` = matched + recent backup date; `False` = no match; `NA` = DP/LS volume, system/infra volume, eu2prdanf01 ANF, or matched but no recent date (see Section 8 for full detail).

**`CV_REPORT_DIR` (from `config.py`):**
```python
CV_REPORT_DIR = os.environ.get("CV_REPORT_DIR", r"\\gmo\dsl\backupautomation\commvault\reports")
```

---

### 4.5 `sharepoint_helper.py`

Handles all SharePoint I/O via Microsoft Graph API.

**Authentication:** Client credentials flow against Graph (`https://graph.microsoft.com/.default`), using `GMO Storage Volume Reporting` app registration with `Sites.ReadWrite.All` (admin consent granted).

**Operations:**

| Method | HTTP verb | Description |
|--------|-----------|-------------|
| `_get_site_id()` | GET | Resolves hostname + site path to site ID (cached) |
| `_get_drive_id()` | GET | Gets the default Documents drive ID (cached) |
| `download_csv(filename)` | GET | Downloads existing CSV; returns empty string on 404 |
| `upload_csv(filename, content)` | PUT | Uploads or overwrites a file in `SHAREPOINT_FOLDER` |

Graph automatically creates the folder if it does not exist.

---

### 4.6 `volume_reporting_main.py`

Orchestrates all collectors and manages the full pipeline lifecycle.

**CLI flags (useful for development / partial runs):**

| Flag | Effect |
|------|--------|
| `--dry-run` | Collect but write CSVs locally; skip SharePoint upload |
| `--skip-sharepoint` | Write CSVs locally instead of uploading |
| `--skip-ontap` | Skip ONTAP SSH collection |
| `--skip-anf` | Skip ANF REST API collection |
| `--skip-commvault` | Skip Commvault backup lookup |
| `--skip-dfs` | Skip DFS path→volume mapping collection |
| `--skip-aggr` | Skip ONTAP aggregate collection |

**Execution steps:**

1. Collect ONTAP snapshots (`ontap_volume_collector.collect_all()`) — all volume types including DP/LS.
2. Collect ANF snapshots (`anf_volume_collector.collect_all()`).
3. Build Commvault backup lookup (`commvault_volume_mapper.build_backup_lookup()`).
4. Assemble `backup_rows` — one row per volume, joining backup status. DP/LS volumes always get `backup_configured=NA` (first override rule).
5. Download existing `volume_snapshots.csv` from SharePoint (to preserve history).
6. Remove today's rows (idempotent — safe to re-run multiple times in one day).
7. Append new rows to existing history.
8. Serialise `volume_snapshots.csv` and `backup_status.csv` with fixed column order.
9. Collect DFS mapping (`dfs_collector.collect_all()`) — ONTAP CIFS share→volume map + PowerShell DFS namespace enumeration.
10. Collect ONTAP aggregate snapshots (`ontap_aggr_collector.collect_all()`) — `aggr show -instance`; merge with existing `aggr_snapshots.csv` history; same idempotency pattern as volume snapshots.
11. Upload all four CSVs to SharePoint. On failure, write locally as fallback.
12. Print summary: total volumes, with-backup count, without-backup count, DFS mapping count, aggregate row count.

**Idempotency guarantee:** Step 6 ensures that if the pipeline is re-triggered the same day (e.g. after a fix), today's data is refreshed rather than duplicated in the history file.

---

## 5. Azure DevOps Pipeline

**File:** `Pipelines/storage-volume-reporting-pipeline.yml`
**Pool:** `SharedBuild` (Windows agent, runs as `svc-prdtfsbld`)
**Schedule:** Daily at 06:00 UTC (`cron: "0 6 * * *"`)
**Branch trigger:** Any commit to `Storage-Reporting/*` on `master`

### Pipeline Steps

| Step | Task | Description |
|------|------|-------------|
| 1 | `script` | Print build number (announce start) |
| 2 | `CopyFiles@2` | Copy `Storage-Reporting/**` to build share `\\gmo\app\Build\DevOps\...` |
| 3 | `PublishBuildArtifacts@1` | Publish artifact `StorageReportingDrop` for audit trail |
| 4 | `powershell` | `py -m pip install -r Storage-Reporting\requirements.txt` |
| 4b | `DownloadSecureFile@1` | Download `svc_netapp_id_rsa` from Secure Files; exposes path as `$(sshKey.secureFilePath)` |
| 4c | `powershell` | Check if RSAT-DFS-Mgmt-Con Windows feature is installed; install if missing (enables `Get-DfsnRoot` / `Get-DfsnFolderTarget` cmdlets required by `dfs_collector.py`) |
| 5 | `powershell` | `cd Storage-Reporting; py volume_reporting_main.py` |

### Environment Variables Injected into Step 5

| Variable | Source | Used By |
|----------|--------|---------|
| `NETAPP_SSH_USER` | Pipeline variable (`svc_netapp`) | ONTAP SSH |
| `NETAPP_SSH_KEY_PATH` | `$(sshKey.secureFilePath)` (Secure Files) | ONTAP SSH |
| `NETAPP_CLUSTERS_FILE` | `$(Build.SourcesDirectory)\Monitoring\netapp_clusters.conf` | ONTAP cluster list |
| `AZURE_TENANT_ID` | Pipeline secret | ANF + SharePoint auth |
| `AZURE_CLIENT_ID` | Pipeline secret | ANF auth |
| `AZURE_CLIENT_SECRET` | Pipeline secret | ANF auth |
| `ANF_SUBSCRIPTION_ID` | Pipeline variable | ANF REST API |
| `CV_REPORT_DIR` | Pipeline variable (`\\gmo\dsl\backupautomation\commvault\reports`) | Path to Commvault daily CSV exports |
| `SP_TENANT_ID` | Same as `AZURE_TENANT_ID` | Graph API auth |
| `SP_CLIENT_ID` | Pipeline secret | Graph API auth |
| `SP_CLIENT_SECRET` | Pipeline secret | Graph API auth |
| `SHAREPOINT_HOSTNAME` | Pipeline variable | Graph API site resolution |
| `SHAREPOINT_SITE_PATH` | Pipeline variable | Graph API site resolution |
| `SHAREPOINT_FOLDER` | Pipeline variable (`Storage-Reporting/volume-data`) | Upload destination |
| `PYTHONUNBUFFERED` | Hardcoded `"1"` | Real-time log output in pipeline |
| `PYTHONIOENCODING` | Hardcoded `"utf-8"` | Allows `→` and other non-ASCII chars in stdout |

> **Note:** All previous Commvault API variables (`COMMVAULT_BASE_URL`, `COMMVAULT_TOKEN_FILE`, `COMMVAULT_ACCESS_TOKEN`, `COMMVAULT_REFRESH_TOKEN`) were removed when the mapper was rewritten to use CSV reports. They no longer exist in the pipeline or `config.py`.

---

## 6. Infrastructure & Credentials Reference

### Azure AD App Registration

| Property | Value |
|----------|-------|
| Display name | GMO Storage Volume Reporting |
| Tenant ID | `337b9f7b-9e69-4689-9b0d-3417bd3d8566` |
| Client ID | `926199bf-ba9b-4fad-8591-f825a9e33aa0` |
| API permission (ANF) | Azure subscription Reader role (RBAC) |
| API permission (SharePoint) | Microsoft Graph → Application → `Sites.ReadWrite.All` (admin consent granted) |
| Subscription | `c303bd32-eddf-42ca-9946-d679e0b1e1f3` (gmo-primary) |

> **Note:** The original client secret was accidentally exposed in a terminal during development and was immediately rotated. The pipeline variables contain the rotated secret.

### ONTAP Clusters

| Hostname | Location |
|----------|----------|
| `ashnasclu001` | Ashburn (US-East) |
| `eu2nasclu001` | EU2 |
| `eu2nasclu003` | EU2 |
| `marbkpclu003` | Marlborough backup |
| `marnasclu003` | Marlborough NAS |
| `sydnasclu002` | Sydney |

- **SSH user:** `svc_netapp`
- **Auth:** Private key at `/opt/svc_netapp/.ssh/id_rsa` on Linux; uploaded to Azure DevOps Secure Files as `svc_netapp_id_rsa` for Windows agent use.

### ANF Accounts

| Account | Resource Group | Region |
|---------|---------------|--------|
| `cusprdanf01` | `centralus-cusprdanf01-rg` | Central US |
| `eu2prdanf01` | `eastus2-eu2prdanf01-rg` | East US 2 |

### Commvault

| Property | Value |
|----------|-------|
| Server | `bedprdbck001` (Commvault v11.40.26) |
| Report directory (UNC) | `\\gmo\dsl\backupautomation\commvault\reports` |
| Report schedule | Daily at 05:00 AM (before 06:00 UTC pipeline run) |
| Report 1 | `*SubclientConfigInfo_daily*.csv` |
| Report 2 | `*DataProtectionReport_daily*.csv` |

> **Note:** No API credentials or token files are used. The pipeline reads pre-generated CSV exports via the UNC path, which is accessible to the `svc-prdtfsbld` Windows agent.

### SharePoint

| Property | Value |
|----------|-------|
| Site URL | `https://onlinegmo.sharepoint.com/sites/teams_platformengineering` |
| Library | Documents |
| Folder | `Storage-Reporting/volume-data` |
| File 1 | `volume_snapshots.csv` (appended daily) |
| File 2 | `backup_status.csv` (overwritten daily) |
| File 3 | `dfs_mapping.csv` (overwritten daily) |
| File 4 | `aggr_snapshots.csv` (appended daily) |

> See Section 7 for the full SharePoint folder layout.

---

## 7. SharePoint Storage Layout

```
Documents/
└── Storage-Reporting/
    └── volume-data/
        ├── volume_snapshots.csv     ← full history, appended daily
        ├── backup_status.csv        ← current state only, overwritten daily
        ├── dfs_mapping.csv          ← current DFS path→volume map, overwritten daily
        └── aggr_snapshots.csv       ← full history, appended daily
```

**volume_snapshots.csv** accumulates rows indefinitely. It is the source of truth for Power BI growth trend charts. Each daily run appends one row per volume (after removing any existing rows for today, ensuring idempotency).

**backup_status.csv** shows the current backup coverage state. It is overwritten completely every run — no history is needed because backup coverage changes infrequently and the intent is to answer "which volumes lack backup right now?"

---

## 8. Data Model (CSV Schemas)

### volume_snapshots.csv

| Column | Type | Description |
|--------|------|-------------|
| `snapshot_date` | `YYYY-MM-DD` | Date the snapshot was taken |
| `platform` | `ONTAP` \| `ANF` | Source platform |
| `cluster` | string | ONTAP cluster hostname or ANF account name |
| `svm` | string | ONTAP vserver name or ANF capacity pool name |
| `volume_name` | string | Volume name |
| `volume_type` | `RW`\|`DP`\|`LS` | Volume type — RW=active data, DP=SnapMirror destination, LS=load-sharing; empty for pre-June 2026 historical rows (treated as RW) |
| `capacity_pool` | string | ANF capacity pool name (empty for ONTAP) |
| `azure_region` | string | ANF region e.g. `centralus` (empty for ONTAP) |
| `resource_group` | string | ANF resource group (empty for ONTAP) |
| `size_gb` | float | ANF: volume provisioned quota in GB. ONTAP: volume provisioned size in GB |
| `used_gb` | float | Actual data consumed in GB (ANF: Azure Monitor `VolumeLogicalSize`; ONTAP: WAFL used) |
| `avail_gb` | float | Available size in GB |
| `pct_used` | float | Percentage used (0–100) |
| `pool_size_gb` | float | ANF capacity pool total provisioned size in GB (empty for ONTAP) |

### backup_status.csv

| Column | Type | Description |
|--------|------|-------------|
| `last_checked` | `YYYY-MM-DD` | Date last checked |
| `platform` | `ONTAP` \| `ANF` | Source platform |
| `cluster` | string | Cluster / account name |
| `svm` | string | Vserver / pool name |
| `volume_name` | string | Volume name |
| `backup_configured` | `True` \| `False` \| `NA` | Backup state (see below) |
| `last_backup_date` | `YYYY-MM-DD` or empty | Date of last successful backup job (empty for `False` / `NA`) |
| `subclient_name` | string | Commvault subclient name (populated for `True` and `NA`; empty for `False`) |
| `volume_type` | `RW`\|`DP`\|`LS` | Volume type — matches `volume_snapshots.csv` |
| `commvault_client` | string | Commvault client name (populated for `True` and `NA`; empty for `False`) |

**`backup_configured` values:**

| Value | Meaning |
|-------|---------|
| `True` | Subclient found in Commvault **and** a recent backup date is present in the Data Protection report |
| `False` | No Commvault subclient match found for this volume |
| `NA` | Not applicable — either: (a) volume is a DP/LS type (SnapMirror replica — never directly backed up), (b) volume is a system/test/infra volume not expected to be backed up, (c) all `eu2prdanf01` ANF volumes (backed up by ANF snapshot replication, not Commvault), or (d) a subclient match was found but the Data Protection report has no recent backup date for it (retired / SLA-excluded subclients) |

### dfs_mapping.csv

| Column | Type | Description |
|--------|------|-------------|
| `dfs_path` | string | DFS namespace path e.g. `\\gmo.tld\BosProd\Current` |
| `target_path` | string | UNC target e.g. `\\marprdsmb32_ha1a_smb\current_sh$` |
| `svm` | string | ONTAP SVM name (empty for ANF) |
| `volume_name` | string | Storage volume name |
| `state` | `Online`\|`Offline` | DFS target state (only Online entries are included) |

### aggr_snapshots.csv

| Column | Type | Description |
|--------|------|-------------|
| `snapshot_date` | `YYYY-MM-DD` | Date the snapshot was taken |
| `cluster` | string | ONTAP cluster hostname |
| `node` | string | Owning node name |
| `aggr_name` | string | Aggregate name |
| `aggr_type` | string | `HDD` \| `SSD` \| `vmdisk` \| `hybrid` |
| `raid_status` | string | `normal` \| `degraded` etc. |
| `size_gb` | float | Total physical size in GB |
| `used_gb` | float | Used physical space in GB |
| `avail_gb` | float | Available physical space in GB |
| `pct_used` | float | Percentage used (0–100) |

---

## 9. Power BI Integration

**Status: Complete.** Report file: `Storage Reporting Dashboard.pbix` (saved locally, published to Power BI Service — My Workspace). Last published: June 11, 2026 with ONTAP physical aggregate data, bookmark-based platform toggle, and Inventory growth rate columns. Platform Overview page removed.

### Data Connection

Connected via **SharePoint folder** connector using M queries in Power Query. Both tables loaded with explicit type casting:

**`volume_snapshots` M query** (includes `volume_type`, blank→RW replacement for historical rows, `vol_key` composite key, and `dfs_path` merge from `dfs_mapping`):
```m
let
    Source = SharePoint.Files("https://onlinegmo.sharepoint.com/sites/teams_platformengineering", [ApiVersion = 15]),
    Filtered = Table.SelectRows(Source, each [Folder Path] = "https://onlinegmo.sharepoint.com/sites/teams_platformengineering/Shared Documents/Storage-Reporting/volume-data/"),
    File   = Filtered{[Name="volume_snapshots.csv"]}[Content],
    Csv    = Csv.Document(File, [Delimiter=",", Encoding=65001, QuoteStyle=QuoteStyle.Csv]),
    Hdrs   = Table.PromoteHeaders(Csv, [PromoteAllScalars=true]),
    Typed  = Table.TransformColumnTypes(Hdrs, {
        {"snapshot_date", type date}, {"platform", type text},
        {"cluster", type text},       {"svm", type text},
        {"volume_name", type text},   {"volume_type", type text},
        {"capacity_pool", type text}, {"azure_region", type text},
        {"resource_group", type text},{"size_gb", type number},
        {"used_gb", type number},     {"avail_gb", type number},
        {"pct_used", type number},    {"pool_size_gb", type number}
    }),
    #"Added Custom" = Table.AddColumn(Typed, "vol_key", each [platform] & "|" & [cluster] & "|" & [volume_name]),
    #"Replaced Value" = Table.ReplaceValue(#"Added Custom","","RW",Replacer.ReplaceValue,{"volume_type"}),
    #"Merged Queries" = Table.NestedJoin(#"Replaced Value", {"volume_name"}, dfs_mapping, {"volume_name"}, "dfs_mapping", JoinKind.LeftOuter),
    #"Expanded dfs_mapping" = Table.ExpandTableColumn(#"Merged Queries", "dfs_mapping", {"dfs_path"}, {"dfs_path"}),
    #"Grouped Rows" = Table.Group(#"Expanded dfs_mapping", {"snapshot_date","platform","cluster","svm","volume_name","volume_type","capacity_pool","azure_region","resource_group","size_gb","used_gb","avail_gb","pct_used","pool_size_gb","vol_key"}, {{"dfs_path", each _, type table}}),
    #"Added Custom1" = Table.AddColumn(#"Grouped Rows", "dfs_paths_text", each Text.Combine(Table.Column([dfs_path], "dfs_path"), ", "))
in
    #"Added Custom1"
```

> **Note:** The `dfs_path` Table column produced by Group By must be deleted and `dfs_paths_text` renamed to `dfs_path` after applying the query.

**`backup_status` M query** (includes `volume_type`, blank→RW replacement):
```m
let
    Source = SharePoint.Files("https://onlinegmo.sharepoint.com/sites/teams_platformengineering", [ApiVersion = 15]),
    Filtered = Table.SelectRows(Source, each [Folder Path] = "https://onlinegmo.sharepoint.com/sites/teams_platformengineering/Shared Documents/Storage-Reporting/volume-data/"),
    File   = Filtered{[Name="backup_status.csv"]}[Content],
    Csv    = Csv.Document(File, [Delimiter=",", Encoding=65001, QuoteStyle=QuoteStyle.Csv]),
    Hdrs   = Table.PromoteHeaders(Csv, [PromoteAllScalars=true]),
    Typed  = Table.TransformColumnTypes(Hdrs, {
        {"last_checked", type date},     {"platform", type text},
        {"cluster", type text},          {"svm", type text},
        {"volume_name", type text},      {"volume_type", type text},
        {"backup_configured", type text},{"last_backup_date", type text},
        {"subclient_name", type text},   {"commvault_client", type text}
    }),
    #"Replaced Value" = Table.ReplaceValue(Typed,"","RW",Replacer.ReplaceValue,{"volume_type"})
in
    #"Replaced Value"
```

**`dfs_mapping` M query:**
```m
let
    Source   = SharePoint.Files("https://onlinegmo.sharepoint.com/sites/teams_platformengineering", [ApiVersion = 15]),
    Filtered = Table.SelectRows(Source, each [Folder Path] = "https://onlinegmo.sharepoint.com/sites/teams_platformengineering/Shared Documents/Storage-Reporting/volume-data/"),
    File     = Filtered{[Name="dfs_mapping.csv"]}[Content],
    Csv      = Csv.Document(File, [Delimiter=",", Encoding=65001, QuoteStyle=QuoteStyle.Csv]),
    Hdrs     = Table.PromoteHeaders(Csv, [PromoteAllScalars=true]),
    Typed    = Table.TransformColumnTypes(Hdrs, {
        {"dfs_path", type text}, {"target_path", type text},
        {"svm", type text},      {"volume_name", type text},
        {"state", type text}
    }),
    #"Added Key" = Table.AddColumn(Typed, "dfs_vol_key", each [svm] & "|" & [volume_name])
in
    #"Added Key"
```

**`aggr_snapshots` M query:**
```m
let
    Source   = SharePoint.Files("https://onlinegmo.sharepoint.com/sites/teams_platformengineering", [ApiVersion = 15]),
    Filtered = Table.SelectRows(Source, each [Folder Path] = "https://onlinegmo.sharepoint.com/sites/teams_platformengineering/Shared Documents/Storage-Reporting/volume-data/"),
    File     = Filtered{[Name="aggr_snapshots.csv"]}[Content],
    Csv      = Csv.Document(File, [Delimiter=",", Encoding=65001, QuoteStyle=QuoteStyle.Csv]),
    Hdrs     = Table.PromoteHeaders(Csv, [PromoteAllScalars=true]),
    Typed    = Table.TransformColumnTypes(Hdrs, {
        {"snapshot_date", type date}, {"cluster", type text},
        {"node", type text},          {"aggr_name", type text},
        {"aggr_type", type text},     {"raid_status", type text},
        {"size_gb", type number},     {"used_gb", type number},
        {"avail_gb", type number},    {"pct_used", type number}
    }),
    #"Is Latest" = Table.AddColumn(Typed, "is_latest",
        each if [snapshot_date] = List.Max(Typed[snapshot_date]) then 1 else 0,
        Int64.Type)
in
    #"Is Latest"
```

### Relationships

A computed `vol_key` column was added to both `volume_snapshots` and `backup_status` in Power Query:
```m
= [platform] & "|" & [cluster] & "|" & [volume_name]
```

Relationship: `volume_snapshots[vol_key]` → `backup_status[vol_key]`, Many-to-one, single cross-filter direction.

> **Why `vol_key` instead of `volume_name`:** Both `cusprdanf01` and `eu2prdanf01` contain volumes with identical names (e.g. `eu2-x-prod`). `volume_name` alone is not unique — `vol_key` combines platform + cluster + volume_name to guarantee uniqueness.

The `dfs_mapping` table is **not** related to `volume_snapshots` via a model relationship. Instead, DFS paths are merged directly into `volume_snapshots` in Power Query (Left Outer join on `volume_name`), concatenated per volume using `Text.Combine`, and surfaced as a native `dfs_path` column.

### DAX Measures

All measures stored in the `backup_status` or `volume_snapshots` table as noted.

> **volume_type filter note:** Page 1 has two page-level filters: `volume_snapshots[volume_type] = RW` and `backup_status[volume_type] = RW`. This scopes all Page 1 KPIs to active data volumes only (logical view). Page 3 has a `volume_type` slicer allowing toggle between RW-only (logical) and RW+DP (physical disk consumption).

```dax
Total Volumes =
CALCULATE(
    COUNTROWS(volume_snapshots),
    volume_snapshots[snapshot_date] = MAX(volume_snapshots[snapshot_date])
)

Volumes Backed Up =
CALCULATE(COUNTROWS(backup_status), backup_status[backup_configured] = "True")

Volumes Not Backed Up =
CALCULATE(COUNTROWS(backup_status), backup_status[backup_configured] = "False")

% Backed Up =
DIVIDE(
    CALCULATE(COUNTROWS(backup_status), backup_status[backup_configured] = "True"),
    CALCULATE(COUNTROWS(backup_status), backup_status[backup_configured] <> "NA"),
    0
)

Volumes Over 80pct Full =
VAR LatestDate = CALCULATE(MAX(volume_snapshots[snapshot_date]), ALLEXCEPT(volume_snapshots, volume_snapshots[volume_type]))
RETURN
CALCULATE(
    COUNTROWS(volume_snapshots),
    volume_snapshots[pct_used] >= 80,
    volume_snapshots[snapshot_date] = LatestDate
)

Latest pct_used =
VAR LatestDate = CALCULATE(MAX(volume_snapshots[snapshot_date]), ALL(volume_snapshots))
RETURN
CALCULATE(
    AVERAGE(volume_snapshots[pct_used]),
    volume_snapshots[snapshot_date] = LatestDate
)

Total Used TB =
VAR LatestDate = CALCULATE(MAX(volume_snapshots[snapshot_date]), ALLEXCEPT(volume_snapshots, volume_snapshots[volume_type]))
RETURN CALCULATE(DIVIDE(SUM(volume_snapshots[used_gb]), 1024), volume_snapshots[snapshot_date] = LatestDate)

Total Size TB =
VAR LatestDate = CALCULATE(MAX(volume_snapshots[snapshot_date]), ALLEXCEPT(volume_snapshots, volume_snapshots[volume_type]))
RETURN CALCULATE(DIVIDE(SUM(volume_snapshots[size_gb]), 1024), volume_snapshots[snapshot_date] = LatestDate)

Total Avail TB =
VAR LatestDate = CALCULATE(MAX(volume_snapshots[snapshot_date]), ALLEXCEPT(volume_snapshots, volume_snapshots[volume_type]))
RETURN CALCULATE(DIVIDE(SUM(volume_snapshots[avail_gb]), 1024), volume_snapshots[snapshot_date] = LatestDate)

Is Latest Snapshot =
VAR LatestDate = CALCULATE(MAX(volume_snapshots[snapshot_date]), ALL(volume_snapshots))
RETURN IF(MAX(volume_snapshots[snapshot_date]) = LatestDate, 1, 0)

Growth Rate GB per Day =
VAR MaxDate = CALCULATE(MAX(volume_snapshots[snapshot_date]), ALL(volume_snapshots))
VAR MinDate = CALCULATE(MIN(volume_snapshots[snapshot_date]), ALL(volume_snapshots))
VAR DaysDiff = MaxDate - MinDate
VAR LatestUsed = CALCULATE(AVERAGE(volume_snapshots[used_gb]), volume_snapshots[snapshot_date] = MaxDate)
VAR EarliestUsed = CALCULATE(AVERAGE(volume_snapshots[used_gb]), volume_snapshots[snapshot_date] = MinDate)
RETURN IF(DaysDiff = 0, 0, DIVIDE(LatestUsed - EarliestUsed, DaysDiff))

Growth Rate Pct per Day =
VAR MaxDate = CALCULATE(MAX(volume_snapshots[snapshot_date]), ALL(volume_snapshots))
VAR MinDate = CALCULATE(MIN(volume_snapshots[snapshot_date]), ALL(volume_snapshots))
VAR DaysDiff = MaxDate - MinDate
VAR LatestPct = CALCULATE(AVERAGE(volume_snapshots[pct_used]), volume_snapshots[snapshot_date] = MaxDate)
VAR EarliestPct = CALCULATE(AVERAGE(volume_snapshots[pct_used]), volume_snapshots[snapshot_date] = MinDate)
RETURN IF(DaysDiff = 0, 0, DIVIDE(LatestPct - EarliestPct, DaysDiff))

Physical Size TB =
VAR LatestDate = CALCULATE(MAX(aggr_snapshots[snapshot_date]), ALL(aggr_snapshots))
RETURN CALCULATE(DIVIDE(SUM(aggr_snapshots[size_gb]), 1024), aggr_snapshots[snapshot_date] = LatestDate)

Physical Used TB =
VAR LatestDate = CALCULATE(MAX(aggr_snapshots[snapshot_date]), ALL(aggr_snapshots))
RETURN CALCULATE(DIVIDE(SUM(aggr_snapshots[used_gb]), 1024), aggr_snapshots[snapshot_date] = LatestDate)

Physical Avail TB =
VAR LatestDate = CALCULATE(MAX(aggr_snapshots[snapshot_date]), ALL(aggr_snapshots))
RETURN CALCULATE(DIVIDE(SUM(aggr_snapshots[avail_gb]), 1024), aggr_snapshots[snapshot_date] = LatestDate)

Physical Pct Used =
VAR LatestDate = CALCULATE(MAX(aggr_snapshots[snapshot_date]), ALL(aggr_snapshots))
RETURN CALCULATE(AVERAGE(aggr_snapshots[pct_used]), aggr_snapshots[snapshot_date] = LatestDate)

ANF Pool Size TB =
-- Total capacity pool size — uses (cluster, svm) pairs to avoid name collision
-- (cusprdanf01/quant_standard and eu2prdanf01/quant_standard are distinct pools)
VAR LatestDate = CALCULATE(MAX(volume_snapshots[snapshot_date]), ALL(volume_snapshots))
RETURN
CALCULATE(
    SUMX(
        SUMMARIZE(volume_snapshots, volume_snapshots[cluster], volume_snapshots[svm]),
        CALCULATE(MAX(volume_snapshots[pool_size_gb]))
    ),
    volume_snapshots[platform] = "ANF",
    volume_snapshots[snapshot_date] = LatestDate
) / 1024

ANF Provisioned TB =
-- Sum of volume provisioned quotas (size_gb) — matrix row context scopes to cluster/pool
VAR LatestDate = CALCULATE(MAX(volume_snapshots[snapshot_date]), ALL(volume_snapshots))
RETURN
CALCULATE(
    DIVIDE(SUM(volume_snapshots[size_gb]), 1024),
    volume_snapshots[platform] = "ANF",
    volume_snapshots[snapshot_date] = LatestDate
)

ANF Pool Avail TB =
-- Pool capacity minus volume provisioned (unallocated pool space)
RETURN [ANF Pool Size TB] - [ANF Provisioned TB]
```

### Report Pages

#### Page 1 — Capacity Overview (redesigned June 2026)

Three sections controlled by bookmark navigation buttons at the top: **ALL(Ontap & ANF)**, **ANF**, **ONTAP**, **Backup Coverage**.

**ONTAP section (visible when ALL or ONTAP selected):**

| Visual | Fields | Purpose |
|--------|--------|---------|
| Dropdown Slicer | `aggr_snapshots[cluster]` — title: "ONTAP Capacity" | Filter ONTAP visuals by cluster |
| Matrix | Rows: `cluster`, Values: `Physical Size TB`, `Physical Used TB`, `Physical Avail TB`, `Physical Pct Used` | Cluster-level physical aggregate totals; visual filter `is_latest=1` |
| Table | `aggr_name`, `node`, `aggr_type`, `Physical Size TB`, `Physical Avail TB`, `Physical Used TB`, `pct_used` | Per-aggregate detail for selected cluster(s); visual filter `is_latest=1`; sorted by `pct_used` desc |
| Line chart | X: `snapshot_date`, Y: `Physical Used TB`, Legend: `aggr_name` | Aggregate growth over time (trend lines appear as daily data accumulates) |

**ANF section (visible when ALL or ANF selected):**

| Visual | Fields | Purpose |
|--------|--------|---------|
| Matrix | Rows: `cluster`, `svm` (pool), Values: `ANF Pool Size TB`, `ANF Provisioned TB`, `ANF Pool Avail TB` | Pool-level view: pool capacity vs allocated volume quota |
| Line chart | X: `snapshot_date`, Y: `ANF Provisioned TB`, Legend: `cluster` | ANF provisioned growth over time; visual filter `platform=ANF` |

**Bookmarks:**

| Bookmark | State |
|----------|-------|
| `All Platforms` | All visuals visible |
| `ONTAP Only` | ANF matrix + ANF line chart hidden |
| `ANF Only` | ONTAP table, matrix, slicer, growth chart hidden |

**Bookmark navigation buttons:** `ALL(Ontap & ANF)` → `All Platforms`, `ONTAP` → `ONTAP Only`, `ANF` → `ANF Only`, `Backup Coverage` → Page navigation to Backup Coverage page.

#### Page 2 — Backup Coverage

| Visual | Fields | Purpose |
|--------|--------|---------|
| Donut chart | Legend: `backup_configured`, Values: `Total Volumes` | True/False/NA split — colour coded: True=green, False=red, NA=grey |
| Table — **Protected Volumes (Backed Up)** (green title) | `volume_name`, `subclient_name`, `commvault_client`, `last_backup_date` filtered to `backup_configured = True`, sorted by `last_backup_date` asc | Shows backed-up volumes; oldest backup date first |
| Table — **Unprotected Volumes — No Backup Configured** (red title) | `platform`, `cluster`, `svm`, `volume_name` filtered to `backup_configured = False` | Volumes requiring backup review |
| Slicer | `cluster` | Filter both tables by cluster |

#### Page 3 — Inventory

| Visual | Fields | Purpose |
|--------|--------|---------|
| Dropdown slicer | `volume_name` | Search/filter by volume name |
| Table | `cluster`, `svm`, `volume_name`, `volume_type`, `size_gb`, `pct_used`, `avail_gb`, `backup_configured`, `last_backup_date`, `dfs_path`, `Growth Rate GB per Day`, `Growth Rate Pct per Day` | Full inventory with capacity, backup status, DFS path, and growth rates |

**Inventory table filters:** `Is Latest Snapshot = 1`

> **Note:** Platform Overview page was removed (June 2026). Its cluster/platform breakdown is now handled by the ONTAP/ANF sections on Page 1 with physical aggregate data.

### Power BI Service Configuration

| Property | Value |
|----------|-------|
| Workspace | My Workspace (Sritam Mohanty) |
| Report name | Storage Reporting Dashboard |
| Data source authentication | OAuth2 (GMO Microsoft account), Privacy level: Organizational |
| Scheduled refresh | Daily at **07:00 UTC** (one hour after pipeline deposits data at 06:00 UTC) |

---

### 4.7 `dfs_collector.py`

Maps DFS namespace paths to their underlying storage volumes. Runs as Step 4b in the daily pipeline (after ONTAP/ANF collection, before SharePoint upload).

**How it works:**

1. **CIFS share → volume map (ONTAP SSH):**
   - SSHes into each ONTAP cluster (reuses `paramiko` infrastructure from `ontap_volume_collector.py`).
   - Runs `vserver cifs share show -instance` — uses `-instance` format to get full untruncated `Volume Name:` field.
   - Builds a dict: `share_name_lower → [(svm, volume_name), ...]`.

2. **DFS enumeration (PowerShell subprocess):**
   - Runs `Get-DfsnRoot | Get-DfsnFolder | Get-DfsnFolderTarget | ConvertTo-Csv` via `subprocess.run`.
   - Excludes `ReplicationOnly` namespaces.
   - Returns list of `{dfs_path, target_path, state}` records.

3. **Mapping:**
   - For each DFS target, parses the UNC into `(hostname, share_name)`.
   - ANF detected by `anf-*` hostname pattern → `share_name == volume_name` (no CIFS lookup needed).
   - ONTAP: looks up `share_name` in the CIFS map → resolves `(svm, volume_name)`.
   - Multi-SVM disambiguation: extracts SVM hint from node-interface hostname (e.g. `marprdsmb32_ha1a_smb` → `marprdsmb32`).

4. **Deduplication:**
   - One row per `(dfs_path, volume_name)` pair.
   - Only `Online` entries are kept — `Offline` entries are DR/mirror targets not actively serving traffic.

5. **Output:** `dfs_mapping.csv` uploaded to SharePoint — 274 rows (June 2026 baseline).

**Prerequisites:** `RSAT-DFS-Mgmt-Con` Windows feature must be installed on the build agent (Step 4c in pipeline checks and installs if missing).

---

### 4.8 `ontap_aggr_collector.py`

Collects true physical aggregate capacity from all ONTAP clusters. Aggregates are the underlying disk pools that volumes sit inside — this data shows real disk utilisation including WAFL overhead, dedupe savings, and snapshot reserve, independent of volume-level accounting.

**How it works:**

1. Reuses `_connect_ssh`, `_exec`, `_parse_size_to_bytes`, `_bytes_to_gb`, `_parse_pct` helpers from `ontap_volume_collector.py`.
2. For each cluster: runs `set -rows 0` then `aggr show -instance`.
3. Parses `-instance` output for fields: `Aggregate:`, `Node:`, `Size:`, `Used Size:`, `Available Size:`, `Percent Used:`, `Aggregate Type:`, `RAID Status:`.
4. Skips system/root aggregates: names containing `aggr0`, `_root`.
5. Derives available/pct_used from size−used when not directly reported.

**Output columns:** `snapshot_date`, `cluster`, `node`, `aggr_name`, `aggr_type`, `raid_status`, `size_gb`, `used_gb`, `avail_gb`, `pct_used`

**Result from first run (June 11, 2026):** 15 aggregates across 6 clusters, 1,574 TB total physical capacity, 877 TB used (54.24% average utilisation).

---

## 10. Issues Encountered and How They Were Fixed

This section documents every significant problem encountered during development and the resolution applied.

---

### Issue 1 — Pipeline YAML `TargetFolder` indentation error

**Symptom:** Azure DevOps pipeline failed to parse the YAML. The `CopyFiles@2` task `TargetFolder` property was at the wrong indentation level.

**Root cause:** `TargetFolder` was placed as a sibling of `inputs:` instead of a child inside it.

**Fix:** Moved `TargetFolder` one level deeper inside the `inputs:` block.

```yaml
# WRONG
- task: CopyFiles@2
  TargetFolder: '$(buildSharePath)'
  inputs:
    Contents: |
      Storage-Reporting/**

# CORRECT
- task: CopyFiles@2
  inputs:
    Contents: |
      Storage-Reporting/**
    TargetFolder: '$(buildSharePath)'
```

---

### Issue 2 — Bash commands on Windows agent

**Symptom:** Pipeline steps using `bash:` task type or Linux-style commands (`mkdir -p`, `chmod`, etc.) failed because the `SharedBuild` pool runs Windows agents.

**Root cause:** Initial pipeline was written assuming a Linux agent (following patterns from other pipelines in the repo that use `pool: SharedBuild` with bash scripts — those agents are actually Linux, but the Windows `SharedBuild` pool was used for this pipeline).

**Fix:** Rewrote all `bash:` steps as `powershell:` steps and removed all Linux-specific commands. The SSH key deployment step was rewritten to use the `DownloadSecureFile@1` task which works cross-platform.

---

### Issue 3 — Python 3.8 type hint syntax `int | None`

**Symptom:** `anf_volume_collector.py` failed with `TypeError: unsupported operand type(s) for |: 'type' and 'NoneType'` on the build agent running Python 3.8.10.

**Root cause:** The union type hint syntax `int | None` (PEP 604) was introduced in Python 3.10. The build agents (SBLD1/SBLD2 on MARPRDTFS039) run Python 3.8.10.

**Fix:** Changed all `int | None` and `str | None` type hints to use `Optional[int]` / `Optional[str]` from the `typing` module (available in all Python 3.x versions).

```python
# BEFORE (Python 3.10+ only)
def _get_volume_used_bytes(resource_id: str) -> int | None:

# AFTER (Python 3.8 compatible)
from typing import Optional
def _get_volume_used_bytes(resource_id: str) -> Optional[int]:
```

---

### Issue 4 — ANF volume list returning HTTP 404 (pool name 404)

**Symptom:** All `_list_volumes()` calls for ANF capacity pools returned HTTP 404.

**Root cause:** The Azure ARM API returns pool names in the format `accountName/poolName` (e.g. `cusprdanf01/PremiumPool`). The code was passing the full compound name to the volumes API, resulting in a URL like `.../capacityPools/cusprdanf01%2FPremiumPool/volumes` which is invalid.

**Fix:** Strip the account prefix using `.split("/")[-1]` when extracting the pool name from the ARM response.

```python
# BEFORE — used the full compound name from ARM
pool_name = pool["name"]  # "cusprdanf01/PremiumPool"

# AFTER — take only the last segment
pool_name = pool["name"].split("/")[-1]  # "PremiumPool"
```

---

### Issue 5 — Unicode box-drawing characters in print statements

**Symptom:** Pipeline log showed garbled characters or the Python step exited with a UnicodeEncodeError. The summary banner used Unicode box-drawing characters (`─`, `═`).

**Root cause:** The Windows console (`cmd.exe` / PowerShell default) uses code page 850 or 1252 by default, which cannot encode Unicode box-drawing characters.

**Fix:**
1. Added `# -*- coding: utf-8 -*-` header to `volume_reporting_main.py`.
2. Replaced all Unicode box-drawing characters with plain ASCII equivalents (`-`, `=`, `|`).

---

### Issue 6 — SSH key not on Windows agent

**Symptom:** ONTAP collector fell through to password authentication (no key file found), then failed because `NETAPP_SSH_PASSWORD` was not set.

**Root cause:** The SSH private key for `svc_netapp` lives at `/opt/svc_netapp/.ssh/id_rsa` on Linux servers. The Windows build agent has no access to that NFS mount.

**Fix:**
1. Uploaded the private key file to **Azure DevOps Secure Files** as `svc_netapp_id_rsa`.
2. Added a `DownloadSecureFile@1` task to the pipeline (Step 4b) to download it to a temporary path at runtime.
3. Passed `$(sshKey.secureFilePath)` as the `NETAPP_SSH_KEY_PATH` environment variable for Step 5.
4. Authorised the pipeline to use the secure file in the Azure DevOps Library settings.

---

### Issue 7 — `token_manager` module not importable from `Storage-Reporting/`

**Symptom:** `commvault_volume_mapper.py` raised `ImportError: No module named 'token_manager'`.

**Root cause:** `token_manager.py` exists in `Commvault/` (a sibling directory). The pipeline only copies `Storage-Reporting/**` to the agent, so the sibling directory was not present.

**Fix:** Copied `Commvault/token_manager.py` into `Storage-Reporting/token_manager.py`. The import path was updated to insert `Path(__file__).parent` into `sys.path` so Python finds it in the same directory regardless of the working directory when the script runs.

```python
_this_dir = str(Path(__file__).parent)
if _this_dir not in sys.path:
    sys.path.insert(0, _this_dir)

from token_manager import TokenManager as _TokenManager
```

---

### Issue 8 — Commvault token file inaccessible from Windows agent

**Symptom:** `_token_mgr.token_data` was empty. The log showed the token manager could not read the token file at `\\gmo\dsl\backupautomation\commvault\.commvault_tokens.json`.

**Root cause:** The `svc-prdtfsbld` Windows service account running the build agent does not have access to the NFS-backed UNC path `\\gmo\dsl\...` where the Commvault tokens are stored. That path is designed for the Linux automation server (`marprdnfs001`).

**Fix:** Added a fallback in `commvault_volume_mapper.py` that reads `COMMVAULT_ACCESS_TOKEN` and `COMMVAULT_REFRESH_TOKEN` from pipeline environment variables (set as secret variables in Azure DevOps) when the token file is inaccessible:

```python
if not _token_mgr.token_data:
    access_token  = os.environ.get("COMMVAULT_ACCESS_TOKEN", "")
    refresh_token = os.environ.get("COMMVAULT_REFRESH_TOKEN", "")
    if access_token and refresh_token:
        _token_mgr.initialize_tokens(access_token, refresh_token)
```

The `COMMVAULT_ACCESS_TOKEN` and `COMMVAULT_REFRESH_TOKEN` pipeline secret variables were added to Azure DevOps and injected into Step 5's `env:` block.

---

### Issue 9 — Windows `os.makedirs` UNC path error (WinError 183)

**Symptom:** Pipeline log showed:
```
[ERROR] Failed to save tokens: [WinError 183] Cannot create a file when that file already exists: '\\gmo\dsl\backupautomation\commvault'
```

**Root cause:** Python's `os.makedirs(path, exist_ok=True)` has a known bug on Windows with UNC paths. When the UNC directory already exists, `makedirs` throws `FileExistsError` (WinError 183) even when `exist_ok=True` is set, because the UNC path check evaluates the root (`\\server\share`) as the "existing file" rather than the full path.

Inside `token_manager.py`'s `_save_tokens()` method, `makedirs` was called on the directory of the token file. When `initialize_tokens()` was called, it tried to ensure the UNC directory existed — which always fails on Windows.

**Fix:** Before calling `initialize_tokens()`, redirect the `TokenManager`'s token file path to a local temporary file on the Windows agent:

```python
import tempfile
local_token_file = os.path.join(tempfile.gettempdir(), ".commvault_tokens.json")
print(f"[COMMVAULT] Token file empty — initialising from pipeline variables (local cache: {local_token_file})")
_token_mgr.token_file = local_token_file
_token_mgr.initialize_tokens(access_token, refresh_token)
```

This means tokens are saved to e.g. `C:\Users\svc-prdtfsbld\AppData\Local\Temp\.commvault_tokens.json` — fully writable by the service account, with no UNC path involved. The temp file is ephemeral (only lives for the duration of the pipeline run, which is all that is needed).

**Commit:** `f25f76c` on branch `sritam_mohanty_05072026`

---

### Issue 10 — Commvault tokens completely invalidated by forced renewal loop

**Symptom:** After implementing the forced renewal fix, the next pipeline run returned:
```
"errorMessage":"Unexpected access token or refresh token provided."
```
Followed by:
```
"errorMessage":"Account is disabled."
```

**Root cause:** Multiple pipeline runs in quick succession (builds .2, .3, .4) each forced a token renewal. Commvault's `v4/AccessToken/Renew` endpoint rotates both the access token AND refresh token on every call — each renewal invalidates the previous pair. Because the pipeline variables still held the original (now 3 rotations behind) tokens, every run was using a stale refresh token. Commvault eventually locked the token session entirely.

**Fix (two parts):**

Part A — Stop forcing renewal. Removed the line that set `expires_at = "2000-01-01"` to artificially expire tokens. The `token_manager` handles expiry naturally and only renews when actually needed.

Part B — Load existing cached tokens first before seeding from pipeline variables:
```python
_token_mgr.token_file = local_token_file
_token_mgr.token_data = _token_mgr._load_tokens()   # try local cache first
if _token_mgr.token_data:
    print("[COMMVAULT] Loaded cached tokens from local file")
else:
    # Only seed from pipeline vars if no local cache exists
    _token_mgr.initialize_tokens(access_token, refresh_token)
```
This ensures that after a successful renewal the rotated tokens are reused on the next run, rather than re-seeding from the now-stale pipeline variable tokens.

Part C — Generated fresh tokens from the Commvault UI, initialized the NFS token file via `token_manager.py`, and updated the pipeline secret variables.

---

### Issues 11–16 — Commvault REST API approach (abandoned)

Multiple attempts were made to retrieve subclient content paths via the Commvault REST API:

- **Issue 11:** `GET /v2/Subclient` bulk endpoint returned 403 — service account lacks admin role required.
- **Issue 12:** `GET /Subclient?clientId=X` list endpoint omits `content` field — required per-subclient detail call.
- **Issue 13:** ANF Commvault clients (`anf-XXXX.gmo.tld`) were excluded from keyword filter — fixed by adding `"anf"`.
- **Issue 14:** Pipeline variable `$(SHAREPOINT_FOLDER)` not expanded — SharePoint folder created with literal name; fixed by defining variable in Azure DevOps.
- **Issue 15:** `GET /Subclient/{id}` per-call timeout (30–60 s each) — Commvault v11.40.26 queries live client connectivity per call; 400+ subclients exceeded 10-minute pipeline budget.
- **Issue 16:** Subclient-name token heuristic (no API, match on name only) — only 70/283 matches; insufficient.

**All API approaches were abandoned.** See Issue 17.

---

### Issue 17 — Complete rewrite: Commvault REST API replaced with scheduled CSV report exports

**Symptom / motivation:** After Issues 11–16, no REST API approach could reliably retrieve Commvault content paths within the 10-minute pipeline window on this Commvault server version.

**Root cause:** The `bedprdbck001` Commvault v11.40.26 server has slow subclient detail endpoints. The `v2/Subclient` bulk endpoint requires admin rights not held by the service account. The `v1/Subclient/{id}` endpoint times out under load.

**Fix — two scheduled Commvault reports:**

Two reports were created in the Commvault Command Center console and scheduled to run daily at 05:00 AM (before the 06:00 UTC pipeline):

1. **SubClient Configuration Information (Content, Filter and Filter Exception)**
   - Saved to: `\\gmo\dsl\backupautomation\commvault\reports`
   - Columns: Client, Workload, Instance, Subclient, Content
   - Content field contains comma-separated UNC paths such as `UNC-NT_anf-63d0.gmo.tld\eu2-x-ats-betas`

2. **Data Protection**
   - Saved to: `\\gmo\dsl\backupautomation\commvault\reports`
   - Columns: Client, Agent, Instance, Subclient, Full App Size (GB), Last Backup Job ID, Last Backup Size (GB), Last Backup Start, Days Since Last Backup, Excluded From SLA, SLA Excluded Reason
   - Date format: `"May 1, 2026, 08:40:12 PM"` or `MM/DD/YYYY HH:MM:SS`

`commvault_volume_mapper.py` was completely rewritten (~180 lines, no API code) to:
- Find the newest file matching each glob pattern in `CV_REPORT_DIR`
- Parse the preamble-skipping CSV reader
- Build a `{volume_name_lower: (subclient, client)}` dict from content paths (P1 exact match)
- Build a word-level ANF index from the Data Protection report (P2 fallback)
- Return `backup_configured=True/False/NA` per volume

**Result:** 89/283 volumes confirmed `True` (with real backup dates), 55 `False`, 139 `NA`.

---

### Issue 18 — CUS ANF account volumes named `eu2-*` (not `cus-*`)

**Symptom:** All 26 volumes in `cusprdanf01` showed `backup_configured=False` even though the Commvault SubClient Configuration report clearly listed UNC paths like `UNC-NT_anf-63d0.gmo.tld\eu2-x-ats-betas`.

**Root cause:** The assumption was that CUS (Central US) ANF volumes would be named with a `cus-` prefix. In reality, both `cusprdanf01` and `eu2prdanf01` host volumes with `eu2-*` naming. The two accounts contain the same volume names but at different service levels (Standard vs Premium) and potentially in different regions. Commvault only backs up the `cusprdanf01` copies; the `eu2prdanf01` copies are marked NA by the business-rule override.

**Fix:** No code change needed — the P1 exact match on volume name works correctly because it strips the UNC hostname prefix and matches just the volume name segment. Once the content paths were available from the CSV report (Issue 17), all 26 CUS volumes matched correctly.

---

### Issue 19 — Unicode `charmap` error reading Commvault CSV reports on Windows agent

**Symptom:** Pipeline run failed inside `commvault_volume_mapper.py` with:
```
[COMMVAULT][ERROR] Commvault mapper raised an exception:
'charmap' codec can't encode character '\u2192' in position 29: character maps to <undefined>
```

**Root cause (two separate causes):**

1. **File reading:** The Commvault Command Center CSV exports contain a `→` character (U+2192, "rightwards arrow") in their 3-line preamble header. Python's default `open()` on Windows uses the system `charmap` (cp1252), which cannot encode U+2192.

2. **stdout encoding:** The same character was being echoed to the pipeline log via a `print()` statement. The Windows console also uses cp1252 by default, so even after fixing the file read, printing the raw preamble would still fail.

**Fix:**
1. Changed the `open()` call in `_read_report()` to use `encoding="utf-8-sig", errors="replace"` — the preamble arrow is replaced with `?` rather than raising an exception.
2. Added `PYTHONIOENCODING: "utf-8"` to the pipeline YAML environment block — forces Python's stdout/stderr to use UTF-8 so any Unicode characters in print output don't cause the pipeline step to abort.

**Commit:** `02b2ed4` on branch `sritam_mohanty_05072026`

---

### Issue 20 — Volumes matched in SubClient report but absent from Data Protection report shown as `True` (incorrect)

**Symptom:** 31 volumes appeared as `backup_configured=True` but had an empty `last_backup_date`. These were all in the `T Drive RO` subclient on `marprdbkp34` and the `QuantBackups2` subclient. On investigation the last backups for these subclients ran in December 2025 or earlier — they are effectively inactive.

**Root cause:** The original mapper logic set `backup_configured=True` whenever a subclient match was found, regardless of whether the Data Protection report contained a recent backup date for that subclient. Subclients that have been retired, excluded from SLA, or simply not run recently still appear in the SubClient Configuration report but not in the Data Protection report's recent-run rows.

**Fix:** Added a three-way result instead of a boolean:
```python
# If matched but no date in Data Protection report → not actively reporting → NA
if matched_sc is not None and not matched_date:
    configured_flag = "NA"
elif matched_sc is not None:
    configured_flag = True
else:
    configured_flag = False
```
This ensures `last_backup_date` is only non-empty when `backup_configured=True`, and volumes with stale/inactive subclients are clearly distinguishable from both actively-backed-up volumes and volumes with no backup at all.

**Commit:** `2a7e617` on branch `sritam_mohanty_05072026`

---

### Issue 21 — `backup_status.csv` schema missing `last_backup_date` column

**Symptom:** The `backup_status.csv` file previously had no `last_backup_date` column. Power BI would not be able to show when a volume was last backed up, or flag volumes whose last backup is old.

**Root cause:** The original schema was designed when Commvault returned only a boolean backup-configured flag. The Data Protection report introduced actual date data.

**Fix:** Added `last_backup_date` column to `BACKUP_COLS` in `config.py` and to the `backup_rows` assembly logic in `volume_reporting_main.py`. For `NA` volumes the column is always empty; for `True` volumes it contains the `YYYY-MM-DD` date from the Data Protection report; for `False` volumes it is empty.

---

### Issue 22 — DP volumes causing incorrect Power BI `ALLEXCEPT` filter stripping

**Symptom:** After adding DP/LS volumes (with `volume_type` field) and adding a `volume_type` slicer to Power BI Page 3, the Total Used TB / Total Size TB / Total Avail TB card visuals showed inconsistent values. Selecting `volume_type = RW` on the slicer did not affect the TB totals — they always showed all-volume figures.

**Root cause:** The original TB measures used `ALL(volume_snapshots)` to compute the latest date, which cleared ALL filters on `volume_snapshots` including the `volume_type` slicer filter context. The computed "latest date" was then used in a `CALCULATE(... snapshot_date = LatestDate)` which did not re-apply `volume_type`.

**Fix:** Changed `ALL(volume_snapshots)` to `ALLEXCEPT(volume_snapshots, volume_snapshots[volume_type])` in all three TB measures and in `Volumes Over 80pct Full`. This preserves the `volume_type` filter context when resolving the latest date, so the slicer correctly scopes the measures.

```dax
-- BEFORE (wrong)
VAR LatestDate = CALCULATE(MAX(volume_snapshots[snapshot_date]), ALL(volume_snapshots))

-- AFTER (correct)
VAR LatestDate = CALCULATE(MAX(volume_snapshots[snapshot_date]), ALLEXCEPT(volume_snapshots, volume_snapshots[volume_type]))
```

---

### Issue 23 — `Get-DfsnRoot` not found on build agent

**Symptom:** `dfs_collector.py` raised `FileNotFoundError` when running PowerShell `Get-DfsnRoot` on the Windows build agent.

**Root cause:** The `Get-DfsnRoot` / `Get-DfsnFolderTarget` cmdlets require the `DFSN` PowerShell module, which is part of the `RSAT-DFS-Mgmt-Con` Windows feature. The feature was not installed on the build agent (`SBLD1` / `SBLD2`).

**Fix:** Added a new pipeline step (Step 4c in the YAML) that checks for the module before attempting installation:

```powershell
$mod = Get-Module -ListAvailable -Name DFSN
if (-not $mod) {
    Write-Host "DFSN module not found - installing RSAT-DFS-Mgmt-Con..."
    Install-WindowsFeature -Name RSAT-DFS-Mgmt-Con -IncludeManagementTools
} else {
    Write-Host "DFSN module already present: $($mod.Version)"
}
```

---

### Issue 24 — ONTAP volume names truncated in `vserver cifs share show` table output

**Symptom:** When `dfs_collector.py` initially used `vserver cifs share show` (tabular output), volume names longer than ~18 characters were truncated (e.g. `marbkp-sqlbkp-vo` instead of `marbkp-sqlbkp-vol01`). Lookups for these shares failed, producing incomplete DFS mapping.

**Root cause:** ONTAP's tabular display automatically truncates long values to fit column widths. This is inherent to the default `show` output format.

**Fix:** Switched to `vserver cifs share show -instance` which outputs each record as key:value pairs with no column width constraint. Volume names are fully rendered. The parser was updated to match the exact ONTAP field labels: `Vserver:`, `Share:`, `Volume Name:`.

---

### Issue 25 — Wrong CIFS share field label names in parser

**Symptom:** After switching to `-instance` output, the parser still produced an empty `share_map` (0 CIFS shares). DFS mapping returned only ANF volumes.

**Root cause:** The initial regex patterns used `Vserver Name:`, `Share Name:`, and `Volume Name:` as expected labels. The actual ONTAP CLI `-instance` output uses `Vserver:` and `Share:` (without "Name" suffix). Only `Volume Name:` was correct.

**Fix:** Updated all three regex patterns to match the exact ONTAP output format:

```python
# WRONG
re.match(r'^\s*Vserver Name:\s+(.+)', line)
re.match(r'^\s*Share Name:\s+(.+)', line)

# CORRECT
re.match(r'^\s*Vserver:\s+(.+)', line)
re.match(r'^\s*Share:\s+(.+)', line)
```

---

### Issue 26 — DAX DFS Paths measure blank in mixed-table Inventory page

**Symptom:** A DAX measure was created to look up DFS paths from the `dfs_mapping` table using `SELECTEDVALUE` on `volume_name`. On the Inventory page table visual (which combines columns from `volume_snapshots` and `backup_status`), the measure always returned blank.

**Root cause:** `SELECTEDVALUE` evaluates the filter context for the target table, but in a row context spanning multiple tables (as a calculated measure in a table visual with columns from different tables), the row context does not propagate to the unrelated `dfs_mapping` table. `MAX` and `FILTER`-based DAX approaches also failed because `dfs_mapping` has no model relationship to `volume_snapshots`.

**Fix:** Abandoned the DAX approach entirely. Instead, merged `dfs_mapping` directly into `volume_snapshots` in Power Query (Left Outer join on `volume_name`). Multiple DFS paths per volume are concatenated using `Text.Combine` in a `Table.Group` step. The result is a native `dfs_path` column in `volume_snapshots` — available in any visual without DAX lookup logic.

---

## 11. Current Status

| Component | Status | Notes |
|-----------|--------|-------|
| Azure AD app registration | Working | `GMO Storage Volume Reporting`, admin consent granted |
| SharePoint connectivity | Working | Validated with `validate_sharepoint.py` |
| ONTAP collection | Working | 347 volumes from 6 clusters (283 RW + 64 DP/LS) |
| ANF collection | Working | 55 volumes (cusprdanf01: 26, eu2prdanf01: 29) — all RW |
| SharePoint upload | Working | All 4 CSVs visible in Platform Engineering site |
| Commvault backup status | Working | 58 True / 55 False / 234 NA out of 347 volumes |
| DFS mapping | **Working** | 274 DFS path→volume records; 468 Offline/mirror targets skipped |
| ONTAP aggregate collection | **Working** | 15 aggregates, 1,574 TB total physical capacity |
| Power BI dashboards | **Complete** | 3-page report (Platform Overview removed); ONTAP physical aggr data; bookmark navigation; Inventory growth rates |
| ServiceNow integration | Not started | See Section 12 for roadmap |
| PR to master | **Complete** | Multiple PRs merged to `master` (May–June 2026) |

**Last confirmed pipeline run (June 11, 2026):**
- 347 volumes collected (283 RW ONTAP + 64 DP/LS ONTAP + 55 ANF)
- Commvault mapper: CSV-report based (no API calls)
  - 58 True / 55 False / 234 NA (all DP/LS → NA, all eu2prdanf01 → NA)
- DFS mapping: 274 path→volume records from 6 ONTAP clusters + 2 ANF accounts
- ONTAP aggregates: 15 aggregates, 1,574 TB total, 877 TB used (54.24%)
- All 4 CSVs uploaded to SharePoint successfully

### Current NA breakdown

| Reason | Count (approx) |
|--------|----------------|
| DP/LS type ONTAP volumes (SnapMirror replicas — never directly backed up) | 64 |
| ONTAP system/root/test/infra volumes (name contains `tst`, `root`, `esx`, `cvault`, `sqlbkp`, `test`) | ~100 |
| All `eu2prdanf01` ANF volumes (no Commvault backup by design) | 29 |
| Matched subclient but no recent backup date in Data Protection report | ~41 |

### Known Remaining Items

| # | Item | Detail |
|---|------|--------|
| 1 | 55 False volumes | Review against Commvault UI to confirm genuinely unprotected; some may be decommissioned shares or ANF DR replicas |
| 2 | Growth rate reliability | Growth Rate measures become meaningful after 2+ weeks of daily data |
| 3 | ServiceNow CMDB integration | See Section 12 |

---

## 12. Future Roadmap

### Power BI — Further Enhancements

The initial dashboard is live (see Section 9). Potential enhancements:
- Add a **capacity forecast** visual: project days-until-full based on `Growth Rate GB per Day` vs `avail_gb`
- Add email **subscriptions** in Power BI Service to send the report to stakeholders weekly
- Move the `.pbix` to a shared team workspace so other team members can view/edit

### ServiceNow CMDB Integration

Create `servicenow_updater.py` to:
- POST/PATCH volume records to the `cmdb_ci_storage_volume` ServiceNow table.
- Map CSV fields to CMDB fields: `name`, `capacity`, `disk_space`, `u_platform`, `u_cluster`, etc.
- Run as an optional step in the pipeline after SharePoint upload.

**Note:** Volume-full alerting is already handled by the existing PowerShell scripts — do not replicate it here.

### Backup-Missing Incident Creation

Add a step that reads `backup_status.csv` and creates ServiceNow incidents for any volume where `backup_configured = False` and the platform/cluster is in-scope for Commvault backup. This is separate from volume-full alerting.

### Merge to Master

**Complete (May 30, 2026).** Branch `sritam_mohanty_05072026` merged to `master`. The daily 06:00 UTC scheduled pipeline is now active on `master`.

### Additional ONTAP Clusters

To add clusters: edit `Monitoring/netapp_clusters.conf` — one hostname per line. No code changes needed.

### Additional ANF Accounts

To add accounts: edit the `ANF_ACCOUNTS` list in `Storage-Reporting/config.py`.

---

## 13. File Inventory

| File | Purpose |
|------|---------|
| `Storage-Reporting/config.py` | Central configuration; all secrets from env vars; CSV schemas for all 4 output files |
| `Storage-Reporting/ontap_volume_collector.py` | SSH into ONTAP clusters; parse `volume show -instance`; all volume types including DP/LS |
| `Storage-Reporting/ontap_aggr_collector.py` | SSH into ONTAP clusters; parse `aggr show -instance`; produces `aggr_snapshots.csv` |
| `Storage-Reporting/anf_volume_collector.py` | ARM REST API + Azure Monitor for ANF volumes; all tagged `volume_type=RW` |
| `Storage-Reporting/commvault_volume_mapper.py` | Reads Commvault CSV reports; P1 exact path match + P2 word fallback; no API calls |
| `Storage-Reporting/dfs_collector.py` | SSH CIFS share→volume map + PowerShell DFS enumeration; produces `dfs_mapping.csv` |
| `Storage-Reporting/sharepoint_helper.py` | Upload/download CSVs via Microsoft Graph API |
| `Storage-Reporting/volume_reporting_main.py` | Orchestrator; merges data; NA override rules (DP/LS first); manages SharePoint I/O |
| `Storage-Reporting/validate_sharepoint.py` | One-time validation script for SharePoint connectivity |
| `Storage-Reporting/requirements.txt` | Python dependencies: paramiko, requests, urllib3 |
| `Pipelines/storage-volume-reporting-pipeline.yml` | Azure DevOps pipeline definition; includes RSAT-DFS-Mgmt-Con install step |
| `Monitoring/netapp_clusters.conf` | ONTAP cluster hostname list (shared with existing scripts) |

> **Note:** `token_manager.py` was previously copied into `Storage-Reporting/` to support the Commvault REST API approach. It is no longer used or required by this solution and can be removed.

---

*Document last updated: June 11, 2026*
*Branch: multiple PRs merged to `master` (May–June 2026); `sritam_mohanty_06102026` active*
*Pipeline last successful run: June 11, 2026 — 347 volumes, 15 aggregates (1,574 TB physical), 274 DFS mappings, 58 True / 55 False / 234 NA*
*Power BI dashboard live in Power BI Service — 3 pages (Platform Overview removed), physical aggregate data, scheduled refresh 07:00 UTC daily*
