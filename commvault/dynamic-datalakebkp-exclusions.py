"""
Commvault History Table Exclusion Manager
==========================================
This script dynamically updates the Commvault subclient exclusion list
to exclude all history table quarters EXCEPT the current quarter.

Schedule: Run monthly before full backup starts
Purpose: Ensures only current quarter history data is backed up
"""

import os
import sys
import urllib3
import requests
import json
from datetime import datetime
from pathlib import Path

# Add current directory to path for token_manager import
sys.path.insert(0, str(Path(__file__).parent))
from token_manager import TokenManager

# Suppress InsecureRequestWarning
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# Configuration
COMMVAULT_URL = "https://bedprdbck001/commandcenter/api/Subclient/1776"
SUBCLIENT_ID = 1776
INSTANCE_ID = 143
CLIENT_ID = 491
APPLICATION_ID = 134

# Define all history table names for GDM
GDM_HISTORY_TABLES = [
    "credit-entity-info",
    "credit-entity-item",
    "credit-market-item",
    "credit-rating",
    "credit-rating-item",
    "credit-rating-tier",
    "credit-seniority",
    "credit-tenor",
    "datastream-macro-series-attribute-item-override",
    "datastream-macro-series-attributes",
    "dbo-issuer-master",
    "dbo-security-master",
    "dbo-security-split-factor",
    "esg-green-revenue-data",
    "index-data-constituent",
    "internal-credit-entity",
    "internal-credit-entity-market-data",
    "internal-credit-rating",
    "internal-issuer-market-cap-data",
    "internal-macro-entity",
    "internal-macro-factors",
    "internal-macro-info",
    "internal-security-dividend",
    "internal-security-split",
    "macro-primary-source",
    "macro-series",
    "priority-credit-market",
]

# Define all history table names for Astral
ASTRAL_HISTORY_TABLES = [
    "gdm-currency-cross-rate",
    "gdm-estimate-summary",
    "gdm-filing",
    "gdm-filing-detail",
    "gdm-index-market-data",
    "gdm-issuer-hierarchy",
    "gdm-issuer-hierarchy-ultimate-parent",
    "gdm-issuer-info",
    "gdm-security-info",
    "gdm-security-market-data",
    "gmo-security-master-feed",
]


def generate_all_quarters(start_year=2024, years_ahead=0):
    """
    Generate all quarters dynamically from start_year to current_year + years_ahead.

    By default, generates quarters from start_year to current_year only.
    Script runs on 1st of every month, so it always catches quarter changes immediately.

    Args:
        start_year (int): The starting year for quarter generation (default: 2024)
        years_ahead (int): Number of years ahead of current year to generate (default: 0)

    Returns:
        list: List of quarters in format 'YYYY_qQ'
    """
    current_year = datetime.now().year
    end_year = current_year + years_ahead

    quarters = []
    for year in range(start_year, end_year + 1):
        for quarter in range(1, 5):
            quarters.append(f"{year}_q{quarter}")

    return quarters


def get_current_quarter():
    """
    Calculate the current quarter based on the current date.

    Returns:
        str: Current quarter in format 'YYYY_qQ' (e.g., '2025_q4')
    """
    now = datetime.now()
    year = now.year
    month = now.month

    # Determine quarter based on month
    if 1 <= month <= 3:
        quarter = 1
    elif 4 <= month <= 6:
        quarter = 2
    elif 7 <= month <= 9:
        quarter = 3
    else:  # 10-12
        quarter = 4

    return f"{year}_q{quarter}"


def generate_history_exclusions(current_quarter):
    """
    Generate exclusion paths for all history table quarters except the current one.

    Args:
        current_quarter (str): Current quarter in format 'YYYY_qQ'

    Returns:
        list: List of exclusion path dictionaries
    """
    exclusions = []

    # Generate all quarters dynamically
    all_quarters = generate_all_quarters()

    # Generate GDM history table exclusions
    for table in GDM_HISTORY_TABLES:
        for quarter in all_quarters:
            if quarter != current_quarter:
                path = f"/app-gdm/curated/gdm/history/{table}/{quarter}"
                exclusions.append({"excludePath": path})

    # Generate Astral history table exclusions
    for table in ASTRAL_HISTORY_TABLES:
        for quarter in all_quarters:
            if quarter != current_quarter:
                path = f"/app-gdm/curated/astral/history/{table}/{quarter}"
                exclusions.append({"excludePath": path})

    return exclusions


