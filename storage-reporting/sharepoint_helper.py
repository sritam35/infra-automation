"""
SharePoint Helper
=================
Downloads and uploads CSV files to a SharePoint Online document library
using the Microsoft Graph API (application-level, client credentials).

Required Azure AD app registration permissions:
    Microsoft Graph → Application permissions → Sites.ReadWrite.All

The site ID and drive ID are resolved once per process run and cached
to avoid repeated Graph API round-trips.
"""

import io
import requests
import urllib3
from datetime import datetime, timezone, timedelta

import config

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# ─── In-process token cache ────────────────────────────────────────────────────
_graph_token: dict = {"token": None, "expires_at": None}
_site_id:     str  = None
_drive_id:    str  = None


def _get_graph_token() -> str:
    """Obtain (or return a cached) Microsoft Graph bearer token."""
    now = datetime.now(timezone.utc)
    if (_graph_token["token"]
            and _graph_token["expires_at"]
            and _graph_token["expires_at"] > now):
        return _graph_token["token"]

    tenant_id     = config.SP_TENANT_ID
    client_id     = config.SP_CLIENT_ID
    client_secret = config.SP_CLIENT_SECRET

    if not all([tenant_id, client_id, client_secret]):
        raise ValueError(
            "Missing SharePoint credentials. "
            "Set SP_TENANT_ID, SP_CLIENT_ID, SP_CLIENT_SECRET environment variables."
        )

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
    data = resp.json()
    _graph_token["token"]      = data["access_token"]
    _graph_token["expires_at"] = now + timedelta(
        seconds=int(data.get("expires_in", 3600)) - 60
    )
    return _graph_token["token"]


def _graph_get(path: str, stream: bool = False) -> requests.Response:
    token = _get_graph_token()
    resp  = requests.get(
        f"https://graph.microsoft.com/v1.0{path}",
        headers={"Authorization": f"Bearer {token}"},
        stream=stream,
        timeout=60,
    )
    resp.raise_for_status()
    return resp


def _graph_put(path: str, data_bytes: bytes, content_type: str = "text/csv") -> requests.Response:
    token = _get_graph_token()
    resp  = requests.put(
        f"https://graph.microsoft.com/v1.0{path}",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type":  content_type,
        },
        data=data_bytes,
        timeout=120,
    )
    resp.raise_for_status()
    return resp


# ─── Site and drive resolution ─────────────────────────────────────────────────
def _get_site_id() -> str:
    global _site_id
    if _site_id:
        return _site_id

    hostname  = config.SHAREPOINT_HOSTNAME
    site_path = config.SHAREPOINT_SITE_PATH.lstrip("/")

    if not hostname or not site_path:
        raise ValueError(
            "SHAREPOINT_HOSTNAME and SHAREPOINT_SITE_PATH must be set. "
            "Example: SHAREPOINT_HOSTNAME=yourorg.sharepoint.com  "
            "SHAREPOINT_SITE_PATH=/sites/ITStorage"
        )

    resp      = _graph_get(f"/sites/{hostname}:/{site_path}")
    _site_id  = resp.json()["id"]
    print(f"[SHAREPOINT] Resolved site ID: {_site_id}")
    return _site_id


def _get_drive_id() -> str:
    global _drive_id
    if _drive_id:
        return _drive_id

    site_id = _get_site_id()
    drives  = _graph_get(f"/sites/{site_id}/drives").json().get("value", [])

    # Prefer the default "Documents" / "Shared Documents" library
    for d in drives:
        if d.get("name", "").lower() in ("documents", "shared documents", "dokumente"):
            _drive_id = d["id"]
            break

    if not _drive_id and drives:
        _drive_id = drives[0]["id"]      # fall back to first available drive

    if not _drive_id:
        raise RuntimeError("No drives found on the SharePoint site.")

    print(f"[SHAREPOINT] Resolved drive ID: {_drive_id} ('{drives[0].get('name', '?') if drives else '?'}')")
    return _drive_id


# ─── Public API ────────────────────────────────────────────────────────────────
def download_csv(filename: str) -> str:
    """
    Download a CSV file from the configured SharePoint folder.
    Returns the file content as a UTF-8 string.
    Returns an empty string if the file does not yet exist (first run).
    """
    drive_id = _get_drive_id()
    folder   = config.SHAREPOINT_FOLDER.strip("/")
    api_path = f"/drives/{drive_id}/root:/{folder}/{filename}:/content"

    try:
        resp = _graph_get(api_path, stream=True)
        content = resp.content.decode("utf-8-sig")   # strip BOM if present
        print(f"[SHAREPOINT] Downloaded {filename} ({len(content):,} chars)")
        return content
    except requests.exceptions.HTTPError as exc:
        if exc.response is not None and exc.response.status_code == 404:
            print(f"[SHAREPOINT] {filename} does not exist yet — will create on upload")
            return ""
        raise


def upload_csv(filename: str, csv_content: str) -> None:
    """
    Upload a CSV string to SharePoint, overwriting any existing file.

    Note: the simple Graph upload API supports files up to ~4 MB without
    chunking.  At ~150 MB/year this solution will stay well within that
    limit for several years.  A TODO comment marks where to add upload-
    session support if the file ever grows beyond 4 MB.
    """
    drive_id   = _get_drive_id()
    folder     = config.SHAREPOINT_FOLDER.strip("/")
    api_path   = f"/drives/{drive_id}/root:/{folder}/{filename}:/content"
    data_bytes = csv_content.encode("utf-8")

    # TODO: switch to upload session if len(data_bytes) > 4_000_000
    _graph_put(api_path, data_bytes)
    print(f"[SHAREPOINT] Uploaded {filename} ({len(data_bytes):,} bytes)")
