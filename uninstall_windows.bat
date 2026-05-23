@echo off
:: ==============================================================================
:: Script: uninstall_windows.bat (Windows)
:: Description: Self-cleaning double-clickable batch uninstaller for Windows.
:: ==============================================================================

title EasySkills Uninstaller (Windows)

echo =============================================
echo Uninstalling EasySkills (Windows)...
echo =============================================

set "PERM_DIR=%USERPROFILE%\EasySkills"

:: Clean up all junctions in agent directories, then unwatch and delete
if exist "%PERM_DIR%\_maintenance\deploy.ps1" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%PERM_DIR%\_maintenance\deploy.ps1" -Cleanup
  powershell -NoProfile -ExecutionPolicy Bypass -File "%PERM_DIR%\_maintenance\unwatch.ps1"
  rd /S /Q "%PERM_DIR%"
  echo Successfully cleaned up permanent directory %USERPROFILE%\EasySkills.
)

echo =============================================
echo Uninstallation complete.
echo Press any key to close this window...
pause > nul
