@echo off
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0jukebox-sync.ps1" -Mode push
echo.
pause
