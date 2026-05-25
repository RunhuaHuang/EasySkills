#!/usr/bin/env bash
# EasySkills WebUI Launcher / 启动 EasySkills 控制面板
cd "$(dirname "$0")/.."
if ! command -v python3 &>/dev/null; then
  echo "Error: python3 is required. Please install Python 3 first."
  echo "错误: 需要 python3。请先安装 Python 3。"
  read -n 1 -s
  exit 1
fi
PYTHON_BIN="$(command -v python3)"
WEBUI_LABEL="com.easyskills.webui.manual"
launchctl remove "$WEBUI_LABEL" 2>/dev/null || true
launchctl submit -l "$WEBUI_LABEL" -- /usr/bin/env EASYSKILLS_NO_BROWSER=1 "$PYTHON_BIN" "$(pwd)/webui.py" 2>/dev/null || {
  EASYSKILLS_NO_BROWSER=1 "$PYTHON_BIN" "$(pwd)/webui.py" >/dev/null 2>&1 &
}
sleep 2
open "http://127.0.0.1:6633"
echo "EasySkills WebUI is launching in the background."
