#!/usr/bin/env bash
# ==============================================================================
# Photo Gallery (Life Museum)
# 24/7 Automated Camera Capture & Immich Gallery Sync
# ==============================================================================

set -o pipefail

# Determine script root directory
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ENV_FILE="$DIR/.env"
[ -f "$ENV_FILE" ] || ENV_FILE="$HOME/nixos-config/.env"

# Load environment configuration if present
if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
fi

# ------------------------------------------------------------------------------
# Default Settings
# ------------------------------------------------------------------------------
IMMICH_INSTANCE_URL="${IMMICH_INSTANCE_URL:-}"
IMMICH_API_KEY="${IMMICH_API_KEY:-}"
IMMICH_ALBUM_NAME="${IMMICH_ALBUM_NAME:-Life Museum}"
IMMICH_DEVICE_ID="${IMMICH_DEVICE_ID:-homelab-camera}"

CAMERA_TYPE="${CAMERA_TYPE:-usb}"
CAMERA_DEVICE="${CAMERA_DEVICE:-/dev/video0}"
CAMERA_RESOLUTION="${CAMERA_RESOLUTION:-1920x1080}"
CAMERA_WARMUP_SECONDS="${CAMERA_WARMUP_SECONDS:-2}"
CAMERA_STREAM_URL="${CAMERA_STREAM_URL:-}"
CAMERA_CUSTOM_CMD="${CAMERA_CUSTOM_CMD:-}"

SCHEDULE_MODE="${SCHEDULE_MODE:-random_daily}"
WINDOW_START_HOUR="${WINDOW_START_HOUR:-8}"
WINDOW_END_HOUR="${WINDOW_END_HOUR:-22}"
MIN_INTERVAL_MINUTES="${MIN_INTERVAL_MINUTES:-60}"
MAX_INTERVAL_MINUTES="${MAX_INTERVAL_MINUTES:-240}"

STORAGE_DIR="${STORAGE_DIR:-$DIR/captures}"
KEEP_LOCAL_DAYS="${KEEP_LOCAL_DAYS:-30}"
LOG_FILE="${LOG_FILE:-}"

STATE_FILE="${STATE_FILE:-$DIR/.last_capture_state}"

# Resolve relative storage path
if [[ "$STORAGE_DIR" != /* ]]; then
    STORAGE_DIR="$DIR/$STORAGE_DIR"
fi

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg"
    if [ -n "$LOG_FILE" ]; then
        mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
        echo "$msg" >> "$LOG_FILE"
    fi
}

log_error() {
    log "[ERROR] $1" >&2
}

log_warn() {
    log "[WARN] $1"
}

# ------------------------------------------------------------------------------
# Validation Helpers
# ------------------------------------------------------------------------------
check_dependencies() {
    local missing=()
    command -v curl >/dev/null 2>&1 || missing+=("curl")
    command -v jq >/dev/null 2>&1 || missing+=("jq")

    case "$CAMERA_TYPE" in
        usb|rtsp)
            command -v ffmpeg >/dev/null 2>&1 || command -v fswebcam >/dev/null 2>&1 || missing+=("ffmpeg or fswebcam")
            ;;
        rpi)
            command -v rpicam-still >/dev/null 2>&1 || command -v libcamera-still >/dev/null 2>&1 || missing+=("rpicam-still or libcamera-still")
            ;;
    esac

    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Missing required dependencies: ${missing[*]}"
        log_error "Please install them using your package manager (e.g., apt install ffmpeg curl jq)."
        return 1
    fi
    return 0
}

check_env() {
    if [ -z "$IMMICH_INSTANCE_URL" ] || [ -z "$IMMICH_API_KEY" ]; then
        log_error "Configuration missing: IMMICH_INSTANCE_URL and IMMICH_API_KEY must be set."
        log_error "Please copy $DIR/.env.example to $DIR/.env and set your credentials."
        return 1
    fi
    return 0
}

get_api_base() {
    local base="${IMMICH_INSTANCE_URL%/}"
    if [[ "$base" != */api ]]; then
        base="${base}/api"
    fi
    echo "$base"
}

