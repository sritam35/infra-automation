"""
Token Health Check Script
==========================
Proactive check to ensure tokens are healthy before monthly backup.
Run this before the exclusion update script to verify token status.

Usage:
    python check_token_health.py

This will:
1. Check if tokens exist
2. Check token age
3. Proactively renew if needed
4. Report token status
"""

import sys
from pathlib import Path
from datetime import datetime

# Add current directory to path
sys.path.insert(0, str(Path(__file__).parent))
from token_manager import TokenManager


def check_token_age(token_mgr):
    """
    Check how old the tokens are.

    Args:
        token_mgr (TokenManager): Token manager instance

    Returns:
        tuple: (days_old, status_message)
    """
    if not token_mgr.token_data or 'last_updated' not in token_mgr.token_data:
        return None, "No token data found"

    try:
        last_updated = datetime.fromisoformat(token_mgr.token_data['last_updated'])
        age = datetime.now() - last_updated
        days_old = age.days

        if days_old > 14:
            status = "⚠️  WARNING: Tokens are too old (>14 days)"
        elif days_old > 10:
            status = "⚠️  CAUTION: Tokens approaching 14-day limit"
        elif days_old > 7:
            status = "✅ GOOD: Tokens are fresh (renewed recently)"
        else:
            status = "✅ EXCELLENT: Tokens are very fresh"

        return days_old, status

    except (ValueError, TypeError) as e:
        return None, f"Error parsing token age: {e}"


def main():
    """Main token health check."""
    print("=" * 70)
    print("Commvault Token Health Check")
    print("=" * 70)

    token_mgr = TokenManager()

    # Check 1: Token existence
    print("\n[CHECK 1] Token File Existence")
    print("-" * 70)
    if token_mgr.token_data and 'access_token' in token_mgr.token_data:
        print("✅ Token file exists and is readable")
    else:
        print("❌ No tokens found!")
        print("\n[ACTION REQUIRED] Initialize tokens first:")
        print("   python token_manager.py <access_token> <refresh_token>")
        return 1

    # Check 2: Token age
    print("\n[CHECK 2] Token Age")
    print("-" * 70)
    days_old, status = check_token_age(token_mgr)
    if days_old is not None:
        print(f"Token Age: {days_old} days")
        print(f"Status: {status}")

        if days_old > 14:
            print("\n❌ CRITICAL: Tokens expired! Must generate new tokens from UI")
            print("\n[ACTION REQUIRED]:")
            print("   1. Go to Commvault UI: https://commvault-server")
            print("   2. Manage → Security → API Tokens → Create Token")
            print("   3. Run: python token_manager.py <new_access> <new_refresh>")
            return 1
    else:
        print(f"⚠️  {status}")

    # Check 3: Token expiration
    print("\n[CHECK 3] Token Expiration Status")
    print("-" * 70)
    info = token_mgr.get_token_info()
    print(f"Status: {info.get('status', 'unknown')}")
    print(f"Expires At: {info.get('expires_at', 'unknown')}")
    print(f"Time Remaining: {info.get('time_remaining', 'unknown')}")

    if info.get('status') == 'expired':
        print("\n[INFO] Token expired, attempting renewal...")

    # Check 4: Token retrieval (with auto-renewal)
    print("\n[CHECK 4] Token Retrieval Test")
    print("-" * 70)
    token = token_mgr.get_valid_token()

    if token:
        print("✅ Valid token obtained successfully!")
        print(f"Token Preview: {token[:50]}...")

        # Re-check age after potential renewal
        print("\n[CHECK 5] Post-Renewal Status")
        print("-" * 70)
        days_old, status = check_token_age(token_mgr)
        if days_old is not None:
            print(f"Token Age: {days_old} days")
            print(f"Status: {status}")
    else:
        print("❌ Failed to obtain valid token!")
        print("\n[ACTION REQUIRED] Generate new tokens from Commvault UI")
        return 1

    # Final summary
    print("\n" + "=" * 70)
    print("HEALTH CHECK SUMMARY")
    print("=" * 70)

    if days_old is not None and days_old <= 14:
        print("✅ ALL CHECKS PASSED!")
        print("\n[STATUS] Tokens are healthy and ready for monthly backup")
        print("[INFO] You can safely run: python dynamic_datalakebkp_exclusions.py")

        # Calculate next renewal
        if days_old is not None:
            days_until_expiry = 14 - days_old
            print(f"\n[INFO] Tokens will be valid for approximately {days_until_expiry} more days")
            print(f"[INFO] Next monthly script run will auto-renew if needed")

        return 0
    else:
        print("❌ HEALTH CHECK FAILED!")
        print("\n[ACTION REQUIRED] Fix token issues before running backup script")
        return 1


if __name__ == "__main__":
    try:
        exit(main())
    except KeyboardInterrupt:
        print("\n\n[INFO] Health check interrupted by user.")
        exit(1)
    except Exception as e:
        print(f"\n[ERROR] Unexpected error: {e}")
        exit(1)
