"""
ONTAP Aggregate Collector
=========================
SSH into each ONTAP cluster and collect daily physical aggregate capacity:
  - aggregate name
  - owning node
  - total size, used size, available size, % used
  - aggregate type (HDD / SSD / hybrid)
  - raid status (optional — for health awareness)

Uses `aggr show -instance` for full untruncated field values.
Reuses the same SSH helpers as ontap_volume_collector.py.

Output: one row per aggregate per day  →  aggr_snapshots.csv  (appended daily)
"""

import os
import re
from datetime import date

import config
from ontap_volume_collector import (
    _connect_ssh,
    _exec,
    _parse_size_to_bytes,
    _bytes_to_gb,
    _parse_pct,
)

# ─── aggr show -instance field patterns ───────────────────────────────────────
# Labels vary slightly across ONTAP 9.x versions; regex handles all variants.
_AGGR_FIELDS = [
    ("aggr_name",   re.compile(r"^aggregate\s*:",                          re.IGNORECASE)),
    ("node",        re.compile(r"^(?:owning\s+)?node\s*name\s*:|^node\s*:", re.IGNORECASE)),
    ("total_size",  re.compile(r"^size\s*:|^aggregate\s+size\s*:",          re.IGNORECASE)),
    ("used_size",   re.compile(r"^used\s+size\s*:|^space\s+used\s*:",       re.IGNORECASE)),
    ("avail_size",  re.compile(r"^available\s+size\s*:|^space\s+available\s*:", re.IGNORECASE)),
    ("pct_used",    re.compile(r"^percent(?:age)?\s+used\s*:|^space\s+used\s+%\s*:", re.IGNORECASE)),
    ("aggr_type",   re.compile(r"^aggregate\s+type\s*:|^storage\s+type\s*:", re.IGNORECASE)),
    ("raid_status", re.compile(r"^raid\s+status\s*:",                       re.IGNORECASE)),
]

# Aggregates to skip — system/internal
_SKIP_AGGR_PATTERNS = ("aggr0", "_root", "aggr0_", "_aggr0")


def _parse_aggr_instance(output: str) -> list:
    """
    Parse `aggr show -instance` output into a list of aggregate dicts.
    Each new aggregate block begins with the 'Aggregate:' line.
    """
    aggrs   = []
    current = {}

    def _save():
        if current.get("aggr_name"):
            aggrs.append(dict(current))

    for line in output.splitlines():
        stripped = line.strip()
        if not stripped:
            continue

        # New aggregate block starts on the 'Aggregate:' label line
        if re.match(r"^aggregate\s*:", stripped, re.IGNORECASE):
            _save()
            current = {}

        for key, pattern in _AGGR_FIELDS:
            if pattern.search(stripped):
                current[key] = stripped.split(":", 1)[-1].strip()
                break

    _save()
    return aggrs


def collect_cluster(cluster: str) -> list:
    """
    SSH into one ONTAP cluster, run `aggr show -instance`, return list of
    aggregate snapshot dicts for today.
    Skips root/system aggregates (aggr0, *_root, etc.).
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
        _exec(ssh, "set -rows 0")
        output, errors = _exec(ssh, "aggr show -instance")

        if errors:
            print(f"  [AGGR][WARN] {cluster} stderr: {errors[:300]}")
        if not output:
            print(f"  [AGGR][WARN] {cluster}: empty response")
            return []

        raw_aggrs = _parse_aggr_instance(output)
        today     = date.today().isoformat()
        records   = []

        for a in raw_aggrs:
            aggr_name = a.get("aggr_name", "").strip()
            if not aggr_name:
                continue

            # Skip system/root aggregates
            name_lower = aggr_name.lower()
            if any(p in name_lower for p in _SKIP_AGGR_PATTERNS):
                continue

            total_bytes = _parse_size_to_bytes(a.get("total_size", ""))
            used_bytes  = _parse_size_to_bytes(a.get("used_size",  ""))
            avail_bytes = _parse_size_to_bytes(a.get("avail_size", ""))
            pct_used    = _parse_pct(a.get("pct_used", ""))

            # Derive avail from total - used when not directly reported
            if total_bytes and used_bytes is not None and avail_bytes is None:
                avail_bytes = max(total_bytes - used_bytes, 0)

            # Derive pct from bytes when not directly reported
            if pct_used is None and total_bytes and used_bytes is not None and total_bytes > 0:
                pct_used = round((used_bytes / total_bytes) * 100, 2)

            records.append({
                "snapshot_date": today,
                "cluster":       cluster,
                "node":          a.get("node",        "").strip(),
                "aggr_name":     aggr_name,
                "aggr_type":     a.get("aggr_type",   "").strip(),
                "raid_status":   a.get("raid_status",  "").strip(),
                "size_gb":       _bytes_to_gb(total_bytes) if total_bytes  is not None else "",
                "used_gb":       _bytes_to_gb(used_bytes)  if used_bytes   is not None else "",
                "avail_gb":      _bytes_to_gb(avail_bytes) if avail_bytes  is not None else "",
                "pct_used":      pct_used                  if pct_used     is not None else "",
            })

        skipped = len(raw_aggrs) - len(records)
        print(f"  [AGGR] {cluster}: {len(records)} aggregates collected "
              f"(skipped {skipped} root/system aggregates)")
        return records

    finally:
        ssh.close()


def collect_all() -> list:
    """
    Read cluster list from config, collect aggregates from each cluster.
    Returns combined list of aggregate snapshot dicts.
    """
    clusters_file = config.ONTAP_CLUSTERS_FILE
    if not os.path.exists(clusters_file):
        print(f"[AGGR][ERROR] Clusters file not found: {clusters_file}")
        return []

    with open(clusters_file) as fh:
        clusters = [
            ln.strip() for ln in fh
            if ln.strip() and not ln.strip().startswith("#")
        ]

    print(f"[AGGR] Collecting from {len(clusters)} cluster(s)")
    all_records = []
    for cluster in clusters:
        all_records.extend(collect_cluster(cluster))

    print(f"[AGGR] Total: {len(all_records)} aggregate snapshot records")
    return all_records
