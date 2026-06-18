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
WEBUI_LABELS=("com.easyskills.webui" "com.easyskills.webui.manual")

# 1. Unload launchd service (modern API with fallback)
if [ -f "$PLIST_PATH" ]; then
  launchctl bootout "$SERVICE_TARGET" 2>/dev/null || launchctl unload "$PLIST_PATH" 2>/dev/null
  rm -f "$PLIST_PATH"
fi

# Stop WebUI launchd jobs and their detached backend child before moving the
# install directory. The macOS WebUI supervisor intentionally starts webui.py as
# a detached child, so removing the launchd job alone is not enough.
for webui_label in "${WEBUI_LABELS[@]}"; do
  launchctl remove "$webui_label" 2>/dev/null || true
done
for pattern in "[E]asySkills/_maintenance/webui-service\\.sh" "[E]asySkills/_maintenance/webui\\.py"; do
  pids=$(pgrep -f "$pattern" 2>/dev/null || true)
  if [ -n "$pids" ]; then
    echo "$pids" | while read -r p; do kill "$p" 2>/dev/null || true; done
  fi
done

# 2. Clean up all symlinks in agent directories, then move ~/EasySkills to Trash
#    (recoverable) instead of irreversible rm -rf — users keep custom skills there.
move_to_trash() {
  local target="$1"
  if [ ! -e "$target" ]; then return 0; fi
  # AppleScript via osascript: Finder "delete" moves to Trash (recoverable).
  if command -v osascript >/dev/null 2>&1; then
    if osascript -e "tell application \"Finder\" to delete POSIX file \"$target\"" >/dev/null 2>&1; then
      echo "Moved to Trash: $target"
      return 0
    fi
  fi
  # Fallback: no Finder/osascript — do NOT silently destroy user data.
  echo "Warning: could not move to Trash automatically." >&2
  echo "         Please manually delete: $target" >&2
  return 1
}

if [ -d "$HOME/EasySkills/_maintenance" ]; then
  bash "$HOME/EasySkills/_maintenance/deploy.sh" --cleanup
  move_to_trash "$HOME/EasySkills"
fi

echo "============================================="
echo "Uninstallation complete."
echo "Press any key to close this window..."
read -n 1 -s
