@echo off
setlocal
set "STATUS=%~dp0servicio_sql_estado.json"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try { $h=Invoke-RestMethod -Uri 'http://127.0.0.1:8787/health' -TimeoutSec 3; $p=Invoke-RestMethod -Uri 'http://127.0.0.1:8787/api/profile-status' -TimeoutSec 3; $o=[ordered]@{service='Capitan Rodolfo SQL';serviceActive=$true;version=$h.version;port=8787;connected=$h.connected;database=$h.database;server=$p.server;user=$p.user;profileSaved=$p.saved;hasProtectedPassword=$p.hasPassword;checkedAt=(Get-Date).ToString('o')}; $o|ConvertTo-Json|Set-Content -Encoding UTF8 '%STATUS%' } catch { @{service='Capitan Rodolfo SQL';serviceActive=$false;error=$_.Exception.Message;checkedAt=(Get-Date).ToString('o')}|ConvertTo-Json|Set-Content -Encoding UTF8 '%STATUS%' }"
start "" notepad.exe "%STATUS%"
exit /b 0
