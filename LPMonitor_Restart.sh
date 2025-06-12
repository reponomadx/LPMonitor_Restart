#!/bin/bash

# ------------------------------------------------------------------------------
# LPMonitor_Restart.sh
# ------------------------------------------------------------------------------
#
# DESCRIPTION:
#   Monitors the health of Imprivata GroundControl Launchpads in a production
#   environment. This script evaluates each Launchpad's connection status,
#   Smart Hub presence (badge reader), and the number of connected devices.
#
#   If a Launchpad is disconnected, missing a Smart Hub, or has no devices for
#   a sustained period, the script triggers a Workspace ONE soft reset via API.
#   Actions are tracked with cooldown logic and alert flags to prevent repeats.
#
#   Designed for continuous use via a macOS LaunchAgent every 60 seconds.
#
# FEATURES:
#   - Queries GroundControl API for Launchpad status
#   - Identifies unhealthy pads based on specific conditions
#   - Issues WS1 soft resets using OAuth authentication
#   - Logs all actions and results, supports alert sound
#   - Avoids repeat resets with per-pad cooldown counters
#
# DEPENDENCIES:
#   - bash
#   - jq
#   - curl
#   - Internet connection
#
# SETUP:
#   - Replace placeholder values in API_URL, TARGET_EMAIL, and WS1 credentials
#   - Store serial lookup CSV in BASE_DIR path
#   - Configure as LaunchAgent with plist to run every minute
#
# AUTHOR:
#   Licensed under MIT. For vendor or internal IT use.
# ------------------------------------------------------------------------------
DEBUG=false

# --------------------------------
# CONFIGURATION
# --------------------------------
BASE_DIR="/scripts/LPMonitor_Restart"
API_URL="https://www.groundctl.com/api/v1/launchpads/find/all?api_key=IMPRIVATA_MAM_API_KEY"
ALERT_SOUND="/System/Library/Sounds/Funk.aiff"
TARGET_EMAIL="SERVICE_ACCT_EMAIL"
OUTPUT_FILE="$BASE_DIR/Prod_LPs.txt"
STATUS_FILE="$BASE_DIR/status.txt"
CSV_FILE="$BASE_DIR/launchpads.csv"

WS1_ENV_URL="https://as1234.awmdm.com"
TOKEN_URL="https://na.uemauth.workspaceone.com/connect/token"
CLIENT_ID="OMNISSA_CLIENT_ID"
CLIENT_SECRET="OMNISSA_CLIENT_Secret"
TOKEN_CACHE_FILE="$BASE_DIR/ws1_token_cache.json"
TOKEN_LIFETIME_SECONDS=3600

