@echo off
setlocal EnableExtensions EnableDelayedExpansion
title Capitan Rodolfo v21

set "APPROOT=%LOCALAPPDATA%\CapitanRodolfo"
set "BRIDGEDIR=%APPROOT%\bridge"
set "BASE=https://raw.githubusercontent.com/DuilioMF/capitan-rodolfo/main/bridge"
set "WEB=https://duiliomf.github.io/capitan-rodolfo/conexion-sql.html"
set "TASKNAME=CapitanRodolfoBridge"
set "HEALTH=http://127.0.0.1:8787/health"
set "REQUIRED_VERSION=21"

color 0E
cls
echo.
echo ============================================================
echo                  CAPITAN RODOLFO v21
echo ============================================================
echo.
echo   Verificando conector local...
echo.

call :health
if "!BRIDGE_OK!"=="1" (
    if "!BRIDGE_VERSION!"=="%REQUIRED_VERSION%" goto :openweb
    echo   Encontre un conector viejo: v!BRIDGE_VERSION!
    echo   Voy a cerrarlo y actualizarlo a v%REQUIRED_VERSION%...
    echo.
    call :stopold
    goto :install
)

if not exist "%BRIDGEDIR%\bridge.py" (
    echo   No encuentro el conector de Capitan Rodolfo.
    echo   Lo voy a instalar ahora...
    echo.
    goto :install
)

echo   El conector esta instalado pero no responde.
echo   Voy a repararlo y actualizarlo...
echo.
goto :install

:install
if not exist "%APPROOT%" mkdir "%APPROOT%" >nul 2>nul
if not exist "%BRIDGEDIR%" mkdir "%BRIDGEDIR%" >nul 2>nul

echo   [1/6] Cerrando bridges anteriores...
call :stopold

echo   [2/6] Descargando la ultima version...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "try { Invoke-WebRequest -UseBasicParsing '%BASE%/bridge.py' -OutFile '%BRIDGEDIR%\bridge.py'; Invoke-WebRequest -UseBasicParsing '%BASE%/requirements.txt' -OutFile '%BRIDGEDIR%\requirements.txt'; exit 0 } catch { Write-Host $_.Exception.Message; exit 1 }"
if errorlevel 1 goto :fatal

echo   [3/6] Verificando Python...
py --version >nul 2>nul
if errorlevel 1 (
    echo.
    echo   Python no esta instalado o no esta disponible con el comando "py".
    pause
    exit /b 1
)

echo   [4/6] Instalando dependencias...
py -m pip install -r "%BRIDGEDIR%\requirements.txt" --disable-pip-version-check >nul
if errorlevel 1 goto :fatal

echo   [5/6] Configurando arranque automatico...
> "%BRIDGEDIR%\iniciar_silencioso.cmd" (
    echo @echo off
    echo cd /d "%%LOCALAPPDATA%%\CapitanRodolfo\bridge"
    echo py bridge.py
)

schtasks /Delete /F /TN "%TASKNAME%" >nul 2>nul
schtasks /Create /F /SC ONLOGON /RL LIMITED /TN "%TASKNAME%" /TR "\"%BRIDGEDIR%\iniciar_silencioso.cmd\"" >nul 2>nul

echo   [6/6] Iniciando conector v%REQUIRED_VERSION%...
call :startbridge
call :waithealth

if not "!BRIDGE_OK!"=="1" goto :fatal
if not "!BRIDGE_VERSION!"=="%REQUIRED_VERSION%" (
    echo.
    echo   El puerto 8787 respondio con v!BRIDGE_VERSION! y deberia ser v%REQUIRED_VERSION%.
    echo   Todavia hay un proceso viejo ocupando el puerto.
    goto :fatal
)

echo.
echo   Bridge v!BRIDGE_VERSION! OK.
echo.
timeout /t 2 >nul
goto :openweb

:startbridge
start "Capitan Rodolfo SQL Bridge v21" /min cmd /c ""%BRIDGEDIR%\iniciar_silencioso.cmd""
exit /b 0

:stopold
echo   Cerrando cualquier bridge.py anterior...

schtasks /End /TN "%TASKNAME%" >nul 2>nul

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='SilentlyContinue';" ^
  "$ps=Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'bridge\.py' -and ($_.Name -match 'python|py') };" ^
  "foreach($p in $ps){ Invoke-CimMethod -InputObject $p -MethodName Terminate | Out-Null };" ^
  "$owners=Get-NetTCPConnection -LocalPort 8787 -State Listen | Select-Object -ExpandProperty OwningProcess -Unique;" ^
  "foreach($pid2 in $owners){ Stop-Process -Id $pid2 -Force -ErrorAction SilentlyContinue };"

for /f "tokens=5" %%P in ('netstat -ano ^| findstr /R /C:":8787 .*LISTENING"') do (
    taskkill /PID %%P /F >nul 2>nul
)

for /L %%I in (1,1,8) do (
    call :portcheck
    if "!PORT_BUSY!"=="0" exit /b 0
    timeout /t 1 >nul
)

echo.
echo   ADVERTENCIA: el puerto 8787 sigue ocupado.
exit /b 0

:portcheck
set "PORT_BUSY=0"
for /f "tokens=5" %%P in ('netstat -ano ^| findstr /R /C:":8787 .*LISTENING"') do set "PORT_BUSY=1"
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
echo   Version detectada: !BRIDGE_VERSION!
echo   Mandame esta pantalla y sigo desde ahi.
echo.
pause
exit /b 1
