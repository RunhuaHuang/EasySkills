# ==============================================================================
# Script: webui.ps1 (Windows)
# Description: EasySkills WebUI backend - PowerShell HttpListener, zero deps.
# Usage: powershell -File _maintenance\webui.ps1
#        or: deploy.ps1 -WebUI
# ==============================================================================

$Port = 6633
$WebUIToken = [Guid]::NewGuid().ToString("N")
$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent
$CentralDir = Split-Path -Path $ScriptDir -Parent

# Dynamically resolve to official home directory installation if it exists
$HomeCentralDir = Join-Path $Home "EasySkills"
$RepoGitDir = Join-Path $CentralDir ".git"
if ((Test-Path $HomeCentralDir) -and -not (Test-Path $RepoGitDir)) {
    $CentralDir = $HomeCentralDir
    $ScriptDir = Join-Path $HomeCentralDir "_maintenance"
}

$CustomTargetsFile = Join-Path -Path $ScriptDir -ChildPath "custom-targets.txt"
$WebUIDir = Join-Path -Path $ScriptDir -ChildPath "webui"
if (-not (Test-Path $WebUIDir)) {
    $WebUIDir = Join-Path -Path (Split-Path -Path $MyInvocation.MyCommand.Definition -Parent) -ChildPath "webui"
}

$DefaultAgents = @(
    @{ Name="Antigravity CLI"; Path="$Home\.gemini\config\skills" },
    @{ Name="Antigravity IDE"; Path="$Home\.gemini\antigravity\skills" },
    @{ Name="Codex"; Path="$Home\.codex\skills" },
    @{ Name="Claude Code"; Path="$Home\.claude\skills" },
    @{ Name="GitHub Copilot"; Path="$Home\.copilot\skills" },
    @{ Name="Pi"; Path="$Home\.pi\skills" },
    @{ Name="OpenCode"; Path="$Home\.opencode\skills" },
    @{ Name="Kimi Code"; Path="$Home\.kimi\skills" },
    @{ Name="Trae (Global)"; Path="$Home\.trae\skills" },
    @{ Name="Trae (Global, App)"; Path="$env:APPDATA\Trae\skills" },
    @{ Name="Trae CN"; Path="$Home\.trae-cn\skills" },
    @{ Name="Trae CN (App)"; Path="$env:APPDATA\Trae-CN\skills" },
    @{ Name="OpenClaw"; Path="$Home\.openclaw\skills" },
    @{ Name="Hermes Agent"; Path="$Home\.hermes\skills" },
    @{ Name="Proma"; Path="$Home\.proma\default-skills" },
    @{ Name="Cursor"; Path="$Home\.cursor\skills" },
    @{ Name="Kiro Agent"; Path="$Home\.kiro\skills" },
    @{ Name="Junie (JetBrains)"; Path="$Home\.junie\skills" },
    @{ Name="Cline"; Path="$Home\.cline\skills" },
    @{ Name="Roo Code"; Path="$Home\.roo\skills" },
    @{ Name="Warp"; Path="$Home\.warp\skills" },
    @{ Name="Windsurf"; Path="$Home\.windsurf\skills" },
    @{ Name="Firebender"; Path="$Home\.firebender\skills" },
    @{ Name="Augment"; Path="$Home\.augment\skills" },
    @{ Name="Continue"; Path="$Home\.continue\skills" },
    @{ Name="Goose"; Path="$Home\.goose\skills" },
    @{ Name="Agents (Standard)"; Path="$Home\.agents\skills" },
    @{ Name="Run"; Path="$Home\.run\global-skills\skills" }
)

$ExcludeNames = @("_maintenance", ".git", "node_modules", "dist")

