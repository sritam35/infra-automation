"""
ANF Volume Collector
====================
Collects daily capacity snapshots for all Azure NetApp Files volumes across
all configured ANF accounts (CUS + EU2) using the Azure Resource Manager
REST API and Azure Monitor Metrics API.

Authentication: Azure AD service principal (client credentials flow).
Required SP permissions:
  - Reader on the ANF subscription (to list accounts / pools / volumes)
  - Monitoring Reader on the ANF subscription (to read Azure Monitor metrics)
"""

from typing import Optional
import requests
import urllib3
from datetime import datetime, timezone, timedelta, date

import config

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# ─── Token cache (in-process, keyed by resource URI) ─────────────────────────
_token_cache: dict = {}


def _get_azure_token(resource: str = "https://management.azure.com/") -> str:
    """Return a valid Azure AD bearer token for the given resource/scope."""
    now = datetime.now(timezone.utc)
    cached = _token_cache.get(resource)
    if cached and cached["expires_at"] > now:
        return cached["token"]

    tenant_id     = config.AZURE_TENANT_ID
    client_id     = config.AZURE_CLIENT_ID
    client_secret = config.AZURE_CLIENT_SECRET

    if not all([tenant_id, client_id, client_secret]):
        raise ValueError(
            "Missing Azure credentials. "
            "Set AZURE_TENANT_ID, AZURE_CLIENT_ID, AZURE_CLIENT_SECRET."
        )

    url = f"https://login.microsoftonline.com/{tenant_id}/oauth2/token"
    payload = {
        "grant_type":    "client_credentials",
        "client_id":     client_id,
        "client_secret": client_secret,
        "resource":      resource,
    }
    resp = requests.post(url, data=payload, timeout=30)
    resp.raise_for_status()
    data       = resp.json()
    token      = data["access_token"]
    expires_in = int(data.get("expires_in", 3600))
    _token_cache[resource] = {
        "token":      token,
        "expires_at": now + timedelta(seconds=expires_in - 60),
    }
    return token


def _arm_get(path: str, params: dict = None) -> dict:
    """Authenticated GET against Azure Resource Manager."""
    token = _get_azure_token("https://management.azure.com/")
    resp  = requests.get(
        f"https://management.azure.com{path}",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        params=params,
        timeout=60,
    )
    resp.raise_for_status()
    return resp.json()


# ─── ANF resource helpers ──────────────────────────────────────────────────────
_ANF_API = "2024-03-01"


def _list_capacity_pools(subscription_id: str, resource_group: str, account_name: str) -> list:
    path = (
        f"/subscriptions/{subscription_id}/resourceGroups/{resource_group}"
        f"/providers/Microsoft.NetApp/netAppAccounts/{account_name}/capacityPools"
    )
    return _arm_get(path, {"api-version": _ANF_API}).get("value", [])


def _list_volumes(subscription_id: str, resource_group: str,
                  account_name: str, pool_name: str) -> list:
    path = (
        f"/subscriptions/{subscription_id}/resourceGroups/{resource_group}"
        f"/providers/Microsoft.NetApp/netAppAccounts/{account_name}"
        f"/capacityPools/{pool_name}/volumes"
    )
    return _arm_get(path, {"api-version": _ANF_API}).get("value", [])


# ─── Azure Monitor metrics ────────────────────────────────────────────────────
def _get_volume_used_bytes(resource_id: str) -> Optional[int]:
    """
    Query Azure Monitor for VolumeLogicalSize (actual consumed bytes) of a
    volume over the last 2 hours, returning the most recent Average data point.

    Returns bytes as int, or None if metrics are unavailable.
    """
    now   = datetime.now(timezone.utc)
    start = (now - timedelta(hours=2)).strftime("%Y-%m-%dT%H:%M:%SZ")
    end   = now.strftime("%Y-%m-%dT%H:%M:%SZ")

    try:
        data = _arm_get(
            f"{resource_id}/providers/microsoft.insights/metrics",
            {
                "api-version":  "2018-01-01",
                "metricnames":  "VolumeLogicalSize",
                "aggregation":  "Average",
                "timespan":     f"{start}/{end}",
                "interval":     "PT1H",
            },
        )
        for metric in data.get("value", []):
            for ts in metric.get("timeseries", []):
                for dp in reversed(ts.get("data", [])):
                    val = dp.get("average")
                    if val is not None:
                        return int(val)
        return None
    except Exception as e:
        print(f"  [ANF][WARN] Metrics unavailable for resource {resource_id.split('/')[-1]}: {e}")
        return None


