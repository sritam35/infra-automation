"""
Commvault Token Manager
========================
Handles automatic access token renewal using refresh tokens.
Stores tokens persistently in a secure file.

Usage:
    from token_manager import TokenManager

    token_mgr = TokenManager()
    auth_token = token_mgr.get_valid_token()
"""

import os
import json
import requests
import urllib3
from datetime import datetime, timedelta
from pathlib import Path

# Suppress InsecureRequestWarning
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# Configuration
COMMVAULT_URL = "https://commvault-server"
TOKEN_RENEW_ENDPOINT = f"{COMMVAULT_URL}/commandcenter/api/v4/AccessToken/Renew"
TOKEN_FILE = "/mnt/automation/nfs/backupautomation/commvault/.commvault_tokens.json"


class TokenManager:
    """Manages Commvault access token lifecycle with automatic renewal."""

    def __init__(self, token_file=TOKEN_FILE):
        """
        Initialize the Token Manager.

        Args:
            token_file (str): Path to store token data
        """
        self.token_file = token_file
        self.token_data = self._load_tokens()

    def _load_tokens(self):
        """
        Load tokens from the persistent storage file.

        Returns:
            dict: Token data with access_token, refresh_token, expires_at
        """
        if os.path.exists(self.token_file):
            try:
                with open(self.token_file, 'r') as f:
                    return json.load(f)
            except (json.JSONDecodeError, IOError) as e:
                print(f"[WARNING] Failed to load tokens: {e}")
                return {}
        return {}

    def _save_tokens(self, access_token, refresh_token, expires_in=1800):
        """
        Save tokens to persistent storage with expiration timestamp.

        Args:
            access_token (str): New access token
            refresh_token (str): New refresh token
            expires_in (int): Token validity in seconds (default: 1800 = 30 min)
        """
        # Calculate expiration time (subtract 2 minutes as buffer)
        expires_at = (datetime.now() + timedelta(seconds=expires_in - 120)).isoformat()

        token_data = {
            "access_token": access_token,
            "refresh_token": refresh_token,
            "expires_at": expires_at,
            "last_updated": datetime.now().isoformat()
        }

        try:
            # Ensure directory exists
            os.makedirs(os.path.dirname(self.token_file), exist_ok=True)

            # Write token file with restricted permissions (600)
            with open(self.token_file, 'w') as f:
                json.dump(token_data, f, indent=2)

            # Set file permissions to read/write for owner only (NFS may block this)
            try:
                os.chmod(self.token_file, 0o600)
            except PermissionError:
                print(f"[WARNING] Could not set file permissions (NFS restriction). Using default permissions.")

            self.token_data = token_data
            print(f"[INFO] Tokens saved successfully to {self.token_file}")

        except IOError as e:
            print(f"[ERROR] Failed to save tokens: {e}")
            raise

    def _is_token_expired(self):
        """
        Check if the current access token is expired or about to expire.

        Returns:
            bool: True if token is expired or missing, False otherwise
        """
        if not self.token_data or 'expires_at' not in self.token_data:
            return True

        try:
            expires_at = datetime.fromisoformat(self.token_data['expires_at'])
            return datetime.now() >= expires_at
        except (ValueError, KeyError):
            return True

    def _renew_token(self):
        """
        Renew the access token using the refresh token.

        Returns:
            bool: True if renewal was successful, False otherwise
        """
        if not self.token_data or 'access_token' not in self.token_data:
            print("[ERROR] No existing token data found. Please initialize tokens first.")
            return False

        access_token = self.token_data.get('access_token')
        refresh_token = self.token_data.get('refresh_token')

        if not access_token or not refresh_token:
            print("[ERROR] Missing access_token or refresh_token.")
            return False

        print("[INFO] Renewing access token...")

        headers = {
            "Host": "commvault-server",
            "Accept": "application/json",
            "Authtoken": access_token,
            "Content-Type": "application/json"
        }

        payload = {
            "accessToken": access_token,
            "refreshToken": refresh_token
        }

        try:
            response = requests.post(
                TOKEN_RENEW_ENDPOINT,
                headers=headers,
                json=payload,
                verify=False,
                timeout=30
            )

            response.raise_for_status()
            response_data = response.json()

            # Extract new tokens from response
            # Response format: {"accessToken": "...", "refreshToken": "...", ...}
            new_access_token = response_data.get('accessToken')
            new_refresh_token = response_data.get('refreshToken')

            if new_access_token and new_refresh_token:
                self._save_tokens(new_access_token, new_refresh_token)
                print("[SUCCESS] Access token renewed successfully!")
                return True
            else:
                print(f"[ERROR] Invalid response format: {response_data}")
                return False

        except requests.exceptions.HTTPError as http_err:
            print(f"[HTTP ERROR] Token renewal failed: {http_err}")
            print(f"[HTTP ERROR] Response: {response.text}")
            return False
        except requests.exceptions.RequestException as req_err:
            print(f"[REQUEST ERROR] Token renewal failed: {req_err}")
            return False
        except Exception as err:
            print(f"[ERROR] Unexpected error during token renewal: {err}")
            return False

    def initialize_tokens(self, access_token, refresh_token):
        """
        Initialize the token manager with first-time tokens.
        Use this when you manually generate tokens from Commvault UI.

        Args:
            access_token (str): Initial access token
            refresh_token (str): Initial refresh token
        """
        print("[INFO] Initializing tokens...")
        self._save_tokens(access_token, refresh_token)
        print("[SUCCESS] Tokens initialized successfully!")

    def get_valid_token(self):
        """
        Get a valid access token, renewing if necessary.

        Returns:
            str: Valid access token in format 'Bearer <token>'
            None: If token retrieval/renewal failed
        """
        # Check if token exists
        if not self.token_data or 'access_token' not in self.token_data:
            print("[ERROR] No tokens found. Please initialize tokens first.")
            print("[ERROR] Use: token_mgr.initialize_tokens(access_token, refresh_token)")
            return None

        # Check if token is expired
        if self._is_token_expired():
            print("[INFO] Token expired or about to expire. Renewing...")
            if not self._renew_token():
                print("[ERROR] Failed to renew token. Please generate new tokens manually.")
                return None

        # Return valid token with Bearer prefix
        return f"Bearer {self.token_data['access_token']}"

    def get_token_info(self):
        """
        Get information about current token status.

        Returns:
            dict: Token status information
        """
        if not self.token_data:
            return {"status": "No tokens found"}

        try:
            expires_at = datetime.fromisoformat(self.token_data['expires_at'])
            time_remaining = expires_at - datetime.now()

            return {
                "status": "expired" if self._is_token_expired() else "valid",
                "expires_at": self.token_data['expires_at'],
                "time_remaining": str(time_remaining) if time_remaining.total_seconds() > 0 else "expired",
                "last_updated": self.token_data.get('last_updated', 'unknown')
            }
        except (ValueError, KeyError) as e:
            return {"status": "error", "message": str(e)}


def main():
    """
    Main function for testing and manual token initialization.
    """
    import sys

    token_mgr = TokenManager()

    # Check if initializing new tokens
    if len(sys.argv) == 3:
        access_token = sys.argv[1]
        refresh_token = sys.argv[2]
        token_mgr.initialize_tokens(access_token, refresh_token)
        print("\n[SUCCESS] Tokens initialized!")
        print("[INFO] You can now use get_valid_token() in your scripts")
        return

    # Display token info
    print("=" * 70)
    print("Commvault Token Status")
    print("=" * 70)

    info = token_mgr.get_token_info()
    for key, value in info.items():
        print(f"{key}: {value}")

    print("\n" + "=" * 70)
    print("Testing Token Retrieval")
    print("=" * 70)

    token = token_mgr.get_valid_token()
    if token:
        print(f"[SUCCESS] Valid token obtained: {token[:30]}...")
    else:
        print("[FAILED] Could not obtain valid token")
        print("\nTo initialize tokens, run:")
        print("python token_manager.py <access_token> <refresh_token>")


if __name__ == "__main__":
    main()
