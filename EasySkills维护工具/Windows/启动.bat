@echo off
:: EasySkills 启动（转发到隐藏引擎目录）
chcp 65001 > nul
if exist "%USERPROFILE%\EasySkills\EasySkills维护工具/.engine\launchers\Windows-启动.vbs" (
  start "" wscript.exe "%USERPROFILE%\EasySkills\EasySkills维护工具/.engine\launchers\Windows-启动.vbs"
) else (
  echo 错误：未找到启动脚本。请检查安装是否完整。
  timeout /t 3 /nobreak > nul
)
