@echo off
setlocal EnableExtensions EnableDelayedExpansion
title Capitan Rodolfo v22

set "APPROOT=%LOCALAPPDATA%\CapitanRodolfo"
set "LOCALPS=%APPROOT%\capitan_rodolfo_local.ps1"
set "REMOTE=https://raw.githubusercontent.com/DuilioMF/capitan-rodolfo/main/bridge/capitan_rodolfo_local.ps1"
set "HEALTH=http://127.0.0.1:8787/health"
set "LOCALURL=http://127.0.0.1:8787/"
set "TASKNAME=CapitanRodolfoLocal"

color 0E
cls
echo.
echo ============================================================
echo                  CAPITAN RODOLFO v22
echo ============================================================
echo.
echo   Preparando conector SQL local...
echo.

if not exist "%APPROOT%" mkdir "%APPROOT%" >nul 2>nul

echo   [1/4] Cerrando conectores anteriores...
schtasks /End /TN "%TASKNAME%" >nul 2>nul
for /f "tokens=5" %%P in ('netstat -ano ^| findstr /R /C:":8787 .*LISTENING"') do taskkill /PID %%P /F >nul 2>nul
timeout /t 1 >nul

echo   [2/4] Descargando conector v22...
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Invoke-WebRequest -UseBasicParsing '%REMOTE%' -OutFile '%LOCALPS%'; exit 0 } catch { Write-Host $_.Exception.Message; exit 1 }"
if errorlevel 1 goto :fatal

echo   [3/4] Configurando arranque automatico...
schtasks /Delete /F /TN "%TASKNAME%" >nul 2>nul
schtasks /Create /F /SC ONLOGON /RL LIMITED /TN "%TASKNAME%" /TR "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"%LOCALPS%\"" >nul 2>nul

echo   [4/4] Iniciando...
start "Capitan Rodolfo Local v22" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%LOCALPS%"

set "OK=0"
for /L %%I in (1,1,20) do (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "try { $r=Invoke-RestMethod -Uri '%HEALTH%' -TimeoutSec 1; if($r.version -eq '22'){exit 0}else{exit 1} } catch { exit 1 }"
  if not errorlevel 1 (
    set "OK=1"
    goto :ready
  )
  timeout /t 1 >nul
)

:ready
if "!OK!"=="1" (
  echo.
  echo   Conector local v22 OK.
  echo   Abriendo conexion SQL...
  start "" "%LOCALURL%"
  timeout /t 2 >nul
  exit /b 0
)

:fatal
color 0C
echo.
echo ============================================================
echo   No se pudo iniciar el conector local v22.
echo ============================================================
echo.
echo   Mandame esta pantalla.
pause
exit /b 1
