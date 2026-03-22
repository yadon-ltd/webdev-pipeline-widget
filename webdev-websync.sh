#!/usr/bin/env bash
# wd-websync — reusable rsync wrapper with named profiles
#
# Usage:
#   wd-websync pull <profile>                          # dry-run pull from server
#   wd-websync pull <profile> -d FALSE                 # real pull
#   wd-websync push <profile>                          # dry-run push to server
#   wd-websync push <profile> -d FALSE                 # real push
#   wd-websync pull <local> <remote>                   # one-off pull, no profile
#   wd-websync push <local> <remote> -d FALSE          # one-off push
#   wd-websync push <local> <remote> --exclude uploads/ # one-off with excludes
#   wd-websync config <profile>                        # create/edit a profile
#   wd-websync list                                    # list saved profiles
#
# Profiles are stored in ~/.websync/<name>.conf
# Dry-run is always the default.
# .DS_Store is always excluded.
# --delete is off by default on push. Pass --delete to enable.
# First real push to a profile requires confirmation.

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
    echo "  wd-websync pull <profile>                   Dry-run pull from server"
    echo "  wd-websync pull <profile> -d FALSE           Pull from server"
    echo "  wd-websync push <profile>                   Dry-run push to server"
    echo "  wd-websync push <profile> -d FALSE           Push to server"
    echo "  wd-websync pull <local> <host:remote>        One-off pull"
    echo "  wd-websync push <local> <host:remote>        One-off push"
    echo "  wd-websync config <profile>                 Create or edit a profile"
    echo "  wd-websync show <profile>                   View a profile without editing"
    echo "  wd-websync delete <profile>                 Delete a profile"
    echo "  wd-websync list                             List saved profiles"
    echo ""
    echo "Options:"
    echo "  -d FALSE         Disable dry run (execute for real)"
    echo "  --delete         Remove remote files not present locally (push only)"
    echo "  --exclude <dir>  Additional exclude (repeatable, one-off mode)"
}

# ---------------------------------------------------------------
# cmd_config — create or edit a profile interactively
# ---------------------------------------------------------------
cmd_config() {
    local profile_name="$1"

    if [[ -z "$profile_name" ]]; then
        echo "Usage: wd-websync config <profile_name>"
        exit 1
    fi

    mkdir -p "$WEBSYNC_CONFIG_DIR"

    local conf_file="$WEBSYNC_CONFIG_DIR/${profile_name}.conf"

    if [[ -f "$conf_file" ]]; then
        echo "Editing existing profile: $profile_name"
        echo "Current contents:"
        echo "---"
        cat "$conf_file"
        echo "---"
        echo ""

        local editor="${EDITOR:-$(command -v nano || command -v vi)}"
        "$editor" "$conf_file"
        echo "Profile updated: $conf_file"
        return
    fi

    echo -n "Profile '$profile_name' not found. Create it? (y/n): "
    read -r yn
    if [[ "$(echo "$yn" | tr '[:upper:]' '[:lower:]')" != "y" ]]; then
        echo "Aborted."
        exit 0
    fi

    echo -n "LOCAL_DIR: "
    read -r local_dir
    echo -n "REMOTE_HOST: "
    read -r remote_host
    echo -n "REMOTE_DIR: "
    read -r remote_dir
    echo -n "EXCLUDES (comma-separated, .DS_Store always included): "
    read -r excludes

    cat > "$conf_file" << CONF
# websync profile: $profile_name
LOCAL_DIR="$local_dir"
REMOTE_HOST="$remote_host"
REMOTE_DIR="$remote_dir"
EXCLUDES="$excludes"
CONF

    echo "Profile saved: $conf_file"
}

