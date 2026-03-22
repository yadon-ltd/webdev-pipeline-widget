#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
# wd-lib.sh — shared functions for the webdev deploy pipeline
# ══════════════════════════════════════════════════════════════
# Sourced by wd-deploy, wd-gitsync, wd-snapshot, and wd-websync.
# Not executable on its own.
#
# Provides:
#   - WEBSYNC_CONFIG_DIR (shared constant)
#   - parse_deploy_conf (full version with patterns — for wd-deploy)
#   - parse_deploy_conf_files (files-only — for wd-gitsync, wd-snapshot)
#   - derive_masked_name (compute .masked filename from a path)
#   - cmd_list_profiles (list available websync profiles)
#   - load_websync_profile (read a websync .conf file)
#   - create_deploy_conf_template (scaffold a new deploy.conf)
# ══════════════════════════════════════════════════════════════

# --- Shared constant ---
WEBSYNC_CONFIG_DIR="$HOME/.websync"

# ---------------------------------------------------------------
# parse_deploy_conf — reads deploy.conf into arrays (full version)
# ---------------------------------------------------------------
# Populates:
#   CONF_FILES[]     — array of secret-bearing file paths
#   Pattern files    — one per CONF_FILES entry at $2/<index>.patterns
#
# Usage: parse_deploy_conf "/path/to/deploy.conf" "/path/to/pattern_dir"
# ---------------------------------------------------------------
parse_deploy_conf() {
    local conf_file="$1"
    local pattern_dir="$2"

    CONF_FILES=()
    mkdir -p "$pattern_dir"

    local current_index=-1

    while IFS= read -r line; do
        # Strip inline comments and leading/trailing whitespace
        line="${line%%#*}"
        line="$(echo "$line" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"
        [[ -z "$line" ]] && continue

        if [[ "$line" == file\ * ]]; then
            ((current_index++))
            CONF_FILES+=("${line#file }")
            # Initialize empty patterns file for this entry
            > "$pattern_dir/${current_index}.patterns"
        elif [[ "$line" == patch\ * ]]; then
            if [[ $current_index -lt 0 ]]; then
                echo "  WARNING: 'patch' before any 'file' in deploy.conf — skipping"
                continue
            fi
            echo "${line#patch }" >> "$pattern_dir/${current_index}.patterns"
        else
            echo "  WARNING: unrecognized line in deploy.conf: $line"
        fi
    done < "$conf_file"
}

# ---------------------------------------------------------------
# parse_deploy_conf_files — reads file entries only from deploy.conf
# ---------------------------------------------------------------
# Populates CONF_FILES[] with the list of secret-bearing files.
# Lighter version for tools that don't need patch patterns.
#
# Usage: parse_deploy_conf_files "/path/to/deploy.conf"
# ---------------------------------------------------------------
parse_deploy_conf_files() {
    local conf_file="$1"
    CONF_FILES=()

    while IFS= read -r line; do
        # Strip inline comments and whitespace
        line="${line%%#*}"
        line="$(echo "$line" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"
        [[ -z "$line" ]] && continue

        if [[ "$line" == file\ * ]]; then
            CONF_FILES+=("${line#file }")
        fi
    done < "$conf_file"
}

# ---------------------------------------------------------------
# derive_masked_name — compute .masked filename from a path
# ---------------------------------------------------------------
# Dotfiles:  .htaccess        → .htaccess.masked
# Normal:    config.php        → config.masked.php
# No ext:    Makefile          → Makefile.masked
# With dir:  public/.htaccess  → public/.htaccess.masked
# ---------------------------------------------------------------
derive_masked_name() {
    local filepath="$1"
    local dir base name ext result

    dir="$(dirname "$filepath")"
    base="$(basename "$filepath")"

    if [[ "$base" == .* ]]; then
        # Dotfile: append .masked
        result="${base}.masked"
    else
        name="${base%.*}"
        ext="${base##*.}"
        if [[ "$name" == "$ext" ]]; then
            # No extension (e.g., Makefile)
            result="${base}.masked"
        else
            # Has extension: insert .masked before it
            result="${name}.masked.${ext}"
        fi
    fi

    if [[ "$dir" == "." ]]; then
        echo "$result"
    else
        echo "${dir}/${result}"
    fi
}

