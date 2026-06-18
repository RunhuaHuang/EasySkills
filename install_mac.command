#!/usr/bin/env bash

# ==============================================================================
# Script: install_mac.command (macOS)
# Description: Self-relocating double-clickable installer for macOS.
#              Copies only _maintenance + README_SYSTEM.md to ~/EasySkills.
#              Preserves user custom-targets.txt across upgrades.
# ==============================================================================

# Fail fast on errors and unset variables — previously errors were silently
# swallowed (a failed cp left a broken install with no message).
set -eu

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

  # Preserve per-machine runtime files (unmapped targets + WebUI token)
  PRESERVE_DIR=$(mktemp -d)
  [ -f "$PERM_DIR/_maintenance/disabled-targets.txt" ] && cp "$PERM_DIR/_maintenance/disabled-targets.txt" "$PRESERVE_DIR/disabled-targets.txt"
  [ -f "$PERM_DIR/_maintenance/.easyskills-token" ] && cp "$PERM_DIR/_maintenance/.easyskills-token" "$PRESERVE_DIR/.easyskills-token"

  # --- Atomic install of _maintenance/ ---
  # Validate source first: never destroy the existing install if the source
  # tree is missing/incomplete.
  if [ ! -d "$CURRENT_DIR/_maintenance" ] || [ ! -f "$CURRENT_DIR/_maintenance/deploy.sh" ] || [ ! -f "$CURRENT_DIR/README_SYSTEM.md" ]; then
    echo "Error: source _maintenance/ missing or incomplete. Aborting; existing install untouched." >&2
    exit 1
  fi
  # Build into a sibling temp dir, verify, then swap via atomic rename — avoids
  # the "rm -rf then cp" footgun where a failed cp bricks the install.
  NEW_MAINT="$PERM_DIR/_maintenance.new"
  rm -rf "$NEW_MAINT"
  cp -R "$CURRENT_DIR/_maintenance" "$NEW_MAINT"
  if [ ! -f "$NEW_MAINT/deploy.sh" ]; then
    echo "Error: copy of _maintenance/ failed. Aborting; existing install untouched." >&2
    rm -rf "$NEW_MAINT"
    exit 1
  fi
  # Swap with rollback: current -> .bak, new -> current. Avoid a window where a
  # failed mv leaves no usable _maintenance at all.
  OLD_MAINT="$PERM_DIR/_maintenance"
  BACKUP_MAINT="$PERM_DIR/_maintenance.bak"
  PREV_BACKUP="$PERM_DIR/_maintenance.bak.prev"
  rm -rf "$PREV_BACKUP"
  if [ -d "$OLD_MAINT" ]; then
    [ -d "$BACKUP_MAINT" ] && mv "$BACKUP_MAINT" "$PREV_BACKUP"
    if ! mv "$OLD_MAINT" "$BACKUP_MAINT"; then
      echo "Error: could not rotate existing _maintenance. Existing install untouched." >&2
      [ -d "$PREV_BACKUP" ] && mv "$PREV_BACKUP" "$BACKUP_MAINT"
      rm -rf "$NEW_MAINT"
      exit 1
    fi
  fi
  if ! mv "$NEW_MAINT" "$OLD_MAINT"; then
    echo "Error: install swap failed; rolling back previous _maintenance." >&2
    rm -rf "$NEW_MAINT"
    if [ ! -d "$OLD_MAINT" ] && [ -d "$BACKUP_MAINT" ]; then
      mv "$BACKUP_MAINT" "$OLD_MAINT" || true
    fi
    if [ -d "$PREV_BACKUP" ]; then
      [ ! -d "$BACKUP_MAINT" ] && mv "$PREV_BACKUP" "$BACKUP_MAINT" || rm -rf "$PREV_BACKUP"
    fi
    exit 1
  fi
  rm -rf "$PREV_BACKUP"
  cp "$CURRENT_DIR/README_SYSTEM.md" "$PERM_DIR/README_SYSTEM.md"
  rm -f "$PERM_DIR/SKILL.md"

  # Restore preserved runtime files
  [ -f "$PRESERVE_DIR/disabled-targets.txt" ] && cp "$PRESERVE_DIR/disabled-targets.txt" "$PERM_DIR/_maintenance/disabled-targets.txt"
  if [ -f "$PRESERVE_DIR/.easyskills-token" ]; then
    cp "$PRESERVE_DIR/.easyskills-token" "$PERM_DIR/_maintenance/.easyskills-token"
    chmod 600 "$PERM_DIR/_maintenance/.easyskills-token"
  fi
  rm -rf "$PRESERVE_DIR"

  # Initialize custom-targets.txt at root if not present
  if [ ! -f "$PERM_DIR/custom-targets.txt" ]; then
    cp "$PERM_DIR/_maintenance/custom-targets.template.txt" "$PERM_DIR/custom-targets.txt" 2>/dev/null || true
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

# --- Launch WebUI in background & pop up browser ---
if command -v python3 &>/dev/null; then
  echo "Launching WebUI Manager on port 6633..."
  bash "$PERM_DIR/_maintenance/deploy.sh" --webui
  echo "WebUI URL: http://127.0.0.1:6633"
else
  echo "Note: python3 not found — WebUI skipped. Install Python 3 to use the WebUI."
fi

echo "============================================="
echo "Press any key to close this window..."
read -n 1 -s
