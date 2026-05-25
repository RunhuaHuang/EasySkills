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
service_loaded=false

echo "============================================="
echo "Uninstalling macOS EasySkills Watcher..."
echo "============================================="

if launchctl print "$SERVICE_TARGET" >/dev/null 2>&1; then
  service_loaded=true
fi

if [ "$service_loaded" = true ] || [ -f "$PLIST_PATH" ]; then
  launchctl bootout "$SERVICE_TARGET" 2>/dev/null || {
    if [ -f "$PLIST_PATH" ]; then
      launchctl unload "$PLIST_PATH" 2>/dev/null || true
    fi
  }
  rm -f "$PLIST_PATH"
  echo "Unloaded watcher service and deleted launchd plist."
else
  echo "No launchd watcher found."
fi

if launchctl print "$SERVICE_TARGET" >/dev/null 2>&1; then
  echo "Error: launchd watcher is still loaded: $SERVICE_TARGET" >&2
  echo "============================================="
  echo "Uninstallation failed."
  echo "============================================="
  exit 1
fi

echo "============================================="
echo "Uninstallation complete."
echo "============================================="
