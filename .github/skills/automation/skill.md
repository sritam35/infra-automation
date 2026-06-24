---
name: infra-automation
description: 'Infrastructure automation skill. Use when writing or reviewing ANY code for this repo: Azure NetApp Files (ANF) DR automation (failover, failback, replication, DFS path management, state tracking), NetApp ONTAP SSH (volumes, snapmirror, snapshots, autogrow, FPolicy, disk health, aggregate reporting, vserver), Commvault backup API (token management, subclient exclusions, datalake backup exclusions, REST API), Azure (VM snapshots, RBAC, PIM role assignments, blob container usage, service principal auth, ANF REST API), PowerShell modules (CorpMaintenance, CorpMaintV2, CorpComputerInfo, SCCM deployments, WMI, AD queries, DFS, NAS, SAN/VMware LUN/NVMe paths), Python automation (Paramiko SSH, requests, azure-identity, LDAP, SharePoint Graph API, storage volume reporting pipeline), Bash scripts (NetApp CLI, HTML email, AES-256-CBC credentials, sendmail), OCUM-ServiceNow integration (event-to-incident, urgency/impact mapping, suppression rules, incident closure), user home directory provisioning, DFS path validation, NFS/CIFS mount validation, storage CI/CD Azure DevOps pipelines, Pester tests, PSScriptAnalyzer, psake, NuGet packaging. Always apply project coding conventions, cluster hostnames, resource names, file paths, credential patterns, and environment config from this skill.'
argument-hint: 'Describe the automation task: ANF DR, NetApp, Commvault, OCUM/ServiceNow, Azure, PowerShell module, Bash, Python, SAN, NAS, or Storage Reporting'
---

# Infrastructure Automation Skill

## When to Use
Load this skill for ANY code in the Storage or DevOps_Maintenance repos:
- **ANF DR** — Failover/failback orchestration, ANF replication (break/resync), DFS target management, state file tracking, capacity pool/volume ARM templates
- **NetApp ONTAP** — SSH automation, volume/aggregate/snapshot management, autogrow, FPolicy, SnapMirror, disk health, health checks, cluster inventory
- **Commvault** — REST API token lifecycle, subclient exclusion policies, datalake backup, PowerShell SDK integration
- **OCUM → ServiceNow** — Event-to-incident automation, urgency/impact mapping, suppression rules, incident closure
- **Storage Reporting** — Daily volume pipeline (ONTAP + ANF + Commvault + DFS + SharePoint)
- **NAS** — PreBackup health check, home directory provisioning, DFS path validation, NFS validation, share cleanup
- **SAN** — VMware vCenter NVMe-oF / FC LUN multipath inventory
- **Azure** — VM snapshots, RBAC/PIM reports, blob usage, ANF REST API, service principal auth
- **PowerShell Modules** — CorpMaintenance, CorpMaintV2, CorpComputerInfo, SCCM package deployment, Pester tests
- **CI/CD** — Azure DevOps pipelines, psake builds, PSScriptAnalyzer, NuGet packaging

---

## Environment & Infrastructure Quick Reference

### NetApp ONTAP Clusters
| Hostname | Region | Role |
|----------|--------|------|
| `cluster-01` | Sydney | NAS |
| `cluster-02` | Melbourne | Backup |
| `cluster-03` | Melbourne | NAS |
| `cluster-04` | East US 2 | NAS |
| `cluster-05` | East US 2 | NAS |
| `cluster-06` | Ashburn | NAS |

### ANF Accounts & Environments
| Account | Region | Resource Group | Label |
|---------|--------|----------------|-------|
| `anf-primary-account` | eastus2 | eastus2-anf-primary-account-rg | EU2 (source) |
| `anf-dr-account` | centralus | centralus-anf-dr-account-rg | CUS (DR) |
| `anf-primary-test-account` | eastus2 | — | EU2 Test |
| `anf-dr-test-account` | centralus | — | CUS Test |

### Key Servers
| Role | Hostname/Path |
|------|---------------|
| Commvault | `commvault-server` |
| Linux Automation | `marprdnfs001` |
| SCCM Site Server | `bosinfprdmsc101.corp.example.com` |
| vCenter | `usvc.corp.example.com` |
| LDAP | `ldap://ldap.corp.example.com` (base: `dc=corp,dc=example,dc=com`) |

### Key File Paths
```
/mnt/automation/nfs/storageautomation/outputs/        # Storage script outputs
/mnt/automation/nfs/backupautomation/commvault/       # Commvault token & scripts
/mnt/automation/nfs/backupautomation/monitoring/      # Monitoring configs
\\fileserver\SysConfig\Storage\                       # PowerShell credential key pairs
\\fileserver\UserHome\                               # User home directories
```

