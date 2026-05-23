# ==============================================================================
# Script: unwatch.ps1 (Windows)
# Description: Safely removes the EasySkillsWatcher startup shortcut and stops background tasks.
# 脚本：unwatch.ps1 (Windows)
# 描述：安全注销 Windows 开机自启项，并优雅关闭后台正在运行的监听服务。
# ==============================================================================

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "⚙️  Uninstalling Windows EasySkills Watcher..." -ForegroundColor Cyan
Write-Host "⚙️  正在卸载 Windows EasySkills 后台自动同步服务..." -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan

# 1. Remove the startup shortcut / 移除开机自启快捷方式
$StartupFolder = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
$ShortcutPath = "$StartupFolder\EasySkillsWatcher.lnk"

if (Test-Path $ShortcutPath) {
    Remove-Item $ShortcutPath -Force
    Write-Host "✅ Removed startup shortcut / 已成功移除开机启动项。" -ForegroundColor Green
} else {
    Write-Host "ℹ️  No startup shortcut found / 未在系统启动项中找到该快捷方式。" -ForegroundColor Gray
}

# 2. Terminate running background PowerShell watcher tasks / 优雅寻找并终止当前正在后台运行的监听进程
try {
    # Find and terminate powershell processes running the watcher script via WMI/CIM
    $WatcherProcesses = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' AND CommandLine LIKE '%watcher-service.ps1%'"
    if ($WatcherProcesses) {
        foreach ($Proc in $WatcherProcesses) {
            $Proc | Invoke-CimMethod -MethodName Terminate | Out-Null
            Write-Host "✅ Terminated running background watcher (PID: $($Proc.ProcessId)) / 已成功关闭后台运行的监听进程。" -ForegroundColor Green
        }
    } else {
        Write-Host "ℹ️  No active background watcher process found / 未检测到当前后台有活跃的监听进程。" -ForegroundColor Gray
    }
}
catch {
    Write-Warning "⚠️  Failed to query or terminate processes: $_"
}

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "🎉 Uninstallation complete / 卸载完成。" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