def load_static_exclusions():
    """
    Load static exclusion paths that never change.

    Returns:
        list: List of static exclusion path dictionaries
    """
    static_exclusions = []

    # Transient folders
    static_exclusions.append({"excludePath": "/app-gdm/transient"})
    static_exclusions.append({"excludePath": "/src-vdm/transient"})

    # src-vdm vendor data exclusions
    src_vdm_paths = [
        "factset/gr-v2/gr-item", "factset/gr-v2/gr-report",
        "factset/own-v5/own-ent-13f-filing-hist", "factset/own-v5/own-ent-fund-filing-hist",
        "factset/own-v5/own-ent-funds", "factset/own-v5/own-ent-institutions",
        "factset/own-v5/own-fund-detail", "factset/own-v5/own-fund-generic",
        "factset/own-v5/own-inst-13f-detail", "factset/own-v5/own-inst-stakes-detail",
        "factset/own-v5/own-sec-coverage", "factset/own-v5/own-sec-prices",
        "factset/ref-v2/entity-type-map", "factset/sym-v1/sym-coverage",
        "factset/sym-v1/sym-entity", "factset/tv-v2/tv-esg-ranks",
        "factset/tv-v2/tv-insight", "factset/tv-v2/tv-momentum",
        "factset/tv-v2/tv-pulse", "factset/tv-v2/tv-volume",
        "ivydb-asia/dbo/currency", "ivydb-asia/dbo/option-price",
        "ivydb-asia/dbo/option-price-2004", "ivydb-asia/dbo/option-price-2005",
        "ivydb-asia/dbo/option-price-2006", "ivydb-asia/dbo/option-price-2007",
        "ivydb-asia/dbo/option-price-2008", "ivydb-asia/dbo/option-price-2009",
        "ivydb-asia/dbo/option-price-2010", "ivydb-asia/dbo/option-price-2011",
        "ivydb-asia/dbo/option-price-2012", "ivydb-asia/dbo/option-price-2013",
        "ivydb-asia/dbo/option-price-2014", "ivydb-asia/dbo/option-price-2015",
        "ivydb-asia/dbo/option-price-2016", "ivydb-asia/dbo/option-price-2017",
        "ivydb-asia/dbo/option-price-2018", "ivydb-asia/dbo/option-price-2019",
        "ivydb-asia/dbo/security-price", "ivydb-canada/dbo/option-info",
        "ivydb-canada/dbo/option-price", "ivydb-canada/dbo/option-price-2006",
        "ivydb-canada/dbo/option-price-2007", "ivydb-canada/dbo/option-price-2008",
        "ivydb-canada/dbo/option-price-2009", "ivydb-canada/dbo/option-price-2010",
        "ivydb-canada/dbo/option-price-2011", "ivydb-canada/dbo/option-price-2012",
        "ivydb-canada/dbo/option-price-2013", "ivydb-canada/dbo/option-price-2014",
        "ivydb-canada/dbo/option-price-2015", "ivydb-canada/dbo/option-price-2016",
        "ivydb-canada/dbo/option-price-2017", "ivydb-canada/dbo/option-price-2018",
        "ivydb-canada/dbo/option-price-2019", "ivydb-canada/dbo/option-price-2020",
        "ivydb-canada/dbo/security-price", "ivydb-europe/dbo/currency",
        "ivydb-europe/dbo/option-price", "ivydb-europe/dbo/option-price-2002",
        "ivydb-europe/dbo/option-price-2003", "ivydb-europe/dbo/option-price-2004",
        "ivydb-europe/dbo/option-price-2005", "ivydb-europe/dbo/option-price-2006",
        "ivydb-europe/dbo/option-price-2007", "ivydb-europe/dbo/option-price-2008",
        "ivydb-europe/dbo/option-price-2009", "ivydb-europe/dbo/option-price-2010",
        "ivydb-europe/dbo/option-price-2011", "ivydb-europe/dbo/option-price-2012",
        "ivydb-europe/dbo/option-price-2013", "ivydb-europe/dbo/option-price-2014",
        "ivydb-europe/dbo/option-price-2015", "ivydb-europe/dbo/option-price-2016",
        "ivydb-europe/dbo/option-price-2017", "ivydb-europe/dbo/option-price-2018",
        "ivydb-europe/dbo/option-price-2019", "ivydb-europe/dbo/option-price-2020",
        "ivydb-europe/dbo/security-price", "ivydb-us/dbo/option-info",
        "ivydb-us/dbo/option-price", "ivydb-us/dbo/security-price",
        "qai/dbo/ds2ctryqtinfo", "qai/dbo/ds2exchqtinfo",
        "qai/dbo/ds2primqtprc", "qai/dbo/ds2primqtri",
        "qai/dbo/fiejvevalprc", "qai/dbo/fiejvprcdly",
        "qai/dbo/fiejvsecinfo", "qai/dbo/ibesmsrcode",
        "qai/dbo/igachg", "qai/dbo/igactryestdata",
        "qai/dbo/igarussestdata", "qai/dbo/igaspestdata",
        "qai/dbo/igatopixestdata", "qai/dbo/wspitcalprd",
        "qai/dbo/wspitcmpissddata", "qai/dbo/wspitcmpissidata",
        "qai/dbo/wspitcmpisssdata", "qai/dbo/wspitinfo",
        "qai/dbo/wspitstmtddata", "qai/dbo/wspitstmtidata",
        "qai/dbo/wspitstmtsdata", "qai/dbo/wspitsupp",
        "vendordatamart/bloomberg/equity-master", "vendordatamart/bloomberg/equity-price",
        "vendordatamart/bloomberg/equity-price-historical-change",
        "vendordatamart/bloomberg/equity-price-revision",
        "vendordatamart/datastream/security-rz-returns",
        "vendordatamart/datastream/series-attributes",
        "vendordatamart/dbo/loadfiles", "vendordatamart/ibes/analyst",
        "vendordatamart/ibes/estimates-detail",
        "vendordatamart/ibes/estimates-excluded-detail",
        "vendordatamart/ibes/report-currency",
        "vendordatamart/ibes/summary-statistics",
        "vendordatamart/ibes/surprise-history",
        "vendordatamart/ibesqfs/actual",
        "vendordatamart/ibesqfs/currency-change",
        "vendordatamart/ibesqfs/detail-estimate",
        "vendordatamart/ibesqfs/summary-estimates",
        "vendordatamart/msci/core-infra-monthly",
        "xpressfeed/dbo/ciqcompany", "xpressfeed/dbo/ciqgvkeyiid",
    ]

    for path in src_vdm_paths:
        static_exclusions.append({"excludePath": f"/src-vdm/cleansed/{path}"})

    # app-gdm curated static exclusions
    app_gdm_paths = [
        "assetfour/esg-item-map", "barclays/index-map", "barclays-live/index-map",
        "barclays-live/lcs-index-map", "bloomberg/id-bb-unique-security-id-override",
        "bloomberg/ranged-security-equity", "bloomberg/security-type-map",
        "bloomberg/vol-exchange-primary-exchange-map", "bloomberg-port/index-map",
        "corporate-action/issuer-action-master", "credit/entity-info",
        "credit/entity-item", "credit/market-item", "credit/rating",
        "credit/rating-item", "credit/rating-tier", "credit/seniority",
        "credit/tenor", "datastream/exchange-map", "datastream/macro-series-attributes",
        "datastream/market-data-country-exclusions", "datastream/total-return-dscodes-ri",
        "dbo/country", "dbo/currency", "dbo/euro-conversion-rate",
        "dbo/exchange", "dbo/exchange-rate", "dbo/gics-group",
        "dbo/gics-industry", "dbo/gics-sector", "dbo/gics-subindustry",
        "dbo/issuer-info", "dbo/issuer-item", "dbo/issuer-master",
        "dbo/provider", "dbo/security-group-master", "dbo/security-hierarchy",
        "dbo/security-hierarchy-master", "dbo/security-hierarchy-membership",
        "dbo/security-hierarchy-node", "dbo/security-hierarchy-source",
        "dbo/security-info", "dbo/security-item", "dbo/security-market-item",
        "dbo/security-master", "dbo/security-return-bypass",
        "dbo/security-return-factor", "dbo/security-split-factor",
        "dbo/security-type", "ejv/ejvassetid-security-id-override",
        "ejv/issuer-equity-map", "ejv/security-type-map",
        "esg/entity-master", "esg/entity-ranged-score", "esg/green-revenue-data",
        "esg/index-aggregate-list", "esg/item", "esg/macro-country-map",
        "esg/mnemonic-list", "esg/ranged-controversy-case-score",
        "esg/ranged-paris-alignment-data", "esg/ranged-scenario-data",
        "esg/ranged-score", "esg/ranged-segment-data", "esg/sector",
        "esg/security-type-exclude", "factset/ownership-entity-master-map",
        "fixed-income/call-schedule", "fixed-income/call-schedule-type",
        "fixed-income/embedded-option-type", "fossil-free/esg-item-map",
        "ftse-russell/esg-item-map", "ftse-russell/grcs-microsector-map",
        "fundamental/country-lag", "fundamental/factset-segment",
        "fundamental/filing", "fundamental/filing-detail",
        "fundamental/filing-detail-footnote", "fundamental/filing-security-detail",
        "fundamental/filing-segment-detail", "fundamental/item",
        "fundamental/vendor-lag", "gmo/esg-item-map", "haver/geo-code-map",
        "haver/series-code-list", "hierarchy/entity-map", "hierarchy/entity-type",
        "hierarchy/hierarchy", "hierarchy/hierarchy-type",
        "ibes/adjustment-factor-override", "ibes/estimate-aggregation-map",
        "ibes/estimate-analyst-map", "ibes/estimate-broker-map",
        "ibes/estimate-country-map", "ibes/estimate-dilution-map",
        "ibes/estimate-gics-map", "ibes/estimate-index-map",
        "ibes/forecast-period-indicator-map", "ibes/fundamental-item-map",
        "index-data/constituent", "index-data/fi-returns-statistics-index-map",
        "index-data/index-master", "index-data/index-security-attribute",
        "index-data/market-item", "internal/credit-entity",
        "internal/credit-entity-market-data", "internal/credit-rating",
        "internal/days", "internal/estimate-detail", "internal/estimate-entity",
        "internal/estimate-summary", "internal/exchange-calendar",
        "internal/index-market-data", "internal/issuer-market-cap-data",
        "internal/macro-entity", "internal/macro-factors", "internal/macro-info",
        "internal/security-dividend", "internal/security-group-membership",
        "internal/security-index-map", "internal/security-market-data",
        "internal/security-split", "macro/primary-source", "macro/series",
        "macro/series-group", "marketaxess/transactions",
        "markit-parsing/security-type-map", "model/esg-component-data-cache",
        "model/esg-component-data-cache-country-code-override",
        "model/esg-indicator-component", "model/gmo-model-meta",
        "msci/ranged-security", "msci-esg/esg-item-map",
        "override/currency-revaluation", "override/dbo-issuer-info",
        "override/dbo-security-info", "override/estimate-summary",
        "override/exchange-calendar", "override/exchange-rate",
        "override/fundamental-factset-segment", "override/fundamental-filing",
        "override/fundamental-filing-detail", "override/index-data-constituent",
        "override/index-market", "override/internal-credit-rating",
        "override/override-master", "override/security-dividend",
        "override/security-group-membership", "override/security-hierarchy-membership",
        "override/security-index-map", "override/security-market",
        "override/security-split", "ownership/entity-master",
        "ownership/position", "portfolio/position", "priority/credit-market",
        "reference/barclays-to-bloomberg-class-map", "reference/country-currency-map",
        "sasb/activity-metric", "sasb/industry", "sasb/metric",
        "sasb/msci-esg-issue-map", "sasb/msci-esg-metric-map",
        "sasb/ranged-security-data", "sasb/sasb-key-security-id-override",
        "sasb/sector", "sasb/sub-activity-metric", "sasb/sub-metric",
        "sasb/topic", "sasb/un-sdg-map", "temporal/esg-ranged-score-history",
        "trucost/esg-item-map", "truvalue/esg-item-map",
    ]

    for path in app_gdm_paths:
        static_exclusions.append({"excludePath": f"/app-gdm/curated/{path}"})

    return static_exclusions


