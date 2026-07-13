# ==============================================================================
# Script: webui.ps1 (Windows)
# Description: EasySkills WebUI backend - PowerShell HttpListener, zero deps.
# Usage: powershell -File _maintenance\webui.ps1
#        or: deploy.ps1 -WebUI
# ==============================================================================

Param(
    [Parameter(Mandatory=$false)][switch]$NoBrowser,
    [Parameter(Mandatory=$false)][switch]$SyncRules
)

$ErrorActionPreference = 'Continue'
$script:RestartRequested = $false

function Write-Utf8NoBom([string]$Path, [string]$Content) {
    $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $Utf8NoBom)
}

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
$AgentPathConfigFile = Join-Path $CentralDir ".easyskills-agent-paths.json"

# --- Instruction-rule library (AGENTS.md / CLAUDE.md management) ---
$InstructionsDir = Join-Path $CentralDir "instructions"
$InstructionSyncStateFile = Join-Path $CentralDir ".easyskills-instruction-state.json"
$EasySkillsBegin = "<!-- EasySkills:begin -->"
$EasySkillsBeginAliases = @(
    $EasySkillsBegin,
    "<!-- EasySkills:begin (managed block - do not edit manually) -->",
    "<!-- EasySkills:begin (managed block — do not edit manually) -->"
)
$EasySkillsEnd = "<!-- EasySkills:end -->"

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
            Write-Utf8NoBom $DisabledTargetsFile (($Lines -join "`n") + "`n")
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
            Write-Utf8NoBom $DisabledTargetsFile (($NewLines -join "`n") + "`n")
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

function Get-DefaultInstructionPaths {
    $Result = @{}
    if (Test-Path $AgentsJsonFile) {
        try {
            $Data = Get-Content $AgentsJsonFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($Agent in $Data.agents) {
                $Name = [string]$Agent.name
                $Raw = [string]$Agent.win_instructions_file
                if (-not $Name -or -not $Raw -or $Result.ContainsKey($Name)) { continue }
                $Expanded = $Raw -replace '%USERPROFILE%', $Home -replace '%APPDATA%', $env:APPDATA
                $Result[$Name] = $Expanded
            }
        } catch {}
    }
    return $Result
}
$DefaultInstructionPaths = Get-DefaultInstructionPaths

function Normalize-AgentPath([string]$PathStr) {
    if (-not $PathStr -or -not $PathStr.Trim()) { return "" }
    $Clean = $PathStr.Trim() -replace '%USERPROFILE%', $Home -replace '%APPDATA%', $env:APPDATA
    try { return [System.IO.Path]::GetFullPath($Clean) } catch { return $Clean }
}

function Get-AgentPathConfigs {
    if (-not (Test-Path $AgentPathConfigFile)) { return @() }
    try {
        $Data = Get-Content $AgentPathConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
        return @($Data.agents)
    } catch {
        return @()
    }
}

function Save-AgentPathConfigs($Entries) {
    $Payload = [ordered]@{
        version = 1
        agents = @($Entries)
    }
    $Json = $Payload | ConvertTo-Json -Depth 6
    Write-Utf8Atomic $AgentPathConfigFile ($Json + "`n")
}

function Resolve-AgentInstructionPath([string]$Name, [string]$SkillsPath, $Configs) {
    $NormalizedSkills = Normalize-AgentPath $SkillsPath
    foreach ($Entry in @($Configs)) {
        if ((Normalize-AgentPath ([string]$Entry.skills_path)) -ne $NormalizedSkills) { continue }
        $Configured = Normalize-AgentPath ([string]$Entry.instructions_path)
        if ($Configured) { return $Configured }
    }
    if ($DefaultInstructionPaths.ContainsKey($Name)) {
        return (Normalize-AgentPath ([string]$DefaultInstructionPaths[$Name]))
    }
    return ""
}

# Ensure ~/.qoder-cn/skills exists — Qoder CN relies on EasySkills to
# create the path if it does not already exist.
$qoderCnSkillsDir = Join-Path $Home ".qoder-cn\skills"
if (-not (Test-Path $qoderCnSkillsDir)) {
    New-Item -Path $qoderCnSkillsDir -ItemType Directory -Force | Out-Null
}

$ExcludeNames = @("_maintenance", ".git", "node_modules", "dist", "docs", "instructions")
$GitHubRepo = "RunhuaHuang/EasySkills"
$GitHubApiLatestRelease = "https://api.github.com/repos/$GitHubRepo/releases/latest"
$GitHubLatestRelease = "https://github.com/$GitHubRepo/releases/latest"
$GitHubReleaseTagPrefix = "https://github.com/$GitHubRepo/releases/tag/"
$TrustedDownloadHosts = @("api.github.com", "github.com", "codeload.github.com", "objects.githubusercontent.com")

function Test-TrustedGitHubDownloadUrl([string]$Url) {
    try { $Uri = [System.Uri]$Url } catch { return $false }
    return ($Uri.Scheme -eq "https") -and ($TrustedDownloadHosts -contains $Uri.Host)
}

function Get-WebResponseFinalUrl($Response) {
    if ($Response -and $Response.BaseResponse.ResponseUri) {
        return $Response.BaseResponse.ResponseUri.AbsoluteUri
    }
    if ($Response -and $Response.BaseResponse.RequestMessage -and $Response.BaseResponse.RequestMessage.RequestUri) {
        return $Response.BaseResponse.RequestMessage.RequestUri.AbsoluteUri
    }
    return ""
}

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

