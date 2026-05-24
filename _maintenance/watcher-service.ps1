# ==============================================================================
# Script: watcher-service.ps1 (Windows)
# Description: Background listener using System.IO.FileSystemWatcher.
# 脚本：watcher-service.ps1 (Windows)
# 描述：Windows 后台静默监听服务，基于 .NET FileSystemWatcher 进行高效率、零 CPU 占用监听。
# ==============================================================================

$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent
$CentralDir = Split-Path -Path $ScriptDir -Parent

# Initial synchronization / 启动时先执行一次全量同步
try {
    & "$ScriptDir\deploy.ps1"
} catch {
    Write-Warning "Initial sync failed: $($_.Exception.Message)"
}

# Initialize FileSystemWatcher / 初始化文件夹监听器，动态监听仓库根目录
$Watcher = New-Object System.IO.FileSystemWatcher
$Watcher.Path = $CentralDir
$Watcher.IncludeSubdirectories = $false
$Watcher.EnableRaisingEvents = $true

Write-Host "👀 Starting background watcher on $CentralDir..."

# Block and wait for changes forever in a low-power loop / 永久进行高效能阻塞式循环监听
while ($true) {
    try {
        # Wait for changes (Create, Delete, Rename) up to 10 minutes / 阻塞等待任何目录变化（最长等待10分钟）
        $Change = $Watcher.WaitForChanged([System.IO.WatcherChangeTypes]::All, 600000)

        if ($Change.TimedOut -eq $false) {
            # Throttling/cooldown to let file writes complete / 防抖冷却：等待半秒以合并并发的写入事件
            Start-Sleep -Milliseconds 500

            # Trigger the deployment script / 自动触发同步
            try {
                & "$ScriptDir\deploy.ps1"
            } catch {
                Write-Warning "Sync failed: $($_.Exception.Message)"
            }
        }
    } catch {
        # Outer guard: catches WaitForChanged failures (e.g. watched directory deleted)
        # 外层保护：捕获 WaitForChanged 本身的异常（如被监控目录被删除），防止 watcher 静默崩溃
        Write-Warning "Watcher error: $($_.Exception.Message). Restarting in 5s..."
        Start-Sleep -Seconds 5
    }
}