# ------------------------------------------------------------------------------
# Camera Capture Engine
# ------------------------------------------------------------------------------
capture_photo() {
    local dest="$1"
    mkdir -p "$(dirname "$dest")" || return 1

    log "Capturing photo (Type: $CAMERA_TYPE, Resolution: $CAMERA_RESOLUTION)..."

    case "$CAMERA_TYPE" in
        usb)
            if command -v ffmpeg >/dev/null 2>&1; then
                # Attempt capture with MJPEG input format first for high resolution USB webcams
                if ! ffmpeg -hide_banner -loglevel error -y \
                    -ss "$CAMERA_WARMUP_SECONDS" \
                    -f v4l2 -input_format mjpeg -video_size "$CAMERA_RESOLUTION" \
                    -i "$CAMERA_DEVICE" -frames:v 1 "$dest" 2>/dev/null; then
                    # Fallback to standard v4l2 pixel format
                    ffmpeg -hide_banner -loglevel error -y \
                        -ss "$CAMERA_WARMUP_SECONDS" \
                        -f v4l2 -video_size "$CAMERA_RESOLUTION" \
                        -i "$CAMERA_DEVICE" -frames:v 1 "$dest" 2>/dev/null
                fi
            elif command -v fswebcam >/dev/null 2>&1; then
                fswebcam -d "$CAMERA_DEVICE" -r "$CAMERA_RESOLUTION" --skip 20 --no-banner "$dest" 2>/dev/null
            else
                log_error "Neither ffmpeg nor fswebcam is available for USB camera capture."
                return 1
            fi
            ;;

        rtsp)
            if [ -z "$CAMERA_STREAM_URL" ]; then
                log_error "CAMERA_STREAM_URL must be specified when CAMERA_TYPE='rtsp'."
                return 1
            fi
            ffmpeg -hide_banner -loglevel error -y \
                -rtsp_transport tcp -i "$CAMERA_STREAM_URL" \
                -frames:v 1 "$dest" 2>/dev/null
            ;;

        http)
            if [ -z "$CAMERA_STREAM_URL" ]; then
                log_error "CAMERA_STREAM_URL must be specified when CAMERA_TYPE='http'."
                return 1
            fi
            curl -s -S --fail --max-time 20 -o "$dest" "$CAMERA_STREAM_URL"
            ;;

        rpi)
            if command -v rpicam-still >/dev/null 2>&1; then
                rpicam-still -t 2000 --width "${CAMERA_RESOLUTION%x*}" --height "${CAMERA_RESOLUTION#*x}" -o "$dest" 2>/dev/null
            elif command -v libcamera-still >/dev/null 2>&1; then
                libcamera-still -t 2000 --width "${CAMERA_RESOLUTION%x*}" --height "${CAMERA_RESOLUTION#*x}" -o "$dest" 2>/dev/null
            else
                log_error "Raspberry Pi camera utilities not found."
                return 1
            fi
            ;;

        custom)
            if [ -z "$CAMERA_CUSTOM_CMD" ]; then
                log_error "CAMERA_CUSTOM_CMD must be set when CAMERA_TYPE='custom'."
                return 1
            fi
            local cmd="${CAMERA_CUSTOM_CMD//\{output\}/$dest}"
            eval "$cmd"
            ;;

        *)
            log_error "Unknown CAMERA_TYPE: '$CAMERA_TYPE'. Supported: usb, rtsp, http, rpi, custom."
            return 1
            ;;
    esac

    if [ ! -s "$dest" ]; then
        log_error "Photo capture failed or produced an empty file at: $dest"
        rm -f "$dest" 2>/dev/null
        return 1
    fi

    local size
    size=$(du -h "$dest" 2>/dev/null | cut -f1)
    log "Photo successfully captured: $dest ($size)"
    return 0
}

