# Conexion de Nucleos v1: token del trabajador protegido en esta PC.
# Nunca envia credenciales SQL ni expone tokens al navegador.
function Get-DoingLioCoreWorkerToken {
  param([string]$Root)
  $path=Join-Path $Root 'sql_queue_token.dat'
  if(-not (Test-Path $path)){throw 'El servicio de DoingLio no tiene su token instalado.'}
  $raw=(Get-Content $path -Raw).Trim()
  $secure=ConvertTo-SecureString $raw
  $ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
  try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}
function Get-DoingLioCoreStatus {
  param([string]$Root,[bool]$SqlConnected,[string]$Database,[int[]]$Stations)
  $path=Join-Path $Root 'doinglio_core_link.json'
  $saved=$null
  if(Test-Path $path){try{$saved=Get-Content $path -Raw | ConvertFrom-Json}catch{}}
  $masked=''
  if($null -ne $saved){
    $digits=([string]$saved.phone -replace '[^0-9]','')
    if($digits.Length -ge 3){$masked='***'+$digits.Substring($digits.Length-3)}
  }
  return @{
    ok=$true;sqlConnected=$SqlConnected;database=$Database;stations=@($Stations);
    workerTokenInstalled=(Test-Path (Join-Path $Root 'sql_queue_token.dat'));
    linked=($null -ne $saved -and $saved.linked -eq $true);
    linkedPhone=$masked;
    linkedStations=$(if($null -ne $saved -and $saved.linked -eq $true){@($saved.stations)}else{@()})
  }
}
function Set-DoingLioCoreLink {
  param([string]$Root,[string]$Phone,[int[]]$Selected,[int[]]$Available,[string]$Database,[bool]$Confirmed)
  $phone=($Phone -replace '[^0-9]','')
  if($phone -notmatch '^\d{9,15}$' -or -not $Confirmed){throw 'Indica el telefono completo y confirma la vinculacion.'}
  $stations=@($Selected|Sort-Object -Unique)
  if($stations.Count -lt 1 -or $stations.Count -gt 64){throw 'Selecciona al menos una estacion.'}
  foreach($id in $stations){if($id -lt 1 -or $Available -notcontains $id){throw 'Hay una estacion que no pertenece a esta base SQL.'}}
  if([string]::IsNullOrWhiteSpace($Database)){throw 'Primero conecta SQL desde Nucleo > Datos.'}
  $path=Join-Path $Root 'doinglio_core_link.json'
  $saved=$null
  if(Test-Path $path){try{$saved=Get-Content $path -Raw | ConvertFrom-Json}catch{}}
  if($null -ne $saved -and $saved.linked -eq $true -and [string]$saved.phone -ne $phone){
    throw 'Este nucleo ya esta vinculado a otro administrador. No se permite cambiarlo sin desvinculacion.'
  }
  $id=if($null -ne $saved -and [string]$saved.installation_id){[string]$saved.installation_id}else{[guid]::NewGuid().ToString()}
  $local=@{installation_id=$id;phone=$phone;stations=$stations;database=$Database;linked=($null -ne $saved -and $saved.linked -eq $true)}
  # Persistir ID antes de la llamada para evitar duplicados por reintentos.
  [IO.File]::WriteAllText($path,($local|ConvertTo-Json -Compress),[Text.Encoding]::UTF8)
  $token=Get-DoingLioCoreWorkerToken -Root $Root
  try {
    $body=@{action='link_installation';installation_id=$id;phone=$phone;station_ids=$stations;database_name=$Database;confirmed=$true}|ConvertTo-Json -Depth 4 -Compress
    $response=Invoke-RestMethod -Uri 'https://pddsehshgfynpmibjqhj.supabase.co/functions/v1/doinglio-sql-queue' -Method POST -Headers @{'x-doinglio-token'=$token} -ContentType 'application/json' -Body $body -TimeoutSec 20
    if($response.ok -ne $true -or $response.linked -ne $true){throw 'DoingLio no confirmo el vinculo.'}
    $local.linked=$true
    [IO.File]::WriteAllText($path,($local|ConvertTo-Json -Compress),[Text.Encoding]::UTF8)
    return @{ok=$true;linked=$true;stationIds=$stations;phoneLast3=$phone.Substring($phone.Length-3)}
  } finally {$token=''}
}
