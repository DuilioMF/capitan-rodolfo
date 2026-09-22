@echo off
setlocal
title Capitán Rodolfo - SQL Bridge v19

set "ROOT=%LOCALAPPDATA%\CapitanRodolfoBridge"
set "BASE=https://raw.githubusercontent.com/DuilioMF/capitan-rodolfo/main/bridge"
set "WEB=https://duiliomf.github.io/capitan-rodolfo/conexion-sql.html"

echo.
echo ==============================================
echo   CAPITAN RODOLFO - CONEXION SQL v19
echo ==============================================
echo.

if not exist "%ROOT%" mkdir "%ROOT%"

echo [1/4] Actualizando bridge desde GitHub...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "Invoke-WebRequest -UseBasicParsing '%BASE%/bridge.py' -OutFile '%ROOT%\bridge.py'; Invoke-WebRequest -UseBasicParsing '%BASE%/requirements.txt' -OutFile '%ROOT%\requirements.txt'"
if errorlevel 1 (
  echo.
  echo ERROR: no se pudo descargar el bridge desde GitHub.
  pause
  exit /b 1
)

echo [2/4] Instalando dependencias...
py -m pip install -r "%ROOT%\requirements.txt"
if errorlevel 1 (
  echo.
  echo ERROR: no se pudieron instalar las dependencias de Python.
  echo Verifica que Python este instalado y que el comando "py" funcione.
  pause
  exit /b 1
)

echo [3/4] Iniciando bridge local en 127.0.0.1:8787...
start "Capitan Rodolfo SQL Bridge v19" cmd /k "cd /d "%ROOT%" && py bridge.py"

echo [4/4] Esperando bridge...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ok=$false; 1..15 | %% { try { $r=Invoke-RestMethod -Uri 'http://127.0.0.1:8787/health' -TimeoutSec 1; if($r.ok){$ok=$true; break} } catch {}; Start-Sleep -Seconds 1 }; if(-not $ok){exit 1}"
if errorlevel 1 (
  echo.
  echo El bridge no respondio a tiempo.
  echo Mira la ventana "Capitan Rodolfo SQL Bridge v19" para ver el error.
  pause
  exit /b 1
)

echo.
echo Bridge OK. Abriendo Capitán Rodolfo...
start "" "%WEB%"

echo.
echo LISTO. Deja abierta la ventana del bridge mientras uses SQL.
timeout /t 3 >nul
exit /b 0