# --------------------------------
# OMNISSA OAUTH
# --------------------------------
get_ws1_token() {
    local now=$(date +%s)
    if [ -f "$TOKEN_CACHE_FILE" ]; then
        local token_age=$((now - $(stat -f %m "$TOKEN_CACHE_FILE")))
        if [ $token_age -lt $TOKEN_LIFETIME_SECONDS ]; then
            ACCESS_TOKEN=$(jq -r '.access_token' "$TOKEN_CACHE_FILE")
            return
        fi
    fi
    echo "Requesting new Workspace ONE access token..."
    TOKEN_RESPONSE=$(curl -s -X POST "$TOKEN_URL" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=client_credentials&client_id=$CLIENT_ID&client_secret=$CLIENT_SECRET")
    echo "$TOKEN_RESPONSE" > "$TOKEN_CACHE_FILE"
    ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token')
}

# --------------------------------
# MAIN SCRIPT
# --------------------------------
rm -f "$STATUS_FILE"

if [ -z "$BASH_VERSION" ]; then
    echo "❌ This script must be run with bash. Use 'bash $0' instead."
    exit 1
fi

SERIAL_LOOKUP_FILE="$BASE_DIR/serial_lookup.tmp"
rm -f "$SERIAL_LOOKUP_FILE"
while IFS=, read -r name serial; do
    clean_key=$(echo "$name" | tr -d '\r' | xargs)
    clean_val=$(echo "$serial" | tr -d '\r' | xargs)
    echo "$clean_key|$clean_val" >> "$SERIAL_LOOKUP_FILE"
done < "$CSV_FILE"

echo "🌐 Checking internet connectivity..."
if ! ping -c 1 -W 1 google.com >/dev/null 2>&1; then
    echo "❌ No internet connection detected. Aborting script." > "$STATUS_FILE"
    exit 1
fi
echo "✅ Internet connection OK. Continuing..."

if ! command -v jq >/dev/null 2>&1; then
    echo "❌ Error: 'jq' is not installed." > "$STATUS_FILE"
    exit 1
fi

echo "📱 Fetching launchpads from Imprivata MAM..."
response=$(curl -s -f -X GET "$API_URL" -H "accept: application/json")
if [ $? -ne 0 ]; then
    echo "❌ Error: Failed to fetch data from API." > "$STATUS_FILE"
    exit 1
fi

count=$(echo "$response" | jq --arg email "$TARGET_EMAIL" 'map(select(. | tostring | contains($email))) | length')
echo "💻 $count production Launchpads found."
ALERT_CACHE_DIR="$BASE_DIR/.alerts"
ALERT_COUNT_DIR="$BASE_DIR/.alert_counts"
mkdir -p "$ALERT_CACHE_DIR" "$ALERT_COUNT_DIR"

alerts=""
IFS=$'\n'
launchpads=$(echo "$response" | jq -r --arg email "$TARGET_EMAIL" 'map(select(. | tostring | contains($email))) | map("\(.name)|\(.connected)|\(.connectedDeviceCount)|\(.connectedBadgeReader)") | .[]')

serials_to_restart=()

for entry in $launchpads; do
    IFS="|" read -r name connected connectedDeviceCount connectedBadgeReader <<< "$entry"

    if [ "$DEBUG" = true ]; then
        echo "DEBUG: Name=$name | Connected=$connected | DeviceCount=$connectedDeviceCount | BadgeReader=$connectedBadgeReader"
    fi

    key_base="$ALERT_COUNT_DIR/$(echo "$name" | tr ' /' '_')"

    # 🔌 NO SMARTHUB (fully disconnected)
    if [ "$connected" != "true" ]; then
        smarthub_count_file="$key_base.noshub"
        smarthub_flag_file="$smarthub_count_file.rebooted"
        count=$( [ -f "$smarthub_count_file" ] && cat "$smarthub_count_file" || echo 0 )
        count=$((count + 1))
        echo "$count" > "$smarthub_count_file"

        if [ "$count" -gt 1 ] && [ ! -f "$smarthub_flag_file" ]; then
            serial_number=$(grep -F "$name|" "$SERIAL_LOOKUP_FILE" | cut -d'|' -f2)
            if [ -n "$serial_number" ]; then
                echo "📅 Queued serial (No SmartHub): $serial_number"
                serials_to_restart+=("\"$serial_number\"")
                echo "🔁 Reboot (No SmartHub) for $name (Serial: $serial_number) at $(date)" >> "$BASE_DIR/reboot_log.txt"
                touch "$smarthub_flag_file"
            fi
        fi
        alerts+="\n🚨 $name is disconnected (count: $count)"
    else
        rm -f "$key_base.noshub" "$key_base.noshub.rebooted"
    fi

    # 📱 NO DEVICES (even when connected)
    if [ "$connected" = "true" ] && [ "$connectedDeviceCount" -lt 1 ]; then
        device_count_file="$key_base.nodevice"
        device_flag_file="$device_count_file.rebooted"
        no_device_count=$( [ -f "$device_count_file" ] && cat "$device_count_file" || echo 0 )
        no_device_count=$((no_device_count + 1))
        echo "$no_device_count" > "$device_count_file"

        if [ "$no_device_count" -gt 1 ] && [ ! -f "$device_flag_file" ]; then
            serial_number=$(grep -F "$name|" "$SERIAL_LOOKUP_FILE" | cut -d'|' -f2)
            if [ -n "$serial_number" ]; then
                echo "📅 Queued serial (No devices): $serial_number"
                serials_to_restart+=("\"$serial_number\"")
                echo "🔁 Reboot (No devices) for $name (Serial: $serial_number) at $(date)" >> "$BASE_DIR/reboot_log.txt"
                touch "$device_flag_file"
            fi
        fi
        alerts+="\n🚨 $name has no devices connected (count: $no_device_count)"
    else
        rm -f "$key_base.nodevice" "$key_base.nodevice.rebooted"
    fi

done

if [ ${#serials_to_restart[@]} -gt 0 ]; then
    echo "🚀 Sending batch restart to ${#serials_to_restart[@]} device(s)..."
    get_ws1_token
    serial_json=$(IFS=,; echo "${serials_to_restart[*]}")
    restart_response=$(curl -s -X POST "${WS1_ENV_URL}/api/mdm/devices/commands/bulk?command=Softreset&searchby=Serialnumber" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -d "{ \"BulkValues\": { \"Value\": [ $serial_json ] } }")

    total=$(echo "$restart_response" | jq -r '.TotalItems // empty')
    accepted=$(echo "$restart_response" | jq -r '.AcceptedItems // empty')
    failed=$(echo "$restart_response" | jq -r '.FailedItems // empty')
    echo "📬 Batch Restart response:"
    echo "  🔸 TotalItems:   ${total:-n/a}"
    echo "  ✅ AcceptedItems: ${accepted:-n/a}"
    echo "  ❌ FailedItems:   ${failed:-n/a}"
fi

if [ -n "$alerts" ]; then
    echo "🚨 ALERT triggered!"
    echo "2" > "$STATUS_FILE"
    afplay "$ALERT_SOUND"
else
    echo "👍🏻 All systems seem healthy."
    echo "1" > "$STATUS_FILE"
fi

TIMESTAMP=$(date "+%Y-%m-%d_%H-%M-%S")
LOG_FILE="$BASE_DIR/logs/monitor_log_$TIMESTAMP.txt"
mkdir -p "$BASE_DIR/logs"

{
    echo "🕒 Run Timestamp: $TIMESTAMP"
    echo "---------------------------"
    if [ -n "$alerts" ]; then
        echo "🚨 ALERTS:"
        echo -e "$alerts"
    else
        echo "✅ All systems healthy."
    fi
} > "$LOG_FILE"
echo "🗒️ Log written to $LOG_FILE"
