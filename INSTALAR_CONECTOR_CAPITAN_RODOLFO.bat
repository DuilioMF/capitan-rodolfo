@echo off
setlocal EnableExtensions
title Instalar conector local - Capitan Rodolfo

set "ROOT=%LOCALAPPDATA%\CapitanRodolfoBridge"
set "BASE=https://raw.githubusercontent.com/DuilioMF/capitan-rodolfo/main/bridge"

echo.
echo ==============================================
echo   INSTALADOR LOCAL - CAPITAN RODOLFO
echo ==============================================
echo.
if not exist "%ROOT%" mkdir "%ROOT%"

echo [1/4] Descargando bridge...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "Invoke-WebRequest -UseBasicParsing '%BASE%/bridge.py' -OutFile '%ROOT%\bridge.py'; Invoke-WebRequest -UseBasicParsing '%BASE%/requirements.txt' -OutFile '%ROOT%\requirements.txt'"
if errorlevel 1 goto :error

echo [2/4] Creando lanzador local...
> "%ROOT%\launch.cmd" (
  echo @echo off
  echo setlocal
  echo set "ROOT=%%LOCALAPPDATA%%\CapitanRodolfoBridge"
  echo set "BASE=https://raw.githubusercontent.com/DuilioMF/capitan-rodolfo/main/bridge"
  echo powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Invoke-WebRequest -UseBasicParsing '%%BASE%%/bridge.py' -OutFile '%%ROOT%%\bridge.py'; Invoke-WebRequest -UseBasicParsing '%%BASE%%/requirements.txt' -OutFile '%%ROOT%%\requirements.txt' } catch {}"
  echo py -m pip install -r "%%ROOT%%\requirements.txt" ^>nul 2^>nul
  echo powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Invoke-RestMethod -Uri 'http://127.0.0.1:8787/health' -TimeoutSec 1 ^| Out-Null; exit 0 } catch { exit 1 }"
  echo if errorlevel 1 start "Capitan Rodolfo SQL Bridge" /min cmd /c "cd /d "%%ROOT%%" ^&^& py bridge.py"
  echo exit /b 0
)

echo [3/4] Registrando protocolo capitanrodolfo:// ...
reg add "HKCU\Software\Classes\capitanrodolfo" /ve /d "URL:Capitan Rodolfo Protocol" /f >nul
reg add "HKCU\Software\Classes\capitanrodolfo" /v "URL Protocol" /d "" /f >nul
reg add "HKCU\Software\Classes\capitanrodolfo\shell\open\command" /ve /d "\"%ROOT%\launch.cmd\" \"%%1\"" /f >nul
if errorlevel 1 goto :error

echo [4/4] Instalando dependencias e iniciando...
py -m pip install -r "%ROOT%\requirements.txt"
if errorlevel 1 goto :error
call "%ROOT%\launch.cmd"

echo.
echo INSTALACION COMPLETA.
echo Desde ahora, la pagina puede iniciar el bridge con capitanrodolfo://start
echo.
start "" "https://duiliomf.github.io/capitan-rodolfo/conexion-sql.html"
timeout /t 3 >nul
exit /b 0

:error
echo.
echo ERROR durante la instalacion.
pause
exit /b 1
