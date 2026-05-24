# ==============================================================================
# Script: watch.ps1 (Windows)
# Description: Installs the background watcher to run on Windows Startup.
# ==============================================================================

$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent
$CentralDir = Split-Path -Path $ScriptDir -Parent

# 1. Run the first-time manual deploy
& "$ScriptDir\deploy.ps1"

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "Installing Windows EasySkills Watcher..." -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan

# 2. Create a Windows Startup shortcut
$StartupFolder = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
$ShortcutPath = "$StartupFolder\EasySkillsWatcher.lnk"

# Remove legacy shortcut if it points to old VBS launcher
if (Test-Path $ShortcutPath) {
    try {
        $OldShortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($ShortcutPath)
        if ($OldShortcut.TargetPath -like "*watcher-launcher.vbs*") {
            Remove-Item $ShortcutPath -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}

$ServiceScript = "$ScriptDir\watcher-service.ps1"

try {
    $WshShell = New-Object -ComObject WScript.Shell
    $Shortcut = $WshShell.CreateShortcut($ShortcutPath)
    $Shortcut.TargetPath = "powershell.exe"
    $Shortcut.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ServiceScript`""
    $Shortcut.WorkingDirectory = $ScriptDir
    $Shortcut.WindowStyle = 7
    $Shortcut.Description = "EasySkills Background Watcher Service"
    $Shortcut.Save()

    # 3. Start watcher without WMI to avoid Defender/ASR false positives.
    $WatcherCmd = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ServiceScript`""
    Start-Process powershell.exe -ArgumentList $WatcherCmd

    Write-Host "=============================================" -ForegroundColor Cyan
    Write-Host "Windows EasySkills Watcher installed!" -ForegroundColor Green
    Write-Host "   Watching: $CentralDir" -ForegroundColor Green
    Write-Host "=============================================" -ForegroundColor Cyan
}
catch {
    Write-Error "Failed to install watcher: $_"
}
