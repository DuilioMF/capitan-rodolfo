@echo off
title DoingLio SQL Bridge v16
cd /d "%~dp0"
echo.
echo ============================================
echo  DoingLio SQL Bridge v16
echo  SQL Server: DUILIO\SQLEXPRESS
echo ============================================
echo.
py -m pip install -r requirements.txt
if errorlevel 1 (
  echo.
  echo ERROR instalando dependencias.
  pause
  exit /b 1
)
echo.
echo Bridge disponible en http://127.0.0.1:8787
echo Deje esta ventana abierta mientras use la conexion SQL.
echo.
py bridge.py
pause
