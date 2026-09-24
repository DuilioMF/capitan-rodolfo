
# Optional DoingLio WhatsApp worker using the existing Capitán Rodolfo local bridge.
# No arbitrary SQL; only the existing read-only station/circuit endpoint.
param([switch]$Configure,[switch]$DryRun,[switch]$Once,[switch]$InstallTask,[int]$PollSeconds=10)
$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
$dir='C:\Sistemas\DoingLio\data\capitan'
$keyFile=Join-Path $dir 'doinglio_wa_bridge_token.dat'
$statusFile=Join-Path $dir 'estado.json'
$gateway='https://pddsehshgfynpmibjqhj.supabase.co/functions/v1/doinglio-bridge-queue'
if(-not(Test-Path $dir)){New-Item -Path $dir -ItemType Directory -Force | Out-Null}
function Get-Token {
 if(-not(Test-Path $keyFile)){throw 'Falta configurar la clave privada con -Configure en la misma cuenta de Windows.'}
 $secret=(Get-Content -Path $keyFile -Raw).Trim() | ConvertTo-SecureString
 $ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($secret)
 try{return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)}
 finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)}
}
function Call-Cloud([hashtable]$body,[string]$token) {
 return Invoke-RestMethod -Uri $gateway -Method POST -Headers @{'x-doinglio-bridge-key'=$token} -ContentType 'application/json' -Body ($body | ConvertTo-Json -Depth 8 -Compress) -TimeoutSec 20
}
function Get-Bridge {
 if(-not(Test-Path $statusFile)){throw 'El conector local no ha creado estado.json.'}
 $status=Get-Content -Path $statusFile -Raw | ConvertFrom-Json
 $port=0
 if(-not([int]::TryParse([string]$status.port,[ref]$port)) -or $port -lt 1 -or $port -gt 65535){throw 'Puerto local invalido.'}
 $base='http://127.0.0.1:'+ $port
 $health=Invoke-RestMethod -Uri ($base+'/health') -Method GET -TimeoutSec 10
 if($health.connected -ne $true -or [string]$health.database -cne 'SiSRL'){throw 'Falta conectar SiSRL en Nucleo Datos.'}
 return $base
}
function Get-LocalStations([string]$base) {
 $res=Invoke-RestMethod -Uri ($base+'/api/station/ids') -Method GET -TimeoutSec 20
 if($res.connected -ne $true){throw 'No se pudo leer estaciones locales.'}
 return @($res.stations | ForEach-Object {[int]$_} | Sort-Object -Unique)
}
if($Configure) {
 $inputSecret=Read-Host 'Clave privada del trabajador DoingLio' -AsSecureString
 if($null -eq $inputSecret){throw 'Clave requerida.'}
 ConvertFrom-SecureString $inputSecret | Set-Content -Path $keyFile -Encoding ASCII
 Write-Host 'Clave protegida por el usuario actual de Windows.'
 exit 0
}
if($InstallTask) {
 if(-not(Test-Path $keyFile)){throw 'Configura el token antes de registrar la tarea.'}
 $file=$MyInvocation.MyCommand.Path
 $command='powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$file+'"'
 & schtasks.exe /Create /F /SC ONLOGON /RL LIMITED /TN 'CapitanRodolfoWhatsApp' /TR $command | Out-Null
 if($LASTEXITCODE -ne 0){throw 'Windows rechazo crear la tarea.'}
 Write-Host 'Tarea registrada. Se iniciara con el mismo usuario de Windows.'
 exit 0
}
if($DryRun) {
 $base=Get-Bridge
 $stations=@(Get-LocalStations $base)
 Write-Host ('Conector existente OK; estaciones reales: '+($stations -join ', '))
 exit 0
}
$token=Get-Token
if($PollSeconds -lt 5){$PollSeconds=5}
do {
 try {
  $base=Get-Bridge
  $localIds=@(Get-LocalStations $base)
  if($localIds.Count -eq 0){throw 'No hay estaciones autorizadas en la base local.'}
  $claim=Call-Cloud @{action='claim'} $token
  $job=$claim.job
  if($null -ne $job) {
   if([string]$job.specialist_key -ne 'capitan-rodolfo' -or [string]$job.intent -ne 'list_tanks'){throw 'Consulta fuera de la lista autorizada.'}
   if($job.can_select_any_station -eq $true){$allowed=@($localIds)}
   else{$allowed=@($job.allowed_station_ids | ForEach-Object {[int]$_} | Where-Object {$localIds -contains $_} | Sort-Object -Unique)}
   if($allowed.Count -eq 0){throw 'Esta suscripcion no tiene estaciones autorizadas en SiSRL.'}
   $parts=@()
   $sum=0
   foreach($station in $allowed) {
    $json=@{idEstacion=[int]$station} | ConvertTo-Json -Compress
    $circuit=Invoke-RestMethod -Uri ($base+'/api/station/circuit') -Method POST -Body $json -ContentType 'application/json' -TimeoutSec 90
    if($circuit.connected -ne $true -or $null -eq $circuit.tanks -or $null -eq $circuit.tanks.rows){throw 'El SQL local no devolvio tanques comprobables.'}
    if($circuit.tanks.truncated -eq $true){throw 'Datos de tanques truncados: no informar un total incompleto.'}
    $qty=@($circuit.tanks.rows).Count
    $parts+=('Estacion '+$station+': '+$qty+' tanques')
    $sum+=$qty
   }
   $response='Capitan Rodolfo, datos de SiSRL: '+($parts -join '; ')+'. Total: '+$sum+' tanques.'
   $result=Call-Cloud @{action='complete';job_id=[string]$job.id;station_ids=@($allowed);response_text=$response;success=$true} $token
   if($result.accepted -ne $true){Write-Warning 'El permiso pudo ser revocado antes de completar la consulta.'}
  }
 } catch {
   # No revelar token, SQL, texto del usuario ni respuesta en logs.
   Write-Warning ('Trabajador no disponible: '+$_.Exception.GetType().Name)
 }
 if($Once){break}
 Start-Sleep -Seconds $PollSeconds
} while($true)
