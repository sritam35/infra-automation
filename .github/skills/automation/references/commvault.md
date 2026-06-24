# Commvault API Reference

## Server & Endpoints
```
Base URL:  https://bedprdbck001/commandcenter/api
Token:     /v4/AccessToken/Renew
Instance:  /Instance/CloudStorage
Subclient: /Subclient/{subclientId}
```

## Token Management (token_manager.py)
```python
class TokenManager:
    TOKEN_FILE = '/mnt/global/nfs/backupautomation/commvault/.commvault_tokens.json'
    DEFAULT_VALIDITY = 1800          # 30 minutes
    EXPIRY_BUFFER_SECONDS = 120      # 2-minute safety margin

    def _load_tokens(self):
        """Load tokens from JSON file; return {} if missing/corrupt."""
        try:
            with open(self.TOKEN_FILE) as f:
                return json.load(f)
        except (FileNotFoundError, json.JSONDecodeError):
            return {}

    def _save_tokens(self, tokens):
        """Save tokens with chmod 0o600 for security."""
        with open(self.TOKEN_FILE, 'w') as f:
            json.dump(tokens, f)
        os.chmod(self.TOKEN_FILE, 0o600)

    def _is_token_expired(self, token_data) -> bool:
        """True if token is expired or within 2-min buffer."""
        expiry = token_data['acquired_at'] + token_data['validity'] - self.EXPIRY_BUFFER_SECONDS
        return time.time() >= expiry

    def get_valid_token(self) -> str:
        """Return cached token; auto-renew if expired."""
        tokens = self._load_tokens()
        if not tokens or self._is_token_expired(tokens):
            return self.renew_token()
        return tokens['token']

    def renew_token(self) -> str:
        """POST to Commvault API to renew token."""
        headers = {'Authtoken': self._load_tokens().get('token', '')}
        response = requests.post(
            f"{COMMVAULT_URL}/commandcenter/api/v4/AccessToken/Renew",
            headers=headers, verify=False, timeout=30
        )
        response.raise_for_status()
        new_token = response.json()['token']
        self._save_tokens({'token': new_token, 'acquired_at': time.time(),
                           'validity': self.DEFAULT_VALIDITY})
        return new_token
```

## Token Health Thresholds (check_token_health.py)
```python
# Age in days since last renewal
if age_days > 14:   # CRITICAL — token expired (14-day validity window)
if age_days > 10:   # CAUTION
if age_days > 7:    # GOOD
else:               # EXCELLENT (< 7 days)
```

## GET Request Pattern (commvault_get_api.py)
```python
def send_get_request(url, headers):
    response = requests.get(url, headers=headers, timeout=30, verify=False)
    response.raise_for_status()
    return response

# Usage
token_mgr = TokenManager()
token = token_mgr.get_valid_token()
headers = {'Authtoken': token, 'Accept': 'application/json'}
response = send_get_request(f"{COMMVAULT_URL}/commandcenter/api/Instance/CloudStorage", headers)
```

## Subclient Update — Datalake (commvault_post_api.py)
```python
# Subclient IDs
SUBCLIENT_ID = 1776   # Datalake backup subclient
INSTANCE_ID  = 143
CLIENT_ID    = 491
APP_ID       = 134    # AZURE_BLOB

# Datalake containers (includePath entries)
INCLUDE_CONTAINERS = [
    '/app-dae', '/app-gdm', '/app-hld', '/app-ldg', '/app-pdb', '/app-ser',
    '/demo', '/lab', '/laboratory', '/raw', '/samples-dae',
    '/src-blackrock', '/src-broadridge', '/src-cvent', '/src-mandatewire',
    '/src-mmd', '/src-on24', '/src-pivotal-crm', '/src-vdm',
    '/synapse', '/synfs-gmoperfsyslwr'
]

def build_payload(include_paths, exclude_paths):
    content = [{"includePath": p} for p in include_paths]
    content += [{"excludePath": p} for p in exclude_paths]
    return {
        "subClientProperties": {
            "content": content,
            "subClientEntity": {
                "subclientId": SUBCLIENT_ID,
                "instanceId": INSTANCE_ID,
                "clientId": CLIENT_ID,
                "appTypeId": APP_ID
            }
        }
    }
```

