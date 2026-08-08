@echo off
:: EasySkills 关闭（转发到隐藏引擎目录）
chcp 65001 > nul
if exist "%USERPROFILE%\EasySkills\EasySkills维护工具/.engine\launchers\Windows-关闭.bat" (
  call "%USERPROFILE%\EasySkills\EasySkills维护工具/.engine\launchers\Windows-关闭.bat"
) else (
  echo 错误：未找到关闭脚本。请检查安装是否完整。
  timeout /t 3 /nobreak > nul
)
