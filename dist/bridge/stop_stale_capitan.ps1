# Limpia únicamente procesos antiguos del conector instalados por DoingLioConnector.
# No termina otras instancias de PowerShell ni modifica archivos de Datos.
$ErrorActionPreference='Continue'
$folder='C:\Sistemas\DoingLioConnector\bridge\'
$names=@('capitan_rodolfo_local.ps1','doinglio_sql_queue_worker.ps1')
try {
  $processes=Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'"
  foreach($p in $processes){
    if($p.ProcessId -eq $PID){continue}
    $line=[string]$p.CommandLine
    if($line -notmatch '(?i)(?:^|\s)-File\s+'){continue}
    $found=$false
    foreach($name in $names){
      $full=[regex]::Escape($folder+$name)
      if($line -match ('(?i)(?:^|\s)-File\s+["'']?'+$full+'(?:["'']|\s|$)')){$found=$true;break}
    }
    if(-not $found){continue}
    try {
      Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
      Write-Output ('Se detuvo conector anterior PID '+$p.ProcessId)
    }catch{Write-Output ('No se pudo detener PID '+$p.ProcessId)}
  }
}catch{Write-Output 'No fue posible buscar los procesos anteriores; se continúa sin cambiar Datos.'}
