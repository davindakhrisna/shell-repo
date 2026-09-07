#!/usr/bin/env bash
# ==============================================================================
# WANE: Warning & Error System Watcher & Log Inspector
# ==============================================================================
# Continuously monitors system warnings and errors from systemd journald,
# logs them to wane-log, and provides a rich CLI to inspect, filter, and clear.
# ==============================================================================

set -o pipefail

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ENV_FILE="$DIR/.env"
[ -f "$ENV_FILE" ] && source "$ENV_FILE"

DEFAULT_LOG_PATH="/var/log/wane/wane-log"
FALLBACK_LOG_PATH="$HOME/.local/state/wane/wane-log"

# Select log file location
if [ -n "${WANE_LOG_FILE:-}" ]; then
    LOG_FILE="$WANE_LOG_FILE"
elif [ -w "/var/log" ] || [ -d "/var/log/wane" ] || [ "$EUID" -eq 0 ]; then
    LOG_FILE="$DEFAULT_LOG_PATH"
else
    LOG_FILE="$FALLBACK_LOG_PATH"
fi

MAX_LOG_SIZE_MB="${WANE_MAX_SIZE_MB:-50}"

# Colors
if [ -t 1 ]; then
    RED='\033[0;31m'
    BOLD_RED='\033[1;31m'
    YELLOW='\033[0;33m'
    BOLD_YELLOW='\033[1;33m'
    GREEN='\033[0;32m'
    BOLD_GREEN='\033[1;32m'
    BLUE='\033[0;34m'
    BOLD_BLUE='\033[1;34m'
    CYAN='\033[0;36m'
    BOLD_CYAN='\033[1;36m'
    MAGENTA='\033[0;35m'
    BOLD='\033[1m'
    DIM='\033[2m'
    NC='\033[0m' # No Color
else
    RED=''
    BOLD_RED=''
    YELLOW=''
    BOLD_YELLOW=''
    GREEN=''
    BOLD_GREEN=''
    BLUE=''
    BOLD_BLUE=''
    CYAN=''
    BOLD_CYAN=''
    MAGENTA=''
    BOLD=''
    DIM=''
    NC=''
fi

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------
ensure_log_dir() {
    local dir
    dir="$(dirname "$LOG_FILE")"
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir" 2>/dev/null || {
            echo -e "${RED}[ERROR]${NC} Cannot create directory '$dir'. Try running with sudo or set WANE_LOG_FILE." >&2
            exit 1
        }
        chmod 775 "$dir" 2>/dev/null || true
    fi
}

colorize_line() {
    local line="$1"
    # Format: [TIMESTAMP] [TYPE] [UNIT] MESSAGE
    if [[ "$line" =~ ^(\[[0-9T: -]+\])[[:space:]]*(\[(ERROR|ERR|CRIT|ALERT|EMERG)\])[[:space:]]*(\[[^]]+\])[[:space:]]*(.*)$ ]]; then
        local ts="${BASH_REMATCH[1]}"
        local type="${BASH_REMATCH[2]}"
        local unit="${BASH_REMATCH[4]}"
        local msg="${BASH_REMATCH[5]}"
        echo -e "${CYAN}${ts}${NC} ${BOLD_RED}${type}${NC} ${BOLD_BLUE}${unit}${NC} ${msg}"
    elif [[ "$line" =~ ^(\[[0-9T: -]+\])[[:space:]]*(\[(WARN|WARNING)\])[[:space:]]*(\[[^]]+\])[[:space:]]*(.*)$ ]]; then
        local ts="${BASH_REMATCH[1]}"
        local type="${BASH_REMATCH[2]}"
        local unit="${BASH_REMATCH[4]}"
        local msg="${BASH_REMATCH[5]}"
        echo -e "${CYAN}${ts}${NC} ${BOLD_YELLOW}${type}${NC} ${BOLD_BLUE}${unit}${NC} ${msg}"
    else
        echo "$line"
    fi
}

