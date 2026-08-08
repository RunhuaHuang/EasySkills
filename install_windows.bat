@echo off
:: ==============================================================================
:: Script: install_windows.bat (Windows)
:: Description: Self-relocating double-clickable installer for Windows.
::              Preserves user custom-targets.txt across upgrades.
:: ==============================================================================

:: Switch the console to UTF-8 so the Chinese engine-directory name
:: (EasySkills维护工具/.engine) is written correctly by the final rename below.
:: NOTE: cmd.exe decodes this batch file with the OEM codepage, so every other
:: path is resolved via the ASCII "EasySkills*" wildcard (which matches the
:: Unicode name on disk regardless of codepage). Only the renames that CREATE
:: the final Chinese name depend on this page switch; if they fail, install
:: aborts loudly instead of corrupting anything.
chcp 65001 > nul

title EasySkills Installer (Windows)

echo =============================================
echo Starting EasySkills Installation (Windows)...
echo =============================================

set "PERM_DIR=%USERPROFILE%\EasySkills"
set "CURRENT_DIR=%~dp0"
set "CURRENT_DIR_STRIP=%CURRENT_DIR:~0,-1%"
set "INSTALL_OK=1"

:: Resolve the engine directory name from disk. NTFS stores it as Unicode, so
:: the ASCII wildcard "EasySkills*" matches the real name on any codepage. We
:: match the PARENT dir (EasySkills维护工具) and append "\.engine", since
:: deploy.ps1 lives inside the .engine subfolder. The .engine\deploy.ps1 guard
:: also ensures a stale "EasySkills维护工具/.engine.new" temp dir never wins.
set "MAINT_DIR="
for /d %%D in ("%PERM_DIR%\EasySkills*") do if exist "%%D\.engine\deploy.ps1" set "MAINT_DIR=%%D\.engine"
set "SRC_MAINT_DIR="
for /d %%D in ("%CURRENT_DIR_STRIP%\EasySkills*") do if exist "%%D\.engine\deploy.ps1" set "SRC_MAINT_DIR=%%D\.engine"

