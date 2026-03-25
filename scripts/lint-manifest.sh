#!/usr/bin/env bash
# lint-manifest.sh — Validate manifest.yml against available app directories
#
# The manifest is the single source of truth for which apps deploy where.
# This script ensures:
#   1. Every app referenced in the manifest has a matching directory with config.yml
#   2. Every app directory with a config.yml is referenced somewhere in the manifest
#   3. Profile names referenced by hosts actually exist
#
# Usage:
#   ./scripts/lint-manifest.sh              # Run from repo root
#   ./scripts/lint-manifest.sh --ci         # Exit 1 on any warning (strict mode)
#
# Requires: yq (https://github.com/mikefarah/yq)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="$REPO_ROOT/manifest.yml"
STRICT=false
ERRORS=0
WARNINGS=0

[[ "${1:-}" == "--ci" ]] && STRICT=true

# Colors
RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
NC='\033[0m'

error() { echo -e "${RED}ERROR:${NC} $*" >&2; ERRORS=$((ERRORS + 1)); }
warn()  { echo -e "${YELLOW}WARN:${NC}  $*" >&2; WARNINGS=$((WARNINGS + 1)); }
ok()    { echo -e "${GREEN}OK:${NC}    $*"; }

# ── Pre-checks ───────────────────────────────────────────────────────────────

if ! command -v yq &>/dev/null; then
    error "yq is required but not installed. Install from https://github.com/mikefarah/yq"
    exit 1
fi

if [[ ! -f "$MANIFEST" ]]; then
    error "manifest.yml not found at $MANIFEST"
    exit 1
fi

# ── Collect data ─────────────────────────────────────────────────────────────

# All app directories that have a config.yml (exclude scripts/, playbooks/, roles/, etc.)
declare -A available_apps
while IFS= read -r dir; do
    app_name="$(basename "$dir")"
    # Skip non-app directories
    [[ "$app_name" == "scripts" ]] && continue
    [[ "$app_name" == "playbooks" ]] && continue
    [[ "$app_name" == "roles" ]] && continue
    [[ "$app_name" == "inventories" ]] && continue
    if [[ -f "$dir/config.yml" ]]; then
        available_apps["$app_name"]=1
    fi
done < <(find "$REPO_ROOT" -mindepth 1 -maxdepth 1 -type d | sort)

# All profile names defined in manifest
declare -A defined_profiles
while IFS= read -r profile; do
    [[ -z "$profile" ]] && continue
    defined_profiles["$profile"]=1
done < <(yq -r '.profiles | keys | .[]' "$MANIFEST" 2>/dev/null)

# All apps referenced in profiles
declare -A profile_apps
while IFS= read -r app; do
    [[ -z "$app" ]] && continue
    profile_apps["$app"]=1
done < <(yq -r '.profiles[].apps[]' "$MANIFEST" 2>/dev/null)

# All apps referenced in host-level apps lists
declare -A host_apps
while IFS= read -r app; do
    [[ -z "$app" || "$app" == "null" ]] && continue
    host_apps["$app"]=1
done < <(yq -r '.hosts[].apps[] | select(. != null)' "$MANIFEST" 2>/dev/null || true)

# Combined: all apps referenced anywhere in the manifest
declare -A manifest_apps
for app in "${!profile_apps[@]}"; do manifest_apps["$app"]=1; done
for app in "${!host_apps[@]}"; do manifest_apps["$app"]=1; done

# ── Check 1: Every manifest app has a directory ──────────────────────────────

echo ""
echo "═══ Check 1: Manifest apps have directories ═══"
for app in $(echo "${!manifest_apps[@]}" | tr ' ' '\n' | sort); do
    if [[ -z "${available_apps[$app]:-}" ]]; then
        error "$app is in manifest but has no directory with config.yml"
    else
        ok "$app"
    fi
done

# ── Check 2: Every app directory is in the manifest ─────────────────────────

echo ""
echo "═══ Check 2: App directories are in manifest ═══"
for app in $(echo "${!available_apps[@]}" | tr ' ' '\n' | sort); do
    if [[ -z "${manifest_apps[$app]:-}" ]]; then
        warn "$app has a directory but is not referenced in manifest.yml"
    else
        ok "$app"
    fi
done

# ── Check 3: Host profile references exist ───────────────────────────────────

echo ""
echo "═══ Check 3: Host profile references exist ═══"
while IFS= read -r host; do
    [[ -z "$host" ]] && continue
    while IFS= read -r profile; do
        [[ -z "$profile" || "$profile" == "null" ]] && continue
        if [[ -z "${defined_profiles[$profile]:-}" ]]; then
            error "Host '$host' references undefined profile '$profile'"
        else
            ok "$host → $profile"
        fi
    done < <(yq -r ".hosts[\"$host\"].profiles[] | select(. != null)" "$MANIFEST" 2>/dev/null || true)
done < <(yq -r '.hosts | keys | .[]' "$MANIFEST" 2>/dev/null)

# ── Check 4: No duplicate app assignments per host ───────────────────────────

echo ""
echo "═══ Check 4: No duplicate app assignments per host ═══"
while IFS= read -r host; do
    [[ -z "$host" ]] && continue
    
    # Collect all apps for this host (from profiles + direct apps)
    declare -A host_all_apps=()
    
    # Apps from profiles
    while IFS= read -r profile; do
        [[ -z "$profile" || "$profile" == "null" ]] && continue
        while IFS= read -r app; do
            [[ -z "$app" ]] && continue
            if [[ -n "${host_all_apps[$app]:-}" ]]; then
                warn "Host '$host' gets '$app' from both '${host_all_apps[$app]}' and profile '$profile'"
            else
                host_all_apps["$app"]="profile:$profile"
            fi
        done < <(yq -r ".profiles[\"$profile\"].apps[]" "$MANIFEST" 2>/dev/null)
    done < <(yq -r ".hosts[\"$host\"].profiles[] | select(. != null)" "$MANIFEST" 2>/dev/null || true)
    
    # Direct apps
    while IFS= read -r app; do
        [[ -z "$app" || "$app" == "null" ]] && continue
        if [[ -n "${host_all_apps[$app]:-}" ]]; then
            warn "Host '$host' has '$app' in direct apps AND in ${host_all_apps[$app]}"
        else
            host_all_apps["$app"]="direct"
        fi
    done < <(yq -r ".hosts[\"$host\"].apps[] | select(. != null)" "$MANIFEST" 2>/dev/null || true)
    
    if [[ ${#host_all_apps[@]} -gt 0 ]]; then
        ok "$host — ${#host_all_apps[@]} apps, no duplicates"
    fi
    
    unset host_all_apps
done < <(yq -r '.hosts | keys | .[]' "$MANIFEST" 2>/dev/null)

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "═══════════════════════════════════════════════"
if [[ $ERRORS -gt 0 ]]; then
    echo -e "${RED}FAILED:${NC} $ERRORS error(s), $WARNINGS warning(s)"
    exit 1
elif [[ $WARNINGS -gt 0 && "$STRICT" == "true" ]]; then
    echo -e "${YELLOW}FAILED (strict):${NC} $WARNINGS warning(s)"
    exit 1
elif [[ $WARNINGS -gt 0 ]]; then
    echo -e "${YELLOW}PASSED with warnings:${NC} $WARNINGS warning(s)"
    exit 0
else
    echo -e "${GREEN}PASSED:${NC} All checks passed"
    exit 0
fi
