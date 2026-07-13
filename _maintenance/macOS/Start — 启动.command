#!/usr/bin/env bash
# EasySkills WebUI Launcher / 启动 EasySkills 控制面板
cd "$(dirname "$0")/.."

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
