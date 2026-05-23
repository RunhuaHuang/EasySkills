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

# 2. Create a Windows Startup shortcut (.lnk) pointing to the VBS launcher
$StartupFolder = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
$ShortcutPath = "$StartupFolder\EasySkillsWatcher.lnk"

try {
    $WshShell = New-Object -ComObject WScript.Shell
    $Shortcut = $WshShell.CreateShortcut($ShortcutPath)
    $Shortcut.TargetPath = "$ScriptDir\watcher-launcher.vbs"
    $Shortcut.WorkingDirectory = $ScriptDir
    $Shortcut.Description = "EasySkills Background Watcher Service"
    $Shortcut.Save()

    # 3. Start the watcher immediately for the current session
    $LauncherPath = "$ScriptDir\watcher-launcher.vbs"
    if (Test-Path $LauncherPath) {
        Start-Process "wscript.exe" -ArgumentList "`"$LauncherPath`"" -WindowStyle Hidden
    }

    Write-Host "=============================================" -ForegroundColor Cyan
    Write-Host "Windows EasySkills Watcher installed successfully!" -ForegroundColor Green
    Write-Host "   Watching: $CentralDir" -ForegroundColor Green
    Write-Host "=============================================" -ForegroundColor Cyan

    # 4. Windows Defender guidance
    Write-Host ""
    Write-Host "NOTE: If Windows Defender shows a warning, you can safely allow it." -ForegroundColor Yellow
    Write-Host "To add an exclusion, run PowerShell as Administrator:" -ForegroundColor Yellow
    Write-Host "  Add-MpPreference -ExclusionPath `"$CentralDir`"" -ForegroundColor Gray
    Write-Host "Or: Windows Security > Virus & threat protection > Exclusions > Add folder" -ForegroundColor Gray
    Write-Host ""
}
catch {
    Write-Error "Failed to install watcher: $_"
}
