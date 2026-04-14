@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "CONFIG_PATH=%SCRIPT_DIR%config.thread.json"
set "SCRIPT_PATH=%SCRIPT_DIR%watch-url.ps1"

if not exist "%SCRIPT_PATH%" (
  echo Script introuvable : "%SCRIPT_PATH%"
  pause
  exit /b 1
)

if not exist "%CONFIG_PATH%" (
  echo Configuration introuvable : "%CONFIG_PATH%"
  pause
  exit /b 1
)

echo Test unique du bot...
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_PATH%" -ConfigPath "%CONFIG_PATH%" -RunOnce

echo.
pause
