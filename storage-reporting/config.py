"""
Central configuration for Storage Volume Reporting.

All secrets come from environment variables (set in Azure DevOps pipeline variables).
Static / structural config is defined here so it is easy to update in one place.
"""

import os

# ─── ONTAP SSH ────────────────────────────────────────────────────────────────
ONTAP_SSH_USER      = os.environ.get("NETAPP_SSH_USER", "admin")
ONTAP_SSH_KEY_PATH  = os.environ.get("NETAPP_SSH_KEY_PATH",
                          "/opt/svc_netapp/.ssh/id_rsa")
ONTAP_SSH_PORT      = int(os.environ.get("NETAPP_SSH_PORT", "22"))

# Reuses the same cluster list used by netapp_autogrow_check.py / netapp_health_check.py.
# One cluster hostname per line; lines starting with # are ignored.
ONTAP_CLUSTERS_FILE = os.environ.get("NETAPP_CLUSTERS_FILE",
                          "/mnt/global/nfs/backupautomation/monitoring/netapp_clusters.conf")

# ─── ANF REST API ─────────────────────────────────────────────────────────────
# Service principal used for ANF REST API calls (needs Reader on the ANF subscription).
AZURE_TENANT_ID     = os.environ.get("AZURE_TENANT_ID", "")
AZURE_CLIENT_ID     = os.environ.get("AZURE_CLIENT_ID", "")
AZURE_CLIENT_SECRET = os.environ.get("AZURE_CLIENT_SECRET", "")

# Subscription ID observed in the CUS/EU2 ARM templates.
ANF_SUBSCRIPTION_ID = os.environ.get("ANF_SUBSCRIPTION_ID",
                          "c303bd32-eddf-42ca-9946-d679e0b1e1f3")

# One entry per ANF account.
# TODO: verify resource_group names match your Azure environment.
ANF_ACCOUNTS = [
    {
        "account_name":   "cusprdanf01",
        "resource_group": "centralus-cusprdanf01-rg",
        "region":         "centralus",
        "label":          "CUS",
    },
    {
        "account_name":   "eu2prdanf01",
        "resource_group": "eastus2-eu2prdanf01-rg",
        "region":         "eastus2",
        "label":          "EU2",
    },
]

# ─── Commvault ────────────────────────────────────────────────────────────────
# Directory containing two scheduled Commvault CSV report exports:
#   SubClient Configuration Information_*.csv  (content paths per subclient)
#   Data Protection_*.csv                       (last backup date per subclient)
# Both are scheduled daily at 05:00 AM to run before the pipeline at 06:00 UTC.
CV_REPORT_DIR = os.environ.get("CV_REPORT_DIR", r"\\gmo\dsl\backupautomation\commvault\reports")

# ─── SharePoint / Microsoft Graph API ────────────────────────────────────────
# Requires an Azure AD app registration with:
#   API permissions → Microsoft Graph → Application → Sites.ReadWrite.All
# SP_TENANT_ID defaults to AZURE_TENANT_ID if the same SP is used for both ANF and SharePoint.
SP_TENANT_ID         = os.environ.get("SP_TENANT_ID",
                            os.environ.get("AZURE_TENANT_ID", ""))
SP_CLIENT_ID         = os.environ.get("SP_CLIENT_ID", "")
SP_CLIENT_SECRET     = os.environ.get("SP_CLIENT_SECRET", "")

# SharePoint Online site details.
# SHAREPOINT_HOSTNAME  → e.g. yourorg.sharepoint.com
# SHAREPOINT_SITE_PATH → e.g. /sites/ITStorage   (the path after the hostname)
# SHAREPOINT_FOLDER    → folder inside the Documents library where CSVs are written
SHAREPOINT_HOSTNAME  = os.environ.get("SHAREPOINT_HOSTNAME",
                            "onlinegmo.sharepoint.com")
SHAREPOINT_SITE_PATH = os.environ.get("SHAREPOINT_SITE_PATH",
                            "/sites/teams_platformengineering")
SHAREPOINT_FOLDER    = os.environ.get("SHAREPOINT_FOLDER",
                            "Storage-Reporting/volume-data")

# ─── Output CSV file names ─────────────────────────────────────────────────────
CSV_SNAPSHOTS     = "volume_snapshots.csv"    # appended daily; full history
CSV_BACKUP_STATUS = "backup_status.csv"       # overwritten daily; current state only
CSV_DFS_MAPPING   = "dfs_mapping.csv"         # overwritten daily; DFS path → volume map

# ─── CSV column schemas ────────────────────────────────────────────────────────
SNAPSHOT_COLS = [
    "snapshot_date",    # YYYY-MM-DD
    "platform",         # ONTAP | ANF
    "cluster",          # ONTAP cluster hostname or ANF account name
    "svm",              # ONTAP vserver name or ANF capacity pool name
    "volume_name",      # volume name
    "volume_type",      # RW | DP | LS (ONTAP only; empty for ANF)
    "capacity_pool",    # ANF capacity pool name (empty for ONTAP)
    "azure_region",     # ANF region (empty for ONTAP)
    "resource_group",   # ANF resource group (empty for ONTAP)
    "size_gb",          # provisioned / total size in GB  (volume quota)
    "used_gb",          # used size in GB  (actual consumption, ANF: Azure Monitor VolumeLogicalSize)
    "avail_gb",         # available size in GB
    "pct_used",         # percentage used (0-100)
    "pool_size_gb",     # ANF capacity pool total size in GB (empty for ONTAP)
]

BACKUP_COLS = [
    "last_checked",      # YYYY-MM-DD
    "platform",
    "cluster",
    "svm",
    "volume_name",
    "volume_type",       # RW | DP | LS (ONTAP only; empty for ANF)
    "backup_configured", # True | False | NA
    "last_backup_date",  # YYYY-MM-DD of last successful backup (empty if none/NA)
    "subclient_name",    # Commvault subclient name (empty if none)
    "commvault_client",  # Commvault client/proxy name (empty if none)
]

DFS_MAPPING_COLS = [
    "dfs_path",     # DFS namespace path  e.g. \\gmo.tld\BosProd\Current
    "target_path",  # UNC target          e.g. \\marprdsmb32_ha1a_smb\current_sh$
    "svm",          # ONTAP SVM name (empty for ANF)
    "volume_name",  # Storage volume name
    "state",        # Online | Offline
]

CSV_AGGR_SNAPSHOTS = "aggr_snapshots.csv"   # appended daily; full history

AGGR_COLS = [
    "snapshot_date",  # YYYY-MM-DD
    "cluster",        # ONTAP cluster hostname
    "node",           # owning node name
    "aggr_name",      # aggregate name
    "aggr_type",      # HDD | SSD | hybrid
    "raid_status",    # normal | degraded | etc.
    "size_gb",        # total physical size in GB
    "used_gb",        # used physical space in GB
    "avail_gb",       # available physical space in GB
    "pct_used",       # percentage used (0-100)
]
