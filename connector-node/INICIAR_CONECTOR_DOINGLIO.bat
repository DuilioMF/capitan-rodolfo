@echo off
title Capitán Rodolfo - Conexión SQL única
echo.
echo Este conector Node fue retirado en C97.
echo Capitán usa una sola conexión SQL guardada por CAPITAN_RODOLFO.bat.
echo.
if exist "%~dp0..\CAPITAN_RODOLFO.bat" (
  call "%~dp0..\CAPITAN_RODOLFO.bat"
  exit /b %errorlevel%
)
echo No se encontro CAPITAN_RODOLFO.bat en la carpeta superior.
echo Descargalo desde Nucleo - Datos.
pause
exit /b 1
