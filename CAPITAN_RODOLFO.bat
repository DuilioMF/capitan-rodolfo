@echo off
setlocal EnableExtensions EnableDelayedExpansion
title Capitan Rodolfo v20

set "APPROOT=%LOCALAPPDATA%\CapitanRodolfo"
set "BRIDGEDIR=%APPROOT%\bridge"
set "BASE=https://raw.githubusercontent.com/DuilioMF/capitan-rodolfo/main/bridge"
set "WEB=https://duiliomf.github.io/capitan-rodolfo/conexion-sql.html"
set "TASKNAME=CapitanRodolfoBridge"
set "HEALTH=http://127.0.0.1:8787/health"
set "REQUIRED_VERSION=20"

color 0E
cls
echo.
echo ============================================================
echo                  CAPITAN RODOLFO v20
echo ============================================================
echo.
echo   Verificando conector local...
echo.

call :health
if "!BRIDGE_OK!"=="1" (
    if "!BRIDGE_VERSION!"=="%REQUIRED_VERSION%" goto :openweb
    echo   Encontre un conector viejo: v!BRIDGE_VERSION!
    echo   Voy a actualizarlo a v%REQUIRED_VERSION%...
    echo.
    call :stopold
    goto :install
)

if not exist "%BRIDGEDIR%\bridge.py" (
    echo   No encuentro el conector de Capitan Rodolfo.
    echo.
    echo   Lo voy a instalar ahora...
    echo   Esto se hace una sola vez.
    echo.
    timeout /t 2 >nul
    goto :install
)

echo   El conector esta instalado pero no esta corriendo.
echo   Lo voy a actualizar y arrancar...
echo.
goto :install

:install
if not exist "%APPROOT%" mkdir "%APPROOT%" >nul 2>nul
if not exist "%BRIDGEDIR%" mkdir "%BRIDGEDIR%" >nul 2>nul

echo   [1/5] Descargando la ultima version...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "try { Invoke-WebRequest -UseBasicParsing '%BASE%/bridge.py' -OutFile '%BRIDGEDIR%\bridge.py'; Invoke-WebRequest -UseBasicParsing '%BASE%/requirements.txt' -OutFile '%BRIDGEDIR%\requirements.txt'; exit 0 } catch { Write-Host $_.Exception.Message; exit 1 }"
if errorlevel 1 goto :fatal

echo   [2/5] Verificando Python...
py --version >nul 2>nul
if errorlevel 1 (
    echo.
    echo   Python no esta instalado o no esta disponible con el comando "py".
    echo   Instala Python y volve a ejecutar este archivo.
    echo.
    pause
    exit /b 1
)

echo   [3/5] Instalando dependencias...
py -m pip install -r "%BRIDGEDIR%\requirements.txt" --disable-pip-version-check >nul
if errorlevel 1 goto :fatal

echo   [4/5] Configurando arranque automatico...
> "%BRIDGEDIR%\iniciar_silencioso.cmd" (
    echo @echo off
    echo cd /d "%%LOCALAPPDATA%%\CapitanRodolfo\bridge"
    echo py bridge.py
)

schtasks /Query /TN "%TASKNAME%" >nul 2>nul
if errorlevel 1 (
    schtasks /Create /F /SC ONLOGON /RL LIMITED /TN "%TASKNAME%" /TR "\"%BRIDGEDIR%\iniciar_silencioso.cmd\"" >nul 2>nul
)

echo   [5/5] Iniciando conector v%REQUIRED_VERSION%...
call :stopold
call :startbridge
call :waithealth

if not "!BRIDGE_OK!"=="1" goto :fatal
if not "!BRIDGE_VERSION!"=="%REQUIRED_VERSION%" (
    echo.
    echo   El bridge respondio, pero la version es v!BRIDGE_VERSION!.
    goto :fatal
)

echo.
echo   Instalacion completa. Bridge v!BRIDGE_VERSION! OK.
echo.
timeout /t 2 >nul
goto :openweb

:startbridge
start "Capitan Rodolfo SQL Bridge v20" /min cmd /c ""%BRIDGEDIR%\iniciar_silencioso.cmd""
exit /b 0

:stopold
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$p=Get-NetTCPConnection -LocalPort 8787 -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique; foreach($id in $p){ try { Stop-Process -Id $id -Force -ErrorAction Stop } catch {} }"
timeout /t 1 >nul
exit /b 0

:waithealth
set "BRIDGE_OK=0"
set "BRIDGE_VERSION="
for /L %%I in (1,1,20) do (
    call :health
    if "!BRIDGE_OK!"=="1" exit /b 0
    timeout /t 1 >nul
)
exit /b 0

:health
set "BRIDGE_OK=0"
set "BRIDGE_VERSION="
for /f "usebackq delims=" %%V in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "try { $r=Invoke-RestMethod -Uri '%HEALTH%' -TimeoutSec 1; if($r.ok){ Write-Output $r.version } } catch {}"`) do set "BRIDGE_VERSION=%%V"
if defined BRIDGE_VERSION set "BRIDGE_OK=1"
exit /b 0

:openweb
echo   Conector v!BRIDGE_VERSION! listo.
echo   Abriendo conexion SQL...
echo.
start "" "%WEB%"
timeout /t 2 >nul
exit /b 0

:fatal
color 0C
echo.
echo ============================================================
echo   No se pudo completar la instalacion o el arranque.
echo ============================================================
echo.
echo   Mandame una foto de esta ventana y veo el error exacto.
echo.
pause
exit /b 1
