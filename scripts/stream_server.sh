#!/bin/bash
#
# Camera Stream Server Script
# Lightweight Python-based MJPEG streaming server
# - Streams live video on port 8080
# - Saves snapshots to /tmp/stream_snapshot.jpg for Prusa Connect uploads
# - All temp files in RAM (tmpfs) to protect SD card
#

CONFIG_FILE="/etc/prusa_cam.conf"
SNAPSHOT_FILE="/tmp/stream_snapshot.jpg"

log_info() {
    echo "$*"
}

log_warn() {
    echo "WARNING: $*"
}

log_error() {
    echo "ERROR: $*"
}

load_configuration() {
    # Keep existing installations compatible by loading the same config file first,
    # then applying defaults only for values that are not configured.
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Configuration file not found: $CONFIG_FILE"
        log_info "Please run the installer first."
        exit 1
    fi

    # shellcheck source=/etc/prusa_cam.conf
    source "$CONFIG_FILE"

    # Current stream defaults.
    STREAM_PORT=${STREAM_PORT:-8080}
    STREAM_WIDTH=${STREAM_WIDTH:-1280}
    STREAM_HEIGHT=${STREAM_HEIGHT:-720}

    # Future autofocus configuration. Loaded for forward compatibility only;
    # intentionally not used yet, so current camera behavior is unchanged.
    FOCUS_MODE=${FOCUS_MODE:-}
    FOCUS_VALUE=${FOCUS_VALUE:-}
    FOCUS_SETTLE_TIME=${FOCUS_SETTLE_TIME:-}
}

print_startup_banner() {
    log_info "========================================"
    log_info "  Camera Stream Server"
    log_info "========================================"
    log_info ""
    log_info "Camera Type: $CAMERA_TYPE"
    log_info "Camera: $CAMERA_NAME"
    log_info "Stream Port: $STREAM_PORT"
    log_info "Resolution: ${STREAM_WIDTH}x${STREAM_HEIGHT}"
    log_info ""
}

has_v4l2_control() {
    local device="$1"
    local control="$2"

    command -v v4l2-ctl &> /dev/null && \
        v4l2-ctl -d "$device" --list-ctrls 2>/dev/null | grep -q "^[[:space:]]*$control[[:space:]]"
}

read_v4l2_control() {
    local device="$1"
    local control="$2"

    v4l2-ctl -d "$device" --get-ctrl="$control" 2>/dev/null
}

write_v4l2_control() {
    local device="$1"
    local control="$2"
    local value="$3"

    v4l2-ctl -d "$device" --set-ctrl="${control}=${value}" 2>/dev/null
}

run_mjpeg_server() {
    STREAM_SERVER_PORT="$STREAM_PORT" \
    STREAM_SERVER_SNAPSHOT_FILE="$SNAPSHOT_FILE" \
    python3 -c "$(generate_mjpeg_server_python)"
}

generate_mjpeg_server_python() {
    cat <<'PYTHON'
import os
import socket
import sys
import threading
import time

HOST = '0.0.0.0'
PORT = int(os.environ['STREAM_SERVER_PORT'])
SNAPSHOT_FILE = os.environ.get('STREAM_SERVER_SNAPSHOT_FILE', '/tmp/stream_snapshot.jpg')
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
    """Periodically save current frame to file for upload service."""
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
            except Exception:
                pass


# Start HTTP server and snapshot saver threads.
t = threading.Thread(target=server_thread)
t.daemon = True
t.start()

ss = threading.Thread(target=snapshot_saver_thread)
ss.daemon = True
ss.start()

# Read MJPEG frames from stdin and publish complete JPEG frames.
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
PYTHON
}

find_rpi_video_command() {
    if command -v rpicam-vid &> /dev/null; then
        echo "rpicam-vid"
    elif command -v libcamera-vid &> /dev/null; then
        echo "libcamera-vid"
    else
        return 1
    fi
}

start_rpi_stream() {
    local vid_cmd

    log_info "Starting RPi camera stream..."

    if ! vid_cmd=$(find_rpi_video_command); then
        log_error "No video capture tool found (rpicam-vid/libcamera-vid)"
        exit 1
    fi

    # Use rpicam-vid/libcamera-vid with inline MJPEG and pipe to Python HTTP server.
    "$vid_cmd" --camera "$CAMERA_ID" \
        --width "$STREAM_WIDTH" \
        --height "$STREAM_HEIGHT" \
        --framerate 15 \
        --codec mjpeg \
        --quality 80 \
        --nopreview \
        -t 0 \
        --inline \
        -o - 2>/dev/null | run_mjpeg_server
}

start_usb_stream() {
    log_info "Starting USB webcam stream..."

    if ! command -v ffmpeg &> /dev/null; then
        log_error "ffmpeg not found"
        exit 1
    fi

    # Use ffmpeg to convert the USB camera feed to MJPEG for the shared HTTP server.
    ffmpeg -f v4l2 -input_format mjpeg \
        -video_size "${STREAM_WIDTH}x${STREAM_HEIGHT}" \
        -framerate 15 \
        -i "$CAMERA_DEVICE" \
        -c:v mjpeg -q:v 5 \
        -f mjpeg - 2>/dev/null | run_mjpeg_server
}

main() {
    load_configuration
    print_startup_banner

    case "$CAMERA_TYPE" in
        "RPI")
            start_rpi_stream
            ;;
        "USB")
            start_usb_stream
            ;;
        *)
            log_error "Unknown camera type: $CAMERA_TYPE"
            exit 1
            ;;
    esac
}

main "$@"
