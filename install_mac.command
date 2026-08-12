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
PRESERVE_DIR=""

cleanup() {
  if [ -n "$PRESERVE_DIR" ] && [ -d "$PRESERVE_DIR" ]; then
    rm -rf "$PRESERVE_DIR"
  fi
}
trap cleanup EXIT

installer_target_key() {
  local line="$1" path
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [[ -z "$line" || "$line" == \#* ]] && return 0
  if [[ "$line" == *"="* ]]; then
    line="${line#*=}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
  fi
  path="$line"
  if [[ "$path" == "~"* ]]; then path="$HOME${path#\~}"; fi
  if [ -d "$path" ]; then
    # Fall back to the literal path if the directory exists but is not
    # enterable (no x permission). Without the fallback the subshell returns
    # non-zero and, under "set -eu", the caller's `_legacy_key=$(...)` would
    # silently abort the whole installer.
    (cd "$path" 2>/dev/null && pwd -P) || printf '%s' "$path"
  else
    printf '%s' "$path"
  fi
}

installer_file_has_target() {
  local key="$1" file="$2" line existing_key
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    existing_key=$(installer_target_key "$line")
    if [ -n "$key" ] && [ "$existing_key" = "$key" ]; then return 0; fi
  done < "$file"
  return 1
}

echo "============================================="
echo "Starting EasySkills Installation (macOS)..."
echo "============================================="

if [ "$CURRENT_DIR" != "$PERM_DIR" ]; then
  echo "Deploying to: $PERM_DIR"

  # Validate the local bundle before modifying any existing installation or
  # migrating user configuration.
  if [ ! -d "$CURRENT_DIR/EasySkills维护工具/.engine" ] || [ ! -f "$CURRENT_DIR/EasySkills维护工具/.engine/deploy.sh" ] || [ ! -f "$CURRENT_DIR/EasySkills维护工具/README_SYSTEM.md" ]; then
    echo "Error: source EasySkills维护工具/.engine/ missing or incomplete. Aborting; existing install untouched." >&2
    exit 1
  fi
  mkdir -p "$PERM_DIR"

  # --- Preserve user data before overwriting EasySkills维护工具/.engine/ ---
  OLD_VERSION=""
  if [ -f "$PERM_DIR/EasySkills维护工具/.engine/.version" ]; then
    OLD_VERSION=$(cat "$PERM_DIR/EasySkills维护工具/.engine/.version")
  fi

  # Preserve per-machine runtime files verbatim. The legacy root custom-target
  # file is kept in place until the staged engine contains all of its entries.
  PRESERVE_DIR=$(mktemp -d)
  CUSTOM_FILE="$PERM_DIR/EasySkills维护工具/.engine/custom-targets.txt"
  DISABLED_FILE="$PERM_DIR/EasySkills维护工具/.engine/disabled-targets.txt"
  TOKEN_FILE="$PERM_DIR/EasySkills维护工具/.engine/.easyskills-token"
  [ -f "$CUSTOM_FILE" ] && cp "$CUSTOM_FILE" "$PRESERVE_DIR/custom-targets.txt"
  [ -f "$DISABLED_FILE" ] && cp "$DISABLED_FILE" "$PRESERVE_DIR/disabled-targets.txt"
  [ -f "$TOKEN_FILE" ] && cp "$TOKEN_FILE" "$PRESERVE_DIR/.easyskills-token"
  # Migrate user config from a legacy _maintenance install (pre-4.1.0 directory
  # rename) when the new paths are absent.
  if [ ! -f "$PRESERVE_DIR/custom-targets.txt" ] && [ -f "$PERM_DIR/_maintenance/custom-targets.txt" ]; then
    cp "$PERM_DIR/_maintenance/custom-targets.txt" "$PRESERVE_DIR/custom-targets.txt"
  fi
  if [ ! -f "$PRESERVE_DIR/disabled-targets.txt" ] && [ -f "$PERM_DIR/_maintenance/disabled-targets.txt" ]; then
    cp "$PERM_DIR/_maintenance/disabled-targets.txt" "$PRESERVE_DIR/disabled-targets.txt"
  fi
  if [ ! -f "$PRESERVE_DIR/.easyskills-token" ] && [ -f "$PERM_DIR/_maintenance/.easyskills-token" ]; then
    cp "$PERM_DIR/_maintenance/.easyskills-token" "$PRESERVE_DIR/.easyskills-token"
  fi
  LEGACY_ROOT_CT="$PERM_DIR/custom-targets.txt"
  LEGACY_MERGE="$PRESERVE_DIR/custom-targets.legacy.txt"
  : > "$LEGACY_MERGE"
  if [ -f "$LEGACY_ROOT_CT" ]; then
    grep -v -E '^[[:space:]]*(#|$)' "$LEGACY_ROOT_CT" > "$LEGACY_MERGE" 2>/dev/null || : > "$LEGACY_MERGE"
  fi

  # --- Atomic install of EasySkills维护工具/.engine/ ---
  # Build into a sibling temp dir, verify, then swap via atomic rename — avoids
  # the "rm -rf then cp" footgun where a failed cp bricks the install.
  NEW_MAINT="$PERM_DIR/EasySkills维护工具/.engine.new"
  rm -rf "$NEW_MAINT"
  # The parent EasySkills维护工具/ may not exist yet on a fresh install.
  mkdir -p "$PERM_DIR/EasySkills维护工具"
  cp -R "$CURRENT_DIR/EasySkills维护工具/.engine" "$NEW_MAINT"
  if [ ! -f "$NEW_MAINT/deploy.sh" ]; then
    echo "Error: copy of EasySkills维护工具/.engine/ failed. Aborting; existing install untouched." >&2
    rm -rf "$NEW_MAINT"
    exit 1
  fi

  # Stage all runtime state before the swap so the newly live engine is never
  # missing custom paths, disabled targets, or its authentication token.
  NEW_CUSTOM_FILE="$NEW_MAINT/custom-targets.txt"
  if [ -f "$PRESERVE_DIR/custom-targets.txt" ]; then
    cp "$PRESERVE_DIR/custom-targets.txt" "$NEW_CUSTOM_FILE"
  else
    rm -f "$NEW_CUSTOM_FILE"
  fi
  if [ -s "$LEGACY_MERGE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      [ -z "$line" ] && continue
      case "$line" in \#*) continue;; esac
      _legacy_key=$(installer_target_key "$line")
      if installer_file_has_target "$_legacy_key" "$NEW_CUSTOM_FILE"; then
        continue
      fi
      if [ -s "$NEW_CUSTOM_FILE" ] && [ -n "$(tail -c 1 "$NEW_CUSTOM_FILE" 2>/dev/null)" ]; then
        printf '\n' >> "$NEW_CUSTOM_FILE"
      fi
      printf '%s\n' "$line" >> "$NEW_CUSTOM_FILE"
    done < "$LEGACY_MERGE"
  fi
  if [ -f "$PRESERVE_DIR/disabled-targets.txt" ]; then
    cp "$PRESERVE_DIR/disabled-targets.txt" "$NEW_MAINT/disabled-targets.txt"
  else
    rm -f "$NEW_MAINT/disabled-targets.txt"
  fi
  if [ -f "$PRESERVE_DIR/.easyskills-token" ]; then
    cp "$PRESERVE_DIR/.easyskills-token" "$NEW_MAINT/.easyskills-token"
    chmod 600 "$NEW_MAINT/.easyskills-token"
  else
    rm -f "$NEW_MAINT/.easyskills-token"
  fi
  # Swap with rollback: current -> .bak, new -> current. Avoid a window where a
  # failed mv leaves no usable EasySkills维护工具/.engine at all.
  OLD_MAINT="$PERM_DIR/EasySkills维护工具/.engine"
  BACKUP_MAINT="$PERM_DIR/.maintenance-bak"
  PREV_BACKUP="$PERM_DIR/.maintenance-bak.prev"

  restore_previous_backup() {
    [ -d "$PREV_BACKUP" ] || return 0
    if [ -d "$BACKUP_MAINT" ]; then
      rm -rf "$PREV_BACKUP"
      return 0
    fi
    # A failed restore must leave PREV_BACKUP untouched: it may be the user's
    # last recoverable engine snapshot after a partial swap.
    if ! mv "$PREV_BACKUP" "$BACKUP_MAINT"; then
      echo "Warning: previous backup could not be restored; preserved at $PREV_BACKUP" >&2
      return 1
    fi
    return 0
  }

  if [ -d "$PREV_BACKUP" ]; then
    if [ -d "$BACKUP_MAINT" ]; then
      rm -rf "$PREV_BACKUP"
    elif ! mv "$PREV_BACKUP" "$BACKUP_MAINT"; then
      echo "Error: previous recoverable backup is preserved at $PREV_BACKUP but could not be reconciled." >&2
      rm -rf "$NEW_MAINT"
      exit 1
    fi
  fi
  if [ -d "$OLD_MAINT" ]; then
    if [ -d "$BACKUP_MAINT" ] && ! mv "$BACKUP_MAINT" "$PREV_BACKUP"; then
      echo "Error: could not preserve the existing rollback backup. Existing install untouched." >&2
      rm -rf "$NEW_MAINT"
      exit 1
    fi
    if ! mv "$OLD_MAINT" "$BACKUP_MAINT"; then
      echo "Error: could not rotate existing EasySkills维护工具/.engine. Existing install untouched." >&2
      restore_previous_backup || true
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
    restore_previous_backup || true
    exit 1
  fi
  rm -rf "$PREV_BACKUP"
  cp "$CURRENT_DIR/EasySkills维护工具/README_SYSTEM.md" "$PERM_DIR/EasySkills维护工具/README_SYSTEM.md"
  rm -f "$PERM_DIR/SKILL.md"
  [ -f "$LEGACY_ROOT_CT" ] && rm -f "$LEGACY_ROOT_CT"

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
echo "Launching WebUI Manager on port 6633..."
if bash "$PERM_DIR/EasySkills维护工具/.engine/deploy.sh" --webui; then
  echo "WebUI URL: http://127.0.0.1:6633"
else
  echo "Note: WebUI skipped. Install Python 3.10+ and run deploy.sh --webui to enable it."
fi

echo "============================================="
echo "Press any key to close this window..."
read -r -n 1 -s
