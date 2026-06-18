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

:: Clean up all junctions in agent directories, then move the install dir to
:: the Recycle Bin (recoverable) instead of an irreversible rd /S /Q — users
:: keep their custom skills under %PERM_DIR%.
if exist "%PERM_DIR%\_maintenance\deploy.ps1" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%PERM_DIR%\_maintenance\deploy.ps1" -Cleanup
  powershell -NoProfile -ExecutionPolicy Bypass -File "%PERM_DIR%\_maintenance\unwatch.ps1"

  powershell -NoProfile -ExecutionPolicy Bypass -Command "try { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory('%PERM_DIR%', 'OnlyErrorDialogs', 'SendToRecycleBin') } catch { Write-Host 'Warning: could not send to Recycle Bin automatically.'; Write-Host 'Please manually delete: %PERM_DIR%' }"
  echo Cleaned up permanent directory %USERPROFILE%\EasySkills ^(sent to Recycle Bin if possible^).
)

echo =============================================
echo Uninstallation complete. This window will close in a moment.
timeout /t 3 /nobreak > nul
