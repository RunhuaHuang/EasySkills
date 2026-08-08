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
# Multi-source with auto-fallback: GitHub is tried first (fastest for overseas
# users); on failure/timeout we walk a list of China-friendly mirrors so users
# behind the GFW aren't blocked. A mirror can be pinned with
# EASYSKILLS_MIRROR=<url-prefix> (the prefix is prepended to the github.com URL).
# Mirror URLs change frequently, so we probe rather than trust any single host.
echo "Downloading EasySkills..."

# Build the ordered list of base URLs to try for the archive tarball. Each entry
# is a prefix that, when prepended to the github.com path, yields a working
# download URL (mirror proxies work that way). GitHub native goes first.
ARCHIVE_PATH="/$REPO/archive/refs/heads/$BRANCH.tar.gz"
MIRROR_PREFIXES=(
  ""                                                  # GitHub native (no prefix)
  "https://ghfast.top"                                # ghfast mirror proxy
  "https://gh-proxy.com"                              # gh-proxy mirror proxy
  "https://github.moeyy.xyz"                          # moeyy mirror proxy
)
# A user-pinned mirror always wins (replaces the whole list).
if [ -n "${EASYSKILLS_MIRROR:-}" ]; then
  MIRROR_PREFIXES=("$EASYSKILLS_MIRROR")
fi

SRC_DIR=""
# Preferred path: shallow git clone. Walk mirrors for this too, since git clone
# over a proxy needs the proxy to support the smart HTTP protocol — most do.
if command -v git &>/dev/null; then
  for _prefix in "${MIRROR_PREFIXES[@]}"; do
    if [ -z "$_prefix" ]; then
      _clone_url="https://github.com/$REPO.git"
    else
      _clone_url="${_prefix}/https://github.com/$REPO.git"
    fi
    if git clone --depth 1 --branch "$BRANCH" "$_clone_url" "$TMP_DIR/EasySkills" 2>/dev/null; then
      SRC_DIR="$TMP_DIR/EasySkills"
      break
    fi
  done
fi
# Fallback path: download the archive tarball over curl, walking mirrors.
if [ -z "$SRC_DIR" ]; then
  for _prefix in "${MIRROR_PREFIXES[@]}"; do
    # Empty prefix = GitHub native; mirror proxies prepend themselves to the
    # full github.com URL. Without this special case the empty prefix would
    # produce a host-less "/RunhuaHuang/..." URL that curl rejects.
    if [ -z "$_prefix" ]; then
      _url="https://github.com${ARCHIVE_PATH}"
    else
      _url="${_prefix}/https://github.com${ARCHIVE_PATH}"
    fi
    if curl -fsSL --connect-timeout 15 "$_url" -o "$TMP_DIR/repo.tar.gz" 2>/dev/null; then
      if tar -xzf "$TMP_DIR/repo.tar.gz" -C "$TMP_DIR" 2>/dev/null; then
        SRC_DIR="$TMP_DIR/EasySkills-$BRANCH"
        break
      fi
    fi
  done
fi

# If every source failed, stop with a clear message instead of proceeding to the
# validation below with an empty SRC_DIR.
if [ -z "$SRC_DIR" ]; then
  echo "Error: could not download EasySkills from GitHub or any mirror." >&2
  echo "       Check your network, or pin a mirror with:" >&2
  echo "         EASYSKILLS_MIRROR=https://ghfast.top bash install.sh" >&2
  exit 1
fi

# --- Install ---
mkdir -p "$PERM_DIR"

# Preserve old version for upgrade reporting
OLD_VERSION=""
if [ -f "$PERM_DIR/EasySkills维护工具/.engine/.version" ]; then
  OLD_VERSION=$(cat "$PERM_DIR/EasySkills维护工具/.engine/.version")
fi

# Preserve user custom-targets.txt before wiping EasySkills维护工具/.engine/
CUSTOM_BACKUP=""
# Preserve the user's custom agent paths VERBATIM (cp, not cat/echo) so paths
# containing backslashes (Windows-style), glob chars (* ? [), or a leading '-'
# survive the round-trip unchanged. cat-into-a-var + echo-out mangles such
# paths and would silently break skill sync to those targets.
CUSTOM_FILE="$PERM_DIR/EasySkills维护工具/.engine/custom-targets.txt"
DISABLED_FILE="$PERM_DIR/EasySkills维护工具/.engine/disabled-targets.txt"
TOKEN_FILE="$PERM_DIR/EasySkills维护工具/.engine/.easyskills-token"
PRESERVE_DIR="$TMP_DIR/preserve"
mkdir -p "$PRESERVE_DIR"
[ -f "$CUSTOM_FILE" ] && cp "$CUSTOM_FILE" "$PRESERVE_DIR/custom-targets.txt"
[ -f "$DISABLED_FILE" ] && cp "$DISABLED_FILE" "$PRESERVE_DIR/disabled-targets.txt"
[ -f "$TOKEN_FILE" ] && cp "$TOKEN_FILE" "$PRESERVE_DIR/.easyskills-token"
# Migrate user config from a legacy _maintenance install (pre-4.1.0 directory
# rename). New installs read the new paths above; older installs keep their
# runtime files under _maintenance/, so copy them if the new paths are absent.
LEGACY_MAINT="$PERM_DIR/_maintenance"
if [ ! -f "$PRESERVE_DIR/custom-targets.txt" ] && [ -f "$LEGACY_MAINT/custom-targets.txt" ]; then
  cp "$LEGACY_MAINT/custom-targets.txt" "$PRESERVE_DIR/custom-targets.txt"