def build_payload(current_quarter):
    """
    Build the complete payload with static and dynamic history exclusions.

    Args:
        current_quarter (str): Current quarter in format 'YYYY_qQ'

    Returns:
        str: JSON-formatted payload
    """
    # Start with all container include paths
    content = [
        {"path": "/app-dae"},
        {"path": "/app-gdm"},
        {"path": "/app-hld"},
        {"path": "/app-ldg"},
        {"path": "/app-pdb"},
        {"path": "/app-ser"},
        {"path": "/demo"},
        {"path": "/lab"},
        {"path": "/laboratory"},
        {"path": "/raw"},
        {"path": "/samples-dae"},
        {"path": "/src-blackrock"},
        {"path": "/src-broadridge"},
        {"path": "/src-cvent"},
        {"path": "/src-mandatewire"},
        {"path": "/src-mmd"},
        {"path": "/src-on24"},
        {"path": "/src-pivotal-crm"},
        {"path": "/src-vdm"},
        {"path": "/synapse"},
        {"path": "/synfs-gmoperfsyslwr"},
    ]

    # Add static exclusions
    content.extend(load_static_exclusions())

    # Add dynamic history table exclusions (all quarters except current)
    content.extend(generate_history_exclusions(current_quarter))

    payload = {
        "subClientProperties": {
            "commonProperties": {
                "impersonateUserCredentialinfo": {"credentialId": 0}
            },
            "useLocalContent": True,
            "subClientEntity": {
                "subclientId": SUBCLIENT_ID,
                "subclientName": "default",
                "instanceId": INSTANCE_ID,
                "clientId": CLIENT_ID,
                "applicationId": APPLICATION_ID
            },
            "fsSubClientProp": {
                "includePolicyFilters": False,
                "useGlobalFilters": "OFF",
                "customSubclientContentFlags": 0,
                "customSubclientFlag": True,
                "openvmsBackupDate": False
            },
            "cloudAppsSubClientProp": {
                "instanceType": "AZURE_BLOB",
                "objectStorageSubclient": {"backupContentType": "CONTENT_BASED"}
            },
            "content": content,
            "fsContentOperationType": "OVERWRITE",
            "fsExcludeFilterOperationType": "OVERWRITE",
            "fsIncludeFilterOperationType": "CLEAR"
        }
    }

    return json.dumps(payload)