# ─── Main collection ───────────────────────────────────────────────────────────
def collect_all() -> list:
    """
    Iterate over all ANF accounts in config, collect all volumes and their
    current capacity metrics.  Returns a list of snapshot dicts ready to
    append to volume_snapshots.csv.
    """
    subscription_id = config.ANF_SUBSCRIPTION_ID
    today           = date.today().isoformat()
    all_records     = []

    print(f"\n[ANF] Collecting from {len(config.ANF_ACCOUNTS)} account(s)")

    for acct in config.ANF_ACCOUNTS:
        account_name   = acct["account_name"]
        resource_group = acct["resource_group"]
        region         = acct["region"]
        label          = acct["label"]

        print(f"\n  [ANF] Account: {account_name} ({label}, {region})")

        try:
            pools = _list_capacity_pools(subscription_id, resource_group, account_name)
        except Exception as e:
            print(f"  [ANF][ERROR] Cannot list pools for {account_name}: {e}")
            continue

        print(f"  [ANF] {account_name}: {len(pools)} capacity pool(s)")
        acct_count = 0

        for pool in pools:
            # ARM returns name as "accountName/poolName" — take the last segment only
            pool_name = pool["name"].split("/")[-1]
            pool_size_bytes = pool.get("properties", {}).get("size") or 0
            pool_size_gb    = round(pool_size_bytes / (1024 ** 3), 2) if pool_size_bytes else ""
            try:
                volumes = _list_volumes(subscription_id, resource_group, account_name, pool_name)
            except Exception as e:
                print(f"  [ANF][ERROR] Cannot list volumes in pool {pool_name}: {e}")
                continue

            for vol in volumes:
                # The ARM name is "accountName/poolName/volumeName" — take the last segment
                vol_name    = vol["name"].split("/")[-1]
                resource_id = vol["id"]
                props       = vol.get("properties", {})

                # usageThreshold = provisioned quota in bytes
                size_bytes  = props.get("usageThreshold") or 0
                size_gb     = round(size_bytes / (1024 ** 3), 2) if size_bytes else ""

                used_bytes  = _get_volume_used_bytes(resource_id)
                used_gb     = round(used_bytes / (1024 ** 3), 2) if used_bytes is not None else ""

                avail_gb = (
                    round(size_gb - used_gb, 2)
                    if (isinstance(size_gb, float) and isinstance(used_gb, float))
                    else ""
                )
                pct_used = (
                    round((used_gb / size_gb) * 100, 2)
                    if (isinstance(size_gb, float) and isinstance(used_gb, float) and size_gb > 0)
                    else ""
                )

                all_records.append({
                    "snapshot_date":  today,
                    "platform":       "ANF",
                    "cluster":        account_name,
                    "svm":            pool_name,
                    "volume_name":    vol_name,
                    "volume_type":    "RW",
                    "capacity_pool":  pool_name,
                    "azure_region":   region,
                    "resource_group": resource_group,
                    "size_gb":        size_gb,
                    "used_gb":        used_gb,
                    "avail_gb":       avail_gb,
                    "pct_used":       pct_used,
                    "pool_size_gb":   pool_size_gb,
                })
                acct_count += 1

        print(f"  [ANF] {account_name}: {acct_count} volumes collected")

    print(f"[ANF] Total: {len(all_records)} volume snapshot records")
    return all_records
