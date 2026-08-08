#!/usr/bin/env bash

# ==============================================================================
# Script: watch.sh (macOS / Linux)
# Description: Installs background watcher to monitor the central directory
#              and auto-sync. macOS: launchd. Linux: systemd path unit.
# ==============================================================================

# Resolve symlinks to find the real script location
SOURCE="$0"
while [ -L "$SOURCE" ]; do
  DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
CENTRAL_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$SCRIPT_DIR"
OS="$(uname -s)"

echo "============================================="
echo "Installing EasySkills Watcher..."
echo "============================================="

# 1. Run the first-time manual deploy
bash "./deploy.sh" "$@"

# 2. Platform-specific watcher installation
if [ "$OS" = "Darwin" ]; then
  # ---- macOS: launchd ----
  PLIST_PATH="$HOME/Library/LaunchAgents/com.easyskills.watcher.plist"
  LABEL="com.easyskills.watcher"
  UID_VAL=$(id -u)
  DOMAIN_TARGET="gui/$UID_VAL"
  SERVICE_TARGET="gui/$UID_VAL/$LABEL"

  mkdir -p "$(dirname "$PLIST_PATH")"

  PROMA_INTERVAL=0
  [ -d "$HOME/.proma" ] && PROMA_INTERVAL=300

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$PLIST_PATH" "$LABEL" "$SCRIPT_DIR/deploy.sh" "$CENTRAL_DIR" "$PROMA_INTERVAL" "$@" <<'PY'
import plistlib
import sys
import os

plist_path, label, deploy_script, central_dir, proma_interval, *args = sys.argv[1:]
plist = {
    "Label": label,
    "ProgramArguments": [deploy_script, *args],
    "WatchPaths": [central_dir, os.path.join(central_dir, "instructions")],
    "RunAtLoad": True,
}
if int(proma_interval):
    plist["StartInterval"] = int(proma_interval)

with open(plist_path, "wb") as f:
    plistlib.dump(plist, f)
PY
  else
    # PlistBuddy fallback (no python3 available). Quote paths defensively:
    # $SCRIPT_DIR/$CENTRAL_DIR may contain spaces (e.g. /Users/John Smith) or
    # non-ASCII characters (e.g. EasySkills维护工具/.engine), so the value passed to
    # -c must be quoted, otherwise PlistBuddy splits it into multiple keys.
    /usr/libexec/PlistBuddy -c "Clear dict" "$PLIST_PATH" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy -c "Add :Label string $LABEL" "$PLIST_PATH"
    /usr/libexec/PlistBuddy -c "Add :ProgramArguments array" "$PLIST_PATH"
    /usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string \"$SCRIPT_DIR/deploy.sh\"" "$PLIST_PATH"
    arg_index=1
    for arg in "$@"; do
      /usr/libexec/PlistBuddy -c "Add :ProgramArguments:$arg_index string \"$arg\"" "$PLIST_PATH"
      arg_index=$((arg_index + 1))
    done
    /usr/libexec/PlistBuddy -c "Add :WatchPaths array" "$PLIST_PATH"
    /usr/libexec/PlistBuddy -c "Add :WatchPaths:0 string \"$CENTRAL_DIR\"" "$PLIST_PATH"
    /usr/libexec/PlistBuddy -c "Add :WatchPaths:1 string \"$CENTRAL_DIR/instructions\"" "$PLIST_PATH"
    /usr/libexec/PlistBuddy -c "Add :RunAtLoad bool true" "$PLIST_PATH"
    if [ "$PROMA_INTERVAL" -gt 0 ]; then
      /usr/libexec/PlistBuddy -c "Add :StartInterval integer $PROMA_INTERVAL" "$PLIST_PATH"
    fi
  fi

  launchctl bootout "$SERVICE_TARGET" 2>/dev/null || launchctl unload -w "$PLIST_PATH" 2>/dev/null
  launchctl enable "$SERVICE_TARGET" 2>/dev/null
  launchctl bootstrap "$DOMAIN_TARGET" "$PLIST_PATH" 2>/dev/null || launchctl load -w "$PLIST_PATH" 2>/dev/null
  launchctl kickstart -k "$SERVICE_TARGET" 2>/dev/null || launchctl start "$LABEL" 2>/dev/null

  echo "============================================="
  echo "macOS EasySkills Watcher installed successfully!"
  echo "   Watching: $CENTRAL_DIR"
  echo "============================================="

elif [ "$OS" = "Linux" ]; then
  # ---- Linux: systemd user units ----
  if ! command -v systemctl &>/dev/null; then
    echo "Error: systemd not found. Cannot install watcher on this Linux system."
    exit 1
  fi

  SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
  mkdir -p "$SYSTEMD_USER_DIR"

  # Propagate user arguments (like macOS launchd does)
  EXTRA_ARGS="${*:---sync}"

  # Install service unit
  cat > "$SYSTEMD_USER_DIR/easyskills-watcher.service" <<EOF
[Unit]
Description=EasySkills Watcher — auto-sync skills to all agents
After=default.target

[Service]
Type=oneshot
ExecStart=/bin/bash "$SCRIPT_DIR/deploy.sh" $EXTRA_ARGS
WorkingDirectory=$CENTRAL_DIR

[Install]
WantedBy=default.target
EOF

  # Install path unit.
  # NOTE: systemd PathModified is NOT recursive — it only fires when the central
  # dir itself changes (a skill folder added/removed/renamed at the top level),
  # not when files INSIDE a skill subfolder are edited. The timer below is the
  # safety net that catches those in-folder edits.
  cat > "$SYSTEMD_USER_DIR/easyskills-watcher.path" <<EOF
[Unit]
Description=EasySkills Watcher path trigger — monitors ~/EasySkills for changes

[Path]
PathModified=$CENTRAL_DIR
PathModified=$CENTRAL_DIR/instructions

[Install]
WantedBy=default.target
EOF

  # Install timer unit (fallback for non-top-level edits the path unit misses)
  cat > "$SYSTEMD_USER_DIR/easyskills-watcher.timer" <<EOF
[Unit]
Description=EasySkills Watcher periodic sync timer — fallback for subdirectories

[Timer]
OnBootSec=1min
OnUnitActiveSec=2min

[Install]
WantedBy=timers.target
EOF

  systemctl --user daemon-reload
  systemctl --user enable easyskills-watcher.path
  systemctl --user start easyskills-watcher.path
  systemctl --user enable easyskills-watcher.timer
  systemctl --user start easyskills-watcher.timer

  # Also run an initial sync via the service
  systemctl --user start easyskills-watcher.service 2>/dev/null || true

  echo "============================================="
  echo "Linux EasySkills Watcher installed successfully!"
  echo "   Watching: $CENTRAL_DIR"
  echo "   Units: ~/.config/systemd/user/easyskills-watcher.{service,path,timer}"
  echo "============================================="

else
  echo "Error: Unsupported platform: $OS"
  echo "  Supported: macOS (launchd), Linux (systemd)"
  exit 1
fi
