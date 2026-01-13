#!/bin/bash
#
# Prusa Connect Camera Setup Script for Raspberry Pi
# https://github.com/Houzvicka/RPi-Prusa-Connect-Cam
#
# This script will:
# 1. Install required dependencies
# 2. Detect and let you select a camera
# 3. Configure Prusa Connect integration
# 4. Set up a local camera stream
# 5. Enable auto-start on boot
#

set -e

INSTALL_DIR="/opt/prusa-cam"
REPO_URL="https://github.com/Houzvicka/RPi-Prusa-Connect-Cam"
REPO_BRANCH="main"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
ORANGE='\033[0;33m'
NC='\033[0m' # No Color

print_header() {
    echo ""
    echo -e "${ORANGE}========================================${NC}"
    echo -e "${ORANGE}  Prusa Connect Camera Setup${NC}"
    echo -e "${ORANGE}========================================${NC}"
    echo ""
}

print_step() {
    echo -e "${GREEN}[$1/$TOTAL_STEPS]${NC} $2"
}

print_error() {
    echo -e "${RED}ERROR:${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}WARNING:${NC} $1"
}

print_success() {
    echo -e "${GREEN}SUCCESS:${NC} $1"
}

TOTAL_STEPS=7

# ============================================
# Pre-flight checks
# ============================================

print_header

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    print_error "This script must be run as root"
    echo "Please run: sudo bash install.sh"
    exit 1
fi

# Check for Raspberry Pi
if ! grep -q "Raspberry Pi\|BCM" /proc/cpuinfo 2>/dev/null; then
    print_warning "This doesn't appear to be a Raspberry Pi"
    read -p "Continue anyway? [y/N]: " confirm < /dev/tty
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        exit 1
    fi
fi

echo "This script will install and configure the Prusa Connect camera service."
echo ""
read -p "Continue with installation? [Y/n]: " confirm < /dev/tty
if [[ "$confirm" == "n" || "$confirm" == "N" ]]; then
    echo "Installation cancelled."
    exit 0
fi

# ============================================
# Step 1: Install dependencies
# ============================================

print_step 1 "Installing dependencies..."

apt-get update -qq

# Core dependencies
apt-get install -y -qq \
    curl \
    git \
    v4l-utils \
    fswebcam \
    ffmpeg

# Build dependencies for ustreamer
apt-get install -y -qq \
    build-essential \
    libevent-dev \
    libjpeg-dev \
    libbsd-dev

echo "  Dependencies installed."

# ============================================
# Step 2: Build and install uStreamer
# ============================================

print_step 2 "Installing uStreamer..."

if command -v ustreamer &> /dev/null; then
    echo "  uStreamer already installed, skipping build."
else
    echo "  Building uStreamer from source..."
    cd /tmp
    rm -rf ustreamer 2>/dev/null || true
    git clone --depth=1 https://github.com/pikvm/ustreamer.git
    cd ustreamer
    make -j$(nproc) > /dev/null 2>&1
    make install > /dev/null 2>&1
    cd /
    rm -rf /tmp/ustreamer
    echo "  uStreamer installed."
fi

# ============================================
# Step 3: Download and install scripts
# ============================================

print_step 3 "Setting up installation directory..."

mkdir -p "$INSTALL_DIR"/{scripts,config,web}

# Check if we're running from the repo directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "$SCRIPT_DIR/scripts/detect_cameras.sh" ]]; then
    # Running from local repo
    echo "  Installing from local repository..."
    cp "$SCRIPT_DIR/scripts/"*.sh "$INSTALL_DIR/scripts/"
    cp "$SCRIPT_DIR/web/"* "$INSTALL_DIR/web/" 2>/dev/null || true
    cp "$SCRIPT_DIR/config/"* "$INSTALL_DIR/config/" 2>/dev/null || true
