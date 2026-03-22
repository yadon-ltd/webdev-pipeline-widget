#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
# wd-gitsync — git commit and push with credential safety gate
# ══════════════════════════════════════════════════════════════
# Stages, commits, and pushes the local project to its git remote.
# Before any push, verifies that every secret-bearing file declared
# in deploy.conf is listed in .gitignore. Blocks on mismatch.
#
# USAGE
#   wd-gitsync <profile>                 Dry-run (show what would happen)
#   wd-gitsync <profile> -d FALSE        Execute commit and push
#   wd-gitsync <profile> -m "message"    Commit with message (still dry-run)
#   wd-gitsync <profile> -d FALSE -m "message"   Commit and push for real
#   wd-gitsync /path/to/project          Use a direct path
#   wd-gitsync list                      List available websync profiles
#
# Reads deploy.conf from the project root to verify .gitignore
# alignment with secret-bearing file declarations.
#
# Dry-run by default — shows status, staged changes, and what
# would be committed and pushed. Pass -d FALSE to execute.
#
# Can be run standalone or called from wd-deploy as a pipeline stage.
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
    echo "  wd-gitsync <profile>                  Dry-run git sync"
    echo "  wd-gitsync <profile> -d FALSE          Commit and push"
    echo "  wd-gitsync <profile> -m \"message\"      Set commit message"
    echo "  wd-gitsync /path/to/project            Use direct path"
    echo "  wd-gitsync list                        List websync profiles"
    echo ""
    echo "Options:"
    echo "  -d FALSE         Disable dry run (execute for real)"
    echo "  -m \"message\"     Commit message (prompted if omitted)"
    echo "  --no-verify      Skip deploy.conf safety gate"
    echo ""
    echo "Safety:"
    echo "  Before pushing, verifies every file declared in deploy.conf"
    echo "  is present in .gitignore. Blocks on mismatch to prevent"
    echo "  accidental credential exposure."
}

