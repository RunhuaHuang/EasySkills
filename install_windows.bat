@echo off
:: ==============================================================================
:: Script: install_windows.bat (Windows)
:: Description: Self-relocating double-clickable installer for Windows.
::              Preserves user custom-targets.txt across upgrades.
:: ==============================================================================

title EasySkills Installer (Windows)

echo =============================================
echo Starting EasySkills Installation (Windows)...
echo =============================================

set "PERM_DIR=%USERPROFILE%\EasySkills"
set "CURRENT_DIR=%~dp0"
set "CURRENT_DIR_STRIP=%CURRENT_DIR:~0,-1%"

if /i "%CURRENT_DIR_STRIP%" neq "%PERM_DIR%" (
  echo Deploying to: %PERM_DIR%
  if not exist "%PERM_DIR%" mkdir "%PERM_DIR%"

  :: --- Preserve user data before overwriting _maintenance\ ---

  :: Save old version
  set "OLD_VERSION="
  if exist "%PERM_DIR%\_maintenance\.version" (
    set /p OLD_VERSION=<"%PERM_DIR%\_maintenance\.version"
  )

  :: Migrate custom-targets.txt from old _maintenance\ location to root
  if exist "%PERM_DIR%\_maintenance\custom-targets.txt" (
    if not exist "%PERM_DIR%\custom-targets.txt" (
      copy /Y "%PERM_DIR%\_maintenance\custom-targets.txt" "%PERM_DIR%\custom-targets.txt" > nul
      echo Migrated custom targets to %PERM_DIR%\custom-targets.txt
    )
  )

  :: Preserve per-machine runtime files (unmapped targets + WebUI token).
  :: Use fixed %TEMP% paths (set outside this block) to avoid the parenthesized
  :: block's parse-time %VAR% expansion trap.
  if exist "%PERM_DIR%\_maintenance\disabled-targets.txt" copy /Y "%PERM_DIR%\_maintenance\disabled-targets.txt" "%TEMP%\easyskills-disabled.bak" > nul
  if exist "%PERM_DIR%\_maintenance\.easyskills-token" copy /Y "%PERM_DIR%\_maintenance\.easyskills-token" "%TEMP%\easyskills-token.bak" > nul

  :: --- Clean install of _maintenance\ ---
  if exist "%PERM_DIR%\_maintenance" rd /S /Q "%PERM_DIR%\_maintenance"
  xcopy /E /I /Y "%CURRENT_DIR%_maintenance" "%PERM_DIR%\_maintenance" > nul
  copy /Y "%CURRENT_DIR%README_SYSTEM.md" "%PERM_DIR%\README_SYSTEM.md" > nul
  if exist "%PERM_DIR%\SKILL.md" del /F /Q "%PERM_DIR%\SKILL.md"

  :: Restore preserved runtime files
  if exist "%TEMP%\easyskills-disabled.bak" copy /Y "%TEMP%\easyskills-disabled.bak" "%PERM_DIR%\_maintenance\disabled-targets.txt" > nul
  if exist "%TEMP%\easyskills-token.bak" copy /Y "%TEMP%\easyskills-token.bak" "%PERM_DIR%\_maintenance\.easyskills-token" > nul
  del /F /Q "%TEMP%\easyskills-disabled.bak" "%TEMP%\easyskills-token.bak" 2>nul

  :: Initialize custom-targets.txt at root if not present
  if not exist "%PERM_DIR%\custom-targets.txt" (
    if exist "%PERM_DIR%\_maintenance\custom-targets.template.txt" (
      copy /Y "%PERM_DIR%\_maintenance\custom-targets.template.txt" "%PERM_DIR%\custom-targets.txt" > nul
    )
  )

  :: --- Version reporting ---
  set "NEW_VERSION=unknown"
  if exist "%PERM_DIR%\_maintenance\.version" (
    set /p NEW_VERSION=<"%PERM_DIR%\_maintenance\.version"
  )
  if defined OLD_VERSION (
    echo Upgraded: %OLD_VERSION% -^> %NEW_VERSION%
  ) else (
    echo Installed version: %NEW_VERSION%
  )
)

:: Run watch.ps1 — registers Scheduled Tasks for both Watcher and WebUI,
:: starts them detached, and they survive this window closing.
powershell -NoProfile -ExecutionPolicy Bypass -File "%PERM_DIR%\_maintenance\watch.ps1"

:: Open the WebUI once the port is up.
powershell -NoProfile -ExecutionPolicy Bypass -Command "for ($i=0;$i -lt 20;$i++) { $c=New-Object System.Net.Sockets.TcpClient; try { $a=$c.BeginConnect('127.0.0.1',6633,$null,$null); if ($a.AsyncWaitHandle.WaitOne(500,$false)) { try { $c.EndConnect($a); Start-Process 'http://localhost:6633'; break } catch {} } } catch {} finally { try { $c.Close() } catch {} }; Start-Sleep -Milliseconds 500 }"

echo =============================================
echo.
echo Open source: https://github.com/RunhuaHuang/EasySkills
echo This window will close automatically in a few seconds.
echo.
timeout /t 3 /nobreak > nul
