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
set "OLD_VERSION="
set "NEW_VERSION=unknown"
set "PRESERVE_DIR=%TEMP%\easyskills-install-%RANDOM%-%RANDOM%"
if exist "%PRESERVE_DIR%" rd /S /Q "%PRESERVE_DIR%"
mkdir "%PRESERVE_DIR%" > nul 2>&1
if errorlevel 1 (
  echo Error: could not create temporary preservation directory. Installation aborted. 1>&2
  exit /b 1
)

:: Resolve the engine directory name from disk. NTFS stores it as Unicode, so
:: the ASCII wildcard "EasySkills*" matches the real name on any codepage. We
:: match the PARENT dir (EasySkills维护工具) and append "\.engine", since
:: deploy.ps1 lives inside the .engine subfolder. The .engine\deploy.ps1 guard
:: also ensures a stale "EasySkills维护工具/.engine.new" temp dir never wins.
set "MAINT_DIR="
set "MAINT_DIR_AMBIGUOUS="
for /d %%D in ("%PERM_DIR%\EasySkills*") do if exist "%%D\.engine\deploy.ps1" (
  if defined MAINT_DIR (
    set "MAINT_DIR_AMBIGUOUS=1"
  ) else (
    set "MAINT_DIR=%%D\.engine"
  )
)
set "SRC_MAINT_DIR="
set "SRC_MAINT_DIR_AMBIGUOUS="
for /d %%D in ("%CURRENT_DIR_STRIP%\EasySkills*") do if exist "%%D\.engine\deploy.ps1" (
  if defined SRC_MAINT_DIR (
    set "SRC_MAINT_DIR_AMBIGUOUS=1"
  ) else (
    set "SRC_MAINT_DIR=%%D\.engine"
  )
)
:: These paths MUST be defined before the large parenthesized install block.
:: cmd.exe expands %%VAR%% once when parsing the whole block, so assigning them
:: inside it would leave fresh installs operating on empty/root-relative paths.
set "VISIBLE_DIR=%PERM_DIR%\EasySkills维护工具"
set "TARGET_MAINT_DIR=%VISIBLE_DIR%\.engine"
set "NEW_MAINT=%VISIBLE_DIR%\.engine.new"

