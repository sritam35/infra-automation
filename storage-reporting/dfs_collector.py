"""
DFS Mapping Collector
=====================
Enumerates all DFS folder targets via PowerShell (Get-DfsnFolderTarget),
then maps each target UNC share to its underlying storage volume by:
  - ONTAP: SSH into each cluster → vserver cifs share show
  - ANF:   Hostname pattern match (anf-*) → share name == volume name

Output: dfs_mapping.csv  (one row per unique DFS path → volume mapping)
        Uploaded to SharePoint alongside volume_snapshots.csv

Designed to run on a Windows domain-joined Azure DevOps agent with DFS
namespaces accessible.
"""

import csv
import io
import os
import re
import subprocess

import paramiko

import config


# ─── SSH helpers (mirrors ontap_volume_collector pattern) ─────────────────────
def _connect_ssh(host, port, username, key_filepath=None, timeout=15):
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        if key_filepath and os.path.exists(key_filepath):
            key = paramiko.RSAKey.from_private_key_file(key_filepath)
            client.connect(hostname=host, port=port, username=username,
                           pkey=key, timeout=timeout)
        else:
            password = os.environ.get("NETAPP_SSH_PASSWORD", "")
            client.connect(hostname=host, port=port, username=username,
                           password=password, timeout=timeout)
        return client
    except Exception as exc:
        print(f"  [DFS][ERROR] SSH to {host}: {exc}")
        return None


def _exec(ssh_client, command, timeout=90):
    try:
        _, stdout, stderr = ssh_client.exec_command(command, timeout=timeout)
        stdout.channel.recv_exit_status()
        return (stdout.read().decode(errors="replace").strip(),
                stderr.read().decode(errors="replace").strip())
    except Exception as exc:
        return "", str(exc)


# ─── ONTAP column-width parser ────────────────────────────────────────────────
def _parse_ontap_table(output):
    """
    Parse ONTAP fixed-width tabular output.
    Locates the separator line (--- --- ---) to determine column positions,
    then slices each data row accordingly.
    Returns list of lists (one per data row).
    """
    lines = output.splitlines()
    sep_idx = None
    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped and re.match(r"^[-\s]+$", stripped) and "-" in stripped:
            sep_idx = i
            break
    if sep_idx is None:
        return []

    sep_line = lines[sep_idx]
    col_spans = [(m.start(), m.end()) for m in re.finditer(r"-+", sep_line)]
    if not col_spans:
        return []

    results = []
    for line in lines[sep_idx + 1:]:
        if not line.strip():
            continue
        row = [line[s:e].strip() for s, e in col_spans]
        results.append(row)
    return results


# ─── ONTAP CIFS share → volume mapping ───────────────────────────────────────
def _collect_cifs_shares(clusters_file):
    """
    SSH into each ONTAP cluster and collect cifs share → volume mapping.
    Returns dict: share_name_lower -> list of (svm, volume_name)
    Duplicate share names across SVMs are preserved for disambiguation.
    """
    if not os.path.exists(clusters_file):
        print(f"[DFS][ERROR] Clusters file not found: {clusters_file}")
        return {}

    with open(clusters_file) as fh:
        clusters = [
            line.strip()
            for line in fh
            if line.strip() and not line.startswith("#")
        ]

    share_map = {}   # share_name_lower -> [(svm, volume_name), ...]

    for cluster in clusters:
        ssh = _connect_ssh(
            cluster,
            config.ONTAP_SSH_PORT,
            config.ONTAP_SSH_USER,
            config.ONTAP_SSH_KEY_PATH,
        )
        if ssh is None:
            continue

        try:
            _exec(ssh, "set -rows 0")
            # Use -instance output to avoid fixed-width column truncation
            out, err = _exec(ssh, "vserver cifs share show -instance")
            if err:
                print(f"  [DFS][WARN] {cluster} CIFS stderr: {err[:200]}")

            count = 0
            current = {}
            for line in out.splitlines():
                stripped = line.strip()
                if not stripped:
                    continue
                # Detect new record boundary — starts with "Vserver:"
                if re.match(r"vserver\s*:", stripped, re.IGNORECASE):
                    # flush previous record
                    if current.get("share") and current.get("volume") and current.get("vserver"):
                        key = current["share"].lower()
                        share_map.setdefault(key, []).append(
                            (current["vserver"], current["volume"])
                        )
                        count += 1
                    current = {"vserver": stripped.split(":", 1)[-1].strip()}
                    continue
                if re.match(r"share\s*:", stripped, re.IGNORECASE):
                    current["share"] = stripped.split(":", 1)[-1].strip()
                elif re.match(r"volume\s+name\s*:", stripped, re.IGNORECASE):
                    # "Volume Name:" field — exact volume name, no parsing needed
                    vol = stripped.split(":", 1)[-1].strip()
                    if vol and vol != "-":
                        current["volume"] = vol
            # flush last record
            if current.get("share") and current.get("volume") and current.get("vserver"):
                key = current["share"].lower()
                share_map.setdefault(key, []).append(
                    (current["vserver"], current["volume"])
                )
                count += 1
            print(f"  [DFS] {cluster}: {count} CIFS share→volume entries")
        finally:
            ssh.close()

    print(f"[DFS] Total unique share names across all clusters: {len(share_map)}")
    return share_map