# ---------------------------------------------------------------
# verify_gitignore — cross-check deploy.conf against .gitignore
# ---------------------------------------------------------------
# Checks two things for each file entry in deploy.conf:
#   1. The real file (config.php) must be in .gitignore
#   2. Its .masked counterpart (config.masked.php) must also be in .gitignore
#
# .example files are NOT checked — they are developer-maintained
# onboarding templates that belong in version control.
#
# Returns 0 if all files are covered. Returns 1 and prints
# the missing entries if any are unprotected.
# ---------------------------------------------------------------
verify_gitignore() {
    local project_dir="$1"
    local gitignore="$project_dir/.gitignore"
    local missing=0

    # If no .gitignore exists at all, every secret file is exposed
    if [[ ! -f "$gitignore" ]]; then
        echo "  ERROR: No .gitignore found in $project_dir"
        echo ""
        echo "  Every file declared in deploy.conf (and its .masked"
        echo "  counterpart) must be in .gitignore. Create .gitignore with:"
        echo ""
        for cf in "${CONF_FILES[@]}"; do
            echo "    $cf"
            derive_masked_name "$cf" | sed 's/^/    /'
        done
        echo ""
        return 1
    fi

    echo "  Checking deploy.conf files against .gitignore..."

    # Build a list of all files to check: real files + masked counterparts
    local files_to_check=()
    for cf in "${CONF_FILES[@]}"; do
        files_to_check+=("$cf")
        files_to_check+=("$(derive_masked_name "$cf")")
    done

    for check_file in "${files_to_check[@]}"; do
        local found=0

        # Strip leading ./ if present for consistent matching
        local clean="${check_file#./}"

        # Check exact match (with or without leading /)
        if grep -qxF "$clean" "$gitignore" 2>/dev/null; then
            found=1
        elif grep -qxF "/$clean" "$gitignore" 2>/dev/null; then
            found=1
        fi

        # Also check if git would actually track this file
        # (a broader .gitignore pattern might cover it)
        if [[ $found -eq 0 ]]; then
            if git -C "$project_dir" check-ignore -q "$clean" 2>/dev/null; then
                found=1
            fi
        fi

        if [[ $found -eq 1 ]]; then
            echo "    ✓ $check_file"
        else
            echo "    ✗ $check_file — NOT in .gitignore"
            ((missing++))
        fi
    done

    echo ""

    if [[ $missing -gt 0 ]]; then
        echo "  BLOCKED: $missing file(s) not covered by .gitignore."
        echo "  Add them to .gitignore before pushing to prevent credential exposure."
        echo ""
        echo "  Append to $gitignore:"
        for check_file in "${files_to_check[@]}"; do
            local clean="${check_file#./}"
            if ! git -C "$project_dir" check-ignore -q "$clean" 2>/dev/null; then
                if ! grep -qxF "$clean" "$gitignore" 2>/dev/null && \
                   ! grep -qxF "/$clean" "$gitignore" 2>/dev/null; then
                    echo "    $clean"
                fi
            fi
        done
        echo ""
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------
# verify_masked_files — warn if .masked files are missing
# ---------------------------------------------------------------
# Non-blocking — just a heads-up that Claude won't have the
# masked config structure. Run wd-deploy to auto-generate them.
# ---------------------------------------------------------------
verify_masked_files() {
    local project_dir="$1"
    local missing=0

    echo "  Checking .masked files..."

    for cf in "${CONF_FILES[@]}"; do
        local masked_name
        masked_name="$(derive_masked_name "$cf")"
        local masked_path="$project_dir/$masked_name"

        if [[ -f "$masked_path" ]]; then
            echo "    ✓ $masked_name"
        else
            echo "    ⚠ $masked_name — missing (run wd-deploy to generate)"
            ((missing++))
        fi
    done

    echo ""

    if [[ $missing -gt 0 ]]; then
        echo "  NOTE: $missing .masked file(s) missing. Claude won't have"
        echo "  the config structure until wd-deploy generates them."
        echo ""
    fi
}

# ---------------------------------------------------------------
# generate_commit_message — auto-generate from staged changes
# ---------------------------------------------------------------
# Produces a summary like:
#   Deploy: 3 modified, 1 added, 1 deleted
#
#   Modified:
#     core/header.php
#     core/footer.php
#     public/style.css
#   Added:
#     public/pages/contact.php
#   Deleted:
#     public/pages/old.php
# ---------------------------------------------------------------
generate_commit_message() {
    local project_dir="$1"
    local modified added deleted renamed
    local mod_count=0 add_count=0 del_count=0 ren_count=0

    modified=$(git -C "$project_dir" diff --cached --name-only --diff-filter=M 2>/dev/null)
    added=$(git -C "$project_dir" diff --cached --name-only --diff-filter=A 2>/dev/null)
    deleted=$(git -C "$project_dir" diff --cached --name-only --diff-filter=D 2>/dev/null)
    renamed=$(git -C "$project_dir" diff --cached --name-only --diff-filter=R 2>/dev/null)

    [[ -n "$modified" ]] && mod_count=$(echo "$modified" | wc -l | tr -d ' ')
    [[ -n "$added" ]] && add_count=$(echo "$added" | wc -l | tr -d ' ')
    [[ -n "$deleted" ]] && del_count=$(echo "$deleted" | wc -l | tr -d ' ')
    [[ -n "$renamed" ]] && ren_count=$(echo "$renamed" | wc -l | tr -d ' ')

    local parts=()
    [[ $mod_count -gt 0 ]] && parts+=("$mod_count modified")
    [[ $add_count -gt 0 ]] && parts+=("$add_count added")
    [[ $del_count -gt 0 ]] && parts+=("$del_count deleted")
    [[ $ren_count -gt 0 ]] && parts+=("$ren_count renamed")

    local summary
    summary=$(IFS=', '; echo "${parts[*]}")

    echo "Deploy: $summary"
    echo ""

    if [[ -n "$modified" ]]; then
        echo "Modified:"
        echo "$modified" | while IFS= read -r f; do echo "  $f"; done
    fi
    if [[ -n "$added" ]]; then
        echo "Added:"
        echo "$added" | while IFS= read -r f; do echo "  $f"; done
    fi
    if [[ -n "$deleted" ]]; then
        echo "Deleted:"
        echo "$deleted" | while IFS= read -r f; do echo "  $f"; done
    fi
    if [[ -n "$renamed" ]]; then
        echo "Renamed:"
        echo "$renamed" | while IFS= read -r f; do echo "  $f"; done
    fi
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

# --- Parse arguments ---
DRY_RUN="true"
COMMIT_MSG=""
SKIP_VERIFY="false"
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
        -m)
            if [[ $# -lt 2 ]]; then
                echo "Error: -m requires a message"
                exit 1
            fi
            COMMIT_MSG="$2"
            shift 2
            ;;
        --no-verify)
            SKIP_VERIFY="true"
            shift
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

# --- Determine project directory ---
PROJECT_DIR=""
PROFILE_NAME=""

if [[ ! "$INPUT" =~ ^[./~] ]] && [[ -f "$WEBSYNC_CONFIG_DIR/${INPUT}.conf" ]]; then
    PROFILE_NAME="$INPUT"
    LOCAL_DIR=""
    REMOTE_HOST=""
    REMOTE_DIR=""
    EXCLUDES=""

    load_websync_profile "$PROFILE_NAME"

    PROJECT_DIR="${LOCAL_DIR/#\~/$HOME}"
    PROJECT_DIR="${PROJECT_DIR%/}"
else
    PROJECT_DIR="${INPUT/#\~/$HOME}"
    PROJECT_DIR="${PROJECT_DIR%/}"
fi

# --- Validate project directory ---
if [[ ! -d "$PROJECT_DIR" ]]; then
    echo "Error: Project directory does not exist: $PROJECT_DIR"
    exit 1
fi

PROJECT_NAME="$(basename "$PROJECT_DIR")"

# --- Verify this is a git repository ---
if [[ ! -d "$PROJECT_DIR/.git" ]]; then
    echo "Error: $PROJECT_DIR is not a git repository."
    echo "  Initialize with: cd $PROJECT_DIR && git init"
    exit 1
fi

# --- Get current branch ---
CURRENT_BRANCH=$(git -C "$PROJECT_DIR" branch --show-current 2>/dev/null)
if [[ -z "$CURRENT_BRANCH" ]]; then
    echo "Error: Could not determine current branch."
    echo "  You may be in a detached HEAD state."
    exit 1
fi

# --- Check for a configured remote ---
REMOTE_NAME=$(git -C "$PROJECT_DIR" remote 2>/dev/null | head -1)
if [[ -z "$REMOTE_NAME" ]]; then
    echo "Error: No git remote configured."
    echo "  Add one with: cd $PROJECT_DIR && git remote add origin <url>"
    exit 1
fi

REMOTE_URL=$(git -C "$PROJECT_DIR" remote get-url "$REMOTE_NAME" 2>/dev/null)

# --- Set up action log ---
PARENT_DIR="$(dirname "$PROJECT_DIR")"
TIMESTAMP="$(date '+%y%m%d_%H%M%S')"
SNAPSHOTS_DIR="$PARENT_DIR/snapshots/$PROJECT_NAME"
GITSYNC_LOG="$SNAPSHOTS_DIR/${PROJECT_NAME}-gitsync-${TIMESTAMP}.log"
mkdir -p "$SNAPSHOTS_DIR"
exec > >(tee -a "$GITSYNC_LOG") 2>&1

# ══════════════════════════════════════════════════════════════
# Header
# ══════════════════════════════════════════════════════════════
echo "══════════════════════════════════════════════════════════════"
if [[ "$DRY_RUN" == "true" ]]; then
    echo "  wd-gitsync — DRY RUN — $(date '+%Y-%m-%d %H:%M:%S')"
else
    echo "  wd-gitsync — LIVE RUN — $(date '+%Y-%m-%d %H:%M:%S')"
fi
echo "══════════════════════════════════════════════════════════════"
echo ""
echo "  Profile:  ${PROFILE_NAME:-(direct path)}"
echo "  Project:  $PROJECT_DIR"
echo "  Branch:   $CURRENT_BRANCH"
echo "  Remote:   $REMOTE_NAME → $REMOTE_URL"
echo "  Log:      $GITSYNC_LOG"
echo ""

# ══════════════════════════════════════════════════════════════
# GATE 1: Credential safety verification
# ══════════════════════════════════════════════════════════════
echo "── Gate: Credential safety check ──────────────────────────────"

DEPLOY_CONF="$PROJECT_DIR/deploy.conf"
CONF_FILES=()

if [[ -f "$DEPLOY_CONF" ]]; then
    parse_deploy_conf_files "$DEPLOY_CONF"

    if [[ ${#CONF_FILES[@]} -gt 0 ]]; then
        if [[ "$SKIP_VERIFY" == "true" ]]; then
            echo "  Safety gate bypassed (--no-verify)"
            echo "  ⚠  You are responsible for verifying .gitignore manually."
            echo ""
        else
            if ! verify_gitignore "$PROJECT_DIR"; then
                echo "  Use --no-verify to bypass this check (not recommended)."
                exit 1
            fi

            echo "  All ${#CONF_FILES[@]} secret file(s) confirmed in .gitignore."
            echo ""

            verify_masked_files "$PROJECT_DIR"
        fi
    else
        echo "  deploy.conf found but declares no files — nothing to verify."
        echo ""
    fi
else
    echo "  No deploy.conf found — safety check skipped."
    echo "  If this project has secret-bearing files, create deploy.conf"
    echo "  to enable the credential safety gate."
    echo ""
fi

# ══════════════════════════════════════════════════════════════
# GATE 2: Check for changes
# ══════════════════════════════════════════════════════════════
echo "── Gate: Working tree status ──────────────────────────────────"

status_output=$(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null)

if [[ -z "$status_output" ]]; then
    echo "  Working tree is clean — nothing to commit."
    echo ""

    unpushed=$(git -C "$PROJECT_DIR" log "$REMOTE_NAME/$CURRENT_BRANCH".."$CURRENT_BRANCH" --oneline 2>/dev/null)
    if [[ -n "$unpushed" ]]; then
        unpushed_count=$(echo "$unpushed" | wc -l | tr -d ' ')
        echo "  Found $unpushed_count unpushed commit(s):"
        echo "$unpushed" | while IFS= read -r line; do echo "    $line"; done
        echo ""

        if [[ "$DRY_RUN" == "false" ]]; then
            echo "  Pushing unpushed commits..."
            git -C "$PROJECT_DIR" push "$REMOTE_NAME" "$CURRENT_BRANCH"
            push_exit=$?
            if [[ $push_exit -ne 0 ]]; then
                echo "  ERROR: git push failed (exit code $push_exit)."
                exit $push_exit
            fi
            echo ""
            echo "  Pushed $unpushed_count commit(s) to $REMOTE_NAME/$CURRENT_BRANCH."
        else
            echo "  DRY RUN: Would push $unpushed_count commit(s) to $REMOTE_NAME/$CURRENT_BRANCH."
        fi
    else
        echo "  No unpushed commits either. Everything is up to date."
    fi

    echo ""
    echo "══════════════════════════════════════════════════════════════"
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  DRY RUN complete — $(date '+%Y-%m-%d %H:%M:%S')"
    else
        echo "  Git sync complete — $(date '+%Y-%m-%d %H:%M:%S')"
    fi
    echo "  Log: $GITSYNC_LOG"
    echo "══════════════════════════════════════════════════════════════"
    echo ""
    exit 0
fi

echo ""
echo "  Changes detected:"
echo "$status_output" | while IFS= read -r line; do echo "    $line"; done
echo ""

staged_count=$(echo "$status_output" | grep -c '^[MADRC]' || true)
unstaged_count=$(echo "$status_output" | grep -c '^.[MDRC]' || true)
untracked_count=$(echo "$status_output" | grep -c '^??' || true)

echo "  Staged: $staged_count  |  Unstaged: $unstaged_count  |  Untracked: $untracked_count"
echo ""

# ══════════════════════════════════════════════════════════════
# Stage 1: Stage all changes
# ══════════════════════════════════════════════════════════════
echo "── Stage 1: Stage changes ─────────────────────────────────────"

if [[ "$DRY_RUN" == "false" ]]; then
    git -C "$PROJECT_DIR" add -A
    add_exit=$?
    if [[ $add_exit -ne 0 ]]; then
        echo "  ERROR: git add failed (exit code $add_exit)."
        exit $add_exit
    fi

    staged_summary=$(git -C "$PROJECT_DIR" diff --cached --stat 2>/dev/null)
    if [[ -n "$staged_summary" ]]; then
        echo "$staged_summary" | while IFS= read -r line; do echo "  $line"; done
    fi
else
    echo "  DRY RUN: Would stage all changes (git add -A)"
    echo ""
    echo "  Would stage:"
    echo "$status_output" | while IFS= read -r line; do echo "    $line"; done
fi

echo ""

# ══════════════════════════════════════════════════════════════
# Stage 2: Commit
# ══════════════════════════════════════════════════════════════
echo "── Stage 2: Commit ────────────────────────────────────────────"

if [[ "$DRY_RUN" == "false" ]]; then
    if [[ -z "$COMMIT_MSG" ]]; then
        auto_msg=$(generate_commit_message "$PROJECT_DIR")
        echo ""
        echo "  Auto-generated commit message:"
        echo "  ────────────────────────────────"
        echo "$auto_msg" | while IFS= read -r line; do echo "  $line"; done
        echo "  ────────────────────────────────"
        echo ""
        echo -n "  Use this message? (y/Enter = yes, n = write your own): "
        read -r msg_confirm
        msg_confirm_lower="$(echo "$msg_confirm" | tr '[:upper:]' '[:lower:]')"

        if [[ "$msg_confirm_lower" == "n" || "$msg_confirm_lower" == "no" ]]; then
            echo -n "  Commit message: "
            read -r COMMIT_MSG
            if [[ -z "$COMMIT_MSG" ]]; then
                echo "  ERROR: Empty commit message. Aborting."
                git -C "$PROJECT_DIR" reset HEAD --quiet
                exit 1
            fi
        else
            COMMIT_MSG="$auto_msg"
        fi
    fi

    git -C "$PROJECT_DIR" commit -m "$COMMIT_MSG"
    commit_exit=$?
    if [[ $commit_exit -ne 0 ]]; then
        echo "  ERROR: git commit failed (exit code $commit_exit)."
        exit $commit_exit
    fi

    commit_hash=$(git -C "$PROJECT_DIR" rev-parse --short HEAD 2>/dev/null)
    echo ""
    echo "  Committed: $commit_hash"
else
    if [[ -n "$COMMIT_MSG" ]]; then
        echo "  DRY RUN: Would commit with message: $COMMIT_MSG"
    else
        echo "  DRY RUN: Would commit with auto-generated message"
    fi
fi

echo ""

# ══════════════════════════════════════════════════════════════
# Stage 3: Push to remote
# ══════════════════════════════════════════════════════════════
echo "── Stage 3: Push to remote ────────────────────────────────────"

if [[ "$DRY_RUN" == "false" ]]; then
    upstream=$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref "$CURRENT_BRANCH@{upstream}" 2>/dev/null)

    if [[ -z "$upstream" ]]; then
        echo "  No upstream set for $CURRENT_BRANCH."
        echo "  Setting upstream and pushing..."
        git -C "$PROJECT_DIR" push -u "$REMOTE_NAME" "$CURRENT_BRANCH"
    else
        git -C "$PROJECT_DIR" push "$REMOTE_NAME" "$CURRENT_BRANCH"
    fi

    push_exit=$?
    if [[ $push_exit -ne 0 ]]; then
        echo ""
        echo "  ERROR: git push failed (exit code $push_exit)."
        echo ""
        echo "  The commit was created locally ($commit_hash) but not pushed."
        echo "  Push manually when ready: cd $PROJECT_DIR && git push"
        exit $push_exit
    fi

    echo ""
    echo "  Pushed to $REMOTE_NAME/$CURRENT_BRANCH"
else
    echo "  DRY RUN: Would push $CURRENT_BRANCH to $REMOTE_NAME"
fi

echo ""

# ══════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════
echo "══════════════════════════════════════════════════════════════"
if [[ "$DRY_RUN" == "true" ]]; then
    echo "  DRY RUN complete — $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  Pass -d FALSE to execute."
else
    echo "  Git sync complete — $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  $commit_hash pushed to $REMOTE_NAME/$CURRENT_BRANCH"
fi
echo "  Log: $GITSYNC_LOG"
echo "══════════════════════════════════════════════════════════════"
echo ""
