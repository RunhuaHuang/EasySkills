@echo off
:: EasySkills WebUI Launcher
title EasySkills WebUI
echo Starting EasySkills WebUI...

set "MAINT_DIR=%~dp0.."

:: Prefer the Scheduled Task (true detachment - survives this window closing).
:: Falls back to a hidden WScript launch if the task isn't registered yet.
schtasks /Query /TN "EasySkills WebUI" >nul 2>&1
if %ERRORLEVEL%==0 (
  schtasks /Run /TN "EasySkills WebUI" >nul 2>&1
  schtasks /Run /TN "EasySkills Watcher" >nul 2>&1
) else (
  :: Fallback: plain Start-Process. Avoids COM/WScript.Shell patterns that AV flags.
  powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell.exe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File','\"%MAINT_DIR%\webui-service.ps1\"' -WindowStyle Hidden; Start-Process powershell.exe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File','\"%MAINT_DIR%\watcher-service.ps1\"' -WindowStyle Hidden"
)

:: Wait until the port is actually listening before opening the browser.
powershell -NoProfile -ExecutionPolicy Bypass -Command "for ($i=0; $i -lt 20; $i++) { $c=New-Object System.Net.Sockets.TcpClient; try { $a=$c.BeginConnect('127.0.0.1',6633,$null,$null); if ($a.AsyncWaitHandle.WaitOne(500,$false)) { try { $c.EndConnect($a); exit 0 } catch {} } } catch {} finally { try { $c.Close() } catch {} }; Start-Sleep -Milliseconds 500 }; exit 1"

start "" "http://localhost:6633"
echo EasySkills WebUI is running in the background.
echo You can safely close this window.