# ------------------------------------------------------------------------------
# Immich API Engine
# ------------------------------------------------------------------------------
immich_test_connection() {
    check_env || return 1
    local api_base
    api_base=$(get_api_base)

    log "Checking Immich server connectivity at: $api_base"

    local response
    response=$(curl -s -w "\n%{http_code}" -X GET "${api_base}/users/me" \
        -H "x-api-key: ${IMMICH_API_KEY}" \
        -H "Accept: application/json")

    local http_code
    http_code=$(echo "$response" | tail -n1)
    local body
    body=$(echo "$response" | sed '$d')

    if [ "$http_code" -ne 200 ]; then
        log_error "Immich connection failed with HTTP status: $http_code"
        local err_msg
        err_msg=$(echo "$body" | jq -r '.message // empty' 2>/dev/null)
        [ -n "$err_msg" ] && log_error "Server response: $err_msg"
        return 1
    fi

    local user_email
    user_email=$(echo "$body" | jq -r '.email // .name // "Authenticated User"')
    log "Successfully connected to Immich as: $user_email"

    # Test album lookup / creation
    local album_id
    album_id=$(immich_get_or_create_album)
    if [ -n "$album_id" ]; then
        log "Immich Album '$IMMICH_ALBUM_NAME' is ready (ID: $album_id)."
        return 0
    else
        log_error "Failed to verify or create album '$IMMICH_ALBUM_NAME'."
        return 1
    fi
}