### ANF DR Config Canonical File
`ANF/DR/ANF_DR_Config.csv` — columns: `Environment, DFSFolderPath, SourceTarget, DRTarget, VolumeName`
- DRTarget UNC share name = volume name (e.g., `\\anf-source.corp.example.com\eu2-dr-test` → volume `eu2-dr-test`)
- State tracked in `dr_state_production.json` / `dr_state_test.json`

### SharePoint Reporting Target
- Tenant: `yourorg.sharepoint.com`
- Site: `/sites/teams_platformengineering`
- Folder: `Storage-Reporting/volume-data`
- Auth: service principal via Microsoft Graph API

---

## Universal Coding Conventions

### Credential Patterns
| System | Method |
|--------|--------|
| NetApp SSH | Paramiko RSA key (`Private Key_svc-netapp.txt`) or AES-256-CBC encrypted password |
| Commvault API | JSON token file `chmod 0o600`, auto-renewed via `TokenManager` with 2-min expiry buffer |
| Azure / ANF | Service principal (AZURE_TENANT_ID, AZURE_CLIENT_ID, AZURE_CLIENT_SECRET env vars) or `DefaultAzureCredential()` |
| SharePoint | Service principal → Microsoft Graph `client_credentials` token |
| LDAP | AES-256-CBC, inline `openssl enc -aes-256-cbc -d` decryption |
| PowerShell (SCCM/Commvault SDK) | AES key file pair in `\\fileserver\SysConfig\Storage\` |
| DFS admin operations | DPAPI `~\.admin_cred.xml` + `Start-Process -Credential` (WinRM workaround) |

### Error Handling Templates
**Python:**
```python
try:
    response = requests.get(url, headers=headers, timeout=30, verify=False)
    response.raise_for_status()
except requests.exceptions.HTTPError as http_err:
    print(f"HTTP error: {http_err} — {response.text}")
except requests.exceptions.Timeout:
    print("Request timed out (30s)")
except requests.exceptions.RequestException as e:
    print(f"Request failed: {e}")
```

**Bash:**
```bash
set -euo pipefail
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
```

**PowerShell:**
```powershell
try {
    # operation
} catch {
    Write-Error "Failed: $_"
    ##vso[task.complete result=Failed;]DONE   # Azure DevOps pipeline fail marker
}
```

### Logging Standard (PowerShell)
```powershell
function Write-LogMessage {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR','SUCCESS')][string]$Level = 'INFO')
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[$timestamp] [$Level] $Message"
    Add-Content -Path $LogFile -Value "[$timestamp] [$Level] $Message"
}
```

### Dry-Run Pattern (Python — default safe)
```python
parser.add_argument('--execute', action='store_true', help='Apply changes (default: dry-run)')
if args.execute:
    execute_command(ssh_client, cmd)
else:
    print(f"[DRY-RUN] Would run: {cmd}")
```

### Idempotency Pattern (Python reporting pipeline)
```python
# Remove today's rows before appending (safe reruns)
today = date.today().isoformat()
existing = [r for r in history if r['snapshot_date'] != today]
history = existing + new_rows
```

### State File Pattern (ANF DR JSON)
```python
# Write state after Disable
state = {"DisabledTarget": target_path, "Timestamp": datetime.now().isoformat()}
with open('dr_state_production.json', 'w') as f:
    json.dump(state, f, indent=2)
# Read state before Enable
with open('dr_state_production.json') as f:
    state = json.load(f)
```

---

## Reference Files
- [ANF DR Automation](./references/anf-dr.md) — Failover/failback, replication, DFS management, ARM templates
- [NetApp ONTAP Patterns](./references/netapp.md) — SSH, CLI commands, size parsing, cluster iteration, health checks
- [OCUM → ServiceNow](./references/ocum-servicenow.md) — Event processing, urgency/impact mapping, suppression rules
- [Commvault API Patterns](./references/commvault.md) — Token lifecycle, subclient API, datalake exclusion logic
- [Storage Reporting Pipeline](./references/storage-reporting.md) — Daily volume pipeline, collectors, SharePoint upload
- [NAS & SAN Management](./references/nas-san.md) — Home dirs, DFS validation, NFS checks, VMware LUN paths
- [PowerShell Modules & CI/CD](./references/powershell-cicd.md) — Corp PS modules, SCCM, Pester, psake, NuGet
- [Bash Automation Patterns](./references/bash.md) — NetApp CLI, HTML email, AES credential decryption
