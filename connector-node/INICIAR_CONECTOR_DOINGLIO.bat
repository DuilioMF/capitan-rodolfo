@echo off
title Conector SQL de DoingLio
cd /d "%~dp0"
where node >nul 2>nul
if errorlevel 1 (
  echo Falta Node.js. Instala Node.js 20 o superior y volve a abrir este archivo.
  pause
  exit /b 1
)
if not exist node_modules (
  echo Preparando el conector por unica vez...
  call npm install --omit=dev
  if errorlevel 1 (
    echo No se pudo preparar el conector.
    pause
    exit /b 1
  )
)
echo.
echo Conector SQL de DoingLio iniciado.
echo Deja esta ventana abierta mientras uses Capitan Rodolfo.
echo.
call npm start
pause

