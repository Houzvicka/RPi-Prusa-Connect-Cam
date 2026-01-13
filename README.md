# RPi-Prusa-Connect-Cam

A simple setup script for connecting a Raspberry Pi camera to Prusa Connect. Works with both Raspberry Pi Camera Modules and USB webcams.

## Features

- **Auto-detection** of RPi Camera Modules and USB webcams
- **Live MJPEG stream** viewable in your browser
- **Prusa Connect integration** - automatic snapshot uploads
- **Auto-start on boot** via systemd services
- **One-command installation**

## Requirements

- Raspberry Pi (any model with camera support)
- Raspberry Pi OS Lite (or Desktop)
- Camera:
  - Raspberry Pi Camera Module (any version), or
  - USB Webcam
- Internet connection
- Prusa Connect account with a registered printer

## Quick Install

Run this single command on your Raspberry Pi:

```bash
wget -qO- https://raw.githubusercontent.com/Houzvicka/RPi-Prusa-Connect-Cam/main/install.sh | sudo bash
```

Or, if you prefer to review the script first:

```bash
wget https://raw.githubusercontent.com/Houzvicka/RPi-Prusa-Connect-Cam/main/install.sh
cat install.sh  # Review the script
sudo bash install.sh
```

## Manual Installation

1. Clone the repository:
   ```bash
   git clone https://github.com/Houzvicka/RPi-Prusa-Connect-Cam.git
   cd RPi-Prusa-Connect-Cam
   ```

2. Run the installer:
   ```bash
   sudo bash install.sh
   ```

## Getting Your Prusa Connect Token

1. Go to [Prusa Connect](https://connect.prusa3d.com)
2. Select your printer
3. Navigate to the **Camera** tab
4. Click **Add new other camera**
5. Copy the **Token** shown

You'll need this token during installation.

## After Installation

### View Camera Stream

Open your browser and go to:
```
http://<raspberry-pi-ip>:8080
```

### View Logs

```bash
# Upload service logs
journalctl -u prusa-connect-upload -f

# Stream service logs
journalctl -u camera-stream -f
```

### Service Commands

```bash
# Restart services
sudo systemctl restart prusa-connect-upload
sudo systemctl restart camera-stream

# Stop services
sudo systemctl stop prusa-connect-upload
sudo systemctl stop camera-stream

# Start services
sudo systemctl start prusa-connect-upload
sudo systemctl start camera-stream

# Check status
sudo systemctl status prusa-connect-upload
sudo systemctl status camera-stream
```

### Edit Configuration

```bash
sudo nano /etc/prusa_cam.conf
```

After editing, restart the services:
```bash
sudo systemctl restart prusa-connect-upload
sudo systemctl restart camera-stream
```

## Configuration Options

The configuration file `/etc/prusa_cam.conf` contains:

| Setting | Description | Default |
|---------|-------------|---------|
| `CAMERA_TYPE` | Camera type: `RPI` or `USB` | Auto-detected |
| `CAMERA_ID` | Camera index (RPi) or device path (USB) | Auto-detected |
| `CAPTURE_WIDTH` | Snapshot width for Prusa Connect | 1920 |
| `CAPTURE_HEIGHT` | Snapshot height for Prusa Connect | 1080 |
| `UPLOAD_INTERVAL` | Seconds between uploads | 10 |
| `STREAM_PORT` | Local stream server port | 8080 |
| `STREAM_WIDTH` | Stream resolution width | 1280 |
| `STREAM_HEIGHT` | Stream resolution height | 720 |

## Uninstall

```bash
sudo /opt/prusa-cam/uninstall.sh
```

Or run:
```bash
wget -qO- https://raw.githubusercontent.com/Houzvicka/RPi-Prusa-Connect-Cam/main/uninstall.sh | sudo bash
```

## Troubleshooting

### Camera not detected

**RPi Camera Module:**
- Ensure the camera is properly connected
- Enable camera in raspi-config: `sudo raspi-config` -> Interface Options -> Camera
- Reboot after enabling

**USB Webcam:**
- Try a different USB port
- Check if detected: `v4l2-ctl --list-devices`
- Some webcams require additional drivers

### Stream not loading

- Check if the service is running: `sudo systemctl status camera-stream`
- Check logs: `journalctl -u camera-stream -f`
- Verify the port is not blocked by firewall

### Uploads failing

- Verify your token is correct in `/etc/prusa_cam.conf`
- Check logs: `journalctl -u prusa-connect-upload -f`
- Ensure internet connection is working

### RPi Camera not working after OS update

Newer Raspberry Pi OS versions use `rpicam-*` commands instead of `libcamera-*`. The script automatically detects and uses the correct commands.

## How It Works

1. **Camera Detection**: Uses `rpicam-hello`/`libcamera-hello` for RPi cameras and `v4l2-ctl` for USB cameras
2. **Snapshot Upload**: Captures JPEG images and uploads to Prusa Connect API every 10 seconds
3. **Live Stream**: Uses [uStreamer](https://github.com/pikvm/ustreamer) for efficient MJPEG streaming
4. **Auto-start**: systemd services ensure everything starts on boot

## Credits

Inspired by [cannikin's gist](https://gist.github.com/cannikin/4954d050b72ff61ef0719c42922464e5).

## License

MIT License - feel free to modify and share!
