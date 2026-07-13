@echo off
:: EasySkills Uninstaller (Windows) / 卸载 EasySkills
title EasySkills Uninstaller

echo =============================================
echo Uninstalling EasySkills / 正在卸载 EasySkills...
echo =============================================

set "PERM_DIR=%USERPROFILE%\EasySkills"

if exist "%PERM_DIR%\_maintenance\deploy.ps1" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%PERM_DIR%\_maintenance\deploy.ps1" -Cleanup
  if errorlevel 1 goto cleanup_failed
  powershell -NoProfile -ExecutionPolicy Bypass -File "%PERM_DIR%\_maintenance\unwatch.ps1"
  powershell -NoProfile -ExecutionPolicy Bypass -Command "try { $p = Join-Path $env:USERPROFILE 'EasySkills'; [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($p, 'OnlyErrorDialogs', 'SendToRecycleBin') } catch { Write-Host 'Warning: could not send to Recycle Bin automatically.'; Write-Host ('Please manually delete: ' + (Join-Path $env:USERPROFILE 'EasySkills')); exit 1 }"
  if errorlevel 1 goto cleanup_failed
  echo Cleaned agent junctions and sent %PERM_DIR% to the Recycle Bin if possible.
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
