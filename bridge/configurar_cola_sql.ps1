# Ejecutar desde la MISMA cuenta de Windows que inicia CapitanRodolfoSqlQueue.
# No escribe el token en texto plano: usa proteccion DPAPI del usuario.
$ErrorActionPreference = 'Stop'
$root = 'C:\Sistemas\DoingLio\data\capitan'
New-Item -ItemType Directory -Path $root -Force | Out-Null
Write-Host 'Pegá el valor de DOINGLIO_SQL_WORKER_TOKEN que configuraste en Supabase.'
Write-Host 'No lo compartas por WhatsApp ni lo guardes en GitHub.'
$secure = Read-Host 'Token privado del conector' -AsSecureString
$encrypted = ConvertFrom-SecureString $secure
if([string]::IsNullOrWhiteSpace($encrypted)) { throw 'Token vacío' }
[IO.File]::WriteAllText((Join-Path $root 'sql_queue_token.dat'),$encrypted,[Text.Encoding]::UTF8)
Write-Host 'Token guardado de forma cifrada para este usuario Windows.'
Write-Host 'Reiniciá la tarea programada CapitanRodolfoSqlQueue o el lanzador Capitán.'