if /i "%CURRENT_DIR_STRIP%" neq "%PERM_DIR%" (
  echo Deploying to: %PERM_DIR%
  if not exist "%PERM_DIR%" mkdir "%PERM_DIR%"

  :: --- Preserve user data before overwriting the engine directory ---

  if defined MAINT_DIR_AMBIGUOUS (
    echo Error: multiple installed engine directories matched EasySkills*. Aborting; existing install untouched. 1>&2
    set "INSTALL_OK=0"
    goto :fail_block
  )

  if defined MAINT_DIR (
    :: Save old version and all per-machine runtime files. The explicit guard
    :: prevents an empty MAINT_DIR from resolving these paths at the drive root.
    if exist "%MAINT_DIR%\.version" set /p OLD_VERSION=<"%MAINT_DIR%\.version"
    if exist "%MAINT_DIR%\custom-targets.txt" (
      copy /Y "%MAINT_DIR%\custom-targets.txt" "%PRESERVE_DIR%\custom-targets.txt" > nul
      if errorlevel 1 goto :preserve_failed
    )
    if exist "%MAINT_DIR%\disabled-targets.txt" (
      copy /Y "%MAINT_DIR%\disabled-targets.txt" "%PRESERVE_DIR%\disabled-targets.txt" > nul
      if errorlevel 1 goto :preserve_failed
    )
    if exist "%MAINT_DIR%\.easyskills-token" (
      copy /Y "%MAINT_DIR%\.easyskills-token" "%PRESERVE_DIR%\.easyskills-token" > nul
      if errorlevel 1 goto :preserve_failed
    )
  )
  :: --- Atomic install of the engine directory ---
  :: Validate source first: never destroy the existing install if source is
  :: missing/incomplete (errors are no longer hidden by > nul).
  if defined SRC_MAINT_DIR_AMBIGUOUS (
    echo Error: multiple source engine directories matched EasySkills*. Aborting; existing install untouched. 1>&2
    set "INSTALL_OK=0"
    goto :fail_block
  )
  if not defined SRC_MAINT_DIR (
    echo Error: source engine directory could not be resolved. Aborting; existing install untouched. 1>&2
    set "INSTALL_OK=0"
    goto :fail_block
  )
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
  if not exist "%VISIBLE_DIR%" mkdir "%VISIBLE_DIR%"
  if exist "%NEW_MAINT%" rd /S /Q "%NEW_MAINT%"
  xcopy /E /I /Y /Q "%SRC_MAINT_DIR%" "%NEW_MAINT%"
  if errorlevel 1 (
    echo Error: copy of engine directory failed. Aborting; existing install untouched. 1>&2
    if exist "%NEW_MAINT%" rd /S /Q "%NEW_MAINT%"
    set "INSTALL_OK=0"
    goto :fail_block
  )
  if not exist "%NEW_MAINT%\deploy.ps1" (
    echo Error: copy of engine directory failed. Aborting; existing install untouched. 1>&2
    if exist "%NEW_MAINT%" rd /S /Q "%NEW_MAINT%"
    set "INSTALL_OK=0"
    goto :fail_block
  )
  :: Carry runtime state into the staged engine BEFORE rotating the live tree.
  :: This keeps the new live engine complete even if a later step fails.
  if exist "%PRESERVE_DIR%\custom-targets.txt" (
    copy /Y "%PRESERVE_DIR%\custom-targets.txt" "%NEW_MAINT%\custom-targets.txt" > nul
    if errorlevel 1 goto :stage_runtime_failed
  )
  if exist "%PRESERVE_DIR%\disabled-targets.txt" (
    copy /Y "%PRESERVE_DIR%\disabled-targets.txt" "%NEW_MAINT%\disabled-targets.txt" > nul
    if errorlevel 1 goto :stage_runtime_failed
  )
  if exist "%PRESERVE_DIR%\.easyskills-token" (
    copy /Y "%PRESERVE_DIR%\.easyskills-token" "%NEW_MAINT%\.easyskills-token" > nul
    if errorlevel 1 goto :stage_runtime_failed
  )
  :: Legacy releases stored custom-targets.txt at the EasySkills root. Merge it
  :: into the staged engine before the swap so a Windows double-click upgrade
  :: cannot leave the user's custom Agent paths behind in an ignored location.
  if exist "%PERM_DIR%\custom-targets.txt" (
    set "EASYSKILLS_LEGACY_CUSTOM=%PERM_DIR%\custom-targets.txt"
    set "EASYSKILLS_STAGED_CUSTOM=%NEW_MAINT%\custom-targets.txt"
    powershell -NoProfile -ExecutionPolicy Bypass -Command "$legacy=$env:EASYSKILLS_LEGACY_CUSTOM; $dest=$env:EASYSKILLS_STAGED_CUSTOM; function Get-P([string]$line){ $raw=if($null -eq $line){''}else{$line.Trim()}; if(-not $raw -or $raw.StartsWith('#')){return ''}; if($raw.Contains('=')){ $parts=$raw.Split('=',2); $prefix=$parts[0].Trim(); $candidate=$parts[1].Trim(); $candidatePath=($candidate.StartsWith('/') -or $candidate.StartsWith('\') -or $candidate.StartsWith('~') -or $candidate.StartsWith('.') -or $candidate.Contains('/') -or $candidate.Contains('\') -or $candidate -match '^[A-Za-z]:[\\/]'); $prefixPath=($prefix.StartsWith('/') -or $prefix.StartsWith('\') -or $prefix.StartsWith('~') -or $prefix.StartsWith('.') -or $prefix.Contains('/') -or $prefix.Contains('\') -or $prefix -match '^[A-Za-z]:[\\/]'); if($prefix -and $candidatePath -and -not $prefixPath){$raw=$candidate} }; return $raw }; $lines=@(); if(Test-Path -LiteralPath $dest){$lines=@(Get-Content -LiteralPath $dest -Encoding UTF8)}; $seen=@{}; $out=@(); foreach($line in $lines){$raw=$line.Trim(); if(-not $raw -or $raw.StartsWith('#')){$out+=$line;continue}; $path=Get-P $line; try{$key=[IO.Path]::GetFullPath($path)}catch{$key=$path}; if(-not $seen.ContainsKey($key)){$seen[$key]=$true;$out+=$line} }; foreach($line in @(Get-Content -LiteralPath $legacy -Encoding UTF8)){$raw=$line.Trim(); if(-not $raw -or $raw.StartsWith('#')){continue}; $path=Get-P $line; try{$key=[IO.Path]::GetFullPath($path)}catch{$key=$path}; if(-not $seen.ContainsKey($key)){$seen[$key]=$true;$out+=$line} }; if($out.Count -gt 0){[IO.File]::WriteAllText($dest,(($out -join [Environment]::NewLine)+[Environment]::NewLine),(New-Object Text.UTF8Encoding($false)))}"
    if errorlevel 1 goto :stage_runtime_failed
    set "EASYSKILLS_LEGACY_CUSTOM="
    set "EASYSKILLS_STAGED_CUSTOM="
  )
  :: Backup lives at the PERM_DIR root (sibling of EasySkills维护工具), so we
  :: use `move` (cross-container) rather than `ren` (same-container only) for
  :: the .engine -> .maintenance-bak rotation, matching install.sh/install.ps1.
  :: Reconcile an interrupted prior rotation. If the normal backup is absent,
  :: .prev may be the only rollback snapshot and must be promoted, not deleted.
  if exist "%PERM_DIR%\.maintenance-bak.prev" (
    if exist "%PERM_DIR%\.maintenance-bak" (
      rd /S /Q "%PERM_DIR%\.maintenance-bak.prev"
    ) else (
      move /Y "%PERM_DIR%\.maintenance-bak.prev" "%PERM_DIR%\.maintenance-bak" > nul
      if errorlevel 1 (
        echo Error: previous recoverable backup could not be reconciled. Existing install untouched. 1>&2
        if exist "%NEW_MAINT%" rd /S /Q "%NEW_MAINT%"
        set "INSTALL_OK=0"
        goto :fail_block
      )
    )
  )
  if exist "%MAINT_DIR%" (
    if exist "%PERM_DIR%\.maintenance-bak" (
      move /Y "%PERM_DIR%\.maintenance-bak" "%PERM_DIR%\.maintenance-bak.prev" > nul
      if errorlevel 1 (
        echo Error: could not preserve the existing rollback backup. Existing install untouched. 1>&2
        if exist "%NEW_MAINT%" rd /S /Q "%NEW_MAINT%"
        set "INSTALL_OK=0"
        goto :fail_block
      )
    )
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
    if not exist "%TARGET_MAINT_DIR%" if exist "%PERM_DIR%\.maintenance-bak" move /Y "%PERM_DIR%\.maintenance-bak" "%TARGET_MAINT_DIR%" > nul
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
  if exist "%PERM_DIR%\custom-targets.txt" del /F /Q "%PERM_DIR%\custom-targets.txt"

  :: TARGET_MAINT_DIR is valid for both upgrades and fresh installs. MAINT_DIR
  :: may have been empty when no prior engine existed. The root custom-targets.txt
  :: is intentionally NOT recreated here: deploy.ps1 owns it inside .engine/, and
  :: any stray root copy is migrated+removed on the next sync (matching install.sh
  :: and install.ps1).

)

goto :install_block_complete

:preserve_failed
echo Error: could not preserve existing runtime configuration. Existing install untouched. 1>&2
set "INSTALL_OK=0"
goto :fail_block

:stage_runtime_failed
echo Error: could not stage preserved runtime configuration. Existing install untouched. 1>&2
if exist "%NEW_MAINT%" rd /S /Q "%NEW_MAINT%"
set "INSTALL_OK=0"
goto :fail_block

:install_block_complete

:: Resolve the now-live engine path outside the block, after the atomic swap.
if "%INSTALL_OK%"=="1" if exist "%TARGET_MAINT_DIR%\deploy.ps1" set "MAINT_DIR=%TARGET_MAINT_DIR%"
if "%INSTALL_OK%"=="1" if defined MAINT_DIR_AMBIGUOUS (
  echo Error: multiple installed engine directories matched EasySkills*. Refusing to continue with an ambiguous installation. 1>&2
  set "INSTALL_OK=0"
  goto :fail_block
)
if "%INSTALL_OK%"=="1" if not defined MAINT_DIR (
  echo Error: installed engine directory could not be resolved. 1>&2
  set "INSTALL_OK=0"
  goto :fail_block
)
if "%INSTALL_OK%"=="1" if not exist "%MAINT_DIR%\deploy.ps1" (
  echo Error: installed engine is missing or incomplete. 1>&2
  set "INSTALL_OK=0"
  goto :fail_block
)
if exist "%MAINT_DIR%\.version" set /p NEW_VERSION=<"%MAINT_DIR%\.version"

:: Initialize user MCP config and install the optional Gateway binary.
if not exist "%PERM_DIR%\mcp" mkdir "%PERM_DIR%\mcp"
if not exist "%PERM_DIR%\mcp\servers.json" if exist "%MAINT_DIR%\mcp-servers.template.json" copy /Y "%MAINT_DIR%\mcp-servers.template.json" "%PERM_DIR%\mcp\servers.json" > nul
if exist "%MAINT_DIR%\install-gateway.ps1" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%MAINT_DIR%\install-gateway.ps1" -SourceDir "%CURRENT_DIR%gateway"
  if errorlevel 1 echo Warning: EasySkills installed, but the optional MCP Gateway installation failed. Run Doctor and retry it later. 1>&2
)