fi
if [ ! -f "$PRESERVE_DIR/disabled-targets.txt" ] && [ -f "$LEGACY_MAINT/disabled-targets.txt" ]; then
  cp "$LEGACY_MAINT/disabled-targets.txt" "$PRESERVE_DIR/disabled-targets.txt"
fi
if [ ! -f "$PRESERVE_DIR/.easyskills-token" ] && [ -f "$LEGACY_MAINT/.easyskills-token" ]; then
  cp "$LEGACY_MAINT/.easyskills-token" "$PRESERVE_DIR/.easyskills-token"
fi
# Also migrate from legacy root location (older installs). Capture non-comment
# lines into a separate file so the verbatim copy above is not disturbed.
LEGACY_ROOT_CT="$PERM_DIR/custom-targets.txt"
LEGACY_MERGE="$PRESERVE_DIR/custom-targets.legacy.txt"
: > "$LEGACY_MERGE"
if [ -f "$LEGACY_ROOT_CT" ]; then
  grep -v -E '^\s*(#|$)' "$LEGACY_ROOT_CT" > "$LEGACY_MERGE" 2>/dev/null || : > "$LEGACY_MERGE"
  rm -f "$LEGACY_ROOT_CT"
fi

# Validate the download before touching anything — a failed clone/extract must
# NOT destroy the existing install. SRC_DIR/EasySkills维护工具/.engine must exist & be non-empty.
if [ ! -d "$SRC_DIR/EasySkills维护工具/.engine" ] || [ -z "$(ls -A "$SRC_DIR/EasySkills维护工具/.engine" 2>/dev/null)" ] || [ ! -f "$SRC_DIR/EasySkills维护工具/README_SYSTEM.md" ]; then
  echo "Error: downloaded source is incomplete or missing (network/GitHub failure?)." >&2
  echo "       Existing installation at $PERM_DIR was left untouched." >&2
  exit 1
fi

# Atomic install: build the new EasySkills维护工具/.engine in a sibling temp dir, verify, then
# swap via rename. A transient copy failure no longer bricks the install (the
# previous "rm -rf then cp" wiped the working copy before validating the copy).
NEW_MAINT="$PERM_DIR/EasySkills维护工具/.engine.new"
rm -rf "$NEW_MAINT"
# The parent EasySkills维护工具/ may not exist yet on a fresh install; cp -R into a
# nested target needs the parent to exist, so create it first.
mkdir -p "$PERM_DIR/EasySkills维护工具"
cp -R "$SRC_DIR/EasySkills维护工具/.engine" "$NEW_MAINT"
# Verify the copy actually produced a usable tree before swapping.
if [ ! -f "$NEW_MAINT/deploy.sh" ]; then
  echo "Error: copy of EasySkills维护工具/.engine failed (disk full? permissions?)." >&2
  rm -rf "$NEW_MAINT"
  echo "       Existing installation at $PERM_DIR was left untouched." >&2
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
    echo "Error: could not rotate existing EasySkills维护工具/.engine. Existing install left untouched." >&2
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
cp "$SRC_DIR/EasySkills维护工具/README_SYSTEM.md" "$PERM_DIR/EasySkills维护工具/README_SYSTEM.md"
# Remove legacy SKILL.md left by older installations to avoid ambiguity
rm -f "$PERM_DIR/SKILL.md"

# Restore user custom-targets.txt verbatim. Append any non-comment lines from
# the legacy root location (deduped against the verbatim copy) so nothing is
# lost, without round-tripping through a shell variable that mangles special
# path characters.
mkdir -p "$PERM_DIR/EasySkills维护工具/.engine"
if [ -f "$PRESERVE_DIR/custom-targets.txt" ]; then
  cp "$PRESERVE_DIR/custom-targets.txt" "$CUSTOM_FILE"
else
  rm -f "$CUSTOM_FILE"
fi
if [ -s "$LEGACY_MERGE" ]; then
  # Append legacy non-comment lines that are not already present (normalize for
  # comparison only; write the original line verbatim).
  while IFS= read -r _line; do
    [ -z "$_line" ] && continue
    case "$_line" in \#*) continue;; esac
    if [ -f "$CUSTOM_FILE" ]; then
      grep -Fxq -- "$_line" "$CUSTOM_FILE" 2>/dev/null && continue
      printf '%s\n' "$_line" >> "$CUSTOM_FILE"
    else
      printf '%s\n' "$_line" >> "$CUSTOM_FILE"
    fi
  done < "$LEGACY_MERGE"
