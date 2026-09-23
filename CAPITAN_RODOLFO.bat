@echo off
setlocal EnableExtensions EnableDelayedExpansion

for %%I in ("%~dp0.") do set "APPROOT=%%~fI"
set "OLDROOT=%LOCALAPPDATA%\CapitanRodolfo"
set "LOCALPS=%APPROOT%\capitan_rodolfo_local.ps1"
set "VERSION_FILE=%APPROOT%\VERSION"
set "LOGDIR=%APPROOT%\logs"
set "VERSION_REMOTE=https://raw.githubusercontent.com/DuilioMF/capitan-rodolfo/main/VERSION"
set "REMOTE=https://raw.githubusercontent.com/DuilioMF/capitan-rodolfo/main/bridge/capitan_rodolfo_local.ps1"
set "HEALTH=http://127.0.0.1:8787/health"
set "WEBURL=http://127.0.0.1:8787/"
set "TASKNAME=CapitanRodolfoLocal"

if not exist "C:\Sistemas" mkdir "C:\Sistemas" >nul 2>nul
if not exist "%APPROOT%" mkdir "%APPROOT%" >nul 2>nul

if not exist "%APPROOT%" (
  echo.
  echo   Necesito crear %APPROOT%
  echo   Windows va a pedir permiso de administrador una sola vez.
  echo.
  powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

if not exist "%LOGDIR%" mkdir "%LOGDIR%" >nul 2>nul

rem La conexión SQL local se conserva cifrada para reutilizarla en el próximo inicio.
if not exist "%APPROOT%\VERSION" if exist "%OLDROOT%\VERSION" copy /Y "%OLDROOT%\VERSION" "%APPROOT%\VERSION" >nul

echo.
echo ============================================================
echo                  CAPITAN RODOLFO
echo ============================================================
echo.
echo   Carpeta local: %APPROOT%
echo   Preparando conector SQL...
echo.

echo   [1/5] Leyendo version actual...
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { $v=(New-Object Net.WebClient).DownloadString('%VERSION_REMOTE%').Trim(); if(-not $v){throw 'VERSION vacia'}; [IO.File]::WriteAllText('%VERSION_FILE%',$v,[Text.Encoding]::ASCII); exit 0 } catch { Write-Host $_.Exception.Message; exit 1 }"
if errorlevel 1 goto :fatal

set "APP_VERSION="
for /f "usebackq delims=" %%V in ("%VERSION_FILE%") do if not defined APP_VERSION set "APP_VERSION=%%V"
if not defined APP_VERSION goto :fatal

title Capitan Rodolfo v!APP_VERSION!
echo   Version objetivo: v!APP_VERSION!
echo.

echo   [2/5] Cerrando conectores anteriores...
schtasks /End /TN "%TASKNAME%" >nul 2>nul
for /f "tokens=5" %%P in ('netstat -ano ^| findstr /R /C:":8787 .*LISTENING"') do taskkill /PID %%P /F >nul 2>nul
timeout /t 1 >nul

echo   [3/5] Descargando conector...
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { $wc=New-Object Net.WebClient; $b=$wc.DownloadData('%REMOTE%'); if($b.Length -ge 3 -and $b[0] -eq 239 -and $b[1] -eq 187 -and $b[2] -eq 191){ [IO.File]::WriteAllBytes('%LOCALPS%',$b) } else { $bom=[byte[]](239,187,191); [IO.File]::WriteAllBytes('%LOCALPS%',$bom+$b) }; exit 0 } catch { Write-Host $_.Exception.Message; exit 1 }"
if errorlevel 1 goto :fatal

echo   [4/5] Configurando arranque automatico...
schtasks /Delete /F /TN "%TASKNAME%" >nul 2>nul
schtasks /Create /F /SC ONLOGON /RL LIMITED /TN "%TASKNAME%" /TR "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"%LOCALPS%\" -AppDir \"%APPROOT%\"" >nul 2>nul

echo   [5/5] Iniciando conector v!APP_VERSION!...
start "Capitan Rodolfo Local" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%LOCALPS%" -AppDir "%APPROOT%"

set "OK=0"
for /L %%I in (1,1,20) do (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "try { $r=Invoke-RestMethod -Uri '%HEALTH%' -TimeoutSec 1; if([string]$r.version -eq '!APP_VERSION!'){exit 0}else{exit 1} } catch { exit 1 }"
  if not errorlevel 1 (
    set "OK=1"
    goto :ready
  )
  timeout /t 1 >nul
)

:ready
if "!OK!"=="1" (
  echo.
  echo   Conector local v!APP_VERSION! OK.
  echo   Archivos locales en: %APPROOT%
  echo   Abriendo Capitan Rodolfo...
  start "" "%WEBURL%"
  timeout /t 2 >nul
  exit /b 0
)

:fatal
color 0C
echo.
echo ============================================================
echo   No se pudo iniciar o actualizar Capitan Rodolfo.
echo ============================================================
echo.
echo   Carpeta: %APPROOT%
echo   Mandame esta pantalla.
pause
exit /b 1
