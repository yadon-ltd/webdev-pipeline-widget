#!/usr/bin/env bash
# webdev-deploy-pipeline-installation — install pipeline tools to PATH
#
# Installs: wd-lib.sh, wd-deploy, wd-snapshot, wd-websync, wd-gitsync
# All tools are placed in /usr/local/bin/ so they share a directory
# and can locate wd-lib.sh via dirname "$0".
set -euo pipefail

# --- Install shared library (must be alongside the tools) ---
sudo cp webdev-lib.sh /usr/local/bin/wd-lib.sh

# --- Install the four pipeline tools ---
sudo cp webdev-deploy.sh /usr/local/bin/wd-deploy
sudo cp webdev-snapshot.sh /usr/local/bin/wd-snapshot
sudo cp webdev-websync.sh /usr/local/bin/wd-websync
sudo cp webdev-gitsync.sh /usr/local/bin/wd-gitsync

# --- Set permissions ---
# wd-lib.sh is sourced (not executed directly), but 755 keeps it
# consistent with the other files and avoids permission headaches.
sudo chmod 755 /usr/local/bin/wd-lib.sh \
               /usr/local/bin/wd-deploy \
               /usr/local/bin/wd-snapshot \
               /usr/local/bin/wd-websync \
               /usr/local/bin/wd-gitsync

echo "Pipeline installed: wd-lib.sh, wd-deploy, wd-snapshot, wd-websync, wd-gitsync"
