# ==============================================================================
# Script: unwatch.ps1 (Windows)
# Description: Removes the EasySkillsWatcher startup shortcut and stops background tasks.
# ==============================================================================

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "[*] Uninstalling Windows EasySkills Watcher..." -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan

# 1. Remove the startup shortcut
$StartupFolder = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
$ShortcutPath = "$StartupFolder\EasySkillsWatcher.lnk"

if (Test-Path $ShortcutPath) {
    Remove-Item $ShortcutPath -Force
    Write-Host "[OK] Removed startup shortcut." -ForegroundColor Green
} else {
    Write-Host "[--] No startup shortcut found." -ForegroundColor Gray
}

# 2. Terminate running background watcher processes via WMI
try {
    $WatcherProcesses = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' AND CommandLine LIKE '%watcher-service.ps1%'"
    if ($WatcherProcesses) {
        foreach ($Proc in $WatcherProcesses) {
            $Proc | Invoke-CimMethod -MethodName Terminate | Out-Null
            Write-Host "[OK] Terminated background watcher (PID: $($Proc.ProcessId))." -ForegroundColor Green
        }
    } else {
        Write-Host "[--] No active background watcher process found." -ForegroundColor Gray
    }
}
catch {
    Write-Warning "Failed to query or terminate processes: $_"
}

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "Uninstallation complete." -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
