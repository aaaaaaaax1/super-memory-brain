@echo off
setlocal EnableExtensions
chcp 65001 >nul

if /I "%~1"=="console" goto console
if /I "%~1"=="cmd" goto console
if /I "%~1"=="ui" goto ui

if /I "%~1"=="bootstrap" goto bootstrap

goto bootstrap

:console
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-menu.ps1"
set "EXIT_CODE=%ERRORLEVEL%"
echo.
if not "%EXIT_CODE%"=="0" echo Super Memory Brain menu exited with code %EXIT_CODE%.
pause
exit /b %EXIT_CODE%

:ui
wscript.exe "%~dp0install-ui.vbs"
set "EXIT_CODE=%ERRORLEVEL%"
if not "%EXIT_CODE%"=="0" echo Super Memory Brain UI launcher exited with code %EXIT_CODE%.
pause
exit /b %EXIT_CODE%

:bootstrap
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0bootstrap.ps1"
set "EXIT_CODE=%ERRORLEVEL%"
echo.
if not "%EXIT_CODE%"=="0" echo Super Memory Brain bootstrap exited with code %EXIT_CODE%.
pause
exit /b %EXIT_CODE%
