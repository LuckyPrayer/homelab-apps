#!/bin/bash
# Universal Container Restore Script (Config-Driven)
# Restores Docker containers/stacks from Backblaze B2 backups
# Reads restore configuration from each app's config.yml
#
# Usage: restore.sh <command> [options]
#   list                    List available snapshots
#   <app_name> [snapshot]   Restore specific app (default: latest)
#   all [snapshot]          Full restore of all apps
#   help                    Show this help
#
# Options:
#   --data-only             Only restore data, don't stop/start containers
#
# Environment variables (from /opt/scripts/backup.env):
#   B2_BUCKET: Backblaze B2 bucket name
#   B2_ACCOUNT_ID: Backblaze B2 Application Key ID
#   B2_ACCOUNT_KEY: Backblaze B2 Application Key
#   RESTIC_PASSWORD: Password for restic repository encryption
#   DISCORD_WEBHOOK_URL: Optional Discord webhook for notifications
#   HOSTNAME_PREFIX: Prefix for backup paths (default: hostname)

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_DIR="${APPS_DIR:-$(dirname "$SCRIPT_DIR")}"

# Source environment file if it exists
if [[ -f /opt/scripts/backup.env ]]; then
    # shellcheck disable=SC1091
    source /opt/scripts/backup.env
fi

COMMAND="${1:-help}"
SNAPSHOT_ID="${2:-latest}"
DATA_ONLY=false

# Check for --data-only flag
for arg in "$@"; do
    if [[ "$arg" == "--data-only" ]]; then
        DATA_ONLY=true
        [[ "${2:-}" == "--data-only" ]] && SNAPSHOT_ID="${3:-latest}"
    fi
done

HOSTNAME_PREFIX="${HOSTNAME_PREFIX:-$(hostname)}"
RESTORE_DIR="${RESTORE_DIR:-/opt/backups/restore-temp-$$}"
mkdir -p "${RESTORE_DIR}"
export TMPDIR="${RESTORE_DIR}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
START_TIME=$(date +%s)

# =============================================================================
# Colors and Logging
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2; }
log_header() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

# =============================================================================
# YAML Config Helpers
# =============================================================================

check_yq() {
    if ! command -v yq &>/dev/null; then
        log_error "yq is required but not installed. Install with: apt install yq"
        exit 1
    fi
}

get_config() {
    local app_name="$1"
    local key="$2"
    local default="${3:-}"
    
    local config_file="$APPS_DIR/$app_name/config.yml"
    if [[ ! -f "$config_file" ]]; then
        echo "$default"
        return
    fi
    
    local value
    value=$(yq -r "$key // \"$default\"" "$config_file" 2>/dev/null) || value="$default"
    
    if [[ "$value" == "null" ]] || [[ -z "$value" ]]; then
        echo "$default"
    else
        echo "$value"
    fi
}

# =============================================================================
# Prerequisites
# =============================================================================

check_prerequisites() {
    local missing=()
    
    for cmd in restic docker curl jq yq; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        exit 1
    fi
    
    if [[ -z "${B2_BUCKET:-}" ]] || [[ -z "${B2_ACCOUNT_ID:-}" ]] || \
       [[ -z "${B2_ACCOUNT_KEY:-}" ]] || [[ -z "${RESTIC_PASSWORD:-}" ]]; then
        log_error "B2/Restic credentials not set in environment"
        exit 1
    fi
}

setup_restic_env() {
    export RESTIC_REPOSITORY="b2:${B2_BUCKET}:${HOSTNAME_PREFIX}"
    export RESTIC_PASSWORD="${RESTIC_PASSWORD}"
    export B2_ACCOUNT_ID="${B2_ACCOUNT_ID}"
    export B2_ACCOUNT_KEY="${B2_ACCOUNT_KEY}"
}

# =============================================================================
# App Discovery
# =============================================================================

