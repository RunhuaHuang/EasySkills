# ==============================================================================
# Script: webui.ps1 (Windows)
# Description: EasySkills WebUI backend - PowerShell HttpListener, zero deps.
# Usage: powershell -File EasySkills维护工具/.engine\webui.ps1
#        or: deploy.ps1 -WebUI
# ==============================================================================

Param(
    [Parameter(Mandatory=$false)][switch]$NoBrowser,
    [Parameter(Mandatory=$false)][switch]$SyncRules,
    [Parameter(Mandatory=$false)][switch]$Doctor,
    [Parameter(Mandatory=$false)][switch]$JsonSelfTest
)

# ==============================================================================
# EasySkills JSON serializer (dependency-free)
# ------------------------------------------------------------------------------
# Windows PowerShell 5.1's ConvertTo-Json has two quirks that break parity with
# the Python backend (json.dumps, ensure_ascii=False) and render the WebUI
# incorrectly on Windows:
#   1. Piping a collection unrolls it, so a top-level array with 0 or 1 element
#      serializes as "null" / a bare object instead of "[]" / "[{...}]".
#   2. An empty array stored as an object value serializes as "null", not "[]".
# This recursive serializer is immune to both (no pipeline, explicit IList
# handling), emits "[]" for every empty array, and passes non-ASCII (e.g.
# Chinese) through as raw UTF-8 — matching the Python contract exactly. It is
# validated by -JsonSelfTest, which the CI runs on real Windows PowerShell 5.1.
# ==============================================================================
function Format-EasySkillsJsonString([string]$Value) {
    $Builder = New-Object System.Text.StringBuilder
    [void]$Builder.Append('"')
    foreach ($Char in $Value.ToCharArray()) {
        $Code = [int][char]$Char
        if ($Code -eq 34) { [void]$Builder.Append('\"') }        # "
        elseif ($Code -eq 92) { [void]$Builder.Append('\\') }    # \
        elseif ($Code -eq 8) { [void]$Builder.Append('\b') }
        elseif ($Code -eq 9) { [void]$Builder.Append('\t') }
        elseif ($Code -eq 10) { [void]$Builder.Append('\n') }
        elseif ($Code -eq 12) { [void]$Builder.Append('\f') }
        elseif ($Code -eq 13) { [void]$Builder.Append('\r') }
        elseif ($Code -lt 32) { [void]$Builder.AppendFormat('\u{0:x4}', $Code) }
        else { [void]$Builder.Append($Char) }
    }
    [void]$Builder.Append('"')
    return $Builder.ToString()
}

function ConvertTo-EasySkillsJson($Node) {
    if ($null -eq $Node) { return 'null' }
    # String before IList: a string is IList<char> and would be misrouted.
    if ($Node -is [string]) { return (Format-EasySkillsJsonString $Node) }
    # Boolean before numeric, to avoid any bool/number coercion edge.
    if ($Node -is [bool]) { if ($Node) { return 'true' } else { return 'false' } }
    if ($Node -is [int] -or $Node -is [long] -or $Node -is [byte]) { return $Node.ToString() }
    if ($Node -is [double] -or $Node -is [single] -or $Node -is [decimal]) {
        return $Node.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    }
    # Array / list (covers @(), [object[]], and any IList).
    if ($Node -is [System.Collections.IList]) {
        if ($Node.Count -eq 0) { return '[]' }
        $Parts = @()
        foreach ($Item in $Node) { $Parts += (ConvertTo-EasySkillsJson $Item) }
        return '[' + ($Parts -join ',') + ']'
    }
    # Hashtable / ordered dictionary.
    if ($Node -is [System.Collections.IDictionary]) {
        if ($Node.Count -eq 0) { return '{}' }
        $Pairs = @()
        foreach ($Key in $Node.Keys) {
            $Pairs += ((Format-EasySkillsJsonString ([string]$Key)) + ':' + (ConvertTo-EasySkillsJson $Node[$Key]))
        }
        return '{' + ($Pairs -join ',') + '}'
    }
    # PSCustomObject (defensive; the WebUI emits hashtables, never PSCustomObject).
    if ($Node -is [pscustomobject]) {
        $Props = @($Node.PSObject.Properties)
        if ($Props.Count -eq 0) { return '{}' }
        $Pairs = @()
        foreach ($Prop in $Props) {
            $Pairs += ((Format-EasySkillsJsonString $Prop.Name) + ':' + (ConvertTo-EasySkillsJson $Prop.Value))
        }
        return '{' + ($Pairs -join ',') + '}'
    }
    # Fallback for anything else (enums, etc.): stringify.
    return (Format-EasySkillsJsonString ([string]$Node))
}

if ($JsonSelfTest) {
    # Force UTF-8 on stdout so the non-ASCII fixture survives capture by the CI
    # (which redirects this process's stdout). Under PS5.1 a redirected stream
    # otherwise falls back to the system OEM code page and replaces Chinese
    # chars with '?'. This only affects this diagnostic mode; the live HTTP
    # path already writes explicit UTF-8 bytes.
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
    # Hermetic behavioral check: serialize fixtures that pin down the exact
    # ConvertTo-Json quirks above. One JSON document per line; the CI asserts
    # each line so a PS5.1 regression (empty array -> null, array unrolling,
    # lost non-ASCII) cannot slip through unnoticed.
    $Empty = @()
    $Single = @(@{ name = 'solo' })
    $Multi = @(@{ n = 1 }, @{ n = 2 })
    $Fixtures = @(
        (ConvertTo-EasySkillsJson $Empty),
        (ConvertTo-EasySkillsJson $Single),
        (ConvertTo-EasySkillsJson $Multi),
        (ConvertTo-EasySkillsJson @{ items = @(); nested = @{ inner = @() } }),
        (ConvertTo-EasySkillsJson @{ ok = $true; flag = $false; nil = $null; cnt = 42 }),
        (ConvertTo-EasySkillsJson @{ name = '技能'; path = '/路径/技能' }),
        (ConvertTo-EasySkillsJson @{ q = 'a"B\c' + [char]10 + 'd' }),
        # PSCustomObject path: /api/mcp always returns config as a PSCustomObject
        # (from ConvertFrom-Json / [pscustomobject]@{}), never a hashtable. This
        # fixture mirrors a real server entry and exercises nested PSCustomObject
        # recursion, a string array value, an empty object, and deep nesting.
        (ConvertTo-EasySkillsJson ('{"name":"ctx7","args":["-y","--port"],"env":{"KEY":"v"},"empty":{},"nested":{"deep":{"x":1}}}' | ConvertFrom-Json))
    )
    foreach ($F in $Fixtures) { Write-Output $F }
    exit 0
}

$ErrorActionPreference = 'Continue'
$script:RestartRequested = $false

