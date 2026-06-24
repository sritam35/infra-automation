# Storage Reporting Pipeline Reference

## Architecture
Daily pipeline: ONTAP clusters (SSH) + ANF (REST API) + Commvault (CSV export) + DFS (PS cmdlets) → merged CSV → SharePoint Online (Graph API)

## Entry Point
`volume_reporting_main.py` with CLI flags:
```bash
python volume_reporting_main.py            # full run
python volume_reporting_main.py --dry-run  # collect only, write locally
python volume_reporting_main.py --skip-ontap --skip-anf  # partial run
```

## CLI Flags
| Flag | Effect |
|------|--------|
| `--dry-run` | Collect data, write locally, skip SharePoint upload |
| `--skip-sharepoint` | Write local CSVs only |
| `--skip-ontap` | Skip ONTAP SSH collection |
| `--skip-anf` | Skip ANF REST collection |
| `--skip-commvault` | Skip Commvault CSV parsing |
| `--skip-dfs` | Skip DFS path mapping |
| `--skip-aggr` | Skip ONTAP aggregate collection |

## Collectors
| Module | System | Method |
|--------|--------|--------|
| `ontap_volume_collector.py` | ONTAP clusters | Paramiko SSH, `volume show` CLI |
| `anf_volume_collector.py` | Azure NetApp Files | Service principal → REST API |
| `commvault_volume_mapper.py` | Commvault | CSV exports (scheduled 05:00 UTC) |
| `dfs_collector.py` | DFS Namespace | PowerShell cmdlets (Get-DfsnFolderTarget) |
| `ontap_aggr_collector.py` | ONTAP aggregates | Paramiko SSH, `aggr show` CLI |

## Output CSV Schemas (from config.py)
```python
SNAPSHOT_COLS = [
    'snapshot_date', 'platform', 'cluster', 'svm', 'volume_name', 'volume_type',
    'capacity_pool', 'azure_region', 'resource_group',
    'size_gb', 'used_gb', 'avail_gb', 'pct_used', 'pool_size_gb',
    'backup_configured', 'last_backup_date'
]
BACKUP_COLS = [
    'last_checked', 'platform', 'cluster', 'svm', 'volume_name', 'volume_type',
    'backup_configured', 'last_backup_date', 'subclient_name', 'commvault_client'
]
DFS_MAPPING_COLS = ['dfs_path', 'target_path', 'svm', 'volume_name', 'state']
AGGR_COLS = [
    'snapshot_date', 'cluster', 'node', 'aggr_name', 'aggr_type',
    'raid_status', 'size_gb', 'used_gb', 'avail_gb', 'pct_used'
]
```

## Output Files
| File | Strategy | Purpose |
|------|----------|---------|
| `volume_snapshots.csv` | Append daily | Full history |
| `backup_status.csv` | Overwrite daily | Current backup state |
| `dfs_mapping.csv` | Overwrite daily | DFS → volume mapping |
| `aggr_snapshots.csv` | Append daily | Aggregate history |

## Idempotency Pattern
```python
today = date.today().isoformat()
# Remove today's rows before appending new data (safe to rerun)
existing = [r for r in history_rows if r['snapshot_date'] != today]
final_rows = existing + new_rows
```

## Business Rules — backup_configured Override
```python
# DP/LS volumes (ONTAP replicas) → "NA"
if row['platform'] == 'ONTAP' and row['volume_type'] in ('DP', 'LS'):
    row['backup_configured'] = 'NA'

# EU2 ANF volumes → "NA" (no Commvault backup by design)
if row['platform'] == 'ANF' and row['azure_region'] == 'eastus2':
    row['backup_configured'] = 'NA'

# ONTAP test/system volumes → "NA"
skip_patterns = ['tst', 'sqlbkp', 'root', 'esx', 'cvault', 'test']
if row['platform'] == 'ONTAP' and any(p in row['volume_name'] for p in skip_patterns):
    row['backup_configured'] = 'NA'
```

## SharePoint Upload (sharepoint_helper.py)
```python
# Authentication: service principal client credentials
token_url = f"https://login.microsoftonline.com/{SP_TENANT_ID}/oauth2/v2.0/token"
token_data = {
    "grant_type": "client_credentials",
    "client_id": SP_CLIENT_ID,
    "client_secret": SP_CLIENT_SECRET,
    "scope": "https://graph.microsoft.com/.default"
}
token = requests.post(token_url, data=token_data).json()["access_token"]

# Upload CSV
headers = {"Authorization": f"Bearer {token}", "Content-Type": "text/csv"}
url = f"https://graph.microsoft.com/v1.0/sites/{site_id}/drive/items/{folder_id}:/{filename}:/content"
requests.put(url, headers=headers, data=csv_content)
```

## Config.py — Environment Variables
```python
# ONTAP
ONTAP_SSH_USER = os.environ.get('ONTAP_SSH_USER', 'admin')
ONTAP_SSH_KEY_PATH = os.environ.get('ONTAP_SSH_KEY_PATH', '/opt/svc_netapp/.ssh/id_rsa')
ONTAP_CLUSTERS_FILE = os.environ.get('ONTAP_CLUSTERS_FILE', '/mnt/global/nfs/backupautomation/monitoring/netapp_clusters.conf')

# ANF (service principal)
AZURE_TENANT_ID = os.environ['AZURE_TENANT_ID']
AZURE_CLIENT_ID = os.environ['AZURE_CLIENT_ID']
AZURE_CLIENT_SECRET = os.environ['AZURE_CLIENT_SECRET']
ANF_SUBSCRIPTION_ID = os.environ.get('ANF_SUBSCRIPTION_ID', 'c303bd32-eddf-42ca-9946-d679e0b1e1f3')

# SharePoint (service principal)
SP_TENANT_ID = os.environ['SP_TENANT_ID']
SP_CLIENT_ID = os.environ['SP_CLIENT_ID']
SP_CLIENT_SECRET = os.environ['SP_CLIENT_SECRET']
SHAREPOINT_HOSTNAME = os.environ.get('SHAREPOINT_HOSTNAME', 'onlinegmo.sharepoint.com')
SHAREPOINT_SITE_PATH = os.environ.get('SHAREPOINT_SITE_PATH', '/sites/teams_platformengineering')
SHAREPOINT_FOLDER = os.environ.get('SHAREPOINT_FOLDER', 'Storage-Reporting/volume-data')

# Commvault CSV exports
CV_REPORT_DIR = os.environ.get('CV_REPORT_DIR', r'\\gmo\dsl\backupautomation\commvault\reports')
```

## ANF Accounts (ANF_ACCOUNTS list)
```python
ANF_ACCOUNTS = [
    {"account_name": "cusprdanf01", "resource_group": "centralus-cusprdanf01-rg",
     "region": "centralus", "label": "CUS"},
    {"account_name": "eu2prdanf01", "resource_group": "eastus2-eu2prdanf01-rg",
     "region": "eastus2", "label": "EU2"}
]
```

## Commvault CSV File Name Patterns
```python
subclient_csv_pattern = "SubClient Configuration Information_*.csv"
protection_csv_pattern = "Data Protection_*.csv"
# Both scheduled for 05:00 AM daily export from Commvault
```

## Python Dependencies (requirements.txt)
```
paramiko>=3.0.0
requests>=2.28.0
pandas>=2.0.0
urllib3>=2.0.0
```

## Pipeline Schedule
- Commvault CSV export: 05:00 UTC daily
- volume_reporting_main.py: 06:00 UTC daily (pipeline: storage-volume-reporting-pipeline.yml)