# ------------------------------------------------------------------------------
# CLI Command: --clear
# ------------------------------------------------------------------------------
cmd_clear() {
    if [ ! -f "$LOG_FILE" ]; then
        echo -e "${YELLOW}No wane-log found at:${NC} $LOG_FILE (nothing to clear)"
        exit 0
    fi

    if [ ! -w "$LOG_FILE" ]; then
        echo -e "${RED}[ERROR]${NC} Permission denied: Cannot write to $LOG_FILE. Try: sudo wane --clear" >&2
        exit 1
    fi

    local lines_before
    lines_before=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
    : > "$LOG_FILE"
    echo -e "${BOLD_GREEN}✓ Cleared wane-log${NC} (${lines_before} entries purged) at: ${CYAN}$LOG_FILE${NC}"
}

# ------------------------------------------------------------------------------
# CLI Command: --status
# ------------------------------------------------------------------------------
cmd_status() {
    echo -e "${BOLD_BLUE}====================================================${NC}"
    echo -e "${BOLD}   📊 WANE: System Warning & Error Watcher Status   ${NC}"
    echo -e "${BOLD_BLUE}====================================================${NC}"
    echo -e "  Log File:       ${BOLD}$LOG_FILE${NC}"

    if [ -f "$LOG_FILE" ]; then
        local size entries errors warnings
        size=$(du -h "$LOG_FILE" | cut -f1)
        entries=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
        errors=$(grep -c -E '\[(ERROR|ERR|CRIT|ALERT|EMERG)\]' "$LOG_FILE" 2>/dev/null || echo 0)
        warnings=$(grep -c -E '\[(WARN|WARNING)\]' "$LOG_FILE" 2>/dev/null || echo 0)

        echo -e "  Log Size:       ${CYAN}$size${NC}"
        echo -e "  Total Entries:  ${BOLD}$entries${NC}"
        echo -e "  Total Errors:   ${BOLD_RED}$errors${NC}"
        echo -e "  Total Warnings: ${BOLD_YELLOW}$warnings${NC}"
    else
        echo -e "  Log File:       ${YELLOW}Not yet created${NC}"
    fi

    echo ""
    echo -e "${BOLD}Daemon Status:${NC}"
    if systemctl is-active --quiet wane-watcher.service 2>/dev/null; then
        echo -e "  Service:        ${BOLD_GREEN}● active (running)${NC} [systemd: wane-watcher.service]"
    elif pgrep -f "wane.*--daemon" >/dev/null 2>&1; then
        echo -e "  Process:        ${BOLD_GREEN}● active (running as process)${NC}"
    else
        echo -e "  Service:        ${YELLOW}○ inactive (not running)${NC}"
    fi
    echo -e "${BOLD_BLUE}====================================================${NC}"
}

