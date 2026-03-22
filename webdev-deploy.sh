#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
# wd-deploy — full pipeline with rollback on failure
# ══════════════════════════════════════════════════════════════
# extract → distribute → env patch → push → git sync → snapshot → cleanup
#
# If any stage fails, all changes are rolled back:
#   - Overwritten files are restored from backup
#   - Newly created files are removed
#   - Server is re-pushed to its pre-deploy state
#   - Partial snapshots are cleaned up
#   - Source zip is preserved
#
# USAGE
#   wd-deploy <profile>                 Dry-run the full pipeline
#   wd-deploy <profile> -d FALSE        Execute everything for real
#   wd-deploy <profile> --no-git        Skip the git sync stage
#
# Requires: wd-websync, wd-snapshot, unzip, zip (installed and in PATH)
# Optional: wd-gitsync (auto-skipped if not installed or no .git present)
# Reads wd-websync profiles from ~/.websync/
# Reads deploy.conf from the project root for secret file declarations
#
# Dry-run by default. All stages are gated together —
# either everything runs dry, or everything runs live.
# ══════════════════════════════════════════════════════════════

set -uo pipefail

# --- Source shared library ---
source "$(dirname "$0")/wd-lib.sh" 2>/dev/null || {
    echo "Error: wd-lib.sh not found alongside $(basename "$0")."
    echo "Reinstall the deploy pipeline."
    exit 1
}

# --- Rollback tracking ---
# These get populated as the pipeline runs so rollback knows what to undo
ROLLBACK_DIR=""               # temp dir holding file backups
ROLLBACK_MANIFEST=""          # file listing backed-up originals
NEW_FILES_MANIFEST=""         # file listing newly created files
NEW_DIRS_MANIFEST=""          # dirs created by distribute
STAGING_DIR=""                # temp dir for zip extraction (set in Stage 1)
SNAPSHOT_OUTPUTS=()           # files/dirs created by snapshot stage
PIPELINE_STAGE="init"         # tracks where we are for error messages
ROLLBACK_TRIGGERED=0          # prevent double-rollback
GIT_SYNC_RAN="false"          # tracks whether git sync completed

# ---------------------------------------------------------------
# show_usage
# ---------------------------------------------------------------
show_usage() {
    echo "Usage:"
    echo "  wd-deploy <profile>              Dry-run the full pipeline"
    echo "  wd-deploy <profile> -d FALSE     Execute all stages for real"
    echo "  wd-deploy <profile> --no-git     Skip the git sync stage"
    echo "  wd-deploy list                   List available websync profiles"
    echo ""
    echo "Pipeline:"
    echo "  1. Extract    — unzip newest zip in project dir"
    echo "  2. Distribute — unflatten files into project tree"
    echo "  3. Env patch  — copy sanitized → .masked, patch real values"
    echo "  4. Push       — wd-websync push to server"
    echo "  5. Git sync   — wd-gitsync commit and push to GitHub"
    echo "  6. Snapshot   — backup zip + Claude-ready flat files"
    echo "  7. Cleanup    — delete the source zip"
    echo ""
    echo "Git sync (Stage 5) is automatic when .git exists and wd-gitsync"
    echo "is installed. Use --no-git to suppress. Skipped silently otherwise."
    echo ""
    echo "Reads deploy.conf from the project root to determine which"
    echo "files contain secrets and which lines to patch."
    echo ""
    echo "All stages roll back automatically on failure."
}

# ---------------------------------------------------------------
# preflight — verify required tools are available
# ---------------------------------------------------------------
preflight() {
    local missing=0

    for cmd in wd-websync wd-snapshot unzip zip; do
        if ! command -v "$cmd" &>/dev/null; then
            echo "Error: Required command '$cmd' not found in PATH."
            missing=1
        fi
    done

    if [[ $missing -eq 1 ]]; then
        echo ""
        echo "Install missing tools before running deploy."
        exit 1
    fi
}

# ---------------------------------------------------------------
# preflight_deploy_conf — warn about declared files not in project
# ---------------------------------------------------------------
# Non-blocking — just a heads-up if deploy.conf references files
# that don't exist in the project. Could indicate a typo or a
# first deploy where the files haven't been created yet.
# ---------------------------------------------------------------
preflight_deploy_conf() {
    local project_dir="$1"
    local missing=0

    for cf in "${CONF_FILES[@]}"; do
        if [[ ! -f "$project_dir/$cf" ]]; then
            if [[ $missing -eq 0 ]]; then
                echo ""
                echo "  ⚠️  deploy.conf references files not found in project:"
            fi
            echo "    - $cf"
            ((missing++))
        fi
    done

    if [[ $missing -gt 0 ]]; then
        echo ""
        echo "  These will be skipped during env patch (normal on first deploy)."
        echo "  If this is not a first deploy, check deploy.conf for typos."
    fi
}

