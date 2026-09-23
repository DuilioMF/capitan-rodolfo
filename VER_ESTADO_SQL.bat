@echo off
setlocal
set "STATUS=%~dp0servicio_sql_estado.json"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "try { $d=Invoke-RestMethod -Uri 'http://127.0.0.1:8787/api/service-status' -TimeoutSec 3; $d | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 '%STATUS%' } catch { @{serviceActive=$false;error=$_.Exception.Message;checkedAt=(Get-Date).ToString('o')} | ConvertTo-Json | Set-Content -Encoding UTF8 '%STATUS%' }"
start "" notepad.exe "%STATUS%"
exit /b 0
