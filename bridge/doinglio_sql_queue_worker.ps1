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
      if([string]$job.intent -notin @("station_circuit","latest_dispatch","today_dispatches") -or [int]$job.idEstacion -le 0){
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
        if([string]$job.intent -eq "today_dispatches"){
          $date=[string]$job.fecha
          if($date -notmatch '^\d{4}-\d{2}-\d{2}$'){throw "La fecha del pedido no es valida"}
          $body=@{idEstacion=[int]$job.idEstacion;fecha=$date}|ConvertTo-Json -Compress
          $daily=Invoke-RestMethod -Uri ($base+"/api/station/today-dispatches") -Method POST -Body $body -ContentType "application/json" -TimeoutSec 55
          if(-not $daily.connected -or [string]$daily.fecha -ne $date){throw "SQL no confirmo fecha y conexion"}
          $count=[long]$daily.total
          $reply="Capitán Rodolfo: estación $($job.idEstacion), fecha $date. $count despachos registrados en SQL Server."
          if($count -gt 0){
            $rows=New-Object System.Collections.Generic.List[string]
            foreach($d in @($daily.lastFive)){
              if($null -eq $d){continue}
              $parts=New-Object System.Collections.Generic.List[string]
              if($null -ne $d.IdSale){$parts.Add("venta "+[string]$d.IdSale)}
              if($null -ne $d.ID_DESPACHO){$parts.Add("despacho "+[string]$d.ID_DESPACHO)}
              if($null -ne $d.ULTIME){$parts.Add("hora "+[string]$d.ULTIME)}
              if($null -ne $d.LITROS){$parts.Add("litros "+[string]$d.LITROS)}
              if($null -ne $d.PESOS){$parts.Add("importe "+[string]$d.PESOS)}
              if($parts.Count){$rows.Add($parts -join ', ')}
            }
            if($rows.Count){$reply+=" Últimos "+$rows.Count+" registros: "+($rows -join '; ')+'.'}
          }
          $meta=@{idEstacion=[int]$job.idEstacion;fecha=$date;dispatches=$count;source="dbo.Despachos"}
          Api $token @{action="complete";id=$job.id;ok=$true;reply_text=$reply;summary=$meta}|Out-Null
          Log ("Despachos por fecha consultados: "+$job.id)
          continue
        }
        if([string]$job.intent -eq "latest_dispatch"){
          # Misma consulta verificada que muestra "Carga" en Capitan V92:
          # /api/station/circuit ejecuta PA_CapitanRodolfo_CircuitoEstacion
          # filtrado por el dia real y estacion. Nunca usar TOP historico alternativo.
          $circuit=Invoke-RestMethod -Uri ($base+"/api/station/circuit") -Method POST -Body $payload -ContentType "application/json" -TimeoutSec 55
          if(-not $circuit.connected -or -not $circuit.verified -or [string]$circuit.source -ne "sp" -or
             [int]$circuit.station -ne [int]$job.idEstacion -or
             [string]$circuit.procedure -ne "dbo.PA_CapitanRodolfo_CircuitoEstacion" -or
             [string]::IsNullOrWhiteSpace([string]$circuit.fecha)){
            throw "El circuito de Capitan no confirmo origen SP, fecha y estacion"
          }
          if($null -eq $circuit.dispatches -or $null -eq $circuit.dispatches.rows -or $circuit.dispatches.truncated){
            throw "El circuito de Capitan no devolvio despachos completos"
          }
          $records=@($circuit.dispatches.rows | Where-Object {$null -ne $_})
          foreach($row in $records){
            if([int]$row.IdEstacion -ne [int]$job.idEstacion -or
               -not ([string]$row.FechaDespacho).StartsWith([string]$circuit.fecha)){
              throw "La respuesta de SQL no coincide con fecha y estacion"
            }
          }
          # El SP de la pantalla ya devuelve despachos ordenados por hora e ID_SALE.
          $reply="Capitan Rodolfo - estacion $($job.idEstacion), fecha $($circuit.fecha). "
          if(-not $records.Count){
            $reply+="No hay despachos en el circuito verificado de esta fecha."
          } else {
            $limit=[Math]::Min(5,$records.Count)
            $reply+="Ultimos $limit de $($records.Count) despachos del mismo circuito que muestra Capitan: "
            $details=New-Object System.Collections.Generic.List[string]
            foreach($d in @($records | Select-Object -First 5)){
              $parts=New-Object System.Collections.Generic.List[string]
              if($null -ne $d.IdSale){$parts.Add("venta "+[string]$d.IdSale)}
              if($null -ne $d.IdDespacho){$parts.Add("despacho "+[string]$d.IdDespacho)}
              if($d.Hora){$parts.Add("hora "+[string]$d.Hora)}
              if($null -ne $d.Cara){$parts.Add("cara "+[string]$d.Cara)}
              if($null -ne $d.Litros){$parts.Add("litros "+[string]$d.Litros)}
              if($null -ne $d.Pesos){$parts.Add("importe "+[string]$d.Pesos)}
              if($null -ne $d.EstadoVta){$parts.Add("estado "+[string]$d.EstadoVta)}
              $details.Add(($parts -join ", "))
            }
            $reply+=($details -join "; ")+"."
          }
          Api $token @{action="complete";id=$job.id;ok=$true;reply_text=$reply;summary=@{idEstacion=[int]$job.idEstacion;fecha=[string]$circuit.fecha;source="dbo.PA_CapitanRodolfo_CircuitoEstacion"}} | Out-Null
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
        # Guardar diagnostico en la PC, sin enviar detalles internos por WhatsApp.
        $httpStatus=""
        try {if($null -ne $_.Exception.Response){$httpStatus=[string][int]$_.Exception.Response.StatusCode}}catch{}
        $errorType=[string]$_.Exception.GetType().Name
        $safeDetail=([string]$_.Exception.Message -replace '(?i)(password|token|authorization|secret|key)\s*[:=]\s*[^\s,;}]+','$1=[REDACTED]')
        if($safeDetail.Length -gt 500){$safeDetail=$safeDetail.Substring(0,500)}
        Log ("Consulta fallida: "+$job.id+"; intent="+$job.intent+"; station="+$job.idEstacion+"; bridge="+$base+"; http="+$httpStatus+"; type="+$errorType+"; detail="+$safeDetail)
        $reply=if($httpStatus){"La consulta SQL fallo (HTTP "+$httpStatus+"). Revisá Núcleo - Datos."}else{"La consulta SQL fallo. Revisá Núcleo - Datos."}
        try{Api $token @{action="complete";id=$job.id;ok=$false;reply_text=$reply} | Out-Null}catch{Log ("No se pudo registrar fallo en la cola: "+$job.id)}
      }
    } catch {
      Log "Error de conexión con la cola. Nuevo intento posterior."
      Start-Sleep -Seconds 20
    }
  }
} finally {if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}
