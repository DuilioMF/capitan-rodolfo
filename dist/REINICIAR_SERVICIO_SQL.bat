@echo off
setlocal
echo Reiniciando Capitán con el instalador canónico para conservar una sola conexión SQL...
call "%~dp0CAPITAN_RODOLFO.bat"
exit /b %errorlevel%
