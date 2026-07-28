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

# Camera capability flags (detected once for USB cameras)
CAMERA_CAPABILITIES_DETECTED=0
CAMERA_CONTROLS=""
CAM_HAS_AF=0
CAM_HAS_FOCUS_ABSOLUTE=0
CAM_HAS_EXPOSURE_AUTO=0
CAM_HAS_EXPOSURE_ABSOLUTE=0
CAM_HAS_BRIGHTNESS=0
CAM_HAS_CONTRAST=0
CAM_HAS_SATURATION=0
CAM_HAS_GAIN=0
CAM_HAS_WHITE_BALANCE=0

log_warning() {
    echo "WARNING: $*"
}

control_yes_no() {
    if [[ "$1" == "1" ]]; then
        echo "yes"
    else
        echo "no"
    fi
}

v4l2_control_exists() {
    local control_name="$1"
    [[ "$CAMERA_CONTROLS" =~ (^|[[:space:]])${control_name}([[:space:]]|$) ]]
}

v4l2_set_control() {
    local control_name="$1"
    local control_value="$2"

    if ! v4l2-ctl -d "$CAMERA_DEVICE" -c "${control_name}=${control_value}" >/dev/null 2>&1; then
        log_warning "Unable to set ${control_name}=${control_value}"
        return 1
    fi

    return 0
}

v4l2_get_control() {
    local control_name="$1"
    local value

    if ! value=$(v4l2-ctl -d "$CAMERA_DEVICE" -C "$control_name" 2>/dev/null); then
        log_warning "Unable to read ${control_name}"
        return 1
    fi

    value=${value##*:}
    value=${value//[[:space:]]/}
    echo "$value"
}

detect_camera_capabilities() {
    if [[ "$CAMERA_CAPABILITIES_DETECTED" == "1" ]]; then
        return 0
    fi

    CAMERA_CAPABILITIES_DETECTED=1

    if [[ "$CAMERA_TYPE" != "USB" ]]; then
        return 0
    fi

    if ! command -v v4l2-ctl &> /dev/null; then
        log_warning "v4l2-ctl not found; camera capabilities cannot be detected"
        return 0
    fi

    if ! CAMERA_CONTROLS=$(v4l2-ctl -d "$CAMERA_DEVICE" --list-ctrls 2>/dev/null | awk '{print $1}'); then
        log_warning "Unable to list V4L2 controls for ${CAMERA_DEVICE}"
        CAMERA_CONTROLS=""
        return 0
    fi

    if v4l2_control_exists "focus_auto" || v4l2_control_exists "focus_automatic_continuous"; then
        CAM_HAS_AF=1
    fi
    v4l2_control_exists "focus_absolute" && CAM_HAS_FOCUS_ABSOLUTE=1
    v4l2_control_exists "exposure_auto" && CAM_HAS_EXPOSURE_AUTO=1
    v4l2_control_exists "exposure_absolute" && CAM_HAS_EXPOSURE_ABSOLUTE=1
    v4l2_control_exists "brightness" && CAM_HAS_BRIGHTNESS=1
    v4l2_control_exists "contrast" && CAM_HAS_CONTRAST=1
    v4l2_control_exists "saturation" && CAM_HAS_SATURATION=1
    v4l2_control_exists "gain" && CAM_HAS_GAIN=1
    if v4l2_control_exists "white_balance_temperature" || v4l2_control_exists "white_balance_temperature_auto"; then
        CAM_HAS_WHITE_BALANCE=1
    fi

    echo "Camera capabilities:"
    echo "  Autofocus ............. $(control_yes_no "$CAM_HAS_AF")"
    echo "  Manual focus .......... $(control_yes_no "$CAM_HAS_FOCUS_ABSOLUTE")"
    echo "  Exposure .............. $(control_yes_no "$CAM_HAS_EXPOSURE_AUTO")"
    echo "  Exposure absolute ..... $(control_yes_no "$CAM_HAS_EXPOSURE_ABSOLUTE")"
    echo "  Brightness ............ $(control_yes_no "$CAM_HAS_BRIGHTNESS")"
    echo "  Contrast .............. $(control_yes_no "$CAM_HAS_CONTRAST")"
    echo "  Saturation ............ $(control_yes_no "$CAM_HAS_SATURATION")"
    echo "  Gain .................. $(control_yes_no "$CAM_HAS_GAIN")"
    echo "  White balance ......... $(control_yes_no "$CAM_HAS_WHITE_BALANCE")"
    echo ""
}

enable_continuous_autofocus() {
    if v4l2_control_exists "focus_auto"; then
        v4l2_set_control "focus_auto" 1
    elif v4l2_control_exists "focus_automatic_continuous"; then
        v4l2_set_control "focus_automatic_continuous" 1
    else
        log_warning "Continuous autofocus control is unavailable"
        return 1
    fi
}

disable_continuous_autofocus() {
    if v4l2_control_exists "focus_auto"; then
        v4l2_set_control "focus_auto" 0
    elif v4l2_control_exists "focus_automatic_continuous"; then
        v4l2_set_control "focus_automatic_continuous" 0
    else
        log_warning "Continuous autofocus control is unavailable"
        return 1
    fi
}

lock_autofocus() {
    local settle_time="${FOCUS_SETTLE_TIME:-3}"
    local locked_focus

    if [[ "$CAM_HAS_AF" != "1" ]]; then
        echo "Autofocus unsupported."
        echo "Continuing without autofocus."
        return 0
    fi

    enable_continuous_autofocus || return 0
    sleep "$settle_time"

    if [[ "$CAM_HAS_FOCUS_ABSOLUTE" != "1" ]]; then
        log_warning "focus_absolute control is unavailable; autofocus remains enabled"
        return 0
    fi

    if ! locked_focus=$(v4l2_get_control "focus_absolute"); then
        log_warning "Unable to capture current focus; autofocus remains enabled"
        return 0
    fi

    disable_continuous_autofocus || return 0
    v4l2_set_control "focus_absolute" "$locked_focus" || return 0

    echo "Autofocus locked at:"
    echo "  $locked_focus"
    echo ""
}

configure_focus() {
    if [[ "$CAMERA_TYPE" != "USB" ]]; then
        return 0
    fi

    if [[ -z "${FOCUS_MODE+x}" || -z "$FOCUS_MODE" ]]; then
        return 0
    fi

    echo "Selected focus mode:"
    echo "  $FOCUS_MODE"
    echo ""

    case "$FOCUS_MODE" in
        "continuous")
            if [[ "$CAM_HAS_AF" == "1" ]]; then
                enable_continuous_autofocus || true
            else
                log_warning "Autofocus unsupported; continuing without autofocus"
            fi
            ;;
        "manual")
            if [[ "$CAM_HAS_FOCUS_ABSOLUTE" == "1" ]]; then
                if [[ -z "${FOCUS_VALUE+x}" || -z "$FOCUS_VALUE" ]]; then
                    log_warning "FOCUS_VALUE is not set; manual focus not configured"
                else
                    v4l2_set_control "focus_absolute" "$FOCUS_VALUE" || true
                fi
            else
                log_warning "focus_absolute control is unavailable; manual focus not configured"
            fi
            ;;
        "lock")
            lock_autofocus || true
            ;;
        "auto")
            lock_autofocus || true
            ;;
        *)
            log_warning "Unknown FOCUS_MODE '${FOCUS_MODE}'; continuing without autofocus changes"
            ;;
    esac
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

        detect_camera_capabilities
        configure_focus

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
