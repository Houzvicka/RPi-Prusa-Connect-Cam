#!/bin/bash
#
# Camera Stream Server Script
# Lightweight Python-based MJPEG streaming server
# - Streams live video on port 8080
# - Saves snapshots to /tmp/stream_snapshot.jpg for Prusa Connect uploads
# - All temp files in RAM (tmpfs) to protect SD card
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

V4L2_CONTROLS_CACHE=""
V4L2_CONTROLS_LOADED=false

load_v4l2_controls() {
    if [[ "$V4L2_CONTROLS_LOADED" == "true" ]]; then
        [[ -n "$V4L2_CONTROLS_CACHE" ]]
        return
    fi

    V4L2_CONTROLS_LOADED=true

    if [[ -z "${CAMERA_DEVICE:-}" ]]; then
        echo "WARNING: CAMERA_DEVICE is not configured; skipping camera capability detection"
        return 1
    fi

    if ! command -v v4l2-ctl &> /dev/null; then
        echo "WARNING: v4l2-ctl not found; skipping camera capability detection"
        return 1
    fi

    V4L2_CONTROLS_CACHE=$(v4l2-ctl -d "$CAMERA_DEVICE" --list-ctrls 2>/dev/null || true)
}

has_v4l2_control() {
    local control_name="$1"

    load_v4l2_controls || return 1
    [[ "$V4L2_CONTROLS_CACHE" =~ (^|[[:space:]])${control_name}[[:space:]] ]]
}

log_capability() {
    local label="$1"
    local control_name="$2"
    local available="no"

    if has_v4l2_control "$control_name"; then
        available="yes"
    fi

    printf '  %-22s %s\n' "$label" "$available"
}

apply_v4l2_setting() {
    local control_name="$1"
    local value="$2"

    if ! has_v4l2_control "$control_name"; then
        echo "WARNING: Camera control '$control_name' is not supported; skipping"
        return 0
    fi

    if v4l2-ctl -d "$CAMERA_DEVICE" --set-ctrl "${control_name}=${value}" &> /dev/null; then
        echo "Applied camera control '${control_name}=${value}'"
    else
        echo "WARNING: Failed to apply camera control '${control_name}=${value}'; continuing"
    fi
}

configure_focus() {
    if [[ "${AUTOFOCUS_ENABLED:-}" =~ ^([Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]|1|on)$ ]]; then
        apply_v4l2_setting "focus_auto" "1"
    elif [[ "${AUTOFOCUS_ENABLED:-}" =~ ^([Ff][Aa][Ll][Ss][Ee]|[Nn][Oo]|0|off)$ ]]; then
        apply_v4l2_setting "focus_auto" "0"

        if [[ -n "${FOCUS_ABSOLUTE:-}" ]]; then
            apply_v4l2_setting "focus_absolute" "$FOCUS_ABSOLUTE"
        fi
    elif [[ -n "${FOCUS_ABSOLUTE:-}" ]]; then
        apply_v4l2_setting "focus_absolute" "$FOCUS_ABSOLUTE"
    fi

    echo "✓ Focus configured"
}

configure_exposure() {
    if has_v4l2_control "exposure_auto" || has_v4l2_control "exposure_absolute"; then
        echo "Exposure controls available; no exposure configuration requested"
    else
        echo "Exposure controls unavailable; skipping"
    fi

    echo "✓ Exposure skipped"
}

