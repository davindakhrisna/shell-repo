# Photo Gallery (Life Museum)

An automated, 24/7 capture daemon for your homelab that takes snapshots from an external camera at a random time each day (or configurable intervals) and automatically syncs them to your self-hosted [Immich](https://immich.app/) instance categorized under the **"Life Museum"** album.

Designed to effortlessly preserve candid, authentic everyday moments without manual intervention.

---

## Features

- 📸 **Universal Camera Support**:
  - **USB Webcams / V4L2** (`/dev/video0`) with sensor warmup to avoid dark/underexposed frames.
  - **RTSP IP Cameras** (`rtsp://...`) from Reolink, Tapo, Hikvision, Dahua, etc.
  - **HTTP/MJPEG Snapshot URLs**.
  - **Raspberry Pi Camera Modules** (`rpicam-still` / `libcamera-still`).
  - **Custom Capture Commands** via placeholder `{output}`.
- 🎲 **Smart Random Scheduling**:
  - `random_daily` *(default)*: Picks a random hour and minute each day during your configured active hours (e.g. 08:00 to 22:00) so snapshots feel spontaneous.
  - `random_hourly`: Captures once every hour at a randomized minute.
  - `random_interval`: Captures after randomized delays between minimum and maximum minutes.
- 🖼️ **Direct Immich Integration**:
  - Direct REST API communication using `curl` and `jq` (no heavy Docker or NodeJS dependencies required).
  - Automatically queries and creates the **"Life Museum"** album if it does not already exist.
  - Uploads the image and attaches it directly into the album.
- 🔄 **24/7 Auto-Start & Resilience**:
  - Built-in `systemd` user service installer (`--install-service`).
  - Automatic restart on failure or network disconnection.
  - Graceful handling of server downtimes (retries without crashing the daemon).
- 🧹 **Local Storage Retention**:
  - Saves a local archive in `./captures/` with configurable retention (`KEEP_LOCAL_DAYS`).

---

## Prerequisites

Ensure the following utilities are installed on your homelab machine:

### Debian / Ubuntu / Raspberry Pi OS
```bash
sudo apt update
sudo apt install -y curl jq ffmpeg
```

### Arch Linux
```bash
sudo pacman -S curl jq ffmpeg
```

### NixOS
Add to `environment.systemPackages` or `home.packages`:
```nix
pkgs.curl
pkgs.jq
pkgs.ffmpeg
```

*(Optional)* If using a USB webcam, ensure your user has permission to access video devices:
```bash
sudo usermod -aG video $USER
```

---

## Quick Start

### 1. Configure Environment

Copy the template configuration file:
```bash
cp .env.example .env
```

Edit `.env` with your Immich credentials and camera preferences:
```bash
nano .env
```

Key settings in `.env`:
```bash
# Immich URL & API Key (Immich Web UI -> Account Settings -> API Keys)
IMMICH_INSTANCE_URL="http://192.168.1.100:2283"
IMMICH_API_KEY="your_api_key_here"
IMMICH_ALBUM_NAME="Life Museum"

# Camera Settings
CAMERA_TYPE="usb"            # usb | rtsp | http | rpi | custom
CAMERA_DEVICE="/dev/video0"
CAMERA_RESOLUTION="1920x1080"
CAMERA_WARMUP_SECONDS="2"    # Warmup time for auto-exposure

# Schedule Settings
SCHEDULE_MODE="random_daily" # random_daily | random_hourly | random_interval
WINDOW_START_HOUR="8"        # 08:00
WINDOW_END_HOUR="22"         # 22:00
```

> **Note:** The script also checks for a global configuration at `$HOME/nixos-config/.env` if `.env` is not found in the local directory.

---

### 2. Verify Your Setup

Before running the 24/7 daemon, test your camera and Immich connection:

#### A. Test Camera Capture
```bash
./photo-gallery.sh --test-camera
```
*Captures a test snapshot to `./test_capture.jpg`.*

#### B. Test Immich Connection & Album
```bash
./photo-gallery.sh --test-immich
```
*Validates the API key and ensures the "Life Museum" album exists or creates it.*

#### C. Manual Capture & Upload
```bash
./photo-gallery.sh --now
```
*Immediately takes a snapshot, uploads it to Immich, and adds it to the "Life Museum" album.*

---

### 3. Enable 24/7 Auto-Start (Systemd)

To run the capture service 24/7 and have it start automatically on system boot:

```bash
./photo-gallery.sh --install-service
```

This installs and enables a user systemd service (`photo-gallery.service`).

#### Monitoring the Service
```bash
# Check service status
./photo-gallery.sh --status
# Or via systemctl
systemctl --user status photo-gallery.service

# View live countdown and execution logs
journalctl --user -u photo-gallery.service -f
```

To stop and remove the systemd auto-start service:
```bash
./photo-gallery.sh --uninstall-service
```

---

## CLI Reference

| Command | Description |
| :--- | :--- |
| `./photo-gallery.sh` or `./photo-gallery.sh --now` | Trigger an immediate capture and upload to Immich |
| `./photo-gallery.sh --daemon` | Run the scheduler loop in the foreground (24/7 mode) |
| `./photo-gallery.sh --test-camera` | Test camera capture without uploading |
| `./photo-gallery.sh --test-immich` | Validate connection to Immich and verify album |
| `./photo-gallery.sh --install-service` | Install and enable the systemd service for auto-start |
| `./photo-gallery.sh --uninstall-service` | Disable and uninstall the systemd service |
| `./photo-gallery.sh --status` | Check systemd service status |
| `./photo-gallery.sh --help` | Display help and usage information |

---

## Camera Configuration Details

### 1. USB Webcam (V4L2)
```bash
CAMERA_TYPE="usb"
CAMERA_DEVICE="/dev/video0"
CAMERA_RESOLUTION="1920x1080"
CAMERA_WARMUP_SECONDS="2" # Allows auto-exposure to adjust before snapshot
```

### 2. RTSP IP Camera
```bash
CAMERA_TYPE="rtsp"
CAMERA_STREAM_URL="rtsp://admin:password@192.168.1.55:554/h264Preview_01_main"
```

### 3. HTTP Snapshot
```bash
CAMERA_TYPE="http"
CAMERA_STREAM_URL="http://192.168.1.55/cgi-bin/snapshot.cgi"
```

### 4. Custom Command
```bash
CAMERA_TYPE="custom"
CAMERA_CUSTOM_CMD="ffmpeg -y -f v4l2 -i /dev/video0 -vframes 1 '{output}'"
```

---

## NixOS Integration (Alternative to `--install-service`)

If you manage your homelab declaratively with NixOS, you can add this service in your `configuration.nix` or Home Manager module:

```nix
systemd.user.services.photo-gallery = {
  description = "Photo Gallery Life Museum Capture Daemon";
  wantedBy = [ "default.target" ];
  after = [ "network-online.target" ];
  wants = [ "network-online.target" ];
  serviceConfig = {
    ExecStart = "/home/kris/shell-repo/photo-gallery/photo-gallery.sh --daemon";
    Restart = "always";
    RestartSec = "15s";
  };
};
```
