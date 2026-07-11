# ==============================================================================
# Script: webui.ps1 (Windows)
# Description: EasySkills WebUI backend - PowerShell HttpListener, zero deps.
# Usage: powershell -File _maintenance\webui.ps1
#        or: deploy.ps1 -WebUI
# ==============================================================================

Param(
    [Parameter(Mandatory=$false)][switch]$NoBrowser
)

$ErrorActionPreference = 'Continue'

# Port must match webui.py:PORT (the single source of truth for the server).
$Port = 6633
$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent
$CentralDir = Split-Path -Path $ScriptDir -Parent

# Keep this long-running process's working directory OUTSIDE _maintenance so a
# self-update / rollback can rename that directory without a sharing violation.
try { [System.IO.Directory]::SetCurrentDirectory($CentralDir) } catch {}

# ---- Persistent token (survives restarts) ----
# Stored under ScriptDir (not bare home) so it stays with the installation
$TokenFile = Join-Path $ScriptDir ".easyskills-token"
function Initialize-WebUIToken {
    $EnvToken = $env:EASYSKILLS_WEBUI_TOKEN
    if ($EnvToken) { return $EnvToken }
    if (Test-Path $TokenFile) {
        $Saved = (Get-Content $TokenFile -ErrorAction SilentlyContinue | Select-Object -First 1).Trim()
        if ($Saved -and $Saved.Length -ge 16) { return $Saved }
    }
    $New = [Guid]::NewGuid().ToString("N") + [Guid]::NewGuid().ToString("N").Substring(0, 16)
    try {
        # Atomic create: throws if file already exists
        $Fs = [System.IO.File]::Open($TokenFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $Writer = [System.IO.StreamWriter]::new($Fs)
        $Writer.Write($New)
        $Writer.Close()
        $Fs.Close()
    } catch [System.IO.IOException] {
        # File already exists — another process won the race. Read their token with retries.
        for ($i = 0; $i -lt 3; $i++) {
            $Saved = (Get-Content $TokenFile -ErrorAction SilentlyContinue | Select-Object -First 1)
            if ($Saved) { $Saved = $Saved.Trim() }
            if ($Saved -and $Saved.Length -ge 16) { return $Saved }
            Start-Sleep -Milliseconds 50
        }
        throw "Token file exists but could not be read after 3 retries."
    } catch {
        Write-Warning "Could not persist WebUI token: $_"
    }
    return $New
}
$WebUIToken = Initialize-WebUIToken

$WebUILogDir  = Join-Path $ScriptDir "logs"
$WebUILogFile = Join-Path $WebUILogDir "webui.log"
if (-not (Test-Path $WebUILogDir)) {
    try { New-Item -ItemType Directory -Path $WebUILogDir -Force | Out-Null } catch {}
}
function Write-WebUILog([string]$Message) {
    try {
        $Line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [pid=$PID] $Message"
        Add-Content -Path $WebUILogFile -Value $Line -Encoding UTF8 -ErrorAction SilentlyContinue
        $Info = Get-Item $WebUILogFile -ErrorAction SilentlyContinue
        if ($Info -and $Info.Length -gt 1048576) {
            $Tail = Get-Content $WebUILogFile -Tail 500 -ErrorAction SilentlyContinue
            if ($Tail) { $Tail | Set-Content -Path $WebUILogFile -Encoding UTF8 }
        }
    } catch {}
}

# Dynamically resolve to official home directory installation if it exists
$HomeCentralDir = Join-Path $Home "EasySkills"
$RepoGitDir = Join-Path $CentralDir ".git"
if ((Test-Path $HomeCentralDir) -and -not (Test-Path $RepoGitDir)) {
    $CentralDir = $HomeCentralDir
    $ScriptDir = Join-Path $HomeCentralDir "_maintenance"
}

$CustomTargetsFile = Join-Path -Path $ScriptDir -ChildPath "custom-targets.txt"
$DisabledTargetsFile = Join-Path -Path $ScriptDir -ChildPath "disabled-targets.txt"

function Add-DisabledTarget([string]$Path) {
    if (-not $Path) { return }
    $Path = $Path.Trim()
    try { $AbsPath = [System.IO.Path]::GetFullPath($Path) } catch { $AbsPath = $Path }

    $Lines = @()
    if (Test-Path $DisabledTargetsFile) {
        $Lines = @(Get-Content $DisabledTargetsFile -Encoding UTF8 -ErrorAction SilentlyContinue)
    }

    $Exists = $false
    foreach ($Line in $Lines) {
        if (-not $Line -or $Line.Trim().StartsWith("#")) { continue }
        try { $LineAbs = [System.IO.Path]::GetFullPath($Line.Trim()) } catch { $LineAbs = $Line.Trim() }
        if ($LineAbs -eq $AbsPath) {
            $Exists = $true
            break
        }
    }

    if (-not $Exists) {
        $Lines += $AbsPath
        try {
            $Lines -join "`n" | Set-Content -Path $DisabledTargetsFile -Encoding UTF8 -Force
        } catch {}
    }
}

function Remove-DisabledTarget([string]$Path) {
    if (-not $Path) { return }
    $Path = $Path.Trim()
    try { $AbsPath = [System.IO.Path]::GetFullPath($Path) } catch { $AbsPath = $Path }

    if (-not (Test-Path $DisabledTargetsFile)) { return }
    $Lines = @(Get-Content $DisabledTargetsFile -Encoding UTF8 -ErrorAction SilentlyContinue)
    $NewLines = @()
    $Updated = $false
    foreach ($Line in $Lines) {
        if (-not $Line -or $Line.Trim().StartsWith("#")) {
            $NewLines += $Line
            continue
        }
        try { $LineAbs = [System.IO.Path]::GetFullPath($Line.Trim()) } catch { $LineAbs = $Line.Trim() }
        if ($LineAbs -eq $AbsPath) {
            $Updated = $true
        } else {
            $NewLines += $Line
        }
    }

    if ($Updated) {
        try {
            $NewLines -join "`n" | Set-Content -Path $DisabledTargetsFile -Encoding UTF8 -Force
        } catch {}
    }
}

function Get-DisabledTargets {
    $Set = @{}
    if (Test-Path $DisabledTargetsFile) {
        $Lines = Get-Content $DisabledTargetsFile -Encoding UTF8 -ErrorAction SilentlyContinue
        foreach ($Line in $Lines) {
            $Stripped = $Line.Trim()
            if ($Stripped -and -not $Stripped.StartsWith("#")) {
                try { $Norm = [System.IO.Path]::GetFullPath($Stripped) } catch { $Norm = $Stripped }
                $Set[$Norm] = $true
            }
        }
    }
    return $Set
}
$WebUIDir = Join-Path -Path $ScriptDir -ChildPath "webui"
if (-not (Test-Path $WebUIDir)) {
    $WebUIDir = Join-Path -Path (Split-Path -Path $MyInvocation.MyCommand.Definition -Parent) -ChildPath "webui"
}

# ---- Load agents from agents.json (single source of truth) ----
$AgentsJsonFile = Join-Path $ScriptDir "agents.json"
function Load-DefaultAgents {
    if (Test-Path $AgentsJsonFile) {
        try {
            $Data = Get-Content $AgentsJsonFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $List = [System.Collections.ArrayList]::new()
            foreach ($Agent in $Data.agents) {
                $WinPath = $Agent.win_path -replace '%USERPROFILE%', $Home
                if ($WinPath) { [void]$List.Add(@{ Name=$Agent.name; Path=$WinPath }) }
                if ($Agent.win_extra_path) {
                    $ExtraPath = $Agent.win_extra_path -replace '%APPDATA%', $env:APPDATA
                    if ($ExtraPath) { [void]$List.Add(@{ Name=$Agent.name; Path=$ExtraPath }) }
                }
            }
            if ($List.Count -gt 0) { return @($List) }
        } catch {}
    }
    # Fallback: hardcoded defaults (kept in sync with agents.json)
    return @(
        @{ Name="Antigravity CLI"; Path="$Home\.gemini\config\skills" },
        @{ Name="Antigravity IDE"; Path="$Home\.gemini\antigravity\skills" },
        @{ Name="Codex"; Path="$Home\.codex\skills" },
        @{ Name="Claude Code"; Path="$Home\.claude\skills" },
        @{ Name="GitHub Copilot"; Path="$Home\.copilot\skills" },
        @{ Name="Pi"; Path="$Home\.pi\agent\skills" },
        @{ Name="OpenCode"; Path="$Home\.config\opencode\skills" },
        @{ Name="Kimi Code"; Path="$Home\.kimi\skills" },
        @{ Name="ZCode"; Path="$Home\.zcode\skills" },
        @{ Name="Trae (Global)"; Path="$Home\.trae\skills" },
        @{ Name="Trae (Global)"; Path="$env:APPDATA\Trae\skills" },
        @{ Name="Trae CN"; Path="$Home\.trae-cn\skills" },
        @{ Name="Trae CN"; Path="$env:APPDATA\Trae-CN\skills" },
        @{ Name="OpenClaw"; Path="$Home\.openclaw\skills" },
        @{ Name="Hermes Agent"; Path="$Home\.hermes\skills" },
        @{ Name="Proma"; Path="$Home\.proma\default-skills" },
        @{ Name="Cursor"; Path="$Home\.cursor\skills" },
        @{ Name="Kiro Agent"; Path="$Home\.kiro\skills" },
        @{ Name="Junie (JetBrains)"; Path="$Home\.junie\skills" },
        @{ Name="Cline"; Path="$Home\.cline\skills" },
        @{ Name="Roo Code"; Path="$Home\.roo\skills" },
        @{ Name="Run"; Path="$Home\.run\global-skills\skills" },
        @{ Name="Warp"; Path="$Home\.warp\skills" },
        @{ Name="Windsurf"; Path="$Home\.codeium\windsurf\skills" },
        @{ Name="Firebender"; Path="$Home\.firebender\skills" },
        @{ Name="Augment"; Path="$Home\.augment\skills" },
        @{ Name="Continue"; Path="$Home\.continue\skills" },
        @{ Name="Goose"; Path="$Home\.config\goose\skills" },
        @{ Name="Agents (Standard)"; Path="$Home\.agents\skills" },
        @{ Name="Qoder"; Path="$Home\.qoder\skills" },
        @{ Name="Qwen Code"; Path="$Home\.qwen\skills" },
        @{ Name="CodeBuddy"; Path="$Home\.codebuddy\skills" },
        @{ Name="Amp"; Path="$Home\.config\agents\skills" },
        @{ Name="OpenHands"; Path="$Home\.openhands\skills" },
        @{ Name="Kilo Code"; Path="$Home\.kilocode\skills" },
        @{ Name="Zencoder"; Path="$Home\.zencoder\skills" },
        @{ Name="iFlow CLI"; Path="$Home\.iflow\skills" },
        @{ Name="Droid"; Path="$Home\.factory\skills" },
        @{ Name="Devin for Terminal"; Path="$Home\.config\devin\skills" },
        @{ Name="WorkBuddy"; Path="$Home\.workbuddy\skills" },
        @{ Name="QClaw"; Path="$Home\.qclaw\skills" },
        @{ Name="CodeWhale"; Path="$Home\.codewhale\skills" },
        @{ Name="QoderWork CN"; Path="$Home\.qoderworkcn\skills" },
        @{ Name="Qoder CN"; Path="$Home\.qoder-cn\skills" },
        @{ Name="MiniMax Code"; Path="$Home\.mavis\skills" }
    )
}
$DefaultAgents = Load-DefaultAgents

# Ensure ~/.qoder-cn/skills exists — Qoder CN relies on EasySkills to
# create the path if it does not already exist.
$qoderCnSkillsDir = Join-Path $Home ".qoder-cn\skills"
if (-not (Test-Path $qoderCnSkillsDir)) {
    New-Item -Path $qoderCnSkillsDir -ItemType Directory -Force | Out-Null
}

$ExcludeNames = @("_maintenance", ".git", "node_modules", "dist", "docs")
$GitHubRepo = "RunhuaHuang/EasySkills"
$GitHubApiLatestRelease = "https://api.github.com/repos/$GitHubRepo/releases/latest"
$GitHubLatestRelease = "https://github.com/$GitHubRepo/releases/latest"
$GitHubReleaseTagPrefix = "https://github.com/$GitHubRepo/releases/tag/"

$VersionFile = Join-Path -Path $ScriptDir -ChildPath ".version"
function Get-EasySkillsVersion {
    if (Test-Path $VersionFile) {
        return (Get-Content $VersionFile -ErrorAction SilentlyContinue | Select-Object -First 1).Trim()
    }
    return "unknown"
}

function New-ReleaseInfoFromTag([string]$Tag, [string]$Name = "") {
    if (-not $Name) { $Name = $Tag }
    return @{
        success = $true
        tag_name = $Tag
        name = $Name
        html_url = "https://github.com/$GitHubRepo/releases/tag/$Tag"
        published_at = ""
        tarball_url = "https://github.com/$GitHubRepo/archive/refs/tags/$Tag.tar.gz"
        zipball_url = "https://github.com/$GitHubRepo/archive/refs/tags/$Tag.zip"
        draft = $false
        prerelease = $false
    }
}

function Get-LatestReleaseViaRedirect {
    try {
        $Response = Invoke-WebRequest -Uri $GitHubLatestRelease -MaximumRedirection 5 -UseBasicParsing -TimeoutSec 15 -Headers @{ "User-Agent" = "EasySkills-WebUI" }
        $FinalUrl = $null
        if ($Response.BaseResponse.ResponseUri) {
            $FinalUrl = $Response.BaseResponse.ResponseUri.AbsoluteUri
        } elseif ($Response.BaseResponse.RequestMessage -and $Response.BaseResponse.RequestMessage.RequestUri) {
            $FinalUrl = $Response.BaseResponse.RequestMessage.RequestUri.AbsoluteUri
        }
        if (-not $FinalUrl -or -not $FinalUrl.StartsWith($GitHubReleaseTagPrefix)) {
            return @{ success = $false; message = "Could not determine latest version" }
        }
        $Tag = [System.Uri]::UnescapeDataString($FinalUrl.Substring($GitHubReleaseTagPrefix.Length).Trim("/"))
        if (-not $Tag) {
            return @{ success = $false; message = "Could not determine latest version" }
        }
        return New-ReleaseInfoFromTag $Tag
    } catch {
        return @{ success = $false; message = "Failed to fetch release redirect: $_" }
    }
}

function Get-LatestRelease {
    $Headers = @{ "Accept" = "application/vnd.github+json"; "User-Agent" = "EasySkills-WebUI" }
    try {
        $Release = Invoke-RestMethod -Uri $GitHubApiLatestRelease -Headers $Headers -TimeoutSec 15
    } catch {
        $Fallback = Get-LatestReleaseViaRedirect
        if ($Fallback.success) {
            $Fallback.message = "GitHub API unavailable; used release redirect fallback ($_)"
            return $Fallback
        }
        return @{ success = $false; message = "Failed to fetch release info: $_" }
    }

    $LatestTag = $Release.tag_name
    if (-not $LatestTag) {
        return @{ success = $false; message = "Could not determine latest version" }
    }

    return @{
        success = $true
        tag_name = $LatestTag
        name = $Release.name
        html_url = $Release.html_url
        published_at = $Release.published_at
        tarball_url = $Release.tarball_url
        zipball_url = $Release.zipball_url
        draft = [bool]$Release.draft
        prerelease = [bool]$Release.prerelease
    }
}

# --------------------------------------------------------------
# Helpers
# --------------------------------------------------------------

function Get-AgentRoot([string]$Target) {
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
        return (Split-Path $Target -Parent)
    }
}