function Test-EasySkillsLinkTarget($Item) {
    # Compare the lexical target without following the final central skill,
    # which may itself be a supported external symlink/junction.
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

function Is-Mapped([string]$TargetPath, $DisabledSet, [bool]$HasSkills) {
    try { $NormPath = [System.IO.Path]::GetFullPath($TargetPath) } catch { $NormPath = $TargetPath }
    if ($DisabledSet.ContainsKey($NormPath)) { return $false }

    if (-not (Test-Path $TargetPath -PathType Container)) { return $false }
    if (-not $HasSkills) { return $true }

    try {
        $Items = Get-ChildItem -Path $TargetPath -Force
        foreach ($Item in $Items) {
            if (Test-EasySkillsLinkTarget $Item) { return $true }
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
    $PathConfigs = @(Get-AgentPathConfigs)

    $CustomTargets = Get-CustomTargets
    $CustomOverrides = @{}
    $CustomList = @()

    foreach ($Ct in $CustomTargets) {
        if ($Ct.Contains("=")) {
            $Parts = $Ct.Split("=", 2)
            $CtName = $Parts[0].Trim()
            $CtPath = Normalize-AgentPath $Parts[1]
            if (-not $CtPath) { continue }
            if (Is-PromaWorkspaceTarget $CtPath) { continue }
            $CustomOverrides[$CtName] = $CtPath
        } else {
            $CtPath = Normalize-AgentPath $Ct
            if (-not $CtPath) { continue }
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
        $PathKey = Normalize-AgentPath $Path
        if ($Seen.ContainsKey($PathKey)) { continue }
        $Seen[$PathKey] = $true

        $Root = Get-AgentRoot $Path
        $Active = Test-Path $Root
        $InstructionsPath = Resolve-AgentInstructionPath $Def.Name $Path $PathConfigs

        $Agents += @{
            name = $Def.Name
            path = $Path
            instructions_path = $InstructionsPath
            instructions_exists = [bool]($InstructionsPath -and (Test-Path $InstructionsPath -PathType Leaf))
            active = $Active
            mapped = if ($Active) { Is-Mapped $Path $DisabledSet $HasSkills } else { $false }
            custom = $CustomOverrides.ContainsKey($Def.Name)
        }
    }

    # 2. Add Custom Agents (that don't match any default name override)
    foreach ($Ct in $CustomList) {
        $PathKey = Normalize-AgentPath $Ct.Path
        if ($Seen.ContainsKey($PathKey)) { continue }
        $Seen[$PathKey] = $true

        $Root = Get-AgentRoot $Ct.Path
        $Active = Test-Path $Root
        $InstructionsPath = Resolve-AgentInstructionPath $Ct.Name $Ct.Path $PathConfigs

        $Agents += @{
            name = $Ct.Name
            path = $Ct.Path
            instructions_path = $InstructionsPath
            instructions_exists = [bool]($InstructionsPath -and (Test-Path $InstructionsPath -PathType Leaf))
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
        $ArgList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $DeployScript) + $ArgsArr

        $ProcInfo = New-Object System.Diagnostics.ProcessStartInfo
        $ProcInfo.FileName = "powershell.exe"
        $ProcInfo.Arguments = (($ArgList | ForEach-Object { Quote-ProcessArgument ([string]$_) }) -join " ")
        $ProcInfo.UseShellExecute = $false
        $ProcInfo.RedirectStandardOutput = $true
        $ProcInfo.RedirectStandardError = $true
        $ProcInfo.CreateNoWindow = $true

        $Process = New-Object System.Diagnostics.Process
        $Process.StartInfo = $ProcInfo
        [void]$Process.Start()

        # Read each stream asynchronously via the .NET Task API so neither
        # pipe buffer can fill and deadlock the child while we block on the
        # other. Synchronous ReadToEnd() on BOTH streams from one thread is
        # the classic deadlock: if stdout fills its ~64 KiB OS pipe buffer
        # while we block on stderr's ReadToEnd (or vice versa), the child
        # blocks on its next write and the 30s timeout below is never reached.
        # ReadToEndAsync returns a Task we can await after WaitForExit, so the
        # timeout stays effective and both buffers drain concurrently.
        $OutTask = $Process.StandardOutput.ReadToEndAsync()
        $ErrTask = $Process.StandardError.ReadToEndAsync()

        $Finished = $Process.WaitForExit(30000)
        if (-not $Finished) { try { $Process.Kill(); $Process.WaitForExit(2000) } catch {} }

        # Give the async reads a moment to complete after process exit.
        try { $OutTask.Wait(2000) | Out-Null; $ErrTask.Wait(2000) | Out-Null } catch {}
        $StdOut = if ($OutTask.IsCompleted) { $OutTask.Result } else { "" }
        $StdErr = if ($ErrTask.IsCompleted) { $ErrTask.Result } else { "" }

        $ExitCode = if ($Finished) { $Process.ExitCode } else { 1 }
        $Combined = ("$StdOut$StdErr").Trim()
        $Msg = if ($Combined) { $Combined } elseif ($ExitCode -eq 0) { "Command completed successfully" } else { "Command failed" }
        return @{ success = ($ExitCode -eq 0); output = $Combined; message = $Msg }
    } catch {
        return @{ success = $false; output = $_.Exception.Message; message = $_.Exception.Message }
    }
}

function Update-AgentPaths(
    [string]$Name,
    [string]$OldSkillsPath,
    [string]$SkillsPath,
    [string]$InstructionsPath
) {
    if (-not $SkillsPath) {
        return @{ success = $false; message = "Skills path cannot be empty" }
    }
    $Current = @(Get-VisibleAgentsData | Where-Object {
        (Normalize-AgentPath ([string]$_.path)) -eq (Normalize-AgentPath $OldSkillsPath)
    } | Select-Object -First 1)
    if (-not $InstructionsPath) {
        if ($Current.Count -gt 0) { $InstructionsPath = [string]$Current[0].instructions_path }
        if (-not $InstructionsPath) {
            return @{ success = $false; message = "Instructions file path cannot be empty" }
        }
    }
    $NewPath = Normalize-AgentPath $SkillsPath
    $NewInstructionsPath = Normalize-AgentPath $InstructionsPath
    if ((Test-Path $NewInstructionsPath) -and -not (Test-Path $NewInstructionsPath -PathType Leaf)) {
        return @{ success = $false; message = "Instructions path must point to a file, not a directory" }
    }

    # Normalize OldPath the same way as NewPath and the stored lines, otherwise
    # a `~`-form or dotted OldPath silently fails to match the stored absolute
    # path, leaving a stale/duplicate entry behind. Mirrors webui.py.
    $OldPath = Normalize-AgentPath $OldSkillsPath

    $Lines = @()
    if (Test-Path $CustomTargetsFile) {
        $Lines = @(Get-Content $CustomTargetsFile -Encoding UTF8 -ErrorAction SilentlyContinue)
    }
    $OriginalCustomContent = if ($Lines.Count -gt 0) { ($Lines -join "`n") + "`n" } else { "" }

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
        $LinePathNormalized = Normalize-AgentPath $LinePath
        if ($LinePathNormalized -eq $OldPath) {
            if (-not $Updated) { $NewLines += "$Name=$NewPath" }
            $Updated = $true
        } else {
            $NewLines += $Line
        }
    }
    if (-not $Updated -and $NewPath -ne $OldPath) {
        $NewLines += "$Name=$NewPath"
    }

    try {
        Write-Utf8NoBom $CustomTargetsFile (($NewLines -join "`n") + "`n")
    } catch {
        return @{ success = $false; message = "Failed to write config: $_" }
    }

    $UpdatedConfigs = @()
    foreach ($Entry in @(Get-AgentPathConfigs)) {
        $EntryPath = Normalize-AgentPath ([string]$Entry.skills_path)
        if ($EntryPath -eq $OldPath -or $EntryPath -eq $NewPath) { continue }
        $UpdatedConfigs += $Entry
    }
    $UpdatedConfigs += [ordered]@{
        name = $Name
        skills_path = $NewPath
        instructions_path = $NewInstructionsPath
    }
    try {
        Save-AgentPathConfigs $UpdatedConfigs
    } catch {
        try { Write-Utf8Atomic $CustomTargetsFile $OriginalCustomContent } catch {}
        return @{ success = $false; message = "Failed to write Agent path config: $_" }
    }

    Remove-DisabledTarget $OldPath
    $WasMapped = $Current.Count -gt 0 -and [bool]$Current[0].mapped
    if ($WasMapped) {
        Remove-DisabledTarget $NewPath
        $CleanupWarning = ""
        if ($NewPath -ne $OldPath) {
            $MapResult = Do-Map $NewPath
            if (-not $MapResult.success) {
                return @{
                    success = $false
                    message = "Agent paths were saved, but the new skills path could not be mapped: $($MapResult.message). The old skills links were preserved."
                    skills_path = $NewPath
                    instructions_path = $NewInstructionsPath
                    partial = $true
                }
            }
            $CleanupResult = Do-Unmap $OldPath
            Remove-DisabledTarget $OldPath
            if (-not $CleanupResult.success) {
                $CleanupWarning = " Warning: old skills links at $OldPath could not be fully removed: $($CleanupResult.message)."
            }
        }
    } else {
        Add-DisabledTarget $NewPath
        $CleanupWarning = ""
    }
    return @{
        success = $true
        message = "Updated $Name skills and instructions paths.$CleanupWarning"
        skills_path = $NewPath
        instructions_path = $NewInstructionsPath
    }
}

function Update-AgentPath([string]$Name, [string]$OldPath, [string]$NewPath) {
    $Current = @(Get-VisibleAgentsData | Where-Object {
        (Normalize-AgentPath ([string]$_.path)) -eq (Normalize-AgentPath $OldPath)
    } | Select-Object -First 1)
    $InstructionsPath = if ($Current.Count -gt 0) { [string]$Current[0].instructions_path } else { "" }
    if (-not $InstructionsPath) {
        $InstructionsPath = Join-Path (Split-Path -Parent $NewPath) "AGENTS.md"
    }
    return (Update-AgentPaths $Name $OldPath $NewPath $InstructionsPath)
}

function Register-CustomAgent([string]$SkillsPath, [string]$InstructionsPath) {
    $SkillsPath = Normalize-AgentPath $SkillsPath
    $InstructionsPath = Normalize-AgentPath $InstructionsPath
    if (-not $SkillsPath) {
        return @{ success = $false; message = "Skills path cannot be empty" }
    }
    if (-not $InstructionsPath) {
        return @{ success = $false; message = "Instructions file path cannot be empty" }
    }
    if ((Test-Path $InstructionsPath) -and -not (Test-Path $InstructionsPath -PathType Leaf)) {
        return @{ success = $false; message = "Instructions path must point to a file, not a directory" }
    }

    $WasRegistered = $false
    foreach ($Target in @(Get-CustomTargets)) {
        $TargetPath = if ($Target.Contains("=")) { $Target.Split("=", 2)[1].Trim() } else { $Target.Trim() }
        if ((Normalize-AgentPath $TargetPath) -eq $SkillsPath) {
            $WasRegistered = $true
            break
        }
    }
    $DeployResult = Run-DeployCommand @("-Add", $SkillsPath)
    if (-not $DeployResult.success) { return $DeployResult }

    $Entries = @()
    foreach ($Entry in @(Get-AgentPathConfigs)) {
        if ((Normalize-AgentPath ([string]$Entry.skills_path)) -eq $SkillsPath) { continue }
        $Entries += $Entry
    }
    $Entries += [ordered]@{
        name = Get-AgentNameFromPath $SkillsPath
        skills_path = $SkillsPath
        instructions_path = $InstructionsPath
    }
    try {
        Save-AgentPathConfigs $Entries
    } catch {
        if (-not $WasRegistered) {
            Run-DeployCommand @("-Remove", $SkillsPath) | Out-Null
        }
        return @{ success = $false; message = "Failed to save Agent paths: $_" }
    }
    return @{
        success = $true
        message = "Registered Agent skills and instructions channels`n$($DeployResult.message)".Trim()
        skills_path = $SkillsPath
        instructions_path = $InstructionsPath
    }
}

function Remove-CustomAgent([string]$SkillsPath) {
    $SkillsPath = Normalize-AgentPath $SkillsPath
    $Result = Run-DeployCommand @("-Remove", $SkillsPath)
    if (-not $Result.success) { return $Result }
    $Entries = @()
    foreach ($Entry in @(Get-AgentPathConfigs)) {
        if ((Normalize-AgentPath ([string]$Entry.skills_path)) -eq $SkillsPath) { continue }
        $Entries += $Entry
    }
    try {
        Save-AgentPathConfigs $Entries
    } catch {
        return @{
            success = $true
            message = "$($Result.message)`nWarning: stale Agent path metadata could not be removed: $_"
        }
    }
    return $Result
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
        $Conflicts = @()
        foreach ($Skill in $Skills) {
            $Name = $Skill.Name
            if ($Name.StartsWith("_") -or $Name.StartsWith(".") -or $ExcludeNames -contains $Name) { continue }
            $Dest = Join-Path $TargetPath $Name
            $Item = Get-Item -LiteralPath $Dest -Force -ErrorAction SilentlyContinue
            if ($Item) {
                if ($Item.Attributes -match "ReparsePoint") {
                    if (Test-EasySkillsLinkTarget $Item) {
                        [System.IO.Directory]::Delete($Dest, $false)
                    } else {
                        $Conflicts += $Name
                        continue
                    }
                } else {
                    continue
                }
            }
            if (-not (Test-Path $Dest)) {
                New-Item -ItemType Junction -Path $Dest -Value $Skill.FullName | Out-Null
            }
        }
        $Message = "Mapped to $TargetPath"
        if ($Conflicts.Count -gt 0) {
            $Message += " (preserved $($Conflicts.Count) foreign link conflict(s): $($Conflicts -join ', '))"
        }
        return @{ success = $true; message = $Message; conflicts = $Conflicts }
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
    # Get-Item -Force detects dangling reparse points that Test-Path follows
    # and incorrectly reports as absent.
    $TargetItem = Get-Item -LiteralPath $Target -Force -ErrorAction SilentlyContinue
    if (-not $TargetItem) {
        return @{ success = $false; message = "Skill not found: $CleanName" }
    }
    try {
        if ($TargetItem.Attributes -match "ReparsePoint") {
            # A central skill may intentionally be an external junction. Never
            # recurse through it or PowerShell 5.1 can delete the real target.
            [System.IO.Directory]::Delete($TargetItem.FullName, $false)
        } else {
            Remove-Item -LiteralPath $Target -Recurse -Force
        }
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

# --------------------------------------------------------------
# Instruction-rule library: modular AGENTS.md / CLAUDE.md management
# --------------------------------------------------------------

# Read configured instruction-file targets from the unified Agent model.
function Get-InstructionTargets {
    $Targets = @()
    $Seen = @{}
    foreach ($Agent in @(Get-VisibleAgentsData)) {
        $Expanded = Normalize-AgentPath ([string]$Agent.instructions_path)
        if (-not $Expanded -or $Seen.ContainsKey($Expanded)) { continue }
        $Seen[$Expanded] = $true
        $Targets += @{ Name = $Agent.name; Path = $Expanded }
    }
    return $Targets
}

function Get-InstructionTargetActivity {
    $Activity = @{}
    foreach ($Agent in @(Get-VisibleAgentsData)) {
        $Resolved = Normalize-AgentPath ([string]$Agent.instructions_path)
        if (-not $Resolved) { continue }
        $WasActive = $Activity.ContainsKey($Resolved) -and $Activity[$Resolved]
        $Activity[$Resolved] = $WasActive -or [bool]$Agent.active
    }
    return $Activity
}

function Get-DetectedInstructionTargets {
    $Activity = Get-InstructionTargetActivity
    return @(Get-InstructionTargets | Where-Object {
        try { $Resolved = [System.IO.Path]::GetFullPath($_.Path) } catch { $Resolved = $_.Path }
        $Activity.ContainsKey($Resolved) -and $Activity[$Resolved]
    })
}

function Resolve-KnownInstructionTarget([string]$PathStr) {
    if (-not $PathStr) { return $null }
    try { $Requested = [System.IO.Path]::GetFullPath($PathStr) } catch { return $null }
    foreach ($Target in @(Get-InstructionTargets)) {
        try { $Candidate = [System.IO.Path]::GetFullPath([string]$Target.Path) } catch { continue }
        if ($Candidate -eq $Requested) { return [string]$Target.Path }
    }
    return $null
}

function Test-InstructionName([string]$Name) {
    $Clean = if ($Name) { $Name.Trim() } else { "" }
    if (-not $Clean) { return @{ ok = $false; value = "Rule name cannot be empty" } }
    if ($Clean.Contains("/") -or $Clean.Contains("\") -or $Clean.Contains([char]0) -or $Clean -eq "." -or $Clean -eq "..") {
        return @{ ok = $false; value = "Invalid rule name" }
    }
    if (-not $Clean.EndsWith(".md")) { $Clean = $Clean + ".md" }
    return @{ ok = $true; value = $Clean }
}

# Replace or insert the managed block within an instruction file's content.
function Inject-ManagedBlock([string]$Existing, [string]$Block) {
    $ExistingBegin = @($EasySkillsBeginAliases | Where-Object { $Existing.Contains($_) } | Select-Object -First 1)
    if ($ExistingBegin.Count -gt 0 -and $Existing.Contains($EasySkillsEnd)) {
        $Pattern = [regex]::Escape([string]$ExistingBegin[0]) + ".*?" + [regex]::Escape($EasySkillsEnd)
        return [regex]::Replace($Existing, $Pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $Block }, [System.Text.RegularExpressions.RegexOptions]::Singleline, 1)
    }
    if ($Existing.Trim()) {
        return $Existing.TrimEnd() + "`n`n" + $Block + "`n"
    }
    return $Block + "`n"
}

# Remove the managed block from content.
function Strip-ManagedBlock([string]$Content) {
    $ExistingBegin = @($EasySkillsBeginAliases | Where-Object { $Content.Contains($_) } | Select-Object -First 1)
    if ($ExistingBegin.Count -eq 0 -or -not ($Content.Contains($EasySkillsEnd))) { return $Content }
    $Pattern = [regex]::Escape([string]$ExistingBegin[0]) + ".*?" + [regex]::Escape($EasySkillsEnd) + "`n?"
    return [regex]::Replace($Content, $Pattern, "", [System.Text.RegularExpressions.RegexOptions]::Singleline, 1)
}

function Get-InstructionsData {
    $Rules = @()
    if (Test-Path $InstructionsDir) {
        $Files = Get-ChildItem -Path $InstructionsDir -Filter "*.md" -File -ErrorAction SilentlyContinue | Sort-Object Name
        foreach ($File in $Files) {
            $Content = ""
            $ReadError = ""
            try {
                $Content = [System.IO.File]::ReadAllText($File.FullName, [System.Text.Encoding]::UTF8)
            } catch {
                $ReadError = $_.Exception.Message
            }
            $Preview = if ($Content.Length -gt 200) { $Content.Substring(0, 200) } else { $Content }
            $Rules += @{ name = $File.Name; preview = $Preview; size = $Content.Length; read_error = $ReadError }
        }
    }

    $Targets = Get-InstructionTargets
    $TargetActivity = Get-InstructionTargetActivity
    $AgentsStatus = @()
    foreach ($T in $Targets) {
        $HasBlock = $false
        $ManagedRules = @()
        $ManagedRuleCount = 0
        $Exists = (Test-Path $T.Path -PathType Leaf)
        if ($Exists) {
            try {
                $Txt = [System.IO.File]::ReadAllText($T.Path, [System.Text.Encoding]::UTF8)
                $HasBlock = @($EasySkillsBeginAliases | Where-Object { $Txt.Contains($_) }).Count -gt 0
                if ($HasBlock) {
                    $Managed = Get-ManagedRules $Txt $T.Path
                    $ManagedRules = @($Managed.Rules.Keys)
                    $LegacyParts = @([regex]::Split(([string]$Managed.Legacy).Trim(), "\r?\n\r?\n---\r?\n\r?\n") | Where-Object { $_.Trim() })
                    $ManagedRuleCount = $ManagedRules.Count + $LegacyParts.Count
                }
            } catch {}
        }
        try { $ResolvedTarget = [System.IO.Path]::GetFullPath($T.Path) } catch { $ResolvedTarget = $T.Path }
        $IsActive = $TargetActivity.ContainsKey($ResolvedTarget) -and $TargetActivity[$ResolvedTarget]
        $AgentsStatus += @{ name = $T.Name; path = $T.Path; exists = $Exists; active = $IsActive; has_managed_block = $HasBlock; managed_rules = $ManagedRules; managed_rule_count = $ManagedRuleCount }
    }

    return @{ success = $true; rules = $Rules; agents = $AgentsStatus }
}

function Write-Utf8Atomic([string]$Path, [string]$Content) {
    $Parent = Split-Path -Path $Path -Parent
    if (-not (Test-Path $Parent)) { New-Item -ItemType Directory -Path $Parent -Force | Out-Null }
    $Leaf = Split-Path -Path $Path -Leaf
    $TempPath = Join-Path $Parent (".$Leaf.$([guid]::NewGuid().ToString('N')).tmp")
    try {
        $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($TempPath, $Content, $Utf8NoBom)
        if (Test-Path $Path) {
            [System.IO.File]::Replace($TempPath, $Path, $null)
        } else {
            [System.IO.File]::Move($TempPath, $Path)
        }
    } finally {
        if (Test-Path $TempPath) { Remove-Item -LiteralPath $TempPath -Force -ErrorAction SilentlyContinue }
    }
}

function Get-ManagedBody($Rules, [string]$LegacyText = "") {
    $Block = Build-ManagedBlock $Rules $LegacyText
    $Start = $EasySkillsBegin.Length + 1
    $Length = $Block.Length - $Start - $EasySkillsEnd.Length - 1
    if ($Length -le 0) { return "" }
    return $Block.Substring($Start, $Length)
}

function Get-BodySha256([string]$Body) {
    $Sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Body.Trim())
        return ([System.BitConverter]::ToString($Sha.ComputeHash($Bytes))).Replace("-", "").ToLowerInvariant()
    } finally {
        $Sha.Dispose()
    }
}

function Get-InstructionSyncState {
    if (Test-Path $InstructionSyncStateFile) {
        try {
            $Data = Get-Content $InstructionSyncStateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($Data -and $null -ne $Data.targets) { return $Data }
        } catch {}
    }
    return [pscustomobject]@{ version = 1; targets = @() }
}

function Get-InstructionStateEntry([string]$PathStr) {
    try { $Key = [System.IO.Path]::GetFullPath($PathStr) } catch { return $null }
    $State = Get-InstructionSyncState
    foreach ($Entry in @($State.targets)) {
        if ([string]$Entry.path -eq $Key) { return $Entry }
    }
    return $null
}

function Save-InstructionSyncState($State) {
    $Json = $State | ConvertTo-Json -Depth 8
    Write-Utf8Atomic $InstructionSyncStateFile ($Json + "`n")
}

function Set-InstructionState([string]$PathStr, $Rules, [string]$LegacyText = "") {
    $Key = [System.IO.Path]::GetFullPath($PathStr)
    $State = Get-InstructionSyncState
    $Targets = @($State.targets | Where-Object { [string]$_.path -ne $Key })
    $RuleEntries = @()
    foreach ($Name in @($Rules.Keys | Sort-Object)) {
        $RuleEntries += [pscustomobject]@{ name = [string]$Name; content = [string]$Rules[$Name] }
    }
    $Targets += [pscustomobject]@{
        path = $Key
        rules = $RuleEntries
        legacy = $LegacyText
        body_sha256 = (Get-BodySha256 (Get-ManagedBody $Rules $LegacyText))
    }
    $State.version = 1
    $State.targets = $Targets
    Save-InstructionSyncState $State
}

function Remove-InstructionState([string]$PathStr) {
    try { $Key = [System.IO.Path]::GetFullPath($PathStr) } catch { return }
    $State = Get-InstructionSyncState
    $Targets = @($State.targets | Where-Object { [string]$_.path -ne $Key })
    if ($Targets.Count -eq @($State.targets).Count) { return }
    if ($Targets.Count -gt 0) {
        $State.targets = $Targets
        Save-InstructionSyncState $State
    } elseif (Test-Path $InstructionSyncStateFile) {
        Remove-Item -LiteralPath $InstructionSyncStateFile -Force -ErrorAction SilentlyContinue
    }
}

function Save-Instruction([string]$Name, [string]$Content) {
    $Check = Test-InstructionName $Name
    if (-not $Check.ok) { return @{ success = $false; message = $Check.value } }
    $CleanName = $Check.value
    try {
        if (-not (Test-Path $InstructionsDir)) { New-Item -ItemType Directory -Path $InstructionsDir -Force | Out-Null }
        Write-Utf8Atomic (Join-Path $InstructionsDir $CleanName) $Content
    } catch {
        return @{ success = $false; message = "Save failed: $_" }
    }
    return @{ success = $true; message = "Saved rule: $CleanName"; name = $CleanName }
}

function Remove-Instruction([string]$Name) {
    $Check = Test-InstructionName $Name
    if (-not $Check.ok) { return @{ success = $false; message = $Check.value } }
    $CleanName = $Check.value
    $Target = Join-Path $InstructionsDir $CleanName
    if (-not (Test-Path $Target)) { return @{ success = $false; message = "Rule not found: $CleanName" } }
    try { Remove-Item -LiteralPath $Target -Force } catch { return @{ success = $false; message = "Delete failed: $_" } }
    return @{ success = $true; message = "Deleted rule: $CleanName"; name = $CleanName }
}

function Get-InstructionContent([string]$Name) {
    $Check = Test-InstructionName $Name
    if (-not $Check.ok) { return @{ success = $false; message = $Check.value } }
    $CleanName = $Check.value
    $Target = Join-Path $InstructionsDir $CleanName
    if (-not (Test-Path $Target)) { return @{ success = $false; message = "Rule not found: $CleanName" } }
    try {
        $Content = [System.IO.File]::ReadAllText($Target, [System.Text.Encoding]::UTF8)
        return @{ success = $true; name = $CleanName; content = $Content }
    } catch {
        return @{ success = $false; message = "Read failed: $_" }
    }
}

function Get-RuleMap([string[]]$RuleNames, [switch]$RequireSelection) {
    if ($RequireSelection -and (-not $RuleNames -or $RuleNames.Count -eq 0)) {
        return @{ success = $false; message = "Select at least one rule."; rules = @{} }
    }
    $Requested = @{}
    if ($RuleNames) {
        foreach ($Name in $RuleNames) {
            $Check = Test-InstructionName $Name
            if (-not $Check.ok) { return @{ success = $false; message = $Check.value; rules = @{} } }
            $Requested[$Check.value] = $true
        }
    }
    $Rules = @{}
    if (Test-Path $InstructionsDir) {
        $Files = Get-ChildItem -Path $InstructionsDir -Filter "*.md" -File -ErrorAction SilentlyContinue | Sort-Object Name
        foreach ($File in $Files) {
            if ($Requested.Count -gt 0 -and -not $Requested.ContainsKey($File.Name)) { continue }
            try {
                $Rules[$File.Name] = [System.IO.File]::ReadAllText($File.FullName, [System.Text.Encoding]::UTF8).Trim()
            } catch {
                return @{ success = $false; message = "Could not read rule $($File.Name): $($_.Exception.Message)"; rules = @{} }
            }
        }
    }
    foreach ($Name in $Requested.Keys) {
        if (-not $Rules.ContainsKey($Name)) { return @{ success = $false; message = "Rule not found: $Name"; rules = @{} } }
    }
    return @{ success = $true; message = ""; rules = $Rules }
}

function Build-ManagedBlock($Rules, [string]$LegacyText = "") {
    $Parts = @()
    foreach ($Name in @($Rules.Keys | Sort-Object)) {
        $Parts += ([string]$Rules[$Name]).Trim()
    }
    if ($LegacyText.Trim()) { $Parts += $LegacyText.Trim() }
    return "$EasySkillsBegin`n$($Parts -join "`n`n")`n$EasySkillsEnd"
}

function Get-ManagedRules([string]$Content, [string]$PathStr = "") {
    $Rules = @{}
    $BeginPattern = "(?:" + (($EasySkillsBeginAliases | ForEach-Object { [regex]::Escape($_) }) -join "|") + ")"
    $OuterPattern = $BeginPattern + "\r?\n?(.*?)\r?\n?" + [regex]::Escape($EasySkillsEnd)
    $Outer = [regex]::Match($Content, $OuterPattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $Outer.Success) { return @{ Rules = $Rules; Legacy = "" } }
    $Body = $Outer.Groups[1].Value

    # Current compact format: one label starts each rule and the next label
    # ends it. Historical begin/end pairs remain readable below for migration.
    $CompactPattern = '<!-- EasySkills:(rule ([^\r\n]+?)|legacy) -->\r?\n?'
    $CompactMatches = [regex]::Matches($Body, $CompactPattern)
    if ($CompactMatches.Count -gt 0) {
        $Unmatched = @()
        $Prefix = $Body.Substring(0, $CompactMatches[0].Index).Trim()
        if ($Prefix) { $Unmatched += $Prefix }
        for ($Index = 0; $Index -lt $CompactMatches.Count; $Index++) {
            $Match = $CompactMatches[$Index]
            $SegmentStart = $Match.Index + $Match.Length
            $SegmentEnd = if ($Index + 1 -lt $CompactMatches.Count) { $CompactMatches[$Index + 1].Index } else { $Body.Length }
            $Segment = $Body.Substring($SegmentStart, $SegmentEnd - $SegmentStart).Trim()
            if ($Match.Groups[1].Value -eq "legacy") {
                if ($Segment) { $Unmatched += $Segment }
            } else {
                $Name = [System.Uri]::UnescapeDataString($Match.Groups[2].Value)
                $Rules[$Name] = $Segment
            }
        }
        return @{ Rules = $Rules; Legacy = ($Unmatched -join "`n`n") }
    }

    $MarkerPattern = '<!-- EasySkills:rule:begin ([^\r\n]+?) -->\r?\n?(.*?)\r?\n?<!-- EasySkills:rule:end -->'
    $Matches = [regex]::Matches($Body, $MarkerPattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $Unmatched = @(); $Cursor = 0
    foreach ($Match in $Matches) {
        $Gap = $Body.Substring($Cursor, $Match.Index - $Cursor).Trim()
        if ($Gap) { $Unmatched += $Gap }
        $Name = [System.Uri]::UnescapeDataString($Match.Groups[1].Value)
        $Rules[$Name] = $Match.Groups[2].Value.Trim()
        $Cursor = $Match.Index + $Match.Length
    }
    $Tail = $Body.Substring($Cursor).Trim()
    if ($Tail) { $Unmatched += $Tail }
    $Legacy = $Unmatched -join "`n`n"

    if ($Rules.Count -eq 0 -and $PathStr) {
        $Entry = Get-InstructionStateEntry $PathStr
        if ($Entry -and [string]$Entry.body_sha256 -eq (Get-BodySha256 $Body)) {
            $Restored = @{}
            $Valid = $true
            foreach ($RuleEntry in @($Entry.rules)) {
                if (-not $RuleEntry -or -not ([string]$RuleEntry.name)) { $Valid = $false; break }
                $Restored[[string]$RuleEntry.name] = [string]$RuleEntry.content
            }
            if ($Valid) {
                return @{ Rules = $Restored; Legacy = [string]$Entry.legacy }
            }
        }
    }

    if ($Legacy -and $Rules.Count -eq 0) {
        $LibraryResult = Get-RuleMap
        $Unresolved = @()
        foreach ($Part in [regex]::Split($Legacy, "\r?\n\r?\n---\r?\n\r?\n")) {
            $Found = $null
            foreach ($Name in $LibraryResult.rules.Keys) {
                if (-not $Rules.ContainsKey($Name) -and ([string]$LibraryResult.rules[$Name]).Trim() -eq $Part.Trim()) { $Found = $Name; break }
            }
            if ($Found) { $Rules[$Found] = $Part.Trim() } elseif ($Part.Trim()) { $Unresolved += $Part.Trim() }
        }
        $Legacy = $Unresolved -join "`n`n---`n`n"
    }
    return @{ Rules = $Rules; Legacy = $Legacy }
}

function Write-RulesToOne([string]$PathStr, $Rules, [bool]$Replace = $false) {
    try {
        $Resolved = [System.IO.Path]::GetFullPath($PathStr)
        $Parent = Split-Path -Path $Resolved -Parent
        if (-not (Test-Path $Parent)) { New-Item -ItemType Directory -Path $Parent -Force | Out-Null }
        $Existing = ""
        if (Test-Path $Resolved) { $Existing = [System.IO.File]::ReadAllText($Resolved, [System.Text.Encoding]::UTF8) }
        $Current = Get-ManagedRules $Existing $Resolved
        $StateEntry = Get-InstructionStateEntry $Resolved
        $StateMatches = $StateEntry -and ([string]$StateEntry.body_sha256 -eq (Get-BodySha256 ([string]$Current.Legacy)))
        if (
            -not $Replace -and
            $Existing.Contains($EasySkillsBegin) -and
            -not $Existing.Contains("EasySkills:rule") -and
            $Current.Legacy.Trim() -and
            $Current.Rules.Count -eq 0 -and
            -not $StateMatches
        ) {
            return @{ success = $false; message = "Rule sync state is missing or stale for $Resolved" }
        }
        if ($Replace) { $Current = @{ Rules = @{}; Legacy = "" } }
        foreach ($Name in $Rules.Keys) { $Current.Rules[$Name] = $Rules[$Name] }
        $Block = Build-ManagedBlock $Current.Rules $Current.Legacy
        $NewContent = Inject-ManagedBlock $Existing $Block
        $PreviousState = Get-InstructionStateEntry $Resolved
        Set-InstructionState $Resolved $Current.Rules $Current.Legacy
        try {
            Write-Utf8Atomic $Resolved $NewContent
        } catch {
            if ($PreviousState) {
                $PreviousRules = @{}
                foreach ($Entry in @($PreviousState.rules)) { $PreviousRules[[string]$Entry.name] = [string]$Entry.content }
                Set-InstructionState $Resolved $PreviousRules ([string]$PreviousState.legacy)
            } else {
                Remove-InstructionState $Resolved
            }
            throw
        }
        return @{ success = $true; message = "Wrote rules to $Resolved" }
    } catch {
        return @{ success = $false; message = "Write failed for $PathStr: $_" }
    }
}

function Write-InstructionsToOne([string]$PathStr) {
    $KnownPath = Resolve-KnownInstructionTarget $PathStr
    if (-not $KnownPath) { return @{ success = $false; message = "Unknown agent instruction target" } }
    $Library = Get-RuleMap
    if (-not $Library.success -or $Library.rules.Count -eq 0) { return @{ success = $false; message = "No rules in the library. Add rules first." } }
    return Write-RulesToOne $KnownPath $Library.rules $true
}

function Remove-InstructionsFromOne([string]$PathStr) {
    try {
        $KnownPath = Resolve-KnownInstructionTarget $PathStr
        if (-not $KnownPath) { return @{ success = $false; message = "Unknown agent instruction target" } }
        $Resolved = [System.IO.Path]::GetFullPath($KnownPath)
        if (-not (Test-Path $Resolved)) {
            Remove-InstructionState $Resolved
            return @{ success = $true; message = "File does not exist: $Resolved" }
        }
        $Content = [System.IO.File]::ReadAllText($Resolved, [System.Text.Encoding]::UTF8)
        $HasBegin = @($EasySkillsBeginAliases | Where-Object { $Content.Contains($_) }).Count -gt 0
        if (-not $HasBegin -or -not $Content.Contains($EasySkillsEnd)) {
            Remove-InstructionState $Resolved
            return @{ success = $true; message = "No managed block in $Resolved" }
        }
        $Remaining = Strip-ManagedBlock $Content
        if ($Remaining.Trim()) {
            Write-Utf8Atomic $Resolved ($Remaining.TrimEnd() + "`n")
        } else {
            Remove-Item -LiteralPath $Resolved -Force
        }
        Remove-InstructionState $Resolved
        return @{ success = $true; message = "Removed managed block from $Resolved" }
    } catch {
        return @{ success = $false; message = "Remove failed for $PathStr: $_" }
    }
}

function Remove-RulesFromOne([string]$PathStr, [string[]]$RuleNames) {
    try {
        $Resolved = [System.IO.Path]::GetFullPath($PathStr)
        if (-not (Test-Path $Resolved)) {
            Remove-InstructionState $Resolved
            return @{ success = $true; message = "File does not exist: $Resolved" }
        }
        $Existing = [System.IO.File]::ReadAllText($Resolved, [System.Text.Encoding]::UTF8)
        $HasBegin = @($EasySkillsBeginAliases | Where-Object { $Existing.Contains($_) }).Count -gt 0
        if (-not $HasBegin -or -not $Existing.Contains($EasySkillsEnd)) {
            Remove-InstructionState $Resolved
            return @{ success = $true; message = "No managed block in $Resolved" }
        }
        $Current = Get-ManagedRules $Existing $Resolved
        $StateEntry = Get-InstructionStateEntry $Resolved
        $StateMatches = $StateEntry -and ([string]$StateEntry.body_sha256 -eq (Get-BodySha256 ([string]$Current.Legacy)))
        if (
            $Existing.Contains($EasySkillsBegin) -and
            -not $Existing.Contains("EasySkills:rule") -and
            $Current.Legacy.Trim() -and
            $Current.Rules.Count -eq 0 -and
            -not $StateMatches
        ) {
            return @{ success = $false; message = "Rule sync state is missing or stale for $Resolved" }
        }
        foreach ($Name in $RuleNames) { [void]$Current.Rules.Remove($Name) }
        $PreviousState = Get-InstructionStateEntry $Resolved
        if ($Current.Rules.Count -gt 0 -or $Current.Legacy.Trim()) {
            $Updated = Inject-ManagedBlock $Existing (Build-ManagedBlock $Current.Rules $Current.Legacy)
            Set-InstructionState $Resolved $Current.Rules $Current.Legacy
        } else {
            $Updated = Strip-ManagedBlock $Existing
        }
        try {
            if ($Updated.Trim()) {
                if ($Current.Rules.Count -eq 0 -and -not $Current.Legacy.Trim()) {
                    $Updated = $Updated.TrimEnd() + "`n"
                }
                Write-Utf8Atomic $Resolved $Updated
            } else {
                Remove-Item -LiteralPath $Resolved -Force
            }
        } catch {
            if ($Current.Rules.Count -gt 0 -or $Current.Legacy.Trim()) {
                if ($PreviousState) {
                    $PreviousRules = @{}
                    foreach ($Entry in @($PreviousState.rules)) { $PreviousRules[[string]$Entry.name] = [string]$Entry.content }
                    Set-InstructionState $Resolved $PreviousRules ([string]$PreviousState.legacy)
                } else {
                    Remove-InstructionState $Resolved
                }
            }
            throw
        }
        if ($Current.Rules.Count -eq 0 -and -not $Current.Legacy.Trim()) { Remove-InstructionState $Resolved }
        return @{ success = $true; message = "Removed selected rules from $Resolved" }
    } catch {
        return @{ success = $false; message = "Remove failed for $PathStr: $_" }
    }
}

function Write-InstructionsToAll {
    $Library = Get-RuleMap
    if (-not $Library.success -or $Library.rules.Count -eq 0) { return @{ success = $false; message = "No rules in the library. Add rules first." } }
    $Targets = Get-DetectedInstructionTargets
    if ($Targets.Count -eq 0) { return @{ success = $false; message = "No detected agent instruction targets found." } }
    $Written = @(); $Failed = @()
    foreach ($T in $Targets) {
        $Result = Write-RulesToOne $T.Path $Library.rules $true
        if ($Result.success) { $Written += $T.Name } else { $Failed += "$($T.Name) ($($T.Path))" }
    }
    $Msg = "Wrote rules to $($Written.Count) agent(s)."
    if ($Failed.Count -gt 0) { $Msg += " Failed: $($Failed -join ', ')" }
    return @{ success = ($Failed.Count -eq 0); message = $Msg; written = $Written.Count; failed = $Failed }
}

function Remove-InstructionsFromAll {
    $Targets = Get-DetectedInstructionTargets
    if ($Targets.Count -eq 0) { return @{ success = $false; message = "No detected agent instruction targets found." } }
    $Removed = @(); $Failed = @()
    foreach ($T in $Targets) {
        $Result = Remove-InstructionsFromOne $T.Path
        if ($Result.success) { $Removed += $T.Name } else { $Failed += "$($T.Name) ($($T.Path))" }
    }
    $Msg = "Removed managed block from $($Removed.Count) agent(s)."
    if ($Failed.Count -gt 0) { $Msg += " Failed: $($Failed -join ', ')" }
	    return @{ success = ($Failed.Count -eq 0); message = $Msg; removed = $Removed.Count; failed = $Failed }
	}

function Write-SelectedInstructions {
    param([string[]]$Rules, [string[]]$Agents)
    if (-not $Rules -or -not $Agents) { return @{ success = $false; message = "Select at least one rule and one agent." } }
    $Library = Get-RuleMap $Rules -RequireSelection
    if (-not $Library.success -or $Library.rules.Count -eq 0) { return @{ success = $false; message = $Library.message } }
    $Targets = Get-InstructionTargets
    if (-not $Targets) { return @{ success = $false; message = "No agent instruction targets found." } }
    $AgentSet = @{}
    try {
        foreach ($a in $Agents) { $AgentSet[([System.IO.Path]::GetFullPath($a))] = $true }
    } catch {
        return @{ success = $false; message = "One or more selected Agent paths are invalid." }
    }
    $Targets = @($Targets | Where-Object { $AgentSet.ContainsKey([System.IO.Path]::GetFullPath($_.Path)) })
    if (-not $Targets) { return @{ success = $false; message = "No matching agent targets. Check the selected paths." } }
    $Written = @(); $Failed = @()
    foreach ($T in $Targets) {
        $Result = Write-RulesToOne $T.Path $Library.rules
        if ($Result.success) { $Written += $T.Name } else { $Failed += "$($T.Name) ($($T.Path))" }
    }
    $Msg = "Wrote rules to $($Written.Count) agent(s)."
    if ($Failed.Count -gt 0) { $Msg += " Failed: $($Failed -join ', ')" }
    return @{ success = ($Failed.Count -eq 0); message = $Msg; written = $Written.Count; failed = $Failed }
}

function Remove-SelectedInstructions {
    param([string[]]$Rules, [string[]]$Agents)
    if (-not $Rules -or -not $Agents) { return @{ success = $false; message = "Select at least one rule and one agent." } }
    $Library = Get-RuleMap $Rules -RequireSelection
    if (-not $Library.success -or $Library.rules.Count -eq 0) { return @{ success = $false; message = $Library.message } }
    $Targets = Get-InstructionTargets
    if (-not $Targets) { return @{ success = $false; message = "No agent instruction targets found." } }
    $AgentSet = @{}
    try {
        foreach ($a in $Agents) { $AgentSet[([System.IO.Path]::GetFullPath($a))] = $true }
    } catch {
        return @{ success = $false; message = "One or more selected Agent paths are invalid." }
    }
    $Targets = @($Targets | Where-Object { $AgentSet.ContainsKey([System.IO.Path]::GetFullPath($_.Path)) })
    if (-not $Targets) { return @{ success = $false; message = "No matching agent targets. Check the selected paths." } }
    $Removed = @(); $Failed = @()
    foreach ($T in $Targets) {
        $Result = Remove-RulesFromOne $T.Path @($Library.rules.Keys)
        if ($Result.success) { $Removed += $T.Name } else { $Failed += "$($T.Name) ($($T.Path))" }
    }
    $Msg = "Removed $($Library.rules.Count) rule(s) from $($Removed.Count) agent(s)."
    if ($Failed.Count -gt 0) { $Msg += " Failed: $($Failed -join ', ')" }
    return @{ success = ($Failed.Count -eq 0); message = $Msg; removed = $Removed.Count; failed = $Failed }
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

        # Defense against a tampered API response redirecting the update to an
        # arbitrary host. Only known GitHub delivery hosts are allowed. Mirrors
        # _is_github_download_url / _GITHUB_TARBALL_HOSTS in webui.py.
        try { $DownloadHost = ([System.Uri]$ZipUrl).Host } catch { $DownloadHost = "" }
        if (-not (Test-TrustedGitHubDownloadUrl $ZipUrl)) {
            return @{ success = $false; message = "Update rejected: download host is not a trusted GitHub host ($DownloadHost)." }
        }

        $TmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "EasySkills_update_$(Get-Random)"
        New-Item -ItemType Directory -Path $TmpDir -Force | Out-Null

        try {
            $ZipPath = Join-Path $TmpDir "release.zip"
            $Headers = @{ "Accept" = "application/vnd.github+json"; "User-Agent" = "EasySkills-WebUI" }
            $DownloadResponse = Invoke-WebRequest -Uri $ZipUrl -OutFile $ZipPath -Headers $Headers -TimeoutSec 60 -UseBasicParsing -PassThru
            $FinalDownloadUrl = Get-WebResponseFinalUrl $DownloadResponse
            if (-not (Test-TrustedGitHubDownloadUrl $FinalDownloadUrl)) {
                throw "Update rejected: download redirected to an untrusted host ($FinalDownloadUrl)."
            }

            # --- Integrity check: re-download and compare SHA-256 ---
            $VerifyPath = Join-Path $TmpDir "release_verify.zip"
            $VerifyResponse = Invoke-WebRequest -Uri $ZipUrl -OutFile $VerifyPath -Headers $Headers -TimeoutSec 60 -UseBasicParsing -PassThru
            $FinalVerifyUrl = Get-WebResponseFinalUrl $VerifyResponse
            if (-not (Test-TrustedGitHubDownloadUrl $FinalVerifyUrl)) {
                throw "Integrity download redirected to an untrusted host ($FinalVerifyUrl)."
            }
            $Hash1 = (Get-FileHash -Path $ZipPath -Algorithm SHA256).Hash
            $Hash2 = (Get-FileHash -Path $VerifyPath -Algorithm SHA256).Hash
            if ($Hash1 -ne $Hash2) {
                return @{ success = $false; message = "Integrity check failed: download digest mismatch. Aborting update." }
            }
            Remove-Item $VerifyPath -Force

            $ExtractDir = Join-Path $TmpDir "extracted"
            # Validate the ZIP central directory before expansion: cap entry
            # count/expanded bytes and reject traversal or absolute paths.
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $ZipArchive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
            try {
                if ($ZipArchive.Entries.Count -gt 10000) {
                    throw "Release archive contains too many entries."
                }
                [long]$ExpandedBytes = 0
                $ExtractRoot = [System.IO.Path]::GetFullPath($ExtractDir).TrimEnd('\') + '\'
                foreach ($Entry in $ZipArchive.Entries) {
                    $ExpandedBytes += [long]$Entry.Length
                    if ($ExpandedBytes -gt 536870912) {
                        throw "Release archive exceeds the 512 MB extracted-size safety limit."
                    }
                    $EntryPath = [System.IO.Path]::GetFullPath((Join-Path $ExtractDir $Entry.FullName))
                    if (-not $EntryPath.StartsWith($ExtractRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                        throw "Release archive contains an unsafe path: $($Entry.FullName)"
                    }
                }
            } finally {
                $ZipArchive.Dispose()
            }
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
                    Write-Utf8NoBom (Join-Path $NewMaintTmp "custom-targets.txt") $CustomBackup
                }
                if ($null -ne $DisabledBackup) {
                    Write-Utf8NoBom (Join-Path $NewMaintTmp "disabled-targets.txt") $DisabledBackup
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
                # Rollback. The dangerous case: the FIRST rename (current -> .bak)
                # succeeded but the SECOND (new -> current) failed — the running
                # version now lives in BackupMaint and DestMaint is gone. Undo the
                # first rename instead of deleting BackupMaint (which would destroy
                # the current version).
                if (Test-Path $NewMaintTmp) { Remove-Item $NewMaintTmp -Recurse -Force -ErrorAction SilentlyContinue }
                try {
                    # Undo the current->.bak rotation so the live version is restored.
                    if (-not (Test-Path $DestMaint) -and (Test-Path $BackupMaint)) {
                        Rename-Item -Path $BackupMaint -NewName "_maintenance" -Force
                    }
                    # Restore the pre-existing .bak snapshot (we overwrote it).
                    if ((Test-Path $BackupMaintNew) -and -not (Test-Path $BackupMaint)) {
                        Rename-Item -Path $BackupMaintNew -NewName "_maintenance.bak" -Force
                    }
                } catch {}
                throw
            }
        } finally {
            Remove-Item $TmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        $SyncResult = Run-DeployCommand @("-Sync")

        $NewVersion = Get-EasySkillsVersion
        $Message = "Updated to $NewVersion."
        if ($SyncResult.success) { $Message += " All agents re-synced." }
        else { $Message += " Update succeeded, but agent re-sync failed: $($SyncResult.message)" }
        return @{ success = $true; message = $Message; version = $NewVersion; sync_success = [bool]$SyncResult.success }
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
            Write-Utf8NoBom (Join-Path $RollbackTmp "custom-targets.txt") $CustomBackup
        }
        if ($null -ne $DisabledBackup) {
            Write-Utf8NoBom (Join-Path $RollbackTmp "disabled-targets.txt") $DisabledBackup
        }
        if (Test-Path $TokenFile) {
            try { Copy-Item $TokenFile (Join-Path $RollbackTmp ".easyskills-token") -Force } catch {}
        }

        # Move our own working directory OUT of _maintenance before renaming it
        try { [System.IO.Directory]::SetCurrentDirectory($CentralDir) } catch {}

        # Pre-clean _maintenance.prev: a stale .prev from a prior failed
        # rollback would make the rename below fail, dooming every subsequent
        # rollback attempt until manual cleanup.
        $Prev = Join-Path $CentralDir "_maintenance.prev"
        if (Test-Path $Prev) { Remove-Item $Prev -Recurse -Force -ErrorAction SilentlyContinue }

        try {
            # Rotate: current -> .prev, rollback-tmp -> current (two renames).
            if (Test-Path $DestMaint) {
                Rename-Item -Path $DestMaint -NewName "_maintenance.prev" -Force
            }
            Rename-Item -Path $RollbackTmp -NewName "_maintenance" -Force
        } catch {
            # If the second rename failed after the first succeeded, the
            # current version is stranded in .prev — restore it.
            try {
                if (-not (Test-Path $DestMaint) -and (Test-Path $Prev)) {
                    Rename-Item -Path $Prev -NewName "_maintenance" -Force
                }
                if (Test-Path $RollbackTmp) { Remove-Item $RollbackTmp -Recurse -Force -ErrorAction SilentlyContinue }
            } catch {}
            throw
        }

        if (Test-Path $Prev) { Remove-Item $Prev -Recurse -Force -ErrorAction SilentlyContinue }

        $SyncResult = Run-DeployCommand @("-Sync")
        # Remove backup so a second rollback doesn't restore stale state
        try { Remove-Item $BackupMaint -Recurse -Force -ErrorAction SilentlyContinue } catch {}
        $Version = Get-EasySkillsVersion
        $Message = "Rolled back to $Version."
        if ($SyncResult.success) { $Message += " All agents re-synced." }
        else { $Message += " Rollback succeeded, but agent re-sync failed: $($SyncResult.message)" }
        return @{ success = $true; message = $Message; version = $Version; sync_success = [bool]$SyncResult.success }
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
        $Items = Get-ChildItem -Path $TargetPath -Force
        foreach ($Item in $Items) {
            if (Test-EasySkillsLinkTarget $Item) {
                    # Remove the reparse point itself only — never recurse into its
                    # target (Remove-Item -Recurse on a junction can delete the real
                    # target contents on Windows PowerShell 5.1).
                    [System.IO.Directory]::Delete($Item.FullName, $false)
                    $Removed += $Item.Name
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
    # Defense-in-depth: prevent MIME sniffing and clickjacking. The index page
    # embeds the auth token in a <meta> tag, so it must not be framable.
    $Response.Headers.Add("X-Content-Type-Options", "nosniff")
    $Response.Headers.Add("X-Frame-Options", "DENY")
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
    $Response.Headers.Add("X-Content-Type-Options", "nosniff")
    $Response.Headers.Add("X-Frame-Options", "DENY")
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
            $DetectedAgents = @($Agents | Where-Object { $_.active })
            $ConfiguredInstructionPaths = @($Agents | Where-Object { $_.instructions_path })
            $ExistingInstructionFiles = @($Agents | Where-Object { $_.instructions_exists })
            $Instructions = Get-InstructionsData
            $DetectedInstructionAgents = @($Instructions.agents | Where-Object { $_.active })
            $ManagedInstructionAgents = @($DetectedInstructionAgents | Where-Object { [int]$_.managed_rule_count -gt 0 })
            $ManagedRuleInstances = 0
            foreach ($Agent in $DetectedInstructionAgents) { $ManagedRuleInstances += [int]$Agent.managed_rule_count }
            $LinkWarnings = Get-CentralDirWarnings
            $Data = @{
                watcher = Get-WatcherStatus
                central_dir = $CentralDir
                skills_count = $Skills.Count
                agents_total = $Agents.Count
                agents_detected = $DetectedAgents.Count
                agents_mapped = $MappedCount
                agent_instruction_paths_configured = $ConfiguredInstructionPaths.Count
                agent_instruction_files_existing = $ExistingInstructionFiles.Count
                instruction_targets_total = @($Instructions.agents).Count
                instruction_target_files_existing = @($Instructions.agents | Where-Object { $_.exists }).Count
                rules_count = @($Instructions.rules).Count
                instruction_agents_detected = $DetectedInstructionAgents.Count
                instruction_agents_managed = $ManagedInstructionAgents.Count
                managed_rule_instances = $ManagedRuleInstances
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
        } elseif ($UrlPath -eq "/api/instructions") {
            if (-not (Test-TokenValid $Request)) {
                Send-ForbiddenResponse $Context
                return
            }
            Send-JsonResponse $Context (Get-InstructionsData)
        } elseif ($UrlPath -like "/api/instructions/content/*") {
            if (-not (Test-TokenValid $Request)) {
                Send-ForbiddenResponse $Context
                return
            }
            $RuleName = [System.Uri]::UnescapeDataString($UrlPath.Substring("/api/instructions/content/".Length))
            Send-JsonResponse $Context (Get-InstructionContent $RuleName)
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
            if (-not ($BodyData -is [System.Collections.IDictionary])) {
                $BodyData = @{}
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
            $OldSkillsPath = if ($BodyData.ContainsKey("old_skills_path")) { $BodyData["old_skills_path"] } else { $BodyData["old_path"] }
            $SkillsPath = if ($BodyData.ContainsKey("skills_path")) { $BodyData["skills_path"] } else { $BodyData["new_path"] }
            Send-JsonResponse $Context (Update-AgentPaths $BodyData["name"] $OldSkillsPath $SkillsPath $BodyData["instructions_path"])
        } elseif ($UrlPath -eq "/api/agents/custom/add") {
            $SkillsPath = if ($BodyData.ContainsKey("skills_path")) { $BodyData["skills_path"] } else { $BodyData["path"] }
            Send-JsonResponse $Context (Register-CustomAgent $SkillsPath $BodyData["instructions_path"])
        } elseif ($UrlPath -eq "/api/agents/custom/remove") {
            Send-JsonResponse $Context (Remove-CustomAgent $BodyData["path"])
        } elseif ($UrlPath -eq "/api/skills/import") {
            Send-JsonResponse $Context (Import-SkillFolder $BodyData["name"] $BodyData["files"])
        } elseif ($UrlPath -eq "/api/skills/delete") {
            Send-JsonResponse $Context (Delete-Skill $BodyData["name"])
        } elseif ($UrlPath -eq "/api/instructions/save") {
            Send-JsonResponse $Context (Save-Instruction (Get-PayloadValue $BodyData "name") (Get-PayloadValue $BodyData "content"))
        } elseif ($UrlPath -eq "/api/instructions/delete") {
            Send-JsonResponse $Context (Remove-Instruction $BodyData["name"])
        } elseif ($UrlPath -eq "/api/instructions/write-all") {
            Send-JsonResponse $Context (Write-InstructionsToAll)
        } elseif ($UrlPath -eq "/api/instructions/remove-all") {
            Send-JsonResponse $Context (Remove-InstructionsFromAll)
        } elseif ($UrlPath -eq "/api/instructions/write-one") {
            Send-JsonResponse $Context (Write-InstructionsToOne $BodyData["path"])
        } elseif ($UrlPath -eq "/api/instructions/remove-one") {
            Send-JsonResponse $Context (Remove-InstructionsFromOne $BodyData["path"])
        } elseif ($UrlPath -eq "/api/instructions/write-selected") {
            Send-JsonResponse $Context (Write-SelectedInstructions -Rules $BodyData["rules"] -Agents $BodyData["agents"])
        } elseif ($UrlPath -eq "/api/instructions/remove-selected") {
            Send-JsonResponse $Context (Remove-SelectedInstructions -Rules $BodyData["rules"] -Agents $BodyData["agents"])
        } elseif ($UrlPath -eq "/api/update") {
            $Result = Run-SelfUpdate
            if ($Result.success) { $script:RestartRequested = $true }
            Send-JsonResponse $Context $Result
        } elseif ($UrlPath -eq "/api/rollback") {
            $Result = Do-Rollback
            if ($Result.success) { $script:RestartRequested = $true }
            Send-JsonResponse $Context $Result
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

if ($SyncRules) {
    $Res = Write-InstructionsToAll
    Write-Host "Rules Sync: $(if ($Res.success) { 'Success' } else { 'Failed' }) - $($Res.message)"
    exit (if ($Res.success) { 0 } else { 1 })
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
                if ($script:RestartRequested) { break }
            } catch {
                Write-WebUILog "Request handler error: $($_.Exception.Message)"
                Close-ResponseQuietly $Context
                if ($script:RestartRequested) { break }
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

    if ($script:RestartRequested) {
        Write-WebUILog "Backend restart requested after update/rollback."
        $RestartReady = $true
        if ($env:EASYSKILLS_SUPERVISED -ne "1") {
            # Direct launches have no supervisor. The replacement's listener
            # retry loop waits until this process releases port 6633.
            try {
                $PowerShellPath = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source
                if (-not $PowerShellPath) { $PowerShellPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" }
                $NewWebUI = Join-Path $CentralDir "_maintenance\webui.ps1"
                Start-Process -FilePath $PowerShellPath `
                    -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", "`"$NewWebUI`"", "-NoBrowser") `
                    -WorkingDirectory $CentralDir -WindowStyle Hidden -ErrorAction Stop | Out-Null
            } catch {
                $RestartReady = $false
                $script:RestartRequested = $false
                Write-WebUILog "Replacement backend launch failed; keeping current process alive: $($_.Exception.Message)"
            }
        }
        if ($RestartReady) {
            exit 0
        }
    }

    # Small breather before recreating the listener
    Start-Sleep -Seconds 1
}
