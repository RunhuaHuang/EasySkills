@echo off
:: ==============================================================================
:: Script: uninstall_windows.bat (Windows)
:: Description: Self-cleaning double-clickable batch uninstaller for Windows.
:: ==============================================================================

:: Switch the console to UTF-8 for any output with non-ASCII text. The engine
:: directory name is resolved below via the ASCII "EasySkills*" wildcard, so
:: it matches on any codepage even if this page switch is unavailable.
chcp 65001 > nul

title EasySkills Uninstaller (Windows)

echo =============================================
echo Uninstalling EasySkills (Windows)...
echo =============================================

set "PERM_DIR=%USERPROFILE%\EasySkills"

:: Resolve the engine directory name from disk (Unicode name, ASCII wildcard).
:: Match the PARENT dir (EasySkills维护工具) and append "\.engine", since
:: deploy.ps1 lives inside the .engine subfolder.
set "MAINT_DIR="
set "MAINT_DIR_AMBIGUOUS="
for /d %%D in ("%PERM_DIR%\EasySkills*") do call :ResolveMaintDir "%%~fD"
if defined MAINT_DIR_AMBIGUOUS (
  echo Error: multiple installed engine directories matched EasySkills*. Aborting; existing install untouched. 1>&2
  goto cleanup_failed
)

:: Clean up all junctions in agent directories, then move the install dir to
:: the Recycle Bin (recoverable) instead of an irreversible rd /S /Q — users
:: keep their custom skills under %PERM_DIR%.
if exist "%MAINT_DIR%\deploy.ps1" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%MAINT_DIR%\deploy.ps1" -Cleanup
  if errorlevel 1 goto cleanup_failed
  powershell -NoProfile -ExecutionPolicy Bypass -File "%MAINT_DIR%\unwatch.ps1"
  if errorlevel 1 goto cleanup_failed

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

:ResolveMaintDir
if not exist "%~1\.engine\deploy.ps1" exit /b 0
if defined MAINT_DIR (
  set "MAINT_DIR_AMBIGUOUS=1"
) else (
  set "MAINT_DIR=%~1\.engine"
)
exit /b 0
