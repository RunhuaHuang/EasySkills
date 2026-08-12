@echo off
:: EasySkills Shutdown (Windows) / 关闭 EasySkills 后台服务
:: Delegate to the canonical unwatch.ps1 so both Scheduled Tasks and the
:: Startup-shortcut/direct-supervisor fallback are stopped consistently.

chcp 65001 > nul

title EasySkills Shutdown

echo =============================================
echo Stopping EasySkills services / 正在关闭 EasySkills...
echo =============================================

set "SCRIPT_DIR=%~dp0"
set "UNWATCH=%SCRIPT_DIR%..\unwatch.ps1"
if not exist "%UNWATCH%" (
  echo Error: canonical unwatch.ps1 was not found.
  timeout /t 3 /nobreak > nul
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%UNWATCH%"
if errorlevel 1 (
  echo Warning: one or more EasySkills services could not be stopped.
  timeout /t 3 /nobreak > nul
  exit /b 1
)

echo =============================================
echo EasySkills services stopped. / EasySkills 已关闭。
echo This window will close in a moment.
echo =============================================
timeout /t 3 /nobreak > nul