$VersionFile = Join-Path -Path $ScriptDir -ChildPath ".version"
function Get-EasySkillsVersion {
    if (Test-Path $VersionFile) {
        return (Get-Content $VersionFile -ErrorAction SilentlyContinue | Select-Object -First 1).Trim()
    }
    return "unknown"
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
        $First = $Rel.Split('\')[0]
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

function Get-AgentNameFromPath([string]$PathStr) {
    if ($PathStr -like "*\.gemini\antigravity\*") { return "Antigravity IDE" }
    if ($PathStr -like "*\.gemini\*") { return "Antigravity CLI" }
    if ($PathStr -like "*\.codex\*") { return "Codex" }
    if ($PathStr -like "*\.claude\*") { return "Claude Code" }
    if ($PathStr -like "*\.copilot\*") { return "GitHub Copilot" }
    if ($PathStr -like "*\.pi\*") { return "Pi" }
    if ($PathStr -like "*\.opencode\*") { return "OpenCode" }
    if ($PathStr -like "*\.kimi\*") { return "Kimi Code" }
    if ($PathStr -like "*\.trae-cn\*" -or $PathStr -like "*\Trae-CN\*") { return "Trae CN" }
    if ($PathStr -like "*\.trae\*" -or $PathStr -like "*\Trae\*") { return "Trae (Global)" }
    if ($PathStr -like "*\.openclaw\*") { return "OpenClaw" }
    if ($PathStr -like "*\.hermes\*") { return "Hermes Agent" }
    if ($PathStr -like "*\.proma\agent-workspaces\*") {
        $Parts = $PathStr.Split('\')
        for ($i = 0; $i -lt $Parts.Length; $i++) {
            if ($Parts[$i] -eq "agent-workspaces" -and $i -lt $Parts.Length - 1) {
                return "Proma Workspace ($($Parts[$i+1]))"
            }
        }
        return "Proma Workspace"
    }
    if ($PathStr -like "*\.proma\*") { return "Proma" }
    if ($PathStr -like "*\.cursor\*") { return "Cursor" }
    if ($PathStr -like "*\.kiro\*") { return "Kiro Agent" }
    if ($PathStr -like "*\.junie\*") { return "Junie (JetBrains)" }
    if ($PathStr -like "*\.cline\*") { return "Cline" }
    if ($PathStr -like "*\.roo\*") { return "Roo Code" }
    if ($PathStr -like "*\.warp\*") { return "Warp" }
    if ($PathStr -like "*\.windsurf\*") { return "Windsurf" }
    if ($PathStr -like "*\.firebender\*") { return "Firebender" }
    if ($PathStr -like "*\.augment\*") { return "Augment" }
    if ($PathStr -like "*\.continue\*") { return "Continue" }
    if ($PathStr -like "*\.goose\*") { return "Goose" }
    if ($PathStr -like "*\.agents\*") { return "Agents (Standard)" }
    if ($PathStr -like "*\.run\*") { return "Run" }
    return "Custom Agent"
}

function Is-Mapped([string]$Target) {
    $TestPath = Join-Path $Target "EasySkills"
    if (Test-Path $TestPath) {
        $Item = Get-Item $TestPath -ErrorAction SilentlyContinue
        if ($Item -and $Item.Attributes -match "ReparsePoint") {
            return $true
        }
    }
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
            $HasMd = Test-Path (Join-Path $Item.FullName "SKILL.md")
            $Skills += @{
                name = $Name
                path = $Item.FullName
                has_skill_md = $HasMd
            }
        }
    }
    return $Skills
}

function Get-AgentsData {
    $Agents = @()
    $Seen = @{}

    $CustomTargets = Get-CustomTargets
    $CustomOverrides = @{}
    $CustomList = @()

    foreach ($Ct in $CustomTargets) {
        if ($Ct.Contains("=")) {
            $Parts = $Ct.Split("=", 2)
            $CtName = $Parts[0].Trim()
            $CtPath = $Parts[1].Trim()
            $CustomOverrides[$CtName] = $CtPath
        } else {
            $CtPath = $Ct.Trim()
            $CtName = Get-AgentNameFromPath $CtPath
            $CustomList += @{ Name = $CtName; Path = $CtPath }
        }
    }

    $PromaDir = Join-Path -Path $Home -ChildPath ".proma"
    $PromaWorkspacesDir = Join-Path -Path $PromaDir -ChildPath "agent-workspaces"
    if (Test-Path $PromaWorkspacesDir) {
        $WorkspaceSkillDirs = Get-ChildItem -Path $PromaWorkspacesDir -Directory -Recurse -Filter "skills" -ErrorAction SilentlyContinue
        foreach ($WsSkills in $WorkspaceSkillDirs) {
            $CustomList += @{ Name = (Get-AgentNameFromPath $WsSkills.FullName); Path = $WsSkills.FullName }
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
        $Mapped = if (Test-Path $Path) { Is-Mapped $Path } else { $false }

        $Agents += @{
            name = $Def.Name
            path = $Path
            active = $Active
            mapped = $Mapped
            custom = $CustomOverrides.ContainsKey($Def.Name)
        }
    }

    # 2. Add Custom Agents (that don't match any default name override)
    foreach ($Ct in $CustomList) {
        if ($Seen.ContainsKey($Ct.Path)) { continue }
        $Seen[$Ct.Path] = $true

        $Root = Get-AgentRoot $Ct.Path
        $Active = Test-Path $Root
        $Mapped = if (Test-Path $Ct.Path) { Is-Mapped $Ct.Path } else { $false }

        $Agents += @{
            name = $Ct.Name
            path = $Ct.Path
            active = $Active
            mapped = $Mapped
            custom = $true
        }
    }
    return $Agents
}

function Run-DeployCommand([string[]]$ArgsArr) {
    try {
        $DeployScript = Join-Path $ScriptDir "deploy.ps1"
        $TempOut = [System.IO.Path]::GetTempFileName()
        $TempErr = [System.IO.Path]::GetTempFileName()
        $ArgList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$DeployScript`"") + $ArgsArr

        $ProcInfo = New-Object System.Diagnostics.ProcessStartInfo
        $ProcInfo.FileName = "powershell.exe"
        $ProcInfo.Arguments = ($ArgList -join " ")
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

    Do-Map $NewPath | Out-Null
    return @{ success = $true; message = "Updated $Name to $NewPath" }
}

function Do-Map([string]$TargetPath) {
    if (-not $TargetPath -or -not $TargetPath.Trim()) {
        return @{ success = $false; message = "Target path cannot be empty" }
    }
    $TargetPath = $TargetPath.Trim()
    try {
        if (-not (Test-Path $TargetPath)) {
            New-Item -ItemType Directory -Path $TargetPath -Force | Out-Null
        }
        $SelfLink = Join-Path $TargetPath "EasySkills"
        if (Test-Path $SelfLink) {
            $Item = Get-Item $SelfLink
            if ($Item.Attributes -match "ReparsePoint") {
                Remove-Item $SelfLink -Recurse -Force
            }
        }
        if (-not (Test-Path $SelfLink)) {
            New-Item -ItemType Junction -Path $SelfLink -Value $CentralDir | Out-Null
        }

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

function Run-SelfUpdate {
    try {
        $Headers = @{ "Accept" = "application/vnd.github+json"; "User-Agent" = "EasySkills-WebUI" }
        try {
            $Release = Invoke-RestMethod -Uri "https://api.github.com/repos/RunhuaHuang/EasySkills/releases/latest" -Headers $Headers -TimeoutSec 15
        } catch {
            return @{ success = $false; message = "Failed to fetch release info: $_" }
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
            Invoke-WebRequest -Uri $ZipUrl -OutFile $ZipPath -Headers $Headers -TimeoutSec 60 -UseBasicParsing

            $ExtractDir = Join-Path $TmpDir "extracted"
            Expand-Archive -Path $ZipPath -DestinationPath $ExtractDir -Force

            $SrcRoot = Get-ChildItem -Path $ExtractDir -Directory | Select-Object -First 1
            if (-not $SrcRoot) {
                return @{ success = $false; message = "Empty archive" }
            }

            $CustomBackup = $null
            if (Test-Path $CustomTargetsFile) {
                $CustomBackup = Get-Content $CustomTargetsFile -Raw -Encoding UTF8
            }

            $SrcMaint = Join-Path $SrcRoot.FullName "_maintenance"
            if (Test-Path $SrcMaint) {
                $DestMaint = Join-Path $CentralDir "_maintenance"
                $Items = Get-ChildItem -Path $SrcMaint
                foreach ($Item in $Items) {
                    $Dest = Join-Path $DestMaint $Item.Name
                    if ($Item.PSIsContainer) {
                        if (Test-Path $Dest) { Remove-Item $Dest -Recurse -Force }
                        Copy-Item $Item.FullName $Dest -Recurse -Force
                    } else {
                        Copy-Item $Item.FullName $Dest -Force
                    }
                }
            }

            $SrcSkill = Join-Path $SrcRoot.FullName "SKILL.md"
            if (Test-Path $SrcSkill) {
                Copy-Item $SrcSkill (Join-Path $CentralDir "SKILL.md") -Force
            }

            if ($null -ne $CustomBackup) {
                $CustomBackup | Set-Content -Path $CustomTargetsFile -Encoding UTF8 -Force
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

function Do-Unmap([string]$TargetPath) {
    if (-not $TargetPath -or -not $TargetPath.Trim()) {
        return @{ success = $false; message = "Target path cannot be empty" }
    }
    $TargetPath = $TargetPath.Trim()
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

function Test-PostAllowed($Request) {
    $Origin = $Request.Headers["Origin"]
    if ($Origin -and $Origin -ne "http://localhost:$Port" -and $Origin -ne "http://127.0.0.1:$Port") {
        return $false
    }
    $Token = $Request.Headers["X-EasySkills-Token"]
    return ($Token -and $Token -eq $WebUIToken)
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

$Listener = New-Object System.Net.HttpListener
$Listener.Prefixes.Add("http://localhost:$Port/")
try {
    $Listener.Start()
    Write-Host ""
    Write-Host "  EasySkills WebUI (Windows)"
    Write-Host "  =========================================="
    Write-Host "    http://localhost:$Port"
    Write-Host "    Press Ctrl+C to stop"
    Write-Host "  =========================================="
    Write-Host ""

    # Auto-open browser
    Start-Process "http://localhost:$Port"

    while ($Listener.IsListening) {
        $Context = $Listener.GetContext()
        $Request = $Context.Request
        $Method = $Request.HttpMethod
        $UrlPath = $Request.Url.AbsolutePath

        if ($Method -eq "OPTIONS") {
            $CorsOrigin = Get-CorsOrigin $Context.Request
            if (-not $CorsOrigin) {
                $Context.Response.StatusCode = 403
                $Context.Response.Close()
                continue
            }
            $Context.Response.StatusCode = 200
            $Context.Response.Headers.Add("Access-Control-Allow-Origin", $CorsOrigin)
            $Context.Response.Headers.Add("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
            $Context.Response.Headers.Add("Access-Control-Allow-Headers", "Content-Type, X-EasySkills-Token")
            $Context.Response.Close()
            continue
        }

        if ($Method -eq "GET") {
            if ($UrlPath -eq "/" -or $UrlPath -eq "/index.html") {
                Send-IndexResponse $Context (Join-Path $WebUIDir "index.html")
            } elseif ($UrlPath -eq "/favicon.ico") {
                $Context.Response.StatusCode = 204
                $Context.Response.Close()
            } elseif ($UrlPath -eq "/api/status") {
                $Skills = @(Get-SkillsData)
                $Agents = @(Get-AgentsData)
                $MappedCount = @($Agents | Where-Object { $_.mapped }).Count
                $Data = @{
                    watcher = Get-WatcherStatus
                    central_dir = $CentralDir
                    skills_count = $Skills.Count
                    agents_total = $Agents.Count
                    agents_mapped = $MappedCount
                    version = Get-EasySkillsVersion
                }
                Send-JsonResponse $Context $Data
            } elseif ($UrlPath -eq "/api/skills") {
                Send-JsonResponse $Context (Get-SkillsData)
            } elseif ($UrlPath -eq "/api/agents") {
                Send-JsonResponse $Context (Get-AgentsData)
            } else {
                $Context.Response.StatusCode = 404
                $Context.Response.Close()
            }
        } elseif ($Method -eq "POST") {
            if (-not (Test-PostAllowed $Request)) {
                Send-ForbiddenResponse $Context
                continue
            }
            $BodyData = @{}
            if ($Request.HasEntityBody) {
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
                Send-JsonResponse $Context (Run-DeployCommand @("-Watch"))
            } elseif ($UrlPath -eq "/api/watcher/stop") {
                Send-JsonResponse $Context (Run-DeployCommand @("-Unwatch"))
            } elseif ($UrlPath -eq "/api/agents/map") {
                Send-JsonResponse $Context (Do-Map $BodyData["path"])
            } elseif ($UrlPath -eq "/api/agents/unmap") {
                Send-JsonResponse $Context (Do-Unmap $BodyData["path"])
            } elseif ($UrlPath -eq "/api/agents/update") {
                Send-JsonResponse $Context (Update-AgentPath $BodyData["name"] $BodyData["old_path"] $BodyData["new_path"])
            } elseif ($UrlPath -eq "/api/agents/custom/add") {
                Send-JsonResponse $Context (Run-DeployCommand @("-Add", "`"$($BodyData["path"])`""))
            } elseif ($UrlPath -eq "/api/agents/custom/remove") {
                Send-JsonResponse $Context (Run-DeployCommand @("-Remove", "`"$($BodyData["path"])`""))
            } elseif ($UrlPath -eq "/api/update") {
                Send-JsonResponse $Context (Run-SelfUpdate)
            } else {
                $Context.Response.StatusCode = 404
                $Context.Response.Close()
            }
        } else {
            $Context.Response.StatusCode = 404
            $Context.Response.Close()
        }
    }
} catch {
    Write-Warning "WebUI server error: $_"
} finally {
    if ($Listener -and $Listener.IsListening) {
        $Listener.Stop()
    }
}
