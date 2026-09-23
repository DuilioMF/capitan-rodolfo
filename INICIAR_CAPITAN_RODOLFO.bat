@echo off
setlocal
rem Lanzador actual: usa PowerShell/.NET oculto. No usa Python y no deja DOS abierto.
call "%~dp0CAPITAN_RODOLFO.bat"
exit /b %errorlevel%
