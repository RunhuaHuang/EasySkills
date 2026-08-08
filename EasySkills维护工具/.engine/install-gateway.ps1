Param(
    [Parameter(Mandatory=$false)][string]$SourceDir = ""
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent
# The engine lives at EasySkills维护工具/.engine (two levels under the install
# root), so CentralDir must go up TWO parents (.engine -> EasySkills维护工具 ->
# root) to reach the directory that holds .runtime/. install-gateway.sh computes
# the same thing as "$SCRIPT_DIR/../..". A single Split-Path would put the
# gateway binary in EasySkills维护工具\.runtime\, but webui.ps1 (after its own
# re-resolution) looks for it at <root>\.runtime\ — a mismatch that would make
# the Gateway silently unavailable on Windows.
$CentralDir = Split-Path -Path (Split-Path -Path $ScriptDir -Parent) -Parent
$RuntimeDir = Join-Path $CentralDir ".runtime"
$Destination = Join-Path $RuntimeDir "easyskills-mcp.exe"
$Repo = "RunhuaHuang/EasySkills"
$TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("easyskills-mcp-" + [Guid]::NewGuid().ToString("N"))

function Install-Candidate([string]$Candidate) {
    & $Candidate version *> $null
    if ($LASTEXITCODE -ne 0) { throw "Gateway self-check failed." }
    New-Item -ItemType Directory -Path $RuntimeDir -Force | Out-Null
    $Staged = Join-Path $RuntimeDir ".easyskills-mcp.new.exe"
    Copy-Item $Candidate $Staged -Force
    $Previous = Join-Path $RuntimeDir ".easyskills-mcp.previous.exe"
    if (Test-Path $Previous) { Remove-Item $Previous -Force }
    if (Test-Path $Destination) { Move-Item $Destination $Previous -Force }
    try {
        Move-Item $Staged $Destination -Force
        if (Test-Path $Previous) { Remove-Item $Previous -Force }
    } catch {
        if ((-not (Test-Path $Destination)) -and (Test-Path $Previous)) { Move-Item $Previous $Destination -Force }
        throw
    }
}

try {
    New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
    $Arch = switch ($env:PROCESSOR_ARCHITECTURE.ToUpperInvariant()) {
        "AMD64" { "amd64" }
        "ARM64" { "arm64" }
        default { throw "Unsupported CPU architecture: $env:PROCESSOR_ARCHITECTURE" }
    }
    $Asset = "easyskills-mcp-windows-$Arch.zip"
    $ReleasePath = "/$Repo/releases/latest/download"
    $Archive = Join-Path $TempDir $Asset
    $Checksums = Join-Path $TempDir "checksums.txt"
    # GitHub native first; then china-friendly mirror proxies (same fallback list
    # as install.ps1). $env:EASYSKILLS_MIRROR pins a single mirror if set.
    $MirrorPrefixes = @("", "https://ghfast.top", "https://gh-proxy.com", "https://github.moeyy.xyz")
    if ($env:EASYSKILLS_MIRROR) { $MirrorPrefixes = @($env:EASYSKILLS_MIRROR) }
    $Downloaded = $false

    # Walk mirrors: download asset + checksums from the same source. Both must
    # succeed and the checksum must verify before we accept a mirror.
    foreach ($Prefix in $MirrorPrefixes) {
        $BaseUrl = "${Prefix}${ReleasePath}"
        try {
            Invoke-WebRequest -Uri "$BaseUrl/$Asset" -OutFile $Archive -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
            Invoke-WebRequest -Uri "$BaseUrl/checksums.txt" -OutFile $Checksums -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
            $ExpectedLine = Get-Content $Checksums | Where-Object { $_ -match "\s\*?$([regex]::Escape($Asset))$" } | Select-Object -First 1
            if (-not $ExpectedLine) { continue }
            $Expected = ($ExpectedLine -split "\s+")[0].ToLowerInvariant()
            $Actual = (Get-FileHash $Archive -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($Expected -ne $Actual) { continue }
            $Extracted = Join-Path $TempDir "extracted"
            Expand-Archive -Path $Archive -DestinationPath $Extracted -Force -ErrorAction Stop
            Install-Candidate (Join-Path $Extracted "easyskills-mcp.exe")
            $Downloaded = $true
            break
        } catch {
            # This mirror failed; try the next one.
        }
    }

    # Final fallback: build from source if a local source tree + Go toolchain exist.
    if (-not $Downloaded) {
        if ($SourceDir -and (Test-Path $SourceDir) -and (Get-Command go.exe -ErrorAction SilentlyContinue)) {
            $Version = if (Test-Path (Join-Path $ScriptDir ".version")) { (Get-Content (Join-Path $ScriptDir ".version") -Raw).Trim() } else { "dev" }
            $Built = Join-Path $TempDir "easyskills-mcp.exe"
            Push-Location $SourceDir
            try {
                $env:CGO_ENABLED = "0"
                & go build -trimpath -ldflags "-s -w -X main.version=$Version -X main.commit=source" -o $Built ./cmd/easyskills-mcp
                if ($LASTEXITCODE -ne 0) { throw "Go build failed." }
            } finally { Pop-Location }
            Install-Candidate $Built
            $Downloaded = $true
        }
    }
    if ($Downloaded) {
        Write-Host "MCP Gateway installed: $Destination" -ForegroundColor Green
        exit 0
    }
} catch {
    Write-Warning "MCP Gateway was not installed; Skills and Rules remain available. $($_.Exception.Message)"
    exit 1
} finally {
    Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue
}
