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
  # Preferir el conector conectado más nuevo si conviven versiones antiguas.
  $best="";$bestVersion=-1
  foreach($p in @(8787,8797,18787,27877,37877,48787,57877)){
    try {
      $health=Invoke-RestMethod -Uri ("http://127.0.0.1:"+$p+"/health") -TimeoutSec 1
      if(-not $health.ok -or -not $health.connected){continue}
      $v=0;[int]::TryParse([string]$health.version,[ref]$v)|Out-Null
      if($v -gt $bestVersion){$best="http://127.0.0.1:$p";$bestVersion=$v}
    } catch {}
  }
  return $best
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
      if([string]$job.intent -notin @("station_circuit","latest_dispatch") -or [int]$job.idEstacion -le 0){
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
        if([string]$job.intent -eq "latest_dispatch"){
          $latest=Invoke-RestMethod -Uri ($base+"/api/station/latest-dispatch") -Method POST -Body $payload -ContentType "application/json" -TimeoutSec 45
          if(-not $latest.connected){throw "SQL no confirmo la conexion"}
          $d=$latest.dispatch
          $reply="Capitan Rodolfo - estacion $($job.idEstacion). "
          if($null -eq $d){
            $reply+="No hay despachos registrados para esta estacion en la base consultada."
          }else{
            $details=New-Object System.Collections.Generic.List[string]
            if($null -ne $d.IdSale){$details.Add("venta "+[string]$d.IdSale)}
            if($null -ne $d.IdDespacho){$details.Add("despacho "+[string]$d.IdDespacho)}
            if($d.FechaDespacho){$details.Add("fecha "+[string]$d.FechaDespacho)}
            if($d.Hora){$details.Add("hora "+[string]$d.Hora)}
            if($null -ne $d.Cara){$details.Add("cara "+[string]$d.Cara)}
            if($null -ne $d.Manguera){$details.Add("manguera "+[string]$d.Manguera)}
            if($d.CodArt){$details.Add("articulo "+[string]$d.CodArt)}
            if($null -ne $d.Litros){$details.Add("litros "+[string]$d.Litros)}
            if($null -ne $d.Pesos){$details.Add("importe "+[string]$d.Pesos)}
            if($null -ne $d.EstadoVta){$details.Add("estado de venta "+[string]$d.EstadoVta)}
            $reply+="Ultimo despacho segun fecha y hora de SQL: "+($details -join ", ")+"."
          }
          Api $token @{action="complete";id=$job.id;ok=$true;reply_text=$reply;summary=@{idEstacion=[int]$job.idEstacion;source="dbo.Despachos"}} | Out-Null
          Log ("Ultimo despacho consultado: "+$job.id)
          continue
        }
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
