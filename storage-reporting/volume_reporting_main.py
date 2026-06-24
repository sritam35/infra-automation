# -*- coding: utf-8 -*-
"""
Storage Volume Reporting - Main Orchestrator
=============================================
Runs all three collectors (ONTAP, ANF, Commvault), merges the results,
and writes two CSVs to SharePoint:

    volume_snapshots.csv   — appended daily; full history (growth trend source)
    backup_status.csv      — overwritten daily; current backup coverage state
    aggr_snapshots.csv     — appended daily; ONTAP physical aggregate capacity

Usage (scheduled via Tidal / cron):
    python volume_reporting_main.py

Developer / test flags:
    --dry-run           collect data but skip SharePoint; write CSVs locally
    --skip-sharepoint   write CSVs locally instead of uploading
    --skip-ontap        skip ONTAP SSH collection
    --skip-anf          skip ANF REST API collection
    --skip-commvault    skip Commvault backup status lookup
    --skip-aggr         skip ONTAP aggregate collection
"""

import argparse
import csv
import io
import sys
from datetime import date

import config
import ontap_volume_collector
import ontap_aggr_collector
import anf_volume_collector
import commvault_volume_mapper
import dfs_collector
import sharepoint_helper


# ─── CSV helpers ──────────────────────────────────────────────────────────────
def _parse_csv(raw_text: str) -> list:
    """Parse a CSV string into a list of dicts.  Returns [] if empty."""
    if not raw_text or not raw_text.strip():
        return []
    return list(csv.DictReader(io.StringIO(raw_text)))


def _write_csv(rows: list, cols: list) -> str:
    """Serialise a list-of-dicts to a CSV string with a fixed column order."""
    buf    = io.StringIO()
    writer = csv.DictWriter(
        buf, fieldnames=cols, extrasaction="ignore", lineterminator="\n"
    )
    writer.writeheader()
    writer.writerows(rows)
    return buf.getvalue()


def _write_local(filename: str, content: str) -> None:
    with open(filename, "w", encoding="utf-8") as fh:
        fh.write(content)
    print(f"[MAIN] Local file written: {filename}")


