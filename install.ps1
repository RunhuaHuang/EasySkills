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
  # EasySkills维护工具/.engine folder isn't held open by a running powershell.exe when we
  # try to overwrite it. Matches by command-line via WMI, then waits up to
  # 5 seconds for the OS to release the file handles.
  try {
    $EasySkillsPath = "$env:USERPROFILE\EasySkills"
    $Procs = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
      Where-Object {
        $_.CommandLine -and (
          ($_.CommandLine -like "*$EasySkillsPath*webui-service.ps1*") -or
          ($_.CommandLine -like "*$EasySkillsPath*watcher-service.ps1*") -or
          ($_.CommandLine -like "*$EasySkillsPath*webui.ps1*")
        )
      }
    $KilledPids = @()
    foreach ($P in $Procs) {
      try {
        $P | Invoke-CimMethod -MethodName Terminate -ErrorAction SilentlyContinue | Out-Null
        $KilledPids += $P.ProcessId
      } catch {}
    }
    if ($KilledPids.Count -gt 0) {
      $Deadline = (Get-Date).AddSeconds(5)
      while ((Get-Date) -lt $Deadline) {
        $StillAlive = $KilledPids | Where-Object {
          try { Get-Process -Id $_ -ErrorAction Stop | Out-Null; $true } catch { $false }
        }
        if (-not $StillAlive) { break }
        Start-Sleep -Milliseconds 200
      }
    }
  } catch {}
}