immich_get_or_create_album() {
    local api_base
    api_base=$(get_api_base)

    # 1. Search for existing album
    local albums_json
    albums_json=$(curl -s -f -X GET "${api_base}/albums" \
        -H "x-api-key: ${IMMICH_API_KEY}" \
        -H "Accept: application/json" 2>/dev/null)

    local album_id=""
    if [ -n "$albums_json" ]; then
        album_id=$(echo "$albums_json" | jq -r --arg name "$IMMICH_ALBUM_NAME" '.[] | select(.albumName == $name) | .id' 2>/dev/null | head -n1)
    fi

    if [ -n "$album_id" ] && [ "$album_id" != "null" ]; then
        echo "$album_id"
        return 0
    fi

    # 2. Create album if missing
    log "Album '$IMMICH_ALBUM_NAME' not found. Creating album..."
    local payload
    payload=$(jq -n \
        --arg name "$IMMICH_ALBUM_NAME" \
        --arg desc "Life Museum - Daily random homelab captures" \
        '{"albumName": $name, "description": $desc}')

    local create_resp
    create_resp=$(curl -s -f -X POST "${api_base}/albums" \
        -H "x-api-key: ${IMMICH_API_KEY}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -d "$payload" 2>/dev/null)

    album_id=$(echo "$create_resp" | jq -r '.id // empty' 2>/dev/null)
    if [ -n "$album_id" ] && [ "$album_id" != "null" ]; then
        log "Album created successfully (ID: $album_id)."
        echo "$album_id"
        return 0
    fi

    return 1
}

immich_upload_and_index() {
    local file_path="$1"
    check_env || return 1

    if [ ! -f "$file_path" ]; then
        log_error "File to upload does not exist: $file_path"
        return 1
    fi

    local api_base
    api_base=$(get_api_base)
    local timestamp_sec
    timestamp_sec=$(date +%s)
    local device_asset_id="${IMMICH_DEVICE_ID}-${timestamp_sec}-${RANDOM}"
    local iso_date
    iso_date=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")

    log "Uploading photo to Immich ($(basename "$file_path"))..."

    local upload_resp
    upload_resp=$(curl -s -w "\n%{http_code}" -X POST "${api_base}/assets" \
        -H "x-api-key: ${IMMICH_API_KEY}" \
        -H "Accept: application/json" \
        -F "assetData=@${file_path}" \
        -F "deviceAssetId=${device_asset_id}" \
        -F "deviceId=${IMMICH_DEVICE_ID}" \
        -F "fileCreatedAt=${iso_date}" \
        -F "fileModifiedAt=${iso_date}" \
        -F "isFavorite=false")

    local http_code
    http_code=$(echo "$upload_resp" | tail -n1)
    local body
    body=$(echo "$upload_resp" | sed '$d')

    if [[ "$http_code" != "200" && "$http_code" != "201" ]]; then
        log_error "Immich upload failed with HTTP $http_code"
        local err_msg
        err_msg=$(echo "$body" | jq -r '.message // empty' 2>/dev/null)
        [ -n "$err_msg" ] && log_error "Response: $err_msg"
        return 1
    fi

    local asset_id
    asset_id=$(echo "$body" | jq -r '.id // empty' 2>/dev/null)

    if [ -z "$asset_id" ] || [ "$asset_id" == "null" ]; then
        # Check if returned as duplicate
        asset_id=$(echo "$body" | jq -r '.duplicateId // empty' 2>/dev/null)
    fi

    if [ -z "$asset_id" ] || [ "$asset_id" == "null" ]; then
        log_error "Could not parse asset ID from Immich response: $body"
        return 1
    fi

    log "Asset indexed successfully in Immich (Asset ID: $asset_id)"

    # Add asset to the "Life Museum" album
    local album_id
    album_id=$(immich_get_or_create_album)
    if [ -n "$album_id" ]; then
        log "Adding asset $asset_id to album '$IMMICH_ALBUM_NAME' ($album_id)..."
        local add_payload
        add_payload=$(jq -n --arg id "$asset_id" '{"ids": [$id]}')

        local put_resp
        put_resp=$(curl -s -w "\n%{http_code}" -X PUT "${api_base}/albums/${album_id}/assets" \
            -H "x-api-key: ${IMMICH_API_KEY}" \
            -H "Content-Type: application/json" \
            -H "Accept: application/json" \
            -d "$add_payload")

        local put_code
        put_code=$(echo "$put_resp" | tail -n1)
        if [[ "$put_code" == "200" ]]; then
            log "Photo successfully added to Life Museum album."
        else
            log_warn "Asset uploaded, but adding to album returned HTTP $put_code"
        fi
    else
        log_warn "Asset uploaded, but target album could not be retrieved."
    fi

    return 0
}

# ------------------------------------------------------------------------------
# Retention Cleanup
# ------------------------------------------------------------------------------
cleanup_local_storage() {
    if [ "$KEEP_LOCAL_DAYS" -gt 0 ] 2>/dev/null; then
        if [ -d "$STORAGE_DIR" ]; then
            log "Running local cleanup: removing snapshots older than $KEEP_LOCAL_DAYS days..."
            find "$STORAGE_DIR" -type f \( -name "*.jpg" -o -name "*.jpeg" -o -name "*.png" \) -mtime +"$KEEP_LOCAL_DAYS" -exec rm -f {} + 2>/dev/null
        fi
    fi
}

# ------------------------------------------------------------------------------
# Capture Workflow
# ------------------------------------------------------------------------------
run_capture_and_upload() {
    check_dependencies || return 1
    check_env || return 1

    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    local dest_file="$STORAGE_DIR/life_museum_${timestamp}.jpg"

    if ! capture_photo "$dest_file"; then
        log_error "Capture workflow aborted due to camera error."
        return 1
    fi

    if ! immich_upload_and_index "$dest_file"; then
        log_error "Photo captured at $dest_file, but failed to sync to Immich."
        return 1
    fi

    # Record state for daily scheduler
    local today
    today=$(date '+%Y-%m-%d')
    echo "$today" > "$STATE_FILE"

    cleanup_local_storage
    log "Capture and sync workflow completed successfully."
    return 0
}

# ------------------------------------------------------------------------------
# Scheduler Engine
# ------------------------------------------------------------------------------
get_next_sleep_seconds() {
    local now_epoch
    now_epoch=$(date +%s)

    case "$SCHEDULE_MODE" in
        random_daily)
            local today
            today=$(date '+%Y-%m-%d')
            local last_date=""
            [ -f "$STATE_FILE" ] && last_date=$(cat "$STATE_FILE" 2>/dev/null)

            local current_hour
            current_hour=$(date '+%H' | sed 's/^0*//')
            [ -z "$current_hour" ] && current_hour=0

            local start_h=$WINDOW_START_HOUR
            local end_h=$WINDOW_END_HOUR
            [ "$start_h" -lt 0 ] && start_h=0
            [ "$end_h" -gt 23 ] && end_h=23
            [ "$start_h" -gt "$end_h" ] && start_h=0 && end_h=23

            local target_date="$today"
            local can_run_today=0

            if [ "$last_date" != "$today" ]; then
                if [ "$current_hour" -le "$end_h" ]; then
                    can_run_today=1
                fi
            fi

            local rand_h
            local rand_m
            local rand_s

            if [ "$can_run_today" -eq 1 ]; then
                local min_h=$start_h
                [ "$current_hour" -gt "$min_h" ] && min_h=$current_hour
                local span=$((end_h - min_h + 1))
                rand_h=$((min_h + RANDOM % span))

                if [ "$rand_h" -eq "$current_hour" ]; then
                    local current_m
                    current_m=$(date '+%M' | sed 's/^0*//')
                    [ -z "$current_m" ] && current_m=0
                    if [ "$current_m" -ge 58 ]; then
                        rand_h=$((rand_h + 1))
                        rand_m=$((RANDOM % 60))
                    else
                        local m_span=$((60 - current_m - 1))
                        rand_m=$((current_m + 1 + RANDOM % m_span))
                    fi
                else
                    rand_m=$((RANDOM % 60))
                fi
                rand_s=$((RANDOM % 60))

                if [ "$rand_h" -gt "$end_h" ]; then
                    can_run_today=0
                fi
            fi

            if [ "$can_run_today" -eq 0 ]; then
                # Plan for tomorrow
                target_date=$(date -d "@$((now_epoch + 86400))" '+%Y-%m-%d' 2>/dev/null || date -v+1d '+%Y-%m-%d')
                local span=$((end_h - start_h + 1))
                rand_h=$((start_h + RANDOM % span))
                rand_m=$((RANDOM % 60))
                rand_s=$((RANDOM % 60))
            fi

            local target_time
            target_time=$(printf "%02d:%02d:%02d" "$rand_h" "$rand_m" "$rand_s")
            local target_epoch
            target_epoch=$(date -d "$target_date $target_time" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M:%S" "$target_date $target_time" +%s)

            local sleep_sec=$((target_epoch - now_epoch))
            if [ "$sleep_sec" -le 0 ]; then
                sleep_sec=60
            fi

            local hours=$((sleep_sec / 3600))
            local mins=$(((sleep_sec % 3600) / 60))
            log "Next random daily capture scheduled for: $target_date $target_time (in ${hours}h ${mins}m / ${sleep_sec}s)"
            echo "$sleep_sec"
            ;;

        random_hourly)
            # Pick a random delay within the current or next hour (15 to 60 mins)
            local delay_min=$((15 + RANDOM % 45))
            local sleep_sec=$((delay_min * 60))
            log "Next hourly capture scheduled in ${delay_min} minutes (${sleep_sec}s)"
            echo "$sleep_sec"
            ;;

        random_interval)
            local min_m=$MIN_INTERVAL_MINUTES
            local max_m=$MAX_INTERVAL_MINUTES
            [ "$min_m" -le 0 ] && min_m=30
            [ "$max_m" -le "$min_m" ] && max_m=$((min_m + 60))
            local span=$((max_m - min_m + 1))
            local delay_min=$((min_m + RANDOM % span))
            local sleep_sec=$((delay_min * 60))
            local hours=$((delay_min / 60))
            local mins=$((delay_min % 60))
            log "Next interval capture scheduled in ${hours}h ${mins}m (${sleep_sec}s)"
            echo "$sleep_sec"
            ;;

        *)
            log_error "Unknown SCHEDULE_MODE: $SCHEDULE_MODE. Defaulting to 1 hour."
            echo "3600"
            ;;
    esac
}

