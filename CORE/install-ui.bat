@echo off
setlocal EnableExtensions
chcp 65001 >nul

call "%~dp0scripts\install.bat" ui
set "EXIT_CODE=%ERRORLEVEL%"
exit /b %EXIT_CODE%