function Write-Utf8NoBom([string]$Path, [string]$Content) {
    $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $Parent = Split-Path -Path $Path -Parent
    if (-not (Test-Path $Parent)) { New-Item -ItemType Directory -Path $Parent -Force | Out-Null }
    $Leaf = Split-Path -Path $Path -Leaf
    $TempPath = Join-Path $Parent (".$Leaf.$([guid]::NewGuid().ToString('N')).tmp")
    try {
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

# Port must match webui.py:PORT (the single source of truth for the server).
$Port = 6633
$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent
# The engine lives at EasySkills维护工具/.engine (two levels under the
# repo/install root), so the central directory that holds mcp/, instructions/,
# and the skill folders is TWO parents up — same as deploy.ps1's double
# Split-Path and deploy.sh's "$SCRIPT_DIR/../..". A single Split-Path would land
# on EasySkills维护工具\ (which only holds .engine/), making mcp/instructions and
# the skill scan resolve to the wrong place.
$CentralDir = Split-Path -Path (Split-Path -Path $ScriptDir -Parent) -Parent

# Dynamically resolve to the official home installation before deriving any
# token, log, or runtime paths.  Initializing those files first would leave a
# repository checkout's backend using stale state even after switching to the
# installed copy under $Home\EasySkills.
$HomeCentralDir = Join-Path $Home "EasySkills"
$RepoGitDir = Join-Path $CentralDir ".git"
if ((Test-Path $HomeCentralDir) -and -not (Test-Path $RepoGitDir)) {
    $CentralDir = $HomeCentralDir
    $ScriptDir = Join-Path $HomeCentralDir "EasySkills维护工具/.engine"
}

# Keep this long-running process's working directory OUTSIDE the engine dir so a
# self-update / rollback can rename that directory without a sharing violation.
try { [System.IO.Directory]::SetCurrentDirectory($CentralDir) } catch {}

# ---- Persistent token (survives restarts) ----
# Stored under ScriptDir (not bare home) so it stays with the installation
$TokenFile = Join-Path $ScriptDir ".easyskills-token"
function Initialize-WebUIToken {
    $EnvToken = $env:EASYSKILLS_WEBUI_TOKEN
    if ($EnvToken) { return $EnvToken }
    $TokenMutex = New-Object System.Threading.Mutex($false, "Local\EasySkillsWebUIToken")
    $Held = $false
    try {
        try {
            $Held = $TokenMutex.WaitOne(5000)
        } catch [System.Threading.AbandonedMutexException] {
            # Ownership is transferred to this process when the prior owner
            # exited without releasing the mutex.
            $Held = $true
        }
        if (-not $Held) { throw "Timed out waiting for the WebUI token lock." }

        if (Test-Path $TokenFile) {
            $Saved = (Get-Content $TokenFile -ErrorAction SilentlyContinue | Select-Object -First 1)
            if ($Saved) { $Saved = $Saved.Trim() }
            if ($Saved -and $Saved.Length -ge 16) { return $Saved }
        }

        # Reclaim empty, truncated, or invalid token files atomically. A stable
        # named mutex prevents concurrent backends from generating different
        # in-memory tokens while File.Replace swaps the on-disk value.
        $New = [Guid]::NewGuid().ToString("N") + [Guid]::NewGuid().ToString("N").Substring(0, 16)
        Write-Utf8NoBom $TokenFile $New
        return $New
    } finally {
        if ($Held) { try { $TokenMutex.ReleaseMutex() } catch {} }
        $TokenMutex.Dispose()
    }
}
$WebUIToken = if ($Doctor) { "" } else { Initialize-WebUIToken }

$WebUILogDir  = Join-Path $ScriptDir "logs"
$WebUILogFile = Join-Path $WebUILogDir "webui.log"
if (-not $Doctor -and -not (Test-Path $WebUILogDir)) {
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

# Keep direct WebUI mutations consistent with deploy.ps1's system-wide lock.
# Child deploy.ps1 invocations acquire the same mutex themselves; therefore
# callers must hold this lock only around direct file/link mutations and release
# it before invoking Run-DeployCommand.
 $script:DeployLockDepth = 0
 $script:DeployLockMutex = $null

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

function Invoke-WithDeployLock([scriptblock]$Action) {
    if ($script:DeployLockDepth -gt 0) {
        $script:DeployLockDepth++
        try { return (& $Action) }
        finally { $script:DeployLockDepth-- }
    }

    # Child deploy/webui processes inherit this marker from a parent that
    # already owns the named mutex.  Re-enter the parent's critical section
    # instead of waiting on the same mutex and deadlocking the request.
    if (Test-InheritedDeployLock) {
        return (& $Action)
    }

    $Mutex = New-Object System.Threading.Mutex($false, "Global\EasySkillsDeploy")
    $script:DeployLockMutex = $Mutex
    $Held = $false
    try {
        try {
            $Held = $Mutex.WaitOne(10000)
        } catch [System.Threading.AbandonedMutexException] {
            # .NET transfers ownership to this process after an abandoned
            # mutex, so the mutation can proceed safely.
            $Held = $true
        }
        if (-not $Held) {
            return @{ success = $false; message = "Another EasySkills synchronization is still running. Please retry shortly." }
        }
        $script:DeployLockDepth = 1
        return (& $Action)
    } finally {
        if ($Held) {
            $script:DeployLockDepth = 0
            try { $Mutex.ReleaseMutex() } catch {}
        }
        $script:DeployLockMutex = $null
        $Mutex.Dispose()
    }
}

$CustomTargetsFile = Join-Path -Path $ScriptDir -ChildPath "custom-targets.txt"
$DisabledTargetsFile = Join-Path -Path $ScriptDir -ChildPath "disabled-targets.txt"
$AgentPathConfigFile = Join-Path $CentralDir ".easyskills-agent-paths.json"

# --- Instruction-rule library (AGENTS.md / CLAUDE.md management) ---
$InstructionsDir = Join-Path $CentralDir "instructions"
$InstructionSyncStateFile = Join-Path $CentralDir ".easyskills-instruction-state.json"
$MCPDir = Join-Path $CentralDir "mcp"
$MCPConfigFile = Join-Path $MCPDir "servers.json"
$MCPConfigBackupFile = Join-Path $MCPDir "servers.json.bak"
$MCPTemplateFile = Join-Path $ScriptDir "mcp-servers.template.json"
$MCPGatewayBinary = Join-Path $CentralDir ".runtime\easyskills-mcp.exe"
$EasySkillsBegin = "<!-- EasySkills:begin -->"
$EasySkillsBeginAliases = @(
    $EasySkillsBegin,
    "<!-- EasySkills:begin (managed block - do not edit manually) -->",
    "<!-- EasySkills:begin (managed block — do not edit manually) -->"
)
$EasySkillsEnd = "<!-- EasySkills:end -->"

function Get-DefaultMCPConfig {
    if (Test-Path $MCPTemplateFile -PathType Leaf) {
        try { return (Get-Content $MCPTemplateFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch {}
    }
    return [pscustomobject]@{
        version = 1
        servers = [pscustomobject]@{}
        profiles = [pscustomobject]@{ default = [pscustomobject]@{ servers = @("*") } }
    }
}

function Test-MCPRuntimeValueSyntax([string]$Value) {
    $Marker = [char]0 + "EASYSKILLS_ESCAPED_ENV_REFERENCE" + [char]0
    $Escaped = $Value.Replace('$${env:', $Marker)
    $WithoutValidReferences = [regex]::Replace($Escaped, '\$\{env:[A-Za-z_][A-Za-z0-9_]*\}', '')
    return -not $WithoutValidReferences.Contains('${env:')
}

function Test-MCPToolPatternSyntax([string]$Pattern) {
    $Index = 0
    while ($Index -lt $Pattern.Length) {
        $Char = $Pattern[$Index]
        if ($Char -eq '\') {
            if ($Index + 1 -ge $Pattern.Length) { return $false }
            $Index += 2
            continue
        }
        if ($Char -ne '[') {
            $Index++
            continue
        }

        $Index++
        if ($Index -lt $Pattern.Length -and $Pattern[$Index] -eq '^') { $Index++ }
        $Ranges = 0
        while ($true) {
            if ($Index -lt $Pattern.Length -and $Pattern[$Index] -eq ']' -and $Ranges -gt 0) {
                $Index++
                break
            }
            if ($Index -ge $Pattern.Length -or $Pattern[$Index] -eq '-' -or $Pattern[$Index] -eq ']') { return $false }
            if ($Pattern[$Index] -eq '\') {
                $Index++
                if ($Index -ge $Pattern.Length) { return $false }
            }
            $Index++
            if ($Index -ge $Pattern.Length) { return $false }
            if ($Pattern[$Index] -eq '-') {
                $Index++
                if ($Index -ge $Pattern.Length -or $Pattern[$Index] -eq '-' -or $Pattern[$Index] -eq ']') { return $false }
                if ($Pattern[$Index] -eq '\') {
                    $Index++
                    if ($Index -ge $Pattern.Length) { return $false }
                }
                $Index++
                if ($Index -ge $Pattern.Length) { return $false }
            }
            $Ranges++
        }
    }
    return $true
}

function Test-MCPConfig($ConfigData) {
    if (-not $ConfigData) { return @{ success = $false; message = "MCP configuration must be a JSON object." } }
    $AllowedTop = @("version", "servers", "profiles")
    foreach ($Prop in @($ConfigData.PSObject.Properties)) {
        if ($Prop.Name -notin $AllowedTop) {
            return @{ success = $false; message = "Unknown top-level fields: $($Prop.Name)" }
        }
    }
    $version = $ConfigData.version
    if ($version -is [bool] -or ($version -isnot [int] -and $version -isnot [long]) -or $version -ne 1) {
        return @{ success = $false; message = "version must be 1." }
    }
    if ($null -eq $ConfigData.servers) { return @{ success = $false; message = "servers must be a JSON object." } }
    if ($ConfigData.servers -isnot [System.Management.Automation.PSCustomObject]) { return @{ success = $false; message = "servers must be a JSON object." } }
    $ProfilesProperty = $ConfigData.PSObject.Properties["profiles"]
    if ($null -ne $ProfilesProperty -and $null -eq $ConfigData.profiles) {
        return @{ success = $false; message = "profiles must be a JSON object." }
    }
    if ($null -ne $ProfilesProperty -and $ConfigData.profiles -isnot [System.Management.Automation.PSCustomObject]) {
        return @{ success = $false; message = "profiles must be a JSON object." }
    }
    $NamePattern = '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
    $AllowedFields = @(
        "enabled", "required", "transport", "command", "args", "cwd", "env",
        "url", "headers", "startup_timeout_seconds", "tool_timeout_seconds",
        "enabled_tools", "disabled_tools"
    )
    foreach ($Property in @($ConfigData.servers.PSObject.Properties)) {
        $Name = [string]$Property.Name
        $Server = $Property.Value
        if ($Name -notmatch $NamePattern) { return @{ success = $false; message = "Invalid MCP server name: $Name" } }
        if (-not $Server) { return @{ success = $false; message = "Server '$Name' must be an object." } }
        if ($Server -isnot [System.Management.Automation.PSCustomObject]) { return @{ success = $false; message = "Server '$Name' must be an object." } }
        foreach ($Prop in @($Server.PSObject.Properties)) {
            if ($Prop.Name -notin $AllowedFields) {
                return @{ success = $false; message = "Server '$Name' has unknown fields: $($Prop.Name)" }
            }
        }
        $EnabledProperty = $Server.PSObject.Properties["enabled"]
        if ($null -ne $EnabledProperty -and $null -eq $Server.enabled) {
            return @{ success = $false; message = "Server '$Name' enabled must be a boolean." }
        }
        if ($null -ne $EnabledProperty -and $Server.enabled -isnot [bool]) {
            return @{ success = $false; message = "Server '$Name' enabled must be a boolean." }
        }
        $RequiredProperty = $Server.PSObject.Properties["required"]
        if ($null -ne $RequiredProperty -and $null -eq $Server.required) {
            return @{ success = $false; message = "Server '$Name' required must be a boolean." }
        }
        if ($null -ne $RequiredProperty -and $Server.required -isnot [bool]) {
            return @{ success = $false; message = "Server '$Name' required must be a boolean." }
        }
        if ($null -eq $Server.transport -or $Server.transport -isnot [string]) {
            return @{ success = $false; message = "Server '$Name' transport must be a string." }
        }
        foreach ($TypedField in @("cwd", "command", "url")) {
            $TypedProperty = $Server.PSObject.Properties[$TypedField]
            if ($null -ne $TypedProperty -and ($null -eq $Server.$TypedField -or $Server.$TypedField -isnot [string])) {
                return @{ success = $false; message = "Server '$Name' $TypedField must be a string." }
            }
        }
        foreach ($ScalarField in @("command", "cwd", "url")) {
            $ScalarValue = [string]$Server.$ScalarField
            if ($ScalarValue.Contains([char]0)) {
                return @{ success = $false; message = "Server '$Name' $ScalarField must not contain NUL." }
            }
        }
        if ($null -ne $Server.startup_timeout_seconds) {
            $val = $Server.startup_timeout_seconds
            if ($val -is [bool] -or ($val -isnot [int] -and $val -isnot [long]) -or $val -lt 0 -or $val -gt 600) {
                return @{ success = $false; message = "Server '$Name' startup_timeout_seconds must be an integer from 0 to 600." }
            }
        } elseif ($null -ne $Server.PSObject.Properties["startup_timeout_seconds"]) {
            return @{ success = $false; message = "Server '$Name' startup_timeout_seconds must be an integer from 0 to 600." }
        }
        if ($null -ne $Server.tool_timeout_seconds) {
            $val = $Server.tool_timeout_seconds
            if ($val -is [bool] -or ($val -isnot [int] -and $val -isnot [long]) -or $val -lt 0 -or $val -gt 3600) {
                return @{ success = $false; message = "Server '$Name' tool_timeout_seconds must be an integer from 0 to 3600." }
            }
        } elseif ($null -ne $Server.PSObject.Properties["tool_timeout_seconds"]) {
            return @{ success = $false; message = "Server '$Name' tool_timeout_seconds must be an integer from 0 to 3600." }
        }
        if ($null -ne $Server.args) {
            if ($Server.args -isnot [array]) {
                return @{ success = $false; message = "Server '$Name' args must be an array of strings." }
            }
            foreach ($arg in $Server.args) {
                if ($arg -isnot [string]) {
                    return @{ success = $false; message = "Server '$Name' args must be an array of strings." }
                }
                if ($arg.Contains([char]0)) {
                    return @{ success = $false; message = "Server '$Name' args must not contain NUL." }
                }
            }
        }
        foreach ($list_field in @("enabled_tools", "disabled_tools")) {
            $val = $Server.$list_field
            if ($null -ne $val) {
                if ($val -isnot [array]) {
                    return @{ success = $false; message = "Server '$Name' $list_field must be an array of strings." }
                }
                foreach ($item in $val) {
                    if ($item -isnot [string]) {
                        return @{ success = $false; message = "Server '$Name' $list_field must be an array of strings." }
                    }
                    if (-not (Test-MCPToolPatternSyntax $item)) {
                        return @{ success = $false; message = "Server '$Name' $list_field contains invalid pattern '$item'." }
                    }
                }
            }
        }
        foreach ($map_field in @("env", "headers")) {
            $val = $Server.$map_field
            if ($null -ne $val) {
                if ($val -isnot [System.Management.Automation.PSCustomObject]) {
                    return @{ success = $false; message = "Server '$Name' $map_field must be an object of string values." }
                }
                foreach ($Prop in @($val.PSObject.Properties)) {
                    if ($Prop.Value -isnot [string]) {
                        return @{ success = $false; message = "Server '$Name' $map_field must be an object of string values." }
                    }
                    $MapKey = [string]$Prop.Name
                    $MapValue = [string]$Prop.Value
                    if ($map_field -eq "env" -and (-not $MapKey -or $MapKey.Contains("=") -or $MapKey.Contains([char]0))) {
                        return @{ success = $false; message = "Server '$Name' env '$MapKey' has an invalid variable name." }
                    }
                    if ($map_field -eq "headers" -and $MapKey -notmatch '^[!#$%&''*+\-.^_`|~0-9A-Za-z]+$') {
                        return @{ success = $false; message = "Server '$Name' header '$MapKey' has an invalid HTTP field name." }
                    }
                    if ($MapValue.Contains([char]0) -or ($map_field -eq "headers" -and ($MapValue.Contains("`r") -or $MapValue.Contains("`n")))) {
                        return @{ success = $false; message = "Server '$Name' $map_field '$MapKey' contains invalid control characters." }
                    }
                    if (-not (Test-MCPRuntimeValueSyntax ([string]$Prop.Value))) {
                        return @{ success = $false; message = "Server '$Name' $map_field '$($Prop.Name)' has an invalid environment reference; expected `${env:NAME}." }
                    }
                }
            }
        }
        $Transport = $Server.transport.Trim().ToLower().Replace("_", "-")
        if ($Transport -eq "streamable-http") { $Transport = "http" }
        if ($Transport -eq "stdio") {
            if (-not ([string]$Server.command).Trim()) { return @{ success = $false; message = "Server '$Name' requires command for stdio." } }
        } elseif ($Transport -eq "http" -or $Transport -eq "sse") {
            try {
                $RawUrl = [string]$Server.url
                if ($RawUrl -ne $RawUrl.Trim() -or $RawUrl -match '\s' -or $RawUrl.Contains('\') -or $RawUrl.Contains([char]0)) { throw "invalid" }
                if ($RawUrl -match '^[A-Za-z][A-Za-z0-9+.-]*://[^/?#]*:$') { throw "invalid" }
                $Uri = [System.Uri]$RawUrl
                $Scheme = $Uri.Scheme.ToLowerInvariant()
                if (-not $Uri.IsAbsoluteUri -or $Uri.Host -eq "" -or $Scheme -notin @("http", "https") -or $Uri.UserInfo -or $Uri.Port -lt 1 -or $Uri.Port -gt 65535) { throw "invalid" }
            } catch { return @{ success = $false; message = "Server '$Name' requires a valid http(s) URL." } }
        } else {
            return @{ success = $false; message = "Server '$Name' transport must be stdio, http, streamable-http, or sse." }
        }
    }
    if ($ConfigData.profiles) {
        $AllowedProfileFields = @("servers", "enabled_tools", "disabled_tools")
        foreach ($Property in @($ConfigData.profiles.PSObject.Properties)) {
            if ([string]$Property.Name -notmatch $NamePattern) {
                return @{ success = $false; message = "Invalid MCP profile name: $($Property.Name)" }
            }
            $Profile = $Property.Value
            if (-not $Profile -or $Profile -isnot [System.Management.Automation.PSCustomObject]) {
                return @{ success = $false; message = "Profile '$($Property.Name)' must be an object." }
            }
            foreach ($PProp in @($Profile.PSObject.Properties)) {
                if ($PProp.Name -notin $AllowedProfileFields) {
                    return @{ success = $false; message = "Profile '$($Property.Name)' has unknown fields: $($PProp.Name)" }
                }
                if ($null -ne $PProp.Value) {
                    if ($PProp.Value -isnot [array]) {
                        return @{ success = $false; message = "Profile '$($Property.Name)' $($PProp.Name) must be an array of strings." }
                    }
                    foreach ($item in $PProp.Value) {
                        if ($item -isnot [string]) {
                            return @{ success = $false; message = "Profile '$($Property.Name)' $($PProp.Name) must be an array of strings." }
                        }
                        if ($PProp.Name -ne "servers" -and -not (Test-MCPToolPatternSyntax $item)) {
                            return @{ success = $false; message = "Profile '$($Property.Name)' $($PProp.Name) contains invalid pattern '$item'." }
                        }
                    }
                }
            }
            foreach ($ServerName in @($Profile.servers)) {
                if ($ServerName -eq "*") { continue }
                if (-not $ConfigData.servers.PSObject.Properties[$ServerName]) {
                    return @{ success = $false; message = "Profile '$($Property.Name)' references unknown server '$ServerName'." }
                }
            }
        }
    }
    return @{ success = $true; message = "" }
}

function Get-MCPConfigObject {
    if (-not (Test-Path $MCPConfigFile -PathType Leaf)) { return (Get-DefaultMCPConfig) }
    $ConfigInfo = Get-Item $MCPConfigFile -ErrorAction Stop
    if ($ConfigInfo.Length -gt 1048576) { throw "MCP configuration exceeds the 1 MB limit." }
    return (Get-Content $MCPConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Get-MCPGatewayInfo {
    $Path = $MCPGatewayBinary
    if (-not (Test-Path $Path -PathType Leaf)) {
        $Command = Get-Command "easyskills-mcp.exe" -ErrorAction SilentlyContinue
        if ($Command) { $Path = $Command.Source }
    }
    $Installed = Test-Path $Path -PathType Leaf
    $Version = ""
    $VersionNumber = ""
    $ExpectedVersion = Get-EasySkillsVersion
    $VersionMatches = $null
    if ($Installed) {
        try { $Version = (& $Path version 2>$null | Select-Object -First 1) } catch {}
        if ([string]$Version -match '^easyskills-mcp\s+([^\s]+)\s+\(') {
            $VersionNumber = $Matches[1]
            if ($ExpectedVersion -ne "unknown") { $VersionMatches = ($VersionNumber -eq $ExpectedVersion) }
        }
    }
    return @{
        installed = [bool]$Installed
        path = $Path
        version = [string]$Version
        version_number = [string]$VersionNumber
        expected_version = [string]$ExpectedVersion
        version_matches = $VersionMatches
    }
}

function Install-MCPGatewayForEngine([string]$EngineDir, [string]$SourceDir = "") {
    $Installer = Join-Path $EngineDir "install-gateway.ps1"
    if (-not (Test-Path $Installer -PathType Leaf)) {
        return @{ attempted = $false; success = $true; message = "" }
    }
    try {
        $CommandArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $Installer)
        if ($SourceDir -and (Test-Path $SourceDir -PathType Container)) {
            $CommandArgs += @("-SourceDir", $SourceDir)
        }
        $Output = (& powershell @CommandArgs 2>&1 | Out-String).Trim()
        $ExitCode = $LASTEXITCODE
        return @{
            attempted = $true
            success = ($ExitCode -eq 0)
            message = if ($Output.Length -gt 4000) { $Output.Substring($Output.Length - 4000) } else { $Output }
        }
    } catch {
        return @{ attempted = $true; success = $false; message = [string]$_ }
    }
}

function Get-MCPConfigData {
    try {
        $Data = Get-MCPConfigObject
        $Validation = Test-MCPConfig $Data
        return @{
            success = [bool]$Validation.success
            path = $MCPConfigFile
            exists = (Test-Path $MCPConfigFile -PathType Leaf)
            config = if ($Validation.success) { $Data } else { $null }
            error = [string]$Validation.message
            gateway = Get-MCPGatewayInfo
        }
    } catch {
        return @{ success = $false; path = $MCPConfigFile; exists = $true; config = $null; error = "Could not read MCP config: $_"; gateway = Get-MCPGatewayInfo }
    }
}

function Save-MCPConfig-Core($ConfigData) {
    $Validation = Test-MCPConfig $ConfigData
    if (-not $Validation.success) { return $Validation }
    try {
        if (-not (Test-Path $MCPDir)) { New-Item -ItemType Directory -Path $MCPDir -Force | Out-Null }
        if (Test-Path $MCPConfigFile -PathType Leaf) {
            # Write the snapshot through the same atomic replacement gate as
            # the live config. This replaces a pre-existing backup link instead
            # of following it into an unrelated user file.
            $ExistingConfig = [System.IO.File]::ReadAllText($MCPConfigFile, [System.Text.Encoding]::UTF8)
            Write-Utf8Atomic-Core $MCPConfigBackupFile $ExistingConfig
        }
        $Json = $ConfigData | ConvertTo-Json -Depth 20
        if ([System.Text.Encoding]::UTF8.GetByteCount($Json) -gt 1048576) {
            return @{ success = $false; message = "MCP configuration exceeds the 1 MB limit." }
        }
        Write-Utf8Atomic $MCPConfigFile ($Json + "`n")
        return @{ success = $true; message = "MCP configuration saved."; config = $ConfigData }
    } catch {
        return @{ success = $false; message = "Could not save MCP configuration: $_" }
    }
}

function Save-MCPConfig($ConfigData) {
    return Invoke-WithDeployLock { Save-MCPConfig-Core $ConfigData }
}

function Add-MCPServer-Core([string]$Name, $ServerData) {
    $Clean = $Name.Trim()
    if ($Clean -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
        return @{ success = $false; message = "Server name must use letters, numbers, dot, underscore, or hyphen." }
    }
    try { $Data = Get-MCPConfigObject } catch { return @{ success = $false; message = "Could not read MCP config: $_" } }
    if ($Data.servers.PSObject.Properties[$Clean]) { return @{ success = $false; message = "MCP server '$Clean' already exists." } }
    $Data.servers | Add-Member -MemberType NoteProperty -Name $Clean -Value $ServerData
    return Save-MCPConfig-Core $Data
}

function Add-MCPServer([string]$Name, $ServerData) {
    return Invoke-WithDeployLock { Add-MCPServer-Core $Name $ServerData }
}

function Update-MCPServer-Core([string]$Name, $ServerData) {
    $Clean = $Name.Trim()
    try { $Data = Get-MCPConfigObject } catch { return @{ success = $false; message = "Could not read MCP config: $_" } }
    $Property = $Data.servers.PSObject.Properties[$Clean]
    if (-not $Property) { return @{ success = $false; message = "MCP server '$Clean' does not exist." } }
    $Property.Value = $ServerData
    return Save-MCPConfig-Core $Data
}

function Update-MCPServer([string]$Name, $ServerData) {
    return Invoke-WithDeployLock { Update-MCPServer-Core $Name $ServerData }
}

function Remove-MCPServer-Core([string]$Name) {
    $Clean = $Name.Trim()
    try { $Data = Get-MCPConfigObject } catch { return @{ success = $false; message = "Could not read MCP config: $_" } }
    if (-not $Data.servers.PSObject.Properties[$Clean]) { return @{ success = $false; message = "MCP server '$Clean' does not exist." } }
    $Data.servers.PSObject.Properties.Remove($Clean)
    foreach ($Profile in @($Data.profiles.PSObject.Properties)) {
        $Profile.Value.servers = @($Profile.Value.servers | Where-Object { $_ -ne $Clean })
    }
    return Save-MCPConfig-Core $Data
}

function Remove-MCPServer([string]$Name) {
    return Invoke-WithDeployLock { Remove-MCPServer-Core $Name }
}

function Test-MCPGateway([string]$Profile = "default", [string]$ServerName = "") {
    $Gateway = Get-MCPGatewayInfo
    if (-not $Gateway.installed) { return @{ success = $false; message = "EasySkills MCP Gateway binary is not installed." } }
    if (-not (Test-Path $MCPConfigFile -PathType Leaf)) { return @{ success = $false; message = "Save the MCP configuration before testing." } }
    if ($Profile -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') { return @{ success = $false; message = "Invalid profile name." } }
    if ($ServerName -and $ServerName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') { return @{ success = $false; message = "Invalid MCP server name." } }
    $Process = $null
    try {
        $Arguments = @("test", "--config", $MCPConfigFile, "--profile", $Profile)
        if ($ServerName) { $Arguments += @("--server", $ServerName) }
        
        $Process = New-Object System.Diagnostics.Process
        $Process.StartInfo.FileName = $Gateway.path
        $EscapedArgs = @()
        foreach ($arg in $Arguments) {
            $EscapedArgs += '"' + $arg.Replace('"', '\"') + '"'
        }
        $Process.StartInfo.Arguments = $EscapedArgs -join " "
        $Process.StartInfo.UseShellExecute = $false
        $Process.StartInfo.RedirectStandardOutput = $true
        $Process.StartInfo.RedirectStandardError = $true
        $Process.StartInfo.CreateNoWindow = $true
        
        if (-not $Process.Start()) {
            return @{ success = $false; message = "Could not run MCP Gateway." }
        }
        
        $OutTask = $Process.StandardOutput.ReadToEndAsync()
        $ErrTask = $Process.StandardError.ReadToEndAsync()
        
        if (-not $Process.WaitForExit(45000)) {
            try { $Process.Kill(); $Process.WaitForExit(2000) } catch {}
            return @{ success = $false; message = "MCP Gateway test timed out after 45 seconds." }
        }
        
        try { [void]$OutTask.Wait(2000); [void]$ErrTask.Wait(2000) } catch {}
        $Stdout = if ($OutTask.IsCompleted) { $OutTask.Result } else { "" }
        $Stderr = if ($ErrTask.IsCompleted) { $ErrTask.Result } else { "" }
        $ExitCode = $Process.ExitCode
        
        if ($ExitCode -ne 0) {
            $ErrOutput = @()
            if ($Stdout) { $ErrOutput += $Stdout }
            if ($Stderr) { $ErrOutput += $Stderr }
            return @{ success = $false; message = (($ErrOutput -join "`n").Trim()) }
        }
        
        $Summary = $Stdout | ConvertFrom-Json
        return @{ success = $true; message = "MCP Gateway test completed."; summary = $Summary }
    } catch {
        return @{ success = $false; message = "Could not run MCP Gateway: $_" }
    } finally {
        if ($Process) { try { $Process.Dispose() } catch {} }
    }
}

function Get-TargetPathFromLine([string]$Line) {
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
    return $Stripped
}

function Add-DisabledTarget([string]$Path) {
    if (-not $Path -or -not $Path.Trim()) { return $false }
    $Path = $Path.Trim()
    try { $AbsPath = Normalize-AgentPath $Path } catch { $AbsPath = $Path }

    $Lines = @()
    if (Test-Path $DisabledTargetsFile) {
        $Lines = @(Get-Content $DisabledTargetsFile -Encoding UTF8 -ErrorAction SilentlyContinue)
    }

    $Exists = $false
    foreach ($Line in $Lines) {
        $LinePath = Get-TargetPathFromLine $Line
        if (-not $LinePath) { continue }
        try { $LineAbs = Normalize-AgentPath $LinePath } catch { $LineAbs = $LinePath }
        if ($LineAbs -eq $AbsPath) {
            $Exists = $true
            break
        }
    }

    if (-not $Exists) {
        $Lines += $AbsPath
        try {
            Write-Utf8NoBom $DisabledTargetsFile (($Lines -join "`n") + "`n")
        } catch { return $false }
    }
    return $true
}

function Remove-DisabledTarget([string]$Path) {
    if (-not $Path -or -not $Path.Trim()) { return $false }
    $Path = $Path.Trim()
    try { $AbsPath = Normalize-AgentPath $Path } catch { $AbsPath = $Path }

    if (-not (Test-Path $DisabledTargetsFile -PathType Leaf)) { return $true }
    $Lines = @(Get-Content $DisabledTargetsFile -Encoding UTF8 -ErrorAction SilentlyContinue)
    $NewLines = @()
    $Updated = $false
    foreach ($Line in $Lines) {
        $LinePath = Get-TargetPathFromLine $Line
        if (-not $LinePath) {
            $NewLines += $Line
            continue
        }
        try { $LineAbs = Normalize-AgentPath $LinePath } catch { $LineAbs = $LinePath }
        if ($LineAbs -eq $AbsPath) {
            $Updated = $true
        } else {
            $NewLines += $Line
        }
    }

    if ($Updated) {
        try {
            Write-Utf8NoBom $DisabledTargetsFile (($NewLines -join "`n") + "`n")
        } catch { return $false }
    }
    return $true
}

function Get-DisabledTargets {
    $Set = @{}
    if (Test-Path $DisabledTargetsFile) {
        $Lines = Get-Content $DisabledTargetsFile -Encoding UTF8 -ErrorAction SilentlyContinue
        foreach ($Line in $Lines) {
            $Stripped = Get-TargetPathFromLine $Line
            if ($Stripped) {
                try { $Norm = Normalize-AgentPath $Stripped } catch { $Norm = $Stripped }
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
        @{ Name="MiniMax Code"; Path="$Home\.mavis\agents\mavis\skills" }
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
if (-not $Doctor -and -not (Test-Path $qoderCnSkillsDir)) {
    New-Item -Path $qoderCnSkillsDir -ItemType Directory -Force | Out-Null
}

$ExcludeNames = @("EasySkills维护工具", ".git", "node_modules", "dist", "docs", "instructions", "mcp", ".runtime", ".maintenance-bak")
$WindowsReservedFileNames = @("CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9")
$GitHubRepo = "RunhuaHuang/EasySkills"
$GitHubApiLatestRelease = "https://api.github.com/repos/$GitHubRepo/releases/latest"
$GitHubLatestRelease = "https://github.com/$GitHubRepo/releases/latest"
$GitHubReleaseTagPrefix = "https://github.com/$GitHubRepo/releases/tag/"
$TrustedDownloadHosts = @("api.github.com", "github.com", "codeload.github.com", "objects.githubusercontent.com")

function Test-TrustedGitHubDownloadUrl([string]$Url) {
    try { $Uri = [System.Uri]$Url } catch { return $false }
    $DownloadHostName = $Uri.Host.ToLowerInvariant()
    $DefaultPort = $Uri.IsDefaultPort -or $Uri.Port -eq 443
    return ($Uri.Scheme -eq "https") -and
        [string]::IsNullOrEmpty($Uri.UserInfo) -and
        $DefaultPort -and
        ($TrustedDownloadHosts -contains $DownloadHostName)
}

function Save-BoundedWebFile(
    [string]$Uri,
    [string]$Path,
    [long]$MaxBytes,
    [string]$LimitMessage,
    [int]$TimeoutSeconds = 60,
    [hashtable]$Headers = @{}
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
            $DeclaredLength = $Response.Content.Headers.ContentLength
            if ($null -ne $DeclaredLength -and [long]$DeclaredLength -gt $MaxBytes) { throw $LimitMessage }
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

# Keep WebUI self-update extraction on the same safety contract as the
# installer. Expand-Archive behavior varies across Windows PowerShell/.NET
# versions, and a plain path-prefix check does not model ZIP symlink chains.
function Normalize-ZipPath([string]$Name) {
    if (-not $Name -or $Name.Contains([char]0)) {
        throw "Release archive contains an invalid path."
    }
    if ($Name.StartsWith('/') -or $Name.StartsWith('\') -or $Name -match '^[A-Za-z]:') {
        throw "Release archive contains an unsafe path: $Name"
    }
    $Parts = $Name.Replace('\', '/').Split('/')
    $Stack = New-Object System.Collections.Generic.List[string]
    foreach ($Part in $Parts) {
        if (-not $Part -or $Part -eq '.') { continue }
        if ($Part -eq '..') {
            if ($Stack.Count -eq 0) { throw "Release archive contains an unsafe path: $Name" }
            [void]$Stack.RemoveAt($Stack.Count - 1)
            continue
        }
        if ($Part.Contains(':')) { throw "Release archive contains an unsafe path: $Name" }
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
            if ($Visited.ContainsKey($Prefix)) { throw "Release archive contains a cyclic link: $Prefix" }
            $Target = [string]$Links[$Prefix]
            if ($Target.StartsWith('/') -or $Target.StartsWith('\') -or $Target -match '^[A-Za-z]:') {
                throw "Release archive contains an unsafe link: $Prefix"
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
    throw "Release archive contains an excessively deep link chain."
}

function Assert-SafeZipArchive([string]$ZipPath, [string]$DestinationPath) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $Archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        if ($Archive.Entries.Count -gt 10000) {
            throw "Release archive contains too many entries."
        }
        [long]$ExpandedBytes = 0
        $DestinationRoot = [System.IO.Path]::GetFullPath($DestinationPath).TrimEnd('\\') + '\\'
        $Seen = @{}
        $Links = @{}
        foreach ($Entry in $Archive.Entries) {
            $ExpandedBytes += [long]$Entry.Length
            if ($ExpandedBytes -gt 536870912) {
                throw "Release archive exceeds the 512 MB extracted-size safety limit."
            }
            $NormalizedName = Normalize-ZipPath $Entry.FullName
            if (-not $NormalizedName -or $Seen.ContainsKey($NormalizedName)) {
                throw "Release archive contains a duplicate path: $($Entry.FullName)"
            }
            $Seen[$NormalizedName] = $true

            # GitHub ZIP archives preserve Unix symlink metadata in the upper
            # mode bits of ExternalAttributes. Validate the complete virtual
            # graph before Expand-Archive writes anything.
            $UnixType = (([uint64]$Entry.ExternalAttributes -shr 16) -band 0xF000)
            if ($UnixType -eq 0xA000) {
                $LinkStream = $Entry.Open()
                try {
                    $Reader = [System.IO.StreamReader]::new($LinkStream, [System.Text.UTF8Encoding]::new($false), $true)
                    try { $LinkTarget = $Reader.ReadToEnd() } finally { $Reader.Dispose() }
                } finally { $LinkStream.Dispose() }
                if (-not $LinkTarget) { throw "Release archive contains an empty symbolic link: $($Entry.FullName)" }
                $Links[$NormalizedName] = $LinkTarget.TrimEnd([char]0, "`r", "`n")
            }

            $EntryPath = [System.IO.Path]::GetFullPath((Join-Path $DestinationPath $NormalizedName))
            if (-not $EntryPath.StartsWith($DestinationRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Release archive contains an unsafe path: $($Entry.FullName)"
            }
        }
        foreach ($Name in @($Seen.Keys)) {
            [void](Resolve-ZipVirtualPath $Name $Links $true)
        }
    } finally {
        $Archive.Dispose()
    }
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
        $CtPath = Get-TargetPathFromLine $Ct
        if ($CtPath -ne $Ct.Trim()) {
            $CtName = $Ct.Substring(0, $Ct.IndexOf("=")).Trim()
            $CtPath = Normalize-AgentPath $CtPath
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
        if ($script:DeployLockDepth -gt 0) {
            $ProcInfo.EnvironmentVariables["EASYSKILLS_DEPLOY_LOCK_HELD"] = "1"
            $ProcInfo.EnvironmentVariables["EASYSKILLS_DEPLOY_LOCK_PID"] = [string]$PID
        }

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

function Update-AgentPaths-Core(
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
    $TargetValidation = Resolve-MappingTarget $SkillsPath
    if (-not $TargetValidation.success) { return $TargetValidation }
    $NewPath = $TargetValidation.path
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

    $WasMapped = $Current.Count -gt 0 -and [bool]$Current[0].mapped
    if ($WasMapped) {
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
            if (-not $CleanupResult.success) {
                $CleanupWarning = " Warning: old skills links at $OldPath could not be fully removed: $($CleanupResult.message)."
            } elseif (-not (Remove-DisabledTarget $OldPath)) {
                $CleanupWarning = " Warning: old skills links were removed, but the disabled-target state for $OldPath could not be cleared."
            }
        } elseif (-not (Remove-DisabledTarget $NewPath)) {
            $CleanupWarning = " Warning: the Agent is mapped, but the disabled-target state for $NewPath could not be cleared."
        }
    } else {
        if (-not (Add-DisabledTarget $NewPath)) {
            return @{
                success = $false
                message = "Agent paths were saved, but the disabled-target state for $NewPath could not be persisted."
                skills_path = $NewPath
                instructions_path = $NewInstructionsPath
                partial = $true
            }
        }
        $CleanupWarning = ""
    }
    $Result = @{
        success = $true
        message = "Updated $Name skills and instructions paths.$CleanupWarning"
        skills_path = $NewPath
        instructions_path = $NewInstructionsPath
    }
    if ($CleanupWarning) { $Result.partial = $true }
    return $Result
}

function Update-AgentPaths(
    [string]$Name,
    [string]$OldSkillsPath,
    [string]$SkillsPath,
    [string]$InstructionsPath
) {
    return Invoke-WithDeployLock {
        Update-AgentPaths-Core $Name $OldSkillsPath $SkillsPath $InstructionsPath
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

function Register-CustomAgent-Core([string]$SkillsPath, [string]$InstructionsPath) {
    $SkillsValidation = Resolve-MappingTarget $SkillsPath
    if (-not $SkillsValidation.success) { return $SkillsValidation }
    $SkillsPath = $SkillsValidation.path
    $InstructionsPath = Normalize-AgentPath $InstructionsPath
    if (-not $InstructionsPath) {
        return @{ success = $false; message = "Instructions file path cannot be empty" }
    }
    if ((Test-Path $InstructionsPath) -and -not (Test-Path $InstructionsPath -PathType Leaf)) {
        return @{ success = $false; message = "Instructions path must point to a file, not a directory" }
    }

    $WasRegistered = $false
    foreach ($Target in @(Get-CustomTargets)) {
        $TargetPath = Get-TargetPathFromLine $Target
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

function Register-CustomAgent([string]$SkillsPath, [string]$InstructionsPath) {
    # Run-DeployCommand inherits this parent's lock marker, so the complete
    # deploy + metadata transaction remains serialized without deadlocking.
    return Invoke-WithDeployLock { Register-CustomAgent-Core $SkillsPath $InstructionsPath }
}

function Remove-CustomAgent-Core([string]$SkillsPath) {
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

function Remove-CustomAgent([string]$SkillsPath) {
    return Invoke-WithDeployLock { Remove-CustomAgent-Core $SkillsPath }
}

function Resolve-MappingTarget([string]$PathStr) {
    if (-not $PathStr -or -not $PathStr.Trim()) {
        return @{ success = $false; message = "Target path cannot be empty" }
    }
    $Normalized = Normalize-AgentPath $PathStr
    if (-not $Normalized) {
        return @{ success = $false; message = "Target path cannot be empty" }
    }
    if (Test-Path -LiteralPath $Normalized) {
        if (-not (Test-Path -LiteralPath $Normalized -PathType Container)) {
            return @{ success = $false; message = "Target path must be a directory" }
        }
        try { $Resolved = (Resolve-Path -LiteralPath $Normalized -ErrorAction Stop).ProviderPath }
        catch { $Resolved = $Normalized }
    } else {
        $Resolved = $Normalized
    }
    try { $CentralResolved = (Resolve-Path -LiteralPath $CentralDir -ErrorAction Stop).ProviderPath }
    catch { $CentralResolved = Normalize-AgentPath $CentralDir }
    if ($Resolved.Equals($CentralResolved, [System.StringComparison]::OrdinalIgnoreCase) -or
        $Resolved.StartsWith("$CentralResolved\", [System.StringComparison]::OrdinalIgnoreCase)) {
        return @{ success = $false; message = "Target path cannot be the EasySkills library or one of its subdirectories" }
    }
    return @{ success = $true; path = $Normalized }
}

function Do-Map-Core([string]$TargetPath) {
    $Validation = Resolve-MappingTarget $TargetPath
    if (-not $Validation.success) { return $Validation }
    $TargetPath = $Validation.path
    try {
        if (!(Test-Path -LiteralPath $TargetPath -PathType Container)) {
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
        if (-not (Remove-DisabledTarget $TargetPath)) {
            return @{ success = $false; partial = $true; message = "Skills were mapped, but the disabled-target state could not be updated; please retry" }
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

function Do-Map([string]$TargetPath) {
    return Invoke-WithDeployLock { Do-Map-Core $TargetPath }
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
    if ($Clean -ne $Name) { return @{ ok = $false; value = "Invalid skill name" } }
    if ($Clean.StartsWith("_") -or $Clean.StartsWith(".") -or ($ExcludeNames -contains $Clean)) {
        return @{ ok = $false; value = "Reserved skill name" }
    }
    $BaseName = $Clean.Split('.')[0].ToUpperInvariant()
    if ($Clean -match '[<>:"/\\|?*\x00-\x1F]' -or $Clean.EndsWith(".") -or $Clean.EndsWith(" ") -or ($WindowsReservedFileNames -contains $BaseName) -or $Clean -eq "." -or $Clean -eq "..") {
        return @{ ok = $false; value = "Invalid skill name" }
    }
    return @{ ok = $true; value = $Clean }
}

function Find-CaseInsensitiveChild([string]$Directory, [string]$Name) {
    if (-not (Test-Path $Directory -PathType Container)) { return $null }
    try {
        return Get-ChildItem -LiteralPath $Directory -Force -ErrorAction Stop |
            Where-Object { $_.Name.Equals($Name, [System.StringComparison]::OrdinalIgnoreCase) } |
            Select-Object -First 1
    } catch {
        return $null
    }
}

function ConvertTo-SafeRelativePath([string]$PathValue) {
    if (-not $PathValue -or $PathValue.Contains([char]0)) { return $null }
    $Normalized = $PathValue.Replace("\", "/")
    if ($Normalized.StartsWith("/") -or $Normalized.Contains(":")) { return $null }
    $Parts = $Normalized.Split("/")
    foreach ($Part in $Parts) {
        if (-not $Part -or $Part -eq "." -or $Part -eq "..") { return $null }
        $BaseName = $Part.Split('.')[0].ToUpperInvariant()
        if ($Part -match '[<>:"/\\|?*\x00-\x1F]' -or $Part.EndsWith(".") -or $Part.EndsWith(" ") -or ($WindowsReservedFileNames -contains $BaseName)) {
            return $null
        }
    }
    return ($Parts -join [System.IO.Path]::DirectorySeparatorChar)
}

function Import-SkillFolder-Core([string]$Name, $Files) {
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
    $Collision = Find-CaseInsensitiveChild $CentralDir $CleanName
    if ($Collision) {
        return @{ success = $false; message = "Skill name conflicts case-insensitively with: $($Collision.Name)" }
    }

    $Prepared = @()
    $SeenPaths = @{}
    $HasSkillMd = $false
    foreach ($File in @($Files)) {
        $RelRaw = [string](Get-PayloadValue $File "path")
        $Rel = ConvertTo-SafeRelativePath $RelRaw
        if (-not $Rel) { return @{ success = $false; message = "Invalid file path in upload" } }
        $Folded = $Rel.Replace('\', '/').ToLowerInvariant()
        if ($SeenPaths.ContainsKey($Folded)) { return @{ success = $false; message = "Duplicate file path in upload: $RelRaw" } }
        $SeenPaths[$Folded] = $true
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
    $Result = @{ success = $true; message = $Msg; skill = $CleanName; sync_success = [bool]$Sync.success }
    if (-not $Sync.success) { $Result.partial = $true }
    return $Result
}

function Import-SkillFolder([string]$Name, $Files) {
    return Invoke-WithDeployLock { Import-SkillFolder-Core $Name $Files }
}

function Delete-Skill-Core([string]$Name) {
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
    $Result = @{ success = $true; message = $Msg; skill = $CleanName; cleanup_success = [bool]$Cleanup.success; sync_success = [bool]$Sync.success }
    if (-not $Cleanup.success -or -not $Sync.success) { $Result.partial = $true }
    return $Result
}

function Delete-Skill([string]$Name) {
    return Invoke-WithDeployLock { Delete-Skill-Core $Name }
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
    if ($Clean -ne $Name) { return @{ ok = $false; value = "Invalid rule name" } }
    $BaseName = $Clean.Split('.')[0].ToUpperInvariant()
    if ($Clean -match '[<>:"/\\|?*\x00-\x1F]' -or $Clean.EndsWith(".") -or $Clean.EndsWith(" ") -or ($WindowsReservedFileNames -contains $BaseName) -or $Clean -eq "." -or $Clean -eq "..") {
        return @{ ok = $false; value = "Invalid rule name" }
    }
    if ($Clean.ToLowerInvariant().EndsWith(".md")) { $Clean = $Clean.Substring(0, $Clean.Length - 3) + ".md" }
    else { $Clean = $Clean + ".md" }
    return @{ ok = $true; value = $Clean }
}

# Remove EVERY managed block and orphan begin/end marker from content.
# Mirrors webui._purge_all_managed_markers: stack-paired begin..end spans are
# dropped as managed blocks (so duplicate/pasted blocks never linger), and
# text between an orphan begin and the real block is preserved — a naive
# begin.*?end regex would instead swallow that user content. Trailing CRLF is
# absorbed (Windows files keep \r\n here, unlike Python's read_text).
function Purge-AllManagedMarkers([string]$Text) {
    # 1) Collect every begin (any alias) and end marker position.
    $Markers = New-Object System.Collections.Generic.List[object]
    foreach ($Alias in $EasySkillsBeginAliases) {
        $Start = 0
        while (($Idx = $Text.IndexOf($Alias, $Start)) -ge 0) {
            $null = $Markers.Add([pscustomobject]@{ Index = $Idx; Kind = "begin"; Length = $Alias.Length })
            $Start = $Idx + $Alias.Length
        }
    }
    $Start = 0
    while (($Idx = $Text.IndexOf($EasySkillsEnd, $Start)) -ge 0) {
        $null = $Markers.Add([pscustomobject]@{ Index = $Idx; Kind = "end"; Length = $EasySkillsEnd.Length })
        $Start = $Idx + $EasySkillsEnd.Length
    }
    $Sorted = $Markers | Sort-Object Index

    # 2) Stack-pair: each end closes the nearest open begin.
    $Spans = New-Object System.Collections.Generic.List[object]
    $Stack = New-Object System.Collections.Stack
    foreach ($Mk in $Sorted) {
        if ($Mk.Kind -eq "begin") {
            $Stack.Push($Mk)
        } else {
            if ($Stack.Count -gt 0) {
                $Open = $Stack.Pop()
                $null = $Spans.Add([pscustomobject]@{ Begin = $Open.Index; EndPos = $Mk.Index + $Mk.Length })
            }
            # an end with no open begin is an orphan, handled in step 4.
        }
    }

    # 3) Drop matched spans (trailing \r\n or \n absorbed), back-to-front.
    foreach ($Span in ($Spans | Sort-Object Begin -Descending)) {
        $Absorb = $Span.EndPos
        if ($Absorb -lt $Text.Length -and $Text[$Absorb] -eq "`n") {
            $Absorb += 1
        } elseif ($Absorb + 1 -le $Text.Length -and $Text.Substring($Absorb, 2) -eq "`r`n") {
            $Absorb += 2
        }
        # Substring(int) throws when startIndex == length; guard like Python's
        # text[absorb:] which safely returns "" at the end of the string.
        $Tail = if ($Absorb -lt $Text.Length) { $Text.Substring($Absorb) } else { "" }
        $Text = $Text.Substring(0, $Span.Begin) + $Tail
    }

    # 4) Remove any remaining orphan begin/end markers.
    foreach ($Alias in $EasySkillsBeginAliases) {
        $Text = $Text.Replace($Alias, "")
    }
    $Text = $Text.Replace($EasySkillsEnd, "")
    return $Text
}

# Replace or insert the managed block within an instruction file's content.
# Duplicate/orphan markers from copy-paste or legacy aliases are purged first so
# the file is left with at most one clean block.
function Inject-ManagedBlock([string]$Existing, [string]$Block) {
    $HasBlock = $Existing.Contains($EasySkillsEnd) -and ($EasySkillsBeginAliases | Where-Object { $Existing.Contains($_) })
    if ($HasBlock) {
        $UserContent = Purge-AllManagedMarkers $Existing
        if ($UserContent.Trim()) {
            return $UserContent.TrimEnd() + "`n`n" + $Block + "`n"
        }
        return $Block + "`n"
    }
    if ($Existing.Trim()) {
        return $Existing.TrimEnd() + "`n`n" + $Block + "`n"
    }
    return $Block + "`n"
}

# Remove the managed block from content.
function Strip-ManagedBlock([string]$Content) {
    if (-not ($Content.Contains($EasySkillsEnd)) -and -not ($EasySkillsBeginAliases | Where-Object { $Content.Contains($_) })) {
        return $Content
    }
    return Purge-AllManagedMarkers $Content
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

function Get-SupportSafePath([string]$PathStr) {
    if (-not $PathStr) { return "" }
    try {
        $FullPath = [System.IO.Path]::GetFullPath($PathStr)
        $HomePath = [System.IO.Path]::GetFullPath($Home)
        while ($HomePath.EndsWith("\") -or $HomePath.EndsWith("/")) {
            $HomePath = $HomePath.Substring(0, $HomePath.Length - 1)
        }
        if ($FullPath.Equals($HomePath, [System.StringComparison]::OrdinalIgnoreCase)) {
            return "~"
        }
        $HomePrefixBackslash = "$HomePath\"
        $HomePrefixSlash = "$HomePath/"
        if ($FullPath.StartsWith($HomePrefixBackslash, [System.StringComparison]::OrdinalIgnoreCase) -or
            $FullPath.StartsWith($HomePrefixSlash, [System.StringComparison]::OrdinalIgnoreCase)) {
            return "~" + $FullPath.Substring($HomePath.Length)
        }
        return $FullPath
    } catch {
        return $PathStr
    }
}

function Test-MCPSensitiveValue([string]$Field, [string]$Name) {
    $Normalized = $Name.Trim().ToLowerInvariant()
    if ($Field -eq "headers" -and $Normalized -in @(
        "authorization", "proxy-authorization", "x-api-key", "api-key",
        "cookie", "set-cookie"
    )) {
        return $true
    }
    return $Normalized -match '(?:^|[_-])(?:api[_-]?key|access[_-]?token|refresh[_-]?token|token|secret|password|passwd|credential|authorization|auth|cookie)(?:[_-]|$)'
}

function Get-MCPCredentialPosture($ConfigData) {
    $References = 0
    $Literals = 0
    if (-not $ConfigData -or -not $ConfigData.servers) {
        return @{ environment_references = 0; literal_values = 0 }
    }
    foreach ($ServerProperty in @($ConfigData.servers.PSObject.Properties)) {
        $Server = $ServerProperty.Value
        if (-not $Server) { continue }
        foreach ($Field in @("env", "headers")) {
            $Values = $Server.$Field
            if (-not $Values) { continue }
            foreach ($Property in @($Values.PSObject.Properties)) {
                $Value = [string]$Property.Value
                if (-not $Value -or -not (Test-MCPSensitiveValue $Field ([string]$Property.Name))) { continue }
                if ($Value -match '(?<!\$)\$\{env:[A-Za-z_][A-Za-z0-9_]*\}') {
                    $References++
                } else {
                    $Literals++
                }
            }
        }
    }
    return @{ environment_references = $References; literal_values = $Literals }
}

function Get-DoctorReport {
    $Skills = @(Get-SkillsData)
    $Agents = @(Get-VisibleAgentsData)
    $DetectedAgents = @($Agents | Where-Object { $_.active })
    $MappedAgents = @($DetectedAgents | Where-Object { $_.mapped })
    $Instructions = Get-InstructionsData
    $InstructionAgents = @($Instructions.agents)
    $DetectedInstructionAgents = @($InstructionAgents | Where-Object { $_.active })
    $ManagedInstructionAgents = @($DetectedInstructionAgents | Where-Object { [int]$_.managed_rule_count -gt 0 })
    $Rules = @($Instructions.rules)
    $LinkWarnings = Get-CentralDirWarnings
    $Watcher = Get-WatcherStatus
    $MCPData = Get-MCPConfigData
    $MCPServerProperties = @()
    if ($MCPData.success -and $MCPData.config -and $MCPData.config.servers) {
        $MCPServerProperties = @($MCPData.config.servers.PSObject.Properties)
    }
    $EnabledMCPServers = @($MCPServerProperties | Where-Object {
        $null -eq $_.Value.enabled -or [bool]$_.Value.enabled
    })
    $MCPConfigForPosture = $null
    if ($MCPData.success) { $MCPConfigForPosture = $MCPData.config }
    $CredentialPosture = Get-MCPCredentialPosture $MCPConfigForPosture
    $Gateway = $MCPData.gateway
    $Checks = New-Object System.Collections.ArrayList
    $AddCheck = {
        param([string]$Id, [string]$Status, [string]$Message, [string]$Action = "")
        [void]$Checks.Add(@{ id = $Id; status = $Status; message = $Message; action = $Action })
    }

    if (Test-Path $CentralDir -PathType Container) {
        & $AddCheck "central-directory" "ok" "Central EasySkills directory is available."
    } else {
        & $AddCheck "central-directory" "error" "Central EasySkills directory is missing." "Reinstall EasySkills or restore the directory from backup."
    }

    if ($Watcher.running) {
        & $AddCheck "watcher" "ok" "Background synchronization watcher is running."
    } else {
        & $AddCheck "watcher" "warning" "Background synchronization watcher is stopped." "Start the watcher from the dashboard or run deploy.ps1 -Watch."
    }

    $Dangling = [int]$LinkWarnings.dangling_count
    $External = [int]$LinkWarnings.external_link_count
    if ($Dangling -gt 0) {
        & $AddCheck "link-health" "warning" "$Dangling dangling central skill link(s) detected." "Run a full sync to prune dangling links."
    } elseif ($External -gt 0) {
        & $AddCheck "link-health" "warning" "$External externally linked skill folder(s) detected." "Keep external targets available or import them into the central library."
    } else {
        & $AddCheck "link-health" "ok" "No dangling or external central skill links detected."
    }

    if ($Skills.Count -gt 0 -and $MappedAgents.Count -gt 0) {
        & $AddCheck "skills-channel" "ok" "$($Skills.Count) skill(s) are connected to $($MappedAgents.Count) detected Agent(s)."
    } elseif ($Skills.Count -gt 0) {
        & $AddCheck "skills-channel" "warning" "$($Skills.Count) skill(s) exist but no detected Agent is connected." "Connect an Agent target or run a full sync."
    } else {
        & $AddCheck "skills-channel" "info" "The central skill library is empty." "Import a skill when you are ready."
    }

    if ($Rules.Count -gt 0 -and $ManagedInstructionAgents.Count -gt 0) {
        & $AddCheck "rules-channel" "ok" "$($Rules.Count) rule(s) are written to $($ManagedInstructionAgents.Count) detected Agent target(s)."
    } elseif ($Rules.Count -gt 0) {
        & $AddCheck "rules-channel" "warning" "$($Rules.Count) rule(s) exist but none are written to a detected Agent target." "Select rules and Agent targets, then write the managed blocks."
    } else {
        & $AddCheck "rules-channel" "info" "The modular Agent rules library is empty."
    }

    if (-not $MCPData.success) {
        & $AddCheck "mcp-config" "error" "The MCP configuration is invalid or unreadable." "Open the MCP page and correct the configuration error."
    } elseif ($Gateway.installed -and $Gateway.version_matches -eq $false) {
        & $AddCheck "mcp-channel" "warning" "Gateway version $($Gateway.version_number) does not match EasySkills $($Gateway.expected_version)." "Reinstall the Gateway from this EasySkills version before using MCP tools."
    } elseif ($MCPServerProperties.Count -gt 0 -and $Gateway.installed) {
        & $AddCheck "mcp-channel" "ok" "Gateway installed with $($EnabledMCPServers.Count) enabled server(s)."
    } elseif ($MCPServerProperties.Count -gt 0) {
        & $AddCheck "mcp-channel" "warning" "$($MCPServerProperties.Count) MCP server(s) are configured but the Gateway binary is missing." "Retry the Gateway installation from EasySkills."
    } elseif ($Gateway.installed) {
        & $AddCheck "mcp-channel" "info" "Gateway is installed; no downstream MCP server is configured yet."
    } else {
        & $AddCheck "mcp-channel" "info" "MCP Gateway is not installed and no downstream server is configured."
    }

    if ([int]$CredentialPosture.literal_values -gt 0) {
        & $AddCheck "credential-posture" "warning" "$($CredentialPosture.literal_values) MCP credential value(s) are stored literally." 'Replace literal secrets with ${env:VARIABLE} references where possible.'
    } elseif ([int]$CredentialPosture.environment_references -gt 0) {
        & $AddCheck "credential-posture" "ok" "$($CredentialPosture.environment_references) MCP credential value(s) use environment references."
    } else {
        & $AddCheck "credential-posture" "info" "No MCP environment or header credentials are configured."
    }

    $Summary = @{
        ok = @($Checks | Where-Object { $_.status -eq "ok" }).Count
        info = @($Checks | Where-Object { $_.status -eq "info" }).Count
        warnings = @($Checks | Where-Object { $_.status -eq "warning" }).Count
        errors = @($Checks | Where-Object { $_.status -eq "error" }).Count
    }
    return @{
        schema_version = 1
        success = ($Summary.errors -eq 0)
        generated_at = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        version = Get-EasySkillsVersion
        platform = "Windows"
        runtime = @{ powershell = $PSVersionTable.PSVersion.ToString() }
        paths = @{ central = Get-SupportSafePath $CentralDir; engine = Get-SupportSafePath $ScriptDir }
        summary = $Summary
        metrics = @{
            skills = $Skills.Count
            agents_detected = $DetectedAgents.Count
            agents_mapped = $MappedAgents.Count
            rules = $Rules.Count
            rule_targets_detected = $DetectedInstructionAgents.Count
            rule_targets_managed = $ManagedInstructionAgents.Count
            mcp_servers = $MCPServerProperties.Count
            mcp_servers_enabled = $EnabledMCPServers.Count
            credential_posture = $CredentialPosture
            dangling_links = $Dangling
            external_links = $External
        }
        checks = @($Checks)
    }
}

function Write-Utf8Atomic-Core([string]$Path, [string]$Content) {
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

function Write-Utf8Atomic([string]$Path, [string]$Content) {
    # All persistent WebUI state (MCP, Agent metadata, instruction library and
    # sync journal) goes through one atomic-write gate.  The named mutex keeps
    # deploy.ps1/watch.ps1 from observing a half-updated multi-file operation;
    # higher-level link mutations use the same gate explicitly.
    return Invoke-WithDeployLock { Write-Utf8Atomic-Core $Path $Content }
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

function Save-Instruction-Core([string]$Name, [string]$Content) {
    $Check = Test-InstructionName $Name
    if (-not $Check.ok) { return @{ success = $false; message = $Check.value } }
    $CleanName = $Check.value
    try {
        if (-not (Test-Path $InstructionsDir)) { New-Item -ItemType Directory -Path $InstructionsDir -Force | Out-Null }
        $Collision = Find-CaseInsensitiveChild $InstructionsDir $CleanName
        if ($Collision -and $Collision.Name -cne $CleanName) {
            return @{ success = $false; message = "Rule name conflicts case-insensitively with: $($Collision.Name)" }
        }
        Write-Utf8Atomic (Join-Path $InstructionsDir $CleanName) $Content
    } catch {
        return @{ success = $false; message = "Save failed: $_" }
    }
    return @{ success = $true; message = "Saved rule: $CleanName"; name = $CleanName }
}

function Save-Instruction([string]$Name, [string]$Content) {
    return Invoke-WithDeployLock { Save-Instruction-Core $Name $Content }
}

function Remove-Instruction-Core([string]$Name) {
    $Check = Test-InstructionName $Name
    if (-not $Check.ok) { return @{ success = $false; message = $Check.value } }
    $CleanName = $Check.value
    $Target = Join-Path $InstructionsDir $CleanName
    if (-not (Test-Path $Target)) { return @{ success = $false; message = "Rule not found: $CleanName" } }
    try { Remove-Item -LiteralPath $Target -Force } catch { return @{ success = $false; message = "Delete failed: $_" } }
    return @{ success = $true; message = "Deleted rule: $CleanName"; name = $CleanName }
}

function Remove-Instruction([string]$Name) {
    return Invoke-WithDeployLock { Remove-Instruction-Core $Name }
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
        
        $RuleEntries = @()
        foreach ($Name in @($Current.Rules.Keys | Sort-Object)) {
            $RuleEntries += [pscustomobject]@{ name = [string]$Name; content = [string]$Current.Rules[$Name] }
        }
        $NewEntry = [pscustomobject]@{
            path = $Resolved
            rules = $RuleEntries
            legacy = [string]$Current.Legacy
            body_sha256 = (Get-BodySha256 (Get-ManagedBody $Current.Rules $Current.Legacy))
        }
        
        $NewEntryJson = $NewEntry | ConvertTo-Json -Depth 8
        $StateEntryJson = ""
        if ($StateEntry) {
            $StateEntryJson = $StateEntry | ConvertTo-Json -Depth 8
        }
        
        if ($Existing -eq $NewContent -and $NewEntryJson -eq $StateEntryJson) {
            return @{ success = $true; message = "Wrote rules to $Resolved" }
        }

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
        return @{ success = $false; message = "Write failed for ${PathStr}: $_" }
    }
}

function Write-InstructionsToOne-Core([string]$PathStr) {
    $KnownPath = Resolve-KnownInstructionTarget $PathStr
    if (-not $KnownPath) { return @{ success = $false; message = "Unknown agent instruction target" } }
    $Library = Get-RuleMap
    if (-not $Library.success -or $Library.rules.Count -eq 0) { return @{ success = $false; message = "No rules in the library. Add rules first." } }
    return Write-RulesToOne $KnownPath $Library.rules $true
}

function Write-InstructionsToOne([string]$PathStr) {
    return Invoke-WithDeployLock { Write-InstructionsToOne-Core $PathStr }
}

function Remove-InstructionsFromOne-Core([string]$PathStr) {
    try {
        $KnownPath = Resolve-KnownInstructionTarget $PathStr
        if (-not $KnownPath) {
            # Bulk cleanup must also reach custom Agents that were removed from
            # the current configuration after EasySkills wrote them. The state
            # file is the trusted allow-list for those historical paths.
            $StateTarget = Get-InstructionStateEntry $PathStr
            if (-not $StateTarget -or -not ([string]$StateTarget.path)) {
                return @{ success = $false; message = "Unknown agent instruction target" }
            }
            $KnownPath = [string]$StateTarget.path
        }
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
        $TargetContent = if ($Remaining.Trim()) { ($Remaining.TrimEnd() + "`n") } else { "" }
        if (-not $TargetContent) {
            Remove-Item -LiteralPath $Resolved -Force
            Remove-InstructionState $Resolved
        } else {
            $StateEntry = Get-InstructionStateEntry $Resolved
            if ($Content -eq $TargetContent -and $null -eq $StateEntry) {
                return @{ success = $true; message = "Removed managed block from $Resolved" }
            }
            Write-Utf8Atomic $Resolved $TargetContent
            Remove-InstructionState $Resolved
        }
        return @{ success = $true; message = "Removed managed block from $Resolved" }
    } catch {
        return @{ success = $false; message = "Remove failed for ${PathStr}: $_" }
    }
}

function Remove-InstructionsFromOne([string]$PathStr) {
    return Invoke-WithDeployLock { Remove-InstructionsFromOne-Core $PathStr }
}

function Remove-RulesFromOne-Core([string]$PathStr, [string[]]$RuleNames) {
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
        return @{ success = $false; message = "Remove failed for ${PathStr}: $_" }
    }
}

function Remove-RulesFromOne([string]$PathStr, [string[]]$RuleNames) {
    return Invoke-WithDeployLock { Remove-RulesFromOne-Core $PathStr $RuleNames }
}

function Write-InstructionsToAll-Core {
    $Library = Get-RuleMap
    if (-not $Library.success) { return @{ success = $false; message = $Library.message } }
    
    $Targets = Get-DetectedInstructionTargets
    $AllTargets = @{}
    foreach ($T in $Targets) {
        $ResolvedPath = [System.IO.Path]::GetFullPath($T.Path)
        $AllTargets[$ResolvedPath] = @{ Name = $T.Name; Path = $T.Path }
    }
    
    $SyncState = Get-InstructionSyncState
    foreach ($Entry in @($SyncState.targets)) {
        if ($Entry -and $Entry.path) {
            $ResolvedPath = [System.IO.Path]::GetFullPath($Entry.path)
            if (-not $AllTargets.ContainsKey($ResolvedPath)) {
                $AllTargets[$ResolvedPath] = @{ Name = (Split-Path $ResolvedPath -Leaf); Path = $ResolvedPath }
            }
        }
    }
    
    $AllTargetsList = @($AllTargets.Values)
    if ($AllTargetsList.Count -eq 0) { return @{ success = $false; message = "No detected or previously synced agent instruction targets found." } }

    if ($Library.rules.Count -eq 0) {
        $Removed = @(); $Failed = @()
        foreach ($T in $AllTargetsList) {
            $Result = Remove-InstructionsFromOne $T.Path
            if ($Result.success) { $Removed += $T.Name } else { $Failed += "$($T.Name) ($($T.Path))" }
        }
        $Msg = "No rules in library. Cleared managed block from $($Removed.Count) agent(s)."
        if ($Failed.Count -gt 0) { $Msg += " Failed: $($Failed -join ', ')" }
        return @{ success = ($Failed.Count -eq 0); message = $Msg; written = 0; failed = $Failed }
    }

    if ($Targets.Count -eq 0) {
        $Removed = @()
        foreach ($T in $AllTargetsList) {
            Remove-InstructionsFromOne $T.Path
            $Removed += $T.Name
        }
        return @{ success = $false; message = "No detected active agent instruction targets found. Cleared legacy block from previously synced targets." }
    }

    $Written = @(); $Failed = @()
    foreach ($T in $Targets) {
        $Result = Write-RulesToOne $T.Path $Library.rules $true
        if ($Result.success) { $Written += $T.Name } else { $Failed += "$($T.Name) ($($T.Path))" }
    }

    $ActivePaths = @{}
    foreach ($T in $Targets) { $ActivePaths[[System.IO.Path]::GetFullPath($T.Path)] = $true }
    foreach ($Entry in @($SyncState.targets)) {
        if ($Entry -and $Entry.path) {
            $ResolvedPath = [System.IO.Path]::GetFullPath($Entry.path)
            if (-not $ActivePaths.ContainsKey($ResolvedPath)) {
                Remove-InstructionsFromOne $ResolvedPath
            }
        }
    }

    $Msg = "Wrote rules to $($Written.Count) agent(s)."
    if ($Failed.Count -gt 0) { $Msg += " Failed: $($Failed -join ', ')" }
    return @{ success = ($Failed.Count -eq 0); message = $Msg; written = $Written.Count; failed = $Failed }
}

function Write-InstructionsToAll {
    return Invoke-WithDeployLock { Write-InstructionsToAll-Core }
}

function Remove-InstructionsFromAll-Core {
    $Targets = Get-DetectedInstructionTargets
    $AllTargets = @{}
    foreach ($T in $Targets) {
        $ResolvedPath = [System.IO.Path]::GetFullPath($T.Path)
        $AllTargets[$ResolvedPath] = @{ Name = $T.Name; Path = $T.Path }
    }
    
    $SyncState = Get-InstructionSyncState
    foreach ($Entry in @($SyncState.targets)) {
        if ($Entry -and $Entry.path) {
            $ResolvedPath = [System.IO.Path]::GetFullPath($Entry.path)
            if (-not $AllTargets.ContainsKey($ResolvedPath)) {
                $AllTargets[$ResolvedPath] = @{ Name = (Split-Path $ResolvedPath -Leaf); Path = $ResolvedPath }
            }
        }
    }
    
    $AllTargetsList = @($AllTargets.Values)
    if ($AllTargetsList.Count -eq 0) { return @{ success = $false; message = "No agent instruction targets found to clear." } }
    
    $Removed = @(); $Failed = @()
    foreach ($T in $AllTargetsList) {
        $Result = Remove-InstructionsFromOne $T.Path
        if ($Result.success) { $Removed += $T.Name } else { $Failed += "$($T.Name) ($($T.Path))" }
    }
    $Msg = "Removed managed block from $($Removed.Count) agent(s)."
    if ($Failed.Count -gt 0) { $Msg += " Failed: $($Failed -join ', ')" }
    return @{ success = ($Failed.Count -eq 0); message = $Msg; removed = $Removed.Count; failed = $Failed }
}

function Remove-InstructionsFromAll {
    return Invoke-WithDeployLock { Remove-InstructionsFromAll-Core }
}

function Write-SelectedInstructions-Core {
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

function Write-SelectedInstructions {
    param([string[]]$Rules, [string[]]$Agents)
    return Invoke-WithDeployLock { Write-SelectedInstructions-Core -Rules $Rules -Agents $Agents }
}

function Remove-SelectedInstructions-Core {
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

function Remove-SelectedInstructions {
    param([string[]]$Rules, [string[]]$Agents)
    return Invoke-WithDeployLock { Remove-SelectedInstructions-Core -Rules $Rules -Agents $Agents }
}

function Run-SelfUpdate-Core {
    $GatewayResult = @{ attempted = $false; success = $true; message = "" }
    $UpdateWarning = ""
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
            $FinalDownloadUrl = Save-BoundedWebFile `
                -Uri $ZipUrl `
                -Path $ZipPath `
                -MaxBytes 104857600 `
                -LimitMessage "Release archive exceeds the 100 MB safety limit." `
                -Headers $Headers
            if (-not (Test-TrustedGitHubDownloadUrl $FinalDownloadUrl)) {
                throw "Update rejected: download redirected to an untrusted host ($FinalDownloadUrl)."
            }

            # --- Integrity check: re-download and compare SHA-256 ---
            $VerifyPath = Join-Path $TmpDir "release_verify.zip"
            $FinalVerifyUrl = Save-BoundedWebFile `
                -Uri $ZipUrl `
                -Path $VerifyPath `
                -MaxBytes 104857600 `
                -LimitMessage "Integrity archive exceeds the 100 MB safety limit." `
                -Headers $Headers
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
            # Validate the ZIP central directory and virtual link graph before
            # expansion. This covers traversal, duplicate paths, archive
            # bombs, and symlink escapes consistently with install.ps1.
            Assert-SafeZipArchive $ZipPath $ExtractDir
            Expand-Archive -Path $ZipPath -DestinationPath $ExtractDir -Force

            # Select by the required engine marker rather than filesystem
            # enumeration order. Multiple matching roots are ambiguous and are
            # rejected before any live installation files are touched.
            $SourceRoots = @(Get-ChildItem -LiteralPath $ExtractDir -Directory -Force -ErrorAction Stop | Where-Object {
                Test-Path (Join-Path $_.FullName "EasySkills维护工具/.engine") -PathType Container
            })
            if ($SourceRoots.Count -eq 0) {
                return @{ success = $false; message = "Archive does not contain EasySkills维护工具/.engine/" }
            }
            if ($SourceRoots.Count -ne 1) {
                $Names = (($SourceRoots | ForEach-Object { $_.Name }) -join ", ")
                return @{ success = $false; message = "Archive contains multiple EasySkills source roots: $Names" }
            }
            $SrcRoot = $SourceRoots[0]

            # Preserve user runtime files (not shipped in the release zip)
            $CustomBackup = $null
            if (Test-Path $CustomTargetsFile) {
                $CustomBackup = Get-Content $CustomTargetsFile -Raw -Encoding UTF8
            }
            $DisabledBackup = $null
            if (Test-Path $DisabledTargetsFile) {
                $DisabledBackup = Get-Content $DisabledTargetsFile -Raw -Encoding UTF8
            }

            # Backup current engine dir for rollback (atomic via temp rename)
            $DestMaint = Join-Path $CentralDir "EasySkills维护工具/.engine"
            $BackupMaint = Join-Path $CentralDir ".maintenance-bak"
            $BackupMaintNew = Join-Path $CentralDir ".maintenance-bak.new"

            $SrcMaint = Join-Path $SrcRoot.FullName "EasySkills维护工具/.engine"
            $ExpectedVersion = if ($LatestTag.StartsWith("v")) { $LatestTag.Substring(1) } else { $LatestTag }
            if ($ExpectedVersion -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?$') {
                return @{ success = $false; message = "Release tag has an invalid version: $LatestTag" }
            }
            $SourceVersionFile = Join-Path $SrcMaint ".version"
            if (-not (Test-Path $SourceVersionFile -PathType Leaf)) {
                return @{ success = $false; message = "Archive version file is missing." }
            }
            $SourceVersion = (Get-Content $SourceVersionFile -Raw).Trim()
            if ($SourceVersion -ne $ExpectedVersion) {
                return @{ success = $false; message = "Archive version '$SourceVersion' does not match release tag '$LatestTag'." }
            }

            # Recover an interrupted prior update before starting another one.
            # If .maintenance-bak is absent, .maintenance-bak.new may be the
            # user's only rollback snapshot and must not be discarded.
            if (Test-Path $BackupMaintNew) {
                if (Test-Path $BackupMaint) {
                    Remove-Item $BackupMaintNew -Recurse -Force
                } else {
                    try { Rename-Item -LiteralPath $BackupMaintNew -NewName ".maintenance-bak" -Force }
                    catch { return @{ success = $false; message = "Could not reconcile the preserved rollback snapshot: $_" } }
                }
            }

            # Build new engine in a temp dir, then rename atomically
            $NewMaintTmp = Join-Path $CentralDir "EasySkills维护工具/.engine.new"
            if (Test-Path $NewMaintTmp) { Remove-Item $NewMaintTmp -Recurse -Force }
            Copy-Item $SrcMaint $NewMaintTmp -Recurse -Force

            $SrcReadme = Join-Path $SrcRoot.FullName "EasySkills维护工具/README_SYSTEM.md"
            $SrcOld = Join-Path $SrcRoot.FullName "SKILL.md"
            $ReadmeSource = if (Test-Path $SrcReadme -PathType Leaf) { $SrcReadme } elseif (Test-Path $SrcOld -PathType Leaf) { $SrcOld } else { $null }

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

                # Move our own working directory OUT of the engine dir so the live
                # server process does not hold the directory we are about to rename.
                try { [System.IO.Directory]::SetCurrentDirectory($CentralDir) } catch {}

                if (Test-Path $DestMaint) {
                    if (Test-Path $BackupMaint) { Remove-Item $BackupMaint -Recurse -Force }
                    Move-Item -LiteralPath $DestMaint -Destination $BackupMaint -Force
                }

                Move-Item -LiteralPath $NewMaintTmp -Destination $DestMaint -Force

                if (Test-Path $BackupMaintNew) {
                    try { Remove-Item $BackupMaintNew -Recurse -Force -ErrorAction Stop }
                    catch { $UpdateWarning += " Old backup snapshot cleanup failed: $_." }
                }

                $GatewayResult = Install-MCPGatewayForEngine $DestMaint (Join-Path $SrcRoot.FullName "gateway")
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
                        Move-Item -LiteralPath $BackupMaint -Destination $DestMaint -Force
                    }
                    # Restore the pre-existing .bak snapshot (we overwrote it).
                    if ((Test-Path $BackupMaintNew) -and -not (Test-Path $BackupMaint)) {
                        Rename-Item -LiteralPath $BackupMaintNew -NewName ".maintenance-bak" -Force
                    }
                } catch {}
                throw
            }

            if ($ReadmeSource) {
                $ReadmeDest = Join-Path $CentralDir "EasySkills维护工具/README_SYSTEM.md"
                $ReadmeStaged = Join-Path (Split-Path -Parent $ReadmeDest) ".README_SYSTEM.md.new"
                try {
                    Copy-Item $ReadmeSource $ReadmeStaged -Force -ErrorAction Stop
                    if (Test-Path $ReadmeDest -PathType Leaf) {
                        [System.IO.File]::Replace($ReadmeStaged, $ReadmeDest, $null)
                    } else {
                        [System.IO.File]::Move($ReadmeStaged, $ReadmeDest)
                    }
                } catch {
                    $UpdateWarning += " Documentation refresh failed: $_."
                    Remove-Item $ReadmeStaged -Force -ErrorAction SilentlyContinue
                }
            }
        } finally {
            Remove-Item $TmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        $SyncResult = Run-DeployCommand @("-Sync")

        $NewVersion = Get-EasySkillsVersion
        $Message = "Updated to $NewVersion."
        if ($SyncResult.success) { $Message += " All agents re-synced." }
        else { $Message += " Update succeeded, but agent re-sync failed: $($SyncResult.message)" }
        if ($GatewayResult.attempted -and -not $GatewayResult.success) {
            $Message += " Gateway update failed; the previous binary was preserved. Run Doctor and retry the Gateway installation."
        }
        $Message += $UpdateWarning
        return @{ success = $true; message = $Message; version = $NewVersion; sync_success = [bool]$SyncResult.success; gateway_success = [bool]$GatewayResult.success }
    } catch {
        return @{ success = $false; message = "Update failed: $_" }
    }
}

function Run-SelfUpdate {
    return Invoke-WithDeployLock { Run-SelfUpdate-Core }
}

function Do-Rollback-Core {
    $BackupMaint = Join-Path $CentralDir ".maintenance-bak"
    $DestMaint = Join-Path $CentralDir "EasySkills维护工具/.engine"
    if (-not (Test-Path $BackupMaint)) {
        return @{ success = $false; message = "No backup found. Nothing to roll back." }
    }
    try {
        # Recover a current engine stranded in .engine.prev by an interrupted
        # prior rollback. Never delete that directory while the live path is
        # absent because it may be the only runnable copy.
        $Prev = Join-Path $CentralDir "EasySkills维护工具/.engine.prev"
        if (Test-Path $Prev) {
            if (Test-Path $DestMaint) {
                Remove-Item $Prev -Recurse -Force
            } else {
                try { Rename-Item -LiteralPath $Prev -NewName ".engine" -Force }
                catch { return @{ success = $false; message = "Rollback recovery snapshot is preserved at '$Prev', but could not be restored: $_" } }
            }
        }

        # Preserve the user's CURRENT runtime files across the rollback
        $CustomBackup = $null
        if (Test-Path $CustomTargetsFile) {
            $CustomBackup = Get-Content $CustomTargetsFile -Raw -Encoding UTF8
        }
        $DisabledBackup = $null
        if (Test-Path $DisabledTargetsFile) {
            $DisabledBackup = Get-Content $DisabledTargetsFile -Raw -Encoding UTF8
        }
        $RollbackTmp = Join-Path $CentralDir "EasySkills维护工具/.engine.rollback"
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

        # Move our own working directory OUT of the engine dir before renaming it
        try { [System.IO.Directory]::SetCurrentDirectory($CentralDir) } catch {}

        try {
            # Rotate: current -> .prev, rollback-tmp -> current (two renames).
            if (Test-Path $DestMaint) {
                Rename-Item -LiteralPath $DestMaint -NewName ".engine.prev" -Force
            }
            Rename-Item -LiteralPath $RollbackTmp -NewName ".engine" -Force
        } catch {
            # If the second rename failed after the first succeeded, the
            # current version is stranded in .prev — restore it.
            try {
                if (-not (Test-Path $DestMaint) -and (Test-Path $Prev)) {
                    Rename-Item -LiteralPath $Prev -NewName ".engine" -Force
                }
                if (Test-Path $RollbackTmp) { Remove-Item $RollbackTmp -Recurse -Force -ErrorAction SilentlyContinue }
            } catch {}
            throw
        }

        if (Test-Path $Prev) { Remove-Item $Prev -Recurse -Force -ErrorAction SilentlyContinue }

        $GatewayResult = Install-MCPGatewayForEngine $DestMaint

        $SyncResult = Run-DeployCommand @("-Sync")
        # Remove backup so a second rollback doesn't restore stale state
        try { Remove-Item $BackupMaint -Recurse -Force -ErrorAction SilentlyContinue } catch {}
        $Version = Get-EasySkillsVersion
        $Message = "Rolled back to $Version."
        if ($SyncResult.success) { $Message += " All agents re-synced." }
        else { $Message += " Rollback succeeded, but agent re-sync failed: $($SyncResult.message)" }
        if ($GatewayResult.attempted -and -not $GatewayResult.success) {
            $Message += " Gateway rollback failed; the existing binary was preserved. Run Doctor and retry the Gateway installation."
        }
        return @{ success = $true; message = $Message; version = $Version; sync_success = [bool]$SyncResult.success; gateway_success = [bool]$GatewayResult.success }
    } catch {
        return @{ success = $false; message = "Rollback failed: $_" }
    }
}

function Do-Rollback {
    return Invoke-WithDeployLock { Do-Rollback-Core }
}

function Do-Unmap-Core([string]$TargetPath) {
    $NormalizedInput = if ($TargetPath) { Normalize-AgentPath $TargetPath } else { "" }
    if (-not $NormalizedInput) {
        return @{ success = $false; message = "Target path cannot be empty" }
    }
    if (-not (Test-Path -LiteralPath $NormalizedInput)) {
        return @{ success = $false; message = "Path does not exist" }
    }
    $Validation = Resolve-MappingTarget $TargetPath
    if (-not $Validation.success) { return $Validation }
    $TargetPath = $Validation.path
    try {
        if (-not (Add-DisabledTarget $TargetPath)) {
            return @{ success = $false; message = "Could not persist the disabled-target state; no links were removed" }
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

function Do-Unmap([string]$TargetPath) {
    return Invoke-WithDeployLock { Do-Unmap-Core $TargetPath }
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

    $JsonStr = ConvertTo-EasySkillsJson $Data
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
    $Response.Headers.Add("X-Content-Type-Options", "nosniff")
    $Response.Headers.Add("X-Frame-Options", "DENY")
    $Response.Headers.Add("Referrer-Policy", "no-referrer")
    $Response.Headers.Add("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
    $Response.Headers.Add("Cross-Origin-Resource-Policy", "same-origin")
    if (Test-Path $FilePath) {
        $NonceBytes = New-Object byte[] 18
        $NonceRng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        try { $NonceRng.GetBytes($NonceBytes) } finally { $NonceRng.Dispose() }
        $Nonce = [Convert]::ToBase64String($NonceBytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        $EscapedToken = [System.Security.SecurityElement]::Escape([string]$WebUIToken)
        $Html = [System.IO.File]::ReadAllText($FilePath, [System.Text.Encoding]::UTF8)
        # Replace the nonce before the escaped token so a token containing the
        # placeholder can never acquire the active script nonce.
        $Html = $Html.Replace("__EASYSKILLS_NONCE__", $Nonce)
        $Html = $Html.Replace("__EASYSKILLS_TOKEN__", $EscapedToken)
        $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Html)
        $Response.StatusCode = 200
        $Response.ContentType = "text/html; charset=utf-8"
        $Response.Headers.Add("Content-Security-Policy", "default-src 'none'; script-src 'nonce-$Nonce'; script-src-attr 'none'; style-src 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; font-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
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
            $MCPData = Get-MCPConfigData
            $MCPServers = @()
            if ($MCPData.success -and $MCPData.config -and $MCPData.config.servers) {
                $MCPServers = @($MCPData.config.servers.PSObject.Properties)
            }
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
                mcp_servers_count = $MCPServers.Count
                mcp_servers_enabled = @($MCPServers | Where-Object { $null -eq $_.Value.enabled -or [bool]$_.Value.enabled }).Count
                mcp_gateway_installed = [bool]$MCPData.gateway.installed
                version = Get-EasySkillsVersion
                has_backup = (Test-Path (Join-Path $CentralDir ".maintenance-bak") -PathType Container)
                # Link health: dangling links will be auto-pruned on next sync;
                # external links are valid-but-fragile symlinks/junctions.
                dangling_count = $LinkWarnings.dangling_count
                external_link_count = $LinkWarnings.external_link_count
            }
            Send-JsonResponse $Context $Data
        } elseif ($UrlPath -eq "/api/doctor") {
            if (-not (Test-TokenValid $Request)) {
                Send-ForbiddenResponse $Context
                return
            }
            Send-JsonResponse $Context (Get-DoctorReport)
        } elseif ($UrlPath -eq "/api/skills") {
            if (-not (Test-TokenValid $Request)) {
                Send-ForbiddenResponse $Context
                return
            }
            # @(… ) re-collects the function's emitted objects into a real array
            # even for 0 / 1 element, so the serializer renders [] / [{…}] and
            # never null / a bare object (PowerShell return-unrolling guard).
            Send-JsonResponse $Context @(Get-SkillsData)
        } elseif ($UrlPath -eq "/api/agents") {
            if (-not (Test-TokenValid $Request)) {
                Send-ForbiddenResponse $Context
                return
            }
            Send-JsonResponse $Context @(Get-VisibleAgentsData)
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
        } elseif ($UrlPath -eq "/api/mcp") {
            if (-not (Test-TokenValid $Request)) {
                Send-ForbiddenResponse $Context
                return
            }
            Send-JsonResponse $Context (Get-MCPConfigData)
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
        # Match the Python backend's strict request framing: every POST must
        # carry an explicit Content-Length, and the stream must yield exactly
        # that many bytes. ReadToEnd() alone accepts a truncated body when the
        # peer closes early, which can turn a short/ambiguous request into a
        # valid mutation.
        $RawContentLength = $Request.Headers["Content-Length"]
        if ($null -eq $RawContentLength) {
            $Context.Response.KeepAlive = $false
            Send-JsonResponse $Context @{ success = $false; message = "Content-Length is required" } 411
            return
        }
        [long]$ContentLength = 0
        if (-not [long]::TryParse([string]$RawContentLength, [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$ContentLength) -or $ContentLength -lt 0) {
            $Context.Response.KeepAlive = $false
            Send-JsonResponse $Context @{ success = $false; message = "Invalid Content-Length" } 400
            return
        }
        if ($ContentLength -gt 10485760) {  # 10 MB limit
            $Context.Response.KeepAlive = $false
            Send-JsonResponse $Context @{ success = $false; message = "Request Entity Too Large" } 413
            return
        }
        if ($ContentLength -gt 0) {
            $Bytes = New-Object byte[] ([int]$ContentLength)
            $Offset = 0
            while ($Offset -lt $Bytes.Length) {
                # HttpListener is single-threaded here. Use a bounded async
                # read so a client that advertises a valid Content-Length but
                # drips bytes forever cannot stall every other local WebUI
                # request indefinitely.
                try {
                    $ReadTask = $Request.InputStream.ReadAsync($Bytes, $Offset, $Bytes.Length - $Offset)
                    if (-not $ReadTask.Wait(30000)) {
                        $Context.Response.KeepAlive = $false
                        Send-JsonResponse $Context @{ success = $false; message = "Request body read timed out" } 408
                        return
                    }
                    $Read = $ReadTask.Result
                } catch {
                    $Context.Response.KeepAlive = $false
                    Send-JsonResponse $Context @{ success = $false; message = "Request body could not be read" } 400
                    return
                }
                if ($Read -le 0) {
                    $Context.Response.KeepAlive = $false
                    Send-JsonResponse $Context @{ success = $false; message = "Request body ended before Content-Length" } 400
                    return
                }
                $Offset += $Read
            }
            $Encoding = if ($Request.ContentEncoding) { $Request.ContentEncoding } else { [System.Text.Encoding]::UTF8 }
            $Json = $Encoding.GetString($Bytes)
            if ($Json.Length -gt 0 -and $Json[0] -eq [char]0xFEFF) { $Json = $Json.Substring(1) }
            try {
                # Keep nested JSON objects as PSCustomObject on every supported
                # PowerShell version. Test-MCPConfig intentionally validates that
                # shape, and the PowerShell 7 Hashtable parsing mode turns
                # nested servers/env/headers/profiles objects into hashtables,
                # making valid MCP writes fail validation only on PowerShell 7+.
                $PsObj = $Json | ConvertFrom-Json
            } catch {
                Send-JsonResponse $Context @{ success = $false; message = "Invalid JSON request body" } 400
                return
            }
            if ($PsObj -isnot [PSCustomObject]) {
                Send-JsonResponse $Context @{ success = $false; message = "JSON request body must be an object" } 400
                return
            }
            # The HTTP dispatcher uses dictionary-style lookup for top-level
            # fields, while nested objects must remain PSCustomObject for the
            # MCP schema validator and Add-Member/PSObject.Properties APIs.
            $BodyData = @{}
            $PsObj.PSObject.Properties | ForEach-Object {
                $BodyData[$_.Name] = $_.Value
            }
        }
        if (-not ($BodyData -is [System.Collections.IDictionary])) {
            Send-JsonResponse $Context @{ success = $false; message = "JSON request body must be an object" } 400
            return
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
        } elseif ($UrlPath -eq "/api/mcp/save") {
            Send-JsonResponse $Context (Save-MCPConfig $BodyData["config"])
        } elseif ($UrlPath -eq "/api/mcp/server/add") {
            Send-JsonResponse $Context (Add-MCPServer $BodyData["name"] $BodyData["server"])
        } elseif ($UrlPath -eq "/api/mcp/server/update") {
            Send-JsonResponse $Context (Update-MCPServer $BodyData["name"] $BodyData["server"])
        } elseif ($UrlPath -eq "/api/mcp/server/delete") {
            Send-JsonResponse $Context (Remove-MCPServer $BodyData["name"])
        } elseif ($UrlPath -eq "/api/mcp/test") {
            Send-JsonResponse $Context (Test-MCPGateway $BodyData["profile"] $BodyData["server"])
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

if ($Doctor) {
    $Report = Get-DoctorReport
    ConvertTo-EasySkillsJson $Report
    if ($Report.success) { exit 0 } else { exit 1 }
}

if ($SyncRules) {
    $Res = Write-InstructionsToAll
    Write-Host "Rules Sync: $(if ($Res.success) { 'Success' } else { 'Failed' }) - $($Res.message)"
    if ($Res.success) { exit 0 } else { exit 1 }
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
                $NewWebUI = Join-Path $CentralDir "EasySkills维护工具/.engine\webui.ps1"
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
