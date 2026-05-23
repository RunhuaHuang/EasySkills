#!/usr/bin/env bash

# ==============================================================================
# Script: unwatch.sh (macOS)
# Description: Safely unloads and removes the com.easyskills.watcher launchd service.
#              Uses modern launchctl API (macOS 13+) with fallback.
# ==============================================================================

PLIST_PATH="$HOME/Library/LaunchAgents/com.easyskills.watcher.plist"
LABEL="com.easyskills.watcher"
UID_VAL=$(id -u)
SERVICE_TARGET="gui/$UID_VAL/$LABEL"

echo "============================================="
echo "Uninstalling macOS EasySkills Watcher..."
echo "============================================="

if [ -f "$PLIST_PATH" ]; then
  launchctl bootout "$SERVICE_TARGET" 2>/dev/null || launchctl unload "$PLIST_PATH" 2>/dev/null
  rm -f "$PLIST_PATH"
  echo "Unloaded and deleted launchd plist."
else
  echo "No launchd watcher found."
fi

echo "============================================="
echo "Uninstallation complete."
echo "============================================="
