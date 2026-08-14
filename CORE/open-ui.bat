@echo off
setlocal EnableExtensions
chcp 65001 >nul

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\open-control-center.ps1"
set "EXIT_CODE=%ERRORLEVEL%"
if not "%EXIT_CODE%"=="0" (
  echo Super Memory Brain Web UI failed to start (code %EXIT_CODE%).
  pause
)
exit /b %EXIT_CODE%
