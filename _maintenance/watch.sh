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

cat <<EOF > "$PLIST_PATH"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$SCRIPT_DIR/deploy.sh</string>
EOF

for arg in "$@"; do
  echo "        <string>$arg</string>" >> "$PLIST_PATH"
done

cat <<EOF >> "$PLIST_PATH"
    </array>
    <key>WatchPaths</key>
    <array>
        <string>$CENTRAL_DIR</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
EOF

# 3. Unload any existing service, then load the new one
#    Modern API (macOS 13+): bootstrap/bootout
#    Legacy API fallback: load/unload
launchctl bootout "$SERVICE_TARGET" 2>/dev/null || launchctl unload "$PLIST_PATH" 2>/dev/null
launchctl bootstrap "$DOMAIN_TARGET" "$PLIST_PATH" 2>/dev/null || launchctl load "$PLIST_PATH" 2>/dev/null
launchctl kickstart -k "$SERVICE_TARGET" 2>/dev/null || launchctl start "$LABEL" 2>/dev/null

echo "============================================="
echo "macOS EasySkills Watcher installed successfully!"
echo "   Watching: $CENTRAL_DIR"
echo "============================================="
