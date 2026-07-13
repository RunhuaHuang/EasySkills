#!/usr/bin/env bash
# EasySkills Uninstaller (macOS) / 卸载 EasySkills
# User skills live under ~/EasySkills, so removal is recoverable via Trash.

echo "============================================="
echo "Uninstalling EasySkills / 正在卸载 EasySkills..."
echo "============================================="

LABEL="com.easyskills.watcher"
UID_VAL=$(id -u)
SERVICE_TARGET="gui/$UID_VAL/$LABEL"
PLIST_PATH="$HOME/Library/LaunchAgents/com.easyskills.watcher.plist"
INSTALL_DIR="$HOME/EasySkills"
uninstall_ok=true

if [ -f "$PLIST_PATH" ]; then
  launchctl bootout "$SERVICE_TARGET" 2>/dev/null || launchctl unload "$PLIST_PATH" 2>/dev/null
  rm -f "$PLIST_PATH"
fi

# Stop WebUI jobs and only processes that are executing this installation.
for webui_label in com.easyskills.webui com.easyskills.webui.manual; do
  launchctl remove "$webui_label" 2>/dev/null || true
done
for script_name in webui-service.sh webui.py; do
  pattern="[E]asySkills/_maintenance/$script_name"
  pids=$(pgrep -f "$pattern" 2>/dev/null || true)
  if [ -n "$pids" ]; then
    echo "$pids" | while read -r p; do
      comm=$(ps -p "$p" -o comm= 2>/dev/null || true)
      cmdline=$(ps -p "$p" -o command= 2>/dev/null || true)
      base="${comm##*/}"
      [[ "$cmdline" == *"$INSTALL_DIR/_maintenance/$script_name"* ]] || continue
      case "$base" in bash|sh|python|python[0-9]*) kill "$p" 2>/dev/null || true;; esac
    done
  fi
done

move_to_trash() {
  local target="$1"
  [ -e "$target" ] || return 0
  if command -v osascript >/dev/null 2>&1; then
    if osascript - "$target" >/dev/null 2>&1 <<'APPLESCRIPT'
on run argv
  tell application "Finder" to delete POSIX file (item 1 of argv)
end run
APPLESCRIPT
    then
      echo "Moved to Trash: $target"
      return 0
    fi
  fi
  echo "Warning: could not move to Trash. Please manually delete: $target" >&2
  return 1
}

if [ -d "$INSTALL_DIR/_maintenance" ]; then
  if ! bash "$INSTALL_DIR/_maintenance/deploy.sh" --cleanup; then
    echo "Warning: some Agent links may remain; the installation was not deleted." >&2
    uninstall_ok=false
  elif move_to_trash "$INSTALL_DIR"; then
    echo "Successfully cleaned Agent links and moved ~/EasySkills to Trash."
    echo "已清理 Agent 软链接，并将 ~/EasySkills 移至废纸篓。"
  else
    uninstall_ok=false
  fi
fi

echo "============================================="
if [ "$uninstall_ok" = true ]; then
  echo "Uninstallation complete. / 卸载完成。"
else
  echo "Uninstallation incomplete; no user data was destroyed. / 卸载未完成，未破坏用户数据。"
fi
echo "Press any key to close / 按任意键关闭..."
read -n 1 -s
[ "$uninstall_ok" = true ] || exit 1
