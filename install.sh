#!/usr/bin/env bash

# ==============================================================================
# Script: install.sh (macOS/Linux remote installer)
# Usage:  curl -fsSL https://raw.githubusercontent.com/RunhuaHuang/EasySkills/main/install.sh | bash
# ==============================================================================

set -e

REPO="RunhuaHuang/EasySkills"
BRANCH="main"
PERM_DIR="$HOME/EasySkills"
TMP_DIR=$(mktemp -d)

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

echo "============================================="
echo "EasySkills Remote Installer (macOS/Linux)"
echo "============================================="

# --- Download ---
echo "Downloading EasySkills..."
if command -v git &>/dev/null; then
  git clone --depth 1 --branch "$BRANCH" "https://github.com/$REPO.git" "$TMP_DIR/EasySkills" 2>/dev/null
  SRC_DIR="$TMP_DIR/EasySkills"
else
  curl -fsSL "https://github.com/$REPO/archive/refs/heads/$BRANCH.tar.gz" -o "$TMP_DIR/repo.tar.gz"
  tar -xzf "$TMP_DIR/repo.tar.gz" -C "$TMP_DIR"
  SRC_DIR="$TMP_DIR/EasySkills-$BRANCH"
fi

# --- Install ---
mkdir -p "$PERM_DIR"

# Preserve old version for upgrade reporting
OLD_VERSION=""
if [ -f "$PERM_DIR/_maintenance/.version" ]; then
  OLD_VERSION=$(cat "$PERM_DIR/_maintenance/.version")
fi

# Preserve user custom-targets.txt before wiping _maintenance/
CUSTOM_BACKUP=""
CUSTOM_FILE="$PERM_DIR/_maintenance/custom-targets.txt"
if [ -f "$CUSTOM_FILE" ]; then
  CUSTOM_BACKUP=$(cat "$CUSTOM_FILE")
fi
# Also migrate from legacy root location (pre-v1.2)
LEGACY_ROOT_CT="$PERM_DIR/custom-targets.txt"
if [ -f "$LEGACY_ROOT_CT" ]; then
  LEGACY_LINES=$(grep -v -E '^\s*(#|$)' "$LEGACY_ROOT_CT" 2>/dev/null || true)
  if [ -n "$LEGACY_LINES" ]; then
    CUSTOM_BACKUP="$CUSTOM_BACKUP
$LEGACY_LINES"
  fi
  rm -f "$LEGACY_ROOT_CT"
fi

# Clean install of _maintenance/
rm -rf "$PERM_DIR/_maintenance"
cp -R "$SRC_DIR/_maintenance" "$PERM_DIR/_maintenance"
cp "$SRC_DIR/SKILL.md" "$PERM_DIR/SKILL.md"

# Restore user custom-targets.txt
if [ -n "$CUSTOM_BACKUP" ]; then
  echo "$CUSTOM_BACKUP" > "$CUSTOM_FILE"
fi

# Version reporting
NEW_VERSION=$(cat "$PERM_DIR/_maintenance/.version" 2>/dev/null || echo "unknown")
if [ -n "$OLD_VERSION" ] && [ "$OLD_VERSION" != "$NEW_VERSION" ]; then
  echo "Upgraded: $OLD_VERSION -> $NEW_VERSION"
else
  echo "Installed version: $NEW_VERSION"
fi

# --- Activate ---
chmod +x "$PERM_DIR/_maintenance/"*.sh
chmod +x "$PERM_DIR/_maintenance/macOS/"*.command 2>/dev/null || true
bash "$PERM_DIR/_maintenance/watch.sh"

# --- Launch WebUI in background & pop up browser ---
if command -v python3 &>/dev/null; then
  echo "Launching WebUI Manager on port 6633..."
  nohup python3 "$PERM_DIR/_maintenance/webui.py" >/dev/null 2>&1 &
else
  echo "Note: python3 not found — WebUI skipped. Install Python 3 to use the WebUI."
fi

# --- Verify watcher status ---
echo ""
if launchctl list 2>/dev/null | grep -q "easyskills"; then
  echo "✅ Watcher is running"
else
  echo "⚠️  Watcher not detected. Try: launchctl load ~/Library/LaunchAgents/com.easyskills.watcher.plist"
fi

echo "============================================="
echo "EasySkills installed successfully!"
echo "Drop your custom skills into: $PERM_DIR"
echo "============================================="
