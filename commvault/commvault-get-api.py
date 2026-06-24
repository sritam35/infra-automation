import os
import sys
import urllib3
import requests
import xml.dom.minidom
from pathlib import Path

# Add current directory to path for token_manager import
sys.path.insert(0, str(Path(__file__).parent))
from token_manager import TokenManager

# Suppress InsecureRequestWarning
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

def send_get_request(url, headers):
    """
    Send a GET request to the specified URL with given headers.

    Args:
        url (str): API endpoint URL
        headers (dict): HTTP headers including authorization

    Returns:
        str: Response text if successful, None otherwise
    """
    try:
        response = requests.get(url, headers=headers, verify=False, timeout=30)
        response.raise_for_status()  # Raise an HTTPError for bad responses (4xx or 5xx)
        return response.text
    except requests.exceptions.HTTPError as http_err:
        print(f"[HTTP ERROR] {http_err}")
        if hasattr(http_err.response, 'text'):
            print(f"[HTTP ERROR] Response: {http_err.response.text}")
    except requests.exceptions.Timeout:
        print("[TIMEOUT ERROR] Request timed out after 30 seconds")
    except requests.exceptions.RequestException as req_err:
        print(f"[REQUEST ERROR] {req_err}")
    except Exception as err:
        print(f"[ERROR] Unexpected error: {err}")
    return None

def pretty_print_xml(xml_string):
    """Parse and pretty-print the given XML string."""
    try:
        # Parse the XML string into a DOM object
        dom = xml.dom.minidom.parseString(xml_string)
        # Generate a pretty-printed XML string with indentation
        pretty_xml = dom.toprettyxml(indent="    ")
        print(pretty_xml)
    except Exception as e:
        print(f"Error parsing XML: {e}")
        print("Original Response:")
        print(xml_string)

def main():
    """
    Main function to retrieve CloudStorage instance information from Commvault.
    """
    print("=" * 70)
    print("Commvault CloudStorage Instance Information")
    print("=" * 70)

    url = "https://commvault-server/commandcenter/api/Instance/CloudStorage"

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

    headers = {
        "Authorization": auth_token,
        "Content-Type": "application/json"
    }

    # Send the GET request and retrieve the response
    print(f"\n[INFO] Sending GET request to Commvault...")
    print(f"[INFO] URL: {url}")

    response_xml = send_get_request(url, headers)

    if response_xml:
        print("\n[SUCCESS] Response received successfully!")
        print("=" * 70)
        # Pretty-print the XML response
        pretty_print_xml(response_xml)
        return 0
    else:
        print("\n[FAILED] No valid response received.")
        return 1

if __name__ == "__main__":
    exit(main())
