@echo off
setlocal
chcp 65001 >nul
title Capitán Rodolfo - Prueba REAL de Cobros en SiSRL
echo.
echo =========================================================
echo       PRUEBA REAL DE COBROS - SISRL - ESTACION 1
echo =========================================================
echo.
echo Este diagnóstico NO modifica SQL ni comparte los cobros.
echo Utiliza el servicio local instalado en esta computadora.
echo.
set "FILE=%TEMP%\verificar_cobros_sisrl.ps1"
set "RAW=https://raw.githubusercontent.com/DuilioMF/capitan-rodolfo/main/diagnostico/verificar_cobros_sisrl.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; Invoke-WebRequest -UseBasicParsing '%RAW%?v=%RANDOM%' -OutFile '%FILE%'" 
if errorlevel 1 (
  echo ERROR: No se pudo descargar el diagnóstico de tu repositorio.
  echo Verificá Internet e intentá de nuevo.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%FILE%" -Estacion 1
set "EXIT=%ERRORLEVEL%"
echo.
if "%EXIT%"=="0" echo LISTO: prueba de cobros local satisfactoria.
if "%EXIT%"=="2" echo PARCIAL: SQL respondió, revisar comprobantes en el reporte.
if not "%EXIT%"=="0" if not "%EXIT%"=="2" echo BLOQUEADO: el diagnóstico muestra el motivo.
echo.
echo Sacá una captura del resultado y mandámela por este chat.
pause
exit /b %EXIT%