function Start-BackgroundPowerShell([string]$ScriptPath, [string]$WorkingDirectory) {
  # Fallback launcher used only when Task Scheduler is unavailable.
  # Prefer wscript.exe + run-hidden.vbs because wscript.exe is GUI-subsystem
  # and creates no console window. Fall back to plain Start-Process if the
  # bootstrap .vbs is missing.
  $LauncherVbs = Join-Path $WorkingDirectory "run-hidden.vbs"
  $WscriptExe  = "$env:WINDIR\System32\wscript.exe"
  if ((Test-Path $LauncherVbs) -and (Test-Path $WscriptExe)) {
    Start-Process -FilePath $WscriptExe `
      -ArgumentList @("`"$LauncherVbs`"", "`"$ScriptPath`"") `
      -WorkingDirectory $WorkingDirectory -WindowStyle Hidden | Out-Null
    return
  }
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
  # Multi-source with auto-fallback: GitHub is tried first; on failure/timeout
  # we walk a list of China-friendly mirrors so users behind the GFW aren't
  # blocked. A mirror can be pinned with $env:EASYSKILLS_MIRROR (a URL prefix
  # prepended to the github.com URL). Mirror URLs change frequently, so we probe
  # rather than trust any single host.
  Write-Host "Downloading EasySkills..."
  New-Item -ItemType Directory -Path $TmpDir -Force | Out-Null
  $ZipPath = Join-Path $TmpDir "repo.zip"
  $ArchivePath = "/$Repo/archive/refs/heads/$Branch.zip"
  # GitHub native goes first; then China-friendly mirror proxies.
  $MirrorPrefixes = @("", "https://ghfast.top", "https://gh-proxy.com", "https://github.moeyy.xyz")
  # A user-pinned mirror always wins (replaces the whole list).
  if ($env:EASYSKILLS_MIRROR) { $MirrorPrefixes = @($env:EASYSKILLS_MIRROR) }

  $Downloaded = $false
  foreach ($Prefix in $MirrorPrefixes) {
    # Empty prefix = GitHub native; mirror proxies prepend themselves to the
    # full github.com URL. Without this special case the empty prefix would
    # produce a host-less "/RunhuaHuang/..." URL that Invoke-WebRequest rejects.
    if ($Prefix) {
      $ZipUrl = "${Prefix}/https://github.com${ArchivePath}"
    } else {
      $ZipUrl = "https://github.com${ArchivePath}"
    }
    try {
      Invoke-WebRequest -Uri $ZipUrl -OutFile $ZipPath -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
      Expand-Archive -Path $ZipPath -DestinationPath $TmpDir -Force -ErrorAction Stop
      $Downloaded = $true
      break
    } catch {
      # This source failed; silently try the next mirror.
    }
  }
  if (-not $Downloaded) {
    throw "Could not download EasySkills from GitHub or any mirror. Check your network, or pin a mirror with: `$env:EASYSKILLS_MIRROR='https://ghfast.top'"
  }
  $SrcDir = Join-Path $TmpDir "EasySkills-$Branch"

  # --- Install ---
  if (!(Test-Path $PermDir)) { New-Item -ItemType Directory -Path $PermDir -Force | Out-Null }

  # Preserve old version for upgrade reporting
  $OldVersion = $null
  $VersionFile = Join-Path $PermDir "EasySkills维护工具/.engine\.version"
  if (Test-Path $VersionFile) { $OldVersion = (Get-Content $VersionFile -Raw).Trim() }

  # Preserve user custom-targets.txt before wiping EasySkills维护工具/.engine/
  $MaintDir = Join-Path $PermDir "EasySkills维护工具/.engine"
  $CustomFile = Join-Path $MaintDir "custom-targets.txt"
  $CustomBackup = $null
  if (Test-Path $CustomFile) {
    $CustomBackup = Get-Content $CustomFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
  }
  # Preserve other per-machine runtime files (unmapped targets + WebUI token).
  # Copy verbatim to a temp dir so the token keeps its exact bytes/encoding.
  $DisabledFile = Join-Path $MaintDir "disabled-targets.txt"
  $TokenFile = Join-Path $MaintDir ".easyskills-token"
  $PreserveDir = Join-Path ([System.IO.Path]::GetTempPath()) ("easyskills-preserve-" + [Guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $PreserveDir -Force | Out-Null
  if (Test-Path $DisabledFile) { Copy-Item $DisabledFile (Join-Path $PreserveDir "disabled-targets.txt") -Force }
  if (Test-Path $TokenFile) { Copy-Item $TokenFile (Join-Path $PreserveDir ".easyskills-token") -Force }
  # Also migrate from legacy root location (older installs put it at the root)
  $LegacyRootCT = Join-Path $PermDir "custom-targets.txt"
  if (Test-Path $LegacyRootCT) {
    $LegacyLines = Get-Content $LegacyRootCT | Where-Object { $_ -and !$_.TrimStart().StartsWith("#") }
    if ($LegacyLines) {
      $CustomBackup = if ($CustomBackup) { "$CustomBackup`n$($LegacyLines -join "`n")" } else { $LegacyLines -join "`n" }
    }
    Remove-Item $LegacyRootCT -Force
  }
  # Migrate user config from a legacy _maintenance install (pre-4.1.0 directory
  # rename) when the new paths are absent. Keeps the upgrade non-destructive.
  $LegacyMaint = Join-Path $PermDir "_maintenance"
  if (-not $CustomBackup) {
    $LegacyCustom = Join-Path $LegacyMaint "custom-targets.txt"
    if (Test-Path $LegacyCustom) { $CustomBackup = Get-Content $LegacyCustom -Raw -Encoding UTF8 -ErrorAction SilentlyContinue }
  }
  if (-not (Test-Path $DisabledFile)) {
    $LegacyDisabled = Join-Path $LegacyMaint "disabled-targets.txt"
    if (Test-Path $LegacyDisabled) { Copy-Item $LegacyDisabled $DisabledFile -Force -ErrorAction SilentlyContinue }
  }
  if (-not (Test-Path $TokenFile)) {
    $LegacyToken = Join-Path $LegacyMaint ".easyskills-token"
    if (Test-Path $LegacyToken) { Copy-Item $LegacyToken $TokenFile -Force -ErrorAction SilentlyContinue }
  }

  # Clean install of EasySkills维护工具/.engine/. Kill any prior supervisors first so
  # they don't hold file handles to the directory we're about to swap.
  Stop-StaleEasySkillsProcesses

  # Validate the downloaded source before touching the existing install — a
  # failed download/extract must NOT brick a working install.
  $SrcMaint = Join-Path $SrcDir "EasySkills维护工具/.engine"
  $SrcDeploy = Join-Path $SrcMaint "deploy.ps1"
  $SrcReadme = Join-Path $SrcDir "EasySkills维护工具/README_SYSTEM.md"
  if (-not (Test-Path $SrcMaint) -or -not (Test-Path $SrcDeploy) -or -not (Test-Path $SrcReadme)) {
    throw "Downloaded source EasySkills维护工具/.engine/ is missing or incomplete (network/GitHub failure?). Existing install left untouched."
  }

  # Atomic install: copy into a sibling temp dir, verify, then swap via rename.
  # Avoids the previous "Remove-Item then Copy-Item" footgun where a failed
  # copy left no EasySkills维护工具/.engine at all.
  $NewMaint = Join-Path $PermDir "EasySkills维护工具/.engine.new"
  if (Test-Path $NewMaint) { Remove-Item $NewMaint -Recurse -Force }
  Copy-Item -Path $SrcMaint -Destination $NewMaint -Recurse
  $NewDeploy = Join-Path $NewMaint "deploy.ps1"
  if (-not (Test-Path $NewDeploy)) {
    if (Test-Path $NewMaint) { Remove-Item $NewMaint -Recurse -Force }
    throw "Copy of EasySkills维护工具/.engine/ failed (disk full? permissions?). Existing install left untouched."
  }
  # Swap with rollback: current -> .bak, new -> current. Avoid a window where a
  # failed rename leaves no usable EasySkills维护工具/.engine at all. Use
  # Move-Item (not Rename-Item) for the .engine -> .maintenance-bak step:
  # Rename-Item only changes the leaf name, so it would leave the backup nested
  # inside EasySkills维护工具\ instead of at $PermDir (mismatching $BackupMaint,
  # which would then break the rollback path below).
  $BackupMaint = Join-Path $PermDir ".maintenance-bak"
  $PrevBackup = Join-Path $PermDir ".maintenance-bak.prev"
  if (Test-Path $PrevBackup) { Remove-Item $PrevBackup -Recurse -Force }
  try {
    if (Test-Path $MaintDir) {
      if (Test-Path $BackupMaint) {
        Move-Item -Path $BackupMaint -Destination $PrevBackup -Force
      }
      Move-Item -Path $MaintDir -Destination $BackupMaint -Force
    }
    Move-Item -Path $NewMaint -Destination $MaintDir -Force
    if (Test-Path $PrevBackup) { Remove-Item $PrevBackup -Recurse -Force }
  } catch {
    if (Test-Path $NewMaint) { Remove-Item $NewMaint -Recurse -Force -ErrorAction SilentlyContinue }
    if ((-not (Test-Path $MaintDir)) -and (Test-Path $BackupMaint)) {
      Move-Item -Path $BackupMaint -Destination $MaintDir -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $PrevBackup) {
      if (-not (Test-Path $BackupMaint)) {
        Move-Item -Path $PrevBackup -Destination $BackupMaint -Force -ErrorAction SilentlyContinue
      } else {
        Remove-Item $PrevBackup -Recurse -Force -ErrorAction SilentlyContinue
      }
    }
    throw "Install swap failed; previous EasySkills维护工具/.engine was restored where possible. $($_.Exception.Message)"
  }
  Copy-Item -Path $SrcReadme -Destination (Join-Path $PermDir "EasySkills维护工具/README_SYSTEM.md") -Force
  # Remove legacy SKILL.md left by older installations to avoid ambiguity
  $LegacySkillMd = Join-Path $PermDir "SKILL.md"
  if (Test-Path $LegacySkillMd) { Remove-Item $LegacySkillMd -Force }

  # After the swap, $MaintDir now points at the OLD tree (renamed to
  # .maintenance-bak), while the LIVE engine lives at $NewMaint's original
  # path. Re-point $MaintDir at the live tree so every subsequent reference
  # (restore, MCP template, gateway installer, version, deploy.ps1, service
  # scripts) targets the newly installed directory instead of the backup.
  $MaintDir = $NewMaint

  # Restore user custom-targets.txt
  if ($CustomBackup) {
    $CustomBackup | Set-Content -Path $CustomFile -Encoding UTF8 -Force
  }
  # Restore other preserved runtime files (verbatim)
  $PreservedDisabled = Join-Path $PreserveDir "disabled-targets.txt"
  if (Test-Path $PreservedDisabled) { Copy-Item $PreservedDisabled $DisabledFile -Force }
  $PreservedToken = Join-Path $PreserveDir ".easyskills-token"
  if (Test-Path $PreservedToken) { Copy-Item $PreservedToken $TokenFile -Force }
  Remove-Item $PreserveDir -Recurse -Force -ErrorAction SilentlyContinue

  # Initialize the user-owned MCP JSON once; upgrades never overwrite it.
  $MCPDir = Join-Path $PermDir "mcp"
  $MCPConfig = Join-Path $MCPDir "servers.json"
  $MCPTemplate = Join-Path $MaintDir "mcp-servers.template.json"
  if (-not (Test-Path $MCPDir)) { New-Item -ItemType Directory -Path $MCPDir -Force | Out-Null }
  if ((-not (Test-Path $MCPConfig)) -and (Test-Path $MCPTemplate)) {
    Copy-Item $MCPTemplate $MCPConfig -Force
  }

  # Install the optional single-file MCP Gateway. Failure is non-fatal.
  $GatewayInstaller = Join-Path $MaintDir "install-gateway.ps1"
  if (Test-Path $GatewayInstaller) {
    try { & powershell -NoProfile -ExecutionPolicy Bypass -File $GatewayInstaller -SourceDir (Join-Path $SrcDir "gateway") }
    catch { Write-Warning "MCP Gateway install skipped: $_" }
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
      # register-tasks.ps1 runs as a child process, so a terminating error
      # inside it does NOT surface as a catchable exception here — it only
      # sets $LASTEXITCODE. Check the exit code explicitly, otherwise a failed
      # registration would be silently reported as success and the startup
      # shortcut fallback would never kick in.
      & powershell -NoProfile -ExecutionPolicy Bypass -File $RegisterScript
      if ($LASTEXITCODE -ne 0) {
        throw "register-tasks.ps1 exited with code $LASTEXITCODE"
      }
      $UsedScheduledTasks = $true
      Write-Host "[OK] Background services registered with Task Scheduler." -ForegroundColor Green
    } catch {
      Write-Warning "Scheduled task registration failed, falling back to startup shortcuts: $_"
    }
  }

  if (-not $UsedScheduledTasks) {
    # --- Fallback: startup shortcuts pointing at wscript.exe + run-hidden.vbs
    #     so the fallback path also has zero visible windows. -----------
    $StartupFolder = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
    $LauncherVbs = Join-Path $MaintDir "run-hidden.vbs"
    $WscriptExe  = "$env:WINDIR\System32\wscript.exe"
    try {
      $WshShell = New-Object -ComObject WScript.Shell
      foreach ($Pair in @(
        @{ Path = "$StartupFolder\EasySkillsWatcher.lnk"; Target = $ServiceScript;     Desc = "EasySkills Background Watcher Service" },
        @{ Path = "$StartupFolder\EasySkillsWebUI.lnk";   Target = $WebUIServiceScript; Desc = "EasySkills WebUI Background Service" }
      )) {
        $Sc = $WshShell.CreateShortcut($Pair.Path)
        $Sc.TargetPath = $WscriptExe
        $Sc.Arguments  = "`"$LauncherVbs`" `"$($Pair.Target)`""
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

  # --- Remove legacy _maintenance/_runtime dirs (pre-4.1.0 installs) ---
  # The Scheduled Tasks above were re-registered against EasySkills维护工具/.engine;
  # the old trees are no longer referenced and their runtime config was
  # migrated earlier. Removing them prevents a stale watcher from double-syncing.
  $LegacyMaint = Join-Path $PermDir "_maintenance"
  if ((Test-Path $LegacyMaint) -and (Test-Path (Join-Path $LegacyMaint "deploy.ps1"))) {
    Write-Host "Removing legacy _maintenance/ directory (config already migrated)..."
    try { Remove-Item $LegacyMaint -Recurse -Force -ErrorAction Stop } catch { Write-Warning "Could not remove legacy _maintenance/: $_" }
  }
  $LegacyRuntime = Join-Path $PermDir "_runtime"
  if (Test-Path $LegacyRuntime) {
    Write-Host "Removing legacy _runtime/ directory (gateway re-installed above)..."
    try { Remove-Item $LegacyRuntime -Recurse -Force -ErrorAction Stop } catch { Write-Warning "Could not remove legacy _runtime/: $_" }
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
