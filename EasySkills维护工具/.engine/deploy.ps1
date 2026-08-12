# ==============================================================================
# Script: deploy.ps1 (Windows)
# Description: Active skills mapping and persistence CLI tool for Windows.
#              Reads agent targets from agents.json with hardcoded fallback.
# ==============================================================================

Param(
  [Parameter(Mandatory=$false)][switch]$Sync,
  [Parameter(Mandatory=$false)][switch]$List,
  [Parameter(Mandatory=$false)][string]$Add,
  [Parameter(Mandatory=$false)][string]$Remove,
  [Parameter(Mandatory=$false)][switch]$Watch,
  [Parameter(Mandatory=$false)][switch]$Unwatch,
  [Parameter(Mandatory=$false)][switch]$Cleanup,
  [Parameter(Mandatory=$false)][switch]$Status,
  [Parameter(Mandatory=$false)][switch]$Doctor,
  [Parameter(Mandatory=$false)][switch]$WebUI,
  [Parameter(Mandatory=$false)][switch]$KeepWebUI,
  [Parameter(Mandatory=$false)][string[]]$CustomPath = @()
)

$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent
# The engine lives at EasySkills维护工具/.engine (two levels under the install
# root), so CentralDir must go up TWO parents (.engine -> EasySkills维护工具 ->
# root) to reach the directory that holds the skill folders. deploy.sh computes
# the same thing as "$SCRIPT_DIR/../..". A single Split-Path would land on
# EasySkills维护工具\ (which only contains .engine/), making the skill scan find
# nothing.
$CentralDir = Split-Path -Path (Split-Path -Path $ScriptDir -Parent) -Parent
$CustomTargetsFile = Join-Path -Path $ScriptDir -ChildPath "custom-targets.txt"

function Write-Utf8NoBom([string]$Path, [string]$Content) {
  # Atomic replace: write to a temp file in the same directory, then move it
  # over the target. A direct WriteAllText truncates-then-writes the target, so
  # an interruption (power loss, hard kill during --add/--remove) can leave
  # custom-targets.txt / disabled-targets.txt truncated and silently drop every
  # persisted custom agent path. File.Replace keeps the destination present
  # atomically on Windows; deleting it before Move would recreate the loss
  # window this helper exists to prevent.
  $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  $Dir = [System.IO.Path]::GetDirectoryName($Path)
  if (-not [System.IO.Directory]::Exists($Dir)) { [System.IO.Directory]::CreateDirectory($Dir) | Out-Null }
  $Tmp = [System.IO.Path]::Combine($Dir, "." + [System.IO.Path]::GetFileName($Path) + "." + [System.IO.Path]::GetRandomFileName() + ".tmp")
  [System.IO.File]::WriteAllText($Tmp, $Content, $Utf8NoBom)
  try {
    if ([System.IO.File]::Exists($Path)) {
      [System.IO.File]::Replace($Tmp, $Path, $null)
    } else {
      [System.IO.File]::Move($Tmp, $Path)
    }
  } catch {
    if (Test-Path -LiteralPath $Tmp) { Remove-Item -LiteralPath $Tmp -Force }
    throw
  }
}

