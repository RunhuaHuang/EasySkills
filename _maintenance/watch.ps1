# ==============================================================================
# Script: watch.ps1 (Windows)
# Description: Installs EasySkills background services as Scheduled Tasks
#              (Task Scheduler is the only Windows-native way to keep them
#              alive past terminal close, system events, and crashes).
# ==============================================================================

$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent
$CentralDir = Split-Path -Path $ScriptDir -Parent

function Start-BackgroundPowerShell([string]$ScriptPath, [string]$WorkingDirectory) {
    # Standard Start-Process — avoids the WScript.Shell COM pattern AV
    # heuristics treat as a malware signature. Only used as Win7 fallback.
    $PSExe = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source
    if (-not $PSExe) { $PSExe = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" }
    Start-Process -FilePath $PSExe `
        -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", "`"$ScriptPath`"") `
        -WorkingDirectory $WorkingDirectory -WindowStyle Hidden | Out-Null
}

# 1. Run the first-time deploy synchronously.
& "$ScriptDir\deploy.ps1"

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "Installing Windows EasySkills services..." -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan

$RegisterScript = Join-Path $ScriptDir "register-tasks.ps1"

if ((Test-Path $RegisterScript) -and (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue)) {
    try {
        & $RegisterScript
        Write-Host "=============================================" -ForegroundColor Cyan
        Write-Host "EasySkills services registered with Task Scheduler." -ForegroundColor Green
        Write-Host "   They will auto-start at logon and auto-restart on failure." -ForegroundColor Green
        Write-Host "   Central dir: $CentralDir" -ForegroundColor Green
        Write-Host "=============================================" -ForegroundColor Cyan
        return
    } catch {
        Write-Warning "Task Scheduler registration failed, falling back to startup shortcuts: $_"
    }
}

# Fallback for environments where Task Scheduler is locked down.
$StartupFolder = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
$WatcherShortcutPath = "$StartupFolder\EasySkillsWatcher.lnk"
$WebUIShortcutPath   = "$StartupFolder\EasySkillsWebUI.lnk"

$ServiceScript     = "$ScriptDir\watcher-service.ps1"
$WebUIServiceScript = "$ScriptDir\webui-service.ps1"

try {
    $WshShell = New-Object -ComObject WScript.Shell
    foreach ($Pair in @(
        @{ Path = $WatcherShortcutPath; Target = $ServiceScript;     Desc = "EasySkills Background Watcher Service" },
        @{ Path = $WebUIShortcutPath;   Target = $WebUIServiceScript; Desc = "EasySkills WebUI Background Service" }
    )) {
        $Sc = $WshShell.CreateShortcut($Pair.Path)
        $Sc.TargetPath = "powershell.exe"
        $Sc.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$($Pair.Target)`""
        $Sc.WorkingDirectory = $ScriptDir
        $Sc.WindowStyle = 7
        $Sc.Description = $Pair.Desc
        $Sc.Save()
    }

    Start-BackgroundPowerShell $ServiceScript $ScriptDir
    Start-BackgroundPowerShell $WebUIServiceScript $ScriptDir

    Write-Host "=============================================" -ForegroundColor Cyan
    Write-Host "EasySkills services installed (fallback mode)." -ForegroundColor Green
    Write-Host "   Watching: $CentralDir" -ForegroundColor Green
    Write-Host "=============================================" -ForegroundColor Cyan
}
catch {
    Write-Error "Failed to install services: $_"
}
