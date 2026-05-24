# ==============================================================================
# Script: webui-service.ps1 (Windows)
# Description: Supervises the EasySkills WebUI backend (port 6633).
#              Designed to run under Task Scheduler (auto-restart + logon
#              trigger). Internally uses a global mutex so only one supervisor
#              ever runs, throttles restart storms, and reaps stale children.
# ==============================================================================

$ErrorActionPreference = 'Continue'
$ScriptDir   = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent
$WebUIScript = Join-Path $ScriptDir "webui.ps1"
$LogDir      = Join-Path $ScriptDir "logs"
$LogFile     = Join-Path $LogDir   "webui-service.log"
$Port        = 6633
$MutexName   = "Local\EasySkillsWebUIService_v2"

if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

function Write-ServiceLog([string]$Message) {
    try {
        $Line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [pid=$PID] $Message"
        Add-Content -Path $LogFile -Value $Line -Encoding UTF8 -ErrorAction SilentlyContinue
        $Info = Get-Item $LogFile -ErrorAction SilentlyContinue
        if ($Info -and $Info.Length -gt 1048576) {
            $Tail = Get-Content $LogFile -Tail 500 -ErrorAction SilentlyContinue
            if ($Tail) { $Tail | Set-Content -Path $LogFile -Encoding UTF8 }
        }
    } catch {}
}

# --- single-instance guard ----------------------------------------------------
$Mutex = New-Object System.Threading.Mutex($false, $MutexName)
$Acquired = $false
try {
    $Acquired = $Mutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
    $Acquired = $true
}
if (-not $Acquired) {
    Write-ServiceLog "Another supervisor instance is already running; exiting cleanly."
    exit 0
}

function Test-WebUIPort {
    $Client = New-Object System.Net.Sockets.TcpClient
    try {
        $Async = $Client.BeginConnect("127.0.0.1", $Port, $null, $null)
        if (-not $Async.AsyncWaitHandle.WaitOne(800, $false)) { return $false }
        $Client.EndConnect($Async)
        return $true
    } catch {
        return $false
    } finally {
        try { $Client.Close() } catch {}
    }
}

function Get-StaleWebUIProcesses {
    Param([int]$ExcludePid = -1)
    try {
        $Filter = "Name = 'powershell.exe' AND CommandLine LIKE '%webui.ps1%'"
        $Procs  = Get-CimInstance Win32_Process -Filter $Filter -ErrorAction SilentlyContinue
        if (-not $Procs) { return @() }
        return @($Procs | Where-Object { $_.ProcessId -ne $ExcludePid -and $_.ProcessId -ne $PID })
    } catch {
        return @()
    }
}

function Stop-StaleWebUIProcesses {
    Param([int]$ExcludePid = -1)
    foreach ($P in (Get-StaleWebUIProcesses -ExcludePid $ExcludePid)) {
        try {
            Stop-Process -Id $P.ProcessId -Force -ErrorAction SilentlyContinue
            Write-ServiceLog "Killed stale webui.ps1 (pid=$($P.ProcessId))."
        } catch {}
    }
}

function Start-WebUIBackend {
    $PowerShellPath = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source
    if (-not $PowerShellPath) { $PowerShellPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" }

    $ProcInfo = New-Object System.Diagnostics.ProcessStartInfo
    $ProcInfo.FileName        = $PowerShellPath
    $ProcInfo.Arguments       = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$WebUIScript`" -NoBrowser"
    $ProcInfo.WorkingDirectory = $ScriptDir
    $ProcInfo.UseShellExecute = $false
    $ProcInfo.CreateNoWindow  = $true
    return [System.Diagnostics.Process]::Start($ProcInfo)
}

Write-ServiceLog "Supervisor started. ScriptDir=$ScriptDir"

$RestartTimestamps = New-Object System.Collections.Queue
$CurrentProc       = $null
$LastHealthLog     = [DateTime]::MinValue

try {
    while ($true) {
        try {
            $PortAlive = Test-WebUIPort
            $ProcAlive = ($null -ne $CurrentProc) -and (-not $CurrentProc.HasExited)

            if ($PortAlive -and $ProcAlive) {
                if (((Get-Date) - $LastHealthLog).TotalMinutes -ge 15) {
                    Write-ServiceLog "Healthy: WebUI listening on $Port (child pid=$($CurrentProc.Id))."
                    $LastHealthLog = Get-Date
                }
                Start-Sleep -Seconds 5
                continue
            }

            if ($PortAlive -and -not $ProcAlive) {
                # Port responds but we don't own the process — adopt the orphan
                # by tracking it again via WMI. If it's ours from a previous
                # supervisor instance, leave it alone.
                $Existing = Get-StaleWebUIProcesses
                if ($Existing.Count -gt 0) {
                    Write-ServiceLog "Port up, adopting existing webui.ps1 (pid=$($Existing[0].ProcessId))."
                    try { $CurrentProc = [System.Diagnostics.Process]::GetProcessById($Existing[0].ProcessId) } catch {}
                }
                Start-Sleep -Seconds 5
                continue
            }

            # --- need to (re)start the backend ------------------------------
            $Now = Get-Date
            while ($RestartTimestamps.Count -gt 0 -and (($Now - $RestartTimestamps.Peek()).TotalSeconds -gt 300)) {
                [void]$RestartTimestamps.Dequeue()
            }
            if ($RestartTimestamps.Count -ge 12) {
                Write-ServiceLog "Restart storm (>=12 in 5min); cooling down 30s."
                Start-Sleep -Seconds 30
                continue
            }

            # Reap any stale webui.ps1 (could be holding the port half-broken)
            Stop-StaleWebUIProcesses

            Write-ServiceLog "Launching webui.ps1 ..."
            $CurrentProc = Start-WebUIBackend
            $RestartTimestamps.Enqueue((Get-Date))

            $StartedAt = Get-Date
            $PortReady = $false
            while (((Get-Date) - $StartedAt).TotalSeconds -lt 15) {
                if ($CurrentProc.HasExited) { break }
                if (Test-WebUIPort) { $PortReady = $true; break }
                Start-Sleep -Milliseconds 500
            }
            if ($PortReady) {
                Write-ServiceLog "WebUI up on port $Port (pid=$($CurrentProc.Id))."
                $LastHealthLog = Get-Date
            } elseif ($CurrentProc.HasExited) {
                Write-ServiceLog "webui.ps1 exited prematurely (code=$($CurrentProc.ExitCode))."
            } else {
                Write-ServiceLog "WebUI not listening within 15s; will retry."
            }
        } catch {
            Write-ServiceLog "Supervisor exception: $($_.Exception.Message)"
            Start-Sleep -Seconds 3
        }
    }
} finally {
    try { $Mutex.ReleaseMutex() } catch {}
    try { $Mutex.Dispose() } catch {}
    Write-ServiceLog "Supervisor exiting."
}
