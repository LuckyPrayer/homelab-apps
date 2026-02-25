#!/bin/bash
# Universal Container Backup Script (Config-Driven)
# Backs up Docker containers/stacks using restic with Backblaze B2
# Reads backup configuration from each app's config.yml
#
# Usage: backup.sh <app_name|all> [backup_type]
#   app_name: Name of the app to backup, or "all" for all apps
#   backup_type: full (default)
#
# Environment variables (from /opt/scripts/backup.env):
#   BACKUP_DIR: Base directory for backups (default: /opt/backups)
#   B2_BUCKET: Backblaze B2 bucket for offsite backup
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

APP_NAME="${1:-}"
BACKUP_TYPE="${2:-full}"
BACKUP_DIR="${BACKUP_DIR:-/opt/backups}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
HOSTNAME_PREFIX="${HOSTNAME_PREFIX:-$(hostname)}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
START_TIME=$(date +%s)

# Ensure restic uses disk storage
export TMPDIR="${BACKUP_DIR}"

# Timeout settings
RESTIC_TIMEOUT="${RESTIC_TIMEOUT:-1800}"
LOCK_TIMEOUT="${LOCK_TIMEOUT:-300}"

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
# YAML Config Helpers (using yq)
# =============================================================================

# Check if yq is available
check_yq() {
    if ! command -v yq &>/dev/null; then
        log_error "yq is required but not installed. Install with: apt install yq"
        exit 1
    fi
}

# Get value from app config.yml
# Usage: get_config app_name ".key.path" "default_value"
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
    
    # Handle null/empty values
    if [[ "$value" == "null" ]] || [[ -z "$value" ]]; then
        echo "$default"
    else
        echo "$value"
    fi
}

# Get array from config (one item per line)
# Usage: get_config_array app_name ".backup.paths"
get_config_array() {
    local app_name="$1"
    local key="$2"
    
    local config_file="$APPS_DIR/$app_name/config.yml"
    if [[ ! -f "$config_file" ]]; then
        return
    fi
    
    yq -r "$key[]? // empty" "$config_file" 2>/dev/null || true
}

# =============================================================================
# App Discovery Functions
# =============================================================================

