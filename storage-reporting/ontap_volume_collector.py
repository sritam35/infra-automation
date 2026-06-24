"""
ONTAP Volume Collector
======================
SSH into each ONTAP cluster listed in netapp_clusters.conf and collect a
daily capacity snapshot (size, used, available, pct_used) for every
read-write data volume.

Reuses the SSH and instance-output parsing patterns established in
netapp_autogrow_check.py / netapp_health_check.py.
"""

import os
import re
import paramiko
from datetime import date

import config

# ─── Size helpers ─────────────────────────────────────────────────────────────
_UNIT_MAP = {
    "b":  1,
    "kb": 1024,
    "mb": 1024 ** 2,
    "gb": 1024 ** 3,
    "tb": 1024 ** 4,
    "pb": 1024 ** 5,
}
_SIZE_RE = re.compile(r"^\s*([0-9]*\.?[0-9]+)\s*([a-z]+)\s*$", re.IGNORECASE)


def _parse_size_to_bytes(size_str):
    if not size_str or size_str.strip() in ("-", ""):
        return None
    m = _SIZE_RE.match(size_str.strip())
    if not m:
        return None
    multiplier = _UNIT_MAP.get(m.group(2).lower())
    if multiplier is None:
        return None
    return int(float(m.group(1)) * multiplier)


def _bytes_to_gb(num_bytes):
    if num_bytes is None:
        return None
    return round(num_bytes / (1024 ** 3), 2)


def _parse_pct(pct_str):
    """Parse '85%' or '85' to float 85.0.  Returns None if unparseable."""
    if not pct_str or pct_str.strip() in ("-", ""):
        return None
    try:
        return round(float(pct_str.strip().rstrip("%")), 2)
    except ValueError:
        return None


# ─── SSH helpers ──────────────────────────────────────────────────────────────
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
        print(f"  [ONTAP] Connected to {host}")
        return client
    except paramiko.AuthenticationException:
        print(f"  [ONTAP][ERROR] Authentication failed for {host}")
        return None
    except Exception as e:
        print(f"  [ONTAP][ERROR] Cannot connect to {host}: {e}")
        return None


def _exec(ssh_client, command, timeout=90):
    try:
        _, stdout, stderr = ssh_client.exec_command(command, timeout=timeout)
        stdout.channel.recv_exit_status()
        return (stdout.read().decode(errors="replace").strip(),
                stderr.read().decode(errors="replace").strip())
    except Exception as e:
        return "", str(e)


# ─── ONTAP volume show -instance parser ───────────────────────────────────────
# These patterns match the verbose field labels in `volume show -instance` output.
# Multiple regex alternatives handle label variations across ONTAP versions.
_INSTANCE_FIELDS = [
    ("vserver",     re.compile(r"^vserver\s+name\s*:",                                          re.IGNORECASE)),
    ("volume",      re.compile(r"^volume\s+name\s*:",                                           re.IGNORECASE)),
    ("volume_size", re.compile(r"^volume\s+size\s*:",                                           re.IGNORECASE)),
    ("used_size",   re.compile(r"^used\s+size\s*:",                                             re.IGNORECASE)),
    ("avail_size",  re.compile(r"^available\s+size\s*:",                                        re.IGNORECASE)),
    ("pct_used",    re.compile(r"^percent(?:age)?(?:\s+of\s+(?:volume\s+)?(?:space\s+)?)?used\s*:",
                               re.IGNORECASE)),
    # Needed to filter out DP / load-sharing volumes
    ("vol_type",    re.compile(r"^volume\s+type\s*:",                                           re.IGNORECASE)),
]


def _parse_instance_output(output):
    """
    Parse `volume show -instance` output into a list of volume dicts.
    Each dict contains: vserver, volume, volume_size, used_size, avail_size,
    pct_used, vol_type.
    """
    volumes = []
    current = {}

    def _save():
        if current.get("volume"):
            volumes.append(dict(current))

    for line in output.splitlines():
        stripped = line.strip()
        if not stripped:
            continue

        # Each new volume block opens with "Vserver Name:"
        if re.match(r"vserver\s+name\s*:", stripped, re.IGNORECASE):
            _save()
            current = {}

        for key, pattern in _INSTANCE_FIELDS:
            if pattern.search(stripped):
                current[key] = stripped.split(":", 1)[-1].strip()
                break

    _save()
    return volumes


