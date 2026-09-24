@echo off
setlocal EnableExtensions
title Reparar Capitan Rodolfo v82

for %%I in ("%~dp0.") do set "APPROOT=%%~fI"
set "RAW=https://raw.githubusercontent.com/DuilioMF/capitan-rodolfo/main"

echo.
echo ==========================================
echo   REPARAR CAPITAN RODOLFO
echo ==========================================
echo.
echo Carpeta: %APPROOT%
echo.
echo Se conservaran:
echo   - sql_profile.json
echo   - openai_key.dat
echo   - logs
echo   - configuracion local
echo.

if not exist "%APPROOT%\bridge" mkdir "%APPROOT%\bridge" >nul 2>nul

echo [1/4] Cerrando solo el proceso que ocupa el puerto 8787...
for /f "tokens=5" %%P in ('netstat -ano ^| findstr /R /C:":8787 .*LISTENING"') do taskkill /PID %%P /F >nul 2>nul
schtasks /End /TN "CapitanRodolfoLocal" >nul 2>nul

echo [2/4] Bajando archivos actuales desde GitHub...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; Invoke-WebRequest -UseBasicParsing '%RAW%/INICIAR_CAPITAN_RODOLFO.bat' -OutFile '%APPROOT%\INICIAR_CAPITAN_RODOLFO.bat'; Invoke-WebRequest -UseBasicParsing '%RAW%/CAPITAN_RODOLFO.bat' -OutFile '%APPROOT%\CAPITAN_RODOLFO.bat'; Invoke-WebRequest -UseBasicParsing '%RAW%/bridge/capitan_rodolfo_local.ps1' -OutFile '%APPROOT%\bridge\capitan_rodolfo_local.ps1'; Invoke-WebRequest -UseBasicParsing '%RAW%/VERSION' -OutFile '%APPROOT%\VERSION'"
if errorlevel 1 goto :error

echo [3/4] Verificando version...
set "V="
for /f "usebackq delims=" %%V in ("%APPROOT%\VERSION") do if not defined V set "V=%%V"
if not "%V%"=="82" (
  echo ERROR: esperaba VERSION 82 y llego "%V%".
  goto :error
)

echo [4/4] Iniciando Capitan Rodolfo v82...
start "" "%APPROOT%\INICIAR_CAPITAN_RODOLFO.bat"

echo.
echo OK. Capitan Rodolfo v82 fue reparado e iniciado.
echo Esta ventana se cerrara sola.
timeout /t 2 >nul
exit /b 0

:error
echo.
echo NO SE PUDO REPARAR.
echo No se borraron tus archivos de configuracion SQL.
pause
exit /b 1