run_daemon() {
    log "========================================================"
    log "Starting Photo Gallery Life Museum Daemon (24/7 Mode)"
    log "Mode: $SCHEDULE_MODE | Camera: $CAMERA_TYPE | Album: $IMMICH_ALBUM_NAME"
    log "========================================================"

    check_dependencies || exit 1
    check_env || exit 1

    # Verify connection on daemon startup
    if ! immich_test_connection; then
        log_warn "Immich connection check failed at startup. Will retry during scheduled runs."
    fi

    # Trap signals for graceful shutdown
    trap 'log "Received shutdown signal. Exiting daemon..."; exit 0' SIGINT SIGTERM

    while true; do
        local sleep_seconds
        sleep_seconds=$(get_next_sleep_seconds)

        log "Entering sleep until next capture window..."
        sleep "$sleep_seconds" &
        wait $!

        log "Waking up to perform scheduled capture..."
        if ! run_capture_and_upload; then
            log_error "Scheduled capture encountered an error. Will continue running 24/7."
            # Sleep brief backoff to avoid tight retry loops on camera failure
            sleep 60
        fi
    done
}

# ------------------------------------------------------------------------------
# Systemd Service Management
# ------------------------------------------------------------------------------
install_systemd_service() {
    local service_name="photo-gallery.service"
    local user_service_dir="$HOME/.config/systemd/user"
    local target_file="$user_service_dir/$service_name"
    local template_file="$DIR/systemd/$service_name"

    if [ ! -f "$template_file" ]; then
        log_error "Template file not found at: $template_file"
        return 1
    fi

    mkdir -p "$user_service_dir"

    log "Installing user systemd service to: $target_file"
    sed -e "s|__WORKING_DIR__|$DIR|g" \
        -e "s|__EXEC_PATH__|$DIR/photo-gallery.sh|g" \
        "$template_file" > "$target_file"

    systemctl --user daemon-reload
    systemctl --user enable "$service_name"
    systemctl --user restart "$service_name"

    log "Service $service_name enabled and started."
    log "Check status with:   systemctl --user status $service_name"
    log "View live logs with: journalctl --user -u $service_name -f"
}

