param(
  [int]$Estacion=1,
  [string]$Fecha='',
  [int]$Venta=0
)
$ErrorActionPreference='Stop'
$report=New-Object System.Collections.Generic.List[string]
function Log([string]$message){
  Write-Host $message
  $script:report.Add($message)
}
function CallLocal([string]$base,[string]$route,$body=$null){
  $uri=$base+$route
  if($null -eq $body){return Invoke-RestMethod -Uri $uri -TimeoutSec 30}
  return Invoke-RestMethod -Uri $uri -Method POST -ContentType 'application/json' -Body ($body|ConvertTo-Json -Compress -Depth 5) -TimeoutSec 75
}
function Field($obj,[string[]]$names){
  if($null -eq $obj){return $null}
  foreach($name in $names){
    foreach($p in $obj.PSObject.Properties){
      if(($p.Name -replace '[^a-zA-Z0-9]','').ToLowerInvariant() -eq ($name -replace '[^a-zA-Z0-9]','').ToLowerInvariant()){
        return $p.Value
      }
    }
  }
  return $null
}
function Similar($left,$right){
  $a=([string]$left).Trim().ToUpperInvariant();$b=([string]$right).Trim().ToUpperInvariant()
  if(!$a -or !$b){return $false}
  if($a -match '^[0-9]+$' -and $b -match '^[0-9]+$'){
    try{return [decimal]$a -eq [decimal]$b}catch{}
  }
  return $a -ceq $b
}
function Amount($v){
  if($null -eq $v -or [string]$v -eq ''){return $null}
  $s=([string]$v).Trim().Replace(' ','').Replace('$','')
  $dot=$s.LastIndexOf('.');$comma=$s.LastIndexOf(',')
  if($dot -ge 0 -and $comma -ge 0){
    if($comma -gt $dot){$s=$s.Replace('.','').Replace(',','.')}
    else{$s=$s.Replace(',','')}
  }elseif($comma -ge 0){$s=$s.Replace(',','.')}
  $num=[decimal]0
  if([decimal]::TryParse($s,[Globalization.NumberStyles]::Number,[Globalization.CultureInfo]::InvariantCulture,[ref]$num)){return $num}
  return $null
}
$success=$false
$partial=$false
try {
  if(!$Fecha){
    $arg=[TimeZoneInfo]::FindSystemTimeZoneById('Argentina Standard Time')
    $Fecha=[TimeZoneInfo]::ConvertTimeFromUtc([datetime]::UtcNow,$arg).ToString('yyyy-MM-dd')
  }
  $dateObj=[datetime]::MinValue
  if(-not [datetime]::TryParseExact($Fecha,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$dateObj)){
    throw 'Fecha invalida. Usar YYYY-MM-DD.'
  }
  if($Estacion -lt 1){throw 'Estacion invalida.'}
  Log ('INICIO: prueba REAL local, SiSRL, estacion '+$Estacion+', fecha '+$Fecha)
  Log 'No se escriben tablas ni se envian importes a Internet.'
  $ports=@(8787,8797,18787,27877,37877,48787,57877)
  $found=@()
  foreach($port in $ports){
    $base='http://127.0.0.1:'+$port
    try {
      $h=Invoke-RestMethod -Uri ($base+'/health') -TimeoutSec 2
      if($h.ok -and $h.service -eq 'Capitan Rodolfo Local'){
        $found+=@([pscustomobject]@{base=$base;version=([int]$h.version);connected=([bool]$h.connected)})
      }
    }catch{}
  }
  if(@($found).Count -eq 0){throw 'NO HAY CONECTOR. Ejecutar CAPITAN_RODOLFO.bat V94 en esta PC y repetir.'}
  $current=@($found|Sort-Object @{Expression='connected';Descending=$true},@{Expression='version';Descending=$true})[0]
  Log ('Conector detectado: v'+$current.version+' en '+$current.base+', conectado='+$current.connected)
  if($current.version -lt 94){throw 'CONECTOR ANTIGUO. Actualizar a V94 antes de probar Cobros.'}
  if(!$current.connected){throw 'SQL NO CONECTADO. Abrir Nucleo > Datos y restaurar SiSRL.'}
  $state=CallLocal $current.base '/api/state'
  if(-not $state.connected -or [string]$state.database -ine 'SiSRL'){
    throw ('BASE INCORRECTA O DESCONECTADA: '+[string]$state.database+'. Se requiere SiSRL.')
  }
  Log 'PASS: misma conexion SQL activa de SiSRL.'
  $stations=CallLocal $current.base '/api/station/ids'
  if(-not (@($stations.stations) -contains $Estacion)){
    throw ('La estacion '+$Estacion+' no esta autorizada en la conexion actual.')
  }
  Log 'PASS: estacion autorizada.'
  $params=@{idEstacion=$Estacion;fechaDesde=$Fecha;fechaHasta=$Fecha;turnoDesde=0;turnoHasta=99999}
  Log ('Consultando dbo.PA_VentasFormasPago en SiSRL para '+$Fecha+'...')
  $payments=CallLocal $current.base '/api/station/payments' $params
  if($payments.database -ine 'SiSRL' -or $payments.source -ne 'dbo.PA_VentasFormasPago' -or
      $payments.fechaDesde -ne $Fecha -or $payments.fechaHasta -ne $Fecha){
    throw 'El servicio devolvio una base, un SP o una fecha diferente: prueba NO valida.'
  }
  $sets=@($payments.resultSets)
  if($sets.Count -eq 0){throw 'El SP no devolvio conjuntos verificables.'}
  Log ('PASS: el SP real responde con '+$sets.Count+' conjunto(s) de resultados.')
  $aliases=@{
    'Efectivo'=@('Efectivo');'Mercado Pago'=@('MercadoPago','Mercado_Pago')
    'App YPF'=@('AppYPF','YPF');'Clover'=@('Clover')
    'Cuenta Corriente'=@('CuentaCorriente','CuentasCorrientes')
    'Tarjetas'=@('Tarjeta','Tarjetas','Tarjet');'PayWay'=@('PayWay')
    'Shell Box'=@('ShellBox');'App Puma'=@('AppPuma');'Cheques'=@('Cheques')
  }
  $chosen=$null
  foreach($set in $sets){
    if($null -eq $set.columns){continue}
    foreach($values in $aliases.Values){
      foreach($col in $values){
        if(@($set.columns|Where-Object {($_ -replace '[^a-zA-Z0-9]','').ToLowerInvariant() -eq ($col -replace '[^a-zA-Z0-9]','').ToLowerInvariant()}).Count -gt 0){$chosen=$set;break}
      }
      if($null -ne $chosen){break}
    }
    if($null -ne $chosen){break}
  }
  if($null -eq $chosen){
    $cols=($sets|ForEach-Object {$_.columns}|Select-Object -Unique) -join ', '
    throw ('El SP responde, pero Cobros no reconoce columnas de medios de pago. Columnas: '+$cols)
  }
  $rows=@($chosen.rows)
  Log ('PASS: pantalla Cobros reconoceria '+$rows.Count+' fila(s) del conjunto de medios.')
  if($payments.truncated -or $chosen.truncated){
    $partial=$true
    Log 'PARCIAL: limite de 5000 filas alcanzado; acotar las fechas antes de confirmar totales.'
  }
  $total=[decimal]0
  foreach($method in ($aliases.Keys|Sort-Object)){
    $column=$null
    foreach($alias in $aliases[$method]){
      foreach($candidate in @($chosen.columns)){
        if(($candidate -replace '[^a-zA-Z0-9]','').ToLowerInvariant() -eq ($alias -replace '[^a-zA-Z0-9]','').ToLowerInvariant()){$column=$candidate;break}
      }
      if($column){break}
    }
    if(!$column){continue}
    $sum=[decimal]0;$count=0
    foreach($row in $rows){
      $value=Amount (Field $row @($column))
      if($null -ne $value -and $value -ne 0){$sum+=$value;$count++}
    }
    $total+=$sum
    Log ($method+': '+$count+' movimiento(s); importe '+$sum.ToString('N2',[Globalization.CultureInfo]::GetCultureInfo('es-AR')))
  }
  Log ('Suma de medios detectados: '+$total.ToString('N2',[Globalization.CultureInfo]::GetCultureInfo('es-AR')))
  Log 'Verificando vinculacion de despacho cobrado con un comprobante...'
  $sample=0
  if($Venta -gt 0){$sample=$Venta}
  else {
    try{
      $daily=CallLocal $current.base '/api/station/today-dispatches' @{idEstacion=$Estacion;fecha=$Fecha}
      Log ('Despachos SQL registrados ese dia: '+[string]$daily.total)
      $paid=@($daily.lastFive|Where-Object {($_.ESTADOVTA -eq 1 -or $_.ESTADOVTA -eq '1') -and $_.IdSale})
      if($paid.Count -gt 0){$sample=[int]$paid[0].IdSale}
    }catch{Log ('AVISO: lectura de despachos no disponible: '+$_.Exception.Message)}
  }
  if($sample -gt 0){
    $link=CallLocal $current.base '/api/station/payment-sale' @{idEstacion=$Estacion;idSale=$sample}
    $linked=@($link.rows|Where-Object {[int]$_.estadoVta -eq 1 -and $_.letra -and $_.sucursal -and $_.numero})
    if($linked.Count -lt 1){
      $partial=$true;Log 'PARCIAL: el despacho seleccionado no tiene comprobante cobrado vinculado y verificable.'
    }else{
      $matches=0
      foreach($invoice in $linked){
        foreach($row in $rows){
          if((Similar (Field $row @('Letra')) $invoice.letra) -and
            (Similar (Field $row @('Sucursal')) $invoice.sucursal) -and
            (Similar (Field $row @('NCompro','Numero','NComp','NComprobante')) $invoice.numero)){
            $matches++
          }
        }
      }
      if($matches -gt 0){Log ('PASS: despacho '+$sample+' vinculado y '+$matches+' fila(s) del comprobante verificadas en el SP.')}
      else{$partial=$true;Log ('PARCIAL: comprobante vinculado para despacho '+$sample+', pero no aparece en el SP para esta fecha/turno.')}
    }
  }else{$partial=$true;Log 'PARCIAL: ultimos cinco despachos sin uno cobrado identificable. Indicar -Venta con ID_SALE cobrado para verificar vinculo.'}
  $success=$true
  if($partial){Log 'RESULTADO: SQL REAL CONSULTADO; VALIDACION PARCIAL (ver avisos).'}
  else{Log 'RESULTADO: PRUEBA LOCAL REAL SATISFACTORIA.'}
}catch{
  Log ('RESULTADO: BLOQUEADO - '+$_.Exception.Message)
}finally{
  $path=Join-Path $env:TEMP ('diagnostico_cobros_sisrl_'+(Get-Date -Format 'yyyyMMdd_HHmmss')+'.txt')
  [IO.File]::WriteAllLines($path,$report,[Text.Encoding]::UTF8)
  Write-Host ('REPORTE LOCAL: '+$path)
  Write-Host 'Enviame una captura de esta ventana o pega el reporte para completar la validacion.'
}
if(!$success){exit 1}
if($partial){exit 2}
exit 0