# ---------------------------------------------------------------
# patch_line — replace a line in TARGET matching PATTERN with the
#              same line from SOURCE. Whole-line swap by line number.
# ---------------------------------------------------------------
# The pattern is a fixed-string grep match, not a regex. It is used
# twice: against the post-distribute file to find the target line
# number, and against the saved pre-distribute copy to extract the
# full replacement line. Awk swaps by line number — no regex on
# values, no escaping required.
#
# The || true after each pipeline suppresses SIGPIPE exit codes
# that can occur when head closes the pipe before grep finishes
# writing (relevant with set -o pipefail).
#
# Usage: patch_line SOURCE_FILE TARGET_FILE "GREP_PATTERN"
# ---------------------------------------------------------------
patch_line() {
    local src="$1" dst="$2" pattern="$3"

    # Get the real line from the saved (pre-distribute) copy
    local real_line
    real_line="$(grep -F "$pattern" "$src" 2>/dev/null | head -1 || true)"
    [[ -z "$real_line" ]] && return

    # Find the line number in the new (post-distribute) file
    local line_num
    line_num="$(grep -nF "$pattern" "$dst" 2>/dev/null | head -1 | cut -d: -f1 || true)"
    [[ -z "$line_num" ]] && return

    if [[ "$DRY_RUN" == "false" ]]; then
        # Uses ENVIRON instead of -v to avoid awk interpreting C-style escape
        # sequences in the value (backslashes in passwords, paths, etc.).
        export __PATCH_LINE="$real_line"
        awk -v n="$line_num" \
            'NR==n {print ENVIRON["__PATCH_LINE"]; next} {print}' \
            "$dst" > "${dst}.tmp" && mv "${dst}.tmp" "$dst"
        unset __PATCH_LINE
        echo "    PATCHED: $pattern"
        ((patch_count++))
    else
        echo "    DRY RUN PATCH: $pattern"
    fi
}

# ---------------------------------------------------------------
# rollback_distribute — restore local files to pre-deploy state
# ---------------------------------------------------------------
rollback_distribute() {
    local errors=0

    # --- Restore overwritten files from backup ---
    if [[ -n "$ROLLBACK_MANIFEST" && -f "$ROLLBACK_MANIFEST" ]]; then
        echo "  Restoring overwritten files..."
        while IFS=$'\t' read -r backup_path original_path; do
            if [[ -f "$backup_path" ]]; then
                cp -p "$backup_path" "$original_path" 2>/dev/null
                if [[ $? -eq 0 ]]; then
                    echo "    RESTORED: $original_path"
                else
                    echo "    ERROR restoring: $original_path"
                    ((errors++))
                fi
            fi
        done < "$ROLLBACK_MANIFEST"
    fi

    # --- Remove newly created files ---
    if [[ -n "$NEW_FILES_MANIFEST" && -f "$NEW_FILES_MANIFEST" ]]; then
        echo "  Removing newly created files..."
        while IFS= read -r new_file; do
            if [[ -f "$new_file" ]]; then
                rm -f "$new_file" 2>/dev/null
                if [[ $? -eq 0 ]]; then
                    echo "    REMOVED: $new_file"
                else
                    echo "    ERROR removing: $new_file"
                    ((errors++))
                fi
            fi
        done < "$NEW_FILES_MANIFEST"
    fi

    # --- Remove newly created directories (reverse order, only if empty) ---
    if [[ -n "$NEW_DIRS_MANIFEST" && -f "$NEW_DIRS_MANIFEST" ]]; then
        echo "  Removing empty directories created by distribute..."
        while IFS= read -r new_dir; do
            if [[ -d "$new_dir" ]]; then
                if [[ -z "$(ls -A "$new_dir" 2>/dev/null)" ]]; then
                    rmdir "$new_dir" 2>/dev/null
                    if [[ $? -eq 0 ]]; then
                        echo "    REMOVED DIR: $new_dir"
                    else
                        ((errors++))
                    fi
                fi
            fi
        done < <(sort -r "$NEW_DIRS_MANIFEST")
    fi

    return $errors
}

# ---------------------------------------------------------------
# rollback_push — re-push pre-deploy local state to server
# ---------------------------------------------------------------
rollback_push() {
    echo "  Re-pushing pre-deploy state to server..."
    # Pipe 'yes' to bypass websync's first-push confirmation if triggered
    echo "yes" | wd-websync push "$PROFILE_NAME" -d FALSE
    if [[ $? -eq 0 ]]; then
        echo "  Server restored to pre-deploy state."
        return 0
    else
        echo "  ⚠️  Could not re-push to server. Server may be in a mixed state."
        echo "     Once the issue is resolved, run: wd-websync push $PROFILE_NAME -d FALSE"
        return 1
    fi
}

