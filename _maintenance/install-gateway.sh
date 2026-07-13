#!/usr/bin/env bash

# Install the platform-specific EasySkills MCP Gateway binary. This helper is
# best-effort by design: Skills and Rules remain usable if the optional Gateway
# asset is temporarily unavailable.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CENTRAL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNTIME_DIR="$CENTRAL_DIR/_runtime"
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
BASE_URL="https://github.com/${REPO}/releases/latest/download"

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
  curl -fsSL --retry 2 --connect-timeout 15 "$BASE_URL/$ASSET" -o "$TMP_DIR/$ASSET" || return 1
  curl -fsSL --retry 2 --connect-timeout 15 "$BASE_URL/checksums.txt" -o "$TMP_DIR/checksums.txt" || return 1
  local expected actual
  expected="$(awk -v asset="$ASSET" '$2 == asset || $2 == "*" asset {print $1; exit}' "$TMP_DIR/checksums.txt")"
  [ -n "$expected" ] || return 1
  if command -v shasum >/dev/null 2>&1; then
    actual="$(shasum -a 256 "$TMP_DIR/$ASSET" | awk '{print $1}')"
  elif command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$TMP_DIR/$ASSET" | awk '{print $1}')"
  else
    return 1
  fi
  [ "$expected" = "$actual" ] || return 1
  mkdir -p "$TMP_DIR/extracted"
  tar -xzf "$TMP_DIR/$ASSET" -C "$TMP_DIR/extracted" || return 1
  install_candidate "$TMP_DIR/extracted/easyskills-mcp"
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
