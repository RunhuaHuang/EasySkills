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
  if errorlevel 1 goto cleanup_failed
  powershell -NoProfile -ExecutionPolicy Bypass -File "%PERM_DIR%\_maintenance\unwatch.ps1"

  powershell -NoProfile -ExecutionPolicy Bypass -Command "try { $p = Join-Path $env:USERPROFILE 'EasySkills'; [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($p, 'OnlyErrorDialogs', 'SendToRecycleBin') } catch { Write-Host 'Warning: could not send to Recycle Bin automatically.'; Write-Host ('Please manually delete: ' + (Join-Path $env:USERPROFILE 'EasySkills')); exit 1 }"
  if errorlevel 1 goto cleanup_failed
  echo Cleaned up permanent directory %USERPROFILE%\EasySkills ^(sent to Recycle Bin if possible^).
)

:uninstall_done
echo =============================================
echo Uninstallation complete. This window will close in a moment.
timeout /t 3 /nobreak > nul
exit /b 0

:cleanup_failed
echo =============================================
echo Uninstallation incomplete. The EasySkills folder was kept to protect user data.
echo Please resolve the error above and run the uninstaller again.
timeout /t 5 /nobreak > nul
exit /b 1
