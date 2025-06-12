#!/bin/bash

# ------------------------------------------------------------------------------
# Update LP List.sh
# ------------------------------------------------------------------------------
#
# DESCRIPTION:
#   Retrieves all devices from Workspace ONE UEM and saves their friendly names
#   and serial numbers into a local CSV file (launchpads.csv).
#
#   Designed to assist with maintaining a current serial number mapping for
#   GroundControl Launchpad monitoring scripts. OAuth is used for authentication,
#   and token caching is built-in.
#
#   The script includes a sanity check: if the new device count drops by 5 or
#   more compared to the previous list, the update is aborted to avoid overwriting
#   due to API errors or network issues.
#
# FEATURES:
#   - Queries Workspace ONE for all managed devices under a given Org Group
#   - Exports DeviceFriendlyName and SerialNumber to CSV
#   - Token caching and re-use to minimize API calls
#   - Alerts if device count unexpectedly drops
#
# DEPENDENCIES:
#   - bash
#   - jq
#   - curl
#   - Internet connection
#
# SETUP:
#   - Update WS1 credentials and Org Group ID in configuration section
#   - Ensure the script path has write access to launchpads.csv
#
# AUTHOR:
#   Licensed under MIT. For vendor or internal IT use.
# ------------------------------------------------------------------------------
BASE_DIR="/scripts/LPMonitor_Restart"  # Base directory for script and output
CSV_FILE="$BASE_DIR/launchpads.csv"        # Output CSV file
TOKEN_URL="https://na.uemauth.workspaceone.com/connect/token"  # OAuth token endpoint
CLIENT_ID="OMNISSA_CLIENT_ID"                 # Workspace ONE API client ID (placeholder)
CLIENT_SECRET="OMNISSA_CLIENT_SECRET"         # Workspace ONE API client secret (placeholder)
WS1_ENV_URL="https://as1234.awmdm.com"     # Workspace ONE API base URL
ORG_GROUP_ID="12345"                       # Organization Group ID for Workspace ONE
TOKEN_CACHE_FILE="$BASE_DIR/ws1_token_cache.json"  # Token cache file path
TOKEN_LIFETIME_SECONDS=3600                # Lifetime of cached token in seconds

# --------------------------------
# FUNCTIONS
# --------------------------------
# Set DEBUG=true to enable debug output
DEBUG=false

# Function: get_ws1_token
# Retrieves a Workspace ONE access token, using a cached token if still valid.
get_ws1_token() {
    now=$(date +%s)
    if [ -f "$TOKEN_CACHE_FILE" ]; then
        token_age=$((now - $(stat -f %m "$TOKEN_CACHE_FILE")))
        if [ $token_age -lt $TOKEN_LIFETIME_SECONDS ]; then
            ACCESS_TOKEN=$(jq -r '.access_token' "$TOKEN_CACHE_FILE")
            return
        fi
    fi
    $DEBUG && echo "Requesting new Workspace ONE access token..."
    TOKEN_RESPONSE=$(curl -s -X POST "$TOKEN_URL" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=client_credentials&client_id=$CLIENT_ID&client_secret=$CLIENT_SECRET")
    echo "$TOKEN_RESPONSE" > "$TOKEN_CACHE_FILE"
    ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token')
}

# --------------------------------
# MAIN SCRIPT
# --------------------------------

# Inform about update process
$DEBUG && echo "🔄 Updating $CSV_FILE..."

# Count entries from previous CSV, excluding the header
old_count=0
if [ -f "$CSV_FILE" ]; then
    old_count=$(tail -n +2 "$CSV_FILE" | wc -l)
fi

# Request an OAuth token
get_ws1_token

# Query Workspace ONE API for device data
response=$(curl -s -X GET "${WS1_ENV_URL}/api/mdm/devices/extensivesearch?organizationgroupid=${ORG_GROUP_ID}" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Accept: application/json")

# Validate API response
if [ $? -ne 0 ]; then
    echo "❌ Error: Failed to fetch device data from Workspace ONE."
    exit 1
fi

# Count new records to detect large unexpected changes
new_count=$(echo "$response" | jq -r '.Devices[] | "\(.DeviceFriendlyName),\(.SerialNumber)"' | sort | uniq | wc -l)
if [ $((old_count - new_count)) -ge 5 ]; then
    echo "❌ Abort: New device count ($new_count) is 5 or more less than the previous count ($old_count)."
    exit 1
fi

# Overwrite CSV with updated values (add header first)
echo "DeviceFriendlyName,SerialNumber" > "$CSV_FILE"
echo "$response" | jq -r '.Devices[] | "\(.DeviceFriendlyName),\(.SerialNumber)"' | sort | uniq >> "$CSV_FILE"

# Debug output for record change
$DEBUG && echo "📈 Launchpad count changed: $old_count → $new_count"

# Final success message
echo "✅ CSV updated: $CSV_FILE"
