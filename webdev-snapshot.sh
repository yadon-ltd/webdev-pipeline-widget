#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
# wd-snapshot — project snapshot for Claude upload + backup
# ══════════════════════════════════════════════════════════════
# Reads a local project directory (via websync profile or path)
# and produces two outputs alongside the project folder:
#
#   1. <project>-for-claude/  — flat files with __ delimiters
#      e.g. core/footer.php → core__footer.php
#      Root-level files keep their bare name (no __ prefix).
#      Ready to drag into a Claude project.
#
#   2. <project>-snapshot-<timestamp>.zip — full directory tree
#      with a snapshot log inside (tree, file detail, checksums).
#      Backup-ready, can be restored directly.
#
# USAGE
#   wd-snapshot <profile>             Dry-run (preview what would happen)
#   wd-snapshot <profile> -d FALSE    Execute snapshot for real
#   wd-snapshot /path/to/project      Use a direct path (dry-run)
#   wd-snapshot list                  List available websync profiles
#
# Dry-run by default. Pass -d FALSE to execute.
#
# Excludes .git/, .DS_Store, plus any EXCLUDES from the
# websync profile. Previous for-claude/ folders are cleared
# on each run.
#
# Reads deploy.conf from the project root to determine which
# files contain secrets and should be excluded from the
# for-claude/ output. If deploy.conf is absent, no files are
# excluded beyond .git and .DS_Store.
# ══════════════════════════════════════════════════════════════

set -uo pipefail

# --- Source shared library ---
source "$(dirname "$0")/wd-lib.sh" 2>/dev/null || {
    echo "Error: wd-lib.sh not found alongside $(basename "$0")."
    echo "Reinstall the deploy pipeline."
    exit 1
}

# ---------------------------------------------------------------
# show_usage — prints help text
# ---------------------------------------------------------------
show_usage() {
    echo "Usage:"
    echo "  wd-snapshot <profile>           Dry-run snapshot (preview only)"
    echo "  wd-snapshot <profile> -d FALSE   Execute snapshot for real"
    echo "  wd-snapshot /path/to/project    Use a direct path (dry-run)"
    echo "  wd-snapshot list                List available websync profiles"
    echo ""
    echo "Options:"
    echo "  -d FALSE         Disable dry run (execute for real)"
    echo ""
    echo "Outputs (placed alongside the project folder):"
    echo "  <project>-for-claude/                Flat files for Claude upload"
    echo "  <project>-snapshot-<timestamp>.zip   Backup with snapshot log"
}

# ---------------------------------------------------------------
# generate_log — creates the snapshot log content
# ---------------------------------------------------------------
generate_log() {
    local project_dir="$1"
    local project_name="$2"

    echo "══════════════════════════════════════════════════════════════"
    echo "  ${project_name} — Snapshot Log"
    echo "  Generated: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  Host:      $(hostname)"
    echo "  Source:     $project_dir"
    echo "══════════════════════════════════════════════════════════════"
    echo ""

    # --- Section 1: Directory tree ---
    echo "── DIRECTORY TREE ─────────────────────────────────────────────"
    echo ""

    if command -v tree &>/dev/null; then
        tree -a --noreport -I '.git|.DS_Store' "$project_dir"
    else
        find "$project_dir" \
            -not -path '*/.git/*' \
            -not -name '.git' \
            -not -name '.DS_Store' \
            | sort \
            | while read -r path; do
                depth=$(echo "$path" | sed "s|$project_dir||" | tr -cd '/' | wc -c)
                indent=$(printf '%*s' $((depth * 2)) '')
                basename "$path" | sed "s|^|$indent|"
            done
    fi

    echo ""

    # --- Section 2: Detailed file listing ---
    # Uses ls -lhA to exclude . and .. entries from output.
    echo "── FILE DETAIL (ls -lhA) ──────────────────────────────────────"
    echo ""

    find "$project_dir" \
        -type d \
        -not -path '*/.git' \
        -not -path '*/.git/*' \
        | sort \
        | while read -r dir; do
            rel="${dir#$project_dir}"
            rel="${rel:-/}"
            echo "  ${rel}/"
            ls -lhA "$dir" \
                | grep -v '^total' \
                | sed 's|^|    |'
            echo ""
        done

    # --- Section 3: MD5 checksums ---
    echo "── MD5 CHECKSUMS ──────────────────────────────────────────────"
    echo ""

    find "$project_dir" \
        -type f \
        -not -path '*/.git/*' \
        -not -name '.DS_Store' \
        | sort \
        | while read -r f; do
            rel="${f#$project_dir/}"
            if command -v md5sum &>/dev/null; then
                hash=$(md5sum "$f" | awk '{print $1}')
            else
                hash=$(md5 -q "$f")
            fi
            printf "  %-32s  %s\n" "$hash" "$rel"
        done

    echo ""
    echo "══════════════════════════════════════════════════════════════"
    echo "  End of snapshot"
    echo "══════════════════════════════════════════════════════════════"
}

