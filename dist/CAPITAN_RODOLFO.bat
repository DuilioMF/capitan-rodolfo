@echo off
setlocal EnableExtensions EnableDelayedExpansion
title DoingLio - Conector SQL

set "APPROOT=C:\Sistemas\DoingLioConnector"
set "BRIDGEDIR=%APPROOT%\bridge"
set "BRIDGE=%BRIDGEDIR%\capitan_rodolfo_local.ps1"
set "SQL_WORKER=%BRIDGEDIR%\doinglio_sql_queue_worker.ps1"
set "CORE_LINK=%BRIDGEDIR%\doinglio_core_link.ps1"
set "STOPPER=%BRIDGEDIR%\stop_stale_capitan.ps1"
set "SQL_WORKER_TASK=CapitanRodolfoSqlQueue"
set "VERSION_FILE=%APPROOT%\VERSION"
set "ALLOWLIST=%APPROOT%\sp_allowlist.json"
set "LOG=%APPROOT%\install.log"
set "TASK=CapitanRodolfoLocal"
set "RAW=https://raw.githubusercontent.com/DuilioMF/capitan-rodolfo/main"
set "EXPECTED_VERSION="
set "CACHEBUST=%RANDOM%%RANDOM%"

if not exist "C:\Sistemas" mkdir "C:\Sistemas" >nul 2>nul
if not exist "%APPROOT%" mkdir "%APPROOT%" >nul 2>nul
if not exist "%BRIDGEDIR%" mkdir "%BRIDGEDIR%" >nul 2>nul

> "%LOG%" echo [%date% %time%] Inicio instalacion conector DoingLio SQL

echo.
echo ============================================================
echo           DOINGLIO - CONECTOR SQL CAPITAN
echo ============================================================
echo.
echo Carpeta local: %APPROOT%
echo Actualizando conector...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; Invoke-WebRequest -UseBasicParsing '%RAW%/bridge/capitan_rodolfo_local.ps1?v=%CACHEBUST%' -OutFile '%BRIDGE%'; Invoke-WebRequest -UseBasicParsing '%RAW%/bridge/doinglio_sql_queue_worker.ps1?v=%CACHEBUST%' -OutFile '%SQL_WORKER%'; Invoke-WebRequest -UseBasicParsing '%RAW%/bridge/doinglio_core_link.ps1?v=%CACHEBUST%' -OutFile '%CORE_LINK%'; Invoke-WebRequest -UseBasicParsing '%RAW%/bridge/stop_stale_capitan.ps1?v=%CACHEBUST%' -OutFile '%STOPPER%'; Invoke-WebRequest -UseBasicParsing '%RAW%/VERSION?v=%CACHEBUST%' -OutFile '%VERSION_FILE%'; Invoke-WebRequest -UseBasicParsing '%RAW%/sp_allowlist.json?v=%CACHEBUST%' -OutFile '%ALLOWLIST%'" >>"%LOG%" 2>&1
if errorlevel 1 goto :error
echo [%date% %time%] Verificando sintaxis PowerShell antes de reiniciar servicios >>"%LOG%"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; foreach($f in @('%BRIDGE%','%SQL_WORKER%','%CORE_LINK%','%STOPPER%')){$tok=$null;$errs=$null;$null=[System.Management.Automation.Language.Parser]::ParseFile($f,[ref]$tok,[ref]$errs);if($errs.Count -gt 0){foreach($e in $errs){Write-Output ($f+': '+$e.Message)};exit 1}}" >>"%LOG%" 2>&1
if errorlevel 1 goto :error
for /f "usebackq delims=" %%V in ("%VERSION_FILE%") do if not defined EXPECTED_VERSION set "EXPECTED_VERSION=%%V"
if not defined EXPECTED_VERSION goto :error

schtasks /End /TN "%TASK%" >nul 2>nul
schtasks /Delete /F /TN "%TASK%" >nul 2>nul

schtasks /End /TN "%SQL_WORKER_TASK%" >nul 2>nul
echo [%date% %time%] Cerrando solo procesos antiguos de este conector >>"%LOG%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%STOPPER%" >>"%LOG%" 2>&1
schtasks /Create /F /SC ONLOGON /RL LIMITED /TN "%SQL_WORKER_TASK%" /TR "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File %SQL_WORKER%" >>"%LOG%" 2>&1
start "" powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%SQL_WORKER%"

echo [%date% %time%] Iniciando PowerShell bridge >>"%LOG%"
powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%BRIDGE%" -AppDir "%APPROOT%" >>"%LOG%" 2>&1

set "ACTIVE_PORT="
for /L %%I in (1,1,30) do (
  for /f "delims=" %%Q in ('powershell -NoProfile -ExecutionPolicy Bypass -Command "$ports=8787,8797,18787,27877,37877,48787,57877; foreach($p in $ports){ try{$r=Invoke-RestMethod -Uri ('http://127.0.0.1:'+ $p +'/health') -TimeoutSec 1; if($r.ok -and [string]$r.version -eq '%EXPECTED_VERSION%'){Write-Output $p; break}}catch{}}"') do (
    set "ACTIVE_PORT=%%Q"
  )
  if defined ACTIVE_PORT goto :ready
  timeout /t 1 >nul
)

:ready
if defined ACTIVE_PORT (
  echo [%date% %time%] Conector listo puerto !ACTIVE_PORT! >>"%LOG%"
  echo Conector SQL v%EXPECTED_VERSION% listo en puerto !ACTIVE_PORT!.
  start "" "http://127.0.0.1:!ACTIVE_PORT!/"
  timeout /t 2 >nul
  exit /b 0
)

:error
echo [%date% %time%] ERROR: no respondio ningun puerto >>"%LOG%"
echo.
echo No se pudo instalar o iniciar el conector SQL.
echo Log: %LOG%
echo No se borraron las credenciales guardadas.
start "" notepad.exe "%LOG%"
pause
exit /b 1