if /i "%CURRENT_DIR_STRIP%" neq "%PERM_DIR%" (
  echo Deploying to: %PERM_DIR%
  if not exist "%PERM_DIR%" mkdir "%PERM_DIR%"

  :: --- Preserve user data before overwriting the engine directory ---

  :: Save old version
  set "OLD_VERSION="
  if exist "%MAINT_DIR%\.version" (
    set /p OLD_VERSION=<"%MAINT_DIR%\.version"
  )

  :: Migrate custom-targets.txt from old engine location to root
  if exist "%MAINT_DIR%\custom-targets.txt" (
    if not exist "%PERM_DIR%\custom-targets.txt" (
      copy /Y "%MAINT_DIR%\custom-targets.txt" "%PERM_DIR%\custom-targets.txt" > nul
      echo Migrated custom targets to %PERM_DIR%\custom-targets.txt
    )
  )

  :: Preserve per-machine runtime files (unmapped targets + WebUI token).
  :: Use fixed %TEMP% paths (set outside this block) to avoid the parenthesized
  :: block's parse-time %VAR% expansion trap.
  if exist "%MAINT_DIR%\disabled-targets.txt" copy /Y "%MAINT_DIR%\disabled-targets.txt" "%TEMP%\easyskills-disabled.bak" > nul
  if exist "%MAINT_DIR%\.easyskills-token" copy /Y "%MAINT_DIR%\.easyskills-token" "%TEMP%\easyskills-token.bak" > nul

  :: --- Atomic install of the engine directory ---
  :: Validate source first: never destroy the existing install if source is
  :: missing/incomplete (errors are no longer hidden by > nul).
  if not exist "%SRC_MAINT_DIR%\deploy.ps1" (
    echo Error: source engine directory missing or incomplete. Aborting; existing install untouched. 1>&2
    set "INSTALL_OK=0"
    goto :fail_block
  )
  if not exist "%CURRENT_DIR%EasySkills维护工具\README_SYSTEM.md" (
    echo Error: source README_SYSTEM.md missing. Aborting; existing install untouched. 1>&2
    set "INSTALL_OK=0"
    goto :fail_block
  )
  :: Build into a sibling temp dir at the SAME nesting as the live engine
  :: (.../EasySkills维护工具/.engine.new), verify, then swap with a same-parent
  :: rename. cmd's `ren` cannot take a path in its 2nd arg, so the temp dir must
  :: already live under the EasySkills维护工具 parent. Avoids the "rd then xcopy"
  :: footgun where a failed xcopy bricks the install.
  set "VISIBLE_DIR=%PERM_DIR%\EasySkills维护工具"
  set "NEW_MAINT=%VISIBLE_DIR%\.engine.new"
  if not exist "%VISIBLE_DIR%" mkdir "%VISIBLE_DIR%"
  if exist "%NEW_MAINT%" rd /S /Q "%NEW_MAINT%"
  xcopy /E /I /Y /Q "%SRC_MAINT_DIR%" "%NEW_MAINT%"
  if not exist "%NEW_MAINT%\deploy.ps1" (
    echo Error: copy of engine directory failed. Aborting; existing install untouched. 1>&2
    if exist "%NEW_MAINT%" rd /S /Q "%NEW_MAINT%"
    set "INSTALL_OK=0"
    goto :fail_block
  )
  :: Backup lives at the PERM_DIR root (sibling of EasySkills维护工具), so we
  :: use `move` (cross-container) rather than `ren` (same-container only) for
  :: the .engine -> .maintenance-bak rotation, matching install.sh/install.ps1.
  if exist "%PERM_DIR%\.maintenance-bak.prev" rd /S /Q "%PERM_DIR%\.maintenance-bak.prev"
  if exist "%MAINT_DIR%" (
    if exist "%PERM_DIR%\.maintenance-bak" move /Y "%PERM_DIR%\.maintenance-bak" "%PERM_DIR%\.maintenance-bak.prev" > nul
    move /Y "%MAINT_DIR%" "%PERM_DIR%\.maintenance-bak" > nul
    if errorlevel 1 (
      echo Error: could not rotate existing engine. Existing install untouched. 1>&2
      if exist "%PERM_DIR%\.maintenance-bak.prev" move /Y "%PERM_DIR%\.maintenance-bak.prev" "%PERM_DIR%\.maintenance-bak" > nul
      if exist "%NEW_MAINT%" rd /S /Q "%NEW_MAINT%"
      set "INSTALL_OK=0"
      goto :fail_block
    )
  )
  :: Same-parent rename: .engine.new -> .engine. (Both are children of
  :: EasySkills维护工具, so `ren` is valid here — its 2nd arg is a bare name.)
  ren "%NEW_MAINT%" .engine
  if errorlevel 1 (
    echo Error: install swap failed; rolling back previous engine. 1>&2
    if exist "%NEW_MAINT%" rd /S /Q "%NEW_MAINT%"
    if not exist "%MAINT_DIR%" if exist "%PERM_DIR%\.maintenance-bak" move /Y "%PERM_DIR%\.maintenance-bak" "%MAINT_DIR%" > nul
    if exist "%PERM_DIR%\.maintenance-bak.prev" (
      if not exist "%PERM_DIR%\.maintenance-bak" (
        move /Y "%PERM_DIR%\.maintenance-bak.prev" "%PERM_DIR%\.maintenance-bak" > nul
      ) else (
        rd /S /Q "%PERM_DIR%\.maintenance-bak.prev"
      )
    )
    set "INSTALL_OK=0"
    goto :fail_block
  )
  if exist "%PERM_DIR%\.maintenance-bak.prev" rd /S /Q "%PERM_DIR%\.maintenance-bak.prev"
  copy /Y "%CURRENT_DIR%EasySkills维护工具\README_SYSTEM.md" "%PERM_DIR%\EasySkills维护工具\README_SYSTEM.md" > nul
  if exist "%PERM_DIR%\SKILL.md" del /F /Q "%PERM_DIR%\SKILL.md"

  :: After the swap the live engine lives at the original %MAINT_DIR% path
  :: (renamed back into place by the swap above), so %MAINT_DIR% stays valid.

  :: Restore preserved runtime files
  if exist "%TEMP%\easyskills-disabled.bak" copy /Y "%TEMP%\easyskills-disabled.bak" "%MAINT_DIR%\disabled-targets.txt" > nul
  if exist "%TEMP%\easyskills-token.bak" copy /Y "%TEMP%\easyskills-token.bak" "%MAINT_DIR%\.easyskills-token" > nul
  del /F /Q "%TEMP%\easyskills-disabled.bak" "%TEMP%\easyskills-token.bak" 2>nul

  :: Initialize custom-targets.txt at root if not present
  if not exist "%PERM_DIR%\custom-targets.txt" (
    if exist "%MAINT_DIR%\custom-targets.template.txt" (
      copy /Y "%MAINT_DIR%\custom-targets.template.txt" "%PERM_DIR%\custom-targets.txt" > nul
    )
  )

  :: Set NEW_VERSION inside the block (stored correctly), but do NOT read it
  :: here — %VAR% inside a parenthesized block expands once at parse time, so
  :: the version report below would always print empty. The report is emitted
  :: AFTER the block closes (at the :version_report label) where the variables
  :: are already final and %VAR% expansion works correctly.
  set "NEW_VERSION=unknown"
  if exist "%MAINT_DIR%\.version" (
    set /p NEW_VERSION=<"%MAINT_DIR%\.version"
  )
)

