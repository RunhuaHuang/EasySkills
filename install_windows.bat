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
set "INSTALL_OK=1"

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

  :: --- Atomic install of _maintenance\ ---
  :: Validate source first: never destroy the existing install if source is
  :: missing/incomplete (errors are no longer hidden by > nul).
  if not exist "%CURRENT_DIR%_maintenance\deploy.ps1" (
    echo Error: source _maintenance\ missing or incomplete. Aborting; existing install untouched. 1>&2
    set "INSTALL_OK=0"
    goto :fail_block
  )
  if not exist "%CURRENT_DIR%README_SYSTEM.md" (
    echo Error: source README_SYSTEM.md missing. Aborting; existing install untouched. 1>&2
    set "INSTALL_OK=0"
    goto :fail_block
  )
  :: Build into a sibling temp dir, verify, then swap. Avoids the "rd then
  :: xcopy" footgun where a failed xcopy bricks the install.
  if exist "%PERM_DIR%\_maintenance.new" rd /S /Q "%PERM_DIR%\_maintenance.new"
  xcopy /E /I /Y /Q "%CURRENT_DIR%_maintenance" "%PERM_DIR%\_maintenance.new"
  if not exist "%PERM_DIR%\_maintenance.new\deploy.ps1" (
    echo Error: copy of _maintenance\ failed. Aborting; existing install untouched. 1>&2
    if exist "%PERM_DIR%\_maintenance.new" rd /S /Q "%PERM_DIR%\_maintenance.new"
    set "INSTALL_OK=0"
    goto :fail_block
  )
  if exist "%PERM_DIR%\_maintenance.bak.prev" rd /S /Q "%PERM_DIR%\_maintenance.bak.prev"
  if exist "%PERM_DIR%\_maintenance" (
    if exist "%PERM_DIR%\_maintenance.bak" ren "%PERM_DIR%\_maintenance.bak" _maintenance.bak.prev
    ren "%PERM_DIR%\_maintenance" _maintenance.bak
    if errorlevel 1 (
      echo Error: could not rotate existing _maintenance. Existing install untouched. 1>&2
      if exist "%PERM_DIR%\_maintenance.bak.prev" ren "%PERM_DIR%\_maintenance.bak.prev" _maintenance.bak
      if exist "%PERM_DIR%\_maintenance.new" rd /S /Q "%PERM_DIR%\_maintenance.new"
      set "INSTALL_OK=0"
      goto :fail_block
    )
  )
  ren "%PERM_DIR%\_maintenance.new" _maintenance
  if errorlevel 1 (
    echo Error: install swap failed; rolling back previous _maintenance. 1>&2
    if exist "%PERM_DIR%\_maintenance.new" rd /S /Q "%PERM_DIR%\_maintenance.new"
    if not exist "%PERM_DIR%\_maintenance" if exist "%PERM_DIR%\_maintenance.bak" ren "%PERM_DIR%\_maintenance.bak" _maintenance
    if exist "%PERM_DIR%\_maintenance.bak.prev" (
      if not exist "%PERM_DIR%\_maintenance.bak" (
        ren "%PERM_DIR%\_maintenance.bak.prev" _maintenance.bak
      ) else (
        rd /S /Q "%PERM_DIR%\_maintenance.bak.prev"
      )
    )
    set "INSTALL_OK=0"
    goto :fail_block
  )
  if exist "%PERM_DIR%\_maintenance.bak.prev" rd /S /Q "%PERM_DIR%\_maintenance.bak.prev"
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

:: Validation failures jump here, skipping the service launch below.
:fail_block

:: Run watch.ps1 — registers Scheduled Tasks for both Watcher and WebUI,
:: starts them detached, and they survive this window closing. Only run if the
:: install actually produced a deploy.ps1 (guards against the fail_block path).
if "%INSTALL_OK%"=="1" if exist "%PERM_DIR%\_maintenance\watch.ps1" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%PERM_DIR%\_maintenance\watch.ps1"

  :: Open the WebUI once the port is up.
  powershell -NoProfile -ExecutionPolicy Bypass -Command "for ($i=0;$i -lt 20;$i++) { $c=New-Object System.Net.Sockets.TcpClient; try { $a=$c.BeginConnect('127.0.0.1',6633,$null,$null); if ($a.AsyncWaitHandle.WaitOne(500,$false)) { try { $c.EndConnect($a); Start-Process 'http://localhost:6633'; break } catch {} } } catch {} finally { try { $c.Close() } catch {} }; Start-Sleep -Milliseconds 500 }"
)

echo =============================================
echo.
echo Open source: https://github.com/RunhuaHuang/EasySkills
echo This window will close automatically in a few seconds.
echo.
timeout /t 3 /nobreak > nul