# ─── PowerShell DFS enumeration ───────────────────────────────────────────────
def _get_dfs_targets():
    """
    Run PowerShell to enumerate all DFS folder targets.
    Excludes ReplicationOnly namespaces.
    Returns list of dicts with keys: dfs_path, target_path, state.
    """
    ps_script = (
        "Get-DfsnRoot -ErrorAction SilentlyContinue "
        "| Where-Object { $_.Path -notmatch 'ReplicationOnly' } "
        "| ForEach-Object { "
        "    Get-DfsnFolder -Path ($_.Path + '\\*') -ErrorAction SilentlyContinue "
        "} "
        "| ForEach-Object { "
        "    Get-DfsnFolderTarget -Path $_.Path -ErrorAction SilentlyContinue "
        "} "
        "| Select-Object Path, TargetPath, State "
        "| ConvertTo-Csv -NoTypeInformation"
    )

    try:
        result = subprocess.run(
            ["powershell", "-NonInteractive", "-Command", ps_script],
            capture_output=True,
            text=True,
            timeout=300,
            env={**os.environ, "PYTHONIOENCODING": "utf-8"},
        )
    except subprocess.TimeoutExpired:
        print("[DFS][ERROR] PowerShell DFS enumeration timed out after 5 min")
        return []
    except Exception as exc:
        print(f"[DFS][ERROR] Failed to run PowerShell: {exc}")
        return []

    if result.returncode != 0:
        print(f"[DFS][WARN] PowerShell exit {result.returncode}: {result.stderr[:300]}")

    rows = []
    try:
        reader = csv.DictReader(io.StringIO(result.stdout))
        for row in reader:
            path   = row.get("Path",       "").strip().strip('"')
            target = row.get("TargetPath", "").strip().strip('"')
            state  = row.get("State",      "").strip().strip('"')
            if path and target:
                rows.append({"dfs_path": path, "target_path": target, "state": state})
    except Exception as exc:
        print(f"[DFS][ERROR] Failed to parse PowerShell output: {exc}")
        return []

    print(f"[DFS] Enumerated {len(rows)} DFS folder targets")
    return rows


# ─── UNC helpers ─────────────────────────────────────────────────────────────
_ANF_HOST_RE = re.compile(r"^anf-", re.IGNORECASE)


def _parse_unc(target_path):
    """
    Parse \\server\share[\subpath] into (server_lower, share_lower).
    Strips .corp.example.com suffix from hostname if present.
    Returns (None, None) if unparseable.
    """
    stripped = target_path.lstrip("\\").lstrip("/")
    stripped = re.sub(r"\.corp.example.com", "", stripped, flags=re.IGNORECASE)
    parts = stripped.split("\\", 2)
    if len(parts) < 2:
        return None, None
    return parts[0].lower(), parts[1].lower()


def _extract_svm_hint(hostname):
    """
    Derive likely SVM name from a node-interface hostname.
    Examples:
      marprdsmb32_ha1a_smb  ->  marprdsmb32
      eu2prdsmb01_ha1n2_smb ->  eu2prdsmb01
    Falls back to full hostname if pattern not matched.
    """
    m = re.match(r"^([a-z0-9]+)_ha", hostname, re.IGNORECASE)
    if m:
        return m.group(1).lower()
    return hostname.lower()


# ─── Main collection ──────────────────────────────────────────────────────────
def collect_all():
    """
    Collect DFS path → storage volume mapping.
    Returns list of dicts with keys:
        dfs_path, target_path, svm, volume_name, state
    Deduplicated to one row per unique (dfs_path, volume_name) pair,
    preferring Online targets over Offline.
    """
    clusters_file = config.ONTAP_CLUSTERS_FILE
    print("\n[DFS] Collecting CIFS share map from ONTAP clusters...")
    share_map = _collect_cifs_shares(clusters_file)

    print("[DFS] Enumerating DFS folder targets via PowerShell...")
    dfs_targets = _get_dfs_targets()

    if not dfs_targets:
        print("[DFS][WARN] No DFS targets returned — DFS mapping will be empty")
        return []

    records  = []
    unmapped = 0

    for t in dfs_targets:
        dfs_path    = t["dfs_path"]
        target_path = t["target_path"]
        state       = t["state"]

        hostname, share_name = _parse_unc(target_path)
        if hostname is None:
            continue

        # ── ANF target ──────────────────────────────────────────────────────
        if _ANF_HOST_RE.match(hostname):
            records.append({
                "dfs_path":    dfs_path,
                "target_path": target_path,
                "svm":         "",           # ANF has no SVM concept
                "volume_name": share_name,   # ANF share name == volume name
                "state":       state,
            })
            continue

        # ── ONTAP target ────────────────────────────────────────────────────
        candidates = share_map.get(share_name, [])
        if not candidates:
            unmapped += 1
            continue   # mirror/replica share or uncatalogued — skip

        if len(candidates) == 1:
            svm, volume_name = candidates[0]
        else:
            # Multiple SVMs have the same share name — disambiguate using
            # the SVM extracted from the node-interface hostname.
            svm_hint = _extract_svm_hint(hostname)
            matched  = [(s, v) for s, v in candidates if s.lower() == svm_hint]
            svm, volume_name = matched[0] if matched else candidates[0]

        records.append({
            "dfs_path":    dfs_path,
            "target_path": target_path,
            "svm":         svm,
            "volume_name": volume_name,
            "state":       state,
        })

    # Deduplicate: one row per (dfs_path, volume_name), prefer Online
    seen: dict = {}
    for r in records:
        key = (r["dfs_path"], r["volume_name"])
        if key not in seen or r["state"].lower() == "online":
            seen[key] = r
    # Only keep Online entries — Offline entries are DR/mirror targets not actively used
    deduped = [r for r in seen.values() if r["state"].lower() == "online"]

    print(
        f"[DFS] Mapped {len(deduped)} DFS path → volume records "
        f"({unmapped} targets skipped — mirror/unmapped shares)"
    )
    return deduped
