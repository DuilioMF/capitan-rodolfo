@echo off
setlocal
rem DoingLio ya descarga los archivos. Este acceso instala/actualiza y arranca el servicio SQL actual.
call "%~dp0CAPITAN_RODOLFO.bat"
exit /b %errorlevel%