# Discover all apps with backup enabled
discover_backup_apps() {
    local apps=()
    
    for app_dir in "$APPS_DIR"/*/; do
        [[ ! -d "$app_dir" ]] && continue
        
        local app_name
        app_name=$(basename "$app_dir")
        
        # Skip scripts directory
        [[ "$app_name" == "scripts" ]] && continue
        
        # Check for config.yml
        local config_file="${app_dir}/config.yml"
        [[ ! -f "$config_file" ]] && continue
        
        # Check for docker-compose.yml
        if [[ ! -f "${app_dir}/docker-compose.yml" ]] && [[ ! -f "${app_dir}/docker-compose.yaml" ]]; then
            continue
        fi
        
        # Check if backup is enabled (default: true)
        local backup_enabled
        backup_enabled=$(get_config "$app_name" ".backup.enabled" "true")
        [[ "$backup_enabled" != "true" ]] && continue
        
        # Check allowed_hosts restriction (if set, current host must be in the list)
        local allowed_hosts
        allowed_hosts=$(yq -r '.allowed_hosts[]? // empty' "$config_file" 2>/dev/null || true)
        if [[ -n "$allowed_hosts" ]]; then
            if ! echo "$allowed_hosts" | grep -qxF "$(hostname)"; then
                log_info "Skipping $app_name - not allowed on $(hostname)"
                continue
            fi
        fi
        
        apps+=("$app_name")
    done
    
    printf '%s\n' "${apps[@]}" | sort -u
}

# Get the compose directory for an app
get_compose_dir() {
    local app_name="$1"
    
    # Check for custom install path in config
    local install_path
    install_path=$(get_config "$app_name" ".paths.install_path" "")
    
    if [[ -n "$install_path" ]] && [[ -d "$install_path" ]]; then
        echo "$install_path"
        return
    fi
    
    # Check /opt/stacks symlink
    if [[ -L "/opt/stacks/$app_name" ]]; then
        readlink -f "/opt/stacks/$app_name"
        return
    fi
    
    # Default to apps directory
    echo "$APPS_DIR/$app_name"
}

# Get paths to backup for an app
get_backup_paths() {
    local app_name="$1"
    local compose_dir
    compose_dir=$(get_compose_dir "$app_name")
    
    local paths=()
    
    # Read paths from config
    while IFS= read -r rel_path; do
        [[ -z "$rel_path" ]] && continue
        
        # Resolve relative paths
        if [[ "$rel_path" == ./* ]]; then
            paths+=("$compose_dir/${rel_path#./}")
        elif [[ "$rel_path" == /* ]]; then
            paths+=("$rel_path")
        else
            paths+=("$compose_dir/$rel_path")
        fi
    done < <(get_config_array "$app_name" ".backup.paths")
    
    # Default to data directory if no paths specified
    if [[ ${#paths[@]} -eq 0 ]]; then
        paths+=("$compose_dir/data")
    fi
    
    printf '%s\n' "${paths[@]}"
}

# Check if app should be stopped during backup
should_stop_app() {
    local app_name="$1"
    
    # Check hot_backup flag (for critical services like traefik, pihole)
    local hot_backup
    hot_backup=$(get_config "$app_name" ".hot_backup" "false")
    [[ "$hot_backup" == "true" ]] && return 1
    
    # Check stop_during_backup preference
    local stop
    stop=$(get_config "$app_name" ".backup.stop_during_backup" "true")
    [[ "$stop" == "true" ]] && return 0
    
    return 1
}

# =============================================================================
# Container Management
# =============================================================================

stop_app_containers() {
    local app_name="$1"
    local compose_dir
    compose_dir=$(get_compose_dir "$app_name")
    
    if ! should_stop_app "$app_name"; then
        log_info "Hot backup enabled for $app_name, skipping container stop"
        return 0
    fi
    
    log_info "Stopping containers for $app_name..."
    
    if [[ ! -d "$compose_dir" ]]; then
        log_warn "Compose directory not found: $compose_dir"
        return 0
    fi
    
    cd "$compose_dir"
    
    if docker compose ps 2>/dev/null | grep -qE "running|Up"; then
        docker compose stop --timeout 30 2>&1 || {
            log_warn "Graceful stop failed, forcing..."
            docker compose kill 2>&1 || true
        }
        log_info "Containers stopped for $app_name"
        return 0
    fi
    
    log_info "No running containers for $app_name"
    return 0
}

start_app_containers() {
    local app_name="$1"
    local compose_dir
    compose_dir=$(get_compose_dir "$app_name")
    
    if ! should_stop_app "$app_name"; then
        return 0
    fi
    
    log_info "Starting containers for $app_name..."
    
    if [[ ! -d "$compose_dir" ]]; then
        log_warn "Compose directory not found: $compose_dir"
        return 1
    fi
    
    cd "$compose_dir"
    
    # Check for infisical secrets
    local infisical_path
    infisical_path=$(get_config "$app_name" ".secrets.infisical_path" "")
    
    if [[ -n "$infisical_path" ]] && [[ -x /usr/local/bin/infisical-run ]]; then
        log_info "Starting with infisical-run..."
        /usr/local/bin/infisical-run docker compose up -d 2>&1 || {
            log_error "Failed to start $app_name with infisical"
            return 1
        }
    else
        docker compose up -d 2>&1 || {
            log_error "Failed to start $app_name"
            return 1
        }
    fi
    
    log_info "Containers started for $app_name"
}

# =============================================================================
# Backup Functions
# =============================================================================

# Run pre-backup hook
run_pre_backup() {
    local app_name="$1"
    local compose_dir
    compose_dir=$(get_compose_dir "$app_name")
    
    local hook
    hook=$(get_config "$app_name" ".backup.pre_backup" "")
    
    if [[ -n "$hook" ]] && [[ "$hook" != "null" ]]; then
        log_info "Running pre-backup hook for $app_name..."
        cd "$compose_dir"
        bash -c "$hook" 2>&1 || log_warn "Pre-backup hook failed (non-fatal)"
    fi
}

# Run post-backup hook
run_post_backup() {
    local app_name="$1"
    local compose_dir
    compose_dir=$(get_compose_dir "$app_name")
    
    local hook
    hook=$(get_config "$app_name" ".backup.post_backup" "")
    
    if [[ -n "$hook" ]] && [[ "$hook" != "null" ]]; then
        log_info "Running post-backup hook for $app_name..."
        cd "$compose_dir"
        bash -c "$hook" 2>&1 || log_warn "Post-backup hook failed (non-fatal)"
    fi
}

# Backup app data to local directory
backup_app_data() {
    local app_name="$1"
    local app_backup_dir="$BACKUP_DIR/$app_name"
    
    mkdir -p "$app_backup_dir"
    
    local compose_dir
    compose_dir=$(get_compose_dir "$app_name")
    
    log_info "Backing up data for $app_name..."
    
    # Get exclude patterns
    local excludes=()
    while IFS= read -r pattern; do
        [[ -n "$pattern" ]] && excludes+=(--exclude="$pattern")
    done < <(get_config_array "$app_name" ".backup.exclude")
    
    # Always exclude common temp files
    excludes+=(--exclude="*.log" --exclude="*.tmp" --exclude="*.pid")
    
    # Create tar archive of compose directory (includes docker-compose.yml + data)
    local backup_file="$app_backup_dir/${app_name}_data_${TIMESTAMP}.tar.gz"
    
    tar czf "$backup_file" \
        "${excludes[@]}" \
        -C "$(dirname "$compose_dir")" \
        "$(basename "$compose_dir")" 2>&1 || {
            log_error "Failed to create backup archive for $app_name"
            return 1
        }
    
    if [[ -f "$backup_file" ]] && [[ -s "$backup_file" ]]; then
        local size
        size=$(du -h "$backup_file" | cut -f1)
        log_info "Created: $backup_file ($size)"
    else
        log_error "Backup file empty or missing: $backup_file"
        rm -f "$backup_file"
        return 1
    fi
}

# Backup database if present
backup_app_database() {
    local app_name="$1"
    local app_backup_dir="$BACKUP_DIR/$app_name"
    local compose_dir
    compose_dir=$(get_compose_dir "$app_name")
    
    cd "$compose_dir"
    
    # PostgreSQL
    if docker compose ps 2>/dev/null | grep -q postgres; then
        log_info "Backing up PostgreSQL database..."
        local pg_container
        pg_container=$(docker compose ps -q postgres 2>/dev/null | head -1)
        if [[ -n "$pg_container" ]]; then
            docker exec "$pg_container" pg_dumpall -U postgres 2>/dev/null | \
                gzip > "$app_backup_dir/${app_name}_postgres_${TIMESTAMP}.sql.gz" || \
                log_warn "PostgreSQL backup failed"
        fi
    fi
    
    # MongoDB
    if docker compose ps 2>/dev/null | grep -q mongo; then
        log_info "Backing up MongoDB..."
        local mongo_container
        mongo_container=$(docker compose ps -q mongo 2>/dev/null | head -1)
        if [[ -n "$mongo_container" ]]; then
            docker exec "$mongo_container" mongodump --archive 2>/dev/null | \
                gzip > "$app_backup_dir/${app_name}_mongo_${TIMESTAMP}.archive.gz" || \
                log_warn "MongoDB backup failed"
        fi
    fi
    
    # MariaDB/MySQL
    if docker compose ps 2>/dev/null | grep -qE 'mariadb|mysql'; then
        log_info "Backing up MariaDB/MySQL..."
        local db_container
        db_container=$(docker compose ps -q mariadb mysql 2>/dev/null | head -1)
        if [[ -n "$db_container" ]]; then
            docker exec "$db_container" mysqldump --all-databases -u root 2>/dev/null | \
                gzip > "$app_backup_dir/${app_name}_mysql_${TIMESTAMP}.sql.gz" || \
                log_warn "MariaDB/MySQL backup failed"
        fi
    fi
}

# Cleanup old local backups
cleanup_old_backups() {
    local app_backup_dir="$1"
    
    log_info "Cleaning up old backups in $app_backup_dir..."
    
    # Keep only current backup (restic handles versioning)
    find "$app_backup_dir" -name "*.tar.gz" ! -name "*_${TIMESTAMP}*" -delete 2>/dev/null || true
    find "$app_backup_dir" -name "*.sql.gz" ! -name "*_${TIMESTAMP}*" -delete 2>/dev/null || true
    find "$app_backup_dir" -name "*.archive.gz" ! -name "*_${TIMESTAMP}*" -delete 2>/dev/null || true
}

# Sync to B2 using restic
sync_to_b2() {
    local app_name="$1"
    local app_backup_dir="$BACKUP_DIR/$app_name"
    
    if [[ -z "${B2_BUCKET:-}" ]] || [[ -z "${B2_ACCOUNT_ID:-}" ]] || \
       [[ -z "${B2_ACCOUNT_KEY:-}" ]] || [[ -z "${RESTIC_PASSWORD:-}" ]]; then
        log_warn "B2 credentials not set, skipping remote sync"
        return 0
    fi
    
    log_info "Syncing to Backblaze B2: $B2_BUCKET"
    
    export RESTIC_REPOSITORY="b2:${B2_BUCKET}:${HOSTNAME_PREFIX}"
    export RESTIC_PASSWORD="${RESTIC_PASSWORD}"
    export B2_ACCOUNT_ID="${B2_ACCOUNT_ID}"
    export B2_ACCOUNT_KEY="${B2_ACCOUNT_KEY}"
    
    # Initialize repo if needed
    if ! timeout 60 restic snapshots &>/dev/null 2>&1; then
        log_info "Initializing restic repository..."
        restic init 2>&1 || {
            log_error "Failed to initialize restic repository"
            return 1
        }
    fi
    
    # Clear stale locks
    restic unlock 2>/dev/null || true
    
    # Backup with tags
    log_info "Running restic backup..."
    timeout "${RESTIC_TIMEOUT}" restic backup "$app_backup_dir" \
        --tag "$app_name" \
        --tag "homelab-apps" \
        --host "$HOSTNAME_PREFIX" \
        --exclude-caches 2>&1 || {
            log_error "Restic backup failed for $app_name"
            return 1
        }
    
    # Apply retention policy
    log_info "Applying retention policy..."
    restic forget \
        --tag "$app_name" \
        --keep-daily 7 \
        --keep-weekly 4 \
        --keep-monthly 3 \
        --prune 2>&1 || log_warn "Retention policy failed (non-fatal)"
    
    log_info "B2 sync completed for $app_name"
}

# Send Discord notification
send_discord_notification() {
    local app_name="$1"
    local message="$2"
    local level="${3:-info}"
    
    [[ -z "${DISCORD_WEBHOOK_URL:-}" ]] && return 0
    
    local color
    case "$level" in
        success) color="3066993" ;;  # Green
        error)   color="15158332" ;; # Red
        warning) color="15844367" ;; # Orange
        *)       color="3447003" ;;  # Blue
    esac
    
    local payload
    payload=$(cat <<EOF
{
    "embeds": [{
        "title": "📦 Backup: ${app_name}",
        "description": "${message}",
        "color": ${color},
        "footer": {"text": "Host: ${HOSTNAME_PREFIX}"},
        "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    }]
}
EOF
)
    
    curl -s -H "Content-Type: application/json" -d "${payload}" "${DISCORD_WEBHOOK_URL}" >/dev/null 2>&1 || true
}

# =============================================================================
# Main Backup Logic
# =============================================================================

backup_app() {
    local app_name="$1"
    
    log_header "Backing up: $app_name"
    
    local compose_dir
    compose_dir=$(get_compose_dir "$app_name")
    
    if [[ ! -d "$compose_dir" ]]; then
        log_error "App directory not found: $compose_dir"
        return 1
    fi
    
    log_info "Compose directory: $compose_dir"
    
    local app_backup_dir="$BACKUP_DIR/$app_name"
    mkdir -p "$app_backup_dir"
    
    local backup_success=true
    local containers_stopped=false
    
    # Pre-backup hook
    run_pre_backup "$app_name"
    
    # Stop containers if needed
    if stop_app_containers "$app_name"; then
        containers_stopped=true
    fi
    
    # Backup database
    backup_app_database "$app_name" || true
    
    # Backup data
    backup_app_data "$app_name" || backup_success=false
    
    # Post-backup hook
    run_post_backup "$app_name"
    
    # Restart containers
    if [[ "$containers_stopped" == "true" ]]; then
        start_app_containers "$app_name"
    fi
    
    # Cleanup old backups
    cleanup_old_backups "$app_backup_dir"
    
    # Sync to B2
    sync_to_b2 "$app_name" || backup_success=false
    
    if [[ "$backup_success" == "true" ]]; then
        log_info "✅ Backup completed for $app_name"
        send_discord_notification "$app_name" "✅ Backup completed successfully" "success"
        return 0
    else
        log_error "❌ Backup failed for $app_name"
        send_discord_notification "$app_name" "❌ Backup failed" "error"
        return 1
    fi
}

backup_all() {
    log_header "Backing up ALL apps"
    log_info "Host: $HOSTNAME_PREFIX"
    log_info "Apps directory: $APPS_DIR"
    
    send_discord_notification "all" "🚀 Starting backup of all apps on ${HOSTNAME_PREFIX}" "info"
    
    local total_success=0
    local total_failed=0
    local failed_apps=""
    
    while IFS= read -r app_name; do
        [[ -z "$app_name" ]] && continue
        
        if backup_app "$app_name"; then
            ((total_success++))
        else
            ((total_failed++))
            failed_apps+=" $app_name"
        fi
    done < <(discover_backup_apps)
    
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - START_TIME))
    local duration_fmt
    duration_fmt=$(printf '%02d:%02d:%02d' $((duration/3600)) $((duration%3600/60)) $((duration%60)))
    
    log_header "Backup Summary"
    log_info "Duration: $duration_fmt"
    log_info "Successful: $total_success"
    log_info "Failed: $total_failed"
    
    if [[ $total_failed -gt 0 ]]; then
        log_error "Failed apps:$failed_apps"
        send_discord_notification "all" "⚠️ Backup completed with errors\\n\\n**Success:** ${total_success}\\n**Failed:** ${total_failed}\\n**Duration:** ${duration_fmt}" "warning"
        return 1
    fi
    
    send_discord_notification "all" "✅ All backups completed\\n\\n**Apps:** ${total_success}\\n**Duration:** ${duration_fmt}" "success"
    return 0
}

list_apps() {
    log_header "Discovered Apps"
    log_info "Apps directory: $APPS_DIR"
    echo ""
    
    local count=0
    while IFS= read -r app_name; do
        [[ -z "$app_name" ]] && continue
        
        local compose_dir
        compose_dir=$(get_compose_dir "$app_name")
        
        local hot_backup
        hot_backup=$(get_config "$app_name" ".hot_backup" "false")
        
        local status=""
        [[ "$hot_backup" == "true" ]] && status=" (hot backup)"
        
        echo "  📦 $app_name"
        echo "     → $compose_dir$status"
        
        ((count++))
    done < <(discover_backup_apps)
    
    echo ""
    log_info "Total apps: $count"
}

show_help() {
    cat <<EOF
Universal Container Backup Script (Config-Driven)
Reads backup configuration from each app's config.yml

Usage: $(basename "$0") <app_name|all|list|help>

Commands:
  <app_name>    Backup specific app
  all           Backup all discovered apps
  list          List all apps with backup enabled
  help          Show this help

Environment Variables (from /opt/scripts/backup.env):
  B2_BUCKET             Backblaze B2 bucket name
  B2_ACCOUNT_ID         Backblaze B2 Application Key ID
  B2_ACCOUNT_KEY        Backblaze B2 Application Key
  RESTIC_PASSWORD       Restic repository encryption password
  DISCORD_WEBHOOK_URL   Optional Discord webhook for notifications
  HOSTNAME_PREFIX       Prefix for backup paths (default: hostname)
  APPS_DIR              Apps directory (default: parent of scripts/)

App config.yml Example:
  backup:
    enabled: true
    paths:
      - ./data
      - ./config
    stop_during_backup: true
    exclude:
      - "*.log"
    pre_backup: "docker exec myapp flush"
  hot_backup: false  # true for critical services (traefik, pihole)

Examples:
  $(basename "$0") vaultwarden    # Backup vaultwarden
  $(basename "$0") all            # Backup all apps
  $(basename "$0") list           # List available apps

Host: ${HOSTNAME_PREFIX}
Apps: ${APPS_DIR}
EOF
}

# =============================================================================
# Main Entry Point
# =============================================================================

main() {
    check_yq
    
    case "${APP_NAME}" in
        ""|help|--help|-h)
            show_help
            ;;
        list)
            list_apps
            ;;
        all)
            backup_all
            ;;
        *)
            # Check if app exists
            if [[ ! -d "$APPS_DIR/$APP_NAME" ]]; then
                log_error "App not found: $APP_NAME"
                log_info "Use 'list' to see available apps"
                exit 1
            fi
            backup_app "$APP_NAME"
            ;;
    esac
}

main
