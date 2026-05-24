@echo off
:: EasySkills WebUI Launcher
title EasySkills WebUI
echo Starting EasySkills WebUI...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\webui.ps1"
if %errorlevel% neq 0 (
    echo.
    echo ==========================================================
    echo [Error] EasySkills WebUI failed to start.
    echo Please check the error message above.
    echo ==========================================================
    pause
)
