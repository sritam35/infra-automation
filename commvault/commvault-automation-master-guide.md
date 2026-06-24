# Commvault Automation — Master Reference Guide

**Author**: Sritam Mohanty
**Created**: February 11, 2026
**Last Updated**: February 16, 2026
**Status**: Active

---

## Table of Contents

1. [Project Overview](#1-project-overview)
2. [Architecture](#2-architecture)
3. [Prerequisites](#3-prerequisites)
4. [Repository Structure](#4-repository-structure)
5. [Part 1 — Build Pipeline Setup](#5-part-1--build-pipeline-setup)
6. [Part 2 — Release Pipeline Setup](#6-part-2--release-pipeline-setup)
7. [Part 3 — Token Management System](#7-part-3--token-management-system)
8. [Part 4 — Datalake Backup Exclusion Automation](#8-part-4--datalake-backup-exclusion-automation)
9. [Part 5 — Tidal Scheduler Configuration](#9-part-5--tidal-scheduler-configuration)
10. [Issue Log & Resolutions](#10-issue-log--resolutions)
11. [Troubleshooting](#11-troubleshooting)
12. [Maintenance & Best Practices](#12-maintenance--best-practices)
13. [Key Lessons Learned](#13-key-lessons-learned)
14. [Pipeline Variables Reference](#14-pipeline-variables-reference)
15. [Appendix — Quick Command Reference](#15-appendix--quick-command-reference)

---

## 1. Project Overview

**Objective:** Automate Commvault subclient (ID: 1776) backup exclusion management for Azure Blob Storage datalake, ensuring only the current quarter's history data is backed up while excluding all other quarters dynamically.

**What this covers:**
- CI/CD pipeline for deploying Commvault Python automation scripts from Azure DevOps to a Linux NFS mount point
- Token management system to handle Commvault API authentication lifecycle
- Dynamic backup exclusion logic for Azure Blob datalake containers
- Chronological log of all configuration issues encountered and their resolutions

**Key Servers:**
| Role | Server |
|------|--------|
| Commvault Server | commvault-server |
| Linux Automation Server | linux-automation-server |

**Deployment Path:** `/mnt/automation/nfs/backupautomation/commvault`
**Network (UNC) Path:** `\fileserver\automation\backupautomation\commvault`
**Scripts Location (Tidal Jobs):** `/mnt/automation/nfs/backupautomation/commvault2/`

---

## 2. Architecture

### CI/CD Workflow

```
Code Commit (Commvault/*)
    ↓
Trigger Build Pipeline (commvault-automation-pipeline.yml)
    ↓
Build & Publish Artifacts
    ↓
Trigger Release Pipeline (Backup Automation Deployment)
    ↓
Deploy to Linux via SSH (as svc-netapp)
    ↓
Scripts Ready on linux-automation-server with Correct Ownership
    ↓
Tidal Scheduler Executes Scripts Monthly/Weekly
```

### Pipeline Components Summary

| Component | Details |
|-----------|---------|
| Build Pipeline | `Pipelines/commvault-automation-pipeline.yml` |
| Build Trigger | Commits to `Commvault/*` on master branch |
| Build Agent | SharedBuild (Windows) |
| Build Artifacts | `\\gmo\app\Build\DevOps\[Pipeline]\[BuildNumber]` |
| Release Pipeline | Backup Automation Deployment (Classic) |
| Release Trigger | Continuous deployment on successful build (master branch) |
| Deployment Agent | DevOpsPRD (DOPSPRD) |
| Deployment Method | **Copy files over SSH** (as `svc-netapp`) |
| Deployment Target | `/mnt/automation/nfs/backupautomation/commvault` |
| SSH Connection | `linux-automation-server` (user: svc-netapp) |

> **Important:** Earlier pipeline versions used Windows UNC path copy (`\fileserver\automation\backupautomation\commvault`), which caused NFS ownership issues. The pipeline now uses SSH-based deployment. See [Issue #10](#issue-10--file-ownership-and-permission-issues-from-windows-deployment) for full details.

---

## 3. Prerequisites

### Linux Server Mount Verification

Ensure the NetApp volume is mounted on linux-automation-server before deploying:

```bash
# Verify mount point exists
df -h | grep backupautomation

# Expected output:
# marprdsmb32_ha1a_nfs:/marprdsmb32_t0_backupautomation_vol/commvault  9.5G  6.0M  9.5G   1% /mnt/automation/nfs/backupautomation/commvault
```

**Mount Details:**
| Field | Value |
|-------|-------|
| Source | `marprdsmb32_ha1a_nfs:/marprdsmb32_t0_backupautomation_vol/commvault` |
| Mount Point | `/mnt/automation/nfs/backupautomation/commvault` |
| Size | 9.5 GB |

### Azure DevOps Service Connections Required

- **SharedBuild agent**: Read access to repository
- **DevOpsPRD (DOPSPRD) agent**: Can establish SSH connection using the `linux-automation-server` service connection
- **`linux-automation-server` SSH connection**: Authenticates to linux-automation-server as `svc-netapp`

---

## 4. Repository Structure

```
Storage/
├── Commvault/
│   ├── check_token_health.py           # Token health validation utility
│   ├── commvault_get_api.py            # GET API wrapper (with TokenManager)
│   ├── commvault_post_api.py           # POST API wrapper
│   ├── dynamic_datalakebkp_exclusions.py  # Main monthly exclusion script
│   ├── renew_token.py                  # Weekly token renewal script
│   ├── token_manager.py                # Core token lifecycle management library
│   └── Pipeline deployment guide.md   # (Superseded by this document)
└── Pipelines/
    └── commvault-automation-pipeline.yml
```

---

## 5. Part 1 — Build Pipeline Setup

### Step 1.1: Pipeline YAML File

**File**: `Pipelines/commvault-automation-pipeline.yml`

```yaml
# Commvault Automation pipeline
# Author: Sritam Mohanty
# Date: 02/11/2026
# Description: Build and deploy Commvault automation scripts
# Trigger: Commits to master branch under Commvault/*
# Pool: SharedBuild
# Version: 1.0

trigger:
  branches:
    include:
      - master
  paths:
    include:
      - Commvault/*

pool:
  name: 'SharedBuild'

steps:
- script: echo Hello There, Build Process Started!
  displayName: 'Start Build'

- task: CopyFiles@2
  inputs:
    Contents: |
      Commvault/**
    TargetFolder: '\\gmo\app\Build\DevOps\$(Build.DefinitionName)\$(Build.BuildNumber)'
  condition: succeeded()
  displayName: 'Copy Commvault files to Build Artifacts'

- task: PublishBuildArtifacts@1
  inputs:
    PathtoPublish: '\\gmo\app\Build\DevOps\$(Build.DefinitionName)\$(Build.BuildNumber)'
    ArtifactName: 'BuildDrop'
  condition: succeeded()
  displayName: 'Publish Commvault Automation Artifacts'
```

### Step 1.2: Commit and Push

```powershell
cd C:\Azure_Devops\Storage
git add Pipelines/commvault-automation-pipeline.yml
git commit -m "Add Commvault automation build pipeline"
git push origin master
```

### Step 1.3: Create Build Pipeline in Azure DevOps

1. Go to: **Azure DevOps → Pipelines → Pipelines → New pipeline**
2. Click **"Use the classic editor"**
3. Source:
   - Source type: **Azure Repos Git**
   - Repository: **Storage**
   - Default branch: **master**
4. Template: Select **YAML** → Apply
5. Configure:
   - **Name**: `Commvault-Automation-Pipeline`
   - **YAML file path**: `Pipelines/commvault-automation-pipeline.yml`
6. Click **"Save & queue"** → **"Save and run"**
7. Verify build status: ✅ Success, artifact `BuildDrop` published

---

## 6. Part 2 — Release Pipeline Setup

### Step 2.1: Create New Release Pipeline

1. Go to: **Azure DevOps → Pipelines → Releases → New pipeline**
2. Select **"Empty job"** → Apply
3. Name the stage: **PRD** (Production)

### Step 2.2: Add Build Artifact

1. Click **"+ Add an artifact"**
   - Source type: **Build**
   - Source (build pipeline): **Commvault-Automation-Pipeline**
   - Default version: **Latest**
   - Source alias: `_Backup Automation Pipeline`
2. Click **"Add"**

### Step 2.3: Enable Continuous Deployment Trigger

1. Click the **lightning bolt icon** on the artifact
2. Toggle **"Continuous deployment trigger"** to **Enabled**
3. Under "Build branch filters" → **+ Add** → Type: **Include**, Branch: **master**

### Step 2.4: Configure Stage Tasks

1. Click **"1 job, 0 task"** in the PRD stage
2. Configure **Agent job**:
   - Agent pool: **DevOpsPRD (DOPSPRD)**

3. Add **"Copy files over SSH"** task:
   - Click **"+"** next to "Agent job"
   - Search for **"Copy files over SSH"**
   - Click **"Add"**

4. Configure the **"Copy files over SSH"** task:

   | Field | Value |
   |-------|-------|
   | SSH service connection | `linux-automation-server` |
   | Source folder | `$(System.DefaultWorkingDirectory)/_Backup Automation Pipeline/BuildDrop/Commvault` |
   | Contents | `**` |
   | Target folder | `/mnt/automation/nfs/backupautomation/commvault` |

   > **Note:** This SSH-based task replaced the original "Copy Files" (Windows UNC path) task. See [Issue #10](#issue-10--file-ownership-and-permission-issues-from-windows-deployment) for the reason.

### Step 2.5: Save the Pipeline

1. Click **"Save"** → Folder: `\` (root)
2. Comment: `"Create Commvault automation release pipeline"`
3. Rename pipeline to: **"Backup Automation Deployment"**

### Step 2.6: Test — Manual Release

1. Click **"Create release"**
2. Verify artifact version (e.g., 20260211.1)
3. Stages for trigger: **PRD** (checked)
4. Click **"Create"** and monitor logs

### Step 2.7: Verify Deployment on Linux Server

```bash
# SSH to linux-automation-server
ssh root@linux-automation-server

# Navigate to deployment location
cd /mnt/automation/nfs/backupautomation/commvault

# List deployed files (expected ownership: svc-netapp)
ls -la

# Expected output:
# -rwx------ 1 svc-netapp gmo  5196 Feb 16 09:54 check_token_health.py
# -rwx------ 1 svc-netapp gmo  3326 Feb 16 09:54 commvault_get_api.py
# -rwx------ 1 svc-netapp gmo 56084 Feb 16 09:54 commvault_post_api.py
# -rwx------ 1 svc-netapp gmo  ...  Feb 16 09:54 dynamic_datalakebkp_exclusions.py
# -rwx------ 1 svc-netapp gmo  ...  Feb 16 09:54 renew_token.py
# -rwx------ 1 svc-netapp gmo  ...  Feb 16 09:54 token_manager.py
```

### Automatic Deployment Workflow (Production)

Once continuous deployment is enabled:

```powershell
# 1. Make changes locally
code C:\Azure_Devops\Storage\Commvault\token_manager.py

# 2. Commit and push — pipeline triggers automatically
git add Commvault/token_manager.py
git commit -m "Update token manager logic"
git push origin master

# Pipeline runs automatically — no manual intervention needed
```

---

## 7. Part 3 — Token Management System

### Background

The Commvault API access token expires every 30 minutes. Running scripts on a monthly Tidal schedule means the token is always expired by execution time. A complete token management system was created to handle this.

**Token Lifecycle:**

| Token Type | Validity |
|------------|----------|
| Access Token | 30 minutes |
| Refresh Token | 1 year from creation |
| Renewal Window | Within 14 days after access token expiry |
| Renewal Behavior | Returns same access token (reactivated) + new refresh token |

### Files Created

| File | Purpose |
|------|---------|
| `token_manager.py` | Core library — stores tokens in `.commvault_tokens.json`, detects expiry, renews via API |
| `renew_token.py` | Weekly lightweight wrapper — calls `TokenManager.get_valid_token()` |
| `check_token_health.py` | Validates current token health |

### Critical Token Management Rules

1. **Only ONE machine should manage tokens** — whichever machine renews first invalidates the token on all others. The production Linux server (`linux-automation-server`) is the single source of truth.
2. Token file (`.commvault_tokens.json`) must be owned by `svc-netapp` (the Tidal service account).
3. Token file permissions must be `600` (owner read/write only).

### Token Initialization on Linux Server

```bash
su - svc-netapp
cd /mnt/automation/nfs/backupautomation/commvault2
python3 token_manager.py "<access_token>" "<refresh_token>"
```

If initialized as root, fix ownership:
```bash
python3 token_manager.py "<access_token>" "<refresh_token>"
chown svc-netapp:svc-netapp .commvault_tokens.json
```

### Commvault API Endpoint Notes

The working API endpoint for token renewal on `commvault-server` is:

```
POST https://commvault-server/commandcenter/api/v4/AccessToken/Renew
```

> **Warning:** Commvault documentation references `/webservice/V4/AccessToken/Renew` — this does **not** exist on this server. See [Issue #6](#issue-6--token-renewal-api-endpoint-returns-404).

**Required authentication header:**
```
Authtoken: <access_token>
```
> Standard `Authorization: Bearer` header does **not** work. Commvault uses its own `Authtoken` header.

**Renewal response format (flat, not nested):**
```json
{
    "accessTokenId": 9,
    "tokenName": "Testing",
    "accessToken": "347405...",
    "refreshToken": "123BFCC1-...",
    "renewableUntilTimestamp": 1778644800,
    "tokenExpiryTimestamp": 1770926484,
    "refreshTokenExpiryTimestamp": 1772134284
}
```

---

## 8. Part 4 — Datalake Backup Exclusion Automation

### Overview

The `dynamic_datalakebkp_exclusions.py` script manages Commvault subclient (ID: 1776) backup exclusions for 21 Azure Blob Storage containers. It runs on the 1st of every month via Tidal and:
- Determines the current active quarter
- Generates exclusion paths for all non-current history quarters
- Submits the full inclusion + exclusion payload to the Commvault API (OVERWRITE operation)

### All 21 Container Inclusion Paths

The POST payload must include **all 21 containers** every time (OVERWRITE — not incremental):

```python
content = [
    {"path": "/app-dae"},
    {"path": "/app-gdm"},
    {"path": "/app-hld"},
    {"path": "/app-ldg"},
    {"path": "/app-pdb"},
    {"path": "/app-ser"},
    {"path": "/demo"},
    {"path": "/lab"},
    {"path": "/laboratory"},
    {"path": "/raw"},
    {"path": "/samples-dae"},
    {"path": "/src-blackrock"},
    {"path": "/src-broadridge"},
    {"path": "/src-cvent"},
    {"path": "/src-mandatewire"},
    {"path": "/src-mmd"},
    {"path": "/src-on24"},
    {"path": "/src-pivotal-crm"},
    {"path": "/src-vdm"},
    {"path": "/synapse"},
    {"path": "/synfs-gmoperfsyslwr"},
]
```

### Key Path Rules

| Rule | Detail |
|------|--------|
| No trailing slashes | `2025_q4` ✅ — `2025_q4/` ❌ |
| Correct vendor data path | `/src-vdm/cleansed/` ✅ — `/src-vdm/curated/` ❌ |
| Quarter generation | `years_ahead=0` (current year only) — no need to generate future quarters |

---

## 9. Part 5 — Tidal Scheduler Configuration

| Job Name | Command | Parameters | Schedule |
|----------|---------|------------|----------|
| `110_commvault_token_renewal` | `/opt/tidalprd_linux/remote_shell.sh` | `-u 'svc-netapp' -h linux-automation-server -s 'python3 /mnt/automation/nfs/backupautomation/commvault2/renew_token.py'` | Every Sunday 00:00 |
| `111_datalake_backup_exclusion` | `/opt/tidalprd_linux/remote_shell.sh` | `-u 'svc-netapp' -h linux-automation-server -s 'python3 /mnt/automation/nfs/backupautomation/commvault2/dynamic_datalakebkp_exclusions.py'` | 1st of every month 00:30 |

> **Note:** Weekly token renewal (job 110) runs every Sunday to stay well within the 14-day renewal window before the monthly script (job 111) executes.

---

## 10. Issue Log & Resolutions

All issues listed in chronological order.

---

### Issue #1 — Incorrect Vendor Data Exclusion Paths
**Date:** January 15, 2026 | **Severity:** Critical
**Scripts Affected:** `commvault_post_api.py`, `update_history_exclusions.py`

**Problem:**
All 143 vendor data exclusion paths under `src-vdm` pointed to `/src-vdm/curated/` instead of the correct `/src-vdm/cleansed/`.

```
WRONG:   /src-vdm/curated/factset/gr-v2/gr-item
CORRECT: /src-vdm/cleansed/factset/gr-v2/gr-item
```

**Fix:** Replaced all 143 path instances across 2 files, changing `/src-vdm/curated/` → `/src-vdm/cleansed/`.

**Verification:** `commvault_post_api.py` returned `errorCode=0, warningCode=0`.

---

### Issue #2 — Trailing Slashes on History Exclusion Paths
**Date:** January 16, 2026 | **Severity:** Critical
**Script Affected:** `dynamic_datalakebkp_exclusions.py`

**Problem:**
History exclusion paths were generated with trailing slashes. Commvault requires exact string matching — folders in Azure Blob do not have trailing slashes, so exclusions were silently failing.

```
WRONG:   /app-gdm/curated/gdm/history/credit-seniority/2025_q4/
CORRECT: /app-gdm/curated/gdm/history/credit-seniority/2025_q4
```

**Fix:**
```python
# Before (broken):
path = f"/app-gdm/curated/gdm/history/{table}/{quarter}/"

# After (fixed):
path = f"/app-gdm/curated/gdm/history/{table}/{quarter}"
```

**Verification:** Re-executed script; exclusions appeared correctly in Commvault UI.

---

### Issue #3 — Missing Container Inclusion Paths (1 vs 21)
**Date:** January 16, 2026 | **Severity:** Critical
**Script Affected:** `dynamic_datalakebkp_exclusions.py`

**Problem:**
`build_payload()` only included 1 container path (`/app-gdm`) instead of all 21. Since POST uses OVERWRITE semantics, 20 containers were effectively excluded from all backups.

**Fix:** Added all 21 container inclusion paths to `build_payload()` (see [Section 8](#8-part-4--datalake-backup-exclusion-automation) for the full list).

**Verification:** Compared with working `commvault_post_api.py` — all 21 containers present.

---

### Issue #4 — Over-Generation of Future Quarter Exclusions
**Date:** January 17, 2026 | **Severity:** Low (Optimization)
**Script Affected:** `dynamic_datalakebkp_exclusions.py`

**Problem:**
`generate_all_quarters()` used `years_ahead=3`, generating quarters from 2024–2029 (24 quarters). Since the monthly script always catches quarter changes, future quarter generation was unnecessary.

**Fix:**
- Reduced `years_ahead=3` → `years_ahead=1` (16 quarters)
- Further reduced to `years_ahead=0` (current year only, ~12 quarters)

**Result:** Fewer exclusion paths, faster execution, no functional difference.

---

### Issue #5 — Access Token Expires Every 30 Minutes
**Date:** January 26, 2026 | **Severity:** Critical
**Scripts Affected:** All scripts using Commvault API

**Problem:**
Commvault access tokens expire after 30 minutes. Hard-coded or environment variable tokens make automated monthly execution impossible.

**Solution:** Created the complete token management system described in [Part 3](#7-part-3--token-management-system):
- `token_manager.py` — Core library with persistent storage and auto-renewal
- `renew_token.py` — Weekly Tidal job wrapper
- Updated `dynamic_datalakebkp_exclusions.py` and `commvault_get_api.py` to use `TokenManager.get_valid_token()` instead of `os.getenv("API_AUTH_TOKEN")`

---

### Issue #6 — Token Renewal API Endpoint Returns 404
**Date:** February 12, 2026 | **Severity:** Critical
**Script Affected:** `token_manager.py`

**Problem:**
Token renewal failed with `404 Not Found` using the documented endpoint:
```
POST https://commvault-server/webservice/V4/AccessToken/Renew
```

**Discovery:**

| Endpoint | Status | Result |
|----------|--------|--------|
| `/webservice/V4/AccessToken/Renew` | 404 | Does not exist |
| `/commandcenter/api/AccessToken/Renew` | 403 | Exists but forbidden |
| `/commandcenter/api/v4/AccessToken/Renew` | **200** | **SUCCESS** |

**Three fixes applied to `token_manager.py`:**

**Fix 1 — Endpoint URL:**
```python
# Before:
TOKEN_RENEW_ENDPOINT = f"{COMMVAULT_URL}/webservice/V4/AccessToken/Renew"

# After:
TOKEN_RENEW_ENDPOINT = f"{COMMVAULT_URL}/commandcenter/api/v4/AccessToken/Renew"
```

**Fix 2 — Authentication Header:**
```python
# Before:
headers = {"Authorization": f"Bearer {access_token}"}

# After:
headers = {"Authtoken": access_token}
```

**Fix 3 — Response Parsing (flat, not nested):**
```python
# Before (broken — expected nested format):
new_access_token = response_data.get('token', {}).get('token')
new_refresh_token = response_data.get('token', {}).get('refreshToken')

# After (working — flat response):
new_access_token = response_data.get('accessToken')
new_refresh_token = response_data.get('refreshToken')
```

**Verification:** Token renewed successfully; GET and POST API calls returned 200.

---

### Issue #7 — Token File Path Mismatch
**Date:** February 13, 2026 | **Severity:** High
**Script Affected:** `token_manager.py`

**Problem:**
Token file path was hard-coded to:
```
/mnt/automation/nfs/storageautomation/automation/commvault/.commvault_tokens.json
```
But scripts were deployed to:
```
/mnt/automation/nfs/backupautomation/commvault2/
```

**Fix:**
```python
# Before:
TOKEN_FILE = "/mnt/automation/nfs/storageautomation/automation/commvault/.commvault_tokens.json"

# After:
TOKEN_FILE = "/mnt/automation/nfs/backupautomation/commvault2/.commvault_tokens.json"
```

---

### Issue #8 — Token File Permission Denied (Tidal/svc-netapp)
**Date:** February 13, 2026 | **Severity:** High
**Script Affected:** `token_manager.py` (runtime)

**Problem:**
Token file was initialized as `root` with `chmod 600`. When Tidal ran the script as `svc-netapp`, it received:
```
[WARNING] Failed to load tokens: [Errno 13] Permission denied:
'/mnt/automation/nfs/backupautomation/commvault2/.commvault_tokens.json'
```

**Fix:** Re-initialize tokens as `svc-netapp`:
```bash
# Option A: Initialize directly as svc-netapp
su - svc-netapp
cd /mnt/automation/nfs/backupautomation/commvault2
python3 token_manager.py "<access_token>" "<refresh_token>"

# Option B: Initialize as root, then fix ownership
python3 token_manager.py "<access_token>" "<refresh_token>"
chown svc-netapp:svc-netapp .commvault_tokens.json
```

---

### Issue #9 — Token Invalidated by Cross-Machine Renewal
**Date:** February 13, 2026 | **Severity:** High
**Impact:** Linux scripts returning 401

**Problem:**
Both Windows (dev) and Linux (prod) were initialized with the same token. When `find_renew_endpoint.py` ran on Windows and renewed the token, Commvault issued a new access token and invalidated the old one. Linux still held the old (now invalid) token.

**Symptom:**
```
[SUCCESS] Valid access token obtained  ← local file check passed (timer OK locally)
[HTTP ERROR] 401 Client Error         ← Commvault rejected it (token replaced server-side)
```

**Fix:** Generated a **fresh** token from Commvault UI and initialized only on the Linux production server. Stopped running renewal scripts from Windows.

**Rule:** Only ONE machine manages token lifecycle. `linux-automation-server` is the single source of truth.

---

### Issue #10 — File Ownership and Permission Issues from Windows Deployment
**Date:** February 13–16, 2026 | **Severity:** Critical
**Impact:** Scripts deployed with incorrect ownership, preventing Tidal scheduler execution

**Problem:**
The release pipeline used Windows file copy (UNC path `\fileserver\automation\backupautomation\commvault`). Files landed on the Linux NFS mount with numeric UID ownership instead of `svc-netapp`:

```bash
ls -l /mnt/automation/nfs/backupautomation/commvault
-rwx------ 1 1631689629 gmo 5196 Feb 13 11:51 check_token_health.py
```
- Owner: numeric UID `1631689629` (Windows SID → Linux UID mapping)
- Should be: `svc-netapp`

**Root Cause:** Windows file copy via SMB/CIFS maps the Windows SID to a numeric UID that doesn't correspond to any Linux user. NFS security (`root_squash`) prevents even root from changing ownership post-deployment.

**Attempted fixes that FAILED:**
1. SSH task to run `chown` → `Operation not permitted` (NFS restriction)
2. Post-deployment permission script → Same NFS security restriction

**Solution: SSH-Based Deployment**

Changed release pipeline:

| Change | Before | After |
|--------|--------|-------|
| Task type | "Copy Files" (Windows) | "Copy files over SSH" |
| Agent | SharedBuild | DevOpsPRD (DOPSPRD) |
| Target path | `\fileserver\automation\backupautomation\commvault` | `/mnt/automation/nfs/backupautomation/commvault` |
| SSH connection | N/A | `linux-automation-server` (as `svc-netapp`) |

**Result after fix:**
```bash
ls -l /mnt/automation/nfs/backupautomation/commvault
-rwx------ 1 svc-netapp gmo 5196 Feb 16 09:54 check_token_health.py
-rwx------ 1 svc-netapp gmo 3326 Feb 16 09:54 commvault_get_api.py
-rwx------ 1 svc-netapp gmo 56084 Feb 16 09:54 commvault_post_api.py
```
✅ Owner: `svc-netapp` | ✅ Group: `gmo` | ✅ Permissions: `700`
✅ Tidal scheduler executes scripts directly — no manual workaround needed

**Why SSH works:** Files copied via SSH as `svc-netapp` are created with `svc-netapp` ownership from the start. NFS security then applies to the correct owner, and no post-deployment changes are needed.

---

## 11. Troubleshooting

### Build Pipeline Issues

| Issue | Solution |
|-------|----------|
| Pipeline not triggering on commit | Verify trigger paths include `Commvault/*`, commit is to `master`, pipeline is not disabled |
| Artifact not published | Check build logs for PublishBuildArtifacts errors; verify `\\gmo\app\Build\DevOps\` is accessible from SharedBuild agent |

### Release Pipeline Issues

| Issue | Solution |
|-------|----------|
| SSH copy task fails with "Access denied" | Verify `linux-automation-server` SSH service connection is active and the target directory exists on linux-automation-server |
| Continuous deployment not triggering | Confirm CD trigger is enabled (lightning bolt icon); verify branch filter includes `master`; check build completed successfully |
| Wrong files deployed | Verify Source Folder ends with `/Commvault`; confirm Contents is `**` |
| Files deployed with wrong owner (numeric UID) | Pipeline is using Windows copy — switch to SSH-based deployment (see [Issue #10](#issue-10--file-ownership-and-permission-issues-from-windows-deployment)) |

### Token / API Issues

| Issue | Solution |
|-------|----------|
| Token renewal → 404 | Use endpoint `/commandcenter/api/v4/AccessToken/Renew` (not `/webservice/`) |
| Token renewal → 403 | Missing or wrong auth header; use `Authtoken: <token>` (not `Authorization: Bearer`) |
| 401 errors after renewal | Another machine renewed the token — reinitialize on Linux server with a fresh token from Commvault UI |
| Permission denied on token file | Token file not owned by `svc-netapp`; re-initialize under that account or `chown` the file |

---

## 12. Maintenance & Best Practices

### Updating Deployment Path

1. Update the SSH task's **Target folder** in the release pipeline
2. Update `TOKEN_FILE` path in `token_manager.py`
3. Update Tidal job parameters to point to the new path

### Adding New Python Scripts

1. Add Python files to `Commvault/` locally
2. Commit and push to master — pipeline deploys automatically

### Modifying Build Trigger

**File**: `Pipelines/commvault-automation-pipeline.yml`

```yaml
trigger:
  branches:
    include:
      - master
      - develop        # Add additional branches as needed
  paths:
    include:
      - Commvault/*
      - Commvault/subfolder/*
```

### Version Control

- Always commit YAML pipeline changes to the repository
- Use meaningful commit messages
- Tag releases for major deployments

### Monitoring

- Set up email notifications for failed builds/releases
- Regularly review pipeline run history
- Monitor disk space on artifact storage and deployment target

### Security

| Resource | Access |
|----------|--------|
| Build Pipeline | Read access to repository |
| Release Pipeline (SSH) | `linux-automation-server` connection (as `svc-netapp`) |
| Token file | `chmod 600`, owned by `svc-netapp` |

---

## 13. Key Lessons Learned

1. **Path precision is critical** — Commvault requires exact string matching. A trailing slash causes exclusions to silently fail.
2. **OVERWRITE operations require complete data** — Every POST must include ALL 21 inclusion paths and ALL exclusion paths; partial payloads remove what's missing.
3. **Commvault API endpoints vary by installation** — Documentation says `/webservice/`; this server uses `/commandcenter/api/v4/`. Always test against the actual server.
4. **Commvault uses `Authtoken` header** — Not the standard `Authorization: Bearer`. This is Commvault-specific.
5. **Token renewal invalidates old tokens** — Only one machine should manage token lifecycle to avoid cross-invalidation. The production Linux server is the single source of truth.
6. **Service account permissions matter** — Token files must be owned by the user Tidal runs scripts as (`svc-netapp`).
7. **Weekly renewal is essential** — A 30-minute token combined with a monthly script guarantees failure. Weekly renewal stays well within the 14-day window.
8. **SSH deployment for Linux NFS targets** — Windows file copy to NFS mounts creates unfixable ownership issues. Use SSH-based deployment to ensure correct ownership from the start.
9. **NFS root_squash security** — Even root cannot change file ownership on NFS mounts with `root_squash`. Design deployment to avoid needing post-deployment ownership changes.
10. **Don't generate unnecessary future data** — `years_ahead=0` in quarter generation is sufficient since the monthly script catches all real quarter changes promptly.

---

## 14. Pipeline Variables Reference

### Build Pipeline (YAML)

| Variable | Value | Description |
|----------|-------|-------------|
| `$(Build.DefinitionName)` | Auto-generated | Build pipeline name |
| `$(Build.BuildNumber)` | Auto-generated | e.g., `20260211.1` |

### Release Pipeline

| Variable | Value | Description |
|----------|-------|-------------|
| `$(System.DefaultWorkingDirectory)` | Auto-generated | Release agent working directory |
| `_Backup Automation Pipeline` | Auto-generated alias | Artifact source alias |

---

## 15. Appendix — Quick Command Reference

### Git Commands

```powershell
git branch                           # Check current branch
git add Commvault/*                  # Stage Commvault changes
git commit -m "Your message"         # Commit
git push origin master               # Push to master
git status                           # Check status
```

### Linux Commands

```bash
# Check NFS mount
df -h | grep backupautomation

# Navigate to deployment folder
cd /mnt/automation/nfs/backupautomation/commvault

# List files with ownership details
ls -la

# Switch to svc-netapp for token init
su - svc-netapp
cd /mnt/automation/nfs/backupautomation/commvault2

# Initialize token
python3 token_manager.py "<access_token>" "<refresh_token>"

# Check token health
python3 check_token_health.py

# Test renewal
python3 renew_token.py
```

### Azure DevOps CLI (Optional)

```powershell
# List pipelines
az pipelines list --organization https://dev.azure.com/yourorg --project YourProject

# Queue a build manually
az pipelines build queue --definition-name "Commvault-Automation-Pipeline"

# List releases
az pipelines release list --organization https://dev.azure.com/yourorg --project YourProject
```

---

## Related Pipelines

| Pipeline | File | Source → Target |
|----------|------|-----------------|
| Storage Automation | `Pipelines/storage-automation-pipeline.yml` | `Automation/*` → `/mnt/automation/nfs/storageautomation/automation2` |
| Storage Monitoring | `Pipelines/storage-monitoring-pipeline.yml` | `Monitoring/*` → `/mnt/automation/nfs/storageautomation/outputs` |
| NetApp OCUM | `Pipelines/netapp-ocum-pipeline.yml` | `NAS/OCUM/*` |

---

## Support and Contact

| Area | Contact |
|------|---------|
| CI/CD Pipeline issues | Azure DevOps administrators |
| NFS mount issues on linux-automation-server | Storage Team |
| Commvault API / subclient issues | Commvault / Backup Team |
| Repository | `Storage` repo in Azure DevOps |
