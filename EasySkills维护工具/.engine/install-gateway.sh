#!/usr/bin/env bash

# Install the platform-specific EasySkills MCP Gateway binary. This helper is
# best-effort by design: Skills and Rules remain usable if the optional Gateway
# asset is temporarily unavailable.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CENTRAL_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNTIME_DIR="$CENTRAL_DIR/.runtime"
DEST="$RUNTIME_DIR/easyskills-mcp"
REPO="RunhuaHuang/EasySkills"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

VERSION="$(tr -d '[:space:]' < "$SCRIPT_DIR/.version" 2>/dev/null || true)"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]]; then
  echo "MCP Gateway: invalid or missing EasySkills version in $SCRIPT_DIR/.version." >&2
  exit 1
fi

case "$(uname -s)" in
  Darwin) GOOS="darwin" ;;
  Linux) GOOS="linux" ;;
  *) echo "MCP Gateway: unsupported operating system." >&2; exit 1 ;;
esac

case "$(uname -m)" in
  arm64|aarch64) GOARCH="arm64" ;;
  x86_64|amd64) GOARCH="amd64" ;;
  *) echo "MCP Gateway: unsupported CPU architecture." >&2; exit 1 ;;
esac

ASSET="easyskills-mcp-${GOOS}-${GOARCH}.tar.gz"
RELEASE_PATH="/${REPO}/releases/download/v${VERSION}"
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
# GitHub native by default, or one explicitly selected HTTPS mirror.
MIRROR_PREFIXES=("")
if [ -n "${EASYSKILLS_MIRROR:-}" ]; then
  case "$EASYSKILLS_MIRROR" in
    https://*) MIRROR_PREFIXES=("${EASYSKILLS_MIRROR%/}") ;;
    *)
      echo "Error: EASYSKILLS_MIRROR must be an explicit HTTPS URL prefix." >&2
      exit 1
      ;;
  esac
fi

install_candidate() {
  local candidate="$1"
  local candidate_version
  [ -x "$candidate" ] || chmod +x "$candidate" 2>/dev/null || return 1
  candidate_version="$("$candidate" version 2>/dev/null)" || return 1
  [ "$(printf '%s\n' "$candidate_version" | awk '{print $2}')" = "$VERSION" ] || return 1
  mkdir -p "$RUNTIME_DIR"
  local staged="$RUNTIME_DIR/.easyskills-mcp.new"
  cp "$candidate" "$staged" || return 1
  chmod 755 "$staged" || return 1
  if [ -f "$DEST" ]; then
    mv "$DEST" "$RUNTIME_DIR/.easyskills-mcp.previous" || return 1
  fi
  if ! mv "$staged" "$DEST"; then
    [ -f "$RUNTIME_DIR/.easyskills-mcp.previous" ] && mv "$RUNTIME_DIR/.easyskills-mcp.previous" "$DEST"
    return 1
  fi
  rm -f "$RUNTIME_DIR/.easyskills-mcp.previous"
  return 0
}

download_release() {
  command -v curl >/dev/null 2>&1 || return 1
  local expected actual entries candidate _prefix _base_url
  # Download the asset and checksum from the selected source. The archive is
  # bounded, verified, and streamed out only if it contains exactly the one
  # expected binary path.
  for _prefix in "${MIRROR_PREFIXES[@]}"; do
    # Empty prefix = GitHub native; mirror proxies prepend themselves to the
    # full github.com URL. Without this the empty prefix yields a host-less URL.
    if [ -z "$_prefix" ]; then
      _base_url="https://github.com${RELEASE_PATH}"
    else
      _base_url="${_prefix}/https://github.com${RELEASE_PATH}"
    fi
    rm -f "$TMP_DIR/$ASSET" "$TMP_DIR/checksums.txt"
    _asset_final_url="$(curl -fsSL --retry 2 --connect-timeout 15 --max-time 120 --max-filesize 52428800 -w '%{url_effective}' "$_base_url/$ASSET" -o "$TMP_DIR/$ASSET" 2>/dev/null)" || continue
    _checksum_final_url="$(curl -fsSL --retry 2 --connect-timeout 15 --max-time 120 --max-filesize 1048576 -w '%{url_effective}' "$_base_url/checksums.txt" -o "$TMP_DIR/checksums.txt" 2>/dev/null)" || continue
    if [ -z "$_prefix" ]; then
      is_trusted_github_final_url "$_asset_final_url" || continue
      is_trusted_github_final_url "$_checksum_final_url" || continue
    else
      [[ "$_asset_final_url" == https://* ]] || continue
      [[ "$_checksum_final_url" == https://* ]] || continue
    fi
    # Match the exact asset name first, then a wildcard ("*") line that covers
    # every file. (The former "$2 == "*" asset" was an awk string concatenation
    # that could never match and was effectively dead code.)
    expected="$(awk -v asset="$ASSET" '$2 == asset || $2 == ("*" asset) || $2 == "*" {print $1; exit}' "$TMP_DIR/checksums.txt")"
    [[ "$expected" =~ ^[0-9A-Fa-f]{64}$ ]] || continue
    if command -v shasum >/dev/null 2>&1; then
      actual="$(shasum -a 256 "$TMP_DIR/$ASSET" | awk '{print $1}')"
    elif command -v sha256sum >/dev/null 2>&1; then
      actual="$(sha256sum "$TMP_DIR/$ASSET" | awk '{print $1}')"
    else
      continue
    fi
    expected="$(printf '%s' "$expected" | tr 'A-F' 'a-f')"
    [ "$expected" = "$actual" ] || continue
    entries="$(tar -tzf "$TMP_DIR/$ASSET" 2>/dev/null)" || continue
    [ "$entries" = "easyskills-mcp" ] || continue
    candidate="$TMP_DIR/easyskills-mcp.downloaded"
    rm -f "$candidate"
    tar -xOzf "$TMP_DIR/$ASSET" easyskills-mcp > "$candidate" || continue
    install_candidate "$candidate" && return 0
  done
  return 1
}

build_from_source() {
  local source="${EASYSKILLS_GATEWAY_SOURCE:-}"
  [ -d "$source" ] || return 1
  command -v go >/dev/null 2>&1 || return 1
  local commit
  commit="$(git -C "$source" rev-parse --short HEAD 2>/dev/null || echo source)"
  (
    cd "$source" || exit 1
    CGO_ENABLED=0 go build -trimpath \
      -ldflags "-s -w -X main.version=$VERSION -X main.commit=$commit" \
      -o "$TMP_DIR/easyskills-mcp" ./cmd/easyskills-mcp
  ) || return 1
  install_candidate "$TMP_DIR/easyskills-mcp"
}

if download_release || build_from_source; then
  echo "MCP Gateway installed: $DEST"
  exit 0
fi

echo "MCP Gateway was not installed; Skills and Rules remain available. Retry from the WebUI after a release asset is available." >&2
exit 1