function Get-CustomTargets {
    if (-not (Test-Path $CustomTargetsFile)) { return @() }
    $Lines = Get-Content $CustomTargetsFile -ErrorAction SilentlyContinue
    $Targets = @()
    foreach ($Line in $Lines) {
        $TLine = $Line.Trim()
        if ($TLine -and -not $TLine.StartsWith("#")) {
            $Targets += $TLine
        }
    }
    return $Targets
}

function Is-PromaWorkspaceTarget([string]$PathStr) {
    $Normalized = $PathStr -replace '/', '\'
    return ($Normalized -like "*\.proma\agent-workspaces\*")
}

function Get-AgentNameFromPath([string]$PathStr) {
    if ($PathStr -like "*\.gemini\antigravity\*") { return "Antigravity IDE" }
    if ($PathStr -like "*\.gemini\*") { return "Antigravity CLI" }
    if ($PathStr -like "*\.codex\*") { return "Codex" }
    if ($PathStr -like "*\.claude\*") { return "Claude Code" }
    if ($PathStr -like "*\.copilot\*") { return "GitHub Copilot" }
    if ($PathStr -like "*\.pi\*") { return "Pi" }
    if ($PathStr -like "*\.config\opencode\*") { return "OpenCode" }
    if ($PathStr -like "*\.kimi\*") { return "Kimi Code" }
    if ($PathStr -like "*\.zcode\*") { return "ZCode" }
    if ($PathStr -like "*\.trae-cn\*" -or $PathStr -like "*\Trae-CN\*") { return "Trae CN" }
    if ($PathStr -like "*\.trae\*" -or $PathStr -like "*\Trae\*") { return "Trae (Global)" }
    if ($PathStr -like "*\.openclaw\*") { return "OpenClaw" }
    if ($PathStr -like "*\.hermes\*") { return "Hermes Agent" }
    if ($PathStr -like "*\.proma\*") { return "Proma" }
    if ($PathStr -like "*\.cursor\*") { return "Cursor" }
    if ($PathStr -like "*\.kiro\*") { return "Kiro Agent" }
    if ($PathStr -like "*\.junie\*") { return "Junie (JetBrains)" }
    if ($PathStr -like "*\.cline\*") { return "Cline" }
    if ($PathStr -like "*\.roo\*") { return "Roo Code" }
    if ($PathStr -like "*\.warp\*") { return "Warp" }
    if ($PathStr -like "*\.codeium\windsurf\*") { return "Windsurf" }
    if ($PathStr -like "*\.firebender\*") { return "Firebender" }
    if ($PathStr -like "*\.augment\*") { return "Augment" }
    if ($PathStr -like "*\.continue\*") { return "Continue" }
    if ($PathStr -like "*\.config\goose\*") { return "Goose" }
    if ($PathStr -like "*\.qoder\*") { return "Qoder" }
    if ($PathStr -like "*\.qwen\*") { return "Qwen Code" }
    if ($PathStr -like "*\.codebuddy\*") { return "CodeBuddy" }
    if ($PathStr -like "*\.config\agents\*") { return "Amp" }
    if ($PathStr -like "*\.openhands\*") { return "OpenHands" }
    if ($PathStr -like "*\.kilocode\*") { return "Kilo Code" }
    if ($PathStr -like "*\.zencoder\*") { return "Zencoder" }
    if ($PathStr -like "*\.iflow\*") { return "iFlow CLI" }
    if ($PathStr -like "*\.factory\*") { return "Droid" }
    if ($PathStr -like "*\.config\devin\*") { return "Devin for Terminal" }
    if ($PathStr -like "*\.workbuddy\*") { return "WorkBuddy" }
    if ($PathStr -like "*\.qclaw\*") { return "QClaw" }
    if ($PathStr -like "*\.codewhale\*") { return "CodeWhale" }
    if ($PathStr -like "*\.qoderworkcn\*") { return "QoderWork CN" }
    if ($PathStr -like "*\.qoder-cn\*") { return "Qoder CN" }
    if ($PathStr -like "*\.mavis\*") { return "MiniMax Code" }
    if ($PathStr -like "*\.agents\*") { return "Agents (Standard)" }
    if ($PathStr -like "*\.run\*") { return "Run" }
    return "Custom Agent"
}

