@echo off
setlocal
set "TASK=CapitanRodolfoLocal"
for /f "tokens=5" %%P in ('netstat -ano ^| findstr /R /C:":8787 .*LISTENING"') do taskkill /PID %%P /F >nul 2>nul
schtasks /End /TN "%TASK%" >nul 2>nul
start "" /min powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0bridge\capitan_rodolfo_local.ps1" -AppDir "%~dp0"
timeout /t 2 >nul
start "" "http://127.0.0.1:8787/"
exit /b 0
