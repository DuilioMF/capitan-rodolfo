# Diagnóstico de solo lectura. Ejecución LOCAL: la conexión SQL y el código del
# procedimiento nunca se envían a GitHub, Supabase ni a ningún servicio externo.
param()
$ErrorActionPreference='Stop'
$root=Join-Path $env:TEMP ('Capitan_Cobros_Rendimiento_'+(Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -Path $root -ItemType Directory -Force | Out-Null
$log=Join-Path $root 'RESUMEN.txt'
$lines=New-Object System.Collections.Generic.List[string]
function Say([string]$message){
  $script:lines.Add($message)
  Write-Host $message
}
function Query([string]$sql,[string]$filename) {
  try {
    $request=@{sessionId=$script:state.sessionId;database='SiSRL';sql=$sql}|ConvertTo-Json -Compress -Depth 6
    $result=Invoke-RestMethod -Method POST -Uri ($script:base+'/api/ai/sql-read') -Body $request -ContentType 'application/json' -TimeoutSec 24
    # Resultados de diagnóstico, no tablas de ventas ni contraseñas.
    $target=Join-Path $script:root $filename
    @($result.rows)|ConvertTo-Json -Depth 8 | Set-Content $target -Encoding UTF8
    return @($result.rows)
  }catch{
    Say ('No se pudo consultar '+$filename+': '+$_.Exception.Message)
    return @()
  }
}
try {
  Say 'CAPITAN: diagnostico LOCAL de rendimiento PA_VentasFormasPago'
  Say 'No ejecuta ni modifica el SP, no crea indices ni lee movimientos comerciales.'
  $candidates=@(8787,8797,18787,27877,37877,48787,57877)
  $found=@()
  foreach($port in $candidates) {
    try {
      $url='http://127.0.0.1:'+$port
      $h=Invoke-RestMethod ($url+'/health') -TimeoutSec 2
      if($h.ok -and $h.service -eq 'Capitan Rodolfo Local') {
        $found+=@([pscustomobject]@{base=$url;version=[int]$h.version;connected=[bool]$h.connected})
      }
    }catch{}
  }
  if(!$found.Count){throw 'El conector local no responde. Abrí Núcleo > Datos.'}
  $selected=@($found|Sort-Object @{Expression='connected';Descending=$true},@{Expression='version';Descending=$true})[0]
  $script:base=$selected.base
  Say ('Conector v'+$selected.version+' ('+$base+')')
  if(!$selected.connected){throw 'El conector responde pero SQL está desconectado.'}
  $script:state=Invoke-RestMethod ($base+'/api/state') -TimeoutSec 5
  if($state.connected -ne $true -or $state.database -ine 'SiSRL' -or !$state.sessionId) {
    throw 'La sesión activa no está conectada a SiSRL.'
  }
  Say 'PASS: reutilizando la MISMA sesión activa SiSRL de Capitán.'
  $proc="dbo.PA_VentasFormasPago"
  $perm=Query "SELECT DB_NAME() AS base,OBJECT_ID(N'dbo.PA_VentasFormasPago',N'P') AS objeto,HAS_PERMS_BY_NAME(N'dbo.PA_VentasFormasPago',N'OBJECT',N'EXECUTE') AS puedeEjecutar,HAS_PERMS_BY_NAME(N'dbo.PA_VentasFormasPago',N'OBJECT',N'VIEW DEFINITION') AS puedeVerCodigo" '01_PERMISOS.json'
  if(!$perm.Count -or !$perm[0].objeto){throw 'El procedimiento no es visible en SiSRL con esta conexión. Confirmá su existencia.'}
  Say ('SP encontrado: '+$proc+'. EXECUTE='+(if($null -eq $perm[0].puedeEjecutar){'sin información'}else{$perm[0].puedeEjecutar}))
  if($perm[0].puedeEjecutar -eq 0){Say 'ATENCION: falta permiso EXECUTE; esto es independiente del error de lentitud.'}
  $parameters=Query "SELECT p.parameter_id,p.name,TYPE_NAME(p.user_type_id) AS tipo,p.max_length,p.is_output FROM sys.parameters p WHERE p.object_id=OBJECT_ID(N'dbo.PA_VentasFormasPago',N'P') ORDER BY p.parameter_id" '02_PARAMETROS.json'
  Say ('Parámetros observados: '+$parameters.Count)
  # El código fuente se guarda en el equipo del usuario. NUNCA va al resumen ni a Git.
  $code=Query "SELECT m.definition FROM sys.sql_modules m WHERE m.object_id=OBJECT_ID(N'dbo.PA_VentasFormasPago',N'P')" '03_MODULO_PRIVADO.json'
  if($code.Count -and ![string]::IsNullOrWhiteSpace([string]$code[0].definition)) {
    $source=Join-Path $root '03_PROCEDIMIENTO_PRIVADO.sql'
    [IO.File]::WriteAllText($source,[string]$code[0].definition,[Text.Encoding]::UTF8)
    Remove-Item (Join-Path $root '03_MODULO_PRIVADO.json') -ErrorAction SilentlyContinue
    Say 'Código del procedimiento: guardado PRIVADAMENTE en el archivo 03_PROCEDIMIENTO_PRIVADO.sql.'
  }else{
    Say 'Código del procedimiento no visible: puede requerir VIEW DEFINITION. No se inventa.'
  }
  # Cache de planes: no son registros actuales ni representan por sí mismos el
  # plan de la consulta que agotó el timeout.
  $perf=Query "SELECT TOP (10) cached_time,last_execution_time,execution_count, last_elapsed_time/1000 AS ultimo_ms,max_elapsed_time/1000 AS maximo_ms, total_elapsed_time/1000 AS total_ms,last_logical_reads,max_logical_reads,last_physical_reads FROM sys.dm_exec_procedure_stats WHERE database_id=DB_ID() AND object_id=OBJECT_ID(N'dbo.PA_VentasFormasPago',N'P') ORDER BY last_execution_time DESC" '04_ESTADISTICAS_PLAN.json'
  Say ('Planes de SP en cache: '+$perf.Count+' (si no hay, puede faltar permiso o el plan se desalojó).')
  foreach($p in $perf){
    Say ('Métrica observada: ejecuciones='+$p.execution_count+'; último ms='+$p.ultimo_ms+'; máximo ms='+$p.maximo_ms+'; últimas lecturas lógicas='+$p.last_logical_reads)
  }
  $deps=Query "SELECT TOP (50) s.name AS esquema,o.name AS objeto,o.type_desc AS tipo FROM sys.sql_expression_dependencies d JOIN sys.objects o ON d.referenced_id=o.object_id JOIN sys.schemas s ON o.schema_id=s.schema_id WHERE d.referencing_id=OBJECT_ID(N'dbo.PA_VentasFormasPago',N'P') ORDER BY s.name,o.name" '05_DEPENDENCIAS.json'
  Say ('Objetos referenciados por SQL estático: '+$deps.Count+' (SQL dinámico puede no aparecer).')
  $keys=Query "SELECT TOP (50) OBJECT_SCHEMA_NAME(i.object_id) AS esquema,OBJECT_NAME(i.object_id) AS tabla,i.name AS indice,i.type_desc AS tipo,c.name AS columna,ic.key_ordinal,ic.is_included_column FROM sys.sql_expression_dependencies d JOIN sys.indexes i ON i.object_id=d.referenced_id JOIN sys.index_columns ic ON ic.object_id=i.object_id AND ic.index_id=i.index_id JOIN sys.columns c ON c.object_id=ic.object_id AND c.column_id=ic.column_id WHERE d.referencing_id=OBJECT_ID(N'dbo.PA_VentasFormasPago',N'P') AND i.index_id>0 ORDER BY OBJECT_NAME(i.object_id),i.name,ic.key_ordinal,c.name" '06_INDICES.json'
  Say ('Columnas de índices inspeccionadas: '+$keys.Count)
  Say 'RESULTADO: diagnóstico de metadatos completado; falta interpretar código y plan para optimizar.'
  Say 'IMPORTANTE: no ejecutes CREATE INDEX ni cambies el SP por suposiciones.'
}catch{
  Say ('BLOQUEO: '+$_.Exception.Message)
}finally{
  Say ('Archivos locales: '+$root)
  Say 'Compartí únicamente RESUMEN.txt; si querés que reescriba el SP, compartí también 03_PROCEDIMIENTO_PRIVADO.sql y, si hace falta, los JSON de índices.'
  [IO.File]::WriteAllLines($log,$lines,[Text.Encoding]::UTF8)
  [IO.File]::WriteAllText((Join-Path $env:TEMP 'Capitan_Cobros_Rendimiento_ultimo.txt'),$root,[Text.Encoding]::UTF8)
  Write-Host 'El diagnóstico y el código SQL permanecen en esta PC.'
}
