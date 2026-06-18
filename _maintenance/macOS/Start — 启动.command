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

if ! command -v python3 &>/dev/null; then
  echo "Error: python3 is required. Please install Python 3 first."
  echo "错误: 需要 python3。请先安装 Python 3。"
  read -n 1 -s
  exit 1
fi
PYTHON_BIN="$(command -v python3)"
WEBUI_LABEL="com.easyskills.webui.manual"
launchctl remove "$WEBUI_LABEL" 2>/dev/null || true
pkill -f "$(pwd)/webui.py" 2>/dev/null || true

"$PYTHON_BIN" - "$PYTHON_BIN" "$(pwd)/webui.py" <<'PY' >/dev/null 2>&1
import os
import subprocess
import sys

python_bin, webui_script = sys.argv[1], sys.argv[2]
env = os.environ.copy()
# Equivalent to launching with EASYSKILLS_NO_BROWSER=1.
env["EASYSKILLS_NO_BROWSER"]="1"
subprocess.Popen(
    [python_bin, webui_script],
    stdin=subprocess.DEVNULL,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
    start_new_session=True,
    env=env,
)
PY

for _ in $(seq 1 40); do
  if command -v nc >/dev/null 2>&1 && nc -z -w1 127.0.0.1 6633 >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done

open "http://127.0.0.1:6633"
echo "EasySkills WebUI is launching in the background."
