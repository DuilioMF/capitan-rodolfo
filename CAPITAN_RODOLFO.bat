@echo off
setlocal EnableExtensions
for %%I in ("%~dp0.") do set "APPROOT=%%~fI"
set "BRIDGE=%APPROOT%\bridge\capitan_rodolfo_local.ps1"
set "TASK=CapitanRodolfoLocal"

if not exist "%BRIDGE%" (
  echo ERROR: falta %BRIDGE%
  pause
  exit /b 1
)

for /f "tokens=5" %%P in ('netstat -ano ^| findstr /R /C:":8787 .*LISTENING"') do taskkill /PID %%P /F >nul 2>nul
schtasks /End /TN "%TASK%" >nul 2>nul
schtasks /Delete /F /TN "%TASK%" >nul 2>nul
schtasks /Create /F /SC ONLOGON /RL LIMITED /TN "%TASK%" /TR "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"%BRIDGE%\" -AppDir \"%APPROOT%\" -BackgroundChild" >nul 2>nul
start "" powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%BRIDGE%" -AppDir "%APPROOT%" -BackgroundChild
timeout /t 2 >nul
start "" "http://127.0.0.1:8787/"
exit /b 0
