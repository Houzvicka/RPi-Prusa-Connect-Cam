#!/bin/bash
#
# Prusa Connect Camera Upload Script
# Captures snapshots and uploads them to Prusa Connect
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

# Temporary file for captured image
TEMP_FILE="/tmp/prusa_snapshot.jpg"

echo "========================================"
echo "  Prusa Connect Camera Upload Service"
echo "========================================"
echo ""
echo "Camera Type: $CAMERA_TYPE"
echo "Camera: $CAMERA_NAME"
echo "Upload Interval: ${DELAY_SECONDS}s"
echo "Fingerprint: $FINGERPRINT"
echo ""
echo "Starting upload loop..."
echo ""

while true; do
    # Remove previous capture
    rm -f "$TEMP_FILE" 2>/dev/null

    # Capture image based on camera type
    CAPTURE_SUCCESS=false

    case "$CAMERA_TYPE" in
        "RPI")
            # Use rpicam-still on newer OS, libcamera-still on older
            if command -v rpicam-still &> /dev/null; then
                rpicam-still --camera "$CAMERA_ID" \
                    --width "${CAPTURE_WIDTH:-1920}" \
                    --height "${CAPTURE_HEIGHT:-1080}" \
                    --quality 80 \
                    --immediate \
                    --nopreview \
                    -o "$TEMP_FILE" 2>/dev/null
            elif command -v libcamera-still &> /dev/null; then
                libcamera-still --camera "$CAMERA_ID" \
                    --width "${CAPTURE_WIDTH:-1920}" \
                    --height "${CAPTURE_HEIGHT:-1080}" \
                    --quality 80 \
                    --immediate \
                    --nopreview \
                    -o "$TEMP_FILE" 2>/dev/null
            else
                echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR: No camera capture tool found"
            fi
            ;;
        "USB")
            # Use fswebcam for USB cameras, fallback to ffmpeg
            if command -v fswebcam &> /dev/null; then
                fswebcam -d "$CAMERA_DEVICE" \
                    -r "${CAPTURE_WIDTH:-1280}x${CAPTURE_HEIGHT:-720}" \
                    --jpeg 80 \
                    --no-banner \
                    -S 3 \
                    "$TEMP_FILE" 2>/dev/null
            elif command -v ffmpeg &> /dev/null; then
                ffmpeg -y -f v4l2 \
                    -input_format mjpeg \
                    -video_size "${CAPTURE_WIDTH:-1280}x${CAPTURE_HEIGHT:-720}" \
                    -i "$CAMERA_DEVICE" \
                    -vframes 1 \
                    -q:v 2 \
                    "$TEMP_FILE" 2>/dev/null
            else
                echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR: No capture tool (fswebcam/ffmpeg) found"
            fi
            ;;
        *)
            echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR: Unknown camera type: $CAMERA_TYPE"
            ;;
    esac

    # Check if capture was successful
    if [[ -f "$TEMP_FILE" ]] && [[ -s "$TEMP_FILE" ]]; then
        CAPTURE_SUCCESS=true
    fi

    if [[ "$CAPTURE_SUCCESS" == true ]]; then
        # Upload to Prusa Connect
        HTTP_RESPONSE=$(curl -s -w "%{http_code}" -X PUT "$HTTP_URL" \
            -H "accept: */*" \
            -H "content-type: image/jpg" \
            -H "fingerprint: $FINGERPRINT" \
            -H "token: $TOKEN" \
            --data-binary "@$TEMP_FILE" \
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
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Capture failed, retrying in ${LONG_DELAY_SECONDS}s"
        DELAY=$LONG_DELAY_SECONDS
    fi

    sleep "$DELAY"
done
