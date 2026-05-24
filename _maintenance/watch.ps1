# ==============================================================================
# Script: watch.ps1 (Windows)
# Description: Installs the background watcher to run on Windows Startup.
# ==============================================================================

$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent
$CentralDir = Split-Path -Path $ScriptDir -Parent

function Start-HiddenPowerShell([string]$ScriptPath, [string]$WorkingDirectory) {
    $Command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`""
    $Shell = New-Object -ComObject WScript.Shell
    $PreviousDirectory = [System.IO.Directory]::GetCurrentDirectory()
    try {
        [System.IO.Directory]::SetCurrentDirectory($WorkingDirectory)
        [void]$Shell.Run($Command, 0, $false)
    } finally {
        [System.IO.Directory]::SetCurrentDirectory($PreviousDirectory)
    }
}

# 1. Run the first-time manual deploy
& "$ScriptDir\deploy.ps1"

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "Installing Windows EasySkills Watcher..." -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan

# 2. Create a Windows Startup shortcut
$StartupFolder = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
$WatcherShortcutPath = "$StartupFolder\EasySkillsWatcher.lnk"
$WebUIShortcutPath = "$StartupFolder\EasySkillsWebUI.lnk"

# Remove legacy shortcut if it points to old VBS launcher
if (Test-Path $WatcherShortcutPath) {
    try {
        $OldShortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($WatcherShortcutPath)
        if ($OldShortcut.TargetPath -like "*watcher-launcher.vbs*") {
            Remove-Item $WatcherShortcutPath -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}

$ServiceScript = "$ScriptDir\watcher-service.ps1"
$WebUIScript = "$ScriptDir\webui.ps1"

try {
    $WshShell = New-Object -ComObject WScript.Shell
    $WatcherShortcut = $WshShell.CreateShortcut($WatcherShortcutPath)
    $WatcherShortcut.TargetPath = "powershell.exe"
    $WatcherShortcut.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ServiceScript`""
    $WatcherShortcut.WorkingDirectory = $ScriptDir
    $WatcherShortcut.WindowStyle = 7
    $WatcherShortcut.Description = "EasySkills Background Watcher Service"
    $WatcherShortcut.Save()

    $WebUIShortcut = $WshShell.CreateShortcut($WebUIShortcutPath)
    $WebUIShortcut.TargetPath = "powershell.exe"
    $WebUIShortcut.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$WebUIScript`""
    $WebUIShortcut.WorkingDirectory = $ScriptDir
    $WebUIShortcut.WindowStyle = 7
    $WebUIShortcut.Description = "EasySkills WebUI Background Service"
    $WebUIShortcut.Save()

    # 3. Start watcher detached from the installer console.
    Start-HiddenPowerShell $ServiceScript $ScriptDir

    Write-Host "=============================================" -ForegroundColor Cyan
    Write-Host "Windows EasySkills Watcher installed!" -ForegroundColor Green
    Write-Host "   Watching: $CentralDir" -ForegroundColor Green
    Write-Host "=============================================" -ForegroundColor Cyan
}
catch {
    Write-Error "Failed to install watcher: $_"
}
