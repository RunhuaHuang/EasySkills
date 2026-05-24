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

# Migrate custom-targets.txt from old _maintenance/ location to root (< v1.1.0)
if [ -f "$PERM_DIR/_maintenance/custom-targets.txt" ]; then
  USER_PATHS=$(grep -v -E '^\s*(#|$)' "$PERM_DIR/_maintenance/custom-targets.txt" 2>/dev/null || true)
  if [ -n "$USER_PATHS" ]; then
    touch "$PERM_DIR/custom-targets.txt"
    echo "$USER_PATHS" | while IFS= read -r line; do
      if ! grep -Fxq "$line" "$PERM_DIR/custom-targets.txt" 2>/dev/null; then
        echo "$line" >> "$PERM_DIR/custom-targets.txt"
      fi
    done
    echo "Migrated custom targets to ~/EasySkills/custom-targets.txt"
  fi
fi

# Clean install of _maintenance/
rm -rf "$PERM_DIR/_maintenance"
cp -R "$SRC_DIR/_maintenance" "$PERM_DIR/_maintenance"
cp "$SRC_DIR/SKILL.md" "$PERM_DIR/_maintenance/SKILL.md"

# Initialize custom-targets.txt at root if not present
if [ ! -f "$PERM_DIR/custom-targets.txt" ]; then
  cp "$PERM_DIR/_maintenance/custom-targets.template.txt" "$PERM_DIR/custom-targets.txt" 2>/dev/null || true
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
bash "$PERM_DIR/_maintenance/watch.sh"

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
