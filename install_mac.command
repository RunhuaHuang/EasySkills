#!/usr/bin/env bash

# ==============================================================================
# Script: install_mac.command (macOS)
# Description: Self-relocating double-clickable installer for macOS.
#              Copies only EasySkills维护工具/.engine + README_SYSTEM.md to ~/EasySkills.
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

  # --- Preserve user data before overwriting EasySkills维护工具/.engine/ ---
  OLD_VERSION=""
  if [ -f "$PERM_DIR/EasySkills维护工具/.engine/.version" ]; then
    OLD_VERSION=$(cat "$PERM_DIR/EasySkills维护工具/.engine/.version")
  fi

  # Migrate custom-targets.txt from old EasySkills维护工具/.engine/ location to root (< v1.1.0)
  if [ -f "$PERM_DIR/EasySkills维护工具/.engine/custom-targets.txt" ]; then
    USER_PATHS=$(grep -v -E '^\s*(#|$)' "$PERM_DIR/EasySkills维护工具/.engine/custom-targets.txt" 2>/dev/null || true)
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
  [ -f "$PERM_DIR/EasySkills维护工具/.engine/disabled-targets.txt" ] && cp "$PERM_DIR/EasySkills维护工具/.engine/disabled-targets.txt" "$PRESERVE_DIR/disabled-targets.txt"
  [ -f "$PERM_DIR/EasySkills维护工具/.engine/.easyskills-token" ] && cp "$PERM_DIR/EasySkills维护工具/.engine/.easyskills-token" "$PRESERVE_DIR/.easyskills-token"
  # Migrate user config from a legacy _maintenance install (pre-4.1.0 directory
  # rename) when the new paths are absent.
  if [ ! -f "$PRESERVE_DIR/disabled-targets.txt" ] && [ -f "$PERM_DIR/_maintenance/disabled-targets.txt" ]; then
    cp "$PERM_DIR/_maintenance/disabled-targets.txt" "$PRESERVE_DIR/disabled-targets.txt"
  fi
  if [ ! -f "$PRESERVE_DIR/.easyskills-token" ] && [ -f "$PERM_DIR/_maintenance/.easyskills-token" ]; then
    cp "$PERM_DIR/_maintenance/.easyskills-token" "$PRESERVE_DIR/.easyskills-token"
  fi

  # --- Atomic install of EasySkills维护工具/.engine/ ---
  # Validate source first: never destroy the existing install if the source
  # tree is missing/incomplete.
  if [ ! -d "$CURRENT_DIR/EasySkills维护工具/.engine" ] || [ ! -f "$CURRENT_DIR/EasySkills维护工具/.engine/deploy.sh" ] || [ ! -f "$CURRENT_DIR/EasySkills维护工具/README_SYSTEM.md" ]; then
    echo "Error: source EasySkills维护工具/.engine/ missing or incomplete. Aborting; existing install untouched." >&2
    exit 1
  fi
  # Build into a sibling temp dir, verify, then swap via atomic rename — avoids
  # the "rm -rf then cp" footgun where a failed cp bricks the install.
  NEW_MAINT="$PERM_DIR/EasySkills维护工具/.engine.new"
  rm -rf "$NEW_MAINT"
  cp -R "$CURRENT_DIR/EasySkills维护工具/.engine" "$NEW_MAINT"
  if [ ! -f "$NEW_MAINT/deploy.sh" ]; then
    echo "Error: copy of EasySkills维护工具/.engine/ failed. Aborting; existing install untouched." >&2
    rm -rf "$NEW_MAINT"
    exit 1
  fi
  # Swap with rollback: current -> .bak, new -> current. Avoid a window where a
  # failed mv leaves no usable EasySkills维护工具/.engine at all.
  OLD_MAINT="$PERM_DIR/EasySkills维护工具/.engine"
  BACKUP_MAINT="$PERM_DIR/.maintenance-bak"
  PREV_BACKUP="$PERM_DIR/.maintenance-bak.prev"
  rm -rf "$PREV_BACKUP"
  if [ -d "$OLD_MAINT" ]; then
    [ -d "$BACKUP_MAINT" ] && mv "$BACKUP_MAINT" "$PREV_BACKUP"
    if ! mv "$OLD_MAINT" "$BACKUP_MAINT"; then
      echo "Error: could not rotate existing EasySkills维护工具/.engine. Existing install untouched." >&2
      [ -d "$PREV_BACKUP" ] && mv "$PREV_BACKUP" "$BACKUP_MAINT"
      rm -rf "$NEW_MAINT"
      exit 1
    fi
  fi
  if ! mv "$NEW_MAINT" "$OLD_MAINT"; then
    echo "Error: install swap failed; rolling back previous EasySkills维护工具/.engine." >&2
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
  cp "$CURRENT_DIR/EasySkills维护工具/README_SYSTEM.md" "$PERM_DIR/EasySkills维护工具/README_SYSTEM.md"
  rm -f "$PERM_DIR/SKILL.md"

  # Restore preserved runtime files
  [ -f "$PRESERVE_DIR/disabled-targets.txt" ] && cp "$PRESERVE_DIR/disabled-targets.txt" "$PERM_DIR/EasySkills维护工具/.engine/disabled-targets.txt"
  if [ -f "$PRESERVE_DIR/.easyskills-token" ]; then
    cp "$PRESERVE_DIR/.easyskills-token" "$PERM_DIR/EasySkills维护工具/.engine/.easyskills-token"
    chmod 600 "$PERM_DIR/EasySkills维护工具/.engine/.easyskills-token"
  fi
  rm -rf "$PRESERVE_DIR"

  # Initialize custom-targets.txt at root if not present
  if [ ! -f "$PERM_DIR/custom-targets.txt" ]; then
    cp "$PERM_DIR/EasySkills维护工具/.engine/custom-targets.template.txt" "$PERM_DIR/custom-targets.txt" 2>/dev/null || true
  fi

  # --- Version reporting ---
  NEW_VERSION=$(cat "$PERM_DIR/EasySkills维护工具/.engine/.version" 2>/dev/null || echo "unknown")
  if [ -n "$OLD_VERSION" ] && [ "$OLD_VERSION" != "$NEW_VERSION" ]; then
    echo "Upgraded: $OLD_VERSION -> $NEW_VERSION"
  else
    echo "Installed version: $NEW_VERSION"
  fi
