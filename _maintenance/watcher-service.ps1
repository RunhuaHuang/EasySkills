# ==============================================================================
# Script: watcher-service.ps1 (Windows)
# Description: Background listener using System.IO.FileSystemWatcher.
#              Single-instance via session-local named mutex. Designed to
#              run under Task Scheduler with restart-on-failure.
# ==============================================================================

$ErrorActionPreference = 'Continue'
$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent
$CentralDir = Split-Path -Path $ScriptDir -Parent
$PromaDir = Join-Path -Path $Home -ChildPath ".proma"
$MutexName = "Local\EasySkillsWatcherService_v2"

$LogDir  = Join-Path $ScriptDir "logs"
$LogFile = Join-Path $LogDir "watcher-service.log"
if (-not (Test-Path $LogDir)) {
    try { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null } catch {}
}
function Write-WatcherLog([string]$Message) {
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

# --- single-instance guard ---------------------------------------------------
$Mutex = New-Object System.Threading.Mutex($false, $MutexName)
$Acquired = $false
try {
    $Acquired = $Mutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
    $Acquired = $true
}
if (-not $Acquired) {
    Write-WatcherLog "Another watcher-service instance is already running; exiting."
    exit 0
}

Write-WatcherLog "Watcher started. CentralDir=$CentralDir"

# Initial synchronization
try {
    & "$ScriptDir\deploy.ps1"
} catch {
    Write-WatcherLog "Initial sync failed: $($_.Exception.Message)"
}

# Initialize FileSystemWatcher
$Watcher = New-Object System.IO.FileSystemWatcher
$Watcher.Path = $CentralDir
$Watcher.IncludeSubdirectories = $false
$Watcher.EnableRaisingEvents = $true

Write-Host "[*] Starting background watcher on $CentralDir..."

try {
    # Block and wait for changes forever
    while ($true) {
        try {
            $PromaPollingEnabled = Test-Path $PromaDir
            $WaitTimeout = if ($PromaPollingEnabled) { 300000 } else { 600000 }
            $Change = $Watcher.WaitForChanged([System.IO.WatcherChangeTypes]::All, $WaitTimeout)

            if (($Change.TimedOut -eq $false) -or ($PromaPollingEnabled -and $Change.TimedOut)) {
                Start-Sleep -Milliseconds 500
                try {
                    & "$ScriptDir\deploy.ps1"
                } catch {
                    Write-WatcherLog "Sync failed: $($_.Exception.Message)"
                }
            }
        } catch {
            Write-WatcherLog "Watcher error: $($_.Exception.Message). Restarting in 5s..."
            Start-Sleep -Seconds 5
        }
    }
} finally {
    try { $Mutex.ReleaseMutex() } catch {}
    try { $Mutex.Dispose() } catch {}
    Write-WatcherLog "Watcher exiting."
}