# ─── Per-cluster collection ────────────────────────────────────────────────────
def collect_cluster(cluster):
    """
    SSH into one ONTAP cluster and return a list of daily snapshot dicts.
    Includes both RW and DP/LS volumes, tagged with a volume_type column.
    Skips only root volumes (vol0 / *_root).
    """
    ssh = _connect_ssh(
        cluster,
        config.ONTAP_SSH_PORT,
        config.ONTAP_SSH_USER,
        config.ONTAP_SSH_KEY_PATH,
    )
    if ssh is None:
        return []

    try:
        _exec(ssh, "set -rows 0")           # disable CLI paging
        output, errors = _exec(ssh, "volume show -instance")

        if errors:
            print(f"  [ONTAP][WARN] {cluster} stderr: {errors[:300]}")
        if not output:
            print(f"  [ONTAP][WARN] {cluster}: empty response")
            return []

        raw_vols = _parse_instance_output(output)
        today    = date.today().isoformat()
        records  = []

        for v in raw_vols:
            vol_name = v.get("volume", "")
            vserver  = v.get("vserver", "")

            # Skip root and system internal volumes
            if not vol_name or vol_name == "vol0" or vol_name.endswith("_root"):
                continue

            vol_type = v.get("vol_type", "RW").strip().upper() or "RW"

            size_bytes  = _parse_size_to_bytes(v.get("volume_size", ""))
            used_bytes  = _parse_size_to_bytes(v.get("used_size", ""))
            avail_bytes = _parse_size_to_bytes(v.get("avail_size", ""))
            pct_used    = _parse_pct(v.get("pct_used", ""))

            # Derive avail from size - used when not directly reported
            if size_bytes and used_bytes is not None and avail_bytes is None:
                avail_bytes = max(size_bytes - used_bytes, 0)

            # Derive pct from bytes when not directly reported
            if pct_used is None and size_bytes and used_bytes is not None and size_bytes > 0:
                pct_used = round((used_bytes / size_bytes) * 100, 2)

            records.append({
                "snapshot_date":  today,
                "platform":       "ONTAP",
                "cluster":        cluster,
                "svm":            vserver,
                "volume_name":    vol_name,
                "volume_type":    vol_type,
                "capacity_pool":  "",
                "azure_region":   "",
                "resource_group": "",
                "size_gb":        _bytes_to_gb(size_bytes)  if size_bytes  is not None else "",
                "used_gb":        _bytes_to_gb(used_bytes)  if used_bytes  is not None else "",
                "avail_gb":       _bytes_to_gb(avail_bytes) if avail_bytes is not None else "",
                "pct_used":       pct_used                  if pct_used    is not None else "",
            })

        print(f"  [ONTAP] {cluster}: {len(records)} volumes collected "
              f"(skipped {len(raw_vols) - len(records)} root volumes, "
              f"{sum(1 for r in records if r['volume_type'] == 'DP')} DP replicas included)")
        return records

    finally:
        ssh.close()


# ─── Main entry point ─────────────────────────────────────────────────────────
def collect_all():
    """
    Read cluster list from config, collect volumes from each cluster.
    Returns combined list of snapshot dicts.
    """
    clusters_file = config.ONTAP_CLUSTERS_FILE
    if not os.path.exists(clusters_file):
        print(f"[ONTAP][ERROR] Clusters file not found: {clusters_file}")
        return []

    with open(clusters_file) as fh:
        clusters = [
            line.strip()
            for line in fh
            if line.strip() and not line.startswith("#")
        ]

    print(f"\n[ONTAP] Collecting from {len(clusters)} cluster(s): {clusters}")

    all_records = []
    for cluster in clusters:
        try:
            records = collect_cluster(cluster)
            all_records.extend(records)
        except Exception as e:
            print(f"[ONTAP][ERROR] {cluster}: unhandled exception — {e}")

    print(f"[ONTAP] Total: {len(all_records)} volume snapshot records")
    return all_records
