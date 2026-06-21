@echo off
setlocal EnableExtensions
chcp 65001 >nul

if /I "%~1"=="console" goto console
if /I "%~1"=="cmd" goto console

wscript.exe "%~dp0install-ui.vbs"
set "EXIT_CODE=%ERRORLEVEL%"
if not "%EXIT_CODE%"=="0" (
  echo Super Memory Brain UI launcher exited with code %EXIT_CODE%.
  echo Please check memory\workspace\last-install-ui-events.log and rerun install.bat.
  pause
  exit /b %EXIT_CODE%
)
exit /b 0

:console
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-menu.ps1"
set "EXIT_CODE=%ERRORLEVEL%"
echo.
if not "%EXIT_CODE%"=="0" echo Super Memory Brain menu exited with code %EXIT_CODE%.
pause
exit /b %EXIT_CODE%
