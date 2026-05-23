#!/usr/bin/env bash

# ==============================================================================
# Script: install_mac.command (macOS)
# Description: Self-relocating double-clickable installer for macOS.
#              Copies only _maintenance + SKILL.md to ~/EasySkills.
#              Preserves user custom-targets.txt across upgrades.
# ==============================================================================

cd "$(dirname "$0")"
CURRENT_DIR="$(pwd)"
PERM_DIR="$HOME/EasySkills"

echo "============================================="
echo "Starting EasySkills Installation (macOS)..."
echo "============================================="

if [ "$CURRENT_DIR" != "$PERM_DIR" ]; then
  echo "Deploying to: $PERM_DIR"
  mkdir -p "$PERM_DIR"

  # --- Preserve user data before overwriting _maintenance/ ---
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

  # --- Clean install of _maintenance/ ---
  rm -rf "$PERM_DIR/_maintenance"
  cp -R "$CURRENT_DIR/_maintenance" "$PERM_DIR/_maintenance"
  cp "$CURRENT_DIR/SKILL.md" "$PERM_DIR/_maintenance/SKILL.md"

  # Initialize custom-targets.txt at root if not present
  if [ ! -f "$PERM_DIR/custom-targets.txt" ]; then
    cp "$PERM_DIR/_maintenance/custom-targets.txt" "$PERM_DIR/custom-targets.txt" 2>/dev/null || true
  fi

  # --- Version reporting ---
  NEW_VERSION=$(cat "$PERM_DIR/_maintenance/.version" 2>/dev/null || echo "unknown")
  if [ -n "$OLD_VERSION" ] && [ "$OLD_VERSION" != "$NEW_VERSION" ]; then
    echo "Upgraded: $OLD_VERSION -> $NEW_VERSION"
  else
    echo "Installed version: $NEW_VERSION"
  fi
fi

chmod +x "$PERM_DIR/_maintenance/"*.sh
bash "$PERM_DIR/_maintenance/watch.sh"

echo "============================================="
echo "Press any key to close this window..."
read -n 1 -s
