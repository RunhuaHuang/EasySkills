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
RELEASE_PATH="/${REPO}/releases/latest/download"
# GitHub native first; then China-friendly mirror proxies (same fallback list
# as install.sh). EASYSKILLS_MIRROR pins a single mirror if set.
MIRROR_PREFIXES=("" "https://ghfast.top" "https://gh-proxy.com" "https://github.moeyy.xyz")
if [ -n "${EASYSKILLS_MIRROR:-}" ]; then
  MIRROR_PREFIXES=("$EASYSKILLS_MIRROR")
fi

install_candidate() {
  local candidate="$1"
  [ -x "$candidate" ] || chmod +x "$candidate" 2>/dev/null || return 1
  "$candidate" version >/dev/null 2>&1 || return 1
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
  local expected actual _prefix _base_url
  # Walk mirrors: download asset + checksums from the same source. Both must
  # succeed and the checksum must verify before we accept a mirror.
  for _prefix in "${MIRROR_PREFIXES[@]}"; do
    # Empty prefix = GitHub native; mirror proxies prepend themselves to the
    # full github.com URL. Without this the empty prefix yields a host-less URL.
    if [ -z "$_prefix" ]; then
      _base_url="https://github.com${RELEASE_PATH}"
    else
      _base_url="${_prefix}/https://github.com${RELEASE_PATH}"
    fi
    rm -f "$TMP_DIR/$ASSET" "$TMP_DIR/checksums.txt"
    curl -fsSL --retry 2 --connect-timeout 15 "$_base_url/$ASSET" -o "$TMP_DIR/$ASSET" || continue
    curl -fsSL --retry 2 --connect-timeout 15 "$_base_url/checksums.txt" -o "$TMP_DIR/checksums.txt" || continue
    # Match the exact asset name first, then a wildcard ("*") line that covers
    # every file. (The former "$2 == "*" asset" was an awk string concatenation
    # that could never match and was effectively dead code.)
    expected="$(awk -v asset="$ASSET" '$2 == asset || $2 == "*" {print $1; exit}' "$TMP_DIR/checksums.txt")"
    [ -n "$expected" ] || continue
    if command -v shasum >/dev/null 2>&1; then
      actual="$(shasum -a 256 "$TMP_DIR/$ASSET" | awk '{print $1}')"
    elif command -v sha256sum >/dev/null 2>&1; then
      actual="$(sha256sum "$TMP_DIR/$ASSET" | awk '{print $1}')"
    else
      continue
    fi
    [ "$expected" = "$actual" ] || continue
    mkdir -p "$TMP_DIR/extracted"
    tar -xzf "$TMP_DIR/$ASSET" -C "$TMP_DIR/extracted" || continue
    install_candidate "$TMP_DIR/extracted/easyskills-mcp" && return 0
  done
  return 1
}

build_from_source() {
  local source="${EASYSKILLS_GATEWAY_SOURCE:-}"
  [ -d "$source" ] || return 1
  command -v go >/dev/null 2>&1 || return 1
  local version commit
  version="$(tr -d '[:space:]' < "$SCRIPT_DIR/.version" 2>/dev/null || true)"
  [ -n "$version" ] || version="dev"
  commit="$(git -C "$source" rev-parse --short HEAD 2>/dev/null || echo source)"
  (
    cd "$source" || exit 1
    CGO_ENABLED=0 go build -trimpath \
      -ldflags "-s -w -X main.version=$version -X main.commit=$commit" \
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
