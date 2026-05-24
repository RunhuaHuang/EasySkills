# ==============================================================================
# Script: install.ps1 (Windows remote installer)
# Usage:  irm https://raw.githubusercontent.com/RunhuaHuang/EasySkills/main/install.ps1 | iex
# ==============================================================================

$ErrorActionPreference = "Stop"

$Repo = "RunhuaHuang/EasySkills"
$Branch = "main"
$PermDir = "$env:USERPROFILE\EasySkills"
$TmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "EasySkills-install-$(Get-Random)"

function Cleanup { if (Test-Path $TmpDir) { Remove-Item $TmpDir -Recurse -Force -ErrorAction SilentlyContinue } }

function Start-HiddenPowerShell([string]$ScriptPath, [string]$WorkingDirectory) {
  $Command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`""
  $Shell = New-Object -ComObject WScript.Shell
  $PreviousDirectory = [System.IO.Directory]::GetCurrentDirectory()
  try {
    [System.IO.Directory]::SetCurrentDirectory($WorkingDirectory)
    [void]$Shell.Run($Command, 0, $false)
  } finally {
    [System.IO.Directory]::SetCurrentDirectory($PreviousDirectory)
  }
}

try {
  Write-Host "=============================================" -ForegroundColor Cyan
  Write-Host "EasySkills Remote Installer (Windows)" -ForegroundColor Cyan
  Write-Host "=============================================" -ForegroundColor Cyan

  # --- Download ---
  Write-Host "Downloading EasySkills..."
  New-Item -ItemType Directory -Path $TmpDir -Force | Out-Null
  $ZipUrl = "https://github.com/$Repo/archive/refs/heads/$Branch.zip"
  $ZipPath = Join-Path $TmpDir "repo.zip"
  Invoke-WebRequest -Uri $ZipUrl -OutFile $ZipPath -UseBasicParsing
  Expand-Archive -Path $ZipPath -DestinationPath $TmpDir -Force
  $SrcDir = Join-Path $TmpDir "EasySkills-$Branch"

  # --- Install ---
  if (!(Test-Path $PermDir)) { New-Item -ItemType Directory -Path $PermDir -Force | Out-Null }

  # Preserve old version for upgrade reporting
  $OldVersion = $null
  $VersionFile = Join-Path $PermDir "_maintenance\.version"
  if (Test-Path $VersionFile) { $OldVersion = (Get-Content $VersionFile -Raw).Trim() }

  # Preserve user custom-targets.txt before wiping _maintenance/
  $MaintDir = Join-Path $PermDir "_maintenance"
  $CustomFile = Join-Path $MaintDir "custom-targets.txt"
  $CustomBackup = $null
  if (Test-Path $CustomFile) {
    $CustomBackup = Get-Content $CustomFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
  }
  # Also migrate from legacy root location (pre-v1.2)
  $LegacyRootCT = Join-Path $PermDir "custom-targets.txt"
  if (Test-Path $LegacyRootCT) {
    $LegacyLines = Get-Content $LegacyRootCT | Where-Object { $_ -and !$_.TrimStart().StartsWith("#") }
    if ($LegacyLines) {
      $CustomBackup = if ($CustomBackup) { "$CustomBackup`n$($LegacyLines -join "`n")" } else { $LegacyLines -join "`n" }
    }
    Remove-Item $LegacyRootCT -Force
  }

  # Clean install of _maintenance/
  if (Test-Path $MaintDir) { Remove-Item $MaintDir -Recurse -Force }
  Copy-Item -Path (Join-Path $SrcDir "_maintenance") -Destination $MaintDir -Recurse
  Copy-Item -Path (Join-Path $SrcDir "SKILL.md") -Destination (Join-Path $PermDir "SKILL.md") -Force

  # Restore user custom-targets.txt
  if ($CustomBackup) {
    $CustomBackup | Set-Content -Path $CustomFile -Encoding UTF8 -Force
  }

  # Version reporting
  $NewVersion = "unknown"
  $NewVersionFile = Join-Path $MaintDir ".version"
  if (Test-Path $NewVersionFile) { $NewVersion = (Get-Content $NewVersionFile -Raw).Trim() }
  if ($OldVersion -and $OldVersion -ne $NewVersion) {
    Write-Host "Upgraded: $OldVersion -> $NewVersion" -ForegroundColor Green
  } else {
    Write-Host "Installed version: $NewVersion" -ForegroundColor Green
  }

  # --- Activate: deploy once (visible) ---
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $MaintDir "deploy.ps1")

  # --- Install startup shortcuts ---
  $StartupFolder = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
  $WatcherShortcutPath = "$StartupFolder\EasySkillsWatcher.lnk"
  $WebUIShortcutPath = "$StartupFolder\EasySkillsWebUI.lnk"
  $ServiceScript = Join-Path $MaintDir "watcher-service.ps1"
  $WebUIScript = Join-Path $MaintDir "webui.ps1"
  try {
    $WshShell = New-Object -ComObject WScript.Shell
    $WatcherShortcut = $WshShell.CreateShortcut($WatcherShortcutPath)
    $WatcherShortcut.TargetPath = "powershell.exe"
    $WatcherShortcut.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ServiceScript`""
    $WatcherShortcut.WorkingDirectory = $MaintDir
    $WatcherShortcut.WindowStyle = 7
    $WatcherShortcut.Description = "EasySkills Background Watcher Service"
    $WatcherShortcut.Save()

    $WebUIShortcut = $WshShell.CreateShortcut($WebUIShortcutPath)
    $WebUIShortcut.TargetPath = "powershell.exe"
    $WebUIShortcut.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$WebUIScript`""
    $WebUIShortcut.WorkingDirectory = $MaintDir
    $WebUIShortcut.WindowStyle = 7
    $WebUIShortcut.Description = "EasySkills WebUI Background Service"
    $WebUIShortcut.Save()

    Write-Host "[OK] Startup shortcuts installed." -ForegroundColor Green
  } catch {
    Write-Warning "Failed to create startup shortcuts: $_"
  }

  # --- Start watcher now via a detached hidden PowerShell process. ---
  try {
    Start-HiddenPowerShell $ServiceScript $MaintDir
    Write-Host "[OK] Background watcher started." -ForegroundColor Green
  } catch {
    Write-Warning "Failed to start watcher: $_"
  }

  # --- Launch WebUI via a detached hidden PowerShell process. ---
  try {
    Start-HiddenPowerShell $WebUIScript $MaintDir
    Write-Host "[OK] WebUI launching on http://localhost:6633" -ForegroundColor Green
    Start-Sleep -Seconds 2
    try {
      Start-Process "http://localhost:6633"
    } catch {
      Write-Warning "Could not automatically open browser: $_"
    }
  } catch {
    Write-Warning "Failed to start WebUI: $_"
  }

  Write-Host "=============================================" -ForegroundColor Cyan
  Write-Host "EasySkills installed successfully!" -ForegroundColor Green
  Write-Host "Drop your custom skills into: $PermDir" -ForegroundColor Green
  Write-Host "=============================================" -ForegroundColor Cyan

} finally {
  Cleanup
}
