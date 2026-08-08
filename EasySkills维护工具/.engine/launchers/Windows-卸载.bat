@echo off
:: EasySkills Uninstaller (Windows) / 卸载 EasySkills

:: Switch the console to UTF-8 for any output with non-ASCII text. The engine
:: directory name is resolved below via the ASCII "EasySkills*" wildcard, so
:: it matches on any codepage even if this page switch is unavailable.
chcp 65001 > nul

title EasySkills Uninstaller

echo =============================================
echo Uninstalling EasySkills / 正在卸载 EasySkills...
echo =============================================

set "PERM_DIR=%USERPROFILE%\EasySkills"

:: Resolve the engine directory name from disk (Unicode name, ASCII wildcard).
:: Match the PARENT dir (EasySkills维护工具) and append "\.engine", since
:: deploy.ps1 lives inside the .engine subfolder.
set "MAINT_DIR="
for /d %%D in ("%PERM_DIR%\EasySkills*") do if exist "%%D\.engine\deploy.ps1" set "MAINT_DIR=%%D\.engine"

if exist "%MAINT_DIR%\deploy.ps1" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%MAINT_DIR%\deploy.ps1" -Cleanup
  if errorlevel 1 goto cleanup_failed
  powershell -NoProfile -ExecutionPolicy Bypass -File "%MAINT_DIR%\unwatch.ps1"
  if errorlevel 1 goto cleanup_failed
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
