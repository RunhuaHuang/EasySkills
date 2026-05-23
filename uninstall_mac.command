#!/usr/bin/env bash

# ==============================================================================
# Script: uninstall_mac.command (macOS)
# Description: Self-cleaning double-clickable uninstaller for macOS.
# ==============================================================================

cd "$(dirname "$0")"

echo "============================================="
echo "Uninstalling EasySkills (macOS)..."
echo "============================================="

LABEL="com.easyskills.watcher"
UID_VAL=$(id -u)
SERVICE_TARGET="gui/$UID_VAL/$LABEL"
PLIST_PATH="$HOME/Library/LaunchAgents/com.easyskills.watcher.plist"

# 1. Unload launchd service (modern API with fallback)
if [ -f "$PLIST_PATH" ]; then
  launchctl bootout "$SERVICE_TARGET" 2>/dev/null || launchctl unload "$PLIST_PATH" 2>/dev/null
  rm -f "$PLIST_PATH"
fi

# 2. Clean up all symlinks in agent directories, then remove home folder
if [ -d "$HOME/EasySkills/_maintenance" ]; then
  bash "$HOME/EasySkills/_maintenance/deploy.sh" --cleanup
  rm -rf "$HOME/EasySkills"
  echo "Successfully cleaned up ~/EasySkills and all agent symlinks."
fi

echo "============================================="
echo "Uninstallation complete."
echo "Press any key to close this window..."
read -n 1 -s
