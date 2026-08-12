# ==============================================================================
# Script: install.ps1 (Windows remote installer)
# Usage:  irm https://raw.githubusercontent.com/RunhuaHuang/EasySkills/main/install.ps1 | iex
# ==============================================================================

$ErrorActionPreference = "Stop"

$Repo = "RunhuaHuang/EasySkills"
$DefaultVersion = "4.1.0"
$InstallChannel = if ($env:EASYSKILLS_CHANNEL) { $env:EASYSKILLS_CHANNEL.ToLowerInvariant() } else { "stable" }
if ($InstallChannel -eq "stable") {
  $InstallVersion = if ($env:EASYSKILLS_VERSION) { $env:EASYSKILLS_VERSION } else { $DefaultVersion }
  if ($InstallVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?$') {
    throw "Invalid EASYSKILLS_VERSION '$InstallVersion' (expected SemVer, e.g. 4.1.0)."
  }
  $GitRef = "v$InstallVersion"
  $ArchiveRef = "tags/$GitRef"
} elseif ($InstallChannel -eq "edge") {
  $GitRef = "main"
  $ArchiveRef = "heads/main"
} else {
  throw "EASYSKILLS_CHANNEL must be 'stable' or 'edge'."
}
$PermDir = "$env:USERPROFILE\EasySkills"
$TmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "EasySkills-install-$(Get-Random)"
$PreserveDir = $null

function Cleanup {
  if (Test-Path $TmpDir) { Remove-Item $TmpDir -Recurse -Force -ErrorAction SilentlyContinue }
  if ($PreserveDir -and (Test-Path $PreserveDir)) { Remove-Item $PreserveDir -Recurse -Force -ErrorAction SilentlyContinue }
}

function Save-BoundedWebFile(
  [string]$Uri,
  [string]$Path,
  [long]$MaxBytes,
  [string]$LimitMessage,
  [int]$TimeoutSeconds = 30,
  [hashtable]$Headers = @{},
  [string[]]$AllowedFinalHosts = @()
) {
  Add-Type -AssemblyName System.Net.Http
  $Handler = [System.Net.Http.HttpClientHandler]::new()
  $Handler.AllowAutoRedirect = $true
  $Handler.MaxAutomaticRedirections = 5
  $Client = [System.Net.Http.HttpClient]::new($Handler)
  $Client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
  $Request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, [System.Uri]$Uri)
  foreach ($Header in $Headers.GetEnumerator()) {
    [void]$Request.Headers.TryAddWithoutValidation([string]$Header.Key, [string]$Header.Value)
  }
  try {
    $Response = $Client.SendAsync(
      $Request,
      [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
    ).GetAwaiter().GetResult()
    try {
      if (-not $Response.IsSuccessStatusCode) {
        throw "Download failed with HTTP status $([int]$Response.StatusCode)."
      }
      $FinalUri = $Response.RequestMessage.RequestUri
      if (-not $FinalUri -or $FinalUri.Scheme -ne "https") {
        throw "Download redirected to a non-HTTPS URL."
      }
      if (-not [string]::IsNullOrEmpty($FinalUri.UserInfo)) {
        throw "Download redirected to a URL containing userinfo."
      }
      if ($AllowedFinalHosts.Count -gt 0 -and -not $FinalUri.IsDefaultPort -and $FinalUri.Port -ne 443) {
        throw "Download redirected to a non-default HTTPS port."
      }
      if ($AllowedFinalHosts.Count -gt 0 -and $AllowedFinalHosts -notcontains $FinalUri.Host.ToLowerInvariant()) {
        throw "Download redirected to an untrusted host: $($FinalUri.Host)"
      }
      $DeclaredLength = $Response.Content.Headers.ContentLength
      if ($null -ne $DeclaredLength -and [long]$DeclaredLength -gt $MaxBytes) {
        throw $LimitMessage
      }
      $InputStream = $Response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
      $OutputStream = [System.IO.File]::Open(
        $Path,
        [System.IO.FileMode]::Create,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None
      )
      try {
        $Buffer = New-Object byte[] 65536
        [long]$Written = 0
        while (($Read = $InputStream.Read($Buffer, 0, $Buffer.Length)) -gt 0) {
          $Written += $Read
          if ($Written -gt $MaxBytes) { throw $LimitMessage }
          $OutputStream.Write($Buffer, 0, $Read)
        }
        $OutputStream.Flush($true)
      } finally {
        $OutputStream.Dispose()
        $InputStream.Dispose()
      }
      return $FinalUri.AbsoluteUri
    } finally {
      $Response.Dispose()
    }
  } catch {
    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    throw
  } finally {
    $Request.Dispose()
    $Client.Dispose()
    $Handler.Dispose()
  }
}