discover_apps() {
    for app_dir in "$APPS_DIR"/*/; do
        [[ ! -d "$app_dir" ]] && continue
        
        local app_name
        app_name=$(basename "$app_dir")
        [[ "$app_name" == "scripts" ]] && continue
        
        [[ ! -f "${app_dir}/config.yml" ]] && continue
        
        echo "$app_name"
    done | sort -u
}

get_compose_dir() {
    local app_name="$1"
    
    local install_path
    install_path=$(get_config "$app_name" ".paths.install_path" "")
    
    if [[ -n "$install_path" ]] && [[ -d "$install_path" ]]; then
        echo "$install_path"
        return
    fi
    
    if [[ -L "/opt/stacks/$app_name" ]]; then
        readlink -f "/opt/stacks/$app_name"
        return
    fi
    
    echo "$APPS_DIR/$app_name"
}

get_parent_dir() {
    local app_name="$1"
    
    local install_path
    install_path=$(get_config "$app_name" ".paths.install_path" "")
    
    if [[ -n "$install_path" ]]; then
        dirname "$install_path"
        return
    fi
    
    echo "$APPS_DIR"
}

# =============================================================================
# Container Management
# =============================================================================

stop_app() {
    local app_name="$1"
    local compose_dir
    compose_dir=$(get_compose_dir "$app_name")
    
    log_info "Stopping app: $app_name..."
    
    [[ ! -d "$compose_dir" ]] && return 0
    
    if [[ ! -f "${compose_dir}/docker-compose.yml" ]] && \
       [[ ! -f "${compose_dir}/docker-compose.yaml" ]]; then
        log_warn "No docker-compose.yml found in $compose_dir"
        return 0
    fi
    
    cd "$compose_dir"
    docker compose down 2>/dev/null || log_warn "App may not be running"
    sleep 3
}

start_app() {
    local app_name="$1"
    local compose_dir
    compose_dir=$(get_compose_dir "$app_name")
    
    log_info "Starting app: $app_name..."
    
    if [[ ! -d "$compose_dir" ]]; then
        log_error "Compose directory not found: $compose_dir"
        return 1
    fi
    
    cd "$compose_dir"
    
    # Run prepare script if exists (e.g., Harbor)
    if [[ -x "${compose_dir}/prepare" ]]; then
        log_info "Running prepare script..."
        ./prepare 2>&1 || log_warn "Prepare script failed"
    fi
    
    # Check for infisical secrets
    local infisical_path
    infisical_path=$(get_config "$app_name" ".secrets.infisical_path" "")
    
    if [[ -n "$infisical_path" ]] && [[ -x /usr/local/bin/infisical-run ]]; then
        log_info "Starting with infisical-run..."
        /usr/local/bin/infisical-run docker compose up -d 2>&1
    else
        docker compose up -d 2>&1
    fi
    
    # Wait for startup
    local retries=20
    while [[ $retries -gt 0 ]]; do
        sleep 3
        if docker compose ps 2>/dev/null | grep -qE "running|Up"; then
            log_info "App $app_name started successfully"
            return 0
        fi
        ((retries--))
    done
    
    log_warn "App startup timed out, may still be initializing"
    return 0
}

# =============================================================================
# Restore Functions
# =============================================================================

list_snapshots() {
    check_prerequisites
    setup_restic_env
    
    log_header "Available Snapshots"
    log_info "Repository: b2:${B2_BUCKET}:${HOSTNAME_PREFIX}"
    echo ""
    
    restic snapshots --host "${HOSTNAME_PREFIX}" 2>&1 || {
        log_error "Failed to list snapshots"
        return 1
    }
}

get_latest_snapshot() {
    local app_name="${1:-}"
    setup_restic_env
    
    local snapshot
    if [[ -n "$app_name" ]]; then
        snapshot=$(restic snapshots --host "${HOSTNAME_PREFIX}" --tag "${app_name}" --json 2>/dev/null | \
                   jq -r 'sort_by(.time) | last | .short_id // empty')
    else
        snapshot=$(restic snapshots --host "${HOSTNAME_PREFIX}" --json 2>/dev/null | \
                   jq -r 'sort_by(.time) | last | .short_id // empty')
    fi
    
    if [[ -z "$snapshot" ]]; then
        log_error "No snapshots found for ${app_name:-all apps}"
        return 1
    fi
    
    echo "$snapshot"
}

run_pre_restore() {
    local app_name="$1"
    local compose_dir
    compose_dir=$(get_compose_dir "$app_name")
    
    local hook
    hook=$(get_config "$app_name" ".restore.pre_restore" "")
    
    if [[ -n "$hook" ]] && [[ "$hook" != "null" ]]; then
        log_info "Running pre-restore hook..."
        cd "$compose_dir" 2>/dev/null || cd "$APPS_DIR/$app_name"
        bash -c "$hook" 2>&1 || log_warn "Pre-restore hook failed"
    fi
}

run_post_restore() {
    local app_name="$1"
    local compose_dir
    compose_dir=$(get_compose_dir "$app_name")
    
    local hook
    hook=$(get_config "$app_name" ".restore.post_restore" "")
    
    if [[ -n "$hook" ]] && [[ "$hook" != "null" ]]; then
        log_info "Running post-restore hook..."
        cd "$compose_dir"
        bash -c "$hook" 2>&1 || log_warn "Post-restore hook failed"
    fi
}

restore_app() {
    local app_name="$1"
    local snapshot_id="${2:-latest}"
    
    check_prerequisites
    setup_restic_env
    
    log_header "Restoring App: $app_name"
    log_info "Snapshot: $snapshot_id"
    log_info "Host: $HOSTNAME_PREFIX"
    
    send_discord_notification "$app_name" "🔄 Starting restore from snapshot \`${snapshot_id}\`..." "info"
    
    # Check if restore is enabled
    local restore_enabled
    restore_enabled=$(get_config "$app_name" ".restore.enabled" "true")
    if [[ "$restore_enabled" != "true" ]]; then
        log_warn "Restore is disabled for $app_name in config.yml"
        return 0
    fi
    
    # Get actual snapshot ID
    if [[ "$snapshot_id" == "latest" ]]; then
        snapshot_id=$(get_latest_snapshot "$app_name") || {
            log_error "No snapshot found for $app_name"
            return 1
        }
        log_info "Using latest snapshot: $snapshot_id"
    fi
    
    local compose_dir
    compose_dir=$(get_compose_dir "$app_name")
    local parent_dir
    parent_dir=$(get_parent_dir "$app_name")
    
    # Stop app if not data-only mode
    if [[ "$DATA_ONLY" == "false" ]] && [[ -d "$compose_dir" ]]; then
        stop_app "$app_name"
    elif [[ "$DATA_ONLY" == "true" ]]; then
        log_info "Data-only mode: skipping container stop"
    fi
    
    # Pre-restore hook
    run_pre_restore "$app_name"
    
    # Create temp restore directory
    mkdir -p "${RESTORE_DIR}"
    cd "${RESTORE_DIR}"
    
    # Download from B2
    log_info "Downloading backup from B2..."
    restic restore "${snapshot_id}" \
        --target "${RESTORE_DIR}" \
        --include "/opt/backups/${app_name}" 2>&1 || {
            log_error "Failed to download from B2"
            rm -rf "${RESTORE_DIR}"
            return 1
        }
    
    # Find backup archive
    local backup_file
    backup_file=$(ls -1t "${RESTORE_DIR}/opt/backups/${app_name}/"*_data_*.tar.gz 2>/dev/null | head -1)
    
    if [[ -z "$backup_file" ]] || [[ ! -f "$backup_file" ]]; then
        log_error "No backup archive found in snapshot"
        rm -rf "${RESTORE_DIR}"
        return 1
    fi
    
    log_info "Found backup: $(basename "$backup_file")"
    
    # Backup existing data
    if [[ -d "$compose_dir" ]]; then
        log_info "Backing up existing data..."
        mv "$compose_dir" "${compose_dir}.old.${TIMESTAMP}" 2>/dev/null || true
    fi
    
    # Extract backup
    log_info "Extracting backup archive..."
    mkdir -p "$parent_dir"
    tar xzf "$backup_file" -C "$parent_dir" 2>&1 || {
        log_error "Failed to extract backup"
        # Restore old data
        [[ -d "${compose_dir}.old.${TIMESTAMP}" ]] && mv "${compose_dir}.old.${TIMESTAMP}" "$compose_dir"
        rm -rf "${RESTORE_DIR}"
        return 1
    }
    
    # Restore database if exists
    local db_backup
    db_backup=$(ls -1t "${RESTORE_DIR}/opt/backups/${app_name}/"*_postgres_*.sql.gz 2>/dev/null | head -1)
    if [[ -f "$db_backup" ]]; then
        log_info "Database backup found, copying for manual restore"
        cp "$db_backup" "${compose_dir}/" 2>/dev/null || true
    fi
    
    # Post-restore hook
    run_post_restore "$app_name"
    
    # Cleanup
    log_info "Cleaning up..."
    rm -rf "${RESTORE_DIR}"
    rm -rf "${compose_dir}.old.${TIMESTAMP}"
    
    # Start app if not data-only mode
    if [[ "$DATA_ONLY" == "false" ]]; then
        start_app "$app_name"
    else
        log_info "Data-only mode: skipping container start"
    fi
    
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - START_TIME))
    local duration_fmt
    duration_fmt=$(printf '%02d:%02d:%02d' $((duration/3600)) $((duration%3600/60)) $((duration%60)))
    
    log_header "Restore Complete: $app_name"
    log_info "Snapshot: $snapshot_id"
    log_info "Duration: $duration_fmt"
    
    send_discord_notification "$app_name" "✅ Restore completed\\n\\n**Snapshot:** \`${snapshot_id}\`\\n**Duration:** ${duration_fmt}" "success"
}

restore_all() {
    local snapshot_id="${1:-latest}"
    
    check_prerequisites
    setup_restic_env
    
    log_header "Full Restore from B2"
    log_info "Host: $HOSTNAME_PREFIX"
    
    send_discord_notification "all" "🔄 Starting full restore on ${HOSTNAME_PREFIX}" "info"
    
    # Get restore priority from apps
    local restore_order=()
    
    while IFS= read -r app_name; do
        [[ -z "$app_name" ]] && continue
        
        local priority
        priority=$(get_config "$app_name" ".restore.priority" "50")
        restore_order+=("$priority:$app_name")
    done < <(discover_apps)
    
    # Sort by priority (lower first)
    IFS=$'\n' restore_order=($(sort -t: -k1 -n <<<"${restore_order[*]}"))
    unset IFS
    
    local total_success=0
    local total_failed=0
    
    for entry in "${restore_order[@]}"; do
        local app_name="${entry#*:}"
        
        # Reset START_TIME for each app
        START_TIME=$(date +%s)
        
        if restore_app "$app_name" "$snapshot_id"; then
            ((total_success++))
        else
            ((total_failed++))
        fi
    done
    
    log_header "Full Restore Summary"
    log_info "Successful: $total_success"
    log_info "Failed: $total_failed"
    
    if [[ $total_failed -gt 0 ]]; then
        send_discord_notification "all" "⚠️ Restore completed with errors\\n\\n**Success:** ${total_success}\\n**Failed:** ${total_failed}" "warning"
        return 1
    fi
    
    send_discord_notification "all" "✅ Full restore completed\\n\\n**Apps:** ${total_success}" "success"
}

send_discord_notification() {
    local app_name="$1"
    local message="$2"
    local level="${3:-info}"
    
    [[ -z "${DISCORD_WEBHOOK_URL:-}" ]] && return 0
    
    local color
    case "$level" in
        success) color="3066993" ;;
        error)   color="15158332" ;;
        warning) color="15844367" ;;
        *)       color="3447003" ;;
    esac
    
    curl -s -H "Content-Type: application/json" -d "{
        \"embeds\": [{
            \"title\": \"🔄 Restore: ${app_name}\",
            \"description\": \"${message}\",
            \"color\": ${color},
            \"footer\": {\"text\": \"Host: ${HOSTNAME_PREFIX}\"},
            \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"
        }]
    }" "${DISCORD_WEBHOOK_URL}" >/dev/null 2>&1 || true
}

show_help() {
    cat <<EOF
Universal Container Restore Script (Config-Driven)
Reads restore configuration from each app's config.yml

Usage: $(basename "$0") <command> [options]

Commands:
  list                         List available snapshots
  <app_name> [snapshot_id]     Restore specific app (default: latest)
  all [snapshot_id]            Full restore of all apps
  help                         Show this help

Options:
  --data-only                  Only restore data, don't stop/start containers

Environment Variables (from /opt/scripts/backup.env):
  B2_BUCKET             Backblaze B2 bucket name
  B2_ACCOUNT_ID         Backblaze B2 Application Key ID
  B2_ACCOUNT_KEY        Backblaze B2 Application Key
  RESTIC_PASSWORD       Restic repository encryption password
  DISCORD_WEBHOOK_URL   Optional Discord webhook
  HOSTNAME_PREFIX       Prefix for backup paths (default: hostname)
  APPS_DIR              Apps directory (default: parent of scripts/)

App config.yml Example:
  restore:
    enabled: true
    priority: 10              # Lower = restore first
    pre_restore: ""           # Command to run before restore
    post_restore: |           # Command to run after restore
      chown -R 1000:1000 ./data

Examples:
  $(basename "$0") list                    # List snapshots
  $(basename "$0") vaultwarden             # Restore from latest
  $(basename "$0") vaultwarden abc123      # Restore specific snapshot
  $(basename "$0") all                     # Restore all apps
  $(basename "$0") vaultwarden --data-only # Data only, no restart

Host: ${HOSTNAME_PREFIX}
Repository: b2:${B2_BUCKET:-<not set>}:${HOSTNAME_PREFIX}
EOF
}

# =============================================================================
# Main Entry Point
# =============================================================================

main() {
    check_yq
    
    case "${COMMAND}" in
        help|--help|-h)
            show_help
            ;;
        list)
            list_snapshots
            ;;
        all)
            restore_all "$SNAPSHOT_ID"
            ;;
        *)
            restore_app "$COMMAND" "$SNAPSHOT_ID"
            ;;
    esac
}

main
