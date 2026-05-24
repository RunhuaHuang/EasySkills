# ==============================================================================
# Script: watcher-service.ps1 (Windows)
# Description: Background listener using System.IO.FileSystemWatcher.
#              Single-instance via global mutex. Designed to run under Task
#              Scheduler with restart-on-failure.
# ==============================================================================

$ErrorActionPreference = 'Continue'
$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent
$CentralDir = Split-Path -Path $ScriptDir -Parent
$PromaDir = Join-Path -Path $Home -ChildPath ".proma"
$MutexName = "Local\EasySkillsWatcherService_v2"

# --- single-instance guard ---------------------------------------------------
$Mutex = New-Object System.Threading.Mutex($false, $MutexName)
$Acquired = $false
try {
    $Acquired = $Mutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
    $Acquired = $true
}
if (-not $Acquired) {
    Write-Warning "Another watcher-service instance is already running; exiting."
    exit 0
}

# Initial synchronization
try {
    & "$ScriptDir\deploy.ps1"
} catch {
    Write-Warning "Initial sync failed: $($_.Exception.Message)"
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
                    Write-Warning "Sync failed: $($_.Exception.Message)"
                }
            }
        } catch {
            Write-Warning "Watcher error: $($_.Exception.Message). Restarting in 5s..."
            Start-Sleep -Seconds 5
        }
    }
} finally {
    try { $Mutex.ReleaseMutex() } catch {}
    try { $Mutex.Dispose() } catch {}
}