function Is-Mapped([string]$TargetPath, $DisabledSet, [bool]$HasSkills) {
    try { $NormPath = [System.IO.Path]::GetFullPath($TargetPath) } catch { $NormPath = $TargetPath }
    if ($DisabledSet.ContainsKey($NormPath)) { return $false }

    if (-not (Test-Path $TargetPath -PathType Container)) { return $false }
    if (-not $HasSkills) { return $true }

    $CentralResolved = (Resolve-Path -LiteralPath $CentralDir).ProviderPath
    try {
        $Items = Get-ChildItem -Path $TargetPath -Force
        foreach ($Item in $Items) {
            if ($Item.Attributes -match "ReparsePoint") {
                $LinkTarget = $Item.Target
                $ResolvedTarget = $null
                if ($LinkTarget) {
                    try {
                        $ResolvedTarget = (Resolve-Path -LiteralPath $LinkTarget).ProviderPath
                    } catch {
                        try { $ResolvedTarget = [System.IO.Path]::GetFullPath($LinkTarget) } catch {}
                    }
                }
                if ($ResolvedTarget) {
                    $ParentResolved = Split-Path -Path $ResolvedTarget -Parent
                    if ($ParentResolved -eq $CentralResolved) {
                        return $true
                    }
                }
            }
        }
    } catch {}
    return $false
}

function Get-WatcherStatus {
    # Use WMI directly for PS 5.1 compatibility (Get-Process lacks CommandLine in PS 5.1)
    try {
        $WmiProc = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' AND CommandLine LIKE '%watcher-service.ps1%'" -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($WmiProc) {
            return @{ running = $true; pid = $WmiProc.ProcessId }
        }
    } catch {}
    return @{ running = $false; pid = $null }
}

function Get-SkillsData {
    $Skills = @()
    if (Test-Path $CentralDir) {
        $Items = Get-ChildItem -Path $CentralDir -Directory
        foreach ($Item in $Items) {
            $Name = $Item.Name
            if ($Name.StartsWith("_") -or $Name.StartsWith(".") -or $ExcludeNames -contains $Name) { continue }
            $HasMd = (Test-Path (Join-Path $Item.FullName "SKILL.md")) -or (Test-Path (Join-Path $Item.FullName "README_SYSTEM.md"))
            # An external-link skill is a reparse point (junction/symlink) whose
            # target still exists — listed and forwarded normally, but marked so
            # the UI can flag it as fragile. (Dangling links are not returned by
            # Get-ChildItem -Directory, mirroring the Python backend.)
            $IsExternal = $false
            try { if ($Item.Attributes -match "ReparsePoint") { $IsExternal = $true } } catch {}
            $Skills += @{
                name = $Name
                path = $Item.FullName
                has_skill_md = $HasMd
                is_external_link = $IsExternal
            }
        }
    }
    return $Skills
}

function Get-CentralDirWarnings {
    # Read-only link-health probe for /api/status, mirroring get_central_dir_warnings
    # in webui.py. Dangling links are auto-pruned by Run-Sync in deploy.ps1.
    $Dangling = 0
    $External = 0
    if (Test-Path $CentralDir) {
        try {
            $Entries = Get-ChildItem -Path $CentralDir -Force -ErrorAction SilentlyContinue
            foreach ($Entry in $Entries) {
                $IsReparse = $false
                try { if ($Entry.Attributes -match "ReparsePoint") { $IsReparse = $true } } catch {}
                if (-not $IsReparse) { continue }
                $EName = $Entry.Name
                if ($EName.StartsWith("_") -or $EName.StartsWith(".") -or $ExcludeNames -contains $EName) { continue }
                if (-not (Test-Path $Entry.FullName)) { $Dangling++ } else { $External++ }
            }
        } catch {}
    }
    return @{ dangling_count = $Dangling; external_link_count = $External }
}