# ------------------------------------------------------------------------------
# CLI Command: --show <number> <order> <type>
# ------------------------------------------------------------------------------
cmd_show() {
    local count="20"
    local order="desc" # desc = newest first; asc = oldest first
    local type="all"   # all, error/err, warn/warning

    # Parse flexible arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            [0-9]*)
                count="$1"
                ;;
            asc|oldest)
                order="asc"
                ;;
            desc|latest|newest)
                order="desc"
                ;;
            error|err|errors)
                type="error"
                ;;
            warn|warning|warnings)
                type="warn"
                ;;
            all)
                type="all"
                ;;
            -n|--number)
                count="$2"
                shift
                ;;
            -o|--order)
                order="$2"
                shift
                ;;
            -t|--type)
                type="$2"
                shift
                ;;
        esac
        shift
    done

    if [ ! -f "$LOG_FILE" ] || [ ! -s "$LOG_FILE" ]; then
        echo -e "${YELLOW}wane-log is empty or not yet created at:${NC} $LOG_FILE"
        exit 0
    fi

    echo -e "${BOLD}Showing ${CYAN}${count}${NC} ${BOLD}entries [Order: ${BOLD_BLUE}${order}${NC}${BOLD}, Type: ${BOLD_YELLOW}${type}${NC}${BOLD}] from:${NC} ${DIM}$LOG_FILE${NC}"
    echo -e "${DIM}--------------------------------------------------------------------------------${NC}"

    # Filter by type
    local filter_cmd="cat"
    if [ "$type" = "error" ] || [ "$type" = "err" ]; then
        filter_cmd="grep -E '\[(ERROR|ERR|CRIT|ALERT|EMERG)\]'"
    elif [ "$type" = "warn" ] || [ "$type" = "warning" ]; then
        filter_cmd="grep -E '\[(WARN|WARNING)\]'"
    fi

    # Read and order entries
    local lines
    if [ "$order" = "desc" ]; then
        # Newest first: reverse file with tac, then head
        lines=$(eval "$filter_cmd \"$LOG_FILE\"" | tac | head -n "$count")
    else
        # Oldest first: normal order with head
        lines=$(eval "$filter_cmd \"$LOG_FILE\"" | head -n "$count")
    fi

    if [ -z "$lines" ]; then
        echo -e "${GREEN}No matching ${type} entries found in wane-log.${NC}"
        exit 0
    fi

    while IFS= read -r line; do
        colorize_line "$line"
    done <<< "$lines"

    echo -e "${DIM}--------------------------------------------------------------------------------${NC}"
}

# ------------------------------------------------------------------------------
# CLI Command: --follow
# ------------------------------------------------------------------------------
cmd_follow() {
    if [ ! -f "$LOG_FILE" ]; then
        ensure_log_dir
        touch "$LOG_FILE"
    fi

    echo -e "${BOLD_CYAN}Streaming live wane-log${NC} (${DIM}$LOG_FILE${NC}) ... [Press Ctrl+C to exit]"
    tail -n 20 -F "$LOG_FILE" | while IFS= read -r line; do
        colorize_line "$line"
    done
}

# ------------------------------------------------------------------------------
# Daemon: --daemon
# ------------------------------------------------------------------------------
RUNNING=true

cleanup_daemon() {
    echo -e "\n[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] WANE watcher daemon stopping..."
    RUNNING=false
    exit 0
}

trap cleanup_daemon SIGINT SIGTERM

