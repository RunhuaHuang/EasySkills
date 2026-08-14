#!/usr/bin/env bash

# ==============================================================================
# Script: install.sh (macOS/Linux remote installer)
# Usage:  curl -fsSL https://raw.githubusercontent.com/RunhuaHuang/EasySkills/main/install.sh | bash
# ==============================================================================

set -e

REPO="RunhuaHuang/EasySkills"
DEFAULT_VERSION="4.1.1"
INSTALL_CHANNEL="${EASYSKILLS_CHANNEL:-stable}"
case "$INSTALL_CHANNEL" in
  stable)
    INSTALL_VERSION="${EASYSKILLS_VERSION:-$DEFAULT_VERSION}"
    if [[ ! "$INSTALL_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]]; then
      echo "Error: invalid EASYSKILLS_VERSION '$INSTALL_VERSION' (expected SemVer, e.g. 4.1.1)." >&2
      exit 1
    fi
    GIT_REF="v$INSTALL_VERSION"
    ARCHIVE_REF="tags/$GIT_REF"
    ;;
  edge)
    GIT_REF="main"
    ARCHIVE_REF="heads/main"
    ;;
  *)
    echo "Error: EASYSKILLS_CHANNEL must be 'stable' or 'edge'." >&2
    exit 1
    ;;
esac
PERM_DIR="$HOME/EasySkills"
TMP_DIR=$(mktemp -d)

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

