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
$VersionFile = Join-Path $ScriptDir ".version"
$Version = if (Test-Path $VersionFile -PathType Leaf) { (Get-Content $VersionFile -Raw).Trim() } else { "" }
if ($Version -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?$') {
    throw "Invalid or missing EasySkills version in $VersionFile."
}

function Install-Candidate([string]$Candidate) {
    $VersionOutput = (& $Candidate version 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw "Gateway self-check failed." }
    if ($VersionOutput -notmatch '^easyskills-mcp\s+([^\s]+)\s+\(' -or $Matches[1] -ne $Version) {
        throw "Gateway version mismatch: expected $Version, got '$VersionOutput'."
    }
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

function Expand-GatewayCandidate([string]$ArchivePath, [string]$CandidatePath) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $ZipArchive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $FileEntries = @($ZipArchive.Entries | Where-Object { -not $_.FullName.EndsWith('/') })
        if ($FileEntries.Count -ne 1 -or $FileEntries[0].FullName -ne "easyskills-mcp.exe") {
            throw "Gateway archive must contain exactly easyskills-mcp.exe."
        }
        if ([long]$FileEntries[0].Length -gt 52428800) {
            throw "Gateway binary exceeds the 50 MB safety limit."
        }
        $InputStream = $FileEntries[0].Open()
        $OutputStream = [System.IO.File]::Open(
            $CandidatePath,
            [System.IO.FileMode]::Create,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
        try {
            $InputStream.CopyTo($OutputStream)
            $OutputStream.Flush($true)
        } finally {
            $OutputStream.Dispose()
            $InputStream.Dispose()
        }
    } finally {
        $ZipArchive.Dispose()
    }
}

function Save-BoundedWebFile(
    [string]$Uri,
    [string]$Path,
    [long]$MaxBytes,
    [string]$LimitMessage,
    [int]$TimeoutSeconds = 30,
    [string[]]$AllowedFinalHosts = @()
) {
    Add-Type -AssemblyName System.Net.Http
    $Handler = [System.Net.Http.HttpClientHandler]::new()
    $Handler.AllowAutoRedirect = $true
    $Handler.MaxAutomaticRedirections = 5
    $Client = [System.Net.Http.HttpClient]::new($Handler)
    $Client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
    $Request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, [System.Uri]$Uri)
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

try {
    New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
    $Arch = switch ($env:PROCESSOR_ARCHITECTURE.ToUpperInvariant()) {
        "AMD64" { "amd64" }
        "ARM64" { "arm64" }
        default { throw "Unsupported CPU architecture: $env:PROCESSOR_ARCHITECTURE" }
    }
    $Asset = "easyskills-mcp-windows-$Arch.zip"
    $ReleasePath = "/$Repo/releases/download/v$Version"
    $Archive = Join-Path $TempDir $Asset
    $Checksums = Join-Path $TempDir "checksums.txt"
    # GitHub native by default, or one explicitly selected HTTPS mirror.
    $MirrorPrefixes = @("")
    if ($env:EASYSKILLS_MIRROR) {
        try { $MirrorUri = [System.Uri]$env:EASYSKILLS_MIRROR } catch { throw "EASYSKILLS_MIRROR must be an explicit HTTPS URL prefix." }
        if (-not $MirrorUri.IsAbsoluteUri -or $MirrorUri.Scheme -ne "https") {
            throw "EASYSKILLS_MIRROR must be an explicit HTTPS URL prefix."
        }
        $MirrorPrefixes = @($env:EASYSKILLS_MIRROR.TrimEnd('/'))
    }
    $Downloaded = $false

    # Download asset + checksums from the selected source. Both must succeed
    # and the checksum must verify before the binary is accepted.
    foreach ($Prefix in $MirrorPrefixes) {
        # Empty prefix = GitHub native; mirror proxies prepend themselves to the
        # full github.com URL. Without this the empty prefix yields a host-less URL.
        if ($Prefix) {
            $BaseUrl = "${Prefix}/https://github.com${ReleasePath}"
        } else {
            $BaseUrl = "https://github.com${ReleasePath}"
        }
        try {
            $AllowedFinalHosts = if ($Prefix) { @() } else { @("github.com", "api.github.com", "codeload.github.com", "objects.githubusercontent.com") }
            Save-BoundedWebFile -Uri "$BaseUrl/$Asset" -Path $Archive -MaxBytes 52428800 -LimitMessage "Gateway archive exceeds the 50 MB safety limit." -AllowedFinalHosts $AllowedFinalHosts | Out-Null
            Save-BoundedWebFile -Uri "$BaseUrl/checksums.txt" -Path $Checksums -MaxBytes 1048576 -LimitMessage "Gateway checksum file exceeds the 1 MB safety limit." -AllowedFinalHosts $AllowedFinalHosts | Out-Null
            $ExpectedLine = Get-Content $Checksums | Where-Object { $_ -match "\s\*?$([regex]::Escape($Asset))$" } | Select-Object -First 1
            if (-not $ExpectedLine) { continue }
            $Expected = ($ExpectedLine -split "\s+")[0].ToLowerInvariant()
            if ($Expected -notmatch '^[0-9a-f]{64}$') { continue }
            $Actual = (Get-FileHash $Archive -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($Expected -ne $Actual) { continue }
            $Candidate = Join-Path $TempDir "easyskills-mcp.downloaded.exe"
            Expand-GatewayCandidate $Archive $Candidate
            Install-Candidate $Candidate
            $Downloaded = $true
            break
        } catch {
            # The selected source failed; local-source build fallback may still work.
        }
    }

    # Final fallback: build from source if a local source tree + Go toolchain exist.
    if (-not $Downloaded) {
        if ($SourceDir -and (Test-Path $SourceDir) -and (Get-Command go.exe -ErrorAction SilentlyContinue)) {
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
