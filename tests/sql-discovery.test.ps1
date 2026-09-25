$ErrorActionPreference='Stop'
$path=(Resolve-Path './bridge/capitan_rodolfo_local.ps1').Path
$all=[IO.File]::ReadAllText($path,[Text.Encoding]::UTF8)
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($all,[ref]$tokens,[ref]$errors)
if(@($errors).Count -gt 0){$errors | ForEach-Object {Write-Host $_.Message};throw 'Sintaxis PowerShell incorrecta'}
$names=@('Add-SqlDiscoveryResult','Get-DiscoveredSqlServers')
foreach($name in $names){
 $func=$ast.FindAll({param($n)($n -is [Management.Automation.Language.FunctionDefinitionAst]) -and $n.Name -eq $name},$true)|Select-Object -First 1
 if(-not $func){throw "Falta función $name"}
 . ([scriptblock]::Create($func.Extent.Text))
}
$oldComputer=$env:COMPUTERNAME
$env:COMPUTERNAME='TESTBOX'
function Ensure-ActiveSession{return $null}
function Load-SqlProfile{return $null}
function Get-CimInstance {
 param([string]$ClassName,[string]$Filter)
 @([pscustomobject]@{Name='MSSQL$SQLEXPRESS';State='Running'},
   [pscustomobject]@{Name='SQLBrowser';State='Running'})
}
function Get-ItemProperty {
 param([string]$LiteralPath)
 [pscustomobject]@{SQLEXPRESS='MSSQL';MSSQLSERVER='MSSQL'}
}
function Start-Job {throw 'NETWORK_AUTO_SCAN_NOT_ALLOWED'}
try{
 $found=Get-DiscoveredSqlServers
 $names=@($found.servers | ForEach-Object {$_.server})
 if($names.Count -ne 2){throw "Esperaba 2 instancias únicas; hay: $($names -join ',')"}
 if($names -notcontains 'TESTBOX\SQLEXPRESS'){throw 'Instancia nombrada ausente'}
 if($names -notcontains 'TESTBOX'){throw 'Instancia default ausente'}
 if($found.networkSearched){throw 'La red no debe explorarse al cargar'}
 if(@($found.servers | Where-Object {$_.connected}).Count -ne 0){throw 'Detectado no equivale a conectado'}
 # Un perfil existente mantiene prioridad sin cambiar credenciales.
 function Load-SqlProfile{return [pscustomobject]@{server='TESTBOX\SQLEXPRESS';auth='sql';user='saved';database='SiSRL'}}
 $saved=Get-DiscoveredSqlServers
 if($saved.servers[0].server -ne 'TESTBOX\SQLEXPRESS'){throw 'El perfil previo no fue priorizado'}
 if(@($saved.servers).Count -ne 2){throw 'No se eliminaron duplicados'}
 # Si existe sesión, se indica conectado sin inventar un servidor distinto.
 function Ensure-ActiveSession{return @{server='TESTBOX\SQLEXPRESS'}}
 $active=Get-DiscoveredSqlServers
 if(-not $active.servers[0].connected){throw 'No se marcó la sesión realmente activa'}
 if($all.Contains('id="server" value="DUILIO\SQLEXPRESS"')){throw 'No quitaron el servidor fijo del formulario local'}
 if($all -notmatch [regex]::Escape("'/api/discover-servers'")){throw 'Falta endpoint de descubrimiento'}
 Write-Host 'OK: PowerShell 5.1, inventario real simulado, sin red implícita, persistencia y estado verificado.'
}finally{$env:COMPUTERNAME=$oldComputer}