function Get-AgentsData {
    $Agents = @()
    $Seen = @{}
    $DisabledSet = Get-DisabledTargets
    $HasSkills = @(Get-SkillsData).Count -gt 0

    $CustomTargets = Get-CustomTargets
    $CustomOverrides = @{}
    $CustomList = @()

    foreach ($Ct in $CustomTargets) {
        if ($Ct.Contains("=")) {
            $Parts = $Ct.Split("=", 2)
            $CtName = $Parts[0].Trim()
            $CtPath = $Parts[1].Trim()
            if (Is-PromaWorkspaceTarget $CtPath) { continue }
            $CustomOverrides[$CtName] = $CtPath
        } else {
            $CtPath = $Ct.Trim()
            if (Is-PromaWorkspaceTarget $CtPath) { continue }
            $CtName = Get-AgentNameFromPath $CtPath
            $CustomList += @{ Name = $CtName; Path = $CtPath }
        }
    }

    # 1. Add Default Agents (checking for overrides)
    foreach ($Def in $DefaultAgents) {
        $Path = $Def.Path
        if ($CustomOverrides.ContainsKey($Def.Name)) {
            $Path = $CustomOverrides[$Def.Name]
        }
        if ($Seen.ContainsKey($Path)) { continue }
        $Seen[$Path] = $true

        $Root = Get-AgentRoot $Path
        $Active = Test-Path $Root

        $Agents += @{
            name = $Def.Name
            path = $Path
            active = $Active
            mapped = if ($Active) { Is-Mapped $Path $DisabledSet $HasSkills } else { $false }
            custom = $CustomOverrides.ContainsKey($Def.Name)
        }
    }

    # 2. Add Custom Agents (that don't match any default name override)
    foreach ($Ct in $CustomList) {
        if ($Seen.ContainsKey($Ct.Path)) { continue }
        $Seen[$Ct.Path] = $true

        $Root = Get-AgentRoot $Ct.Path
        $Active = Test-Path $Root

        $Agents += @{
            name = $Ct.Name
            path = $Ct.Path
            active = $Active
            mapped = if ($Active) { Is-Mapped $Ct.Path $DisabledSet $HasSkills } else { $false }
            custom = $true
        }
    }
    return $Agents
}

function Is-PromaWorkspaceAgent($Agent) {
    return (($Agent.name -like "Proma Workspace*") -or (Is-PromaWorkspaceTarget $Agent.path))
}

function Get-VisibleAgentsData {
    return @(Get-AgentsData | Where-Object { -not (Is-PromaWorkspaceAgent $_) })
}

function Start-WatcherTask {
    # Narrow path for the WebUI "start watcher" button. Just nudges the
    # already-registered Scheduled Task — does NOT call register-tasks.ps1
    # (which would re-register both tasks and kill webui.ps1 mid-request,
    # causing a "Network offline" flash in the browser).
    try {
        if (-not (Get-Command Start-ScheduledTask -ErrorAction SilentlyContinue)) {
            return (Run-DeployCommand @("-Watch"))
        }
        $task = Get-ScheduledTask -TaskName "EasySkills Watcher" -ErrorAction SilentlyContinue
        if (-not $task) {
            # Task missing (legacy / partially-uninstalled state) — fall back
            # to full registration. This is the slow path that may briefly
            # disrupt the WebUI, but it's a rare upgrade scenario.
            return (Run-DeployCommand @("-Watch"))
        }
        # Re-enable in case a previous Stop disabled it.
        if ($task.State -eq 'Disabled' -and (Get-Command Enable-ScheduledTask -ErrorAction SilentlyContinue)) {
            try { Enable-ScheduledTask -TaskName "EasySkills Watcher" -ErrorAction SilentlyContinue | Out-Null } catch {}
        }
        Start-ScheduledTask -TaskName "EasySkills Watcher" -ErrorAction Stop
        return @{ success = $true; output = "Watcher task started."; message = "Watcher started." }
    } catch {
        return @{ success = $false; output = $_.Exception.Message; message = "Failed to start watcher: $($_.Exception.Message)" }
    }
}

function Stop-WatcherTask {
    # Narrow path for the WebUI "stop watcher" button. Stops + disables the
    # Scheduled Task (so it won't auto-restart at next logon) and kills the
    # currently-running watcher-service.ps1 child — without touching the
    # WebUI task or webui.ps1.
    try {
        $stoppedSomething = $false
        if (Get-Command Stop-ScheduledTask -ErrorAction SilentlyContinue) {
            $task = Get-ScheduledTask -TaskName "EasySkills Watcher" -ErrorAction SilentlyContinue
            if ($task) {
                try { Stop-ScheduledTask -TaskName "EasySkills Watcher" -ErrorAction SilentlyContinue } catch {}
                if (Get-Command Disable-ScheduledTask -ErrorAction SilentlyContinue) {
                    try { Disable-ScheduledTask -TaskName "EasySkills Watcher" -ErrorAction SilentlyContinue | Out-Null } catch {}
                }
                $stoppedSomething = $true
            }
        }
        # Kill any lingering watcher-service.ps1 process (the task action
        # may have already exited but the spawned PS child can survive).
        try {
            $procs = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' AND CommandLine LIKE '%watcher-service.ps1%'" -ErrorAction SilentlyContinue
            foreach ($p in $procs) {
                try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue; $stoppedSomething = $true } catch {}
            }
        } catch {}

        if ($stoppedSomething) {
            return @{ success = $true; output = "Watcher task stopped and disabled."; message = "Watcher stopped." }
        }
        # Nothing to stop via the fast path — fall back to legacy unwatch
        # (still preserves the WebUI via -KeepWebUI).
        return (Run-DeployCommand @("-Unwatch", "-KeepWebUI"))
    } catch {
        return @{ success = $false; output = $_.Exception.Message; message = "Failed to stop watcher: $($_.Exception.Message)" }
    }
}