cmd_daemon() {
    ensure_log_dir
    touch "$LOG_FILE"
    chmod 664 "$LOG_FILE" 2>/dev/null || true

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Starting WANE watcher daemon 24/7..."
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Target log file: $LOG_FILE"

    # Backfill last 25 warnings/errors on daemon start if log is empty
    if [ ! -s "$LOG_FILE" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Populating initial boot errors and warnings..."
        journalctl -b -p 0..4 -o json -n 25 --no-pager 2>/dev/null | jq --unbuffered -r '
            (if (.PRIORITY | tonumber) <= 3 then "ERROR" else "WARN" end) as $type |
            "[\((.__REALTIME_TIMESTAMP | tonumber / 1000000 | strftime("%Y-%m-%d %H:%M:%S")))] [\($type)] [\(._SYSTEMD_UNIT // .SYSLOG_IDENTIFIER // "system")] \(.MESSAGE)"
        ' >> "$LOG_FILE" 2>/dev/null || true
    fi

    # Continuous streaming loop from journald
    while $RUNNING; do
        # Stream priorities 0 through 4 (emerg, alert, crit, err, warning) in real time
        journalctl -f -p 0..4 -o json -n 0 2>/dev/null | jq --unbuffered -r '
            (if (.PRIORITY | tonumber) <= 3 then "ERROR" else "WARN" end) as $type |
            "[\((.__REALTIME_TIMESTAMP | tonumber / 1000000 | strftime("%Y-%m-%d %H:%M:%S")))] [\($type)] [\(._SYSTEMD_UNIT // .SYSLOG_IDENTIFIER // "system")] \(.MESSAGE)"
        ' >> "$LOG_FILE" || true

        # Rotate if log exceeds MAX_LOG_SIZE_MB
        if [ -f "$LOG_FILE" ]; then
            local current_size_kb
            current_size_kb=$(du -k "$LOG_FILE" 2>/dev/null | cut -f1 || echo 0)
            local max_size_kb=$((MAX_LOG_SIZE_MB * 1024))
            if [ "$current_size_kb" -gt "$max_size_kb" ]; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Log size ($current_size_kb KB) exceeded $MAX_LOG_SIZE_MB MB. Rotating..."
                tail -n 10000 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
                chmod 664 "$LOG_FILE" 2>/dev/null || true
            fi
        fi

        sleep 2
    done
}

# ------------------------------------------------------------------------------
# Help & Usage
# ------------------------------------------------------------------------------
usage() {
    echo -e "${BOLD_BLUE}================================================================${NC}"
    echo -e "${BOLD}   👁️  WANE: Warning & Error System Watcher & Inspector        ${NC}"
    echo -e "${BOLD_BLUE}================================================================${NC}"
    echo -e "${BOLD}Usage:${NC}"
    echo -e "  ${BOLD_CYAN}wane --show${NC} [number] [order] [type]   Peek at collected warnings and errors"
    echo -e "  ${BOLD_CYAN}wane --clear${NC}                          Clear / truncate the wane-log"
    echo -e "  ${BOLD_CYAN}wane --status${NC}                         Show log statistics and watcher state"
    echo -e "  ${BOLD_CYAN}wane --follow${NC}                         Live stream new entries in real time"
    echo -e "  ${BOLD_CYAN}wane --daemon${NC}                         Run background collection daemon"
    echo -e "  ${BOLD_CYAN}wane --help${NC}                           Show this help menu"
    echo ""
    echo -e "${BOLD}Show Parameters:${NC}"
    echo -e "  ${BOLD}<number>${NC}    Number of entries to display (default: ${CYAN}20${NC})"
    echo -e "  ${BOLD}<order>${NC}     Sort order: ${BOLD_BLUE}desc${NC} (newest first, default) | ${BOLD_BLUE}asc${NC} (oldest first)"
    echo -e "  ${BOLD}<type>${NC}      Filter: ${BOLD_YELLOW}all${NC} (default) | ${BOLD_RED}error${NC} (errors only) | ${BOLD_YELLOW}warn${NC} (warnings only)"
    echo ""
    echo -e "${BOLD}Examples:${NC}"
    echo -e "  ${DIM}# Show last 20 warnings and errors (newest first):${NC}"
    echo -e "  ${BOLD}wane --show${NC}"
    echo ""
    echo -e "  ${DIM}# Quick peek at the latest 10 errors only:${NC}"
    echo -e "  ${BOLD}wane --show 10 desc error${NC}"
    echo ""
    echo -e "  ${DIM}# View 50 oldest warnings:${NC}"
    echo -e "  ${BOLD}wane --show 50 asc warn${NC}"
    echo ""
    echo -e "  ${DIM}# Clear the log file:${NC}"
    echo -e "  ${BOLD}wane --clear${NC}"
    echo ""
    echo -e "  ${DIM}# View log stats and error counts:${NC}"
    echo -e "  ${BOLD}wane --status${NC}"
    echo -e "${BOLD_BLUE}================================================================${NC}"
    exit 0
}

# ------------------------------------------------------------------------------
# Dispatcher
# ------------------------------------------------------------------------------
case "${1:-}" in
    --clear|-c|clear)
        cmd_clear
        ;;
    --status|status)
        cmd_status
        ;;
    --show|-s|show)
        shift
        cmd_show "$@"
        ;;
    --follow|-f|follow)
        cmd_follow
        ;;
    --daemon|-d|daemon)
        cmd_daemon
        ;;
    --help|-h|help|"")
        if [ $# -eq 0 ]; then
            # Default to showing recent entries if run without arguments
            cmd_show 20 desc all
        else
            usage
        fi
        ;;
    *)
        # If arguments match show options (e.g. wane 10 desc error)
        cmd_show "$@"
        ;;
esac