function Start-BackgroundPowerShell([string]$ScriptPath, [string]$WorkingDirectory) {
  # Prefer wscript.exe + run-hidden.vbs (GUI subsystem = no console window).
  # Fall back to direct Start-Process if the .vbs bootstrap is missing.
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

# --- One-time migration and cleanup helpers -----------------------------------
# These operations mutate the installation and therefore must run only after the
# deploy mutex is held. Keeping them at top level used to let two concurrent
# deploy.ps1 processes migrate/delete the same files before either one acquired
# the mutex.
$LegacyRootTargets = Join-Path -Path $CentralDir -ChildPath "custom-targets.txt"

function Get-TargetLinePath([string]$Line) {
  $Stripped = if ($null -eq $Line) { "" } else { $Line.Trim() }
  if (-not $Stripped -or $Stripped.StartsWith("#")) { return "" }
  if ($Stripped.Contains("=")) {
    $Parts = $Stripped.Split("=", 2)
    $Prefix = $Parts[0].Trim()
    $Candidate = $Parts[1].Trim()
    $CandidateLooksLikePath = $Candidate.StartsWith("/") -or $Candidate.StartsWith("\") -or
      $Candidate.StartsWith("~") -or $Candidate.StartsWith(".") -or $Candidate.Contains("/") -or
      $Candidate.Contains("\") -or $Candidate -match '^[A-Za-z]:[\\/]'
    $PrefixLooksLikePath = $Prefix.StartsWith("/") -or $Prefix.StartsWith("\") -or
      $Prefix.StartsWith("~") -or $Prefix.StartsWith(".") -or $Prefix.Contains("/") -or
      $Prefix.Contains("\") -or $Prefix -match '^[A-Za-z]:[\\/]'
    if ($Prefix -and $CandidateLooksLikePath -and -not $PrefixLooksLikePath) {
      $Stripped = $Candidate
    }
  }
  if ($Stripped.StartsWith("~")) { $Stripped = Join-Path $Home $Stripped.Substring(1) }
  return $Stripped
}

function Get-TargetLineKey([string]$Line) {
  $Path = Get-TargetLinePath $Line
  if (-not $Path) { return "" }
  try {
    if (Test-Path -LiteralPath $Path -PathType Container) {
      return (Get-Item -LiteralPath $Path -Force).FullName
    }
    return [System.IO.Path]::GetFullPath($Path)
  } catch {
    return $Path
  }
}

function Test-IsCentralDescendant([string]$Path) {
  if (-not $Path) { return $false }
  try {
    $Candidate = if (Test-Path -LiteralPath $Path) {
      (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    } else {
      [System.IO.Path]::GetFullPath($Path)
    }
    $Central = (Resolve-Path -LiteralPath $CentralDir -ErrorAction Stop).ProviderPath
    return $Candidate.Equals($Central, [System.StringComparison]::OrdinalIgnoreCase) -or
      $Candidate.StartsWith("$Central\", [System.StringComparison]::OrdinalIgnoreCase)
  } catch {
    return $false
  }
}

function Invoke-LegacyTargetMigration {
  if ($Doctor -or -not (Test-Path $LegacyRootTargets -PathType Leaf)) { return $true }
  $LegacyLines = Get-Content $LegacyRootTargets | Where-Object { $_ -and !$_.TrimStart().StartsWith("#") }
  try {
    $Existing = if (Test-Path $CustomTargetsFile) { @(Get-Content $CustomTargetsFile -ErrorAction Stop) } else { @() }
    $Merged = @()
    $Seen = @{}
    foreach ($Line in @($Existing) + @($LegacyLines)) {
      $Key = Get-TargetLineKey $Line
      if ($Key -and $Seen.ContainsKey($Key)) { continue }
      if ($Key) { $Seen[$Key] = $true }
      $Merged += $Line
    }
    if ($Merged.Count -gt 0) {
      Write-Utf8NoBom $CustomTargetsFile (($Merged -join "`r`n") + "`r`n")
    }
    Remove-Item $LegacyRootTargets -Force -ErrorAction Stop
    return $true
  } catch {
    Write-Error "Legacy custom-target migration failed; original file was preserved. $_"
    return $false
  }
}

function Remove-StaleRootFiles {
  if ($Doctor) { return }
  $GitDir = Join-Path $CentralDir ".git"
  if (Test-Path $GitDir) { return }
  foreach ($Stale in @("README.md","README_EN.md","README_CN.md","LICENSE","install.sh","install.ps1",
                       "install_mac.command","install_windows.bat",
                       "uninstall_mac.command","uninstall_windows.bat")) {
    $StaleFile = Join-Path $CentralDir $Stale
    if (Test-Path $StaleFile) { Remove-Item $StaleFile -Force -ErrorAction SilentlyContinue }
  }
}

# ---- Load agent targets from agents.json (single source of truth) ----
$AgentsJsonFile = Join-Path -Path $ScriptDir -ChildPath "agents.json"
$script:Targets = @()
$script:AgentNameMap = @{}

function Load-Agents {
  $loaded = $false
  if (Test-Path $AgentsJsonFile) {
    try {
      $Data = Get-Content $AgentsJsonFile -Raw | ConvertFrom-Json
      if ($Data.agents) {
        $TargetList = [System.Collections.ArrayList]::new()
        $NameMap = @{}
        foreach ($Agent in $Data.agents) {
          $WinPath = $Agent.win_path -replace '%USERPROFILE%', $Home
          if ($WinPath) {
            [void]$TargetList.Add($WinPath)
            $NameMap[$WinPath] = $Agent.name
          }
          if ($Agent.win_extra_path) {
            $ExtraPath = $Agent.win_extra_path -replace '%APPDATA%', $env:APPDATA
            if ($ExtraPath) {
              [void]$TargetList.Add($ExtraPath)
              $NameMap[$ExtraPath] = $Agent.name
            }
          }
        }
        if ($TargetList.Count -gt 0) {
          $script:Targets = @($TargetList)
          $script:AgentNameMap = $NameMap
          $loaded = $true
        }
      }
    } catch {
      Write-Warning "Failed to parse agents.json: $_"
    }
  }
  if (-not $loaded) {
    # Fallback: hardcoded defaults (kept in sync with agents.json)
    $script:Targets = @(
      "$Home\.gemini\config\skills",
      "$Home\.gemini\antigravity\skills",
      "$Home\.codex\skills",
      "$Home\.claude\skills",
      "$Home\.copilot\skills",
      "$Home\.pi\agent\skills",
      "$Home\.config\opencode\skills",
      "$Home\.kimi\skills",
      "$Home\.zcode\skills",
      "$Home\.trae\skills",
      "$env:APPDATA\Trae\skills",
      "$Home\.trae-cn\skills",
      "$env:APPDATA\Trae-CN\skills",
      "$Home\.openclaw\skills",
      "$Home\.hermes\skills",
      "$Home\.proma\default-skills",
      "$Home\.cursor\skills",
      "$Home\.kiro\skills",
      "$Home\.junie\skills",
      "$Home\.cline\skills",
      "$Home\.roo\skills",
      "$Home\.warp\skills",
      "$Home\.codeium\windsurf\skills",
      "$Home\.firebender\skills",
      "$Home\.augment\skills",
      "$Home\.continue\skills",
      "$Home\.config\goose\skills",
      "$Home\.agents\skills",
      "$Home\.run\global-skills\skills",
      "$Home\.qoder\skills",
      "$Home\.qwen\skills",
      "$Home\.codebuddy\skills",
      "$Home\.config\agents\skills",
      "$Home\.openhands\skills",
      "$Home\.kilocode\skills",
      "$Home\.zencoder\skills",
      "$Home\.iflow\skills",
      "$Home\.factory\skills",
      "$Home\.config\devin\skills",
      "$Home\.workbuddy\skills",
      "$Home\.qclaw\skills",
      "$Home\.codewhale\skills",
      "$Home\.qoderworkcn\skills",
      "$Home\.qoder-cn\skills",
      "$Home\.mavis\agents\mavis\skills"
    )
    $script:AgentNameMap = @{}
  }
}

Load-Agents

# ---- Concurrency lock (named mutex, system-wide) ----
$script:DeployMutex = $null

function Test-InheritedDeployLock {
  if ($env:EASYSKILLS_DEPLOY_LOCK_HELD -ne "1") { return $false }
  $OwnerPid = 0
  if (-not [int]::TryParse([string]$env:EASYSKILLS_DEPLOY_LOCK_PID, [ref]$OwnerPid)) { return $false }
  if ($OwnerPid -le 0 -or $OwnerPid -eq $PID) { return $false }
  try {
    [void](Get-Process -Id $OwnerPid -ErrorAction Stop)
    return $true
  } catch {
    return $false
  }
}

function Acquire-Lock {
  $script:DeployMutex = New-Object System.Threading.Mutex($false, "Global\EasySkillsDeploy")
  try {
    $ExplicitMutation = [bool]($Cleanup -or $Add -or $Remove)
    $WaitMilliseconds = if ($ExplicitMutation) { 5000 } else { 0 }
    if (-not $script:DeployMutex.WaitOne($WaitMilliseconds)) {
      if ($ExplicitMutation) {
        Write-Error "Another deploy is still running; the requested mutation was not performed."
        exit 1
      }
      Write-Host "Another deploy is already running, skipping duplicate sync."
      exit 0
    }
  } catch [System.Threading.AbandonedMutexException] {
    # The previous holder was killed without releasing (Task Manager kill,
    # hard reboot mid-sync). .NET transfers ownership to us on this exception,
    # so we hold the mutex and can proceed — mirroring the self-healing PID
    # recovery in deploy.sh. Without this catch the exception is unhandled
    # (the call site is before the outer try/finally), the process terminates
    # while now owning the mutex, re-abandoning it, and bricking every
    # subsequent deploy until a reboot.
  }
  # Mark a lock acquired by this standalone deploy process so the nested
  # webui.ps1 -SyncRules child participates in the same critical section
  # instead of waiting on our own mutex until its timeout. An inherited marker
  # is left untouched because the original WebUI process owns the mutex.
  $env:EASYSKILLS_DEPLOY_LOCK_HELD = "1"
  $env:EASYSKILLS_DEPLOY_LOCK_PID = [string]$PID
}

function Release-Lock {
  if ($script:DeployMutex) {
    try { $script:DeployMutex.ReleaseMutex() } catch {}
    $script:DeployMutex.Dispose()
    $script:DeployMutex = $null
  }
}

# Derive the agent's root config directory from a target skills path
function Get-AgentRoot ([string]$Target) {
  if ($Target -like "$env:APPDATA\*") {
    $After = $Target.Substring($env:APPDATA.Length + 1)
    $AppName = $After.Split('\')[0]
    return Join-Path $env:APPDATA $AppName
  } elseif ($Target -like "$Home\*") {
    $Rel = $Target.Substring($Home.Length + 1)
    $Parts = $Rel.Split('\')
    $First = $Parts[0]
    if ($First -eq ".config" -and $Parts.Length -gt 1) {
      return Join-Path $Home (Join-Path ".config" $Parts[1])
    }
    return Join-Path $Home $First
  } else {
    return $Target
  }
}

function Add-TargetOnce([string]$Path) {
  if ($Path -and ($script:Targets -notcontains $Path)) {
    $script:Targets += $Path
  }
}

function Load-CustomTargets {
  if (Test-Path $CustomTargetsFile -PathType Leaf) {
    $Lines = Get-Content $CustomTargetsFile
    foreach ($Line in $Lines) {
      $Target = Get-TargetLinePath $Line
      if ($Target -and (Test-Path -LiteralPath $Target -PathType Container) -and -not (Test-IsCentralDescendant $Target)) {
          Add-TargetOnce $Target
      }
    }
  }

  $PromaDir = Join-Path -Path $Home -ChildPath ".proma"
  $PromaWorkspacesDir = Join-Path -Path $PromaDir -ChildPath "agent-workspaces"
  if (Test-Path $PromaWorkspacesDir) {
    $WorkspaceSkillDirs = Get-ChildItem -Path $PromaWorkspacesDir -Directory -Recurse -Filter "skills" -ErrorAction SilentlyContinue
    foreach ($WsSkills in $WorkspaceSkillDirs) {
      Add-TargetOnce $WsSkills.FullName
    }
  }
}

$DisabledTargetsFile = Join-Path -Path $ScriptDir -ChildPath "disabled-targets.txt"
$script:DisabledTargets = @{}

function Load-DisabledTargets {
  $script:DisabledTargets = @{}
  if (Test-Path $DisabledTargetsFile) {
    $Lines = Get-Content $DisabledTargetsFile
    foreach ($Line in $Lines) {
      if ($Line -and !(($Line.Trim()).StartsWith("#"))) {
        $Target = Get-TargetLinePath $Line
        if ($Target) {
          if ($Target.StartsWith("~")) {
            $Target = $Target.Replace("~", $Home)
          }
          try {
            $AbsPath = (Get-Item $Target).FullName
          } catch {
            $AbsPath = $Target
          }
          $script:DisabledTargets[$AbsPath] = $true
        }
      }
    }
  }
}

function Remove-DisabledTarget([string]$Path) {
  if (!$Path) { return }
  $AbsPath = $Path
  if (Test-Path $Path) {
    $AbsPath = (Get-Item $Path).FullName
  }
  if (Test-Path $DisabledTargetsFile) {
    $Content = Get-Content $DisabledTargetsFile
    $NewContent = $Content | Where-Object {
      $LinePath = Get-TargetLinePath $_
      try {
        $LineAbs = $LinePath
        if (Test-Path $LinePath) { $LineAbs = (Get-Item $LinePath).FullName }
        $LineAbs -ne $AbsPath
      } catch {
        $LinePath -ne $AbsPath
      }
    }
    Write-Utf8NoBom $DisabledTargetsFile ($NewContent -join "`r`n")
  }
}

function Get-AgentName ([string]$Path) {
  # O(1) lookup from agents.json-derived map
  if ($script:AgentNameMap.ContainsKey($Path)) {
    return $script:AgentNameMap[$Path]
  }
  # Dynamic Proma workspace detection
  if ($Path -like "*\.proma\agent-workspaces\*") {
    $Parts = $Path.Split('\')
    for ($i = 0; $i -lt $Parts.Length; $i++) {
      if ($Parts[$i] -eq "agent-workspaces" -and $i -lt $Parts.Length - 1) {
        return "Proma Workspace ($($Parts[$i+1]))"
      }
    }
    return "Proma Workspace"
  }
  # Fallback: prefix-based matching (precise, avoids substring false positives)
  # NOTE: $env:APPDATA (e.g. C:\Users\<user>\AppData\Roaming) is itself under
  # $Home (C:\Users\<user>), so it MUST be tested first — otherwise a Trae
  # AppData path matches "$Home\" and becomes "AppData\Roaming\Trae\skills",
  # which hits the default branch and gets mislabelled "Custom Agent".
  $Rel = $Path
  if ($Path.StartsWith("$env:APPDATA\")) { $Rel = $Path.Substring($env:APPDATA.Length + 1) }
  elseif ($Path.StartsWith("$Home\")) { $Rel = $Path.Substring($Home.Length + 1) }
  switch -Wildcard ($Rel) {
    "Trae-CN\*"                { return "Trae CN" }
    "Trae\*"                   { return "Trae (Global)" }
    ".gemini\antigravity\*"    { return "Antigravity IDE" }
    ".gemini\*"                { return "Antigravity CLI" }
    ".codex\*"                 { return "Codex" }
    ".claude\*"                { return "Claude Code" }
    ".copilot\*"               { return "GitHub Copilot" }
    ".pi\*"                    { return "Pi" }
    ".config\opencode\*"       { return "OpenCode" }
    ".kimi\*"                  { return "Kimi Code" }
    ".zcode\*"                 { return "ZCode" }
    ".trae-cn\*"               { return "Trae CN" }
    ".trae\*"                  { return "Trae (Global)" }
    ".openclaw\*"              { return "OpenClaw" }
    ".hermes\*"                { return "Hermes Agent" }
    ".proma\*"                 { return "Proma" }
    ".cursor\*"                { return "Cursor" }
    ".kiro\*"                  { return "Kiro Agent" }
    ".junie\*"                 { return "Junie (JetBrains)" }
    ".cline\*"                 { return "Cline" }
    ".roo\*"                   { return "Roo Code" }
    ".warp\*"                  { return "Warp" }
    ".codeium\windsurf\*"      { return "Windsurf" }
    ".firebender\*"            { return "Firebender" }
    ".augment\*"               { return "Augment" }
    ".continue\*"              { return "Continue" }
    ".config\goose\*"          { return "Goose" }
    ".qoder\*"                 { return "Qoder" }
    ".qwen\*"                  { return "Qwen Code" }
    ".codebuddy\*"             { return "CodeBuddy" }
    ".config\agents\*"         { return "Amp" }
    ".openhands\*"             { return "OpenHands" }
    ".kilocode\*"              { return "Kilo Code" }
    ".zencoder\*"              { return "Zencoder" }
    ".iflow\*"                 { return "iFlow CLI" }
    ".factory\*"               { return "Droid" }
    ".config\devin\*"          { return "Devin for Terminal" }
    ".workbuddy\*"             { return "WorkBuddy" }
    ".qclaw\*"                 { return "QClaw" }
    ".codewhale\*"             { return "CodeWhale" }
    ".qoderworkcn\*"           { return "QoderWork CN" }
    ".qoder-cn\*"              { return "Qoder CN" }
    ".mavis\*"                 { return "MiniMax Code" }
    ".agents\*"                { return "Agents (Standard)" }
    ".run\*"                   { return "Run" }
    "Trae-CN\*"                { return "Trae CN" }
    "Trae\*"                   { return "Trae (Global)" }
    default                    { return "Custom Agent" }
  }
}

function Test-EasySkillsLinkTarget($Item) {
  # Compare the reparse point's lexical target without Resolve-Path. The final
  # central skill can itself be a junction/symlink to an external directory;
  # following it would make our own Agent mapping look foreign.
  if (-not $Item -or -not ($Item.Attributes -match "ReparsePoint")) { return $false }
  $RawTarget = [string](@($Item.Target)[0])
  if (-not $RawTarget) { return $false }
  try {
    if (-not [System.IO.Path]::IsPathRooted($RawTarget)) {
      $ItemParent = [System.IO.Path]::GetDirectoryName([string]$Item.FullName)
      $RawTarget = Join-Path $ItemParent $RawTarget
    }
    $LexicalTarget = [System.IO.Path]::GetFullPath($RawTarget)
    $CentralResolved = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $CentralDir).ProviderPath).TrimEnd('\')
    return $LexicalTarget.Equals($CentralResolved, [System.StringComparison]::OrdinalIgnoreCase) -or
      $LexicalTarget.StartsWith("$CentralResolved\", [System.StringComparison]::OrdinalIgnoreCase)
  } catch {
    return $false
  }
}

function Run-Sync {
  Load-CustomTargets
  Load-DisabledTargets
  $script:SuccessfulInjections = @()

  # Ensure ~/.qoder-cn/skills exists — Qoder CN relies on EasySkills to
  # create the path if it does not already exist.
  $qoderCnSkills = Join-Path $Home ".qoder-cn\skills"
  if (-not (Test-Path $qoderCnSkills)) {
    New-Item -Path $qoderCnSkills -ItemType Directory -Force | Out-Null
  }

  foreach ($Path in $CustomPath) {
    if ((Test-Path -LiteralPath $Path -PathType Container) -and -not (Test-IsCentralDescendant $Path)) { $script:Targets += $Path }
  }

  Write-Host "==========================================================" -ForegroundColor Cyan
  Write-Host "Starting EasySkills Sync (Windows)..." -ForegroundColor Cyan
  Write-Host "==========================================================" -ForegroundColor Cyan

  # PART A: Legacy cleanup (Remove EasySkills self-mapping from previous versions)
  $CentralResolved = (Resolve-Path -LiteralPath $CentralDir).ProviderPath
  foreach ($Target in $script:Targets) {
    if (Test-IsCentralDescendant $Target) {
      Write-Warning "Skipped unsafe target inside the EasySkills library: $Target"
      continue
    }
    $DestPath = Join-Path -Path $Target -ChildPath "EasySkills"
    # Use Get-Item -Force (not Test-Path) so a DANGLING reparse point — whose
    # target no longer exists and which Test-Path follows and reports as False —
    # is still detected. Test-Path on a reparse point follows the link; the
    # attributes check below does not.
    $Item = Get-Item -LiteralPath $DestPath -Force -ErrorAction SilentlyContinue
    if ($Item -and ($Item.Attributes -match "ReparsePoint")) {
      $LinkTarget = $Item.Target
      $ResolvedTarget = $null
      if ($LinkTarget) {
        try {
          $ResolvedTarget = (Resolve-Path -LiteralPath $LinkTarget).ProviderPath
        } catch {
          try { $ResolvedTarget = [System.IO.Path]::GetFullPath($LinkTarget) } catch {}
        }
      }
      if ($ResolvedTarget -and $ResolvedTarget.Equals($CentralResolved, [System.StringComparison]::OrdinalIgnoreCase)) {
        # Delete the reparse point ITSELF, never its target. Remove-Item -Recurse
        # on a directory junction/symlink can traverse into and delete the real
        # contents of the link target on Windows PowerShell 5.1.
        [System.IO.Directory]::Delete($Item.FullName, $false)
        Write-Host "   * Cleaned up legacy self-mapping -> $DestPath" -ForegroundColor Green
      }
    }
  }

  # PART A.5: Prune dangling reparse-point skills and flag external-link skills
  # in the central dir. Mirrors run_sync's PART A.5 in deploy.sh.
  #
  # A dangling link (its target was removed) is dead weight: agents that stat
  # the link target without a try/catch abort their whole skill scan on it,
  # silently dropping every skill sorted after it. Junction targets must exist
  # to be created, but a user-built SymbolicLink (or a Junction whose target
  # was later deleted) can dangle, so we detect and prune defensively.
  # An external-link skill (valid symlink/junction) is left in place and
  # forwarded for backward compatibility, but we warn and collect it.
  #
  # NOTE: Get-ChildItem -Directory does NOT enumerate dangling directory
  # symlinks (it follows the link, the follow fails, the entry is dropped), so
  # -Force is required to even see them here.
  $DanglingRemoved = 0
  $ExternalLinkSkills = @()
  $CentralEntries = Get-ChildItem -Path $CentralDir -Force -ErrorAction SilentlyContinue
  foreach ($Entry in $CentralEntries) {
    if (-not ($Entry.Attributes -match "ReparsePoint")) { continue }
    $EName = $Entry.Name
    if ($EName -eq "node_modules" -or $EName -eq ".git" -or $EName -eq "dist" -or $EName -eq "docs" -or $EName -eq "EasySkills维护工具" -or $EName -eq "instructions" -or $EName -eq "mcp" -or $EName -like "_*" -or $EName -like ".*") { continue }
    # Test-Path follows the reparse point: False => dangling, True => external.
    if (-not (Test-Path $Entry.FullName)) {
      # Delete the dead link itself, not any target it may still partially
      # resolve to. Directory::Delete(path, $false) removes the reparse point
      # without recursing into the target.
      try { [System.IO.Directory]::Delete($Entry.FullName, $false) } catch {}
      $DanglingRemoved++
      Write-Host "   * Pruned dangling link: $EName (target no longer exists)" -ForegroundColor DarkGray
    } else {
      $ExternalLinkSkills += $EName
      Write-Host "   [!] Warning: [$EName] is an external link (-> $($Entry.Target))" -ForegroundColor Yellow
      Write-Host "       If its target is removed, this skill may break all agents' skill scans." -ForegroundColor Yellow
      Write-Host "       Consider converting it to a real directory." -ForegroundColor Yellow
    }
  }

  # PART B: Map each custom skill directory
  $SkillDirs = Get-ChildItem -Path $CentralDir -Directory

  foreach ($SkillDir in $SkillDirs) {
    $SkillName = $SkillDir.Name
    if ($SkillName -eq "node_modules" -or $SkillName -eq ".git" -or $SkillName -eq "dist" -or $SkillName -eq "docs" -or $SkillName -eq "EasySkills维护工具" -or $SkillName -eq "instructions" -or $SkillName -eq "mcp" -or $SkillName -like "_*" -or $SkillName -like ".*") {
      continue
    }

    Write-Host "   Found skill: $SkillName" -ForegroundColor Magenta

    foreach ($Target in $script:Targets) {
      try {
        $AbsTarget = (Get-Item $Target).FullName
      } catch {
        $AbsTarget = $Target
      }
      if ($script:DisabledTargets.ContainsKey($AbsTarget)) {
        continue
      }

      $AgentRoot = Get-AgentRoot $Target
      if (!(Test-Path $AgentRoot)) { continue }

      if (!(Test-Path $Target)) {
        New-Item -ItemType Directory -Path $Target -Force | Out-Null
      }

      $DestPath = Join-Path -Path $Target -ChildPath $SkillName

      # Detect an existing entry WITHOUT following reparse points. Test-Path
      # follows links, so a DANGLING junction/symlink (target removed) reports
      # False and would be skipped below — then New-Item would fail because the
      # dead reparse point still occupies the name. Get-Item -Force sees the
      # entry regardless of whether its target exists.
      $Existing = Get-Item -LiteralPath $DestPath -Force -ErrorAction SilentlyContinue
      if ($Existing) {
        if ($Existing.Attributes -match "ReparsePoint") {
          if (Test-EasySkillsLinkTarget $Existing) {
            # Remove the link ITSELF only — never recurse into its target.
            [System.IO.Directory]::Delete($Existing.FullName, $false)
          } else {
            Write-Host "      Warning: [$SkillName] already exists as a foreign link in $Target. Preserved and skipped." -ForegroundColor Yellow
            continue
          }
        } else {
          Write-Host "      Warning: [$SkillName] already exists as a real directory in $Target. Skipped." -ForegroundColor Yellow
          continue
        }
      }

      New-Item -ItemType Junction -Path $DestPath -Value $SkillDir.FullName | Out-Null
      Write-Host "      -> Mapped to: $DestPath" -ForegroundColor Gray
      if ($script:SuccessfulInjections -notcontains $Target) {
        $script:SuccessfulInjections += $Target
      }
    }
  }

  # PART C: Compile and synchronize Agent Rules
  $WebUIScript = Join-Path $ScriptDir "webui.ps1"
  if (Test-Path $WebUIScript) {
    Write-Host "   Syncing Agent rules..."
    powershell -NoProfile -ExecutionPolicy Bypass -File "$WebUIScript" -SyncRules
    if ($LASTEXITCODE -ne 0) {
      Write-Warning "Agent rule sync failed; skill junctions were still synchronized."
    }
  }

  Write-Host "==========================================================" -ForegroundColor Cyan
  Write-Host "EasySkills Sync completed successfully!" -ForegroundColor Green
  Write-Host "==========================================================" -ForegroundColor Cyan
  Write-Host "Injection Summary:" -ForegroundColor Cyan
  Write-Host "==========================================================" -ForegroundColor Cyan
  if ($script:SuccessfulInjections.Count -eq 0) {
    Write-Host "   No active target Agent directories mapped." -ForegroundColor Yellow
  } else {
    Write-Host "Successfully injected into the following agents:" -ForegroundColor Green
    foreach ($Injected in $script:SuccessfulInjections) {
      $AgentName = Get-AgentName $Injected
      Write-Host "   -> [$AgentName] $Injected" -ForegroundColor Gray
    }
  }
  # Link-health report: surface the pruning/warning that ran in PART A.5.
  if ($DanglingRemoved -gt 0) {
    Write-Host "----------------------------------------------------------" -ForegroundColor Cyan
    Write-Host "   Pruned $DanglingRemoved dangling skill link(s) from central dir." -ForegroundColor DarkGray
  }
  if ($ExternalLinkSkills.Count -gt 0) {
    Write-Host "----------------------------------------------------------" -ForegroundColor Cyan
    Write-Host "   [!] $($ExternalLinkSkills.Count) skill(s) are external links (still forwarded, but fragile):" -ForegroundColor Yellow
    foreach ($S in $ExternalLinkSkills) { Write-Host "      - $S" -ForegroundColor Yellow }
    Write-Host "   Tip: convert them to real directories for robustness." -ForegroundColor Yellow
  }
  Write-Host "==========================================================" -ForegroundColor Cyan
}

function List-Links {
  Load-CustomTargets
  Write-Host "==========================================================" -ForegroundColor Cyan
  Write-Host "Current Mapped Targets:" -ForegroundColor Cyan
  Write-Host "==========================================================" -ForegroundColor Cyan
  foreach ($Target in $script:Targets) {
    if (Test-Path $Target) {
      Write-Host "Agent Path: $Target" -ForegroundColor Yellow
      $Items = Get-ChildItem -Path $Target -Force
      foreach ($Item in $Items) {
        if ($Item.Attributes -match "ReparsePoint") {
          Write-Host "   Junction: $($Item.Name) -> $($Item.Target)" -ForegroundColor Gray
        }
      }
    }
  }
  Write-Host "==========================================================" -ForegroundColor Cyan
}

function Add-Target ([string]$Path) {
  if (!$Path -or !(Test-Path $Path -PathType Container)) {
    Write-Error "Error: Please specify a valid directory."
    return $false
  }
  if (Test-IsCentralDescendant $Path) {
    Write-Error "Error: The EasySkills library cannot be registered as an Agent skills directory."
    return $false
  }
  $AbsPath = (Get-Item $Path).FullName
  $Content = if (Test-Path $CustomTargetsFile) { @(Get-Content $CustomTargetsFile -ErrorAction SilentlyContinue) } else { @() }
  $AlreadyPersisted = @($Content | Where-Object {
    $Line = Get-TargetLinePath $_
    $Line -eq $AbsPath
  }).Count -gt 0
  if ($AlreadyPersisted) {
    Write-Host "Path is already persisted: $AbsPath" -ForegroundColor Gray
  } else {
    $NewContent = @($Content) + $AbsPath
    # Read-modify-write through the atomic replacement helper. A direct append
    # can leave a truncated final path after a hard kill or power loss.
    Write-Utf8NoBom $CustomTargetsFile (($NewContent -join "`r`n") + "`r`n")
    Write-Host "Successfully persisted custom target: $AbsPath" -ForegroundColor Green
  }
  Remove-DisabledTarget $Path
  Run-Sync
  return $true
}

function Remove-Target ([string]$Path) {
  if (!$Path) {
    Write-Error "Error: Please specify a path to remove."
    return $false
  }
  # Resolve to absolute path (same as Add-Target)
  $AbsPath = $Path
  if (Test-Path $Path) {
    $AbsPath = (Get-Item $Path).FullName
  }
  if (Test-Path $CustomTargetsFile) {
    $Content = Get-Content $CustomTargetsFile
    $NewContent = $Content | Where-Object {
      $LinePath = Get-TargetLinePath $_
      $LinePath -ne $AbsPath
    }
    Write-Utf8NoBom $CustomTargetsFile ($NewContent -join "`r`n")
    Remove-DisabledTarget $Path
    Write-Host "Successfully removed path: $AbsPath" -ForegroundColor Green
    Run-Sync
  } else {
    Write-Host "No custom targets file found." -ForegroundColor Gray
  }
  return $true
}

function Run-Cleanup {
  Load-CustomTargets
  $CleanupErrors = @()
  Write-Host "==========================================================" -ForegroundColor Cyan
  Write-Host "Cleaning up all EasySkills junctions from agent directories..." -ForegroundColor Cyan
  Write-Host "==========================================================" -ForegroundColor Cyan
  foreach ($Target in $script:Targets) {
    if (Test-Path $Target) {
      try {
        $Items = Get-ChildItem -Path $Target -Force -ErrorAction Stop
      } catch {
        $CleanupErrors += "$Target`: $($_.Exception.Message)"
        continue
      }
      foreach ($Item in $Items) {
        if (Test-EasySkillsLinkTarget $Item) {
          try {
            # Delete the reparse point only, not its target's contents.
            [System.IO.Directory]::Delete($Item.FullName, $false)
            Write-Host "   Removed junction: $($Item.FullName)" -ForegroundColor Green
          } catch {
            $CleanupErrors += "$($Item.FullName): $($_.Exception.Message)"
          }
        }
      }
    }
  }
  if ($CleanupErrors.Count -gt 0) {
    foreach ($CleanupError in $CleanupErrors) { Write-Error "Cleanup failed: $CleanupError" }
    Write-Host "Cleanup incomplete: $($CleanupErrors.Count) junction(s) could not be removed." -ForegroundColor Red
    Write-Host "==========================================================" -ForegroundColor Cyan
    return $false
  }
  Write-Host "All EasySkills junctions cleaned up." -ForegroundColor Green
  Write-Host "==========================================================" -ForegroundColor Cyan
  return $true
}

function Run-Status {
  Load-CustomTargets
  Write-Host "==========================================================" -ForegroundColor Cyan
  Write-Host "EasySkills Status" -ForegroundColor Cyan
  Write-Host "==========================================================" -ForegroundColor Cyan

  # Watcher status (WMI for PS 5.1 compatibility)
  $WmiProc = $null
  try {
    $WmiProc = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' AND CommandLine LIKE '%watcher-service.ps1%'" -ErrorAction SilentlyContinue |
      Select-Object -First 1
  } catch {}
  if ($WmiProc) {
    Write-Host "   Watcher: [OK] Running (PID $($WmiProc.ProcessId))" -ForegroundColor Green
  } else {
    Write-Host "   Watcher: [--] Not running" -ForegroundColor Red
  }

  # Mapped agents
  $AgentCount = 0
  $TotalSkills = 0
  foreach ($Target in $script:Targets) {
    if (Test-Path $Target) {
      $Junctions = Get-ChildItem -Path $Target -Force | Where-Object { Test-EasySkillsLinkTarget $_ }
      if ($Junctions) {
        $Count = @($Junctions).Count
        $AgentCount++
        $TotalSkills += $Count
        $AgentName = Get-AgentName $Target
        Write-Host "   Agent: $AgentName ($Count skills)" -ForegroundColor Gray
      }
    }
  }

  Write-Host "   ------------------------------------------" -ForegroundColor Cyan
  Write-Host "   Total: $AgentCount agents, $TotalSkills skill mappings" -ForegroundColor White

  # Link-health snapshot of the central dir (read-only: status never deletes).
  # Mirrors the PART A.5 detection in Run-Sync so users can preview problems.
  $DanglingCount = 0
  $ExternalCount = 0
  $StatusEntries = Get-ChildItem -Path $CentralDir -Force -ErrorAction SilentlyContinue
  foreach ($Entry in $StatusEntries) {
    if (-not ($Entry.Attributes -match "ReparsePoint")) { continue }
    $EName = $Entry.Name
    if ($EName -eq "node_modules" -or $EName -eq ".git" -or $EName -eq "dist" -or $EName -eq "docs" -or $EName -eq "EasySkills维护工具" -or $EName -eq "instructions" -or $EName -eq "mcp" -or $EName -like "_*" -or $EName -like ".*") { continue }
    if (-not (Test-Path $Entry.FullName)) { $DanglingCount++ } else { $ExternalCount++ }
  }
  if ($DanglingCount -gt 0 -or $ExternalCount -gt 0) {
    Write-Host "   ------------------------------------------" -ForegroundColor Cyan
    Write-Host "   Link health: $DanglingCount dangling (run sync to prune), $ExternalCount external" -ForegroundColor Yellow
  }
  Write-Host "==========================================================" -ForegroundColor Cyan
}

# ---- Main dispatch with mutex protection ----
$NeedsLock = -not ($List -or $Watch -or $Unwatch -or $Status -or $Doctor -or $WebUI)

if ($NeedsLock -and -not (Test-InheritedDeployLock)) { Acquire-Lock }

if ($NeedsLock) {
  if (-not (Invoke-LegacyTargetMigration)) { Release-Lock; exit 1 }
  Remove-StaleRootFiles
}

try {
  if ($Doctor) {
    & "$ScriptDir\webui.ps1" -Doctor
    exit $LASTEXITCODE
  } elseif ($Status) {
    Run-Status
  } elseif ($WebUI) {
    $Started = $false
    if (Get-Command Start-ScheduledTask -ErrorAction SilentlyContinue) {
      if (Get-ScheduledTask -TaskName "EasySkills WebUI" -ErrorAction SilentlyContinue) {
        try { Start-ScheduledTask -TaskName "EasySkills WebUI" -ErrorAction Stop; $Started = $true } catch {}
      }
    }
    if (-not $Started) {
      Start-BackgroundPowerShell (Join-Path $ScriptDir "webui-service.ps1") $ScriptDir
    }
    Write-Host "WebUI launching on http://localhost:6633"
  } elseif ($Cleanup) {
    if (-not (Run-Cleanup)) { exit 1 }
  } elseif ($List) {
    List-Links
  } elseif ($Add) {
    if (-not (Add-Target $Add)) { Release-Lock; exit 1 }
  } elseif ($Remove) {
    if (-not (Remove-Target $Remove)) { Release-Lock; exit 1 }
  } elseif ($Watch) {
    & "$ScriptDir\watch.ps1"
  } elseif ($Unwatch) {
    if ($KeepWebUI) {
      & "$ScriptDir\unwatch.ps1" -KeepWebUI
    } else {
      & "$ScriptDir\unwatch.ps1"
    }
  } else {
    Run-Sync
  }
} finally {
  if ($NeedsLock) { Release-Lock }
}