fi
# Restore other preserved runtime files
if [ -f "$PRESERVE_DIR/disabled-targets.txt" ]; then
  cp "$PRESERVE_DIR/disabled-targets.txt" "$DISABLED_FILE"
fi
if [ -f "$PRESERVE_DIR/.easyskills-token" ]; then
  cp "$PRESERVE_DIR/.easyskills-token" "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
fi

# Initialize the user-owned MCP JSON once; upgrades never overwrite it.
mkdir -p "$PERM_DIR/mcp"
chmod 700 "$PERM_DIR/mcp" 2>/dev/null || true
if [ ! -f "$PERM_DIR/mcp/servers.json" ] && [ -f "$PERM_DIR/EasySkills维护工具/.engine/mcp-servers.template.json" ]; then
  cp "$PERM_DIR/EasySkills维护工具/.engine/mcp-servers.template.json" "$PERM_DIR/mcp/servers.json"
  chmod 600 "$PERM_DIR/mcp/servers.json" 2>/dev/null || true
fi

# Install the optional single-file MCP Gateway. A missing release asset does
# not prevent the existing Skills and Rules channels from installing.
if [ -f "$PERM_DIR/EasySkills维护工具/.engine/install-gateway.sh" ]; then
  chmod +x "$PERM_DIR/EasySkills维护工具/.engine/install-gateway.sh"
  EASYSKILLS_GATEWAY_SOURCE="$SRC_DIR/gateway" \
    bash "$PERM_DIR/EasySkills维护工具/.engine/install-gateway.sh" || true
fi

# Version reporting
NEW_VERSION=$(cat "$PERM_DIR/EasySkills维护工具/.engine/.version" 2>/dev/null || echo "unknown")
if [ -n "$OLD_VERSION" ] && [ "$OLD_VERSION" != "$NEW_VERSION" ]; then
  echo "Upgraded: $OLD_VERSION -> $NEW_VERSION"
else
  echo "Installed version: $NEW_VERSION"
fi

# --- Activate ---
chmod +x "$PERM_DIR/EasySkills维护工具/.engine/"*.sh
chmod +x "$PERM_DIR/EasySkills维护工具/.engine/launchers/"*.command 2>/dev/null || true

# --- Create the visible user entry: EasySkills维护工具/ with macOS/Windows
#     subfolders that link back into the hidden .engine directory (dot-prefixed,
#     so Finder hides it). Users only ever see the two launcher folders with
#     启动/关闭 inside. ------------------------------------------------------
VISIBLE_DIR="$PERM_DIR/EasySkills维护工具"
mkdir -p "$VISIBLE_DIR/macOS" "$VISIBLE_DIR/Windows"
ENGINE_LAUNCHERS="$VISIBLE_DIR/.engine/launchers"
ln -sfn "../.engine/launchers/macOS-启动.command" "$VISIBLE_DIR/macOS/启动.command"
ln -sfn "../.engine/launchers/macOS-关闭.command" "$VISIBLE_DIR/macOS/关闭.command"
chmod +x "$VISIBLE_DIR/macOS/"*.command 2>/dev/null || true
cp "$SRC_DIR/EasySkills维护工具/Windows/启动.bat" "$VISIBLE_DIR/Windows/启动.bat" 2>/dev/null || true
cp "$SRC_DIR/EasySkills维护工具/Windows/关闭.bat" "$VISIBLE_DIR/Windows/关闭.bat" 2>/dev/null || true

bash "$PERM_DIR/EasySkills维护工具/.engine/watch.sh"

# --- Remove legacy _maintenance directory (pre-4.1.0 installs) ---
# The watcher above has already been re-registered against EasySkills维护工具/.engine,
# so the old tree is no longer referenced. Verify it is really the old EasySkills
# maintenance dir before deleting; its runtime config was migrated above.
if [ -d "$PERM_DIR/_maintenance" ] && [ -f "$PERM_DIR/_maintenance/deploy.sh" ]; then
  echo "Removing legacy _maintenance/ directory (config already migrated)..."
  rm -rf "$PERM_DIR/_maintenance"
fi
# Also clean the legacy MCP runtime dir; the gateway installer re-creates it.
if [ -d "$PERM_DIR/_runtime" ]; then
  echo "Removing legacy _runtime/ directory (gateway will be re-installed)..."
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

# --- Verify watcher status ---
echo ""
if launchctl list 2>/dev/null | awk '$3 == "com.easyskills.watcher" { found=1 } END { exit found ? 0 : 1 }'; then
  echo "✅ Watcher is running"
else
  echo "⚠️  Watcher not detected. Try: launchctl load ~/Library/LaunchAgents/com.easyskills.watcher.plist"
fi

echo "============================================="
echo "EasySkills installed successfully!"
echo "Drop your custom skills into: $PERM_DIR"
echo "============================================="
