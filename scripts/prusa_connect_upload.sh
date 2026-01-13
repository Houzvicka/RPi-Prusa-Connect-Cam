#!/bin/bash
#
# Prusa Connect Camera Upload Script
# Uploads snapshots from the stream server to Prusa Connect
#

CONFIG_FILE="/etc/prusa_cam.conf"

# Check if config exists
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Configuration file not found: $CONFIG_FILE"
    echo "Please run the installer first."
    exit 1
fi

# Load configuration
source "$CONFIG_FILE"

# API endpoint
HTTP_URL="https://connect.prusa3d.com/c/snapshot"

# Delay settings
DELAY_SECONDS=${UPLOAD_INTERVAL:-10}
LONG_DELAY_SECONDS=60

# Snapshot file (created by stream server)
SNAPSHOT_FILE="/tmp/stream_snapshot.jpg"

echo "========================================"
echo "  Prusa Connect Camera Upload Service"
echo "========================================"
echo ""
echo "Camera Type: $CAMERA_TYPE"
echo "Camera: $CAMERA_NAME"
echo "Upload Interval: ${DELAY_SECONDS}s"
echo "Fingerprint: $FINGERPRINT"
echo ""
echo "Waiting for stream server to start..."

# Wait for stream server to create snapshot file
WAIT_COUNT=0
while [[ ! -f "$SNAPSHOT_FILE" ]] && [[ $WAIT_COUNT -lt 30 ]]; do
    sleep 2
    ((WAIT_COUNT++))
done

if [[ ! -f "$SNAPSHOT_FILE" ]]; then
    echo "WARNING: Snapshot file not found after 60s, will keep trying..."
fi

echo "Starting upload loop..."
echo ""

while true; do
    # Check if snapshot file exists and is recent (less than 30 seconds old)
    if [[ -f "$SNAPSHOT_FILE" ]]; then
        FILE_AGE=$(($(date +%s) - $(stat -c %Y "$SNAPSHOT_FILE" 2>/dev/null || echo 0)))

        if [[ $FILE_AGE -lt 30 ]]; then
            # Upload to Prusa Connect
            HTTP_RESPONSE=$(curl -s -w "%{http_code}" -X PUT "$HTTP_URL" \
                -H "accept: */*" \
                -H "content-type: image/jpg" \
                -H "fingerprint: $FINGERPRINT" \
                -H "token: $TOKEN" \
                --data-binary "@$SNAPSHOT_FILE" \
                --no-progress-meter \
                --compressed \
                -o /dev/null \
                --max-time 30)

            case "$HTTP_RESPONSE" in
                200|204)
                    echo "$(date '+%Y-%m-%d %H:%M:%S') - Upload successful"
                    DELAY=$DELAY_SECONDS
                    ;;
                401)
                    echo "$(date '+%Y-%m-%d %H:%M:%S') - Upload failed: Invalid token (HTTP 401)"
                    DELAY=$LONG_DELAY_SECONDS
                    ;;
                403)
                    echo "$(date '+%Y-%m-%d %H:%M:%S') - Upload failed: Access denied (HTTP 403)"
                    DELAY=$LONG_DELAY_SECONDS
                    ;;
                *)
                    echo "$(date '+%Y-%m-%d %H:%M:%S') - Upload failed (HTTP $HTTP_RESPONSE)"
                    DELAY=$LONG_DELAY_SECONDS
                    ;;
            esac
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Snapshot too old (${FILE_AGE}s), waiting for fresh frame..."
            DELAY=5
        fi
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Waiting for snapshot from stream server..."
        DELAY=5
    fi

    sleep "$DELAY"
done
