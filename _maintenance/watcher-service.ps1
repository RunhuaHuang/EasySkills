# ==============================================================================
# Script: watcher-service.ps1 (Windows)
# Description: Background listener using System.IO.FileSystemWatcher.
# ==============================================================================

$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent
$CentralDir = Split-Path -Path $ScriptDir -Parent
$PromaDir = Join-Path -Path $Home -ChildPath ".proma"

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
