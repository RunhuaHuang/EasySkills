#!/usr/bin/env bash
# EasySkills Shutdown (macOS) / 关闭 EasySkills 后台服务
# Stops the WebUI backend on port 6633 and unloads the background watcher.
# Resolve the physical script location even when invoked through a symlink.
cd "$(cd "$(dirname "$0")" && pwd -P)/.." || exit 1

# --- Stop the WebUI backend (port 6633) --------------------------------
# Match precisely on this installation's webui.py so editors/greps that merely
# reference the file are never killed.
if command -v lsof &>/dev/null; then
  for pid in $(lsof -tiTCP:6633 -sTCP:LISTEN 2>/dev/null); do
    cmdline=$(ps -p "$pid" -o command= 2>/dev/null || true)
    comm=$(ps -p "$pid" -o comm= 2>/dev/null || true)
    base="${comm##*/}"
    if [[ "$cmdline" == *"$(pwd)/webui.py"* ]]; then
      case "$base" in [Pp]ython|[Pp]ython[0-9]*) kill "$pid" 2>/dev/null || true;; esac
    fi
  done
fi
for pid in $(pgrep -f "$(pwd)/webui.py" 2>/dev/null || true); do
  comm=$(ps -p "$pid" -o comm= 2>/dev/null || true)
  base="${comm##*/}"
  case "$base" in [Pp]ython|[Pp]ython[0-9]*) kill "$pid" 2>/dev/null || true;; esac
done

# --- Stop the background watcher (launchd) -----------------------------
bash "$(pwd)/deploy.sh" --unwatch >/dev/null 2>&1 || true

echo "EasySkills 后台服务已关闭 / EasySkills services stopped."
echo "WebUI: http://127.0.0.1:6633 (已停止 / stopped)"
echo "按任意键关闭此窗口 / Press any key to close this window..."
read -r -n 1 -s
