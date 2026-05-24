@echo off
:: EasySkills Uninstaller (Windows) / 卸载 EasySkills
title EasySkills Uninstaller

echo =============================================
echo Uninstalling EasySkills / 正在卸载 EasySkills...
echo =============================================

set "PERM_DIR=%USERPROFILE%\EasySkills"

if exist "%PERM_DIR%\_maintenance\deploy.ps1" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%PERM_DIR%\_maintenance\deploy.ps1" -Cleanup
  powershell -NoProfile -ExecutionPolicy Bypass -File "%PERM_DIR%\_maintenance\unwatch.ps1"
  rd /S /Q "%PERM_DIR%"
  echo Successfully removed %PERM_DIR% and all agent junctions.
)

echo =============================================
echo Uninstallation complete. This window will close in a moment.
timeout /t 3 /nobreak > nul
