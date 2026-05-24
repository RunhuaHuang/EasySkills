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

  :: --- Clean install of _maintenance\ ---
  if exist "%PERM_DIR%\_maintenance" rd /S /Q "%PERM_DIR%\_maintenance"
  xcopy /E /I /Y "%CURRENT_DIR%_maintenance" "%PERM_DIR%\_maintenance" > nul
  copy /Y "%CURRENT_DIR%SKILL.md" "%PERM_DIR%\SKILL.md" > nul

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

:: Run watch.ps1 from the permanent location
powershell -NoProfile -ExecutionPolicy Bypass -File "%PERM_DIR%\_maintenance\watch.ps1"

:: Launch WebUI in background
echo Launching WebUI Manager on port 6633...
start "" /B powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%PERM_DIR%\_maintenance\webui.ps1"

echo =============================================
echo.
echo NOTE: If Windows Defender shows a warning, you can safely allow it.
echo To add an exclusion, run PowerShell as Administrator:
echo   Add-MpPreference -ExclusionPath "%PERM_DIR%"
echo Or: Windows Security ^> Virus ^& threat protection ^> Exclusions ^> Add folder
echo.
echo Press any key to close this window...
pause > nul