fi

# Initialize user MCP config and install the optional Gateway binary.
mkdir -p "$PERM_DIR/mcp"
chmod 700 "$PERM_DIR/mcp" 2>/dev/null || true
if [ ! -f "$PERM_DIR/mcp/servers.json" ] && [ -f "$PERM_DIR/EasySkills维护工具/.engine/mcp-servers.template.json" ]; then
  cp "$PERM_DIR/EasySkills维护工具/.engine/mcp-servers.template.json" "$PERM_DIR/mcp/servers.json"
  chmod 600 "$PERM_DIR/mcp/servers.json" 2>/dev/null || true
fi
if [ -f "$PERM_DIR/EasySkills维护工具/.engine/install-gateway.sh" ]; then
  chmod +x "$PERM_DIR/EasySkills维护工具/.engine/install-gateway.sh"
  EASYSKILLS_GATEWAY_SOURCE="$CURRENT_DIR/gateway" \
    bash "$PERM_DIR/EasySkills维护工具/.engine/install-gateway.sh" || true
fi

chmod +x "$PERM_DIR/EasySkills维护工具/.engine/"*.sh
chmod +x "$PERM_DIR/EasySkills维护工具/.engine/launchers/"*.command 2>/dev/null || true

# --- Create the visible user entry: EasySkills维护工具/ with macOS/Windows
#     subfolders that link back into the hidden .engine directory (dot-prefixed,
#     so Finder hides it). Users only ever see the two launcher folders with
#     启动/关闭 inside. Mirrors install.sh so a .command install matches a .sh
#     install. ---------------------------------------------------------------
VISIBLE_DIR="$PERM_DIR/EasySkills维护工具"
mkdir -p "$VISIBLE_DIR/macOS" "$VISIBLE_DIR/Windows"
ln -sfn "../.engine/launchers/macOS-启动.command" "$VISIBLE_DIR/macOS/启动.command"
ln -sfn "../.engine/launchers/macOS-关闭.command" "$VISIBLE_DIR/macOS/关闭.command"
chmod +x "$VISIBLE_DIR/macOS/"*.command 2>/dev/null || true
cp "$CURRENT_DIR/EasySkills维护工具/Windows/启动.bat" "$VISIBLE_DIR/Windows/启动.bat" 2>/dev/null || true
cp "$CURRENT_DIR/EasySkills维护工具/Windows/关闭.bat" "$VISIBLE_DIR/Windows/关闭.bat" 2>/dev/null || true

bash "$PERM_DIR/EasySkills维护工具/.engine/watch.sh"

# --- Remove legacy _maintenance/_runtime dirs (pre-4.1.0 installs) ---
# The watcher was re-registered above against EasySkills维护工具/.engine; the old trees
# are no longer referenced and their runtime config was migrated earlier.
if [ -d "$PERM_DIR/_maintenance" ] && [ -f "$PERM_DIR/_maintenance/deploy.sh" ]; then
  echo "Removing legacy _maintenance/ directory (config already migrated)..."
  rm -rf "$PERM_DIR/_maintenance"
fi
if [ -d "$PERM_DIR/_runtime" ]; then
  echo "Removing legacy _runtime/ directory (gateway re-installed above)..."
  rm -rf "$PERM_DIR/_runtime"
fi

# --- Launch WebUI in background & pop up browser ---
if command -v python3 &>/dev/null; then
  echo "Launching WebUI Manager on port 6633..."
  bash "$PERM_DIR/EasySkills维护工具/.engine/deploy.sh" --webui
  echo "WebUI URL: http://127.0.0.1:6633"
else
  echo "Note: python3 not found — WebUI skipped. Install Python 3 to use the WebUI."
fi

echo "============================================="
echo "Press any key to close this window..."
read -n 1 -s
