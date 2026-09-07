#!/usr/bin/env bash
# ==============================================================================
# Auto-VC: 24/7 Automated Git Version Control Daemon
# ==============================================================================
# Continuously monitors a target repository, automatically staging changes,
# generating structured commits, and pushing to the remote repository.
# ==============================================================================

set -o pipefail

# Determine script root directory
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ENV_FILE="$DIR/.env"

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
REPO_PATH="${REPO_PATH:-${FLINT_DIR:-$HOME/.config/flint}}"
GIT_BRANCH="${GIT_BRANCH:-main}"
GIT_REMOTE="${GIT_REMOTE:-origin}"
CHECK_INTERVAL="${CHECK_INTERVAL:-60}"
COMMIT_PREFIX="${COMMIT_PREFIX:-chore(auto-vc)}"
PULL_BEFORE_PUSH="${PULL_BEFORE_PUSH:-true}"
DRY_RUN="${DRY_RUN:-false}"
LOG_FILE="${LOG_FILE:-}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_github_deploy}"

# Set SSH command if specific deploy key exists and GIT_SSH_COMMAND not set
if [ -n "$SSH_KEY" ] && [ -f "$SSH_KEY" ] && [ -z "${GIT_SSH_COMMAND:-}" ]; then
    export GIT_SSH_COMMAND="ssh -i $SSH_KEY -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
fi

# Terminal colors (disabled if not connected to a tty)
if [ -t 1 ]; then
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    RED='\033[0;31m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    GREEN=''
    YELLOW=''
    BLUE=''
    RED=''
    CYAN=''
    BOLD=''
    NC=''
fi

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo -e "$msg"
    if [ -n "$LOG_FILE" ]; then
        mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
        echo "$msg" >> "$LOG_FILE"
    fi
}

log_info() {
    log "${CYAN}[INFO]${NC} $1"
}

log_success() {
    log "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    log "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    log "${RED}[ERROR]${NC} $1" >&2
}

# ------------------------------------------------------------------------------
# Signal Handling
# ------------------------------------------------------------------------------
RUNNING=true

cleanup() {
    log_info "Received shutdown signal. Stopping Auto-VC daemon cleanly..."
    RUNNING=false
    # Remove git lock file if present and stale
    if [ -f "$REPO_PATH/.git/index.lock" ]; then
        log_warn "Cleaning up stale git index.lock..."
        rm -f "$REPO_PATH/.git/index.lock" 2>/dev/null || true
    fi
    exit 0
}

trap cleanup SIGINT SIGTERM

# ------------------------------------------------------------------------------
# Git Helpers
# ------------------------------------------------------------------------------
verify_repo() {
    if [ ! -d "$REPO_PATH" ]; then
        log_error "Target directory '$REPO_PATH' does not exist!"
        return 1
    fi

    if ! git -C "$REPO_PATH" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        log_error "Directory '$REPO_PATH' is not a valid Git repository!"
        return 1
    fi

    # Mark directory as safe for git if running as a different user / systemd
    git config --global --add safe.directory "$REPO_PATH" 2>/dev/null || true

    return 0
}

has_uncommitted_changes() {
    local status
    status=$(git -C "$REPO_PATH" status --porcelain 2>/dev/null || true)
    [ -n "$status" ]
}

