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

function Stop-EasySkillsBackgroundProcesses {
    # Terminate any currently-running supervisor/server processes from a
    # previous install (legacy or upgrade). This is required because
    # Unregister-ScheduledTask does NOT kill running task instances; if we
    # don't reap them, an old supervisor process from the prior install
    # will keep running alongside the freshly-registered task.
    try {
        $Procs = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object {
                $_.CommandLine -and (
                    $_.CommandLine -like '*webui-service.ps1*' -or
                    $_.CommandLine -like '*watcher-service.ps1*' -or
                    $_.CommandLine -like '*webui.ps1*'
                ) -and $_.ProcessId -ne $PID
            }
        foreach ($P in $Procs) {
            try {
                $P | Invoke-CimMethod -MethodName Terminate -ErrorAction SilentlyContinue | Out-Null
            } catch {}
        }
    } catch {}
}

$LauncherVbs = Join-Path $ScriptDir "run-hidden.vbs"
$WscriptExe  = "$env:WINDIR\System32\wscript.exe"

function Register-EasySkillsTask {
    Param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][string]$ServicePath,
        [Parameter(Mandatory=$true)][string]$Description
    )

    # Launch the supervisor via wscript.exe + run-hidden.vbs instead of
    # powershell.exe directly. wscript.exe is a GUI-subsystem app — it never
    # creates a console window, so the spawned PowerShell child runs with a
    # hidden console for its entire lifetime, in any session, regardless of
    # LogonType. This is what truly eliminates the visible-window problem;
    # `-WindowStyle Hidden` alone is unreliable under PS 5.x in interactive
    # logon sessions.
    $Argument = "`"$LauncherVbs`" `"$ServicePath`""
    $Action = New-ScheduledTaskAction -Execute $WscriptExe -Argument $Argument -WorkingDirectory $ScriptDir

    $UserId = "$env:USERDOMAIN\$env:USERNAME"
    # Triggers: launch at logon, AND every 10 minutes as a self-healing backstop.
    # The action launches the supervisor (webui-service.ps1 / watcher-service.ps1),
    # which run an internal while($true) loop and exit only on crash. Because the
    # wscript launcher exits immediately (non-blocking), Task Scheduler cannot
    # reliably detect a crashed supervisor to fire RestartCount — so the periodic
    # trigger is what actually revives a dead service. The supervisor's own
    # session mutex (Local\EasySkills*Service_v2) prevents duplicate instances.
    $Triggers = @()
    $Triggers += New-ScheduledTaskTrigger -AtLogOn -User $UserId
    try {
        $Triggers += New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) `
            -RepetitionInterval (New-TimeSpan -Minutes 10) `
            -RepetitionDuration ([TimeSpan]::MaxValue)
    } catch {
        # Older PowerShell / older Task Scheduler: fall back to logon-only.
    }

    # ExecutionTimeLimit 0 == unlimited. RestartCount is kept as a best-effort
    # backstop (it rarely fires given the non-blocking launcher, hence the
    # periodic trigger above), but a conservative value avoids looking like
    # malware persistence to AV heuristics.
    $Settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit (New-TimeSpan -Seconds 0) `
        -MultipleInstances IgnoreNew

    if (Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $Name -Confirm:$false -ErrorAction SilentlyContinue
    }

    # Interactive logon. We previously tried S4U for "Session 0 hiding" but
    # that turned out not to be how S4U works (it only changes auth, not
    # session) AND most non-admin accounts lack SeBatchLogonRight so the
    # S4U attempt always failed with "Access Denied". Window hiding is now
    # handled at the action level via wscript.exe + run-hidden.vbs, so the
    # LogonType only needs to be the simplest one that works without admin.
    $Principal = New-ScheduledTaskPrincipal -UserId $UserId -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $Name `
        -Action $Action -Trigger $Triggers -Settings $Settings -Principal $Principal `
        -Description $Description -Force | Out-Null
}

if (-not (Test-ScheduledTaskModule)) {
    Write-Warning "ScheduledTasks PowerShell module unavailable; falling back to startup shortcuts."
    return
}

Remove-LegacyStartupShortcuts
Stop-EasySkillsBackgroundProcesses

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