# ---------------------------------------------------------------
# rollback_snapshot — clean up partial snapshot outputs
# ---------------------------------------------------------------
rollback_snapshot() {
    if [[ ${#SNAPSHOT_OUTPUTS[@]} -gt 0 ]]; then
        echo "  Cleaning up snapshot outputs..."
        for item in "${SNAPSHOT_OUTPUTS[@]}"; do
            if [[ -d "$item" ]]; then
                rm -rf "$item"
                echo "    REMOVED DIR: $item"
            elif [[ -f "$item" ]]; then
                rm -f "$item"
                echo "    REMOVED: $item"
            fi
        done
    fi
}

# ---------------------------------------------------------------
# rollback_all — undo everything back to pre-deploy state
# ---------------------------------------------------------------
rollback_all() {
    # Prevent double-rollback
    if [[ $ROLLBACK_TRIGGERED -eq 1 ]]; then
        return
    fi
    ROLLBACK_TRIGGERED=1

    echo ""
    echo "  Rolling back ALL stages..."
    echo ""

    local total_errors=0

    # Snapshot outputs
    rollback_snapshot

    # Re-push original state to server (only if we got past distribute)
    if [[ "$PIPELINE_STAGE" == "push" || "$PIPELINE_STAGE" == "gitsync" || "$PIPELINE_STAGE" == "snapshot" ]]; then
        # First restore local files, then push the restored state
        rollback_distribute
        ((total_errors += $?))
        echo ""
        rollback_push
        ((total_errors += $?))
    else
        # Still in distribute or env_patch — just restore local
        rollback_distribute
        ((total_errors += $?))
    fi

    echo ""
    if [[ $total_errors -gt 0 ]]; then
        echo "  Rollback completed with $total_errors error(s)."
        echo "  Check the deploy log for details and manually verify."
    else
        echo "  Full rollback complete. Project restored to pre-deploy state."
    fi
    echo "  Source zip preserved: $ZIP_NAME"
    echo ""
}

# ---------------------------------------------------------------
# fail — log error, present rollback options, and exit
# ---------------------------------------------------------------
fail() {
    local message="$1"
    echo ""
    echo "══════════════════════════════════════════════════════════════"
    echo "  ⚠️  FAILURE during: $PIPELINE_STAGE"
    echo "══════════════════════════════════════════════════════════════"
    echo ""
    echo "  $message"
    echo ""

    if [[ "$DRY_RUN" == "false" ]]; then
        case "$PIPELINE_STAGE" in
            extract)
                echo "  Nothing to roll back (extraction failed before any changes were made)."
                ;;
            distribute)
                echo "  Rolling back local file changes..."
                echo ""
                rollback_distribute
                echo ""
                echo "  Local files restored. Source zip preserved: $ZIP_NAME"
                ;;
            env_patch)
                echo "  Env patch failed. Rolling back local file changes..."
                echo ""
                rollback_distribute
                echo ""
                echo "  Local files restored. Source zip preserved: $ZIP_NAME"
                ;;
            push)
                echo "  The local files have been updated but the push to server failed."
                echo ""
                echo "  Options:"
                echo "    s = Stop here (keep local changes, fix the issue, re-run wd-websync push manually)"
                echo "    a = Roll back ALL (restore local files to pre-deploy state)"
                echo ""
                echo -n "  Choice (s/a): "
                read -r choice
                choice_lower="$(echo "$choice" | tr '[:upper:]' '[:lower:]')"

                if [[ "$choice_lower" == "a" ]]; then
                    rollback_all
                else
                    echo ""
                    echo "  Stopped. Local changes preserved."
                    echo "  When ready, push manually: wd-websync push $PROFILE_NAME -d FALSE"
                    echo "  Source zip preserved: $ZIP_NAME"
                fi
                ;;
            snapshot)
                echo "  Push to server succeeded, but snapshot failed."
                echo ""
                echo "  Options:"
                echo "    s = Stop here (keep changes + push, snapshot can be re-run manually)"
                echo "    a = Roll back ALL (restore local files, re-push original state to server)"
                echo ""
                echo -n "  Choice (s/a): "
                read -r choice
                choice_lower="$(echo "$choice" | tr '[:upper:]' '[:lower:]')"

                if [[ "$choice_lower" == "a" ]]; then
                    rollback_all
                else
                    rollback_snapshot
                    echo ""
                    echo "  Stopped. Local changes and server push preserved."
                    echo "  Partial snapshot outputs cleaned up."
                    echo "  Re-run snapshot manually: wd-snapshot $PROFILE_NAME"
                    echo "  Source zip preserved: $ZIP_NAME"
                fi
                ;;
        esac
    else
        echo "  (Dry run — no changes were made, nothing to roll back.)"
    fi

    echo ""
    echo "  Log: $DEPLOY_LOG"
    exit 1
}

# ---------------------------------------------------------------
# Main
# ---------------------------------------------------------------

