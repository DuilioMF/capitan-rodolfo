$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../bridge/doinglio_core_link.ps1')
$root=Join-Path $env:TEMP ('capitan-link-'+[guid]::NewGuid())
New-Item -ItemType Directory -Path $root | Out-Null
try {
  $path=Join-Path $root 'doinglio_core_link.json'
  $original=@{installation_id=[guid]::NewGuid().ToString();phone='5493413692112';stations=@(1);database='SiSRL';linked=$true}
  [IO.File]::WriteAllText($path,($original|ConvertTo-Json -Compress))
  $connected=Get-DoingLioCoreStatus -Root $root -SqlConnected $true -Database 'SiSRL' -Stations @(1,2)
  if(-not $connected.linked){throw 'El vínculo existente dejó de verse como conectado.'}
  if((Get-DoingLioCoreStatus -Root $root -SqlConnected $true -Database 'OtraBase' -Stations @(1)).linked){throw 'Se mostró una base distinta como vinculada.'}
  if((Get-DoingLioCoreStatus -Root $root -SqlConnected $true -Database 'SiSRL' -Stations @(2)).linked){throw 'Se mostró una estación ausente como vinculada.'}

  function Get-DoingLioCoreWorkerToken { return 'token-de-prueba' }
  function Invoke-RestMethod { throw 'Falla de red simulada' }
  try {
    Set-DoingLioCoreLink -Root $root -Phone '5493413692112' -Selected @(1,2) -Available @(1,2) -Database 'SiSRL' -Confirmed $true | Out-Null
    throw 'La falla de red fue aceptada como vínculo.'
  } catch {
    if($_.Exception.Message -ne 'DoingLio no confirmó el vínculo. Comprobá Internet y volvé a intentar.'){throw}
  }
  $saved=Get-Content $path -Raw | ConvertFrom-Json
  if(-not $saved.linked -or @($saved.stations).Count -ne 1 -or $saved.stations[0] -ne 1){throw 'La falla reemplazó el vínculo anterior.'}
  Write-Host 'Vínculo anterior preservado; una base/estación distinta no aparece conectada.'
} finally {Remove-Item $root -Recurse -Force}
