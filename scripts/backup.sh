#!/bin/bash
# Universal Container Backup Script (Config-Driven)
# Backs up Docker containers/stacks and syncs to Atlas backup server
# Reads backup configuration from each app's config.yml
#
# Usage: backup.sh <app_name|all> [backup_type]
#   app_name: Name of the app to backup, or "all" for all apps
#   backup_type: full (default)
#
# Environment variables (from /opt/scripts/backup.env):
#   BACKUP_DIR: Base directory for backups (default: /opt/backups)
#   ATLAS_HOST: Atlas backup server hostname/IP
#   ATLAS_USER: SSH user for Atlas connection
#   ATLAS_SSH_KEY: Path to SSH private key for Atlas (default: /root/.ssh/atlas_backup)
#   ATLAS_BACKUP_DIR: Remote backup directory on Atlas (default: /opt/backrest/data/backups)
#   DISCORD_WEBHOOK_URL: Optional Discord webhook for notifications
#   HOSTNAME_PREFIX: Prefix for backup paths (default: hostname)

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_DIR="${APPS_DIR:-$(dirname "$SCRIPT_DIR")}"

# Infrastructure stack config directory (deployed from homelab repo)
INFRA_CONFIG_DIR="${INFRA_CONFIG_DIR:-/opt/infrastructure/backup-config}"

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

# Find config.yml for an app/stack (checks APPS_DIR then INFRA_CONFIG_DIR)
find_config_file() {
    local app_name="$1"
    if [[ -f "$APPS_DIR/$app_name/config.yml" ]]; then
        echo "$APPS_DIR/$app_name/config.yml"
    elif [[ -f "$INFRA_CONFIG_DIR/$app_name/config.yml" ]]; then
        echo "$INFRA_CONFIG_DIR/$app_name/config.yml"
    fi
}

# Get value from app/stack config.yml
# Usage: get_config app_name ".key.path" "default_value"
get_config() {
    local app_name="$1"
    local key="$2"
    local default="${3:-}"
    
    local config_file
    config_file=$(find_config_file "$app_name")
    if [[ -z "$config_file" ]]; then
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
    
    local config_file
    config_file=$(find_config_file "$app_name")
    if [[ -z "$config_file" ]]; then
        return
    fi
    
    yq -r "$key[]? // empty" "$config_file" 2>/dev/null || true
}

# =============================================================================
# App Discovery Functions
# =============================================================================

# Discover all apps/stacks with backup enabled
# Scans both APPS_DIR (homelab-apps) and INFRA_CONFIG_DIR (infrastructure stacks)
discover_backup_apps() {
    local apps=()
    
    # Scan application stacks (homelab-apps)
    for app_dir in "$APPS_DIR"/*/; do
        [[ ! -d "$app_dir" ]] && continue
        
        local app_name
        app_name=$(basename "$app_dir")
        
        # Skip scripts/playbooks/roles directories
        [[ "$app_name" == "scripts" || "$app_name" == "playbooks" || "$app_name" == "roles" || "$app_name" == "inventories" ]] && continue
        
        # Skip renamed/archived directories (contain .old.)
        [[ "$app_name" == *.old.* ]] && continue
        
        # Check for config.yml
        [[ ! -f "${app_dir}/config.yml" ]] && continue
        
        # Check for docker-compose.yml (apps must have a compose file)
        if [[ ! -f "${app_dir}/docker-compose.yml" ]] && [[ ! -f "${app_dir}/docker-compose.yaml" ]]; then
            continue
        fi
        
        # Check if backup is enabled (default: true)
        local backup_enabled
        backup_enabled=$(get_config "$app_name" ".backup.enabled" "true")
        [[ "$backup_enabled" != "true" ]] && continue
        
        apps+=("$app_name")
    done
    
    # Scan infrastructure stacks (config-only, compose lives at install_path)
    if [[ -d "$INFRA_CONFIG_DIR" ]]; then
        for stack_dir in "$INFRA_CONFIG_DIR"/*/; do
            [[ ! -d "$stack_dir" ]] && continue
            
            local stack_name
            stack_name=$(basename "$stack_dir")
            
            [[ "$stack_name" == *.old.* ]] && continue
            [[ ! -f "${stack_dir}/config.yml" ]] && continue
            
            # Check if backup is enabled (default: true)
            local backup_enabled
            backup_enabled=$(get_config "$stack_name" ".backup.enabled" "true")
            [[ "$backup_enabled" != "true" ]] && continue
            
            # Verify install_path exists on this host (stack is actually deployed here)
            local install_path
            install_path=$(get_config "$stack_name" ".paths.install_path" "")
            if [[ -n "$install_path" ]] && [[ ! -d "$install_path" ]]; then
                continue  # Stack not deployed on this host
            fi
            
            apps+=("$stack_name")
        done
    fi
    
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
    
    # Redis (RDB dump)
    if docker compose ps 2>/dev/null | grep -q redis; then
        log_info "Backing up Redis data..."
        local redis_container
        redis_container=$(docker compose ps -q redis 2>/dev/null | head -1)
        if [[ -n "$redis_container" ]]; then
            local db_backup="$app_backup_dir/${app_name}_redis_${TIMESTAMP}.rdb"
            docker exec "$redis_container" redis-cli BGSAVE 2>/dev/null || true
            sleep 2
            docker exec "$redis_container" cat /data/dump.rdb 2>/dev/null > "$db_backup" || true
            if [[ -s "$db_backup" ]]; then
                log_info "Redis backup created: $db_backup"
            else
                rm -f "$db_backup"
            fi
        fi
    fi
}