# ---------------------------------------------------------------
# Main
# ---------------------------------------------------------------

# Handle no args
if [[ $# -eq 0 ]]; then
    show_usage
    exit 0
fi

# Handle list command
if [[ "$1" == "list" ]]; then
    cmd_list_profiles
    exit 0
fi

# Handle help
if [[ "$1" == "-h" || "$1" == "--help" || "$1" == "help" ]]; then
    show_usage
    exit 0
fi

# --- Determine project directory and excludes ---
PROJECT_DIR=""
EXCLUDES=""
PROFILE_NAME=""
DRY_RUN="true"

# --- Parse arguments ---
POSITIONAL=()

# Re-parse with shift to handle -d <value> pairs
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
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done

INPUT="${POSITIONAL[0]:-}"

if [[ -z "$INPUT" ]]; then
    echo "Error: No profile or path specified."
    show_usage
    exit 1
fi

# Check if arg is a websync profile
if [[ ! "$INPUT" =~ ^[./~] ]] && [[ -f "$WEBSYNC_CONFIG_DIR/${INPUT}.conf" ]]; then
    PROFILE_NAME="$INPUT"
    LOCAL_DIR=""
    REMOTE_HOST=""
    REMOTE_DIR=""

    load_websync_profile "$PROFILE_NAME"

    PROJECT_DIR="${LOCAL_DIR/#\~/$HOME}"
    PROJECT_DIR="${PROJECT_DIR%/}"

    echo "Using wd-websync profile: $PROFILE_NAME"
else
    PROJECT_DIR="${INPUT/#\~/$HOME}"
    PROJECT_DIR="${PROJECT_DIR%/}"
fi

# --- Validate project directory ---
if [[ ! -d "$PROJECT_DIR" ]]; then
    echo "ERROR: Project directory does not exist: $PROJECT_DIR"
    exit 1
fi

# --- Derive names and paths ---
PROJECT_NAME="$(basename "$PROJECT_DIR")"
PARENT_DIR="$(dirname "$PROJECT_DIR")"
TIMESTAMP="$(date '+%y%m%d_%H%M%S')"

# Outputs go into a per-project subfolder under ../snapshots/
SNAPSHOTS_DIR="$PARENT_DIR/snapshots/$PROJECT_NAME"
CLAUDE_DIR="$SNAPSHOTS_DIR/${PROJECT_NAME}-for-claude"
SNAPSHOT_ZIP="$SNAPSHOTS_DIR/${PROJECT_NAME}-snapshot-${TIMESTAMP}.zip"
SNAPSHOT_LOG="$SNAPSHOTS_DIR/${PROJECT_NAME}-snapshot-${TIMESTAMP}.log"

mkdir -p "$SNAPSHOTS_DIR"

# --- Start action log (tee everything to both console and log) ---
exec > >(tee -a "$SNAPSHOT_LOG") 2>&1

echo "══════════════════════════════════════════════════════════════"
if [[ "$DRY_RUN" == "true" ]]; then
    echo "  wd-snapshot — DRY RUN — $(date '+%Y-%m-%d %H:%M:%S')"
else
    echo "  wd-snapshot — LIVE RUN — $(date '+%Y-%m-%d %H:%M:%S')"
fi
echo "══════════════════════════════════════════════════════════════"
echo ""
echo "Project:      $PROJECT_DIR"
echo "Profile:      ${PROFILE_NAME:-(direct path)}"
echo "Snapshots:    $SNAPSHOTS_DIR"
echo "Claude dir:   $CLAUDE_DIR"
echo "Backup zip:   $SNAPSHOT_ZIP"
echo "Log:          $SNAPSHOT_LOG"
echo ""

# --- Parse deploy.conf for Claude excludes ---
DEPLOY_CONF="$PROJECT_DIR/deploy.conf"
CONF_FILES=()

if [[ -f "$DEPLOY_CONF" ]]; then
    parse_deploy_conf_files "$DEPLOY_CONF"
    echo "deploy.conf:  ${#CONF_FILES[@]} secret file(s) excluded from Claude output"
else
    echo "deploy.conf:  not found — no files will be excluded from Claude output"
fi
echo ""

# --- Build find exclude arguments ---
FIND_EXCLUDES=(-not -path '*/.git/*' -not -name '.git' -not -name '.DS_Store')

ZIP_EXCLUDES=(".git/*" ".git" ".DS_Store")

if [[ -n "$EXCLUDES" ]]; then
    echo "Excludes from profile: $EXCLUDES"
    IFS=',' read -ra EXCLUDE_ARR <<< "$EXCLUDES"
    for excl in "${EXCLUDE_ARR[@]}"; do
        excl="$(echo "$excl" | sed 's/^ *//;s/ *$//')"
        if [[ -n "$excl" ]]; then
            local_excl="${excl%/}"
            FIND_EXCLUDES+=(-not -path "*/${local_excl}/*" -not -name "$local_excl")
            ZIP_EXCLUDES+=("${local_excl}/*" "$local_excl")
        fi
    done
else
    echo "Excludes: (defaults only — .git, .DS_Store)"
fi
echo ""

# Also exclude snapshots folder and previous outputs
FIND_EXCLUDES+=(-not -path '*/snapshots/*' -not -name '*-snapshot-*.zip' -not -path '*-for-claude/*')

# ══════════════════════════════════════════════════════════════
# OUTPUT 1: Flat files for Claude
# ══════════════════════════════════════════════════════════════
echo "── Creating Claude upload files ─────────────────────────────"

# Claude-specific excludes — files declared in deploy.conf contain
# real credentials and must NOT be sent to Claude. Claude gets
# .masked and .example versions of these instead.
CLAUDE_EXCLUDES=("${FIND_EXCLUDES[@]}")
if [[ ${#CONF_FILES[@]} -gt 0 ]]; then
    for cf in "${CONF_FILES[@]}"; do
        CLAUDE_EXCLUDES+=(-not -path "$PROJECT_DIR/$cf")
    done
fi

if [[ ${#CONF_FILES[@]} -gt 0 ]]; then
    echo "  Excluding from Claude output (per deploy.conf):"
    for cf in "${CONF_FILES[@]}"; do
        echo "    - $cf"
    done
    echo ""
fi

# Clear previous for-claude dir
if [[ "$DRY_RUN" == "false" ]]; then
    if [[ -d "$CLAUDE_DIR" ]]; then
        echo "  Clearing previous for-claude directory"
        rm -rf "$CLAUDE_DIR"
    fi
    mkdir -p "$CLAUDE_DIR"
else
    if [[ -d "$CLAUDE_DIR" ]]; then
        echo "  DRY RUN: Would clear previous for-claude directory"
    fi
fi

# Find all files, flatten paths with __ delimiters.
# Root-level files keep their bare name (no __ prefix).
claude_count=0
find "$PROJECT_DIR" -type f "${CLAUDE_EXCLUDES[@]}" | sort | while IFS= read -r filepath; do
    rel="${filepath#$PROJECT_DIR/}"

    # Replace / with __ to flatten. Root-level files (no /) stay as-is.
    flat_name="${rel//\//__}"

    if [[ "$DRY_RUN" == "false" ]]; then
        cp -p "$filepath" "$CLAUDE_DIR/$flat_name"
        echo "  FLATTEN: $rel -> $flat_name"
    else
        echo "  DRY RUN FLATTEN: $rel -> $flat_name"
    fi
done

# Count results (done separately — the while loop runs in a pipe subshell)
if [[ "$DRY_RUN" == "false" ]]; then
    claude_count=$(find "$CLAUDE_DIR" -type f | wc -l | tr -d ' ')
else
    claude_count=$(find "$PROJECT_DIR" -type f "${CLAUDE_EXCLUDES[@]}" | wc -l | tr -d ' ')
fi
echo ""
if [[ "$DRY_RUN" == "false" ]]; then
    echo "  $claude_count files flattened into $CLAUDE_DIR"
else
    echo "  $claude_count files would be flattened into $CLAUDE_DIR"
fi
echo ""

# ══════════════════════════════════════════════════════════════
# OUTPUT 2: Backup zip with snapshot log
# ══════════════════════════════════════════════════════════════
echo "── Creating backup snapshot ─────────────────────────────────"

if [[ "$DRY_RUN" == "false" ]]; then
    LOG_TEMP="/tmp/snapshot-log-${TIMESTAMP}.txt"
    echo "  Generating snapshot log..."
    generate_log "$PROJECT_DIR" "$PROJECT_NAME" > "$LOG_TEMP"
    echo "  Snapshot log written to temp: $LOG_TEMP"

    ZIP_EXCLUDE_FLAGS=()
    for excl in "${ZIP_EXCLUDES[@]}"; do
        ZIP_EXCLUDE_FLAGS+=(-x "$excl")
    done

    ZIP_EXCLUDE_FLAGS+=(-x "*/snapshots/*" -x "*-snapshot-*.zip" -x "*-for-claude/*")

    echo "  Zipping project tree..."
    (
        cd "$PARENT_DIR"
        zip -r -q "$SNAPSHOT_ZIP" "$PROJECT_NAME" "${ZIP_EXCLUDE_FLAGS[@]}"
    )

    echo "  Adding snapshot log to zip..."
    zip -j -q "$SNAPSHOT_ZIP" "$LOG_TEMP"
    rm -f "$LOG_TEMP"

    zip_size=$(ls -lh "$SNAPSHOT_ZIP" | awk '{print $5}')
    zip_count=$(unzip -l "$SNAPSHOT_ZIP" | tail -1 | awk '{print $2}')
    echo "  $zip_count files archived ($zip_size)"
    echo "  $SNAPSHOT_ZIP"
else
    echo "  DRY RUN: Would generate snapshot log"
    echo "  DRY RUN: Would create $SNAPSHOT_ZIP"

    zip_count=$(find "$PROJECT_DIR" -type f "${FIND_EXCLUDES[@]}" | wc -l | tr -d ' ')
    echo "  $zip_count files would be archived"
fi
echo ""

# ══════════════════════════════════════════════════════════════
# Done
# ══════════════════════════════════════════════════════════════
echo "══════════════════════════════════════════════════════════════"
if [[ "$DRY_RUN" == "true" ]]; then
    echo "  DRY RUN complete — $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  Pass -d FALSE to execute."
else
    echo "  Snapshot complete — $(date '+%Y-%m-%d %H:%M:%S')"
fi
echo "══════════════════════════════════════════════════════════════"
if [[ "$DRY_RUN" == "false" ]]; then
    echo "  Claude upload:  $CLAUDE_DIR  ($claude_count flat files)"
    echo "  Backup zip:     $(basename "$SNAPSHOT_ZIP")  ($zip_size)"
else
    echo "  Claude upload:  $claude_count files would be flattened"
    echo "  Backup zip:     $zip_count files would be archived"
fi
echo "  Log:            $(basename "$SNAPSHOT_LOG")"
echo ""
