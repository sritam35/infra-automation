"""
Commvault Volume Mapper
=======================
Reads two pre-generated Commvault CSV reports from a shared directory and
produces a per-volume backup_configured + last_backup_date lookup.

Reports required (both saved to CV_REPORT_DIR, scheduled daily before pipeline):

  1. SubClient Configuration Information  (Content, Filter and Filter Exception)
     Columns: Client, Workload, Instance, Subclient, Content
     Content field: comma-separated UNC paths, e.g.
         UNC-NT_anf-63d0.gmo.tld\\eu2-x-ats-betas, UNC-NT_anf-63d0.gmo.tld\\eu2-x-ats-bonds
     Glob: *SubclientConfigInfo_daily*.csv

  2. Data Protection
     Columns: Client, Agent, Instance, Subclient, ..., Last Backup Start, ...
     Glob: *DataProtectionReport_daily*.csv

Matching strategy
-----------------
  P1 (exact): extract volume name from each UNC content path.
      UNC-NT_anf-63d0.gmo.tld\\eu2-x-ats-betas  →  volume = eu2-x-ats-betas
  P2 (word):  for ANF volumes not matched by P1, use best word-intersection
      between volume name and subclient name (ANF clients only).
      Handles subclients like CUSQuant_ATS that cover multiple ats-* volumes
      without listing each path individually.
"""

import csv
import glob
import os
import re
from datetime import date, datetime


# ─── File helpers ─────────────────────────────────────────────────────────────

def _newest_csv(directory: str, pattern: str):
    """Return the newest file matching glob pattern inside directory, or None."""
    candidates = glob.glob(os.path.join(directory, pattern))
    return max(candidates, key=os.path.getmtime) if candidates else None


def _read_report(path: str):
    """
    Yield rows as dicts from a Commvault Command Center CSV export.
    These files have a 3-line preamble before the real header row.
    Field names are stripped of surrounding whitespace.
    """
    with open(path, newline="", encoding="utf-8-sig", errors="replace") as fh:
        lines = fh.readlines()

    start = 0
    for i, line in enumerate(lines):
        if line.strip().strip('"').startswith("Client"):
            start = i
            break

    reader = csv.DictReader("".join(lines[start:]).splitlines())
    reader.fieldnames = [f.strip() for f in (reader.fieldnames or [])]
    yield from reader


# ─── Parse reports ────────────────────────────────────────────────────────────

def _parse_content_report(path: str) -> dict:
    """
    Parse SubClient Configuration Information CSV (Content section).

    Returns: {volume_name_lower: (subclient, client)}
    Built from exact UNC path last-segments.
    """
    vol_to_sc = {}
    for row in _read_report(path):
        client    = (row.get("Client")    or "").strip()
        subclient = (row.get("Subclient") or "").strip()
        content   = (row.get("Content")   or "").strip()
        if not client or not subclient or not content or subclient.lower() == "default":
            continue
        for raw_path in content.split(","):
            last = re.split(r"[/\\]", raw_path.strip())[-1].strip()
            if not last or "*" in last:
                continue
            if last.lower() not in vol_to_sc:          # first match wins
                vol_to_sc[last.lower()] = (subclient, client)
    return vol_to_sc


def _parse_date_report(path: str) -> dict:
    """
    Parse Data Protection CSV.

    Returns: {(client_lower, subclient_lower): last_backup_date_str}
    """
    DATE_FMTS = ("%B %d, %Y, %I:%M:%S %p", "%b %d, %Y, %I:%M:%S %p", "%m/%d/%Y %H:%M:%S")
    sc_to_date = {}
    for row in _read_report(path):
        client    = (row.get("Client")            or "").strip()
        subclient = (row.get("Subclient")         or "").strip()
        last_bkp  = (row.get("Last Backup Start") or "").strip()
        if not client or not subclient or last_bkp in ("", "Never"):
            continue
        for fmt in DATE_FMTS:
            try:
                date_str = datetime.strptime(last_bkp, fmt).strftime("%Y-%m-%d")
                key = (client.lower(), subclient.lower())
                if key not in sc_to_date or date_str > sc_to_date[key]:
                    sc_to_date[key] = date_str
                break
            except ValueError:
                continue
    return sc_to_date