installer_target_key() {
  local line="$1" path prefix candidate
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [[ -z "$line" || "$line" == \#* ]] && return 0
  if [[ "$line" == *"="* ]]; then
    prefix="${line%%=*}"
    candidate="${line#*=}"
    prefix="${prefix#"${prefix%%[![:space:]]*}"}"
    prefix="${prefix%"${prefix##*[![:space:]]}"}"
    candidate="${candidate#"${candidate%%[![:space:]]*}"}"
    candidate="${candidate%"${candidate##*[![:space:]]}"}"
    if [ -n "$prefix" ] && [[ "$candidate" == /* || "$candidate" == ~* || "$candidate" == .* || "$candidate" == */* || "$candidate" == *\\* || "$candidate" =~ ^[A-Za-z]:[\\/] ]] &&
       [[ "$prefix" != /* && "$prefix" != ~* && "$prefix" != .* && "$prefix" != */* && "$prefix" != *\\* && ! "$prefix" =~ ^[A-Za-z]:[\\/] ]]; then
      line="$candidate"
    fi
  fi
  path="$line"
  if [[ "$path" == "~"* ]]; then path="$HOME${path#\~}"; fi
  if [ -d "$path" ]; then
    # Fall back to the literal path if the directory exists but is not
    # enterable (no x permission). Without the fallback the subshell returns
    # non-zero and, under "set -e", the caller's `_legacy_key=$(...)` would
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

safe_extract_archive() {
  local archive_path="$1"
  local destination="$2"
  if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: Python 3 is required to validate and extract the fallback release archive safely." >&2
    return 1
  fi
  python3 - "$archive_path" "$destination" <<'PY'
import os
import posixpath
import sys
import tarfile

archive, destination = sys.argv[1:]
destination_real = os.path.realpath(destination)

with tarfile.open(archive, "r:gz") as tf:
    members = tf.getmembers()
    if len(members) > 10_000:
        raise ValueError("release archive contains too many entries")
    if sum(member.size for member in members if member.isfile()) > 512 * 1024 * 1024:
        raise ValueError("release archive exceeds the 512 MB extracted-size safety limit")

    seen = set()
    links = {}

    def normalize_name(name):
        if not name or "\x00" in name or "\\" in name:
            raise ValueError("release archive contains an invalid path: %r" % name)
        normalized = posixpath.normpath(name)
        if normalized in ("", "."):
            return ""
        if normalized == ".." or normalized.startswith("../") or normalized.startswith("/"):
            raise ValueError("release archive contains an unsafe path: %r" % name)
        return normalized

    for member in members:
        if not (member.isfile() or member.isdir() or member.issym() or member.islnk()):
            raise ValueError("release archive contains an unsupported entry: %r" % member.name)
        normalized = normalize_name(member.name)
        if not normalized or normalized in seen:
            raise ValueError("release archive contains a duplicate path: %r" % member.name)
        seen.add(normalized)
        if member.issym() or member.islnk():
            if not member.linkname or "\x00" in member.linkname or os.path.isabs(member.linkname):
                raise ValueError("release archive contains an unsafe link: %r" % member.name)
            links[normalized] = (member.linkname, member.issym())

    def resolve_virtual(path, follow_final=True):
        """Resolve archive-internal links without touching the host filesystem."""
        current = normalize_name(path)
        visited = set()
        for _ in range(64):
            parts = current.split("/") if current else []
            replaced = False
            for index in range(1, len(parts) + 1):
                prefix = "/".join(parts[:index])
                if prefix not in links or (index == len(parts) and not follow_final):
                    continue
                if prefix in visited:
                    raise ValueError("release archive contains a cyclic link: %r" % prefix)
                linkname, is_symlink = links[prefix]
                if is_symlink:
                    base = posixpath.dirname(prefix)
                    replacement = posixpath.normpath(posixpath.join(base, linkname))
                else:
                    # Tar hard-link names are archive-root-relative.
                    replacement = posixpath.normpath(linkname)
                if replacement == ".." or replacement.startswith("../") or replacement.startswith("/"):
                    raise ValueError("release archive contains an unsafe link: %r" % prefix)
                rest = "/".join(parts[index:])
                current = normalize_name(posixpath.join(replacement, rest))
                visited.add(prefix)
                replaced = True
                break
            if not replaced:
                return current
        raise ValueError("release archive contains an excessively deep link chain")

    # Resolve every member through the virtual archive graph. This catches the
    # important case where an apparently safe member path traverses a symlink
    # that is declared elsewhere in the archive and would escape at extraction.
    for normalized in seen:
        resolve_virtual(normalized)
    for member in members:
        try:
            tf.extract(member, destination, filter="data")
        except TypeError:
            tf.extract(member, destination)
PY
}

echo "============================================="
echo "EasySkills Remote Installer (macOS/Linux)"
echo "============================================="

# --- Download ---
# GitHub is the only implicit source. A third-party mirror changes the source
# trust boundary, so it is used only when the user explicitly selects one with
# EASYSKILLS_MIRROR=<https-url-prefix>.
echo "Downloading EasySkills ($INSTALL_CHANNEL: $GIT_REF)..."

is_trusted_github_final_url() {
  case "$1" in
    https://github.com/*|https://api.github.com/*|https://codeload.github.com/*|https://objects.githubusercontent.com/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Build the ordered list of base URLs to try for the archive tarball. Each entry
# is a prefix that, when prepended to the github.com path, yields a working
# download URL (mirror proxies work that way). GitHub native goes first.
ARCHIVE_PATH="/$REPO/archive/refs/$ARCHIVE_REF.tar.gz"
MIRROR_PREFIXES=("") # GitHub native (no prefix)
# A user-selected mirror replaces GitHub native for this run.
if [ -n "${EASYSKILLS_MIRROR:-}" ]; then
  case "$EASYSKILLS_MIRROR" in
    https://*) MIRROR_PREFIXES=("${EASYSKILLS_MIRROR%/}") ;;
    *)
      echo "Error: EASYSKILLS_MIRROR must be an explicit HTTPS URL prefix." >&2
      exit 1
      ;;
  esac
fi

SRC_DIR=""
# Preferred path: shallow git clone. Walk mirrors for this too, since git clone
# over a proxy needs the proxy to support the smart HTTP protocol — most do.
if command -v git &>/dev/null; then
  for _prefix in "${MIRROR_PREFIXES[@]}"; do
    # A failed clone can leave a partial destination behind, which would make
    # every later mirror fail immediately with "destination already exists".
    rm -rf "$TMP_DIR/EasySkills"
    if [ -z "$_prefix" ]; then
      _clone_url="https://github.com/$REPO.git"
    else
      _clone_url="${_prefix}/https://github.com/$REPO.git"
    fi
    if [ -z "$_prefix" ]; then
      # The implicit GitHub source must not follow a redirect to an arbitrary
      # host.  Explicit mirrors are already a user-selected trust boundary.
      if git -c http.followRedirects=false clone --depth 1 --branch "$GIT_REF" "$_clone_url" "$TMP_DIR/EasySkills" 2>/dev/null; then
        SRC_DIR="$TMP_DIR/EasySkills"
        break
      fi
    elif git clone --depth 1 --branch "$GIT_REF" "$_clone_url" "$TMP_DIR/EasySkills" 2>/dev/null; then
      SRC_DIR="$TMP_DIR/EasySkills"
      break
    fi
  done
fi
# Fallback path: download the archive tarball over curl, walking mirrors.
if [ -z "$SRC_DIR" ]; then
  for _prefix in "${MIRROR_PREFIXES[@]}"; do
    rm -f "$TMP_DIR/repo.tar.gz"
    while IFS= read -r _partial_dir; do
      rm -rf "$_partial_dir"
    done < <(find "$TMP_DIR" -mindepth 1 -maxdepth 1 -type d -name 'EasySkills-*' -print 2>/dev/null)
    # Empty prefix = GitHub native; mirror proxies prepend themselves to the
    # full github.com URL. Without this special case the empty prefix would
    # produce a host-less "/RunhuaHuang/..." URL that curl rejects.
    if [ -z "$_prefix" ]; then
      _url="https://github.com${ARCHIVE_PATH}"
    else
      _url="${_prefix}/https://github.com${ARCHIVE_PATH}"
    fi
    _effective_url="$(curl -fsSL --connect-timeout 15 --max-time 120 --max-filesize 104857600 -w '%{url_effective}' "$_url" -o "$TMP_DIR/repo.tar.gz" 2>/dev/null)" || _effective_url=""
    if [ -s "$TMP_DIR/repo.tar.gz" ] && { [ -n "$_prefix" ] || is_trusted_github_final_url "$_effective_url"; }; then
      if safe_extract_archive "$TMP_DIR/repo.tar.gz" "$TMP_DIR" 2>/dev/null; then
        _candidate_count=0
        _candidate_path=""
        while IFS= read -r -d '' _candidate_dir; do
          if [ -d "$_candidate_dir/EasySkills维护工具/.engine" ]; then
            _candidate_count=$((_candidate_count + 1))
            _candidate_path="$_candidate_dir"
          fi
        done < <(find "$TMP_DIR" -mindepth 1 -maxdepth 1 -type d -name 'EasySkills-*' -print0 2>/dev/null)
        [ "$_candidate_count" -eq 1 ] || continue
        SRC_DIR="$_candidate_path"
        break
      fi
    fi
  done
fi

# If every source failed, stop with a clear message instead of proceeding to the
# validation below with an empty SRC_DIR.
if [ -z "$SRC_DIR" ]; then
  echo "Error: could not download EasySkills from GitHub or the explicitly configured mirror." >&2
  echo "       Check your network, or explicitly trust a mirror with:" >&2
  echo "         EASYSKILLS_MIRROR=https://ghfast.top bash install.sh" >&2
  exit 1
fi

# Validate the selected source before touching any existing installation or
# legacy user configuration. Also reject a stale/wrong stable archive even if
# it happens to contain a superficially valid directory tree.
if [ ! -d "$SRC_DIR/EasySkills维护工具/.engine" ] || [ -z "$(ls -A "$SRC_DIR/EasySkills维护工具/.engine" 2>/dev/null)" ] || [ ! -f "$SRC_DIR/EasySkills维护工具/.engine/deploy.sh" ] || [ ! -f "$SRC_DIR/EasySkills维护工具/README_SYSTEM.md" ]; then
  echo "Error: downloaded source is incomplete or missing (network/GitHub failure?)." >&2
  echo "       Existing installation at $PERM_DIR was left untouched." >&2
  exit 1
fi
if [ "$INSTALL_CHANNEL" = "stable" ]; then
  SOURCE_VERSION=$(cat "$SRC_DIR/EasySkills维护工具/.engine/.version" 2>/dev/null || true)
  if [ "$SOURCE_VERSION" != "$INSTALL_VERSION" ]; then
    echo "Error: downloaded source version '$SOURCE_VERSION' does not match requested version '$INSTALL_VERSION'." >&2
    echo "       Existing installation at $PERM_DIR was left untouched." >&2
    exit 1
  fi
fi

# --- Install ---
mkdir -p "$PERM_DIR"

# Preserve old version for upgrade reporting
OLD_VERSION=""
if [ -f "$PERM_DIR/EasySkills维护工具/.engine/.version" ]; then
  OLD_VERSION=$(cat "$PERM_DIR/EasySkills维护工具/.engine/.version")
fi

# Preserve user custom-targets.txt before wiping EasySkills维护工具/.engine/
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
  grep -v -E '^[[:space:]]*(#|$)' "$LEGACY_ROOT_CT" > "$LEGACY_MERGE" 2>/dev/null || : > "$LEGACY_MERGE"
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

# Carry runtime state into the staged tree before the rename. Once the swap
# succeeds, the live engine is therefore complete even if a later, non-engine
# step (README copy, launcher creation, watcher registration) fails.
NEW_CUSTOM_FILE="$NEW_MAINT/custom-targets.txt"
NEW_DISABLED_FILE="$NEW_MAINT/disabled-targets.txt"
NEW_TOKEN_FILE="$NEW_MAINT/.easyskills-token"
if [ -f "$PRESERVE_DIR/custom-targets.txt" ]; then
  cp "$PRESERVE_DIR/custom-targets.txt" "$NEW_CUSTOM_FILE"
else
  rm -f "$NEW_CUSTOM_FILE"
fi
if [ -s "$LEGACY_MERGE" ]; then
  while IFS= read -r _line || [ -n "$_line" ]; do
    [ -z "$_line" ] && continue
    case "$_line" in \#*) continue;; esac
    _legacy_key=$(installer_target_key "$_line")
    if installer_file_has_target "$_legacy_key" "$NEW_CUSTOM_FILE"; then
      continue
    fi
    if [ -s "$NEW_CUSTOM_FILE" ] && [ -n "$(tail -c 1 "$NEW_CUSTOM_FILE" 2>/dev/null)" ]; then
      printf '\n' >> "$NEW_CUSTOM_FILE"
    fi
    printf '%s\n' "$_line" >> "$NEW_CUSTOM_FILE"
  done < "$LEGACY_MERGE"
fi
if [ -f "$PRESERVE_DIR/disabled-targets.txt" ]; then
  cp "$PRESERVE_DIR/disabled-targets.txt" "$NEW_DISABLED_FILE"
else
  rm -f "$NEW_DISABLED_FILE"
fi
if [ -f "$PRESERVE_DIR/.easyskills-token" ]; then
  cp "$PRESERVE_DIR/.easyskills-token" "$NEW_TOKEN_FILE"
  chmod 600 "$NEW_TOKEN_FILE"
else
  rm -f "$NEW_TOKEN_FILE"
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

# Reconcile a transaction directory left by an interrupted/failed prior
# upgrade. If the normal backup vanished, .prev may be the only recoverable
# snapshot and must be promoted rather than deleted.
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
    echo "Error: could not preserve the existing rollback backup. Existing install left untouched." >&2
    rm -rf "$NEW_MAINT"
    exit 1
  fi
  if ! mv "$OLD_MAINT" "$BACKUP_MAINT"; then
    echo "Error: could not rotate existing EasySkills维护工具/.engine. Existing install left untouched." >&2
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
cp "$SRC_DIR/EasySkills维护工具/README_SYSTEM.md" "$PERM_DIR/EasySkills维护工具/README_SYSTEM.md"
# Remove legacy SKILL.md left by older installations to avoid ambiguity
rm -f "$PERM_DIR/SKILL.md"
# The legacy root file is removed only after its entries are safely present in
# the live engine. A pre-swap failure therefore leaves the original untouched.
[ -f "$LEGACY_ROOT_CT" ] && rm -f "$LEGACY_ROOT_CT"

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
echo "Launching WebUI Manager on port 6633..."
if bash "$PERM_DIR/EasySkills维护工具/.engine/deploy.sh" --webui; then
  echo "WebUI URL: http://127.0.0.1:6633"
else
  echo "Note: WebUI skipped. Install Python 3.10+ and run deploy.sh --webui to enable it."
fi

# --- Verify watcher status ---
echo ""
case "$(uname -s)" in
  Darwin)
    if launchctl list 2>/dev/null | awk '$3 == "com.easyskills.watcher" { found=1 } END { exit found ? 0 : 1 }'; then
      echo "✅ Watcher is running"
    else
      echo "⚠️  Watcher not detected. Try: launchctl load ~/Library/LaunchAgents/com.easyskills.watcher.plist"
    fi
    ;;
  Linux)
    if systemctl --user is-active --quiet easyskills-watcher.path 2>/dev/null &&
       systemctl --user is-active --quiet easyskills-watcher.timer 2>/dev/null; then
      echo "✅ Watcher is running (systemd user units)"
    else
      echo "⚠️  Watcher not detected. Try: systemctl --user status easyskills-watcher.path easyskills-watcher.timer"
    fi
    ;;
  *)
    echo "⚠️  Watcher status could not be checked on $(uname -s)."
    ;;
esac

echo "============================================="
echo "EasySkills installed successfully!"
echo "Drop your custom skills into: $PERM_DIR"
echo "============================================="