else
    # Download from GitHub
    echo "  Downloading from GitHub..."
    cd /tmp
    rm -rf RPi-Prusa-Connect-Cam-* 2>/dev/null || true
    curl -sL "$REPO_URL/archive/$REPO_BRANCH.tar.gz" | tar -xz
    cp RPi-Prusa-Connect-Cam-$REPO_BRANCH/scripts/*.sh "$INSTALL_DIR/scripts/"
    cp RPi-Prusa-Connect-Cam-$REPO_BRANCH/web/* "$INSTALL_DIR/web/" 2>/dev/null || true
    cp RPi-Prusa-Connect-Cam-$REPO_BRANCH/config/* "$INSTALL_DIR/config/" 2>/dev/null || true
    rm -rf /tmp/RPi-Prusa-Connect-Cam-*
fi

chmod +x "$INSTALL_DIR/scripts/"*.sh

echo "  Scripts installed to $INSTALL_DIR"

# ============================================
# Step 4: Detect and select camera
# ============================================

print_step 4 "Detecting cameras..."

# Source the detection script
source "$INSTALL_DIR/scripts/detect_cameras.sh"

# Run camera selection
SELECTED_CAMERA=$(select_camera)

if [[ -z "$SELECTED_CAMERA" ]]; then
    print_error "No camera selected"
    exit 1
fi

CAMERA_TYPE=$(echo "$SELECTED_CAMERA" | cut -d: -f1)
CAMERA_ID=$(echo "$SELECTED_CAMERA" | cut -d: -f2)
CAMERA_NAME=$(echo "$SELECTED_CAMERA" | cut -d: -f3-)

echo ""
echo -e "  Selected: ${GREEN}$CAMERA_NAME${NC}"

# ============================================
# Step 5: Configure Prusa Connect
# ============================================

print_step 5 "Configuring Prusa Connect..."

echo ""
echo "To get your camera token:"
echo "  1. Go to https://connect.prusa3d.com"
echo "  2. Select your printer"
echo "  3. Go to the Camera tab"
echo "  4. Click 'Add new other camera'"
echo "  5. Copy the Token shown"
echo ""

while true; do
    read -p "Enter your Prusa Connect Token: " TOKEN < /dev/tty
    if [[ -n "$TOKEN" ]]; then
        break
    fi
    print_error "Token cannot be empty"
done

# Generate unique fingerprint
FINGERPRINT=$(cat /proc/sys/kernel/random/uuid)

echo ""
echo -e "  Generated Fingerprint: ${YELLOW}$FINGERPRINT${NC}"
echo ""
echo "  IMPORTANT: Save this fingerprint! You may need it to re-register"
echo "  the camera in Prusa Connect if you reinstall."
echo ""

# Determine camera device for USB cameras
if [[ "$CAMERA_TYPE" == "USB" ]]; then
    CAMERA_DEVICE="$CAMERA_ID"
else
    CAMERA_DEVICE=""
fi

# Create configuration file
cat > /etc/prusa_cam.conf << EOF
# Prusa Connect Camera Configuration
# Generated on $(date)
# https://github.com/Houzvicka/RPi-Prusa-Connect-Cam

# Camera Settings
CAMERA_TYPE="$CAMERA_TYPE"
CAMERA_ID="$CAMERA_ID"
CAMERA_DEVICE="$CAMERA_DEVICE"
CAMERA_NAME="$CAMERA_NAME"

# Prusa Connect API
FINGERPRINT="$FINGERPRINT"
TOKEN="$TOKEN"

# Capture Settings
CAPTURE_WIDTH=1920
CAPTURE_HEIGHT=1080
UPLOAD_INTERVAL=10

# Stream Settings
STREAM_PORT=8080
STREAM_WIDTH=1280
STREAM_HEIGHT=720
EOF

chmod 600 /etc/prusa_cam.conf

echo "  Configuration saved to /etc/prusa_cam.conf"

# ============================================
# Step 6: Install systemd services
# ============================================

print_step 6 "Installing systemd services..."

# Prusa Connect Upload Service
cat > /etc/systemd/system/prusa-connect-upload.service << 'EOF'
[Unit]
Description=Prusa Connect Camera Upload Service
Documentation=https://github.com/Houzvicka/RPi-Prusa-Connect-Cam
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/prusa-cam/scripts/prusa_connect_upload.sh
Restart=always
RestartSec=10
User=root
StandardOutput=journal
StandardError=journal
SyslogIdentifier=prusa-connect-upload

[Install]
WantedBy=multi-user.target
EOF

# Camera Stream Service
cat > /etc/systemd/system/camera-stream.service << 'EOF'
[Unit]
Description=Camera MJPEG Stream Server
Documentation=https://github.com/Houzvicka/RPi-Prusa-Connect-Cam
After=network.target

[Service]
Type=simple
ExecStart=/opt/prusa-cam/scripts/stream_server.sh
Restart=always
RestartSec=5
User=root
StandardOutput=journal
StandardError=journal
SyslogIdentifier=camera-stream

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd and enable services
systemctl daemon-reload
systemctl enable prusa-connect-upload.service
systemctl enable camera-stream.service

echo "  Services installed and enabled."

# ============================================
# Step 7: Start services
# ============================================

print_step 7 "Starting services..."

systemctl start camera-stream.service
sleep 2
systemctl start prusa-connect-upload.service

echo "  Services started."

# ============================================
# Installation complete
# ============================================

# Get IP address
IP_ADDR=$(hostname -I 2>/dev/null | awk '{print $1}')
if [[ -z "$IP_ADDR" ]]; then
    IP_ADDR="<your-pi-ip>"
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Installation Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Camera Stream:"
echo -e "  ${YELLOW}http://$IP_ADDR:8080${NC}"
echo ""
echo "Prusa Connect:"
echo "  Snapshots are being uploaded every 10 seconds"
echo "  Check your printer's Camera tab in Prusa Connect"
echo ""
echo "Your camera fingerprint:"
echo -e "  ${YELLOW}$FINGERPRINT${NC}"
echo ""
echo "Useful commands:"
echo "  View upload logs:   journalctl -u prusa-connect-upload -f"
echo "  View stream logs:   journalctl -u camera-stream -f"
echo "  Restart upload:     sudo systemctl restart prusa-connect-upload"
echo "  Restart stream:     sudo systemctl restart camera-stream"
echo "  Edit config:        sudo nano /etc/prusa_cam.conf"
echo "  Uninstall:          sudo /opt/prusa-cam/uninstall.sh"
echo ""
echo -e "${GREEN}Enjoy your Prusa Connect camera!${NC}"
echo ""