def _build_anf_word_index(vol_to_sc: dict, sc_to_date: dict) -> list:
    """
    Build word-level index for ANF subclients.
    Returns list of (sc_words, subclient, client, date) for P2 fallback.
    """
    index = []
    seen  = set()
    for (client_l, sc_l), date_str in sc_to_date.items():
        if not client_l.startswith("anf-") or (client_l, sc_l) in seen:
            continue
        seen.add((client_l, sc_l))
        sc_words = {w for w in re.split(r"[_\-]+", sc_l) if len(w) >= 3}
        if not sc_words:
            continue
        # Recover original-case names
        sc_name, client_name = sc_l, client_l
        for sc, cl in vol_to_sc.values():
            if sc.lower() == sc_l and cl.lower() == client_l:
                sc_name, client_name = sc, cl
                break
        index.append((sc_words, sc_name, client_name, date_str))
    return index


# ─── Public API ───────────────────────────────────────────────────────────────

def build_backup_lookup(volume_records: list) -> dict:
    """
    Build a backup-status lookup for every volume in volume_records.

    Returns dict keyed by (cluster, svm, volume_name, platform):
        {last_checked, backup_configured, last_backup_date,
         subclient_name, commvault_client}
    """
    import config
    today      = date.today().isoformat()
    report_dir = config.CV_REPORT_DIR

    content_file = _newest_csv(report_dir, "*SubclientConfigInfo_daily*.csv")
    date_file    = _newest_csv(report_dir, "*DataProtectionReport_daily*.csv")

    missing = [p for p, f in [
        ("*SubclientConfigInfo_daily*.csv",       content_file),
        ("*DataProtectionReport_daily*.csv",       date_file),
    ] if not f]
    if missing:
        print(f"[COMMVAULT][ERROR] Missing report file(s) in {report_dir}: {missing}")
        return _empty_lookup(volume_records, today)

    for f in (content_file, date_file):
        age_h = (datetime.now() - datetime.fromtimestamp(os.path.getmtime(f))).total_seconds() / 3600
        stale = " [STALE > 25h]" if age_h > 25 else ""
        print(f"[COMMVAULT] {os.path.basename(f)}  ({age_h:.1f}h old){stale}")

    vol_to_sc  = _parse_content_report(content_file)
    sc_to_date = _parse_date_report(date_file)
    anf_index  = _build_anf_word_index(vol_to_sc, sc_to_date)

    print(f"[COMMVAULT] {len(vol_to_sc)} exact volume→subclient mappings")
    print(f"[COMMVAULT] {len(sc_to_date)} subclient backup dates")
    print(f"[COMMVAULT] {len(anf_index)} ANF subclients in word-level index")

    lookup = {}
    for rec in volume_records:
        vol_lower  = rec["volume_name"].lower()
        key        = (rec["cluster"], rec["svm"], rec["volume_name"], rec["platform"])
        is_anf_vol = rec.get("platform", "").upper() == "ANF"

        matched_sc = matched_client = matched_date = None

        # P1: exact path match
        if vol_lower in vol_to_sc:
            matched_sc, matched_client = vol_to_sc[vol_lower]
            matched_date = sc_to_date.get((matched_client.lower(), matched_sc.lower()), "")

        # P2: word-level fallback for ANF volumes
        if matched_sc is None and is_anf_vol:
            vol_words  = {w for w in re.split(r"[_\-]+", vol_lower) if len(w) >= 3}
            best_score = (0, 0)
            best_entry = None
            for sc_words, sc_name, client_name, date_str in anf_index:
                inter = vol_words & sc_words
                if not inter:
                    continue
                score = (len(inter), -len(sc_words - vol_words))
                if score > best_score:
                    best_score = score
                    best_entry = (sc_name, client_name, date_str)
            if best_entry:
                matched_sc, matched_client, matched_date = best_entry

        # If matched but no date in Data Protection report → not actively reporting → NA
        if matched_sc is not None and not matched_date:
            configured_flag = "NA"
        elif matched_sc is not None:
            configured_flag = True
        else:
            configured_flag = False

        lookup[key] = {
            "last_checked":      today,
            "backup_configured": configured_flag,
            "last_backup_date":  matched_date or "",
            "subclient_name":    matched_sc     or "",
            "commvault_client":  matched_client or "",
        }

    configured = sum(1 for v in lookup.values() if v["backup_configured"])
    print(f"[COMMVAULT] Result: {configured}/{len(lookup)} volumes have backup configured")
    return lookup


def _empty_lookup(volume_records: list, today: str) -> dict:
    return {
        (r["cluster"], r["svm"], r["volume_name"], r["platform"]): {
            "last_checked":      today,
            "backup_configured": False,
            "last_backup_date":  "",
            "subclient_name":    "",
            "commvault_client":  "",
        }
        for r in volume_records
    }