## Dynamic Datalake Exclusions (dynamic_datalakebkp_exclusions.py)
```python
def generate_all_quarters(start_year=2024, years_ahead=0) -> list:
    """Generate all quarters in YYYY_qQ format up to current quarter."""
    current = date.today()
    current_quarter = (current.month - 1) // 3 + 1
    quarters = []
    for year in range(start_year, current.year + years_ahead + 1):
        for q in range(1, 5):
            if year == current.year and q >= current_quarter:
                break
            quarters.append(f"{year}_q{q}")
    return quarters

# History table families requiring exclusion
GDM_TABLES = [
    'credit-entity-info', 'credit-entity-item', 'credit-market-item', 'credit-rating',
    'dbo-issuer-master', 'dbo-security-master', 'esg-green-revenue-data',
    'index-data-constituent', 'internal-esg-data', 'macro-data-point',
    # ... (27 total GDM tables)
]
ASTRAL_TABLES = [
    'gdm-currency-cross-rate', 'gdm-estimate-summary', 'gdm-filing', 'gdm-filing-detail',
    'gdm-index-market-data', 'gdm-issuer-master', 'gdm-security-master', 'gmo-security-master-feed',
    # ... (11 total Astral tables)
]

# Exclusion path format: /{container}/{table}/{quarter}
# Exclude all quarters EXCEPT current quarter
exclude_paths = [
    f"/{container}/{table}/{quarter}"
    for quarter in generate_all_quarters()
    for table in (GDM_TABLES + ASTRAL_TABLES)
    for container in ['raw', 'gdm']  # adjust per actual containers
]
```

## Vendor Data Exclusion Paths (static, commvault_post_api.py)
```
FactSet paths:  /raw/gr-v2/..., /raw/own-v5/..., /raw/ref-v2/..., /raw/sym-v1/..., /raw/tv-v2/...
IVYDb paths:    /raw/ivydb-Asia/..., /raw/ivydb-Canada/..., /raw/ivydb-Europe/..., /raw/ivydb-US/...
  (Sub-paths: option-price/{year} from 2004-2020, security-price)
```

## PowerShell SDK — GetCVBackupReport.ps1
```powershell
# Connection with AES encrypted credentials
$key  = Get-Content "\\gmo\dsl\SysConfig\Storage\Svc-PrdBCKAuto\Svc-PrdBCKAuto.key"
$pass = Get-Content "\\gmo\dsl\SysConfig\Storage\Svc-PrdBCKAuto\Svc-PrdBCKAuto.txt" |
        ConvertTo-SecureString -Key $key
$cred = New-Object PSCredential("Svc-PrdBCKAuto", $pass)
Connect-CVServer -Server bedprdbck001 -Credential $cred

# Client filtering
$clients = Get-CVClient | Where-Object {
    $_.name -notmatch '_' -and
    ($_.name -match 'SMB|NFS|BKP|GMO') -and
    $_.name -notmatch 'FAS'
}

# Subclient correlation with DFS/NetApp
foreach ($client in $clients) {
    $subclients = Get-CVSubclient -ClientName $client.name
    foreach ($sc in $subclients) {
        # Extract vserver from DFS namespace path mapping
        # Match against vserver.csv + DFSTargets_Export.csv
    }
}
```

## Commvault Pipeline (Azure DevOps)
- File: `Pipelines/commvault-automation-pipeline.yml`
- Trigger: master branch, path `Commvault/*`
- Deploy to: `/mnt/global/nfs/backupautomation/commvault/` on marprdnfs001

## Token Renewal Schedule
```
Renew every 7 days (proactive — within 14-day validity window)
Check health before monthly operations: check_token_health.py
Emergency renewal: renew_token.py
```
