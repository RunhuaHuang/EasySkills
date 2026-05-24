# ==============================================================================
# Script: watcher-service.ps1 (Windows)
# Description: Background listener using System.IO.FileSystemWatcher.
# ==============================================================================

$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent
$CentralDir = Split-Path -Path $ScriptDir -Parent

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
        $Change = $Watcher.WaitForChanged([System.IO.WatcherChangeTypes]::All, 600000)

        if ($Change.TimedOut -eq $false) {
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
