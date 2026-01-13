#!/bin/bash
#
# Camera Stream Server Script
# Runs uStreamer to provide MJPEG stream
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

# Default stream settings
STREAM_PORT=${STREAM_PORT:-8080}
STREAM_WIDTH=${STREAM_WIDTH:-1280}
STREAM_HEIGHT=${STREAM_HEIGHT:-720}

echo "========================================"
echo "  Camera Stream Server"
echo "========================================"
echo ""
echo "Camera Type: $CAMERA_TYPE"
echo "Camera: $CAMERA_NAME"
echo "Stream Port: $STREAM_PORT"
echo "Resolution: ${STREAM_WIDTH}x${STREAM_HEIGHT}"
echo ""

# Determine streaming method based on camera type
case "$CAMERA_TYPE" in
    "RPI")
        echo "Starting RPi camera stream..."
        echo ""

        # For RPi cameras, we pipe rpicam-vid/libcamera-vid output to ustreamer
        # Using a FIFO for the stream
        FIFO_PATH="/tmp/camera_fifo"
        rm -f "$FIFO_PATH"
        mkfifo "$FIFO_PATH"

        # Determine which command to use
        if command -v rpicam-vid &> /dev/null; then
            VID_CMD="rpicam-vid"
        elif command -v libcamera-vid &> /dev/null; then
            VID_CMD="libcamera-vid"
        else
            echo "ERROR: No video capture tool found (rpicam-vid/libcamera-vid)"
            exit 1
        fi

        # Start video capture in background
        $VID_CMD --camera "$CAMERA_ID" \
            --width "$STREAM_WIDTH" \
            --height "$STREAM_HEIGHT" \
            --framerate 15 \
            --codec mjpeg \
            --quality 80 \
            --nopreview \
            -t 0 \
            -o "$FIFO_PATH" &
        VID_PID=$!

        # Give it a moment to start
        sleep 2

        # Start ustreamer reading from FIFO
        ustreamer \
            --device "$FIFO_PATH" \
            --host 0.0.0.0 \
            --port "$STREAM_PORT" \
            --format MJPEG \
            --workers 2 \
            --drop-same-frames 30 \
            --slowdown

        # Cleanup
        kill $VID_PID 2>/dev/null
        rm -f "$FIFO_PATH"
        ;;

    "USB")
        echo "Starting USB webcam stream..."
        echo ""

        # Check if ustreamer is available
        if ! command -v ustreamer &> /dev/null; then
            echo "ERROR: ustreamer not found. Please install it first."
            exit 1
        fi

        # USB cameras use V4L2 directly with ustreamer
        ustreamer \
            --device "$CAMERA_DEVICE" \
            --host 0.0.0.0 \
            --port "$STREAM_PORT" \
            --resolution "${STREAM_WIDTH}x${STREAM_HEIGHT}" \
            --format MJPEG \
            --workers 2 \
            --drop-same-frames 30
        ;;

    *)
        echo "ERROR: Unknown camera type: $CAMERA_TYPE"
        exit 1
        ;;
esac