configure_image_controls() {
    local controls=(brightness contrast gain saturation white_balance_temperature sharpness)
    local control_name
    local available_controls=()

    for control_name in "${controls[@]}"; do
        if has_v4l2_control "$control_name"; then
            available_controls+=("$control_name")
        fi
    done

    if (( ${#available_controls[@]} > 0 )); then
        echo "Image controls available: ${available_controls[*]}"
    else
        echo "No supported image controls detected"
    fi

    echo "✓ Image controls skipped"
}

configure_camera() {
    echo "Camera capabilities"
    echo "-------------------"
    log_capability "Autofocus" "focus_auto"
    log_capability "Manual focus" "focus_absolute"
    log_capability "Exposure auto" "exposure_auto"
    log_capability "Exposure absolute" "exposure_absolute"
    log_capability "Brightness" "brightness"
    log_capability "Contrast" "contrast"
    log_capability "Gain" "gain"
    log_capability "Saturation" "saturation"
    log_capability "White balance" "white_balance_temperature"
    log_capability "Sharpness" "sharpness"
    echo ""
    echo "Applying camera configuration..."
    configure_focus
    configure_exposure
    configure_image_controls
    echo ""
}

case "$CAMERA_TYPE" in
    "RPI")
        echo "Starting RPi camera stream..."

        # Determine which command to use
        if command -v rpicam-vid &> /dev/null; then
            VID_CMD="rpicam-vid"
        elif command -v libcamera-vid &> /dev/null; then
            VID_CMD="libcamera-vid"
        else
            echo "ERROR: No video capture tool found (rpicam-vid/libcamera-vid)"
            exit 1
        fi

        # Use rpicam-vid with inline MJPEG and pipe to Python HTTP server
        $VID_CMD --camera "$CAMERA_ID" \
            --width "$STREAM_WIDTH" \
            --height "$STREAM_HEIGHT" \
            --framerate 15 \
            --codec mjpeg \
            --quality 80 \
            --nopreview \
            -t 0 \
            --inline \
            -o - 2>/dev/null | python3 -c "
import sys
import socket
import threading
import time
import os

HOST = '0.0.0.0'
PORT = $STREAM_PORT
SNAPSHOT_FILE = '/tmp/stream_snapshot.jpg'
SNAPSHOT_INTERVAL = 2  # Save snapshot every 2 seconds

BOUNDARY = b'--FRAME'
HEADERS = (
    b'HTTP/1.1 200 OK\r\n'
    b'Content-Type: multipart/x-mixed-replace; boundary=FRAME\r\n'
    b'Cache-Control: no-cache\r\n'
    b'Connection: close\r\n'
    b'\r\n'
)

clients = []
clients_lock = threading.Lock()
current_frame = None
frame_lock = threading.Lock()

def handle_client(conn, addr):
    try:
        conn.recv(4096)
        conn.sendall(HEADERS)

        with clients_lock:
            clients.append(conn)

        while True:
            try:
                conn.setblocking(False)
                try:
                    data = conn.recv(1, socket.MSG_PEEK)
                    if not data:
                        break
                except BlockingIOError:
                    pass
                conn.setblocking(True)

                with frame_lock:
                    frame = current_frame

                if frame:
                    try:
                        conn.sendall(BOUNDARY + b'\r\nContent-Type: image/jpeg\r\n\r\n' + frame + b'\r\n')
                    except:
                        break

                time.sleep(0.066)
            except:
                break
    except:
        pass
    finally:
        with clients_lock:
            if conn in clients:
                clients.remove(conn)
        try:
            conn.close()
        except:
            pass

def server_thread():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((HOST, PORT))
    server.listen(5)
    print(f'Stream server listening on http://{HOST}:{PORT}/')

    while True:
        try:
            conn, addr = server.accept()
            t = threading.Thread(target=handle_client, args=(conn, addr))
            t.daemon = True
            t.start()
        except:
            pass

def snapshot_saver_thread():
    \"\"\"Periodically save current frame to file for upload service\"\"\"
    while True:
        time.sleep(SNAPSHOT_INTERVAL)
        with frame_lock:
            frame = current_frame
        if frame:
            try:
                tmp_file = SNAPSHOT_FILE + '.tmp'
                with open(tmp_file, 'wb') as f:
                    f.write(frame)
                os.rename(tmp_file, SNAPSHOT_FILE)
            except Exception as e:
                pass

# Start server thread
t = threading.Thread(target=server_thread)
t.daemon = True
t.start()

# Start snapshot saver thread
ss = threading.Thread(target=snapshot_saver_thread)
ss.daemon = True
ss.start()

# Read MJPEG frames from stdin
buffer = b''
SOI = b'\xff\xd8'
EOI = b'\xff\xd9'

while True:
    chunk = sys.stdin.buffer.read(4096)
    if not chunk:
        break
    buffer += chunk

    while True:
        start = buffer.find(SOI)
        if start == -1:
            buffer = b''
            break

        end = buffer.find(EOI, start)
        if end == -1:
            buffer = buffer[start:]
            break

        frame = buffer[start:end+2]
        buffer = buffer[end+2:]

        with frame_lock:
            current_frame = frame
"
        ;;

    "USB")
        echo "Starting USB webcam stream..."

        if ! command -v ffmpeg &> /dev/null; then
            echo "ERROR: ffmpeg not found"
            exit 1
        fi

        configure_camera

        # Use ffmpeg + python server for USB cameras
        ffmpeg -f v4l2 -input_format mjpeg \
            -video_size "${STREAM_WIDTH}x${STREAM_HEIGHT}" \
            -framerate 15 \
            -i "$CAMERA_DEVICE" \
            -c:v mjpeg -q:v 5 \
            -f mjpeg - 2>/dev/null | python3 -c "
import sys
import socket
import threading
import time
import os

HOST = '0.0.0.0'
PORT = $STREAM_PORT
SNAPSHOT_FILE = '/tmp/stream_snapshot.jpg'
SNAPSHOT_INTERVAL = 2

BOUNDARY = b'--FRAME'
HEADERS = (
    b'HTTP/1.1 200 OK\r\n'
    b'Content-Type: multipart/x-mixed-replace; boundary=FRAME\r\n'
    b'Cache-Control: no-cache\r\n'
    b'Connection: close\r\n'
    b'\r\n'
)

current_frame = None
frame_lock = threading.Lock()

def handle_client(conn, addr):
    global current_frame
    try:
        conn.recv(4096)
        conn.sendall(HEADERS)
        while True:
            with frame_lock:
                frame = current_frame
            if frame:
                try:
                    conn.sendall(BOUNDARY + b'\r\nContent-Type: image/jpeg\r\n\r\n' + frame + b'\r\n')
                except:
                    break
            time.sleep(0.066)
    except:
        pass
    finally:
        conn.close()

def server_thread():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((HOST, PORT))
    server.listen(5)
    print(f'Stream server listening on http://{HOST}:{PORT}/')
    while True:
        conn, addr = server.accept()
        t = threading.Thread(target=handle_client, args=(conn, addr))
        t.daemon = True
        t.start()

def snapshot_saver_thread():
    while True:
        time.sleep(SNAPSHOT_INTERVAL)
        with frame_lock:
            frame = current_frame
        if frame:
            try:
                tmp_file = SNAPSHOT_FILE + '.tmp'
                with open(tmp_file, 'wb') as f:
                    f.write(frame)
                os.rename(tmp_file, SNAPSHOT_FILE)
            except:
                pass

t = threading.Thread(target=server_thread)
t.daemon = True
t.start()

ss = threading.Thread(target=snapshot_saver_thread)
ss.daemon = True
ss.start()

buffer = b''
SOI = b'\xff\xd8'
EOI = b'\xff\xd9'

while True:
    chunk = sys.stdin.buffer.read(4096)
    if not chunk:
        break
    buffer += chunk
    while True:
        start = buffer.find(SOI)
        if start == -1:
            buffer = b''
            break
        end = buffer.find(EOI, start)
        if end == -1:
            buffer = buffer[start:]
            break
        frame = buffer[start:end+2]
        buffer = buffer[end+2:]
        with frame_lock:
            current_frame = frame
"
        ;;

    *)
        echo "ERROR: Unknown camera type: $CAMERA_TYPE"
        exit 1
        ;;
esac