has_unpushed_commits() {
    local upstream branch unpushed
    branch=$(git -C "$REPO_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "$GIT_BRANCH")
    upstream="${GIT_REMOTE}/${branch}"

    # Check if upstream branch is tracked
    if ! git -C "$REPO_PATH" rev-parse --verify "$upstream" >/dev/null 2>&1; then
        # If upstream is not yet tracked, check if HEAD exists
        return 0
    fi

    unpushed=$(git -C "$REPO_PATH" cherry -v "$upstream" 2>/dev/null || true)
    [ -n "$unpushed" ]
}

# ------------------------------------------------------------------------------
# Sync Cycle
# ------------------------------------------------------------------------------
run_sync_cycle() {
    local changed_files branch commit_msg timestamp

    if ! verify_repo; then
        return 1
    fi

    branch=$(git -C "$REPO_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "$GIT_BRANCH")
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Step 1: Check for uncommitted changes
    if has_uncommitted_changes; then
        changed_files=$(git -C "$REPO_PATH" status --porcelain)
        local count
        count=$(echo "$changed_files" | wc -l)

        log_info "Detected ${BOLD}$count${NC} modified/untracked file(s) in $REPO_PATH:"
        echo "$changed_files" | head -n 10 | sed 's/^/  /'
        if [ "$count" -gt 10 ]; then
            echo "  ... and $((count - 10)) more"
        fi

        if [ "$DRY_RUN" = "true" ]; then
            log_warn "[DRY-RUN] Changes would be staged, committed, and pushed."
            return 0
        fi

        # Stage all changes
        log_info "Staging all changes (git add -A)..."
        if ! git -C "$REPO_PATH" add -A; then
            log_error "Failed to stage changes in '$REPO_PATH'."
            return 1
        fi

        # Build commit message
        commit_msg="${COMMIT_PREFIX}: automated backup ${timestamp}

Automated sync performed by Auto-VC on homelab.
Modified files:
${changed_files}"

        log_info "Committing changes..."
        if ! git -C "$REPO_PATH" commit -m "$commit_msg" >/dev/null 2>&1; then
            log_error "Failed to commit staged changes."
            return 1
        fi

        local commit_hash
        commit_hash=$(git -C "$REPO_PATH" rev-parse --short HEAD)
        log_success "Created commit ${BOLD}${commit_hash}${NC} on branch ${BOLD}${branch}${NC}."
    fi

    # Step 2: Push changes if there are unpushed commits
    if has_unpushed_commits || has_uncommitted_changes; then
        if [ "$DRY_RUN" = "true" ]; then
            log_warn "[DRY-RUN] Commits would be pushed to ${GIT_REMOTE}/${branch}."
            return 0
        fi

        # Pull rebase before push if enabled
        if [ "$PULL_BEFORE_PUSH" = "true" ]; then
            log_info "Pulling remote changes with rebase before pushing..."
            if ! git -C "$REPO_PATH" pull --rebase "$GIT_REMOTE" "$branch" >/dev/null 2>&1; then
                log_warn "Pull --rebase failed or network unreachable. Continuing to push attempt..."
            fi
        fi

        log_info "Pushing to ${BOLD}${GIT_REMOTE}/${branch}${NC}..."
        if git -C "$REPO_PATH" push "$GIT_REMOTE" "$branch" 2>&1; then
            log_success "Push completed successfully to ${BOLD}${GIT_REMOTE}/${branch}${NC}."
        else
            log_warn "Failed to push to remote (network down or auth issue). Will retry next cycle."
            return 1
        fi
    else
        log_info "Repository clean. No changes or unpushed commits."
    fi

    return 0
}

# ------------------------------------------------------------------------------
# CLI Dispatcher
# ------------------------------------------------------------------------------
usage() {
    echo -e "${BOLD}Auto-VC: 24/7 Automated Git Version Control Daemon${NC}"
    echo ""
    echo -e "${BOLD}Usage:${NC} $0 [OPTIONS]"
    echo ""
    echo -e "${BOLD}Options:${NC}"
    echo -e "  -d, --daemon            Run continuously in background daemon mode"
    echo -e "  -o, --run-once          Run one sync cycle and exit immediately (default)"
    echo -e "  -s, --status            Inspect current repository and sync status"
    echo -e "  -n, --dry-run           Check for changes without committing or pushing"
    echo -e "  -r, --repo <path>       Target repository path (default: $REPO_PATH)"
    echo -e "  -b, --branch <name>     Target branch (default: $GIT_BRANCH)"
    echo -e "  -i, --interval <sec>    Daemon check interval in seconds (default: $CHECK_INTERVAL)"
    echo -e "  -h, --help              Show this help message"
    echo ""
    exit 0
}

MODE="once"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--daemon)
            MODE="daemon"
            shift
            ;;
        -o|--run-once)
            MODE="once"
            shift
            ;;
        -s|--status)
            MODE="status"
            shift
            ;;
        -n|--dry-run)
            DRY_RUN="true"
            shift
            ;;
        -r|--repo)
            REPO_PATH="$2"
            shift 2
            ;;
        -b|--branch)
            GIT_BRANCH="$2"
            shift 2
            ;;
        -i|--interval)
            CHECK_INTERVAL="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo -e "${RED}Unknown option:${NC} $1" >&2
            usage
            ;;
    esac
done

# ------------------------------------------------------------------------------
# Mode Execution
# ------------------------------------------------------------------------------
case "$MODE" in
    status)
        echo -e "${BLUE}${BOLD}=== Auto-VC Status ===${NC}"
        echo -e "  Repository: ${BOLD}$REPO_PATH${NC}"
        echo -e "  Branch:     ${BOLD}$GIT_BRANCH${NC}"
        echo -e "  Remote:     ${BOLD}$GIT_REMOTE${NC}"
        echo -e "  Interval:   ${BOLD}${CHECK_INTERVAL}s${NC}"
        echo ""
        if verify_repo; then
            if has_uncommitted_changes; then
                echo -e "${YELLOW}Uncommitted changes detected:${NC}"
                git -C "$REPO_PATH" status -s
            else
                echo -e "${GREEN}Working directory is clean.${NC}"
            fi

            if has_unpushed_commits; then
                echo -e "${YELLOW}Unpushed commits present.${NC}"
            else
                echo -e "${GREEN}Up to date with remote.${NC}"
            fi
        fi
        ;;

    once)
        log_info "Running single Auto-VC sync cycle on $REPO_PATH..."
        run_sync_cycle || exit 1
        ;;

    daemon)
        log_info "${BOLD}Starting Auto-VC daemon 24/7${NC} (repo: $REPO_PATH, interval: ${CHECK_INTERVAL}s)..."
        while $RUNNING; do
            run_sync_cycle || true
            sleep "$CHECK_INTERVAL" &
            wait $!
        done
        ;;
esac