# ---------------------------------------------------------------
# cmd_list_profiles — list available websync profiles
# ---------------------------------------------------------------
# Shared by wd-deploy, wd-gitsync, wd-snapshot, wd-websync.
# Call directly for 'list' subcommand.
# ---------------------------------------------------------------
cmd_list_profiles() {
    if [[ ! -d "$WEBSYNC_CONFIG_DIR" ]]; then
        echo "No websync profiles found. Run 'wd-websync config <name>' to create one."
        exit 0
    fi

    local found=0
    echo "Available websync profiles:"

    for conf_file in "$WEBSYNC_CONFIG_DIR"/*.conf; do
        [[ -f "$conf_file" ]] || continue
        found=1

        local LOCAL_DIR="" REMOTE_HOST="" REMOTE_DIR="" EXCLUDES=""
        source "$conf_file"

        local name
        name="$(basename "$conf_file" .conf)"
        printf "  %-14s %s\n" "$name" "$LOCAL_DIR"
    done

    if [[ $found -eq 0 ]]; then
        echo "  (none)"
    fi
}

# ---------------------------------------------------------------
# load_websync_profile — reads a websync .conf file into env vars
# ---------------------------------------------------------------
# Sets: LOCAL_DIR, REMOTE_HOST, REMOTE_DIR, EXCLUDES
# Returns 0 on success, 1 if profile not found.
#
# Usage: load_websync_profile "profile_name"
# ---------------------------------------------------------------
load_websync_profile() {
    local profile_name="$1"
    local conf_file="$WEBSYNC_CONFIG_DIR/${profile_name}.conf"

    if [[ ! -f "$conf_file" ]]; then
        return 1
    fi

    source "$conf_file"
    return 0
}

# ---------------------------------------------------------------
# create_deploy_conf_template — scaffold a new deploy.conf
# ---------------------------------------------------------------
# Creates a commented template at $PROJECT_DIR/deploy.conf with
# syntax reference and common examples. Does nothing if the file
# already exists.
#
# Usage: create_deploy_conf_template "/path/to/project"
# Returns: 0 if created, 1 if already exists
# ---------------------------------------------------------------
create_deploy_conf_template() {
    local project_dir="$1"
    local conf_file="$project_dir/deploy.conf"

    if [[ -f "$conf_file" ]]; then
        return 1
    fi

    cat > "$conf_file" << 'TEMPLATE'
# deploy.conf — environment-specific file declarations
#
# Declares which files contain secrets. Used by:
#   - wd-deploy Stage 3  (save real values, generate .masked, patch)
#   - wd-gitsync          (credential safety gate — blocks push if
#                          real or .masked files aren't in .gitignore)
#   - wd-snapshot          (excludes real files from Claude output)
#
# ─── SETUP ───────────────────────────────────────────────────
# After adding entries here, also add each file AND its .masked
# counterpart to .gitignore. This is a one-time step per file.
#
# Example .gitignore entries for the declarations below:
#   config.php
#   config.masked.php
#   .env
#   .env.masked
#
# ─── SYNTAX ──────────────────────────────────────────────────
#   file <path>           Declares a secret-bearing file
#                         (path relative to project root)
#   patch <grep_pattern>  A line to capture and restore
#                         (belongs to the preceding file entry)
#
# The grep pattern is a fixed-string match — not a regex.
# It matches the beginning of a line to identify which lines
# contain environment-specific values.
#
# ─── EXAMPLES ────────────────────────────────────────────────
#
# PHP project:
#   file config.php
#   patch define('DB_HOST'
#   patch define('DB_PASS'
#   patch define('SMTP_HOST'
#
# Node / dotenv project:
#   file .env
#   patch DB_HOST=
#   patch DB_PASS=
#   patch API_KEY=
#
# Apache htaccess with server-specific paths:
#   file public/.htaccess
#   patch auto_prepend_file
#
# ─── YOUR DECLARATIONS ──────────────────────────────────────
# Uncomment and edit the lines below, or replace with your own.
#
# file config.php
# patch define('DB_HOST'
# patch define('DB_PASS'
#
TEMPLATE

    return 0
}
