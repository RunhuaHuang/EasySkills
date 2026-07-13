Param(
    [Parameter(Mandatory=$false)][string]$SourceDir = ""
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent
$CentralDir = Split-Path -Path $ScriptDir -Parent
$RuntimeDir = Join-Path $CentralDir "_runtime"
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
    $BaseUrl = "https://github.com/$Repo/releases/latest/download"
    $Archive = Join-Path $TempDir $Asset
    $Checksums = Join-Path $TempDir "checksums.txt"
    $Downloaded = $false
    try {
        Invoke-WebRequest -Uri "$BaseUrl/$Asset" -OutFile $Archive -UseBasicParsing -TimeoutSec 60
        Invoke-WebRequest -Uri "$BaseUrl/checksums.txt" -OutFile $Checksums -UseBasicParsing -TimeoutSec 60
        $ExpectedLine = Get-Content $Checksums | Where-Object { $_ -match "\s\*?$([regex]::Escape($Asset))$" } | Select-Object -First 1
        if (-not $ExpectedLine) { throw "Checksum entry missing." }
        $Expected = ($ExpectedLine -split "\s+")[0].ToLowerInvariant()
        $Actual = (Get-FileHash $Archive -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($Expected -ne $Actual) { throw "Checksum mismatch." }
        $Extracted = Join-Path $TempDir "extracted"
        Expand-Archive -Path $Archive -DestinationPath $Extracted -Force
        Install-Candidate (Join-Path $Extracted "easyskills-mcp.exe")
        $Downloaded = $true
    } catch {
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
        } else {
            throw
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