function Normalize-ZipPath([string]$Name) {
  if (-not $Name -or $Name.Contains([char]0)) {
    throw "Downloaded archive contains an invalid path."
  }
  if ($Name.StartsWith('/') -or $Name.StartsWith('\') -or $Name -match '^[A-Za-z]:') {
    throw "Downloaded archive contains an unsafe path: $Name"
  }
  $Parts = $Name.Replace('\', '/').Split('/')
  $Stack = New-Object System.Collections.Generic.List[string]
  foreach ($Part in $Parts) {
    if (-not $Part -or $Part -eq '.') { continue }
    if ($Part -eq '..') {
      if ($Stack.Count -eq 0) { throw "Downloaded archive contains an unsafe path: $Name" }
      [void]$Stack.RemoveAt($Stack.Count - 1)
      continue
    }
    if ($Part.Contains(':')) { throw "Downloaded archive contains an unsafe path: $Name" }
    [void]$Stack.Add($Part)
  }
  return ($Stack -join '/')
}

function Resolve-ZipVirtualPath([string]$PathName, [hashtable]$Links, [bool]$FollowFinal = $true) {
  $Current = Normalize-ZipPath $PathName
  $Visited = @{}
  for ($Round = 0; $Round -lt 64; $Round++) {
    $Parts = if ($Current) { $Current.Split('/') } else { @() }
    $Replaced = $false
    for ($Index = 1; $Index -le $Parts.Count; $Index++) {
      $Prefix = ($Parts[0..($Index - 1)] -join '/')
      if (-not $Links.ContainsKey($Prefix) -or (-not $FollowFinal -and $Index -eq $Parts.Count)) { continue }
      if ($Visited.ContainsKey($Prefix)) { throw "Downloaded archive contains a cyclic link: $Prefix" }
      $Target = [string]$Links[$Prefix]
      if ($Target.StartsWith('/') -or $Target.StartsWith('\') -or $Target -match '^[A-Za-z]:') {
        throw "Downloaded archive contains an unsafe link: $Prefix"
      }
      $Base = if ($Index -gt 1) { ($Parts[0..($Index - 2)] -join '/') } else { '' }
      $Joined = if ($Base) { "$Base/$Target" } else { $Target }
      $Replacement = Normalize-ZipPath $Joined
      $Rest = if ($Index -lt $Parts.Count) { ($Parts[$Index..($Parts.Count - 1)] -join '/') } else { '' }
      $Current = if ($Rest) { Normalize-ZipPath "$Replacement/$Rest" } else { $Replacement }
      $Visited[$Prefix] = $true
      $Replaced = $true
      break
    }
    if (-not $Replaced) { return $Current }
  }
  throw "Downloaded archive contains an excessively deep link chain."
}

function Assert-SafeZipArchive([string]$ZipPath, [string]$DestinationPath) {
  # Expand-Archive behavior differs across Windows PowerShell/.NET releases.
  # Validate the central directory ourselves before extraction so a malicious
  # or corrupted mirror response cannot escape the temporary directory or
  # expand into an unbounded archive bomb.
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $Archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
  try {
    if ($Archive.Entries.Count -gt 10000) {
      throw "Downloaded archive contains too many entries."
    }
    [long]$ExpandedBytes = 0
    $DestinationRoot = [System.IO.Path]::GetFullPath($DestinationPath).TrimEnd('\') + '\'
    $Seen = @{}
    $Links = @{}
    foreach ($Entry in $Archive.Entries) {
      $ExpandedBytes += [long]$Entry.Length
      if ($ExpandedBytes -gt 536870912) {
        throw "Downloaded archive exceeds the 512 MB extracted-size safety limit."
      }
      $NormalizedName = Normalize-ZipPath $Entry.FullName
      if (-not $NormalizedName -or $Seen.ContainsKey($NormalizedName)) {
        throw "Downloaded archive contains a duplicate path: $($Entry.FullName)"
      }
      $Seen[$NormalizedName] = $true
      # GitHub ZIP archives preserve Unix symlinks in ExternalAttributes. Read
      # their relative target and include it in the virtual graph so a later
      # member cannot escape through a link declared earlier or later.
      $UnixType = (([uint64]$Entry.ExternalAttributes -shr 16) -band 0xF000)
      if ($UnixType -eq 0xA000) {
        $LinkStream = $Entry.Open()
        try {
          $Reader = [System.IO.StreamReader]::new($LinkStream, [System.Text.UTF8Encoding]::new($false), $true)
          try { $LinkTarget = $Reader.ReadToEnd() } finally { $Reader.Dispose() }
        } finally { $LinkStream.Dispose() }
        if (-not $LinkTarget) { throw "Downloaded archive contains an empty symbolic link: $($Entry.FullName)" }
        $Links[$NormalizedName] = $LinkTarget.TrimEnd([char]0, "`r", "`n")
      }
      $EntryPath = [System.IO.Path]::GetFullPath((Join-Path $DestinationPath $NormalizedName))
      if (-not $EntryPath.StartsWith($DestinationRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Downloaded archive contains an unsafe path: $($Entry.FullName)"
      }
    }
    foreach ($Name in @($Seen.Keys)) {
      [void](Resolve-ZipVirtualPath $Name $Links $true)
    }
  } finally {
    $Archive.Dispose()
  }
}

function Get-InstallerTargetKey([string]$Line) {
  $Stripped = if ($null -eq $Line) { '' } else { $Line.Trim() }
  if (-not $Stripped -or $Stripped.StartsWith('#')) { return '' }
  if ($Stripped.Contains('=')) {
    $Parts = $Stripped.Split('=', 2)
    $Prefix = $Parts[0].Trim()
    $Candidate = $Parts[1].Trim()
    $CandidateLooksLikePath = $Candidate.StartsWith('/') -or $Candidate.StartsWith('\') -or
      $Candidate.StartsWith('~') -or $Candidate.StartsWith('.') -or $Candidate.Contains('/') -or
      $Candidate.Contains('\') -or $Candidate -match '^[A-Za-z]:[\\/]'
    $PrefixLooksLikePath = $Prefix.StartsWith('/') -or $Prefix.StartsWith('\') -or
      $Prefix.StartsWith('~') -or $Prefix.StartsWith('.') -or $Prefix.Contains('/') -or
      $Prefix.Contains('\') -or $Prefix -match '^[A-Za-z]:[\\/]'
    if ($Prefix -and $CandidateLooksLikePath -and -not $PrefixLooksLikePath) {
      $Stripped = $Candidate
    }
  }
  if ($Stripped.StartsWith('~')) { $Stripped = Join-Path $Home $Stripped.Substring(1) }
  try {
    if (Test-Path -LiteralPath $Stripped -PathType Container) {
      return (Get-Item -LiteralPath $Stripped -Force).FullName
    }
    return [System.IO.Path]::GetFullPath($Stripped)
  } catch {
    return $Stripped
  }
}

function Append-Utf8LinePreservingContent([string]$Path, [string]$Line) {
  $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  if (Test-Path -LiteralPath $Path) {
    $Bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($Bytes.Length -gt 0 -and $Bytes[$Bytes.Length - 1] -ne 10 -and $Bytes[$Bytes.Length - 1] -ne 13) {
      [System.IO.File]::AppendAllText($Path, "`r`n", $Utf8NoBom)
    }
  }
  [System.IO.File]::AppendAllText($Path, $Line + "`r`n", $Utf8NoBom)
}

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
  # GitHub is the only implicit source. A third-party mirror changes the source
  # trust boundary, so it is used only when the user explicitly selects one via
  # $env:EASYSKILLS_MIRROR (an HTTPS URL prefix prepended to github.com URLs).
  Write-Host "Downloading EasySkills ($InstallChannel`: $GitRef)..."
  New-Item -ItemType Directory -Path $TmpDir -Force | Out-Null
  $ZipPath = Join-Path $TmpDir "repo.zip"
  $ArchivePath = "/$Repo/archive/refs/$ArchiveRef.zip"
  $MirrorPrefixes = @("")
  if ($env:EASYSKILLS_MIRROR) {
    try { $MirrorUri = [System.Uri]$env:EASYSKILLS_MIRROR } catch { throw "EASYSKILLS_MIRROR must be an explicit HTTPS URL prefix." }
    if (-not $MirrorUri.IsAbsoluteUri -or $MirrorUri.Scheme -ne "https") {
      throw "EASYSKILLS_MIRROR must be an explicit HTTPS URL prefix."
    }
    $MirrorPrefixes = @($env:EASYSKILLS_MIRROR.TrimEnd('/'))
  }

  $Downloaded = $false
  foreach ($Prefix in $MirrorPrefixes) {
    # A failed expansion can leave a partial EasySkills-* directory that would
    # otherwise be mistaken for the next mirror's source tree.
    Get-ChildItem -LiteralPath $TmpDir -Directory -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -like "EasySkills-*" } |
      Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force -ErrorAction SilentlyContinue }
    # Empty prefix = GitHub native; mirror proxies prepend themselves to the
    # full github.com URL. Without this special case the empty prefix would
    # produce a host-less "/RunhuaHuang/..." URL that Invoke-WebRequest rejects.
    if ($Prefix) {
      $ZipUrl = "${Prefix}/https://github.com${ArchivePath}"
    } else {
      $ZipUrl = "https://github.com${ArchivePath}"
    }
    try {
      $AllowedFinalHosts = if ($Prefix) { @() } else { @("github.com", "api.github.com", "codeload.github.com", "objects.githubusercontent.com") }
      Save-BoundedWebFile `
        -Uri $ZipUrl `
        -Path $ZipPath `
        -MaxBytes 104857600 `
        -LimitMessage "Downloaded archive exceeds the 100 MB safety limit." `
        -AllowedFinalHosts $AllowedFinalHosts `
        -TimeoutSeconds 30 | Out-Null
      Assert-SafeZipArchive $ZipPath $TmpDir
      Expand-Archive -Path $ZipPath -DestinationPath $TmpDir -Force -ErrorAction Stop
      $Downloaded = $true
      break
    } catch {
      # This source failed; silently try the next mirror.
    }
  }
  if (-not $Downloaded) {
    throw "Could not download EasySkills from GitHub or the explicitly configured mirror. Check your network, or explicitly trust one with: `$env:EASYSKILLS_MIRROR='https://ghfast.top'"
  }
  $SourceRoots = @(Get-ChildItem -LiteralPath $TmpDir -Directory -ErrorAction Stop |
    Where-Object {
      $_.Name -like "EasySkills-*" -and
      (Test-Path (Join-Path $_.FullName "EasySkills维护工具/.engine") -PathType Container)
    })
  if ($SourceRoots.Count -eq 0) { throw "Downloaded archive did not contain an EasySkills source directory." }
  if ($SourceRoots.Count -ne 1) {
    $SourceNames = (($SourceRoots | ForEach-Object { $_.Name }) -join ', ')
    throw "Downloaded archive contains multiple EasySkills source directories: $SourceNames."
  }
  $SrcDir = $SourceRoots[0].FullName

  # Validate the selected source before changing the existing install or
  # stopping its background services.
  $SrcMaint = Join-Path $SrcDir "EasySkills维护工具/.engine"
  $SrcDeploy = Join-Path $SrcMaint "deploy.ps1"
  $SrcReadme = Join-Path $SrcDir "EasySkills维护工具/README_SYSTEM.md"
  $SrcVersionFile = Join-Path $SrcMaint ".version"
  if (-not (Test-Path $SrcMaint) -or -not (Test-Path $SrcDeploy) -or -not (Test-Path $SrcReadme) -or -not (Test-Path $SrcVersionFile)) {
    throw "Downloaded source EasySkills维护工具/.engine/ is missing or incomplete (network/GitHub failure?). Existing install left untouched."
  }
  if ($InstallChannel -eq "stable") {
    $SourceVersion = (Get-Content $SrcVersionFile -Raw -Encoding UTF8).Trim()
    if ($SourceVersion -ne $InstallVersion) {
      throw "Downloaded source version '$SourceVersion' does not match requested version '$InstallVersion'. Existing install left untouched."
    }
  }

  # --- Install ---
  if (!(Test-Path $PermDir)) { New-Item -ItemType Directory -Path $PermDir -Force | Out-Null }

  # Preserve old version for upgrade reporting
  $OldVersion = $null
  $VersionFile = Join-Path $PermDir "EasySkills维护工具/.engine\.version"
  if (Test-Path $VersionFile) { $OldVersion = (Get-Content $VersionFile -Raw).Trim() }

  # Preserve user custom-targets.txt before wiping EasySkills维护工具/.engine/
  $MaintDir = Join-Path $PermDir "EasySkills维护工具/.engine"
  $CustomFile = Join-Path $MaintDir "custom-targets.txt"
  # Preserve other per-machine runtime files (unmapped targets + WebUI token).
  # Copy every runtime file verbatim to a temp dir so paths, line endings and
  # the token keep their exact bytes/encoding.
  $DisabledFile = Join-Path $MaintDir "disabled-targets.txt"
  $TokenFile = Join-Path $MaintDir ".easyskills-token"
  $PreserveDir = Join-Path ([System.IO.Path]::GetTempPath()) ("easyskills-preserve-" + [Guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $PreserveDir -Force | Out-Null
  $PreservedCustom = Join-Path $PreserveDir "custom-targets.txt"
  $PreservedDisabled = Join-Path $PreserveDir "disabled-targets.txt"
  $PreservedToken = Join-Path $PreserveDir ".easyskills-token"
  if (Test-Path $CustomFile) { Copy-Item $CustomFile $PreservedCustom -Force }
  if (Test-Path $DisabledFile) { Copy-Item $DisabledFile $PreservedDisabled -Force }
  if (Test-Path $TokenFile) { Copy-Item $TokenFile $PreservedToken -Force }
  # Also migrate from legacy root location (older installs put it at the root)
  $LegacyRootCT = Join-Path $PermDir "custom-targets.txt"
  $LegacyLines = @()
  if (Test-Path $LegacyRootCT) {
    $LegacyLines = Get-Content $LegacyRootCT | Where-Object { $_ -and !$_.TrimStart().StartsWith("#") }
  }
  # Migrate user config from a legacy _maintenance install (pre-4.1.0 directory
  # rename) when the new paths are absent. Keeps the upgrade non-destructive.
  $LegacyMaint = Join-Path $PermDir "_maintenance"
  if (-not (Test-Path $PreservedCustom)) {
    $LegacyCustom = Join-Path $LegacyMaint "custom-targets.txt"
    if (Test-Path $LegacyCustom) { Copy-Item $LegacyCustom $PreservedCustom -Force }
  }
  if (-not (Test-Path $PreservedDisabled)) {
    $LegacyDisabled = Join-Path $LegacyMaint "disabled-targets.txt"
    if (Test-Path $LegacyDisabled) { Copy-Item $LegacyDisabled $PreservedDisabled -Force }
  }
  if (-not (Test-Path $PreservedToken)) {
    $LegacyToken = Join-Path $LegacyMaint ".easyskills-token"
    if (Test-Path $LegacyToken) { Copy-Item $LegacyToken $PreservedToken -Force }
  }

  # Clean install of EasySkills维护工具/.engine/. Kill any prior supervisors first so
  # they don't hold file handles to the directory we're about to swap.
  Stop-StaleEasySkillsProcesses

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

  # Stage all runtime state before the rename so a successful swap always
  # exposes a complete engine, even if a later launcher/service step fails.
  $NewCustomFile = Join-Path $NewMaint "custom-targets.txt"
  $NewDisabledFile = Join-Path $NewMaint "disabled-targets.txt"
  $NewTokenFile = Join-Path $NewMaint ".easyskills-token"
  if (Test-Path $PreservedCustom) { Copy-Item $PreservedCustom $NewCustomFile -Force }
  elseif (Test-Path $NewCustomFile) { Remove-Item $NewCustomFile -Force }
  $ExistingCustomLines = if (Test-Path $NewCustomFile) { @(Get-Content $NewCustomFile -Encoding UTF8) } else { @() }
  $ExistingTargetKeys = @{}
  foreach ($ExistingLine in @($ExistingCustomLines)) {
    $ExistingKey = Get-InstallerTargetKey ([string]$ExistingLine)
    if ($ExistingKey) { $ExistingTargetKeys[$ExistingKey] = $true }
  }
  foreach ($Line in @($LegacyLines)) {
    $LegacyKey = Get-InstallerTargetKey ([string]$Line)
    if ($LegacyKey -and $ExistingTargetKeys.ContainsKey($LegacyKey)) { continue }
    Append-Utf8LinePreservingContent $NewCustomFile ([string]$Line)
    $ExistingCustomLines += [string]$Line
    if ($LegacyKey) { $ExistingTargetKeys[$LegacyKey] = $true }
  }
  if (Test-Path $PreservedDisabled) { Copy-Item $PreservedDisabled $NewDisabledFile -Force }
  elseif (Test-Path $NewDisabledFile) { Remove-Item $NewDisabledFile -Force }
  if (Test-Path $PreservedToken) { Copy-Item $PreservedToken $NewTokenFile -Force }
  elseif (Test-Path $NewTokenFile) { Remove-Item $NewTokenFile -Force }
  # Swap with rollback: current -> .bak, new -> current. Avoid a window where a
  # failed rename leaves no usable EasySkills维护工具/.engine at all. Use
  # Move-Item (not Rename-Item) for the .engine -> .maintenance-bak step:
  # Rename-Item only changes the leaf name, so it would leave the backup nested
  # inside EasySkills维护工具\ instead of at $PermDir (mismatching $BackupMaint,
  # which would then break the rollback path below).
  $BackupMaint = Join-Path $PermDir ".maintenance-bak"
  $PrevBackup = Join-Path $PermDir ".maintenance-bak.prev"
  if (Test-Path $PrevBackup) {
    if (Test-Path $BackupMaint) {
      Remove-Item $PrevBackup -Recurse -Force
    } else {
      try { Move-Item -Path $PrevBackup -Destination $BackupMaint -Force }
      catch {
        if (Test-Path $NewMaint) { Remove-Item $NewMaint -Recurse -Force -ErrorAction SilentlyContinue }
        throw "Previous recoverable backup is preserved at '$PrevBackup' but could not be reconciled. $($_.Exception.Message)"
      }
    }
  }
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
  if (Test-Path $LegacyRootCT) { Remove-Item $LegacyRootCT -Force }
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
    try {
      & powershell -NoProfile -ExecutionPolicy Bypass -File $GatewayInstaller -SourceDir (Join-Path $SrcDir "gateway")
      if ($LASTEXITCODE -ne 0) { throw "install-gateway.ps1 exited with code $LASTEXITCODE" }
    }
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
  if ($LASTEXITCODE -ne 0) {
    throw "Initial EasySkills deploy failed with exit code $LASTEXITCODE. The new engine remains installed and can be retried manually."
  }

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
