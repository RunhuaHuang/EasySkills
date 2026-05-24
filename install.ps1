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

function Stop-StaleEasySkillsProcesses {
  # Terminate any supervisor / webui.ps1 from a prior install so that the
  # _maintenance folder isn't held open by a running powershell.exe when we
  # try to overwrite it. Matches by command-line via WMI.
  try {
    $Procs = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
      Where-Object {
        $_.CommandLine -and (
          $_.CommandLine -like '*webui-service.ps1*' -or
          $_.CommandLine -like '*watcher-service.ps1*' -or
          $_.CommandLine -like '*webui.ps1*'
        )
      }
    foreach ($P in $Procs) {
      try { $P | Invoke-CimMethod -MethodName Terminate -ErrorAction SilentlyContinue | Out-Null } catch {}
    }
  } catch {}
}

function Start-BackgroundPowerShell([string]$ScriptPath, [string]$WorkingDirectory) {
  # Plain Start-Process — used only as fallback when Task Scheduler is
  # unavailable. Avoids the WScript.Shell COM pattern that AV products
  # commonly associate with script-based malware.
  $PSExe = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source
  if (-not $PSExe) { $PSExe = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" }
  Start-Process -FilePath $PSExe `
    -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", "`"$ScriptPath`"") `
    -WorkingDirectory $WorkingDirectory -WindowStyle Hidden | Out-Null
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
  Invoke-WebRequest -Uri $ZipUrl -OutFile $ZipPath -UseBasicParsing -TimeoutSec 60
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
  # Also migrate from legacy root location (older installs put it at the root)
  $LegacyRootCT = Join-Path $PermDir "custom-targets.txt"
  if (Test-Path $LegacyRootCT) {
    $LegacyLines = Get-Content $LegacyRootCT | Where-Object { $_ -and !$_.TrimStart().StartsWith("#") }
    if ($LegacyLines) {
      $CustomBackup = if ($CustomBackup) { "$CustomBackup`n$($LegacyLines -join "`n")" } else { $LegacyLines -join "`n" }
    }
    Remove-Item $LegacyRootCT -Force
  }

  # Clean install of _maintenance/. Kill any prior supervisors first so
  # they don't hold file handles to the directory we're about to wipe.
  Stop-StaleEasySkillsProcesses
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

  $ServiceScript     = Join-Path $MaintDir "watcher-service.ps1"
  $WebUIServiceScript = Join-Path $MaintDir "webui-service.ps1"
  $RegisterScript    = Join-Path $MaintDir "register-tasks.ps1"

  # --- Register Windows Scheduled Tasks (THE persistence mechanism) ---
  # Task Scheduler runs the services detached from any console — they
  # survive terminal close, log off/on, and auto-restart on failure.
  $UsedScheduledTasks = $false
  if ((Test-Path $RegisterScript) -and (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue)) {
    try {
      & powershell -NoProfile -ExecutionPolicy Bypass -File $RegisterScript
      $UsedScheduledTasks = $true
      Write-Host "[OK] Background services registered with Task Scheduler." -ForegroundColor Green
    } catch {
      Write-Warning "Scheduled task registration failed, falling back to startup shortcuts: $_"
    }
  }

  if (-not $UsedScheduledTasks) {
    # --- Fallback: legacy startup shortcuts + detached launch ---
    $StartupFolder = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
    try {
      $WshShell = New-Object -ComObject WScript.Shell
      foreach ($Pair in @(
        @{ Path = "$StartupFolder\EasySkillsWatcher.lnk"; Target = $ServiceScript;     Desc = "EasySkills Background Watcher Service" },
        @{ Path = "$StartupFolder\EasySkillsWebUI.lnk";   Target = $WebUIServiceScript; Desc = "EasySkills WebUI Background Service" }
      )) {
        $Sc = $WshShell.CreateShortcut($Pair.Path)
        $Sc.TargetPath = "powershell.exe"
        $Sc.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$($Pair.Target)`""
        $Sc.WorkingDirectory = $MaintDir
        $Sc.WindowStyle = 7
        $Sc.Description = $Pair.Desc
        $Sc.Save()
      }
      Write-Host "[OK] Startup shortcuts installed (fallback)." -ForegroundColor Green
    } catch {
      Write-Warning "Failed to create startup shortcuts: $_"
    }

    try { Start-BackgroundPowerShell $ServiceScript $MaintDir; Write-Host "[OK] Background watcher started." -ForegroundColor Green }
    catch { Write-Warning "Failed to start watcher: $_" }

    try { Start-BackgroundPowerShell $WebUIServiceScript $MaintDir; Write-Host "[OK] WebUI launching." -ForegroundColor Green }
    catch { Write-Warning "Failed to start WebUI: $_" }
  }

  # --- Wait for the WebUI port to come up, then open the browser ---
  $PortReady = $false
  for ($i = 0; $i -lt 20; $i++) {
    $Test = New-Object System.Net.Sockets.TcpClient
    try {
      $Async = $Test.BeginConnect("127.0.0.1", 6633, $null, $null)
      if ($Async.AsyncWaitHandle.WaitOne(500, $false)) {
        try { $Test.EndConnect($Async); $PortReady = $true } catch {}
      }
    } catch {} finally { try { $Test.Close() } catch {} }
    if ($PortReady) { break }
    Start-Sleep -Milliseconds 500
  }
  if ($PortReady) {
    Write-Host "[OK] WebUI is listening on http://localhost:6633" -ForegroundColor Green
    try { Start-Process "http://localhost:6633" } catch { Write-Warning "Could not open browser: $_" }
  } else {
    Write-Warning "WebUI did not come up within 10s; it should appear shortly."
  }

  Write-Host "=============================================" -ForegroundColor Cyan
  Write-Host "EasySkills installed successfully!" -ForegroundColor Green
  Write-Host "Drop your custom skills into: $PermDir" -ForegroundColor Green
  Write-Host "=============================================" -ForegroundColor Cyan

} finally {
  Cleanup
}
