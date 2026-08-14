#!/usr/bin/env bash
# EasySkills WebUI Launcher / 启动 EasySkills 控制面板
# Resolve the physical script location even when invoked through a symlink
# (EasySkills维护工具/macOS/启动.command -> ../.engine/launchers/macOS-启动.command).
# `dirname $0` alone does not resolve a symlink on the final path component,
# so follow the link chain explicitly (same approach as watch.sh).
_SRC="$0"
while [ -L "$_SRC" ]; do
  _DIR="$(cd "$(dirname "$_SRC")" && pwd)"
  _SRC="$(readlink "$_SRC")"
  [[ "$_SRC" != /* ]] && _SRC="$_DIR/$_SRC"
done
cd "$(cd "$(dirname "$_SRC")" && pwd -P)" || exit 1
cd "$(pwd)/.." || exit 1
unset _SRC _DIR

# Under launchd the PATH is minimal and /usr/bin/python3 may be a stale system
# Python too old to run webui.py (needs 3.10+ for `X | None` syntax). Prepend
# common modern-interpreter locations so Homebrew's et al. python3 wins.
# Preserve priority order even if some paths already exist later in PATH.
_PATH_PREFIX=""
for _p in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin" "$HOME/.pyenv/shims"; do
  [ -d "$_p" ] || continue
  _PATH_PREFIX="${_PATH_PREFIX}${_PATH_PREFIX:+:}$_p"
done
PATH="${_PATH_PREFIX}${_PATH_PREFIX:+:}${PATH:-}"
unset _PATH_PREFIX
export PATH

# Reuse the audited launcher instead of duplicating process discovery here.
# deploy.sh verifies both the exact script path and interpreter type before it
# stops a stale backend, so editors/greps that mention webui.py are never killed.
exec bash "$(pwd)/deploy.sh" --webui
