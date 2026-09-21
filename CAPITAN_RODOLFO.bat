@echo off
setlocal EnableExtensions EnableDelayedExpansion
title Capitan Rodolfo

set "APPROOT=%LOCALAPPDATA%\CapitanRodolfo"
set "BRIDGEDIR=%APPROOT%\bridge"
set "BASE=https://raw.githubusercontent.com/DuilioMF/capitan-rodolfo/main/bridge"
set "WEB=https://duiliomf.github.io/capitan-rodolfo/"
set "TASKNAME=CapitanRodolfoBridge"
set "HEALTH=http://127.0.0.1:8787/health"

color 0E
cls
echo.
echo ============================================================
echo                  CAPITAN RODOLFO
echo ============================================================
echo.
echo   Verificando conector local...
echo.

call :health
if "!BRIDGE_OK!"=="1" goto :openweb

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
echo   Lo voy a iniciar...
echo.
call :startbridge
call :waithealth
if "!BRIDGE_OK!"=="1" goto :openweb

echo.
echo   No pude iniciar el conector.
echo   Voy a actualizarlo y repararlo...
echo.
goto :install

:install
if not exist "%APPROOT%" mkdir "%APPROOT%" >nul 2>nul
if not exist "%BRIDGEDIR%" mkdir "%BRIDGEDIR%" >nul 2>nul

echo   [1/5] Descargando la ultima version...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "try { Invoke-WebRequest -UseBasicParsing '%BASE%/bridge.py' -OutFile '%BRIDGEDIR%\bridge.py'; Invoke-WebRequest -UseBasicParsing '%BASE%/requirements.txt' -OutFile '%BRIDGEDIR%\requirements.txt'; exit 0 } catch { Write-Host $_.Exception.Message; exit 1 }"
if errorlevel 1 goto :fatal

echo   [2/5] Preparando Python...
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

echo   [4/5] Creando arranque automatico...
> "%BRIDGEDIR%\iniciar_silencioso.cmd" (
    echo @echo off
    echo cd /d "%%LOCALAPPDATA%%\CapitanRodolfo\bridge"
    echo py bridge.py
)

schtasks /Query /TN "%TASKNAME%" >nul 2>nul
if errorlevel 1 (
    schtasks /Create /F /SC ONLOGON /RL LIMITED /TN "%TASKNAME%" /TR "\"%BRIDGEDIR%\iniciar_silencioso.cmd\"" >nul 2>nul
)

echo   [5/5] Iniciando conector...
call :startbridge
call :waithealth

if not "!BRIDGE_OK!"=="1" goto :fatal

echo.
echo   Instalacion completa.
echo   El conector quedara listo para los proximos inicios de Windows.
echo.
timeout /t 2 >nul
goto :openweb

:startbridge
start "Capitan Rodolfo SQL Bridge" /min cmd /c ""%BRIDGEDIR%\iniciar_silencioso.cmd""
exit /b 0

:waithealth
set "BRIDGE_OK=0"
for /L %%I in (1,1,15) do (
    call :health
    if "!BRIDGE_OK!"=="1" exit /b 0
    timeout /t 1 >nul
)
exit /b 0

:health
set "BRIDGE_OK=0"
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "try { $r=Invoke-RestMethod -Uri '%HEALTH%' -TimeoutSec 1; if($r.ok){ exit 0 } else { exit 1 } } catch { exit 1 }"
if not errorlevel 1 set "BRIDGE_OK=1"
exit /b 0

:openweb
echo   Conector listo.
echo   Abriendo Capitan Rodolfo...
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
echo   Si queres, copia esta pantalla y me la mandas.
echo.
pause
exit /b 1