def send_update_request(url, headers, payload):
    """
    Send POST request to update Commvault subclient configuration.

    Args:
        url (str): API endpoint URL
        headers (dict): HTTP headers
        payload (str): JSON payload

    Returns:
        tuple: (success: bool, response_text: str)
    """
    try:
        response = requests.post(url, headers=headers, data=payload, verify=False)
        response.raise_for_status()
        return True, response.text
    except requests.exceptions.HTTPError as http_err:
        return False, f"[HTTP ERROR] {http_err}"
    except requests.exceptions.RequestException as req_err:
        return False, f"[REQUEST ERROR] {req_err}"
    except Exception as err:
        return False, f"[ERROR] {err}"


def main():
    """
    Main function to update Commvault history table exclusions.
    """
    print("=" * 70)
    print("Commvault History Table Exclusion Update")
    print("=" * 70)

    # Get current quarter
    current_quarter = get_current_quarter()
    print(f"\n[INFO] Current Quarter: {current_quarter}")
    print(f"[INFO] This quarter's history tables will be INCLUDED in backup")
    print(f"[INFO] All other quarter history tables will be EXCLUDED")

    # Get valid access token using Token Manager
    print("\n[INFO] Obtaining valid access token...")
    token_mgr = TokenManager()
    auth_token = token_mgr.get_valid_token()

    if not auth_token:
        print("\n[ERROR] Failed to obtain valid access token.")
        print("[ERROR] Please initialize tokens first:")
        print("[ERROR] python token_manager.py <access_token> <refresh_token>")
        return 1

    print("[SUCCESS] Valid access token obtained")

    # Build payload
    print("\n[INFO] Building payload with exclusions...")
    payload = build_payload(current_quarter)

    # Prepare headers
    headers = {
        "Authorization": auth_token,
        "Content-Type": "application/json"
    }

    # Send update request
    print(f"\n[INFO] Sending update request to Commvault...")
    print(f"[INFO] URL: {COMMVAULT_URL}")

    success, response = send_update_request(COMMVAULT_URL, headers, payload)

    if success:
        print("\n[SUCCESS] Subclient configuration updated successfully!")
        print(f"[SUCCESS] Current quarter '{current_quarter}' will be backed up")
        print(f"[SUCCESS] All other history quarters are excluded")
        return 0
    else:
        print(f"\n[FAILED] Failed to update subclient configuration")
        print(f"[FAILED] {response}")
        return 1


if __name__ == "__main__":
    exit(main())