# ─── Main ─────────────────────────────────────────────────────────────────────
def main(
    dry_run:         bool = False,
    skip_sharepoint: bool = False,
    skip_ontap:      bool = False,
    skip_anf:        bool = False,
    skip_commvault:  bool = False,
    skip_dfs:        bool = False,
    skip_aggr:       bool = False,
) -> int:

    today = date.today().isoformat()
    print(f"\n{'=' * 70}")
    print(f"  Storage Volume Reporting — {today}")
    print(f"{'=' * 70}")

    # ── Step 1: Collect volume capacity snapshots ──────────────────────────
    new_snapshot_rows: list = []

    if not skip_ontap:
        try:
            new_snapshot_rows.extend(ontap_volume_collector.collect_all())
        except Exception as exc:
            print(f"[MAIN][ERROR] ONTAP collector raised an exception: {exc}")
    else:
        print("[MAIN] --skip-ontap: ONTAP collection skipped")

    if not skip_anf:
        try:
            new_snapshot_rows.extend(anf_volume_collector.collect_all())
        except Exception as exc:
            print(f"[MAIN][ERROR] ANF collector raised an exception: {exc}")
    else:
        print("[MAIN] --skip-anf: ANF collection skipped")

    print(f"\n[MAIN] New snapshot rows collected today: {len(new_snapshot_rows)}")

    if not new_snapshot_rows:
        print("[MAIN] No volume data collected — nothing to write. Exiting.")
        return 1

    # ── Step 2: Build Commvault backup status ──────────────────────────────
    backup_lookup: dict = {}
    if not skip_commvault:
        try:
            backup_lookup = commvault_volume_mapper.build_backup_lookup(new_snapshot_rows)
        except Exception as exc:
            print(f"[MAIN][ERROR] Commvault mapper raised an exception: {exc}")
            print("[MAIN] Backup status will default to False for all volumes.")
    else:
        print("[MAIN] --skip-commvault: backup lookup skipped")

    # ── Business rules for backup_configured override ─────────────────────
    # Volumes where backup is structurally Not Applicable (NA):
    #   - All ANF volumes from anf-primary-account (EU2 ANF — no Commvault backup taken)
    #   - ONTAP volumes whose names contain any of the following patterns
    #     (test/infra/system volumes that are never backed up by design)
    _NA_VOL_PATTERNS = ("tst", "sqlbkp", "root", "esx", "cvault", "test")

    def _backup_override(rec: dict, cv_result: bool) -> str:
        """Return 'NA', True, or False for backup_configured."""
        vol   = rec["volume_name"].lower()
        plat  = rec["platform"]
        clust = rec["cluster"]
        # DP/LS replica volumes — never directly Commvault-protected
        if plat == "ONTAP" and rec.get("volume_type", "RW") in ("DP", "LS"):
            return "NA"
        # EU2 ANF — no backup by design
        if plat == "ANF" and clust == "anf-primary-account":
            return "NA"
        # ONTAP test/infra volumes — not applicable
        if plat == "ONTAP" and any(p in vol for p in _NA_VOL_PATTERNS):
            return "NA"
        return cv_result

    # Assemble backup_status rows (one row per volume collected today)
    backup_rows: list = []
    for rec in new_snapshot_rows:
        key = (rec["cluster"], rec["svm"], rec["volume_name"], rec["platform"])
        bk  = backup_lookup.get(key, {
            "last_checked":      today,
            "backup_configured": False,
            "last_backup_date":  "",
            "subclient_name":    "",
            "commvault_client":  "",
        })
        configured_val = _backup_override(rec, bk["backup_configured"])
        backup_rows.append({
            "last_checked":      bk["last_checked"],
            "platform":          rec["platform"],
            "cluster":           rec["cluster"],
            "svm":               rec["svm"],
            "volume_name":       rec["volume_name"],
            "volume_type":       rec.get("volume_type", ""),
            "backup_configured": configured_val,
            # Clear last_backup_date for NA volumes (not applicable)
            "last_backup_date":  "" if configured_val == "NA" else bk.get("last_backup_date", ""),
            "subclient_name":    bk["subclient_name"],
            "commvault_client":  bk["commvault_client"],
        })

    # ── Step 3: Merge with historical snapshot data ────────────────────────
    existing_snapshot_rows: list = []

    if not (dry_run or skip_sharepoint):
        try:
            raw = sharepoint_helper.download_csv(config.CSV_SNAPSHOTS)
            existing_snapshot_rows = _parse_csv(raw)
        except Exception as exc:
            print(f"[MAIN][WARN] Could not download existing snapshots: {exc}")
            print("[MAIN] Starting fresh — existing history will not be merged.")
    else:
        # Try to load a local copy for idempotency during dev/test runs
        try:
            with open(config.CSV_SNAPSHOTS, encoding="utf-8") as fh:
                existing_snapshot_rows = _parse_csv(fh.read())
        except FileNotFoundError:
            pass

    # Remove today's rows before appending (ensures the script is idempotent on reruns)
    existing_snapshot_rows = [
        r for r in existing_snapshot_rows if r.get("snapshot_date") != today
    ]

    combined_snapshot_rows = existing_snapshot_rows + new_snapshot_rows
    print(
        f"[MAIN] Snapshot rows: {len(existing_snapshot_rows)} existing  "
        f"+ {len(new_snapshot_rows)} new  = {len(combined_snapshot_rows)} total"
    )

    # ── Step 4: Serialise to CSV ───────────────────────────────────────────
    snapshots_csv     = _write_csv(combined_snapshot_rows, config.SNAPSHOT_COLS)
    backup_status_csv = _write_csv(backup_rows,            config.BACKUP_COLS)

    # ── Step 4b: Collect DFS mapping ──────────────────────────────────────
    dfs_rows: list = []
    if not skip_dfs:
        try:
            dfs_rows = dfs_collector.collect_all()
        except Exception as exc:
            print(f"[MAIN][WARN] DFS collection failed: {exc}")
            print("[MAIN] Continuing without DFS mapping.")
    dfs_mapping_csv = _write_csv(dfs_rows, config.DFS_MAPPING_COLS)

    # ── Step 4c: Collect ONTAP aggregate snapshots ────────────────────────
    aggr_rows: list = []
    if not skip_aggr and not skip_ontap:
        try:
            aggr_rows = ontap_aggr_collector.collect_all()
        except Exception as exc:
            print(f"[MAIN][WARN] Aggregate collection failed: {exc}")
            print("[MAIN] Continuing without aggregate data.")

    # Merge with existing aggr history (same idempotency pattern as snapshots)
    existing_aggr_rows: list = []
    if not (dry_run or skip_sharepoint) and aggr_rows:
        try:
            raw = sharepoint_helper.download_csv(config.CSV_AGGR_SNAPSHOTS)
            existing_aggr_rows = _parse_csv(raw)
        except Exception:
            pass
    existing_aggr_rows = [
        r for r in existing_aggr_rows if r.get("snapshot_date") != today
    ]
    combined_aggr_rows = existing_aggr_rows + aggr_rows
    aggr_snapshots_csv = _write_csv(combined_aggr_rows, config.AGGR_COLS)

    # ── Step 5: Upload to SharePoint (or write locally) ────────────────────
    if dry_run:
        print(
            f"\n[DRY RUN] Skipping SharePoint upload. "
            f"Writing local files for inspection."
        )
        _write_local(config.CSV_SNAPSHOTS,       snapshots_csv)
        _write_local(config.CSV_BACKUP_STATUS,    backup_status_csv)
        _write_local(config.CSV_DFS_MAPPING,      dfs_mapping_csv)
        _write_local(config.CSV_AGGR_SNAPSHOTS,   aggr_snapshots_csv)
        print(f"[DRY RUN] Complete.")
        return 0

    if skip_sharepoint:
        _write_local(config.CSV_SNAPSHOTS,       snapshots_csv)
        _write_local(config.CSV_BACKUP_STATUS,    backup_status_csv)
        _write_local(config.CSV_DFS_MAPPING,      dfs_mapping_csv)
        _write_local(config.CSV_AGGR_SNAPSHOTS,   aggr_snapshots_csv)
    else:
        upload_ok = True
        for filename, content in (
            (config.CSV_SNAPSHOTS,       snapshots_csv),
            (config.CSV_BACKUP_STATUS,    backup_status_csv),
            (config.CSV_DFS_MAPPING,      dfs_mapping_csv),
            (config.CSV_AGGR_SNAPSHOTS,   aggr_snapshots_csv),
        ):
            try:
                sharepoint_helper.upload_csv(filename, content)
            except Exception as exc:
                print(f"[MAIN][ERROR] Failed to upload {filename}: {exc}")
                print(f"[MAIN] Writing {filename} locally as fallback.")
                _write_local(filename, content)
                upload_ok = False

        if not upload_ok:
            return 1

    # ── Summary ────────────────────────────────────────────────────────────
    configured  = sum(1 for r in backup_rows if str(r.get("backup_configured")).lower() == "true")
    not_applic  = sum(1 for r in backup_rows if str(r.get("backup_configured")).upper() == "NA")
    not_config  = len(backup_rows) - configured - not_applic
    print(f"\n[MAIN] -- Summary --------------------------------------------------")
    print(f"[MAIN] Date             : {today}")
    print(f"[MAIN] Volumes reported : {len(new_snapshot_rows)}")
    print(f"[MAIN] With backup      : {configured}")
    print(f"[MAIN] Without backup   : {not_config}")
    print(f"[MAIN] Not applicable   : {not_applic}  (anf-primary-account + tst/sqlbkp/root/esx/cvault/test volumes)")
    print(f"[MAIN] Snapshot history : {len(combined_snapshot_rows)} total rows")
    print(f"[MAIN] DFS mappings     : {len(dfs_rows)} path \u2192 volume records")
    print(f"[MAIN] Aggregates       : {len(combined_aggr_rows)} total rows ({len(aggr_rows)} new)")
    print(f"[MAIN] ------------------------------------------------------------")
    return 0


