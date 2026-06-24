"""
Quick validation — confirms the app registration can reach the SharePoint site.
Run once from any terminal; does NOT write any data.

Usage:
    python validate_sharepoint.py
"""

import sys

try:
    import requests
except ImportError:
    print("[ERROR] 'requests' library not installed.")
    print("        Run:  pip install requests")
    sys.exit(1)

print("=" * 60)
print("  SharePoint App Registration Validator")
print("=" * 60)

tenant_id     = input("\nTenant ID     : ").strip()
client_id     = input("Client ID     : ").strip()
client_secret = input("Client Secret : ").strip()

if not all([tenant_id, client_id, client_secret]):
    print("\n[ERROR] All three values are required.")
    sys.exit(1)

HOSTNAME  = "onlinegmo.sharepoint.com"
SITE_PATH = "sites/teams_platformengineering"

print(f"\n[1/3] Getting token from Azure AD...")
try:
    resp = requests.post(
        f"https://login.microsoftonline.com/{tenant_id}/oauth2/v2.0/token",
        data={
            "grant_type":    "client_credentials",
            "client_id":     client_id,
            "client_secret": client_secret,
            "scope":         "https://graph.microsoft.com/.default",
        },
        timeout=30,
    )
    resp.raise_for_status()
    token = resp.json().get("access_token")
    if not token:
        print(f"[ERROR] No token in response: {resp.json()}")
        sys.exit(1)
    print("  Token obtained successfully")
except Exception as e:
    print(f"  [ERROR] Token request failed: {e}")
    sys.exit(1)

headers = {"Authorization": f"Bearer {token}"}

print(f"\n[2/3] Resolving SharePoint site...")
try:
    resp = requests.get(
        f"https://graph.microsoft.com/v1.0/sites/{HOSTNAME}:/{SITE_PATH}",
        headers=headers,
        timeout=30,
    )
    resp.raise_for_status()
    site = resp.json()
    site_id = site.get("id")
    site_name = site.get("displayName")
    print(f"  Site ID      : {site_id}")
    print(f"  Display name : {site_name}")
except Exception as e:
    print(f"  [ERROR] Cannot reach site: {e}")
    if hasattr(e, 'response') and e.response is not None:
        print(f"  Response: {e.response.text[:300]}")
    sys.exit(1)

print(f"\n[3/3] Listing document libraries...")
try:
    resp = requests.get(
        f"https://graph.microsoft.com/v1.0/sites/{site_id}/drives",
        headers=headers,
        timeout=30,
    )
    resp.raise_for_status()
    drives = resp.json().get("value", [])
    for d in drives:
        print(f"  Library: {d.get('name'):<30} ID: {d.get('id')}")
except Exception as e:
    print(f"  [ERROR] Cannot list drives: {e}")
    sys.exit(1)

print(f"\n{'=' * 60}")
print("  ALL CHECKS PASSED — SharePoint connection is ready.")
print(f"{'=' * 60}\n")
