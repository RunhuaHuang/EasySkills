#!/usr/bin/env bash

# ==============================================================================
# Script: unwatch.sh (macOS / Linux)
# Description: Safely unloads and removes the EasySkills watcher service.
#              macOS: launchd. Linux: systemd path unit.
# ==============================================================================

OS="$(uname -s)"

echo "============================================="
echo "Uninstalling EasySkills Watcher..."
echo "============================================="

if [ "$OS" = "Darwin" ]; then
  PLIST_PATH="$HOME/Library/LaunchAgents/com.easyskills.watcher.plist"
  LABEL="com.easyskills.watcher"
  UID_VAL=$(id -u)
  SERVICE_TARGET="gui/$UID_VAL/$LABEL"
  service_loaded=false

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

elif [ "$OS" = "Linux" ]; then
  if command -v systemctl &>/dev/null; then
    systemctl --user stop easyskills-watcher.path 2>/dev/null || true
    systemctl --user stop easyskills-watcher.timer 2>/dev/null || true
    systemctl --user stop easyskills-watcher.service 2>/dev/null || true
    systemctl --user disable easyskills-watcher.path 2>/dev/null || true
    systemctl --user disable easyskills-watcher.timer 2>/dev/null || true
    systemctl --user disable easyskills-watcher.service 2>/dev/null || true
    rm -f "$HOME/.config/systemd/user/easyskills-watcher.service"
    rm -f "$HOME/.config/systemd/user/easyskills-watcher.path"
    rm -f "$HOME/.config/systemd/user/easyskills-watcher.timer"
    systemctl --user daemon-reload 2>/dev/null || true
    echo "Unloaded and removed systemd watcher units."
  else
    echo "systemctl not found. Cannot uninstall watcher."
  fi

else
  echo "Error: Unsupported platform: $OS"
  exit 1
fi

echo "============================================="
echo "Uninstallation complete."
echo "============================================="
