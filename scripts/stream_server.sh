#!/bin/bash
#
# Camera Stream Server Script
# Serves MJPEG stream via HTTP
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

HOST = '0.0.0.0'
PORT = $STREAM_PORT

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
        # Read the HTTP request (and ignore it)
        conn.recv(4096)
        conn.sendall(HEADERS)

        with clients_lock:
            clients.append(conn)

        # Keep connection open, frames sent by main thread
        while True:
            try:
                # Check if connection is still alive
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

                import time
                time.sleep(0.066)  # ~15fps
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
    print(f'Stream server listening on http://{HOST}:{PORT}/stream')

    while True:
        try:
            conn, addr = server.accept()
            t = threading.Thread(target=handle_client, args=(conn, addr))
            t.daemon = True
            t.start()
        except:
            pass

# Start server in background
t = threading.Thread(target=server_thread)
t.daemon = True
t.start()

# Read MJPEG frames from stdin
buffer = b''
SOI = b'\xff\xd8'  # JPEG Start Of Image
EOI = b'\xff\xd9'  # JPEG End Of Image

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

        # Check if ustreamer is available
        if command -v ustreamer &> /dev/null; then
            # USB cameras use V4L2 directly with ustreamer
            ustreamer \
                --device "$CAMERA_DEVICE" \
                --host 0.0.0.0 \
                --port "$STREAM_PORT" \
                --resolution "${STREAM_WIDTH}x${STREAM_HEIGHT}" \
                --format MJPEG \
                --workers 2 \
                --drop-same-frames 30
        elif command -v ffmpeg &> /dev/null; then
            # Fallback to ffmpeg + python server
            ffmpeg -f v4l2 -input_format mjpeg \
                -video_size "${STREAM_WIDTH}x${STREAM_HEIGHT}" \
                -framerate 15 \
                -i "$CAMERA_DEVICE" \
                -c:v mjpeg -q:v 5 \
                -f mjpeg - 2>/dev/null | python3 -c "
import sys
import socket
import threading

# Same Python server as above...
HOST = '0.0.0.0'
PORT = $STREAM_PORT

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
            import time
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
    while True:
        conn, addr = server.accept()
        t = threading.Thread(target=handle_client, args=(conn, addr))
        t.daemon = True
        t.start()

t = threading.Thread(target=server_thread)
t.daemon = True
t.start()

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
        else
            echo "ERROR: No streaming tool available (ustreamer/ffmpeg)"
            exit 1
        fi
        ;;

    *)
        echo "ERROR: Unknown camera type: $CAMERA_TYPE"
        exit 1
        ;;
esac
