# ==============================================================================
# Script: deploy.ps1 (Windows)
# Description: Active skills mapping and persistence CLI tool for Windows.
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
  [Parameter(Mandatory=$false)][string[]]$CustomPath = @()
)

$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent
$CentralDir = Split-Path -Path $ScriptDir -Parent
$CustomTargetsFile = Join-Path -Path $CentralDir -ChildPath "custom-targets.txt"

# --- One-time migration: move custom-targets.txt from legacy _maintenance/ location ---
$LegacyCustomTargets = Join-Path -Path $ScriptDir -ChildPath "custom-targets.txt"
if ((Test-Path $LegacyCustomTargets) -and ($LegacyCustomTargets -ne $CustomTargetsFile)) {
  $LegacyLines = Get-Content $LegacyCustomTargets | Where-Object { $_ -and !$_.TrimStart().StartsWith("#") }
  if ($LegacyLines) {
    if (!(Test-Path $CustomTargetsFile)) { New-Item -ItemType File -Path $CustomTargetsFile -Force | Out-Null }
    $Existing = @(Get-Content $CustomTargetsFile -ErrorAction SilentlyContinue)
    foreach ($Line in $LegacyLines) {
      if ($Existing -notcontains $Line) {
        Add-Content -Path $CustomTargetsFile -Value $Line
      }
    }
  }
}

# Default target skills directories
$Targets = @(
  "$Home\.gemini\config\skills",
  "$Home\.codex\skills",
  "$Home\.claude\skills",
  "$Home\.copilot\skills",
  "$Home\.pi\skills",
  "$Home\.opencode\skills",
  "$Home\.kimi\skills",
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
  "$Home\.windsurf\skills",
  "$Home\.firebender\skills",
  "$Home\.augment\skills",
  "$Home\.continue\skills",
  "$Home\.goose\skills",
  "$Home\.agents\skills",
  "$Home\.run\global-skills\skills",
  "$Home\.run\global-skills"
)

# ---- Concurrency lock (named mutex, system-wide) ----
$script:DeployMutex = $null

function Acquire-Lock {
  $script:DeployMutex = New-Object System.Threading.Mutex($false, "Global\EasySkillsDeploy")
  if (-not $script:DeployMutex.WaitOne(0)) {
    Write-Host "Another deploy is already running, skipping."
    exit 0
  }
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
    $First = $Rel.Split('\')[0]
    return Join-Path $Home $First
  } else {
    return $Target
  }
}

function Load-CustomTargets {
  if (Test-Path $CustomTargetsFile) {
    $Lines = Get-Content $CustomTargetsFile
    foreach ($Line in $Lines) {
      if ($Line -and !(($Line.Trim()).StartsWith("#"))) {
        if (Test-Path $Line) {
          $script:Targets += $Line
        }
      }
    }
  }
}

function Get-AgentName ([string]$Path) {
  if ($Path -like "*\.gemini\*") { return "Antigravity (Gemini)" }
  if ($Path -like "*\.codex\*") { return "Codex" }
  if ($Path -like "*\.claude\*") { return "Claude Code" }
  if ($Path -like "*\.copilot\*") { return "GitHub Copilot" }
  if ($Path -like "*\.pi\*") { return "Pi" }
  if ($Path -like "*\.opencode\*") { return "OpenCode" }
  if ($Path -like "*\.kimi\*") { return "Kimi Code" }
  if ($Path -like "*\.trae-cn\*" -or $Path -like "*\Trae-CN\*") { return "Trae CN" }
  if ($Path -like "*\.trae\*" -or $Path -like "*\Trae\*") { return "Trae (Global)" }
  if ($Path -like "*\.openclaw\*") { return "OpenClaw" }
  if ($Path -like "*\.hermes\*") { return "Hermes Agent" }
  if ($Path -like "*\.proma\*") { return "Proma" }
  if ($Path -like "*\.cursor\*") { return "Cursor" }
  if ($Path -like "*\.kiro\*") { return "Kiro Agent" }
  if ($Path -like "*\.junie\*") { return "Junie (JetBrains)" }
  if ($Path -like "*\.cline\*") { return "Cline" }
  if ($Path -like "*\.roo\*") { return "Roo Code" }
  if ($Path -like "*\.warp\*") { return "Warp" }
  if ($Path -like "*\.windsurf\*") { return "Windsurf" }
  if ($Path -like "*\.firebender\*") { return "Firebender" }
  if ($Path -like "*\.augment\*") { return "Augment" }
  if ($Path -like "*\.continue\*") { return "Continue" }
  if ($Path -like "*\.goose\*") { return "Goose" }
  if ($Path -like "*\.agents\*") { return "Agents (Standard)" }
  if ($Path -like "*\.run\*") { return "RunAI (Backup)" }
  return "Custom Agent"
}

