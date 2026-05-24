#!/usr/bin/env bash

# ==============================================================================
# Script: watch.sh (macOS)
# Description: Installs the launchd agent plist to monitor the central directory
#              and auto-sync. Uses modern launchctl API (macOS 13+) with fallback.
# ==============================================================================

cd "$(dirname "$0")"

SCRIPT_DIR="$(pwd)"
CENTRAL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLIST_PATH="$HOME/Library/LaunchAgents/com.easyskills.watcher.plist"
LABEL="com.easyskills.watcher"
UID_VAL=$(id -u)
DOMAIN_TARGET="gui/$UID_VAL"
SERVICE_TARGET="gui/$UID_VAL/$LABEL"

echo "============================================="
echo "Installing macOS EasySkills Watcher..."
echo "============================================="

# 1. Run the first-time manual deploy
bash "./deploy.sh" "$@"

# 2. Write the launchd plist file dynamically
mkdir -p "$(dirname "$PLIST_PATH")"

PROMA_INTERVAL=0
[ -d "$HOME/.proma" ] && PROMA_INTERVAL=300

if command -v python3 >/dev/null 2>&1; then
  python3 - "$PLIST_PATH" "$LABEL" "$SCRIPT_DIR/deploy.sh" "$CENTRAL_DIR" "$PROMA_INTERVAL" "$@" <<'PY'
import plistlib
import sys

plist_path, label, deploy_script, central_dir, proma_interval, *args = sys.argv[1:]
plist = {
    "Label": label,
    "ProgramArguments": [deploy_script, *args],
    "WatchPaths": [central_dir],
    "RunAtLoad": True,
}
if int(proma_interval):
    plist["StartInterval"] = int(proma_interval)

with open(plist_path, "wb") as f:
    plistlib.dump(plist, f)
PY
else
  /usr/libexec/PlistBuddy -c "Clear dict" "$PLIST_PATH" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Add :Label string $LABEL" "$PLIST_PATH"
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments array" "$PLIST_PATH"
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string $SCRIPT_DIR/deploy.sh" "$PLIST_PATH"
  arg_index=1
  for arg in "$@"; do
    /usr/libexec/PlistBuddy -c "Add :ProgramArguments:$arg_index string $arg" "$PLIST_PATH"
    arg_index=$((arg_index + 1))
  done
  /usr/libexec/PlistBuddy -c "Add :WatchPaths array" "$PLIST_PATH"
  /usr/libexec/PlistBuddy -c "Add :WatchPaths:0 string $CENTRAL_DIR" "$PLIST_PATH"
  /usr/libexec/PlistBuddy -c "Add :RunAtLoad bool true" "$PLIST_PATH"
  if [ "$PROMA_INTERVAL" -gt 0 ]; then
    /usr/libexec/PlistBuddy -c "Add :StartInterval integer $PROMA_INTERVAL" "$PLIST_PATH"
  fi
fi

# 3. Unload any existing service, then load the new one
#    Modern API (macOS 13+): bootstrap/bootout
#    Legacy API fallback: load/unload
launchctl bootout "$SERVICE_TARGET" 2>/dev/null || launchctl unload -w "$PLIST_PATH" 2>/dev/null
launchctl enable "$SERVICE_TARGET" 2>/dev/null
launchctl bootstrap "$DOMAIN_TARGET" "$PLIST_PATH" 2>/dev/null || launchctl load -w "$PLIST_PATH" 2>/dev/null
launchctl kickstart -k "$SERVICE_TARGET" 2>/dev/null || launchctl start "$LABEL" 2>/dev/null

echo "============================================="
echo "macOS EasySkills Watcher installed successfully!"
echo "   Watching: $CENTRAL_DIR"
echo "============================================="