:: --- Version reporting (outside the parenthesized block above) ---
:version_report
if defined OLD_VERSION (
  echo Upgraded: %OLD_VERSION% -^> %NEW_VERSION%
) else (
  echo Installed version: %NEW_VERSION%
)

:: Validation failures jump here, skipping the service launch below.
:fail_block

if exist "%PRESERVE_DIR%" rd /S /Q "%PRESERVE_DIR%"

:: Run watch.ps1 — registers Scheduled Tasks for both Watcher and WebUI,
:: starts them detached, and they survive this window closing. Only run if the
:: install actually produced a deploy.ps1 (guards against the fail_block path).
if "%INSTALL_OK%"=="1" if exist "%MAINT_DIR%\watch.ps1" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%MAINT_DIR%\watch.ps1"
  if errorlevel 1 (
    echo Error: EasySkills was installed, but background service registration failed. 1>&2
    set "INSTALL_OK=0"
    goto :install_done
  )

  :: Remove legacy _maintenance/_runtime dirs (pre-4.1.0 installs). The tasks
  :: were re-registered above; the old trees are no longer referenced and their
  :: runtime config was migrated earlier in this script.
  powershell -NoProfile -ExecutionPolicy Bypass -Command "try { $lm = Join-Path $env:USERPROFILE 'EasySkills\_maintenance'; if ((Test-Path $lm) -and (Test-Path (Join-Path $lm 'deploy.ps1'))) { Remove-Item $lm -Recurse -Force }; $lr = Join-Path $env:USERPROFILE 'EasySkills\_runtime'; if (Test-Path $lr) { Remove-Item $lr -Recurse -Force } } catch { Write-Warning ('Legacy cleanup skipped: ' + $_.Exception.Message) }"

  :: Open the WebUI once the port is up.
  powershell -NoProfile -ExecutionPolicy Bypass -Command "for ($i=0;$i -lt 20;$i++) { $c=New-Object System.Net.Sockets.TcpClient; try { $a=$c.BeginConnect('127.0.0.1',6633,$null,$null); if ($a.AsyncWaitHandle.WaitOne(500,$false)) { try { $c.EndConnect($a); Start-Process 'http://localhost:6633'; break } catch {} } } catch {} finally { try { $c.Close() } catch {} }; Start-Sleep -Milliseconds 500 }"
)

:install_done
echo =============================================
echo.
echo Open source: https://github.com/RunhuaHuang/EasySkills
echo This window will close automatically in a few seconds.
echo.
timeout /t 3 /nobreak > nul
if "%INSTALL_OK%"=="0" exit /b 1
exit /b 0
