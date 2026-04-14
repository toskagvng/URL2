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

echo Demarrage du bot de surveillance...
echo Une fenetre PowerShell va rester ouverte tant que le bot tourne.
echo Ferme cette fenetre pour arreter la surveillance.
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_PATH%" -ConfigPath "%CONFIG_PATH%"

echo.
echo Le bot s'est arrete.
pause