# ─── CLI entry point ──────────────────────────────────────────────────────────
if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Storage Volume Reporting — daily capacity & backup status collector"
    )
    parser.add_argument("--dry-run",         action="store_true",
                        help="Collect data, write CSVs locally; skip SharePoint upload")
    parser.add_argument("--skip-sharepoint", action="store_true",
                        help="Write CSVs locally instead of uploading to SharePoint")
    parser.add_argument("--skip-ontap",      action="store_true",
                        help="Skip ONTAP SSH collection")
    parser.add_argument("--skip-anf",        action="store_true",
                        help="Skip ANF REST API collection")
    parser.add_argument("--skip-commvault",  action="store_true",
                        help="Skip Commvault backup status lookup")
    parser.add_argument("--skip-dfs",        action="store_true",
                        help="Skip DFS path → volume mapping collection")
    parser.add_argument("--skip-aggr",       action="store_true",
                        help="Skip ONTAP aggregate collection")
    args = parser.parse_args()

    sys.exit(main(
        dry_run         = args.dry_run,
        skip_sharepoint = args.skip_sharepoint,
        skip_ontap      = args.skip_ontap,
        skip_anf        = args.skip_anf,
        skip_commvault  = args.skip_commvault,
        skip_dfs        = args.skip_dfs,
        skip_aggr       = args.skip_aggr,
    ))
