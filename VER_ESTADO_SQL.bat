@echo off
setlocal
set "STATUS=%~dp0servicio_sql_estado.json"
set "PORT="
for /f "delims=" %%P in ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0bridge\detectar_puerto.ps1"') do set "PORT=%%P"
if not defined PORT (
  powershell.exe -NoProfile -Command "@{service='Capitan Rodolfo SQL';serviceActive=$false;error='No se encontró el conector activo';checkedAt=(Get-Date).ToString('o')}|ConvertTo-Json|Set-Content -Encoding UTF8 '%STATUS%'"
  start "" notepad.exe "%STATUS%"
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try { $base='http://127.0.0.1:%PORT%'; $h=Invoke-RestMethod -Uri ($base+'/health') -TimeoutSec 3; $p=Invoke-RestMethod -Uri ($base+'/api/profile-status') -TimeoutSec 3; $o=[ordered]@{service='Capitan Rodolfo SQL';serviceActive=$true;version=$h.version;port=%PORT%;connected=$h.connected;database=$h.database;server=$p.server;user=$p.user;profileSaved=$p.saved;hasProtectedPassword=$p.hasPassword;checkedAt=(Get-Date).ToString('o')}; $o|ConvertTo-Json|Set-Content -Encoding UTF8 '%STATUS%' } catch { @{service='Capitan Rodolfo SQL';serviceActive=$false;error=$_.Exception.Message;checkedAt=(Get-Date).ToString('o')}|ConvertTo-Json|Set-Content -Encoding UTF8 '%STATUS%' }"
start "" notepad.exe "%STATUS%"
exit /b 0
