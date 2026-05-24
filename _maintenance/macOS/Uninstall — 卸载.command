#!/usr/bin/env bash
# EasySkills Uninstaller (macOS) / 卸载 EasySkills

echo "============================================="
echo "Uninstalling EasySkills / 正在卸载 EasySkills..."
echo "============================================="

LABEL="com.easyskills.watcher"
UID_VAL=$(id -u)
SERVICE_TARGET="gui/$UID_VAL/$LABEL"
PLIST_PATH="$HOME/Library/LaunchAgents/com.easyskills.watcher.plist"

if [ -f "$PLIST_PATH" ]; then
  launchctl bootout "$SERVICE_TARGET" 2>/dev/null || launchctl unload "$PLIST_PATH" 2>/dev/null
  rm -f "$PLIST_PATH"
fi

if [ -d "$HOME/EasySkills/_maintenance" ]; then
  bash "$HOME/EasySkills/_maintenance/deploy.sh" --cleanup
  rm -rf "$HOME/EasySkills"
  echo "Successfully removed ~/EasySkills and all agent symlinks."
  echo "已成功删除 ~/EasySkills 及所有 Agent 软链接。"
fi

echo "============================================="
echo "Uninstallation complete. / 卸载完成。"
echo "Press any key to close / 按任意键关闭..."
read -n 1 -s