# ---------------------------------------------------------------
# cmd_list — list all saved profiles with full connection details
# ---------------------------------------------------------------
# Websync's list is richer than cmd_list_profiles (shows remote
# host and path), so it uses its own version.
# ---------------------------------------------------------------
cmd_list() {
    mkdir -p "$WEBSYNC_CONFIG_DIR"

    local found=0
    echo "Saved profiles (~/.websync/):"

    for conf_file in "$WEBSYNC_CONFIG_DIR"/*.conf; do
        [[ -f "$conf_file" ]] || continue
        found=1

        local LOCAL_DIR="" REMOTE_HOST="" REMOTE_DIR="" EXCLUDES=""
        source "$conf_file"

        local name
        name="$(basename "$conf_file" .conf)"

        printf "  %-14s %s  <->  %s:%s\n" "$name" "$LOCAL_DIR" "$REMOTE_HOST" "$REMOTE_DIR"
    done

    if [[ $found -eq 0 ]]; then
        echo "  (none)"
    fi
}

# ---------------------------------------------------------------
# cmd_show — display a profile's settings without opening an editor
# ---------------------------------------------------------------
cmd_show() {
    local profile_name="$1"

    if [[ -z "$profile_name" ]]; then
        echo "Usage: wd-websync show <profile_name>"
        exit 1
    fi

    local conf_file="$WEBSYNC_CONFIG_DIR/${profile_name}.conf"

    if [[ ! -f "$conf_file" ]]; then
        echo "Error: Profile '$profile_name' not found."
        echo "Run 'wd-websync list' to see available profiles."
        exit 1
    fi

    local LOCAL_DIR="" REMOTE_HOST="" REMOTE_DIR="" EXCLUDES=""
    source "$conf_file"

    echo "Profile: $profile_name"
    echo "  Local dir:   $LOCAL_DIR"
    echo "  Remote host: $REMOTE_HOST"
    echo "  Remote dir:  $REMOTE_DIR"
    echo "  Excludes:    ${EXCLUDES:-(none)}"

    if [[ -f "$WEBSYNC_CONFIG_DIR/.${profile_name}.pushed" ]]; then
        echo "  Status:      has been pushed"
    else
        echo "  Status:      never pushed (first push will require confirmation)"
    fi
}

# ---------------------------------------------------------------
# cmd_delete — remove a profile and its push marker
# ---------------------------------------------------------------
cmd_delete() {
    local profile_name="$1"

    if [[ -z "$profile_name" ]]; then
        echo "Usage: wd-websync delete <profile_name>"
        exit 1
    fi

    local conf_file="$WEBSYNC_CONFIG_DIR/${profile_name}.conf"

    if [[ ! -f "$conf_file" ]]; then
        echo "Error: Profile '$profile_name' not found."
        echo "Run 'wd-websync list' to see available profiles."
        exit 1
    fi

    echo "About to delete profile '$profile_name':"
    local LOCAL_DIR="" REMOTE_HOST="" REMOTE_DIR="" EXCLUDES=""
    source "$conf_file"
    echo "  $LOCAL_DIR  <->  $REMOTE_HOST:$REMOTE_DIR"
    echo ""
    echo -n "Type 'yes' to confirm: "
    read -r confirm

    if [[ "$confirm" != "yes" ]]; then
        echo "Aborted."
        exit 0
    fi

    rm -f "$conf_file"
    rm -f "$WEBSYNC_CONFIG_DIR/.${profile_name}.pushed"
    echo "Profile '$profile_name' deleted."
}

# ---------------------------------------------------------------
# mark_first_push_done — records that a real push has happened
# ---------------------------------------------------------------
mark_first_push_done() {
    local profile_name="$1"
    touch "$WEBSYNC_CONFIG_DIR/.${profile_name}.pushed"
}

# ---------------------------------------------------------------
# is_first_push — checks if this profile has ever been pushed
# ---------------------------------------------------------------
is_first_push() {
    local profile_name="$1"
    [[ ! -f "$WEBSYNC_CONFIG_DIR/.${profile_name}.pushed" ]]
}

# ---------------------------------------------------------------
# cmd_sync — the main pull/push logic
# ---------------------------------------------------------------
cmd_sync() {
    local direction="$1"
    shift

    local DRY_RUN="true"
    local USE_DELETE="false"
    local EXTRA_EXCLUDES=()
    local POSITIONAL=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d)
                local flag_val
                flag_val="$(echo "$2" | tr '[:upper:]' '[:lower:]')"
                if [[ "$flag_val" == "false" ]]; then
                    DRY_RUN="false"
                fi
                shift 2
                ;;
            --delete)
                USE_DELETE="true"
                shift
                ;;
            --exclude)
                EXTRA_EXCLUDES+=("$2")
                shift 2
                ;;
            *)
                POSITIONAL+=("$1")
                shift
                ;;
        esac
    done

    local PROFILE_NAME=""
    local LOCAL_DIR=""
    local REMOTE_HOST=""
    local REMOTE_DIR=""
    local EXCLUDES=""

    if [[ ${#POSITIONAL[@]} -eq 1 ]]; then
        PROFILE_NAME="${POSITIONAL[0]}"

        if ! load_websync_profile "$PROFILE_NAME"; then
            echo "Error: Profile '$PROFILE_NAME' not found."
            echo "Run 'wd-websync config $PROFILE_NAME' to create it."
            exit 1
        fi

    elif [[ ${#POSITIONAL[@]} -eq 2 ]]; then
        LOCAL_DIR="${POSITIONAL[0]}"

        if [[ "${POSITIONAL[1]}" == *:* ]]; then
            REMOTE_HOST="${POSITIONAL[1]%%:*}"
            REMOTE_DIR="${POSITIONAL[1]#*:}"
        else
            echo "Error: Remote must be in host:path format (e.g. yadon:~/abide)"
            exit 1
        fi
    else
        echo "Error: Expected a profile name or <local_dir> <host:remote_dir>"
        show_usage
        exit 1
    fi

    # --- Expand tilde in LOCAL_DIR ---
    LOCAL_DIR="${LOCAL_DIR/#\~/$HOME}"

    # --- Set up action log ---
    local PROJECT_DIR_CLEAN="${LOCAL_DIR%/}"
    local PROJECT_NAME_LOG="$(basename "$PROJECT_DIR_CLEAN")"
    local PARENT_DIR_LOG="$(dirname "$PROJECT_DIR_CLEAN")"
    local SNAPSHOTS_DIR_LOG="$PARENT_DIR_LOG/snapshots/$PROJECT_NAME_LOG"
    local TIMESTAMP_LOG="$(date '+%y%m%d_%H%M%S')"
    local WEBSYNC_LOG="$SNAPSHOTS_DIR_LOG/${PROJECT_NAME_LOG}-websync-${direction}-${TIMESTAMP_LOG}.log"
    mkdir -p "$SNAPSHOTS_DIR_LOG"
    exec > >(tee -a "$WEBSYNC_LOG") 2>&1

    # --- Ensure local dir has trailing slash for rsync ---
    LOCAL_DIR="${LOCAL_DIR%/}/"

    # --- Ensure remote dir has trailing slash ---
    REMOTE_DIR="${REMOTE_DIR%/}/"

    # --- Build the rsync command ---
    local rsync_args=("-avz")

    if [[ "$DRY_RUN" == "true" ]]; then
        rsync_args+=("-n")
    fi

    # --delete only when explicitly requested on push
    if [[ "$direction" == "push" && "$USE_DELETE" == "true" ]]; then
        rsync_args+=("--delete")
    fi

    # Always exclude .DS_Store
    rsync_args+=("--exclude" ".DS_Store")

    # Profile excludes (comma-separated)
    if [[ -n "$EXCLUDES" ]]; then
        IFS=',' read -ra EXCLUDE_ARR <<< "$EXCLUDES"
        for excl in "${EXCLUDE_ARR[@]}"; do
            excl="$(echo "$excl" | sed 's/^ *//;s/ *$//')"
            if [[ -n "$excl" ]]; then
                rsync_args+=("--exclude" "$excl")
            fi
        done
    fi

    # Command-line --exclude additions
    if [[ ${#EXTRA_EXCLUDES[@]} -gt 0 ]]; then
        for excl in "${EXTRA_EXCLUDES[@]}"; do
            rsync_args+=("--exclude" "$excl")
        done
    fi

    # --- Set source and destination based on direction ---
    local source=""
    local destination=""
    local remote_full="${REMOTE_HOST}:${REMOTE_DIR}"

    if [[ "$direction" == "pull" ]]; then
        source="$remote_full"
        destination="$LOCAL_DIR"
    elif [[ "$direction" == "push" ]]; then
        source="$LOCAL_DIR"
        destination="$remote_full"
    else
        echo "Error: Direction must be 'pull' or 'push'."
        exit 1
    fi

    # --- First-push safety check (profile mode only) ---
    if [[ "$direction" == "push" && "$DRY_RUN" == "false" && -n "$PROFILE_NAME" ]]; then
        if is_first_push "$PROFILE_NAME"; then
            if [[ "$USE_DELETE" == "true" ]]; then
                echo "⚠️  First push to '$PROFILE_NAME' with --delete — remote files not present locally WILL be removed."
            else
                echo "⚠️  First push to '$PROFILE_NAME' — local files will overwrite matching remote files."
            fi
            echo -n "Type 'yes' to confirm: "
            read -r confirm
            if [[ "$confirm" != "yes" ]]; then
                echo "Aborted."
                exit 0
            fi
        fi
    fi

    # --- Print header ---
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "DRY RUN — no files will be transferred."
    fi

    if [[ -n "$PROFILE_NAME" ]]; then
        echo "Profile: $PROFILE_NAME"
    else
        echo "Profile: (none — using command line args)"
    fi

    if [[ "$direction" == "pull" ]]; then
        echo "Direction: PULL (server -> local)"
    else
        echo "Direction: PUSH (local -> server)"
    fi

    echo "Source: $source"
    echo "Destination: $destination"

    local all_excludes=()
    if [[ -n "$EXCLUDES" ]]; then
        IFS=',' read -ra EXCLUDE_ARR <<< "$EXCLUDES"
        for excl in "${EXCLUDE_ARR[@]}"; do
            excl="$(echo "$excl" | sed 's/^ *//;s/ *$//')"
            [[ -n "$excl" ]] && all_excludes+=("$excl")
        done
    fi
    if [[ ${#EXTRA_EXCLUDES[@]} -gt 0 ]]; then
        for excl in "${EXTRA_EXCLUDES[@]}"; do
            all_excludes+=("$excl")
        done
    fi
    all_excludes+=(".DS_Store")

    echo "Excludes: $(IFS=', '; echo "${all_excludes[*]}")"

    if [[ "$direction" == "push" && "$USE_DELETE" == "true" ]]; then
        echo "Delete: enabled (remote files not in local will be removed)"
    elif [[ "$direction" == "push" ]]; then
        echo "Delete: off (pass --delete to remove remote-only files)"
    fi
    echo "Log: $WEBSYNC_LOG"
    echo ""

    # --- Pre-flight checks ---
    local local_check="${LOCAL_DIR%/}"
    if [[ "$direction" == "push" && ! -d "$local_check" ]]; then
        echo "ERROR: Local directory does not exist: $local_check"
        echo "  Create it first, or check your profile's LOCAL_DIR setting."
        exit 1
    fi

    if [[ "$direction" == "pull" && ! -d "$local_check" ]]; then
        echo "Local directory does not exist. Creating: $local_check"
        mkdir -p "$local_check"
    fi

    if ! ssh -o ConnectTimeout=10 -o BatchMode=yes "$REMOTE_HOST" "echo ok" >/dev/null 2>&1; then
        echo "ERROR: Cannot connect to remote host '$REMOTE_HOST'."
        echo "  Possible causes:"
        echo "    - Host is unreachable (check your internet connection)"
        echo "    - SSH config is missing or wrong (check ~/.ssh/config)"
        echo "    - SSH key auth failed (run 'ssh $REMOTE_HOST' to test manually)"
        echo "    - Wrong hostname in profile (run 'wd-websync config ${PROFILE_NAME:-<profile>}' to check)"
        exit 1
    fi

    if ! ssh "$REMOTE_HOST" "test -d '${REMOTE_DIR%/}'" 2>/dev/null; then
        if [[ "$direction" == "push" ]]; then
            echo "Remote directory does not exist: $REMOTE_HOST:$REMOTE_DIR"
            echo -n "Create it? (y/n): "
            read -r create_yn
            if [[ "$(echo "$create_yn" | tr '[:upper:]' '[:lower:]')" == "y" ]]; then
                ssh "$REMOTE_HOST" "mkdir -p '${REMOTE_DIR%/}'"
            else
                echo "Aborted."
                exit 0
            fi
        else
            echo "ERROR: Remote directory does not exist: $REMOTE_HOST:$REMOTE_DIR"
            echo "  Check your profile's REMOTE_DIR setting."
            exit 1
        fi
    fi

    # --- Execute rsync ---
    rsync "${rsync_args[@]}" "$source" "$destination"
    local exit_code=$?

    echo ""

    if [[ $exit_code -ne 0 ]]; then
        echo "ERROR: rsync failed (exit code $exit_code)."
        case $exit_code in
            1)  echo "  Syntax or usage error — this is likely a bug in wd-websync." ;;
            2)  echo "  Protocol incompatibility — local and remote rsync versions may be mismatched." ;;
            3)  echo "  Errors selecting input/output files or directories."
                echo "  Check that paths exist and you have the right permissions." ;;
            5)  echo "  Error starting client-server protocol."
                echo "  The remote shell (SSH) connected but rsync couldn't start on the server." ;;
            10) echo "  Error in socket I/O — connection was interrupted mid-transfer." ;;
            11) echo "  Error in file I/O — check disk space on both sides." ;;
            12) echo "  Error in rsync protocol data stream — transfer was corrupted." ;;
            14) echo "  Error in IPC code — internal rsync error." ;;
            20) echo "  Received SIGUSR1 or SIGINT — transfer was cancelled." ;;
            21) echo "  Some error returned by waitpid()." ;;
            22) echo "  Error allocating core memory buffers." ;;
            23) echo "  Partial transfer — some files were not transferred."
                echo "  Check permissions on both local and remote sides." ;;
            24) echo "  Partial transfer — some source files vanished during transfer."
                echo "  A file was deleted or renamed while rsync was running." ;;
            25) echo "  The --max-delete limit was reached." ;;
            30) echo "  Timeout in data send/receive — connection too slow or server unresponsive." ;;
            35) echo "  Timeout waiting for daemon connection." ;;
            127) echo "  rsync not found — is it installed? Try: brew install rsync" ;;
            255) echo "  SSH connection failed unexpectedly during transfer."
                 echo "  The connection may have dropped, or the server closed the session." ;;
            *)  echo "  Unexpected error. Run with -v for more detail." ;;
        esac
        exit $exit_code
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "Pass -d FALSE to execute."
    else
        echo "--- Done ---"
        if [[ "$direction" == "push" && -n "$PROFILE_NAME" ]]; then
            mark_first_push_done "$PROFILE_NAME"
        fi
    fi
    echo "Log: $(basename "$WEBSYNC_LOG")"
}

# ---------------------------------------------------------------
# Main — route to the right subcommand
# ---------------------------------------------------------------

if [[ $# -eq 0 ]]; then
    show_usage
    exit 0
fi

case "$1" in
    pull|push)
        cmd_sync "$@"
        ;;
    config)
        cmd_config "$2"
        ;;
    show)
        cmd_show "$2"
        ;;
    delete)
        cmd_delete "$2"
        ;;
    list)
        cmd_list
        ;;
    -h|--help|help)
        show_usage
        ;;
    *)
        echo "Error: Unknown command '$1'"
        show_usage
        exit 1
        ;;
esac
