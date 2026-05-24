@echo off
:: EasySkills WebUI Launcher
title EasySkills WebUI
echo Starting EasySkills WebUI...
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0..\webui.ps1"
timeout /t 2 /nobreak > nul
start "" "http://localhost:6633"
echo EasySkills WebUI is launching in the background.
