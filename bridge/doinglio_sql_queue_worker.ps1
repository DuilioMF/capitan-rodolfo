param(
 [string]$DataRoot = "C:\Sistemas\DoingLio\data\capitan",
 [string]$QueueUrl = "https://pddsehshgfynpmibjqhj.supabase.co/functions/v1/doinglio-sql-queue"
)
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if(-not (Test-Path $DataRoot)){New-Item -ItemType Directory -Path $DataRoot -Force | Out-Null}
$tokenPath = Join-Path $DataRoot "sql_queue_token.dat"
$logPath = Join-Path $DataRoot "sql_queue_worker.log"
$mutex = New-Object System.Threading.Mutex($false,"Local\DoingLioCapitanSqlQueueWorker")
$locked = $false
try { $locked = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $locked = $true }
if(-not $locked) { exit 0 }
function Log([string]$event){
  try {
    if ((Test-Path $logPath) -and (Get-Item $logPath).Length -gt 1048576) { Move-Item $logPath "$logPath.old" -Force }
    Add-Content -Path $logPath -Value ("["+(Get-Date).ToString("s")+"] "+$event)
  } catch {}
}
function Read-Token {
  if(-not (Test-Path $tokenPath)){return ""}
  try {
    $secure = ConvertTo-SecureString ((Get-Content $tokenPath -Raw).Trim())
    $ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)}
    finally {[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)}
  } catch {return ""}
}
function Api([string]$token,[hashtable]$body){
  $json = ConvertTo-Json $body -Depth 7 -Compress
  return Invoke-RestMethod -Uri $QueueUrl -Method POST -Headers @{"x-doinglio-token"=$token} -Body $json -ContentType "application/json" -TimeoutSec 15
}
function Local-Bridge {
  foreach($p in @(8787,8797,18787,27877,37877,48787,57877)){
    try {
      $health = Invoke-RestMethod -Uri ("http://127.0.0.1:"+$p+"/health") -TimeoutSec 1
      if($health.ok) { return ("http://127.0.0.1:"+$p) }
    } catch {}
  }
  return ""
}
function Set-Count($value) {
  if($null -eq $value){return 0}
  if($value -is [array]){return $value.Count}
  if($value.PSObject.Properties.Name -contains "rows"){return @($value.rows).Count}
  if($value.PSObject.Properties.Name -contains "resultSets"){return @($value.resultSets).Count}
  return 0
}
Log "Worker iniciado (consulta saliente Supabase; SQL no expuesto)"
try {
  while($true){
    $token=Read-Token
    if([string]::IsNullOrWhiteSpace($token)){Start-Sleep -Seconds 30;continue}
    try {
      $response=Api $token @{action="claim"}
      $job=$response.job
      if($null -eq $job){Start-Sleep -Seconds 8;continue}
      if([string]$job.intent -ne "station_circuit" -or [int]$job.idEstacion -le 0){
        Api $token @{action="complete";id=$job.id;ok=$false;reply_text="Operación no permitida."} | Out-Null
        continue
      }
      $base=Local-Bridge
      if(-not $base){
        Api $token @{action="complete";id=$job.id;ok=$false;reply_text="El conector local no está disponible. Revisá Núcleo → Datos."} | Out-Null
        continue
      }
      try {
        $payload=@{idEstacion=[int]$job.idEstacion} | ConvertTo-Json -Compress
        $result=Invoke-RestMethod -Uri ($base+"/api/station/circuit") -Method POST -Body $payload -ContentType "application/json" -TimeoutSec 50
        if(-not $result.connected){throw "SQL no confirmó conexión"}
        $tc=Set-Count $result.tanks
        $hc=Set-Count $result.hoses
        $dc=Set-Count $result.dispatches
        $rc=Set-Count $result.receipts
        $summary=@{idEstacion=[int]$job.idEstacion;tanks=$tc;hoses=$hc;dispatches=$dc;receipts=$rc;source=[string]$result.source}
        $reply="Capitán Rodolfo - estación $($job.idEstacion): tanques $tc, mangueras $hc, despachos $dc, comprobantes $rc. Datos obtenidos de SQL Server."
        Api $token @{action="complete";id=$job.id;ok=$true;reply_text=$reply;summary=$summary} | Out-Null
        Log ("Consulta completada: "+$job.id)
      } catch {
        try{Api $token @{action="complete";id=$job.id;ok=$false;reply_text="No se pudo consultar SQL. Revisá la conexión y los permisos del circuito."} | Out-Null}catch{}
        Log ("Consulta fallida: "+$job.id)
      }
    } catch {
      Log "Error de conexión con la cola. Nuevo intento posterior."
      Start-Sleep -Seconds 20
    }
  }
} finally {if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}
