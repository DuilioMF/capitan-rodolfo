@echo off
setlocal
for /f "tokens=5" %%P in ('netstat -ano ^| findstr /R /C:":8787 .*LISTENING"') do taskkill /PID %%P /F >nul 2>nul
schtasks /End /TN "CapitanRodolfoLocal" >nul 2>nul
start "" powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0bridge\capitan_rodolfo_local.ps1" -AppDir "%~dp0" -BackgroundChild
timeout /t 2 >nul
start "" "http://127.0.0.1:8787/"
exit /b 0
