#!/bin/bash
#
# Camera Detection Script for Raspberry Pi
# Detects both RPi Camera Modules and USB Webcams
#

# Detect RPi camera modules using libcamera/rpicam tools
detect_rpi_cameras() {
    local cam_cmd=""

    # Check for rpicam-hello first (Bookworm+), fallback to libcamera-hello
    if command -v rpicam-hello &> /dev/null; then
        cam_cmd="rpicam-hello"
    elif command -v libcamera-hello &> /dev/null; then
        cam_cmd="libcamera-hello"
    else
        return 0
    fi

    # Parse output: "0 : imx219 [3280x2464 10-bit RGGB]" or similar
    $cam_cmd --list-cameras 2>&1 | grep -E "^[0-9]+ :" | while read -r line; do
        local cam_index
        local cam_model
        cam_index=$(echo "$line" | cut -d':' -f1 | xargs)
        cam_model=$(echo "$line" | cut -d':' -f2 | cut -d'[' -f1 | xargs)
        echo "RPI:$cam_index:$cam_model"
    done
}

# Detect USB webcams using v4l2-ctl
detect_usb_cameras() {
    if ! command -v v4l2-ctl &> /dev/null; then
        return 0
    fi

    local current_name=""
    local found_device=false

    v4l2-ctl --list-devices 2>/dev/null | while IFS= read -r line; do
        if [[ -z "$line" ]]; then
            found_device=false
            continue
        elif [[ "$line" =~ ^[[:space:]] ]]; then
            # Device path (indented line)
            if [[ "$found_device" == false ]]; then
                local device_path
                device_path=$(echo "$line" | xargs)
                if [[ "$device_path" =~ /dev/video[0-9]+$ ]]; then
                    # Skip RPi camera devices (they appear as mmal, bcm2835, unicam, or rp1-cfe)
                    if [[ ! "$current_name" =~ mmal|bcm2835|unicam|rp1-cfe|"platform:"|rpivid ]]; then
                        echo "USB:$device_path:$current_name"
                        found_device=true
                    fi
                fi
            fi
        else
            # Device name line
            current_name=$(echo "$line" | sed 's/ (.*)//')
            found_device=false
        fi
    done
}

# Display menu and get user selection
select_camera() {
    echo ""
    echo "=== Detected Cameras ==="
    echo ""

    local cameras=()
    local i=1

    # Collect RPi cameras
    while IFS= read -r cam; do
        if [[ -n "$cam" ]]; then
            cameras+=("$cam")
            local cam_id
            local cam_name
            cam_id=$(echo "$cam" | cut -d: -f2)
            cam_name=$(echo "$cam" | cut -d: -f3)
            echo "  $i) [RPi Camera] $cam_name (Camera $cam_id)"
            ((i++))
        fi
    done < <(detect_rpi_cameras)

    # Collect USB cameras
    while IFS= read -r cam; do
        if [[ -n "$cam" ]]; then
            cameras+=("$cam")
            local device
            local cam_name
            device=$(echo "$cam" | cut -d: -f2)
            cam_name=$(echo "$cam" | cut -d: -f3)
            echo "  $i) [USB Webcam] $cam_name ($device)"
            ((i++))
        fi
    done < <(detect_usb_cameras)

    echo ""

    if [[ ${#cameras[@]} -eq 0 ]]; then
        echo "ERROR: No cameras detected!"
        echo ""
        echo "For RPi Camera Module:"
        echo "  - Ensure camera is properly connected"
        echo "  - Enable camera in raspi-config"
        echo "  - Reboot after enabling"
        echo ""
        echo "For USB Webcam:"
        echo "  - Ensure webcam is plugged in"
        echo "  - Try a different USB port"
        echo ""
        return 1
    fi

    local selection
    while true; do
        read -p "Select camera [1-$((i-1))]: " selection
        if [[ "$selection" =~ ^[0-9]+$ ]] && [[ "$selection" -ge 1 ]] && [[ "$selection" -lt "$i" ]]; then
            break
        fi
        echo "Invalid selection. Please enter a number between 1 and $((i-1))"
    done

    echo "${cameras[$((selection-1))]}"
}

# If script is run directly, perform detection and selection
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    select_camera
fi
