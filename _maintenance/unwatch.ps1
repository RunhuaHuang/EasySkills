# ==============================================================================
# Script: unwatch.ps1 (Windows)
# Description: Removes EasySkills Scheduled Tasks (or legacy startup shortcuts)
#              and terminates running background processes.
# ==============================================================================

Param(
    [Parameter(Mandatory=$false)][switch]$KeepWebUI
)

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "[*] Uninstalling Windows EasySkills services..." -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan

# 1. Unregister Scheduled Tasks (new mechanism)
$TaskNames = @("EasySkills Watcher")
if (-not $KeepWebUI) { $TaskNames += "EasySkills WebUI" }

if (Get-Command Unregister-ScheduledTask -ErrorAction SilentlyContinue) {
    foreach ($Name in $TaskNames) {
        $T = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
        if ($T) {
            try { Stop-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue } catch {}
            try {
                Unregister-ScheduledTask -TaskName $Name -Confirm:$false -ErrorAction Stop
                Write-Host "[OK] Removed scheduled task: $Name" -ForegroundColor Green
            } catch {
                Write-Warning "Could not remove scheduled task ${Name}: $_"
            }
        }
    }
}

# 2. Remove any legacy startup shortcuts
$StartupFolder = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
$ShortcutPaths = @("$StartupFolder\EasySkillsWatcher.lnk")
if (-not $KeepWebUI) {
    $ShortcutPaths += "$StartupFolder\EasySkillsWebUI.lnk"
}
foreach ($ShortcutPath in $ShortcutPaths) {
    if (Test-Path $ShortcutPath) {
        Remove-Item $ShortcutPath -Force
        Write-Host "[OK] Removed startup shortcut: $([System.IO.Path]::GetFileName($ShortcutPath))" -ForegroundColor Green
    }
}

# 3. Terminate any currently-running background processes
try {
    $Filter = if ($KeepWebUI) {
        "Name = 'powershell.exe' AND CommandLine LIKE '%watcher-service.ps1%'"
    } else {
        "Name = 'powershell.exe' AND (CommandLine LIKE '%watcher-service.ps1%' OR CommandLine LIKE '%webui-service.ps1%' OR CommandLine LIKE '%webui.ps1%')"
    }
    $Processes = Get-CimInstance Win32_Process -Filter $Filter -ErrorAction SilentlyContinue
    $KilledPids = @()
    if ($Processes) {
        foreach ($Proc in $Processes) {
            try {
                $Proc | Invoke-CimMethod -MethodName Terminate | Out-Null
                $KilledPids += $Proc.ProcessId
                Write-Host "[OK] Terminated process (PID: $($Proc.ProcessId))." -ForegroundColor Green
            } catch {}
        }
    } else {
        Write-Host "[--] No active background process found." -ForegroundColor Gray
    }

    # Wait for terminated processes to fully exit so their file handles are
    # released. The caller (uninstaller .bat) immediately tries to `rd /S /Q`
    # the install directory; without this wait, locked files can survive.
    if ($KilledPids.Count -gt 0) {
        $Deadline = (Get-Date).AddSeconds(5)
        while ((Get-Date) -lt $Deadline) {
            $StillAlive = $KilledPids | Where-Object {
                try { Get-Process -Id $_ -ErrorAction Stop | Out-Null; $true } catch { $false }
            }
            if (-not $StillAlive) { break }
            Start-Sleep -Milliseconds 200
        }
    }
}
catch {
    Write-Warning "Failed to query or terminate processes: $_"
}

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "Uninstallation complete." -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