function Quote-ProcessArgument([string]$Arg) {
    if ($null -eq $Arg) { return '""' }
    if ($Arg -eq "") { return '""' }
    if ($Arg -notmatch '[\s"]') { return $Arg }

    $Out = '"'
    $Backslashes = 0
    foreach ($Ch in $Arg.ToCharArray()) {
        if ($Ch -eq '\') {
            $Backslashes += 1
            continue
        }
        if ($Ch -eq '"') {
            if ($Backslashes -gt 0) { $Out += ('\' * ($Backslashes * 2)) }
            $Out += '\"'
            $Backslashes = 0
            continue
        }
        if ($Backslashes -gt 0) {
            $Out += ('\' * $Backslashes)
            $Backslashes = 0
        }
        $Out += $Ch
    }
    if ($Backslashes -gt 0) { $Out += ('\' * ($Backslashes * 2)) }
    $Out += '"'
    return $Out
}

function Run-DeployCommand([string[]]$ArgsArr) {
    try {
        $DeployScript = Join-Path $ScriptDir "deploy.ps1"
        $TempOut = [System.IO.Path]::GetTempFileName()
        $TempErr = [System.IO.Path]::GetTempFileName()
        $ArgList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $DeployScript) + $ArgsArr

        $ProcInfo = New-Object System.Diagnostics.ProcessStartInfo
        $ProcInfo.FileName = "powershell.exe"
        $ProcInfo.Arguments = (($ArgList | ForEach-Object { Quote-ProcessArgument ([string]$_) }) -join " ")
        $ProcInfo.UseShellExecute = $false
        $ProcInfo.RedirectStandardOutput = $true
        $ProcInfo.RedirectStandardError = $true
        $ProcInfo.CreateNoWindow = $true

        $Process = [System.Diagnostics.Process]::Start($ProcInfo)
        # Read streams first to prevent deadlock, then wait
        $StdOut = $Process.StandardOutput.ReadToEnd()
        $StdErr = $Process.StandardError.ReadToEnd()
        $Finished = $Process.WaitForExit(30000)
        if (-not $Finished) { try { $Process.Kill() } catch {} }

        $ExitCode = if ($Finished) { $Process.ExitCode } else { 1 }
        $Combined = ("$StdOut$StdErr").Trim()
        $Msg = if ($Combined) { $Combined } elseif ($ExitCode -eq 0) { "Command completed successfully" } else { "Command failed" }
        return @{ success = ($ExitCode -eq 0); output = $Combined; message = $Msg }
    } catch {
        return @{ success = $false; output = $_.Exception.Message; message = $_.Exception.Message }
    }
}

function Update-AgentPath([string]$Name, [string]$OldPath, [string]$NewPath) {
    if (-not $NewPath) {
        return @{ success = $false; message = "New path cannot be empty" }
    }
    $NewPath = $NewPath.Trim()
    try { $NewPath = [System.IO.Path]::GetFullPath($NewPath) } catch {}

    $Lines = @()
    if (Test-Path $CustomTargetsFile) {
        $Lines = @(Get-Content $CustomTargetsFile -Encoding UTF8 -ErrorAction SilentlyContinue)
    }

    $Updated = $false
    $NewLines = @()
    foreach ($Line in $Lines) {
        $Stripped = $Line.Trim()
        if (-not $Stripped -or $Stripped.StartsWith("#")) {
            $NewLines += $Line
            continue
        }
        $LineName = ""
        $LinePath = ""
        if ($Stripped.Contains("=")) {
            $Parts = $Stripped.Split("=", 2)
            $LineName = $Parts[0].Trim()
            $LinePath = $Parts[1].Trim()
        } else {
            $LinePath = $Stripped
            $LineName = Get-AgentNameFromPath $LinePath
        }
        if ($LinePath -eq $OldPath -or ($LineName -eq $Name -and $Name -ne "Custom Agent")) {
            $NewLines += "$Name=$NewPath"
            $Updated = $true
        } else {
            $NewLines += $Line
        }
    }
    if (-not $Updated) {
        $NewLines += "$Name=$NewPath"
    }

    try {
        $NewLines -join "`n" | Set-Content -Path $CustomTargetsFile -Encoding UTF8 -Force
    } catch {
        return @{ success = $false; message = "Failed to write config: $_" }
    }

    Remove-DisabledTarget $OldPath
    Remove-DisabledTarget $NewPath
    Do-Map $NewPath | Out-Null
    return @{ success = $true; message = "Updated $Name to $NewPath" }
}

function Do-Map([string]$TargetPath) {
    if (-not $TargetPath -or -not $TargetPath.Trim()) {
        return @{ success = $false; message = "Target path cannot be empty" }
    }
    $TargetPath = $TargetPath.Trim()
    Remove-DisabledTarget $TargetPath
    try {
        if (!(Test-Path $TargetPath)) {
            New-Item -ItemType Directory -Path $TargetPath -Force | Out-Null
        }
        # Per-skill links

        # Map skills
        $Skills = Get-ChildItem -Path $CentralDir -Directory
        foreach ($Skill in $Skills) {
            $Name = $Skill.Name
            if ($Name.StartsWith("_") -or $Name.StartsWith(".") -or $ExcludeNames -contains $Name) { continue }
            $Dest = Join-Path $TargetPath $Name
            if (Test-Path $Dest) {
                $Item = Get-Item $Dest
                if ($Item.Attributes -match "ReparsePoint") {
                    Remove-Item $Dest -Recurse -Force
                }
            }
            if (-not (Test-Path $Dest)) {
                New-Item -ItemType Junction -Path $Dest -Value $Skill.FullName | Out-Null
            }
        }
        return @{ success = $true; message = "Mapped to $TargetPath" }
    } catch {
        return @{ success = $false; message = $_.Exception.Message }
    }
}

function Get-PayloadValue($Item, [string]$Name) {
    if ($Item -is [hashtable]) {
        if ($Item.ContainsKey($Name)) { return $Item[$Name] }
        return $null
    }
    if ($Item -and $Item.PSObject -and $Item.PSObject.Properties[$Name]) {
        return $Item.PSObject.Properties[$Name].Value
    }
    return $null
}

function Test-SkillName([string]$Name) {
    $Clean = if ($Name) { $Name.Trim() } else { "" }
    if (-not $Clean) { return @{ ok = $false; value = "Skill name cannot be empty" } }
    if ($Clean.StartsWith("_") -or $Clean.StartsWith(".") -or ($ExcludeNames -contains $Clean)) {
        return @{ ok = $false; value = "Reserved skill name" }
    }
    if ($Clean.Contains("/") -or $Clean.Contains("\") -or $Clean.Contains([char]0) -or $Clean -eq "." -or $Clean -eq "..") {
        return @{ ok = $false; value = "Invalid skill name" }
    }
    return @{ ok = $true; value = $Clean }
}

function ConvertTo-SafeRelativePath([string]$PathValue) {
    if (-not $PathValue -or $PathValue.Contains([char]0)) { return $null }
    $Normalized = $PathValue.Replace("\", "/")
    if ($Normalized.StartsWith("/") -or $Normalized.Contains(":")) { return $null }
    $Parts = $Normalized.Split("/")
    foreach ($Part in $Parts) {
        if (-not $Part -or $Part -eq "." -or $Part -eq "..") { return $null }
    }
    return ($Parts -join [System.IO.Path]::DirectorySeparatorChar)
}

function Import-SkillFolder([string]$Name, $Files) {
    $NameCheck = Test-SkillName $Name
    if (-not $NameCheck.ok) { return @{ success = $false; message = $NameCheck.value } }
    $CleanName = $NameCheck.value
    if (-not $Files -or @($Files).Count -eq 0) {
        return @{ success = $false; message = "No files were provided" }
    }

    if (-not (Test-Path $CentralDir)) {
        New-Item -ItemType Directory -Path $CentralDir -Force | Out-Null
    }
    $Target = Join-Path $CentralDir $CleanName
    if (Test-Path $Target) {
        return @{ success = $false; message = "Skill already exists: $CleanName" }
    }

    $Prepared = @()
    $HasSkillMd = $false
    foreach ($File in @($Files)) {
        $RelRaw = [string](Get-PayloadValue $File "path")
        $Rel = ConvertTo-SafeRelativePath $RelRaw
        if (-not $Rel) { return @{ success = $false; message = "Invalid file path in upload" } }
        $Data = Get-PayloadValue $File "data"
        if (-not ($Data -is [string])) {
            return @{ success = $false; message = "Invalid file data: $RelRaw" }
        }
        try {
            $Bytes = [System.Convert]::FromBase64String($Data)
        } catch {
            return @{ success = $false; message = "Invalid base64 data: $RelRaw" }
        }
        if ($RelRaw.Replace("\", "/") -eq "SKILL.md") { $HasSkillMd = $true }
        $Prepared += @{ rel = $Rel; bytes = $Bytes }
    }
    if (-not $HasSkillMd) {
        return @{ success = $false; message = "Selected folder must contain SKILL.md at its root" }
    }

    $TmpDir = Join-Path $CentralDir ".import-$([Guid]::NewGuid().ToString('N'))"
    try {
        New-Item -ItemType Directory -Path $TmpDir -Force | Out-Null
        foreach ($Item in $Prepared) {
            $Dest = Join-Path $TmpDir $Item.rel
            $Parent = Split-Path -Path $Dest -Parent
            if (-not (Test-Path $Parent)) {
                New-Item -ItemType Directory -Path $Parent -Force | Out-Null
            }
            [System.IO.File]::WriteAllBytes($Dest, [byte[]]$Item.bytes)
        }
        Move-Item -LiteralPath $TmpDir -Destination $Target
    } catch {
        try { if (Test-Path $TmpDir) { Remove-Item -LiteralPath $TmpDir -Recurse -Force } } catch {}
        return @{ success = $false; message = "Import failed: $($_.Exception.Message)" }
    }

    $Sync = Run-DeployCommand @("-Sync")
    $Msg = "Imported $CleanName"
    if ($Sync.message) { $Msg = "$Msg`n$($Sync.message)" }
    return @{ success = $true; message = $Msg; skill = $CleanName }
}

function Delete-Skill([string]$Name) {
    $NameCheck = Test-SkillName $Name
    if (-not $NameCheck.ok) { return @{ success = $false; message = $NameCheck.value } }
    $CleanName = $NameCheck.value
    $Target = Join-Path $CentralDir $CleanName
    if (-not (Test-Path $Target)) {
        return @{ success = $false; message = "Skill not found: $CleanName" }
    }
    try {
        Remove-Item -LiteralPath $Target -Recurse -Force
    } catch {
        return @{ success = $false; message = "Delete failed: $($_.Exception.Message)" }
    }

    $Cleanup = Run-DeployCommand @("-Cleanup")
    $Sync = Run-DeployCommand @("-Sync")
    $Msg = "Deleted $CleanName"
    foreach ($Result in @($Cleanup, $Sync)) {
        if ($Result.message) { $Msg = "$Msg`n$($Result.message)" }
    }
    return @{ success = $true; message = $Msg; skill = $CleanName }
}

function Run-SelfUpdate {
    try {
        $Release = Get-LatestRelease
        if (-not $Release.success) {
            return $Release
        }

        $LatestTag = $Release.tag_name
        if (-not $LatestTag) {
            return @{ success = $false; message = "Could not determine latest version" }
        }

        $ZipUrl = $Release.zipball_url
        if (-not $ZipUrl) {
            return @{ success = $false; message = "No download URL in release" }
        }

        $TmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "EasySkills_update_$(Get-Random)"
        New-Item -ItemType Directory -Path $TmpDir -Force | Out-Null

        try {
            $ZipPath = Join-Path $TmpDir "release.zip"
            $Headers = @{ "Accept" = "application/vnd.github+json"; "User-Agent" = "EasySkills-WebUI" }
            Invoke-WebRequest -Uri $ZipUrl -OutFile $ZipPath -Headers $Headers -TimeoutSec 60 -UseBasicParsing

            # --- Integrity check: re-download and compare SHA-256 ---
            $VerifyPath = Join-Path $TmpDir "release_verify.zip"
            Invoke-WebRequest -Uri $ZipUrl -OutFile $VerifyPath -Headers $Headers -TimeoutSec 60 -UseBasicParsing
            $Hash1 = (Get-FileHash -Path $ZipPath -Algorithm SHA256).Hash
            $Hash2 = (Get-FileHash -Path $VerifyPath -Algorithm SHA256).Hash
            if ($Hash1 -ne $Hash2) {
                return @{ success = $false; message = "Integrity check failed: download digest mismatch. Aborting update." }
            }
            Remove-Item $VerifyPath -Force

            $ExtractDir = Join-Path $TmpDir "extracted"
            Expand-Archive -Path $ZipPath -DestinationPath $ExtractDir -Force

            $SrcRoot = Get-ChildItem -Path $ExtractDir -Directory | Select-Object -First 1
            if (-not $SrcRoot) {
                return @{ success = $false; message = "Empty archive" }
            }

            # Preserve user runtime files (not shipped in the release zip)
            $CustomBackup = $null
            if (Test-Path $CustomTargetsFile) {
                $CustomBackup = Get-Content $CustomTargetsFile -Raw -Encoding UTF8
            }
            $DisabledBackup = $null
            if (Test-Path $DisabledTargetsFile) {
                $DisabledBackup = Get-Content $DisabledTargetsFile -Raw -Encoding UTF8
            }

            # Backup current _maintenance for rollback (atomic via temp rename)
            $DestMaint = Join-Path $CentralDir "_maintenance"
            $BackupMaint = Join-Path $CentralDir "_maintenance.bak"
            $BackupMaintNew = Join-Path $CentralDir "_maintenance.bak.new"

            $SrcMaint = Join-Path $SrcRoot.FullName "_maintenance"
            if (-not (Test-Path $SrcMaint)) {
                return @{ success = $false; message = "Archive does not contain _maintenance/" }
            }

            # Build new _maintenance in a temp dir, then rename atomically
            $NewMaintTmp = Join-Path $CentralDir "_maintenance.new"
            if (Test-Path $NewMaintTmp) { Remove-Item $NewMaintTmp -Recurse -Force }
            Copy-Item $SrcMaint $NewMaintTmp -Recurse -Force

            $SrcReadme = Join-Path $SrcRoot.FullName "README_SYSTEM.md"
            if (Test-Path $SrcReadme) {
                Copy-Item $SrcReadme (Join-Path $CentralDir "README_SYSTEM.md") -Force
            } else {
                $SrcOld = Join-Path $SrcRoot.FullName "SKILL.md"
                if (Test-Path $SrcOld) {
                    Copy-Item $SrcOld (Join-Path $CentralDir "README_SYSTEM.md") -Force
                }
            }

            if (Test-Path $BackupMaint) {
                if (Test-Path $BackupMaintNew) { Remove-Item $BackupMaintNew -Recurse -Force }
                Copy-Item $BackupMaint $BackupMaintNew -Recurse -Force
            }

            try {
                if ($null -ne $CustomBackup) {
                    $CustomBackup | Set-Content -Path (Join-Path $NewMaintTmp "custom-targets.txt") -Encoding UTF8 -Force
                }
                if ($null -ne $DisabledBackup) {
                    $DisabledBackup | Set-Content -Path (Join-Path $NewMaintTmp "disabled-targets.txt") -Encoding UTF8 -Force
                }
                # Preserve the auth token so existing browser sessions stay valid
                # if the service restarts after the update.
                if (Test-Path $TokenFile) {
                    try { Copy-Item $TokenFile (Join-Path $NewMaintTmp ".easyskills-token") -Force } catch {}
                }

                # Move our own working directory OUT of _maintenance so the live
                # server process does not hold the directory we are about to rename.
                try { [System.IO.Directory]::SetCurrentDirectory($CentralDir) } catch {}

                if (Test-Path $DestMaint) {
                    if (Test-Path $BackupMaint) { Remove-Item $BackupMaint -Recurse -Force }
                    Rename-Item -Path $DestMaint -NewName "_maintenance.bak" -Force
                }

                Rename-Item -Path $NewMaintTmp -NewName "_maintenance" -Force

                if (Test-Path $BackupMaintNew) { Remove-Item $BackupMaintNew -Recurse -Force }
            } catch {
                # Rollback: restore from backup snapshot if available
                if (Test-Path $NewMaintTmp) { Remove-Item $NewMaintTmp -Recurse -Force }
                if (Test-Path $BackupMaintNew) {
                    if (Test-Path $BackupMaint) { Remove-Item $BackupMaint -Recurse -Force }
                    Rename-Item -Path $BackupMaintNew -NewName "_maintenance.bak" -Force
                }
                if (-not (Test-Path $DestMaint) -and (Test-Path $BackupMaint)) {
                    Copy-Item $BackupMaint $DestMaint -Recurse -Force
                }
                throw
            }
        } finally {
            Remove-Item $TmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        Run-DeployCommand @("-Sync") | Out-Null

        $NewVersion = Get-EasySkillsVersion
        return @{ success = $true; message = "Updated to $NewVersion. All agents re-synced."; version = $NewVersion }
    } catch {
        return @{ success = $false; message = "Update failed: $_" }
    }
}

function Do-Rollback {
    $BackupMaint = Join-Path $CentralDir "_maintenance.bak"
    $DestMaint = Join-Path $CentralDir "_maintenance"
    if (-not (Test-Path $BackupMaint)) {
        return @{ success = $false; message = "No backup found. Nothing to roll back." }
    }
    try {
        # Preserve the user's CURRENT runtime files across the rollback
        $CustomBackup = $null
        if (Test-Path $CustomTargetsFile) {
            $CustomBackup = Get-Content $CustomTargetsFile -Raw -Encoding UTF8
        }
        $DisabledBackup = $null
        if (Test-Path $DisabledTargetsFile) {
            $DisabledBackup = Get-Content $DisabledTargetsFile -Raw -Encoding UTF8
        }
        $RollbackTmp = Join-Path $CentralDir "_maintenance.rollback"
        if (Test-Path $RollbackTmp) { Remove-Item $RollbackTmp -Recurse -Force }

        if (Test-Path $BackupMaint) {
            Copy-Item $BackupMaint $RollbackTmp -Recurse -Force
        }

        if ($null -ne $CustomBackup) {
            $CustomBackup | Set-Content -Path (Join-Path $RollbackTmp "custom-targets.txt") -Encoding UTF8 -Force
        }
        if ($null -ne $DisabledBackup) {
            $DisabledBackup | Set-Content -Path (Join-Path $RollbackTmp "disabled-targets.txt") -Encoding UTF8 -Force
        }
        if (Test-Path $TokenFile) {
            try { Copy-Item $TokenFile (Join-Path $RollbackTmp ".easyskills-token") -Force } catch {}
        }

        # Move our own working directory OUT of _maintenance before renaming it
        try { [System.IO.Directory]::SetCurrentDirectory($CentralDir) } catch {}

        if (Test-Path $DestMaint) {
            Rename-Item -Path $DestMaint -NewName "_maintenance.prev" -Force
        }
        Rename-Item -Path $RollbackTmp -NewName "_maintenance" -Force

        $Prev = Join-Path $CentralDir "_maintenance.prev"
        if (Test-Path $Prev) { Remove-Item $Prev -Recurse -Force }

        Run-DeployCommand @("-Sync") | Out-Null
        # Remove backup so a second rollback doesn't restore stale state
        try { Remove-Item $BackupMaint -Recurse -Force -ErrorAction SilentlyContinue } catch {}
        $Version = Get-EasySkillsVersion
        return @{ success = $true; message = "Rolled back to $Version. All agents re-synced."; version = $Version }
    } catch {
        return @{ success = $false; message = "Rollback failed: $_" }
    }
}

function Do-Unmap([string]$TargetPath) {
    if (-not $TargetPath -or -not $TargetPath.Trim()) {
        return @{ success = $false; message = "Target path cannot be empty" }
    }
    $TargetPath = $TargetPath.Trim()
    Add-DisabledTarget $TargetPath
    try {
        if (-not (Test-Path $TargetPath)) {
            return @{ success = $false; message = "Path does not exist" }
        }
        $Removed = @()
        $CentralResolved = (Resolve-Path -LiteralPath $CentralDir).ProviderPath
        $Items = Get-ChildItem -Path $TargetPath -Force
        foreach ($Item in $Items) {
            if ($Item.Attributes -match "ReparsePoint") {
                $LinkTarget = $Item.Target
                $ResolvedTarget = $null
                if ($LinkTarget) {
                    try {
                        $ResolvedTarget = (Resolve-Path -LiteralPath $LinkTarget).ProviderPath
                    } catch {
                        try { $ResolvedTarget = [System.IO.Path]::GetFullPath($LinkTarget) } catch {}
                    }
                }
                if ($ResolvedTarget -and ($ResolvedTarget.Equals($CentralResolved, [System.StringComparison]::OrdinalIgnoreCase) -or $ResolvedTarget.StartsWith("$CentralResolved\", [System.StringComparison]::OrdinalIgnoreCase))) {
                    Remove-Item $Item.FullName -Recurse -Force
                    $Removed += $Item.Name
                }
            }
        }
        return @{ success = $true; message = "Removed $($Removed.Count) junctions"; removed = $Removed }
    } catch {
        return @{ success = $false; message = $_.Exception.Message }
    }
}

# --------------------------------------------------------------
# HTTP Server
# --------------------------------------------------------------

function Get-CorsOrigin($Request) {
    $Origin = $Request.Headers["Origin"]
    if ($Origin -eq "http://localhost:$Port" -or $Origin -eq "http://127.0.0.1:$Port") {
        return $Origin
    }
    return $null
}

function Test-TokenValid($Request) {
    $Token = $Request.Headers["X-EasySkills-Token"]
    if ($null -eq $Token) {
        $Token = ""
    }

    $Diff = $Token.Length -bxor $WebUIToken.Length
    $MaxLen = [Math]::Max($Token.Length, $WebUIToken.Length)
    for ($i = 0; $i -lt $MaxLen; $i++) {
        $A = 0
        $B = 0
        if ($i -lt $Token.Length) {
            $A = [int][char]$Token[$i]
        }
        if ($i -lt $WebUIToken.Length) {
            $B = [int][char]$WebUIToken[$i]
        }
        $Diff = $Diff -bor ($A -bxor $B)
    }
    return ($Diff -eq 0)
}

function Test-PostAllowed($Request) {
    $Origin = $Request.Headers["Origin"]
    if ($Origin -and $Origin -ne "http://localhost:$Port" -and $Origin -ne "http://127.0.0.1:$Port") {
        return $false
    }
    return (Test-TokenValid $Request)
}

function Send-ForbiddenResponse($Context) {
    Send-JsonResponse $Context @{ success = $false; message = "Forbidden" } 403
}

function Send-JsonResponse($Context, $Data, $StatusCode = 200) {
    $Response = $Context.Response
    $Response.StatusCode = $StatusCode
    $CorsOrigin = Get-CorsOrigin $Context.Request
    if ($CorsOrigin) {
        $Response.Headers.Add("Access-Control-Allow-Origin", $CorsOrigin)
    }
    $Response.ContentType = "application/json; charset=utf-8"

    $JsonStr = $Data | ConvertTo-Json -Depth 10 -Compress
    $Buffer = [System.Text.Encoding]::UTF8.GetBytes($JsonStr)
    $Response.ContentLength64 = $Buffer.Length
    $Response.OutputStream.Write($Buffer, 0, $Buffer.Length)
    $Response.Close()
}

function Send-FileResponse($Context, $FilePath, $ContentType) {
    $Response = $Context.Response
    $CorsOrigin = Get-CorsOrigin $Context.Request
    if ($CorsOrigin) {
        $Response.Headers.Add("Access-Control-Allow-Origin", $CorsOrigin)
    }
    if (Test-Path $FilePath) {
        $Response.StatusCode = 200
        $Response.ContentType = $ContentType
        $Response.Headers.Add("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
        $Response.Headers.Add("Pragma", "no-cache")
        $Response.Headers.Add("Expires", "0")
        $Bytes = [System.IO.File]::ReadAllBytes($FilePath)
        $Response.ContentLength64 = $Bytes.Length
        $Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
    } else {
        $Response.StatusCode = 404
    }
    $Response.Close()
}

function Send-IndexResponse($Context, $FilePath) {
    $Response = $Context.Response
    if (Test-Path $FilePath) {
        $Html = [System.IO.File]::ReadAllText($FilePath, [System.Text.Encoding]::UTF8)
        $Html = $Html.Replace("__EASYSKILLS_TOKEN__", $WebUIToken)
        $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Html)
        $Response.StatusCode = 200
        $Response.ContentType = "text/html; charset=utf-8"
        $Response.Headers.Add("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
        $Response.Headers.Add("Pragma", "no-cache")
        $Response.Headers.Add("Expires", "0")
        $Response.ContentLength64 = $Bytes.Length
        $Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
    } else {
        $Response.StatusCode = 404
    }
    $Response.Close()
}

function Close-ResponseQuietly($Context) {
    try {
        if ($Context -and $Context.Response) {
            $Context.Response.Close()
        }
    } catch {}
}

function Invoke-WebUIRequest($Context) {
    $Request = $Context.Request
    
    # DNS Rebinding Protection: Host header validation
    $HostHeader = $Request.Headers["Host"]
    $AllowedHosts = @("localhost:$Port", "127.0.0.1:$Port")
    if ($HostHeader -notin $AllowedHosts) {
        $Context.Response.StatusCode = 400
        $Context.Response.Close()
        return
    }

    $Method = $Request.HttpMethod
    $UrlPath = $Request.Url.AbsolutePath

    if ($Method -eq "OPTIONS") {
        $CorsOrigin = Get-CorsOrigin $Context.Request
        if (-not $CorsOrigin) {
            $Context.Response.StatusCode = 403
            $Context.Response.Close()
            return
        }
        $Context.Response.StatusCode = 200
        $Context.Response.Headers.Add("Access-Control-Allow-Origin", $CorsOrigin)
        $Context.Response.Headers.Add("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        $Context.Response.Headers.Add("Access-Control-Allow-Headers", "Content-Type, X-EasySkills-Token")
        $Context.Response.Close()
        return
    }

    if ($Method -eq "GET") {
        if ($UrlPath -eq "/" -or $UrlPath -eq "/index.html") {
            Send-IndexResponse $Context (Join-Path $WebUIDir "index.html")
        } elseif ($UrlPath -eq "/favicon.ico") {
            $Context.Response.StatusCode = 204
            $Context.Response.Close()
        } elseif ($UrlPath -eq "/api/status") {
            if (-not (Test-TokenValid $Request)) {
                Send-ForbiddenResponse $Context
                return
            }
            $Skills = @(Get-SkillsData)
            $Agents = @(Get-VisibleAgentsData)
            $MappedCount = @($Agents | Where-Object { $_.mapped }).Count
            $LinkWarnings = Get-CentralDirWarnings
            $Data = @{
                watcher = Get-WatcherStatus
                central_dir = $CentralDir
                skills_count = $Skills.Count
                agents_total = $Agents.Count
                agents_mapped = $MappedCount
                version = Get-EasySkillsVersion
                has_backup = (Test-Path (Join-Path $CentralDir "_maintenance.bak") -PathType Container)
                # Link health: dangling links will be auto-pruned on next sync;
                # external links are valid-but-fragile symlinks/junctions.
                dangling_count = $LinkWarnings.dangling_count
                external_link_count = $LinkWarnings.external_link_count
            }
            Send-JsonResponse $Context $Data
        } elseif ($UrlPath -eq "/api/skills") {
            if (-not (Test-TokenValid $Request)) {
                Send-ForbiddenResponse $Context
                return
            }
            Send-JsonResponse $Context (Get-SkillsData)
        } elseif ($UrlPath -eq "/api/agents") {
            if (-not (Test-TokenValid $Request)) {
                Send-ForbiddenResponse $Context
                return
            }
            Send-JsonResponse $Context (Get-VisibleAgentsData)
        } elseif ($UrlPath -eq "/api/latest-release") {
            if (-not (Test-TokenValid $Request)) {
                Send-ForbiddenResponse $Context
                return
            }
            Send-JsonResponse $Context (Get-LatestRelease)
        } else {
            $Context.Response.StatusCode = 404
            $Context.Response.Close()
        }
    } elseif ($Method -eq "POST") {
        if (-not (Test-PostAllowed $Request)) {
            Send-ForbiddenResponse $Context
            return
        }
        $BodyData = @{}
        if ($Request.HasEntityBody) {
            if ($Request.ContentLength64 -gt 10485760) {  # 10 MB limit
                Send-JsonResponse $Context @{ success = $false; message = "Request Entity Too Large" } 413
                return
            }
            $Reader = New-Object System.IO.StreamReader($Request.InputStream, $Request.ContentEncoding)
            try {
                $Json = $Reader.ReadToEnd()
            } finally {
                $Reader.Close()
                $Reader.Dispose()
            }
            if ($Json) {
                try {
                    # PowerShell 7+ supports -AsHashtable; fallback for 5.1
                    $BodyData = $Json | ConvertFrom-Json -AsHashtable
                } catch {
                    # PowerShell 5.1 fallback: convert PSObject to hashtable
                    $PsObj = $Json | ConvertFrom-Json
                    $BodyData = @{}
                    if ($PsObj) {
                        $PsObj.PSObject.Properties | ForEach-Object {
                            $BodyData[$_.Name] = $_.Value
                        }
                    }
                }
            }
        }

        if ($UrlPath -eq "/api/sync") {
            Send-JsonResponse $Context (Run-DeployCommand @("-Sync"))
        } elseif ($UrlPath -eq "/api/cleanup") {
            Send-JsonResponse $Context (Run-DeployCommand @("-Cleanup"))
        } elseif ($UrlPath -eq "/api/watcher/start") {
            Send-JsonResponse $Context (Start-WatcherTask)
        } elseif ($UrlPath -eq "/api/watcher/stop") {
            Send-JsonResponse $Context (Stop-WatcherTask)
        } elseif ($UrlPath -eq "/api/agents/map") {
            Send-JsonResponse $Context (Do-Map $BodyData["path"])
        } elseif ($UrlPath -eq "/api/agents/unmap") {
            Send-JsonResponse $Context (Do-Unmap $BodyData["path"])
        } elseif ($UrlPath -eq "/api/agents/update") {
            Send-JsonResponse $Context (Update-AgentPath $BodyData["name"] $BodyData["old_path"] $BodyData["new_path"])
        } elseif ($UrlPath -eq "/api/agents/custom/add") {
            Send-JsonResponse $Context (Run-DeployCommand @("-Add", $BodyData["path"]))
        } elseif ($UrlPath -eq "/api/agents/custom/remove") {
            Send-JsonResponse $Context (Run-DeployCommand @("-Remove", $BodyData["path"]))
        } elseif ($UrlPath -eq "/api/skills/import") {
            Send-JsonResponse $Context (Import-SkillFolder $BodyData["name"] $BodyData["files"])
        } elseif ($UrlPath -eq "/api/skills/delete") {
            Send-JsonResponse $Context (Delete-Skill $BodyData["name"])
        } elseif ($UrlPath -eq "/api/update") {
            Send-JsonResponse $Context (Run-SelfUpdate)
        } elseif ($UrlPath -eq "/api/rollback") {
            Send-JsonResponse $Context (Do-Rollback)
        } else {
            $Context.Response.StatusCode = 404
            $Context.Response.Close()
        }
    } else {
        $Context.Response.StatusCode = 404
        $Context.Response.Close()
    }
}

function Start-WebUIListener {
    $L = New-Object System.Net.HttpListener
    $L.Prefixes.Add("http://localhost:$Port/")
    $L.Prefixes.Add("http://127.0.0.1:$Port/")
    $L.Start()
    return $L
}

Write-WebUILog "webui.ps1 starting up."

$BrowserOpened = $false
$ListenerAttempts = 0

# Outer retry loop: if the listener dies for any reason, rebuild it.
while ($true) {
    $Listener = $null
    try {
        $Listener = Start-WebUIListener
        $ListenerAttempts = 0
        Write-WebUILog "HttpListener bound to port $Port."

        Write-Host ""
        Write-Host "  EasySkills WebUI (Windows)"
        Write-Host "  =========================================="
        Write-Host "    http://127.0.0.1:$Port"
        Write-Host "    Press Ctrl+C to stop"
        Write-Host "  =========================================="
        Write-Host ""

        $SkipBrowser = $NoBrowser -or ($env:EASYSKILLS_NO_BROWSER -eq "1")
        if (-not $SkipBrowser -and -not $BrowserOpened) {
            try { Start-Process "http://127.0.0.1:$Port" } catch {
                Write-WebUILog "Browser open failed (ignored): $($_.Exception.Message)"
            }
            $BrowserOpened = $true
        }

        while ($Listener.IsListening) {
            $Context = $null
            try {
                $Context = $Listener.GetContext()
            } catch {
                if ($Listener.IsListening) {
                    Write-WebUILog "GetContext transient error: $($_.Exception.Message)"
                    Start-Sleep -Milliseconds 200
                }
                continue
            }

            try {
                Invoke-WebUIRequest $Context
            } catch {
                Write-WebUILog "Request handler error: $($_.Exception.Message)"
                Close-ResponseQuietly $Context
                continue
            }
        }

        Write-WebUILog "Listener stopped listening; will rebuild."
    } catch {
        $ListenerAttempts++
        Write-WebUILog "Listener fatal error (attempt $ListenerAttempts): $($_.Exception.Message)"
        # Back off but never give up — the outer supervisor will restart us
        # if even this loop dies.
        $Sleep = [Math]::Min(30, [Math]::Max(2, $ListenerAttempts * 2))
        Start-Sleep -Seconds $Sleep
    } finally {
        if ($Listener) {
            try { if ($Listener.IsListening) { $Listener.Stop() } } catch {}
            try { $Listener.Close() } catch {}
        }
    }

    # Small breather before recreating the listener
    Start-Sleep -Seconds 1
}
