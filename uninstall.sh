#!/bin/bash
#
# Prusa Connect Camera Uninstall Script
# https://github.com/Houzvicka/RPi-Prusa-Connect-Cam
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo ""
echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}  Prusa Connect Camera Uninstall${NC}"
echo -e "${YELLOW}========================================${NC}"
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}ERROR:${NC} This script must be run as root"
    echo "Please run: sudo bash uninstall.sh"
    exit 1
fi

echo "This will remove the Prusa Connect camera service."
echo ""
read -p "Are you sure you want to uninstall? [y/N]: " confirm < /dev/tty
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Uninstall cancelled."
    exit 0
fi

echo ""

# Stop services
echo "Stopping services..."
systemctl stop prusa-connect-upload.service 2>/dev/null || true
systemctl stop camera-stream.service 2>/dev/null || true

# Disable services
echo "Disabling services..."
systemctl disable prusa-connect-upload.service 2>/dev/null || true
systemctl disable camera-stream.service 2>/dev/null || true

# Remove service files
echo "Removing service files..."
rm -f /etc/systemd/system/prusa-connect-upload.service
rm -f /etc/systemd/system/camera-stream.service
systemctl daemon-reload

# Remove installation directory
echo "Removing installation directory..."
rm -rf /opt/prusa-cam

# Ask about config file
echo ""
if [[ -f /etc/prusa_cam.conf ]]; then
    echo "Configuration file contains your camera token and fingerprint."
    read -p "Remove configuration file? [y/N]: " remove_config < /dev/tty
    if [[ "$remove_config" == "y" || "$remove_config" == "Y" ]]; then
        rm -f /etc/prusa_cam.conf
        echo "Configuration file removed."
    else
        echo "Configuration file kept at /etc/prusa_cam.conf"
    fi
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Uninstall Complete${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "The Prusa Connect camera service has been removed."
echo ""
echo "To reinstall, run:"
echo "  wget -qO- https://raw.githubusercontent.com/Houzvicka/RPi-Prusa-Connect-Cam/main/install.sh | sudo bash"
echo ""
