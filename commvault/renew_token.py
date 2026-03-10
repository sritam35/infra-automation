"""
Token Renewal Script
====================
Lightweight script to renew access tokens every 7 days.
This keeps the refresh token valid by renewing within the 14-day window.

Schedule: Run every 7 days (bi-weekly)
Purpose: Keep tokens fresh for monthly backup exclusion script

Usage:
    python renew_token.py
"""

import sys
from pathlib import Path

# Add current directory to path
sys.path.insert(0, str(Path(__file__).parent))
from token_manager import TokenManager


def main():
    """
    Renew access token to keep refresh token valid.
    """
    print("=" * 70)
    print("Commvault Token Renewal")
    print("=" * 70)

    token_mgr = TokenManager()

    # Check if tokens exist
    if not token_mgr.token_data or 'access_token' not in token_mgr.token_data:
        print("\n[ERROR] No tokens found!")
        print("[ERROR] Please initialize tokens first:")
        print("[ERROR] python token_manager.py <access_token> <refresh_token>")
        return 1

    print("\n[INFO] Attempting token renewal...")

    # Force get token (which will renew if expired)
    token = token_mgr.get_valid_token()

    if token:
        print("[SUCCESS] Token renewed successfully!")
        print(f"[SUCCESS] Token preview: {token[:50]}...")

        # Show token info
        info = token_mgr.get_token_info()
        print(f"\n[INFO] Token Status: {info.get('status', 'unknown')}")
        print(f"[INFO] Time Remaining: {info.get('time_remaining', 'unknown')}")

        return 0
    else:
        print("\n[ERROR] Token renewal failed!")
        print("[ERROR] Please generate new tokens from Commvault UI")
        return 1


if __name__ == "__main__":
    exit(main())