function Run-Sync {
  Load-CustomTargets
  $script:SuccessfulInjections = @()

  foreach ($Path in $CustomPath) {
    if (Test-Path $Path) { $script:Targets += $Path }
  }

  Write-Host "==========================================================" -ForegroundColor Cyan
  Write-Host "Starting EasySkills Sync (Windows)..." -ForegroundColor Cyan
  Write-Host "==========================================================" -ForegroundColor Cyan

  # PART A: Map EasySkills itself
  foreach ($Target in $script:Targets) {
    $AgentRoot = Get-AgentRoot $Target
    if (!(Test-Path $AgentRoot)) { continue }

    if (!(Test-Path $Target)) {
      New-Item -ItemType Directory -Path $Target -Force | Out-Null
    }

    $DestPath = Join-Path -Path $Target -ChildPath "EasySkills"

    if (Test-Path $DestPath) {
      $Item = Get-Item $DestPath
      if ($Item.Attributes -match "ReparsePoint") {
        Remove-Item $DestPath -Recurse -Force
      } else {
        continue
      }
    }

    New-Item -ItemType Junction -Path $DestPath -Value $CentralDir | Out-Null
    Write-Host "   * Self-Mapped EasySkills -> $DestPath" -ForegroundColor Green
    if ($script:SuccessfulInjections -notcontains $Target) {
      $script:SuccessfulInjections += $Target
    }
  }

  # PART B: Map each custom skill directory
  $SkillDirs = Get-ChildItem -Path $CentralDir -Directory

  foreach ($SkillDir in $SkillDirs) {
    $SkillName = $SkillDir.Name
    if ($SkillName -eq "node_modules" -or $SkillName -eq ".git" -or $SkillName -eq "dist" -or $SkillName -eq "_maintenance" -or $SkillName -like "_*") {
      continue
    }

    Write-Host "   Found skill: $SkillName" -ForegroundColor Magenta

    foreach ($Target in $script:Targets) {
      $AgentRoot = Get-AgentRoot $Target
      if (!(Test-Path $AgentRoot)) { continue }

      if (!(Test-Path $Target)) {
        New-Item -ItemType Directory -Path $Target -Force | Out-Null
      }

      $DestPath = Join-Path -Path $Target -ChildPath $SkillName

      if (Test-Path $DestPath) {
        $Item = Get-Item $DestPath
        if ($Item.Attributes -match "ReparsePoint") {
          Remove-Item $DestPath -Recurse -Force
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
  if (!$Path -or !(Test-Path $Path)) {
    Write-Error "Error: Please specify a valid directory."
    exit 1
  }
  $AbsPath = (Get-Item $Path).FullName
  if (!(Test-Path $CustomTargetsFile)) {
    New-Item -ItemType File -Path $CustomTargetsFile -Force | Out-Null
  }
  $Content = Get-Content $CustomTargetsFile -ErrorAction SilentlyContinue
  if ($Content -contains $AbsPath) {
    Write-Host "Path is already persisted: $AbsPath" -ForegroundColor Gray
  } else {
    Add-Content -Path $CustomTargetsFile -Value $AbsPath
    Write-Host "Successfully persisted custom target: $AbsPath" -ForegroundColor Green
  }
  Run-Sync
}

function Remove-Target ([string]$Path) {
  if (!$Path) {
    Write-Error "Error: Please specify a path to remove."
    exit 1
  }
  if (Test-Path $CustomTargetsFile) {
    $Content = Get-Content $CustomTargetsFile
    $NewContent = $Content | Where-Object { $_ -ne $Path }
    Set-Content -Path $CustomTargetsFile -Value $NewContent
    Write-Host "Successfully removed path: $Path" -ForegroundColor Green
    Run-Sync
  } else {
    Write-Host "No custom targets file found." -ForegroundColor Gray
  }
}

function Run-Cleanup {
  Load-CustomTargets
  Write-Host "==========================================================" -ForegroundColor Cyan
  Write-Host "Cleaning up all EasySkills junctions from agent directories..." -ForegroundColor Cyan
  Write-Host "==========================================================" -ForegroundColor Cyan
  foreach ($Target in $script:Targets) {
    if (Test-Path $Target) {
      $Items = Get-ChildItem -Path $Target -Force
      foreach ($Item in $Items) {
        if ($Item.Attributes -match "ReparsePoint") {
          $LinkTarget = $Item.Target
          if ($LinkTarget -and ($LinkTarget -like "*EasySkills*")) {
            Remove-Item $Item.FullName -Recurse -Force
            Write-Host "   Removed junction: $($Item.FullName)" -ForegroundColor Green
          }
        }
      }
    }
  }
  Write-Host "All EasySkills junctions cleaned up." -ForegroundColor Green
  Write-Host "==========================================================" -ForegroundColor Cyan
}

function Run-Status {
  Load-CustomTargets
  Write-Host "==========================================================" -ForegroundColor Cyan
  Write-Host "EasySkills Status" -ForegroundColor Cyan
  Write-Host "==========================================================" -ForegroundColor Cyan

  # Watcher status
  $WatcherProc = Get-Process -Name "powershell","pwsh" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -like "*watcher-service*" }
  if ($WatcherProc) {
    Write-Host "   Watcher: ✅ Running (PID $($WatcherProc.Id))" -ForegroundColor Green
  } else {
    Write-Host "   Watcher: ❌ Not running" -ForegroundColor Red
  }

  # Mapped agents
  $AgentCount = 0
  $TotalSkills = 0
  foreach ($Target in $script:Targets) {
    if (Test-Path $Target) {
      $Junctions = Get-ChildItem -Path $Target -Force | Where-Object { $_.Attributes -match "ReparsePoint" }
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
  Write-Host "==========================================================" -ForegroundColor Cyan
}

# ---- Main dispatch with mutex protection ----
$NeedsLock = -not ($List -or $Watch -or $Unwatch -or $Status)

if ($NeedsLock) { Acquire-Lock }

try {
  if ($Status) {
    Run-Status
  } elseif ($Cleanup) {
    Run-Cleanup
  } elseif ($List) {
    List-Links
  } elseif ($Add) {
    Add-Target $Add
  } elseif ($Remove) {
    Remove-Target $Remove
  } elseif ($Watch) {
    & "$ScriptDir\watch.ps1"
  } elseif ($Unwatch) {
    & "$ScriptDir\unwatch.ps1"
  } else {
    Run-Sync
  }
} finally {
  if ($NeedsLock) { Release-Lock }
}
