# ==============================================================================
# Script: webui-service.ps1 (Windows)
# Description: Supervises the EasySkills WebUI backend and restarts it if needed.
# ==============================================================================

$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent
$WebUIScript = Join-Path $ScriptDir "webui.ps1"
$LogDir = Join-Path $ScriptDir "logs"
$LogFile = Join-Path $LogDir "webui-service.log"
$Port = 6633

if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

function Write-ServiceLog([string]$Message) {
    $Line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message"
    Add-Content -Path $LogFile -Value $Line -Encoding UTF8
}

function Test-WebUIPort {
    $Client = New-Object System.Net.Sockets.TcpClient
    try {
        $Async = $Client.BeginConnect("127.0.0.1", $Port, $null, $null)
        if (-not $Async.AsyncWaitHandle.WaitOne(500, $false)) {
            return $false
        }
        $Client.EndConnect($Async)
        return $true
    } catch {
        return $false
    } finally {
        try { $Client.Close() } catch {}
    }
}

Write-ServiceLog "EasySkills WebUI supervisor started."

while ($true) {
    try {
        if (Test-WebUIPort) {
            Start-Sleep -Seconds 10
            continue
        }

        Write-ServiceLog "WebUI port is not listening; starting backend."
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$WebUIScript" -NoBrowser
        Write-ServiceLog "WebUI backend exited; restarting shortly."
    } catch {
        Write-ServiceLog "Supervisor error: $($_.Exception.Message)"
    }

    Start-Sleep -Seconds 3
}