uninstall_systemd_service() {
    local service_name="photo-gallery.service"
    local user_service_dir="$HOME/.config/systemd/user"
    local target_file="$user_service_dir/$service_name"

    log "Stopping and disabling $service_name..."
    systemctl --user stop "$service_name" 2>/dev/null
    systemctl --user disable "$service_name" 2>/dev/null
    rm -f "$target_file"
    systemctl --user daemon-reload

    log "Systemd service uninstalled."
}

service_status() {
    local service_name="photo-gallery.service"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl --user status "$service_name" --no-pager
    else
        log "systemctl not available."
    fi
}

# ------------------------------------------------------------------------------
# Testing Helpers
# ------------------------------------------------------------------------------
test_camera_only() {
    check_dependencies || exit 1
    local test_file="$DIR/test_capture.jpg"
    log "Running test camera capture to: $test_file"
    if capture_photo "$test_file"; then
        log "Success! Test image saved at: $test_file"
    else
        log_error "Camera test failed. Please verify CAMERA_TYPE, CAMERA_DEVICE, or stream settings."
        exit 1
    fi
}

show_help() {
    cat << EOF
Photo Gallery (Life Museum) - 24/7 Homelab Camera Capture & Immich Sync

Usage: $0 [OPTION]

Commands:
  (no arguments)        Capture photo immediately and upload to Immich
  --now, -n             Capture photo immediately and upload to Immich
  --daemon, -d          Run in 24/7 background scheduler mode
  --test-camera, -tc    Test camera capture only (saves to ./test_capture.jpg)
  --test-immich, -ti    Verify Immich connectivity, API key, and album setup
  --install-service     Install and activate systemd 24/7 auto-start service
  --uninstall-service   Stop and remove systemd service
  --status              Show systemd service status
  --help, -h            Display this help message

Configuration:
  Settings are loaded from .env in this directory (or \$HOME/nixos-config/.env).
  See .env.example for all available configuration options.
EOF
}

# ------------------------------------------------------------------------------
# Main Dispatch
# ------------------------------------------------------------------------------
case "$1" in
    --daemon|-d)
        run_daemon
        ;;
    --now|-n|"")
        run_capture_and_upload
        ;;
    --test-camera|-tc)
        test_camera_only
        ;;
    --test-immich|-ti)
        immich_test_connection
        ;;
    --install-service)
        install_systemd_service
        ;;
    --uninstall-service)
        uninstall_systemd_service
        ;;
    --status)
        service_status
        ;;
    --help|-h)
        show_help
        ;;
    *)
        echo "Unknown option: $1"
        echo "Use '$0 --help' for available options."
        exit 1
        ;;
esac
