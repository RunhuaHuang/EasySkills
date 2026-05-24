# ==============================================================================
# Script: register-tasks.ps1 (Windows)
# Description: Registers two user-level Scheduled Tasks that supervise the
#              EasySkills background services. Task Scheduler runs them
#              detached from any console — surviving terminal close, with
#              auto-restart on failure and re-launch at user logon.
# Idempotent: safe to re-run; tasks are recreated each call.
# ==============================================================================

Param(
    [Parameter(Mandatory=$false)][switch]$NoStart
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent
$WatcherService = Join-Path $ScriptDir "watcher-service.ps1"
$WebUIService   = Join-Path $ScriptDir "webui-service.ps1"

$WatcherTaskName = "EasySkills Watcher"
$WebUITaskName   = "EasySkills WebUI"

function Test-ScheduledTaskModule {
    return [bool](Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue)
}

function Remove-LegacyStartupShortcuts {
    $StartupFolder = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
    foreach ($Name in @("EasySkillsWatcher.lnk", "EasySkillsWebUI.lnk")) {
        $Path = Join-Path $StartupFolder $Name
        if (Test-Path $Path) {
            try { Remove-Item $Path -Force -ErrorAction Stop } catch {}
        }
    }
}

function Register-EasySkillsTask {
    Param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][string]$ServicePath,
        [Parameter(Mandatory=$true)][string]$Description
    )

    $PowerShellPath = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source
    if (-not $PowerShellPath) { $PowerShellPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" }

    $Argument = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ServicePath`""
    $Action = New-ScheduledTaskAction -Execute $PowerShellPath -Argument $Argument -WorkingDirectory $ScriptDir

    $UserId = "$env:USERDOMAIN\$env:USERNAME"
    $Trigger = New-ScheduledTaskTrigger -AtLogOn -User $UserId

    # ExecutionTimeLimit 0 == unlimited. RestartCount/Interval = Task Scheduler
    # auto-relaunches if the action terminates abnormally. Keeping RestartCount
    # at a conservative value (3) — the service has its own internal supervisor
    # loop and this is just a backstop; very high values look like malware
    # persistence to AV heuristics.
    $Settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit (New-TimeSpan -Seconds 0) `
        -MultipleInstances IgnoreNew

    $Principal = New-ScheduledTaskPrincipal -UserId $UserId -LogonType Interactive -RunLevel Limited

    if (Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $Name -Confirm:$false -ErrorAction SilentlyContinue
    }

    Register-ScheduledTask -TaskName $Name `
        -Action $Action -Trigger $Trigger -Settings $Settings -Principal $Principal `
        -Description $Description -Force | Out-Null
}

if (-not (Test-ScheduledTaskModule)) {
    Write-Warning "ScheduledTasks PowerShell module unavailable; falling back to startup shortcuts."
    return
}

Remove-LegacyStartupShortcuts

$VersionTag = ""
$VersionFile = Join-Path $ScriptDir ".version"
if (Test-Path $VersionFile) {
    try { $VersionTag = " (v$((Get-Content $VersionFile -Raw).Trim()))" } catch {}
}

$WatcherDesc = "EasySkills$VersionTag — open-source skills manager. " +
               "Watches $((Split-Path $ScriptDir -Parent)) and re-syncs skill " +
               "junctions to AI agent directories on change. " +
               "Source: https://github.com/RunhuaHuang/EasySkills"

$WebUIDesc   = "EasySkills$VersionTag — open-source skills manager. " +
               "Local-only management UI at http://127.0.0.1:6633 (no external network access after install). " +
               "Source: https://github.com/RunhuaHuang/EasySkills"

Register-EasySkillsTask -Name $WatcherTaskName `
    -ServicePath $WatcherService `
    -Description $WatcherDesc

Register-EasySkillsTask -Name $WebUITaskName `
    -ServicePath $WebUIService `
    -Description $WebUIDesc

Write-Host "[OK] Scheduled tasks registered:" -ForegroundColor Green
Write-Host "      - $WatcherTaskName" -ForegroundColor Green
Write-Host "      - $WebUITaskName" -ForegroundColor Green

if (-not $NoStart) {
    # Stop any current instances so the fresh task action takes over cleanly.
    try { Stop-ScheduledTask -TaskName $WatcherTaskName -ErrorAction SilentlyContinue } catch {}
    try { Stop-ScheduledTask -TaskName $WebUITaskName   -ErrorAction SilentlyContinue } catch {}

    Start-Sleep -Milliseconds 500

    try {
        Start-ScheduledTask -TaskName $WatcherTaskName -ErrorAction Stop
        Write-Host "[OK] Started: $WatcherTaskName" -ForegroundColor Green
    } catch {
        Write-Warning "Could not start ${WatcherTaskName}: $_"
    }
    try {
        Start-ScheduledTask -TaskName $WebUITaskName -ErrorAction Stop
        Write-Host "[OK] Started: $WebUITaskName" -ForegroundColor Green
    } catch {
        Write-Warning "Could not start ${WebUITaskName}: $_"
    }
}
