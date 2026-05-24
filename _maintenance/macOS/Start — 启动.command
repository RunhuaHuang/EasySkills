#!/usr/bin/env bash
# EasySkills WebUI Launcher / 启动 EasySkills 控制面板
cd "$(dirname "$0")/.."
if ! command -v python3 &>/dev/null; then
  echo "Error: python3 is required. Please install Python 3 first."
  echo "错误: 需要 python3。请先安装 Python 3。"
  read -n 1 -s
  exit 1
fi
python3 webui.py
