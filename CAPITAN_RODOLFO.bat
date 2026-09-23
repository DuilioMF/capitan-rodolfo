@echo off
setlocal EnableExtensions
title DoingLio - Conector SQL

set "APPROOT=C:\Sistemas\DoingLioConnector"
set "BRIDGEDIR=%APPROOT%\bridge"
set "BRIDGE=%BRIDGEDIR%\capitan_rodolfo_local.ps1"
set "VERSION_FILE=%APPROOT%\VERSION"
set "ALLOWLIST=%APPROOT%\sp_allowlist.json"
set "TASK=CapitanRodolfoLocal"
set "RAW=https://raw.githubusercontent.com/DuilioMF/capitan-rodolfo/main"

if not exist "C:\Sistemas" mkdir "C:\Sistemas" >nul 2>nul
if not exist "%APPROOT%" mkdir "%APPROOT%" >nul 2>nul
if not exist "%BRIDGEDIR%" mkdir "%BRIDGEDIR%" >nul 2>nul

echo.
echo ============================================================
echo           DOINGLIO - CONECTOR SQL CAPITAN
echo ============================================================
echo.
echo Carpeta local: %APPROOT%
echo Actualizando conector...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; Invoke-WebRequest -UseBasicParsing '%RAW%/bridge/capitan_rodolfo_local.ps1' -OutFile '%BRIDGE%'; Invoke-WebRequest -UseBasicParsing '%RAW%/VERSION' -OutFile '%VERSION_FILE%'; Invoke-WebRequest -UseBasicParsing '%RAW%/sp_allowlist.json' -OutFile '%ALLOWLIST%'"
if errorlevel 1 goto :error

for /f "tokens=5" %%P in ('netstat -ano ^| findstr /R /C:":8787 .*LISTENING"') do taskkill /PID %%P /F >nul 2>nul
schtasks /End /TN "%TASK%" >nul 2>nul
schtasks /Delete /F /TN "%TASK%" >nul 2>nul

rem El propio conector crea la tarea de inicio y lanza el hijo oculto.
powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%BRIDGE%" -AppDir "%APPROOT%"

set "READY=0"
for /L %%I in (1,1,20) do (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "try { $r=Invoke-RestMethod -Uri 'http://127.0.0.1:8787/health' -TimeoutSec 1; if($r.ok){exit 0}else{exit 1} } catch { exit 1 }"
  if not errorlevel 1 (
    set "READY=1"
    goto :ready
  )
  timeout /t 1 >nul
)

:ready
if "%READY%"=="1" (
  echo Conector SQL listo.
  start "" "https://duiliomf.github.io/capitan-rodolfo/conexion-sql.html"
  timeout /t 2 >nul
  exit /b 0
)

:error
echo.
echo No se pudo instalar o iniciar el conector SQL.
echo No se borraron las credenciales guardadas.
pause
exit /b 1