# Cleanup old local backups
cleanup_old_backups() {
    local app_backup_dir="$1"
    
    log_info "Cleaning up old backups in $app_backup_dir..."
    
    # Keep only files from current timestamp (Atlas/Backrest handles versioning)
    find "$app_backup_dir" -name "*.tar.gz" ! -name "*_${TIMESTAMP}*" -delete 2>/dev/null || true
    find "$app_backup_dir" -name "*.sql.gz" ! -name "*_${TIMESTAMP}*" -delete 2>/dev/null || true
    find "$app_backup_dir" -name "*.archive.gz" ! -name "*_${TIMESTAMP}*" -delete 2>/dev/null || true
    find "$app_backup_dir" -name "*.rdb" ! -name "*_${TIMESTAMP}*" -delete 2>/dev/null || true
}

# Sync backups to Atlas backup server via rsync
# Atlas runs Backrest which manages B2 uploads
sync_to_atlas() {
    local app_name="$1"
    local app_backup_dir="$BACKUP_DIR/$app_name"

    if [[ -z "${ATLAS_HOST:-}" ]] || [[ -z "${ATLAS_USER:-}" ]]; then
        log_warn "Atlas backup not configured (missing ATLAS_HOST or ATLAS_USER)"
        log_warn "Local backups retained but NOT synced offsite"
        return 1
    fi

    local ssh_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=30 -o BatchMode=yes"
    if [[ -n "${ATLAS_SSH_KEY:-}" ]] && [[ -f "${ATLAS_SSH_KEY}" ]]; then
        ssh_opts="${ssh_opts} -i ${ATLAS_SSH_KEY}"
    fi

    local atlas_dest="${ATLAS_BACKUP_DIR:-/opt/backrest/data/backups}/${HOSTNAME_PREFIX}/${app_name}/"

    log_info "Syncing backups to Atlas: ${ATLAS_USER}@${ATLAS_HOST}:${atlas_dest}"

    # Test connectivity
    if ! ssh ${ssh_opts} "${ATLAS_USER}@${ATLAS_HOST}" "echo ok" &>/dev/null; then
        log_error "Cannot connect to Atlas (${ATLAS_HOST})"
        send_discord_notification "${app_name}" "⚠️ Cannot connect to Atlas backup server (${ATLAS_HOST}) for ${app_name} on ${HOSTNAME_PREFIX}" "warning"
        return 1
    fi

    # Create remote directory
    ssh ${ssh_opts} "${ATLAS_USER}@${ATLAS_HOST}" "mkdir -p '${atlas_dest}'" 2>&1 || {
        log_error "Failed to create directory on Atlas"
        return 1
    }

    # Rsync backup files to Atlas (--delete removes old files on Atlas)
    if rsync -avz --delete \
        -e "ssh ${ssh_opts}" \
        "${app_backup_dir}/" \
        "${ATLAS_USER}@${ATLAS_HOST}:${atlas_dest}" 2>&1; then

        log_info "Backups synced to Atlas successfully"

        # Show what was synced
        local file_count
        file_count=$(find "${app_backup_dir}" -type f | wc -l)
        local total_size
        total_size=$(du -sh "${app_backup_dir}" 2>/dev/null | cut -f1)
        log_info "Synced ${file_count} files (${total_size}) to Atlas"
    else
        log_error "Failed to rsync backups to Atlas"
        send_discord_notification "${app_name}" "⚠️ Failed to sync ${app_name} backups to Atlas (${ATLAS_HOST}) from ${HOSTNAME_PREFIX}" "warning"
        return 1
    fi
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
        warning) color="15105570" ;; # Orange
        *)       color="3447003" ;;  # Blue
    esac
    
    local payload
    payload=$(cat <<EOF
{
    "embeds": [{
        "title": "🗄️ Backup Notification",
        "description": "${message}",
        "color": ${color},
        "fields": [
            {"name": "Host", "value": "${HOSTNAME_PREFIX}", "inline": true},
            {"name": "Stack", "value": "${app_name}", "inline": true},
            {"name": "Type", "value": "${BACKUP_TYPE}", "inline": true}
        ],
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
    
    # Sync to Atlas backup server
    sync_to_atlas "$app_name" || backup_success=false
    
    # List created backup files for notification
    local backup_files
    backup_files=$(ls -lh "${app_backup_dir}"/*_${TIMESTAMP}* 2>/dev/null | awk '{print $NF": "$5}' | tr '\n' ', ' | sed 's/, $//')
    
    if [[ "$backup_success" == "true" ]]; then
        log_info "✅ Backup completed for $app_name"
        send_discord_notification "$app_name" "✅ Backup completed successfully\\n\\n**Files:** ${backup_files:-none}" "success"
        return 0
    else
        log_error "❌ Backup failed for $app_name"
        send_discord_notification "$app_name" "❌ Backup failed\\n\\n**Files:** ${backup_files:-none}" "error"
        return 1
    fi
}

backup_all() {
    log_header "Backing up ALL apps & stacks"
    log_info "Host: $HOSTNAME_PREFIX"
    log_info "Apps directory: $APPS_DIR"
    log_info "Infra config directory: $INFRA_CONFIG_DIR"
    
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
    log_header "Discovered Apps & Stacks"
    log_info "Apps directory: $APPS_DIR"
    log_info "Infra config directory: $INFRA_CONFIG_DIR"
    echo ""
    
    local count=0
    while IFS= read -r app_name; do
        [[ -z "$app_name" ]] && continue
        
        local compose_dir
        compose_dir=$(get_compose_dir "$app_name")
        
        local hot_backup
        hot_backup=$(get_config "$app_name" ".hot_backup" "false")
        
        local source="app"
        [[ -f "$INFRA_CONFIG_DIR/$app_name/config.yml" ]] && source="infra"
        
        local status=""
        [[ "$hot_backup" == "true" ]] && status=" (hot backup)"
        
        echo "  📦 $app_name [$source]"
        echo "     → $compose_dir$status"
        
        ((count++))
    done < <(discover_backup_apps)
    
    echo ""
    log_info "Total: $count"
}

show_help() {
    cat <<EOF
Universal Container Backup Script (Config-Driven)
Backs up apps and infrastructure stacks, syncs to Atlas backup server.
Reads backup configuration from each app/stack's config.yml.

Usage: $(basename "$0") <app_name|all|list|help>

Commands:
  <app_name>    Backup specific app or infrastructure stack
  all           Backup all discovered apps and stacks
  list          List all apps/stacks with backup enabled
  help          Show this help

Environment Variables (from /opt/scripts/backup.env):
  ATLAS_HOST            Atlas backup server hostname/IP
  ATLAS_USER            SSH user for Atlas connection (default: root)
  ATLAS_SSH_KEY         Path to SSH private key for Atlas
  ATLAS_BACKUP_DIR      Remote backup directory on Atlas
  DISCORD_WEBHOOK_URL   Optional Discord webhook for notifications
  HOSTNAME_PREFIX       Prefix for backup paths (default: hostname)
  APPS_DIR              Apps directory (default: parent of scripts/)
  INFRA_CONFIG_DIR      Infrastructure stack configs (default: /opt/infrastructure/backup-config)

Config Sources:
  Apps:  \${APPS_DIR}/<app>/config.yml     (homelab-apps repo)
  Infra: \${INFRA_CONFIG_DIR}/<stack>/config.yml (homelab repo)

Examples:
  $(basename "$0") vaultwarden    # Backup vaultwarden app
  $(basename "$0") harbor         # Backup harbor infra stack
  $(basename "$0") all            # Backup everything
  $(basename "$0") list           # List available apps/stacks

Host: ${HOSTNAME_PREFIX}
Apps: ${APPS_DIR}
Infra: ${INFRA_CONFIG_DIR}
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
            # Check if app/stack exists in either config directory
            local config_file
            config_file=$(find_config_file "$APP_NAME")
            if [[ -z "$config_file" ]]; then
                log_error "App/stack not found: $APP_NAME"
                log_info "Use 'list' to see available apps and stacks"
                exit 1
            fi
            backup_app "$APP_NAME"
            ;;
    esac
}

main
