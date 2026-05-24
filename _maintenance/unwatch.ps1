# ==============================================================================
# Script: unwatch.ps1 (Windows)
# Description: Removes the EasySkillsWatcher startup shortcut and stops background tasks.
# ==============================================================================

Param(
    [Parameter(Mandatory=$false)][switch]$KeepWebUI
)

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "[*] Uninstalling Windows EasySkills Watcher..." -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan

# 1. Remove startup shortcuts
$StartupFolder = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
$ShortcutPaths = @("$StartupFolder\EasySkillsWatcher.lnk")
if (-not $KeepWebUI) {
    $ShortcutPaths += "$StartupFolder\EasySkillsWebUI.lnk"
}

foreach ($ShortcutPath in $ShortcutPaths) {
    if (Test-Path $ShortcutPath) {
        Remove-Item $ShortcutPath -Force
        Write-Host "[OK] Removed startup shortcut: $([System.IO.Path]::GetFileName($ShortcutPath))" -ForegroundColor Green
    } else {
        Write-Host "[--] Startup shortcut not found: $([System.IO.Path]::GetFileName($ShortcutPath))" -ForegroundColor Gray
    }
}

# 2. Terminate running background processes via WMI
try {
    $Filter = if ($KeepWebUI) {
        "Name = 'powershell.exe' AND CommandLine LIKE '%watcher-service.ps1%'"
    } else {
        "Name = 'powershell.exe' AND (CommandLine LIKE '%watcher-service.ps1%' OR CommandLine LIKE '%webui-service.ps1%' OR CommandLine LIKE '%webui.ps1%')"
    }
    $Processes = Get-CimInstance Win32_Process -Filter $Filter
    if ($Processes) {
        foreach ($Proc in $Processes) {
            $Proc | Invoke-CimMethod -MethodName Terminate | Out-Null
            Write-Host "[OK] Terminated background process (PID: $($Proc.ProcessId))." -ForegroundColor Green
        }
    } else {
        Write-Host "[--] No active background process found." -ForegroundColor Gray
    }
}
catch {
    Write-Warning "Failed to query or terminate processes: $_"
}

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "Uninstallation complete." -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
