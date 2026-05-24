@echo off
:: EasySkills WebUI Launcher
title EasySkills WebUI
echo Starting EasySkills WebUI...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$s=New-Object -ComObject WScript.Shell; [void]$s.Run('powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""%~dp0..\webui-service.ps1""', 0, $false)"
timeout /t 2 /nobreak > nul
start "" "http://localhost:6633"
echo EasySkills WebUI is launching in the background.
