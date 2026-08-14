@echo off
setlocal EnableExtensions
chcp 65001 >nul

wscript.exe "%~dp0brain-ui.vbs"
set "EXIT_CODE=%ERRORLEVEL%"
if not "%EXIT_CODE%"=="0" (
  echo Super Brain Console exited with code %EXIT_CODE%.
  echo Please check memory\workspace\last-install-ui-events.log and rerun brain.bat.
  pause
  exit /b %EXIT_CODE%
)
exit /b 0
