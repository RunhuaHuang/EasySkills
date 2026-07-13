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
# Preserve the user's custom agent paths VERBATIM (cp, not cat/echo) so paths
# containing backslashes (Windows-style), glob chars (* ? [), or a leading '-'
# survive the round-trip unchanged. cat-into-a-var + echo-out mangles such
# paths and would silently break skill sync to those targets.
CUSTOM_FILE="$PERM_DIR/_maintenance/custom-targets.txt"
DISABLED_FILE="$PERM_DIR/_maintenance/disabled-targets.txt"
TOKEN_FILE="$PERM_DIR/_maintenance/.easyskills-token"
PRESERVE_DIR="$TMP_DIR/preserve"
mkdir -p "$PRESERVE_DIR"
[ -f "$CUSTOM_FILE" ] && cp "$CUSTOM_FILE" "$PRESERVE_DIR/custom-targets.txt"
[ -f "$DISABLED_FILE" ] && cp "$DISABLED_FILE" "$PRESERVE_DIR/disabled-targets.txt"
[ -f "$TOKEN_FILE" ] && cp "$TOKEN_FILE" "$PRESERVE_DIR/.easyskills-token"
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
# NOT destroy the existing install. SRC_DIR/_maintenance must exist & be non-empty.
if [ ! -d "$SRC_DIR/_maintenance" ] || [ -z "$(ls -A "$SRC_DIR/_maintenance" 2>/dev/null)" ] || [ ! -f "$SRC_DIR/README_SYSTEM.md" ]; then
  echo "Error: downloaded source is incomplete or missing (network/GitHub failure?)." >&2
  echo "       Existing installation at $PERM_DIR was left untouched." >&2
  exit 1
fi

# Atomic install: build the new _maintenance in a sibling temp dir, verify, then
# swap via rename. A transient copy failure no longer bricks the install (the
# previous "rm -rf then cp" wiped the working copy before validating the copy).
NEW_MAINT="$PERM_DIR/_maintenance.new"
rm -rf "$NEW_MAINT"
cp -R "$SRC_DIR/_maintenance" "$NEW_MAINT"
# Verify the copy actually produced a usable tree before swapping.
if [ ! -f "$NEW_MAINT/deploy.sh" ]; then
  echo "Error: copy of _maintenance failed (disk full? permissions?)." >&2
  rm -rf "$NEW_MAINT"
  echo "       Existing installation at $PERM_DIR was left untouched." >&2
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
    echo "Error: could not rotate existing _maintenance. Existing install left untouched." >&2
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
cp "$SRC_DIR/README_SYSTEM.md" "$PERM_DIR/README_SYSTEM.md"
# Remove legacy SKILL.md left by older installations to avoid ambiguity
rm -f "$PERM_DIR/SKILL.md"

# Restore user custom-targets.txt verbatim. Append any non-comment lines from
# the legacy root location (deduped against the verbatim copy) so nothing is
# lost, without round-tripping through a shell variable that mangles special
# path characters.
mkdir -p "$PERM_DIR/_maintenance"
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
if [ ! -f "$PERM_DIR/mcp/servers.json" ] && [ -f "$PERM_DIR/_maintenance/mcp-servers.template.json" ]; then
  cp "$PERM_DIR/_maintenance/mcp-servers.template.json" "$PERM_DIR/mcp/servers.json"
  chmod 600 "$PERM_DIR/mcp/servers.json" 2>/dev/null || true
fi

# Install the optional single-file MCP Gateway. A missing release asset does
# not prevent the existing Skills and Rules channels from installing.
if [ -f "$PERM_DIR/_maintenance/install-gateway.sh" ]; then
  chmod +x "$PERM_DIR/_maintenance/install-gateway.sh"
  EASYSKILLS_GATEWAY_SOURCE="$SRC_DIR/gateway" \
    bash "$PERM_DIR/_maintenance/install-gateway.sh" || true
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
  bash "$PERM_DIR/_maintenance/deploy.sh" --webui
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