# Handle no args
if [[ $# -eq 0 ]]; then
    show_usage
    exit 0
fi

# Handle list
if [[ "$1" == "list" ]]; then
    cmd_list_profiles
    exit 0
fi

# Handle help
if [[ "$1" == "-h" || "$1" == "--help" || "$1" == "help" ]]; then
    show_usage
    exit 0
fi

# --- Pre-flight: verify dependencies ---
preflight

# --- Parse arguments ---
DRY_RUN="true"
SKIP_GIT="false"
POSITIONAL=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d)
            if [[ $# -lt 2 ]]; then
                echo "Error: -d requires a value (e.g. -d FALSE)"
                exit 1
            fi
            flag_val="$(echo "$2" | tr '[:upper:]' '[:lower:]')"
            if [[ "$flag_val" == "false" ]]; then
                DRY_RUN="false"
            fi
            shift 2
            ;;
        --no-git)
            SKIP_GIT="true"
            shift
            ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done

PROFILE_NAME="${POSITIONAL[0]:-}"

if [[ -z "$PROFILE_NAME" ]]; then
    echo "Error: No profile specified."
    show_usage
    exit 1
fi

# --- Load websync profile ---
CONF_FILE="$WEBSYNC_CONFIG_DIR/${PROFILE_NAME}.conf"
if [[ ! -f "$CONF_FILE" ]]; then
    echo "Error: Profile '$PROFILE_NAME' not found."
    echo "Run 'wd-websync config $PROFILE_NAME' to create it."
    exit 1
fi

LOCAL_DIR=""
REMOTE_HOST=""
REMOTE_DIR=""
EXCLUDES=""
source "$CONF_FILE"

# Expand tilde in LOCAL_DIR
PROJECT_DIR="${LOCAL_DIR/#\~/$HOME}"
PROJECT_DIR="${PROJECT_DIR%/}"

if [[ ! -d "$PROJECT_DIR" ]]; then
    echo "Error: Project directory does not exist: $PROJECT_DIR"
    exit 1
fi

PROJECT_NAME="$(basename "$PROJECT_DIR")"
TIMESTAMP="$(date '+%y%m%d_%H%M%S')"

# --- Set up deploy action log ---
SNAPSHOTS_DIR="$(dirname "$PROJECT_DIR")/snapshots/$PROJECT_NAME"
mkdir -p "$SNAPSHOTS_DIR"
DEPLOY_LOG="$SNAPSHOTS_DIR/${PROJECT_NAME}-deploy-${TIMESTAMP}.log"

# Tee all output to both console and log file
exec > >(tee -a "$DEPLOY_LOG") 2>&1

# --- Set up rollback infrastructure ---
ROLLBACK_DIR="$(mktemp -d)"
ROLLBACK_MANIFEST="$ROLLBACK_DIR/overwritten.tsv"
NEW_FILES_MANIFEST="$ROLLBACK_DIR/new_files.txt"
NEW_DIRS_MANIFEST="$ROLLBACK_DIR/new_dirs.txt"
touch "$ROLLBACK_MANIFEST" "$NEW_FILES_MANIFEST" "$NEW_DIRS_MANIFEST"

# Clean up rollback dir on exit (but NOT the deploy log)
trap 'rm -rf "$ROLLBACK_DIR" "$STAGING_DIR" 2>/dev/null; wait' EXIT

# Catch Ctrl+C and termination signals — trigger rollback before exiting
handle_interrupt() {
    echo ""
    echo "  Interrupted (signal received)."
    if [[ "$DRY_RUN" == "false" && "$PIPELINE_STAGE" != "init" && "$PIPELINE_STAGE" != "done" ]]; then
        fail "Pipeline interrupted by signal during: $PIPELINE_STAGE"
    else
        exit 1
    fi
}
trap 'handle_interrupt' INT TERM

# --- Parse deploy.conf ---
# Reads the project's secret-file declarations. If deploy.conf is
# missing, the pipeline offers to create a template, then continues
# with Stage 3 (env patch) as a no-op.
DEPLOY_CONF="$PROJECT_DIR/deploy.conf"
CONF_FILES=()
CONF_PATTERN_DIR="$ROLLBACK_DIR/conf_patterns"

if [[ -f "$DEPLOY_CONF" ]]; then
    parse_deploy_conf "$DEPLOY_CONF" "$CONF_PATTERN_DIR"
    echo "deploy.conf: ${#CONF_FILES[@]} secret file(s) declared"
    if [[ ${#CONF_FILES[@]} -gt 0 ]]; then
        for cf in "${CONF_FILES[@]}"; do
            echo "  - $cf"
        done
        # Warn about declared files that don't exist in the project
        preflight_deploy_conf "$PROJECT_DIR"
    fi
    echo ""
else
    echo "deploy.conf: not found in $PROJECT_DIR"
    echo ""

    # Offer to create a template
    echo -n "  Create a deploy.conf template? (y/n): "
    read -r create_conf
    create_conf_lower="$(echo "$create_conf" | tr '[:upper:]' '[:lower:]')"

    if [[ "$create_conf_lower" == "y" || "$create_conf_lower" == "yes" ]]; then
        create_deploy_conf_template "$PROJECT_DIR"
        echo "  Created: $DEPLOY_CONF"
        echo "  Edit this file to declare your secret-bearing files."
        echo ""

        # Open in editor if available and user wants to
        editor="${EDITOR:-$(command -v nano 2>/dev/null || command -v vi 2>/dev/null || true)}"
        if [[ -n "$editor" ]]; then
            echo -n "  Open in editor now? (y/n): "
            read -r open_editor
            open_editor_lower="$(echo "$open_editor" | tr '[:upper:]' '[:lower:]')"
            if [[ "$open_editor_lower" == "y" || "$open_editor_lower" == "yes" ]]; then
                "$editor" "$DEPLOY_CONF"
                # Re-parse after editing
                if [[ -s "$DEPLOY_CONF" ]]; then
                    parse_deploy_conf "$DEPLOY_CONF" "$CONF_PATTERN_DIR"
                    echo ""
                    echo "  deploy.conf: ${#CONF_FILES[@]} secret file(s) declared after editing"
                fi
            fi
        fi
    else
        echo "  Stage 3 (env patch) will be skipped."
        echo "  Create deploy.conf later to declare secret-bearing files."
    fi
    echo ""
fi

# --- Find the zip to process ---
# Prefer files.zip if it exists, otherwise grab the newest zip
# Excludes snapshot zips to avoid grabbing old backups
TARGET_ZIP=""

if [[ -f "$PROJECT_DIR/files.zip" ]]; then
    TARGET_ZIP="$PROJECT_DIR/files.zip"
else
    TARGET_ZIP=$(find "$PROJECT_DIR" -maxdepth 1 -name '*.zip' \
        -not -name '*-snapshot-*' \
        -type f -print0 \
        | xargs -0 ls -t 2>/dev/null \
        | head -1)
fi

if [[ -z "$TARGET_ZIP" ]]; then
    echo "Error: No zip files found in $PROJECT_DIR"
    exit 1
fi

ZIP_NAME="$(basename "$TARGET_ZIP")"

# --- Confirm zip selection ---
echo "Detected zip: $ZIP_NAME"

# List any other non-snapshot zips in case the wrong one was picked
other_zips=$(find "$PROJECT_DIR" -maxdepth 1 -name '*.zip' \
    -not -name '*-snapshot-*' \
    -type f \
    | while IFS= read -r z; do
        bname="$(basename "$z")"
        [[ "$bname" != "$ZIP_NAME" ]] && echo "  $bname"
    done)

if [[ -n "$other_zips" ]]; then
    echo "Other zips found:"
    echo "$other_zips"
fi

echo -n "Proceed with $ZIP_NAME? (y/Enter/n/filename): "
read -r zip_confirm

zip_confirm_lower="$(echo "$zip_confirm" | tr '[:upper:]' '[:lower:]')"

if [[ "$zip_confirm_lower" == "n" || "$zip_confirm_lower" == "no" ]]; then
    echo "Aborted."
    exit 0
elif [[ -z "$zip_confirm" || "$zip_confirm_lower" == "y" || "$zip_confirm_lower" == "yes" ]]; then
    :
else
    if [[ -f "$PROJECT_DIR/$zip_confirm" ]]; then
        TARGET_ZIP="$PROJECT_DIR/$zip_confirm"
        ZIP_NAME="$zip_confirm"
        echo "Using: $ZIP_NAME"
    else
        echo "Error: '$zip_confirm' not found in $PROJECT_DIR"
        exit 1
    fi
fi

echo ""

# --- Staging area for extracted files ---
STAGING_DIR="$(mktemp -d)"

# ══════════════════════════════════════════════════════════════
# Header
# ══════════════════════════════════════════════════════════════
echo "══════════════════════════════════════════════════════════════"
if [[ "$DRY_RUN" == "true" ]]; then
    echo "  wd-deploy — DRY RUN — $(date '+%Y-%m-%d %H:%M:%S')"
else
    echo "  wd-deploy — LIVE RUN — $(date '+%Y-%m-%d %H:%M:%S')"
fi
echo "══════════════════════════════════════════════════════════════"
echo ""
echo "  Profile:    $PROFILE_NAME"
echo "  Project:    $PROJECT_DIR"
echo "  Zip:        $ZIP_NAME"
echo "  Deploy log: $DEPLOY_LOG"
echo ""

# ══════════════════════════════════════════════════════════════
# STAGE 1: Extract zip to staging
# ══════════════════════════════════════════════════════════════
PIPELINE_STAGE="extract"
echo "── Stage 1: Extract ─────────────────────────────────────────"
echo "  Source: $TARGET_ZIP"

unzip -q -o "$TARGET_ZIP" -d "$STAGING_DIR"
if [[ $? -ne 0 ]]; then
    fail "Failed to extract $ZIP_NAME. The zip may be corrupted."
fi

# Remove __MACOSX junk if present (macOS zip artifact)
if [[ -d "$STAGING_DIR/__MACOSX" ]]; then
    rm -rf "$STAGING_DIR/__MACOSX"
    echo "  Removed __MACOSX metadata folder"
fi

# The zip may contain a top-level folder or flat files.
# Detect: if staging has exactly one directory and no files, go into it.
EXTRACT_ROOT="$STAGING_DIR"

file_count=0
for item in "$STAGING_DIR"/*; do
    [[ -f "$item" ]] && ((file_count++))
done

dir_count=0
for item in "$STAGING_DIR"/*/; do
    [[ -d "$item" ]] && ((dir_count++))
done

if [[ $dir_count -eq 1 && $file_count -eq 0 ]]; then
    for d in "$STAGING_DIR"/*/; do
        EXTRACT_ROOT="${d%/}"
    done
    echo "  Detected top-level folder: $(basename "$EXTRACT_ROOT")"
fi

extracted_count=$(find "$EXTRACT_ROOT" -type f | wc -l | tr -d ' ')
echo "  Extracted $extracted_count files to staging"

if [[ $extracted_count -eq 0 ]]; then
    fail "Zip extracted but contained no files."
fi

echo ""

# ══════════════════════════════════════════════════════════════
# PRE-DISTRIBUTE: Capture real values from local files
# ══════════════════════════════════════════════════════════════
# Before distribute overwrites local files, save copies of every
# file declared in deploy.conf. These copies preserve the real
# environment-specific values for patching in Stage 3.
#
# If a file doesn't exist yet (first deploy), capture is skipped
# for that file and Stage 3 will skip patching it.
# ──────────────────────────────────────────────────────────────

ENV_SAVED_DIR="$ROLLBACK_DIR/env_saved"
mkdir -p "$ENV_SAVED_DIR"

echo "── Pre-distribute: Saving environment files ───────────────────"

if [[ ${#CONF_FILES[@]} -eq 0 ]]; then
    echo "  No files declared in deploy.conf — nothing to save"
else
    for cf in "${CONF_FILES[@]}"; do
        local_file="$PROJECT_DIR/$cf"
        if [[ -f "$local_file" ]]; then
            saved_subdir="$ENV_SAVED_DIR/$(dirname "$cf")"
            mkdir -p "$saved_subdir"
            cp -p "$local_file" "$ENV_SAVED_DIR/$cf"
            echo "  Saved: $cf"
        else
            echo "  Not found (first deploy — Stage 3 will skip): $cf"
        fi
    done
fi

echo ""

# ══════════════════════════════════════════════════════════════
# STAGE 2: Distribute (unflatten files into project tree)
# ══════════════════════════════════════════════════════════════
# Files with __ in the name are unflattened into subdirectories:
#   core__footer.php → core/footer.php
#
# Files WITHOUT __ are treated as root-level project files:
#   index.php → index.php (project root)
#
# Every file in the zip is distributed. The zip should contain
# only project files intended for the working tree.
# ──────────────────────────────────────────────────────────────
PIPELINE_STAGE="distribute"
echo "── Stage 2: Distribute ──────────────────────────────────────"

dist_copied=0
dist_deleted=0

for filepath in "$EXTRACT_ROOT"/*; do
    [[ -f "$filepath" ]] || continue

    filename="$(basename "$filepath")"

    # Determine relative path: __ becomes /, bare names stay at root
    if [[ "$filename" == *__* ]]; then
        relative_path="${filename//__//}"
    else
        relative_path="$filename"
    fi

    dest_path="$PROJECT_DIR/$relative_path"
    dest_dir="$(dirname "$dest_path")"

    if [[ "$DRY_RUN" == "false" ]]; then
        # --- Backup existing file before overwriting ---
        if [[ -e "$dest_path" ]]; then
            backup_subdir="$ROLLBACK_DIR/backup/$(dirname "$relative_path")"
            mkdir -p "$backup_subdir"
            backup_path="$backup_subdir/$(basename "$dest_path")"

            cp -p "$dest_path" "$backup_path"
            if [[ $? -ne 0 ]]; then
                fail "Failed to backup $relative_path before overwriting."
            fi

            printf '%s\t%s\n' "$backup_path" "$dest_path" >> "$ROLLBACK_MANIFEST"

            rm -- "$dest_path"
            echo "  DELETED: $relative_path"
            ((dist_deleted++))
        fi

        # --- Create dirs (track new ones for rollback) ---
        if [[ ! -d "$dest_dir" ]]; then
            check_dir="$dest_dir"
            new_dirs_stack=()
            while [[ ! -d "$check_dir" ]]; do
                new_dirs_stack+=("$check_dir")
                check_dir="$(dirname "$check_dir")"
            done

            mkdir -p "$dest_dir"

            for nd in "${new_dirs_stack[@]}"; do
                echo "$nd" >> "$NEW_DIRS_MANIFEST"
            done
        fi

        # --- Copy the file ---
        cp -p "$filepath" "$dest_path"
        if [[ $? -ne 0 ]]; then
            fail "Failed to copy $filename to $relative_path."
        fi

        # If this file didn't exist before (no backup was made), track as new
        if ! grep -qF "$dest_path" "$ROLLBACK_MANIFEST" 2>/dev/null; then
            echo "$dest_path" >> "$NEW_FILES_MANIFEST"
        fi

        echo "  COPIED:  $filename -> $relative_path"
    else
        if [[ -e "$dest_path" ]]; then
            echo "  DRY RUN DELETE: $relative_path"
            ((dist_deleted++))
        fi
        echo "  DRY RUN COPY:   $filename -> $relative_path"
    fi
    ((dist_copied++))
done

echo ""
echo "  Files distributed: $dist_copied"
echo "  Files deleted:     $dist_deleted"

# Sanity check: warn if extracted count doesn't match processed count
if [[ $extracted_count -ne $dist_copied ]]; then
    echo ""
    echo "  ⚠️  WARNING: Extracted $extracted_count files but only processed $dist_copied."
    echo "     $((extracted_count - dist_copied)) files were in subdirectories and were not distributed."
    echo "     Deploy expects flat files at the zip root (with __ delimiters for subdirectories)."
fi

if [[ $dist_copied -eq 0 ]]; then
    fail "No files were distributed. Check that the zip contains files at its root level."
fi

echo ""

# ══════════════════════════════════════════════════════════════
# STAGE 3: Env patch (driven by deploy.conf)
# ══════════════════════════════════════════════════════════════
# Two operations per file declared in deploy.conf:
#   A. Copy sanitized version → .masked (for Claude)
#   B. Patch real values back into the working copy
#
# .masked files contain the structure with sentinel placeholders
# (e.g. ********). Claude uses these to understand the config
# layout without seeing real credentials.
#
# .example files are maintained by the developer (or Claude the
# AI) as onboarding templates — the pipeline does not touch them.
#
# If deploy.conf is missing or empty, this stage is a no-op.
# If a file wasn't present locally before distribute (first
# deploy), .masked is still created but patching is skipped.
#
# .masked files are tracked in the rollback manifest so they
# are restored (or removed) on failure like any other file.
# ──────────────────────────────────────────────────────────────
PIPELINE_STAGE="env_patch"
echo "── Stage 3: Env patch ───────────────────────────────────────"

patch_count=0

if [[ ${#CONF_FILES[@]} -eq 0 ]]; then
    echo "  No files declared in deploy.conf — skipping"
else
    for i in "${!CONF_FILES[@]}"; do
        cf="${CONF_FILES[$i]}"
        local_file="$PROJECT_DIR/$cf"
        saved_file="$ENV_SAVED_DIR/$cf"
        masked_name="$(derive_masked_name "$cf")"
        masked_path="$PROJECT_DIR/$masked_name"

        echo ""
        echo "  ── $cf ──"

        # --- A. Copy sanitized → .masked ---
        if [[ -f "$local_file" ]]; then
            mkdir -p "$(dirname "$masked_path")"
            if [[ "$DRY_RUN" == "false" ]]; then
                # Track .masked file for rollback before creating/overwriting
                if [[ -e "$masked_path" ]]; then
                    # Existing .masked — back it up
                    backup_subdir="$ROLLBACK_DIR/backup/$(dirname "$masked_name")"
                    mkdir -p "$backup_subdir"
                    backup_path="$backup_subdir/$(basename "$masked_path")"
                    cp -p "$masked_path" "$backup_path"
                    printf '%s\t%s\n' "$backup_path" "$masked_path" >> "$ROLLBACK_MANIFEST"
                else
                    # New .masked — track for removal on rollback
                    echo "$masked_path" >> "$NEW_FILES_MANIFEST"
                fi

                cp -p "$local_file" "$masked_path"
                echo "  MASKED: $cf -> $masked_name"
            else
                echo "  DRY RUN MASKED: $cf -> $masked_name"
            fi
        else
            echo "  Not in zip — skipping .masked copy"
        fi

        # --- B. Patch real values from saved copy ---
        pattern_file="$CONF_PATTERN_DIR/${i}.patterns"

        if [[ ! -f "$saved_file" ]]; then
            echo "  No saved copy (first deploy) — skipping patch"
            continue
        fi

        if [[ ! -f "$local_file" ]]; then
            echo "  File not in zip — skipping patch"
            continue
        fi

        if [[ ! -f "$pattern_file" ]] || [[ ! -s "$pattern_file" ]]; then
            echo "  No patch patterns declared — skipping patch"
            continue
        fi

        echo "  Patching..."
        while IFS= read -r pattern; do
            [[ -z "$pattern" ]] && continue
            patch_line "$saved_file" "$local_file" "$pattern"
        done < "$pattern_file"
    done
fi

echo ""
echo "  $patch_count values patched"
echo ""

# ══════════════════════════════════════════════════════════════
# STAGE 4: Push to server via websync
# ══════════════════════════════════════════════════════════════
# Pushes changed local project files to the web server via rsync.
# Only modified files are transferred. Files deleted locally are
# NOT removed on the server — this is a copy, not a mirror.
# ──────────────────────────────────────────────────────────────
PIPELINE_STAGE="push"
echo "── Stage 4: Push to server ──────────────────────────────────"

if [[ "$DRY_RUN" == "false" ]]; then
    wd-websync push "$PROFILE_NAME" -d FALSE
    push_exit=$?

    if [[ $push_exit -ne 0 ]]; then
        fail "wd-websync push failed (exit code $push_exit)."
    fi
else
    wd-websync push "$PROFILE_NAME"
    push_exit=$?

    if [[ $push_exit -ne 0 ]]; then
        echo "  ⚠️  Dry-run push returned exit code $push_exit (may be expected in dry run)"
    fi
fi

echo ""

# ══════════════════════════════════════════════════════════════
# STAGE 5: Git sync (optional — requires .git and wd-gitsync)
# ══════════════════════════════════════════════════════════════
# Commits and pushes to the git remote. Skipped automatically if:
#   - --no-git flag was passed
#   - wd-gitsync is not installed
#   - Project is not a git repository
#
# wd-gitsync handles its own safety gate (deploy.conf vs .gitignore)
# and will block the push if secret files aren't properly ignored.
#
# Non-fatal: git sync failure does NOT trigger a full rollback.
# The server push already succeeded — we offer to continue or stop.
# ──────────────────────────────────────────────────────────────
PIPELINE_STAGE="gitsync"
echo "── Stage 5: Git sync ──────────────────────────────────────────"

GIT_SYNC_RAN="false"

if [[ "$SKIP_GIT" == "true" ]]; then
    echo "  Skipped (--no-git flag)"
elif ! command -v wd-gitsync &>/dev/null; then
    echo "  Skipped (wd-gitsync not installed)"
elif [[ ! -d "$PROJECT_DIR/.git" ]]; then
    echo "  Skipped (not a git repository)"
else
    if [[ "$DRY_RUN" == "false" ]]; then
        wd-gitsync "$PROFILE_NAME" -d FALSE
        gitsync_exit=$?

        if [[ $gitsync_exit -ne 0 ]]; then
            echo ""
            echo "  ⚠️  Git sync failed (exit code $gitsync_exit)."
            echo "  Server push succeeded. Local files are correct."
            echo ""
            echo "  Options:"
            echo "    c = Continue to snapshot (skip git for now)"
            echo "    s = Stop here (re-run git sync manually later)"
            echo ""
            echo -n "  Choice (c/s): "
            read -r git_choice
            git_choice_lower="$(echo "$git_choice" | tr '[:upper:]' '[:lower:]')"

            if [[ "$git_choice_lower" == "s" ]]; then
                echo ""
                echo "  Stopped. Server push preserved. Re-run git sync manually:"
                echo "    wd-gitsync $PROFILE_NAME -d FALSE"
                echo ""
                echo "  Log: $DEPLOY_LOG"
                exit 1
            else
                echo "  Continuing to snapshot..."
            fi
        else
            GIT_SYNC_RAN="true"
        fi
    else
        wd-gitsync "$PROFILE_NAME"
        gitsync_exit=$?

        if [[ $gitsync_exit -ne 0 ]]; then
            echo "  ⚠️  Dry-run git sync returned exit code $gitsync_exit"
        fi
    fi
fi

echo ""

# ══════════════════════════════════════════════════════════════
# STAGE 6: Snapshot
# ══════════════════════════════════════════════════════════════
PIPELINE_STAGE="snapshot"
echo "── Stage 6: Snapshot ────────────────────────────────────────"

if [[ "$DRY_RUN" == "false" ]]; then
    SNAPSHOT_CLAUDE_DIR="$SNAPSHOTS_DIR/${PROJECT_NAME}-for-claude"
    pre_snap_files=$(find "$SNAPSHOTS_DIR" -maxdepth 1 -type f 2>/dev/null | sort)

    wd-snapshot "$PROFILE_NAME" -d FALSE
    snap_exit=$?

    post_snap_files=$(find "$SNAPSHOTS_DIR" -maxdepth 1 -type f 2>/dev/null | sort)
    new_snap_files=$(comm -13 <(echo "$pre_snap_files") <(echo "$post_snap_files"))

    if [[ -d "$SNAPSHOT_CLAUDE_DIR" ]]; then
        SNAPSHOT_OUTPUTS+=("$SNAPSHOT_CLAUDE_DIR")
    fi
    while IFS= read -r sf; do
        [[ -n "$sf" ]] && SNAPSHOT_OUTPUTS+=("$sf")
    done <<< "$new_snap_files"

    if [[ $snap_exit -ne 0 ]]; then
        fail "Snapshot failed (exit code $snap_exit)."
    fi
else
    echo "  DRY RUN: Would create snapshot and for-claude output"
    echo "  Location: $SNAPSHOTS_DIR/"
    snap_exit=0
fi

echo ""

# ══════════════════════════════════════════════════════════════
# STAGE 7: Cleanup — delete source zip
# ══════════════════════════════════════════════════════════════
PIPELINE_STAGE="cleanup"
echo "── Stage 7: Cleanup ─────────────────────────────────────────"

if [[ "$DRY_RUN" == "false" ]]; then
    rm -f "$TARGET_ZIP"
    if [[ $? -ne 0 ]]; then
        echo "  ⚠️  WARNING: Could not delete $ZIP_NAME"
        echo "     All other stages completed successfully."
    else
        echo "  DELETED: $ZIP_NAME"
    fi
else
    echo "  DRY RUN: Would delete $ZIP_NAME"
fi

echo ""

# ══════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════
PIPELINE_STAGE="done"
echo "══════════════════════════════════════════════════════════════"
if [[ "$DRY_RUN" == "true" ]]; then
    echo "  DRY RUN complete — $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  Pass -d FALSE to execute all stages."
else
    echo "  Deploy complete — $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  $dist_copied files distributed, pushed, and snapshotted."
    if [[ "$GIT_SYNC_RAN" == "true" ]]; then
        echo "  Git: committed and pushed."
    elif [[ "$SKIP_GIT" == "true" ]]; then
        echo "  Git: skipped (--no-git)."
    fi
fi
echo "  Log: $DEPLOY_LOG"
echo "══════════════════════════════════════════════════════════════"
echo ""