:: Initialize user MCP config and install the optional Gateway binary.
if not exist "%PERM_DIR%\mcp" mkdir "%PERM_DIR%\mcp"
if not exist "%PERM_DIR%\mcp\servers.json" if exist "%MAINT_DIR%\mcp-servers.template.json" copy /Y "%MAINT_DIR%\mcp-servers.template.json" "%PERM_DIR%\mcp\servers.json" > nul
if exist "%MAINT_DIR%\install-gateway.ps1" powershell -NoProfile -ExecutionPolicy Bypass -File "%MAINT_DIR%\install-gateway.ps1" -SourceDir "%CURRENT_DIR%gateway"

:: --- Version reporting (MUST be outside the parenthesized block above) ---
:: Here %OLD_VERSION% / %NEW_VERSION% are read AFTER the block that sets them,
:: so CMD's parse-time expansion reflects their real values. OLD_VERSION is only
:: defined on the upgrade path (set near the top of the block above).
:version_report
if defined OLD_VERSION (
  echo Upgraded: %OLD_VERSION% -^> %NEW_VERSION%
) else (
  echo Installed version: %NEW_VERSION%
)

:: Validation failures jump here, skipping the service launch below.
:fail_block

:: Run watch.ps1 — registers Scheduled Tasks for both Watcher and WebUI,
:: starts them detached, and they survive this window closing. Only run if the
:: install actually produced a deploy.ps1 (guards against the fail_block path).
if "%INSTALL_OK%"=="1" if exist "%MAINT_DIR%\watch.ps1" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%MAINT_DIR%\watch.ps1"

  :: Remove legacy _maintenance/_runtime dirs (pre-4.1.0 installs). The tasks
  :: were re-registered above; the old trees are no longer referenced and their
  :: runtime config was migrated earlier in this script.
  powershell -NoProfile -ExecutionPolicy Bypass -Command "try { $lm = Join-Path $env:USERPROFILE 'EasySkills\_maintenance'; if ((Test-Path $lm) -and (Test-Path (Join-Path $lm 'deploy.ps1'))) { Remove-Item $lm -Recurse -Force }; $lr = Join-Path $env:USERPROFILE 'EasySkills\_runtime'; if (Test-Path $lr) { Remove-Item $lr -Recurse -Force } } catch { Write-Warning ('Legacy cleanup skipped: ' + $_.Exception.Message) }"

  :: Open the WebUI once the port is up.
  powershell -NoProfile -ExecutionPolicy Bypass -Command "for ($i=0;$i -lt 20;$i++) { $c=New-Object System.Net.Sockets.TcpClient; try { $a=$c.BeginConnect('127.0.0.1',6633,$null,$null); if ($a.AsyncWaitHandle.WaitOne(500,$false)) { try { $c.EndConnect($a); Start-Process 'http://localhost:6633'; break } catch {} } } catch {} finally { try { $c.Close() } catch {} }; Start-Sleep -Milliseconds 500 }"
)

echo =============================================
echo.
echo Open source: https://github.com/RunhuaHuang/EasySkills
echo This window will close automatically in a few seconds.
echo.
timeout /t 3 /nobreak > nul
