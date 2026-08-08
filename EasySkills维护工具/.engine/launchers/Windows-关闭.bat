@echo off
:: EasySkills Shutdown (Windows) / 关闭 EasySkills 后台服务
:: Stops the WebUI and Watcher Scheduled Tasks.

chcp 65001 > nul

title EasySkills Shutdown

echo =============================================
echo Stopping EasySkills services / 正在关闭 EasySkills...
echo =============================================

:: Stop the two Scheduled Tasks that power the background services.
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Stop-ScheduledTask -TaskName 'EasySkills WebUI' -ErrorAction Stop; Stop-ScheduledTask -TaskName 'EasySkills Watcher' -ErrorAction Stop; Write-Host 'Scheduled tasks stopped.' } catch { Write-Host ('Warning: ' + $_.Exception.Message) }"

echo =============================================
echo EasySkills services stopped. / EasySkills 已关闭。
echo This window will close in a moment.
echo =============================================
timeout /t 3 /nobreak > nul
