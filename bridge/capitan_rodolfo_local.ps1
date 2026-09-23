param(
  [int]$Port = 8787,
  [string]$DefaultServer = "",
  [string]$AppDir = "",
  [switch]$BackgroundChild
)

$ErrorActionPreference = "Stop"
if([string]::IsNullOrWhiteSpace($AppDir)){
    $AppDir = Split-Path -Parent $PSScriptRoot
}
$AppDir = [IO.Path]::GetFullPath($AppDir)
if(-not (Test-Path $AppDir)){ New-Item -ItemType Directory -Path $AppDir -Force | Out-Null }
$LogDir = Join-Path $AppDir "logs"
if(-not (Test-Path $LogDir)){ New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$VersionPath = Join-Path $AppDir "VERSION"
$Version = "dev"
try {
    if(Test-Path $VersionPath){
        $candidate = (Get-Content $VersionPath -Raw).Trim()
        if(-not [string]::IsNullOrWhiteSpace($candidate)){ $Version = $candidate }
    }
} catch {}
$Sessions = @{}
$ActiveSessionId = $null
$ProfilePath = Join-Path $AppDir "sql_profile.json"
$OpenAIKeyPath = Join-Path $AppDir "openai_key.dat"
$ServiceStatusPath = Join-Path $AppDir "servicio_sql_estado.json"
$TaskName = "CapitanRodolfoLocal"
$script:LastRestoreError = ""

function Write-ServiceStatus {
    param([string]$State,[string]$Database="",[string]$Server="",[string]$User="",[string]$ErrorMessage="")
    try {
        $hasProtectedPassword = $false
        if(Test-Path $ProfilePath){
            try {
                $sp = Get-Content $ProfilePath -Raw | ConvertFrom-Json
                $hasProtectedPassword = -not [string]::IsNullOrWhiteSpace([string]$sp.passwordProtected)
                if([string]::IsNullOrWhiteSpace($User)){ $User = [string]$sp.user }
                if([string]::IsNullOrWhiteSpace($Server)){ $Server = [string]$sp.server }
                if([string]::IsNullOrWhiteSpace($Database)){ $Database = [string]$sp.database }
            } catch {}
        }
        $payload = [ordered]@{
            service = "Capitan Rodolfo SQL"
            state = $State
            mode = "background"
            version = $Version
            pid = $PID
            port = $Port
            database = $Database
            server = $Server
            user = $User
            hasProtectedPassword = $hasProtectedPassword
            profileExists = (Test-Path $ProfilePath)
            scheduledTask = $TaskName
            updatedAt = (Get-Date).ToString("o")
            error = $ErrorMessage
        }
        [IO.File]::WriteAllText($ServiceStatusPath,($payload | ConvertTo-Json -Depth 4),[Text.Encoding]::UTF8)
    } catch {}
}

function Ensure-BackgroundTask {
    try {
        $action = 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Port ' + $Port + ' -AppDir "' + $AppDir + '" -BackgroundChild'
        & schtasks.exe /Create /F /SC ONLOGON /RL LIMITED /TN $TaskName /TR $action 2>$null | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

if(-not $BackgroundChild){
    Ensure-BackgroundTask | Out-Null
    $argLine = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Port ' + $Port + ' -AppDir "' + $AppDir + '" -BackgroundChild'
    Start-Process -FilePath "powershell.exe" -ArgumentList $argLine -WindowStyle Hidden
    exit 0
}

Ensure-BackgroundTask | Out-Null
Write-ServiceStatus -State "starting"

function Import-LegacyLocalState {
    $roots = @("C:\Sistemas", (Join-Path $env:LOCALAPPDATA "CapitanRodolfo")) | Where-Object { $_ -and (Test-Path $_) }
    foreach($target in @(
        @{ Name="sql_profile.json"; Path=$ProfilePath },
        @{ Name="openai_key.dat"; Path=$OpenAIKeyPath }
    )){
        if(Test-Path $target.Path){ continue }
        $candidate = $null
        foreach($root in $roots){
            try {
                $candidate = Get-ChildItem -Path $root -Filter $target.Name -File -Recurse -ErrorAction SilentlyContinue |
                    Where-Object {
                        $_.FullName -ne $target.Path -and
                        ($_.DirectoryName -match '(?i)capitan|rodolfo')
                    } |
                    Sort-Object LastWriteTime -Descending |
                    Select-Object -First 1
                if($candidate){ break }
            } catch {}
        }
        if($candidate){
            try {
                Copy-Item -Path $candidate.FullName -Destination $target.Path -Force
                Write-Host "Estado local recuperado: $($target.Name) desde $($candidate.DirectoryName)"
            } catch {
                Write-Host "No se pudo recuperar $($target.Name): $($_.Exception.Message)"
            }
        }
    }
}
Import-LegacyLocalState

function Send-Response {
    param(
        [System.Net.Sockets.NetworkStream]$Stream,
        [int]$StatusCode = 200,
        [string]$ContentType = "text/html; charset=utf-8",
        [string]$Body = ""
    )
    $statusText = switch ($StatusCode) {
        200 {"OK"} 204 {"No Content"} 400 {"Bad Request"} 401 {"Unauthorized"}
        403 {"Forbidden"} 404 {"Not Found"} 500 {"Internal Server Error"} default {"OK"}
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $nl = [Environment]::NewLine
    $allowedOrigins = @("https://duiliomf.github.io","http://127.0.0.1:8790","http://localhost:8790")
    $corsOrigin = "https://duiliomf.github.io"
    if(-not [string]::IsNullOrWhiteSpace([string]$script:CurrentOrigin) -and $allowedOrigins -contains [string]$script:CurrentOrigin){
        $corsOrigin = [string]$script:CurrentOrigin
    }
    $headers = "HTTP/1.1 $StatusCode $statusText" + $nl +
      "Content-Type: $ContentType" + $nl +
      "Content-Length: $($bytes.Length)" + $nl +
      "Cache-Control: no-store" + $nl +
      "Access-Control-Allow-Origin: $corsOrigin" + $nl +
      "Access-Control-Allow-Methods: GET, POST, OPTIONS" + $nl +
      "Access-Control-Allow-Headers: Content-Type" + $nl +
      "Access-Control-Allow-Private-Network: true" + $nl +
      "Connection: close" + $nl + $nl
    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($headers)
    $Stream.Write($headerBytes,0,$headerBytes.Length)
    if($bytes.Length -gt 0){ $Stream.Write($bytes,0,$bytes.Length) }
    $Stream.Flush()
}

function Save-OpenAIKey {
    param([string]$ApiKey)
    if([string]::IsNullOrWhiteSpace($ApiKey) -or -not $ApiKey.StartsWith('sk-')){ throw "La clave de OpenAI no tiene un formato válido." }
    $secure = ConvertTo-SecureString $ApiKey.Trim() -AsPlainText -Force
    [IO.File]::WriteAllText($OpenAIKeyPath,(ConvertFrom-SecureString $secure),[Text.Encoding]::UTF8)
}

function Get-OpenAIKey {
    if(-not (Test-Path $OpenAIKeyPath)){ return $null }
    try {
        $secure = ConvertTo-SecureString ((Get-Content $OpenAIKeyPath -Raw).Trim())
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
    } catch { return $null }
}

function New-OpenAIRealtimeSecret {
    param([string]$ApiKey)
    $instructions = "Sos Capitán Rodolfo, especialista de DoingLio para estaciones de servicio. Hablás siempre en español rioplatense, claro, breve y natural. Tu identidad visible es Capitán Rodolfo; no te presentás como OpenAI. Escuchás sin exigir que el usuario pulse enviar. Si necesitás datos reales de la estación, usás consultar_sql_lectura. Nunca inventás tablas, campos, relaciones, formas de pago ni valores. Para mapear la estación primero inspeccionás el esquema real con consultas a sys.tables, sys.views, sys.columns, sys.foreign_keys, sys.procedures y sys.sql_modules; después probás cada consulta de negocio con datos reales. Solo afirmás una relación cuando la evidencia SQL la confirma. El mapeo buscado es Tanque → Surtidor → Pico/Manguera → Despacho → Estado → Cobro → Forma de pago. Efectivo, tarjeta, Mercado Pago, App YPF u otros solo se nombran si aparecen realmente. Antes de consultar, explicás brevemente qué necesitás mirar."
    $payload = @{
        session = @{
            type='realtime'; model='gpt-realtime-2.1'; output_modalities=@('audio'); instructions=$instructions
            audio=@{input=@{transcription=@{model='gpt-4o-mini-transcribe';language='es'};turn_detection=@{type='semantic_vad'}};output=@{voice='cedar'}}
            tools=@(@{type='function';name='consultar_sql_lectura';description='Consulta datos reales de la base SQL Server activa. Solo admite SELECT o WITH de lectura.';parameters=@{type='object';properties=@{consulta=@{type='string';description='Consulta T-SQL de solo lectura, sin punto y coma.'}};required=@('consulta')}})
            tool_choice='auto'
        }
    } | ConvertTo-Json -Depth 12 -Compress
    $headers = @{Authorization="Bearer $ApiKey";'OpenAI-Safety-Identifier'='capitan-rodolfo-local'}
    return Invoke-RestMethod -Uri 'https://api.openai.com/v1/realtime/client_secrets' -Method Post -Headers $headers -ContentType 'application/json' -Body $payload -TimeoutSec 20
}

function Invoke-ReadOnlySql {
    param([string]$SessionId,[string]$Database,[string]$Sql)
    if(-not $Sessions.ContainsKey($SessionId)){ throw 'Sesión SQL vencida. Volvé a conectar desde Núcleo → Datos.' }
    $sess=$Sessions[$SessionId]
    if([string]::IsNullOrWhiteSpace($Database) -or $sess.databases -notcontains $Database){ throw 'Base SQL no autorizada.' }
    $clean=$Sql.Trim()
    if($clean -notmatch '^(?is)(SELECT|WITH)\b'){ throw 'Solo se permiten consultas SELECT o WITH.' }
    if($clean -match '(?is);|--|/\*|\b(INSERT|UPDATE|DELETE|MERGE|DROP|ALTER|CREATE|TRUNCATE|EXEC|EXECUTE|GRANT|REVOKE|DENY|BACKUP|RESTORE|DBCC|KILL|INTO)\b'){ throw 'La consulta contiene una operación no permitida.' }
    $cn=$sess.connection;$cn.ChangeDatabase($Database);$cmd=$cn.CreateCommand();$cmd.CommandText=$clean;$cmd.CommandTimeout=15;$reader=$cmd.ExecuteReader()
    try {
        $rows=New-Object System.Collections.Generic.List[object]
        while($reader.Read() -and $rows.Count -lt 50){$row=[ordered]@{};for($i=0;$i -lt $reader.FieldCount;$i++){$value=$reader.GetValue($i);if($value -is [DBNull]){$value=$null};$row[$reader.GetName($i)]=$value};$rows.Add([pscustomobject]$row)}
        return @{database=$Database;rowCount=$rows.Count;rows=$rows}
    } finally {$reader.Close()}
}

function Send-Json {
    param($Stream, [int]$StatusCode, $Object)
    $json = $Object | ConvertTo-Json -Depth 6 -Compress
    Send-Response -Stream $Stream -StatusCode $StatusCode -ContentType "application/json; charset=utf-8" -Body $json
}

function Send-Redirect {
    param([System.Net.Sockets.NetworkStream]$Stream,[string]$Location)
    $nl = [Environment]::NewLine
    $headers = "HTTP/1.1 302 Found" + $nl +
      "Location: $Location" + $nl +
      "Cache-Control: no-store" + $nl +
      "Content-Length: 0" + $nl +
      "Connection: close" + $nl + $nl
    $bytes = [System.Text.Encoding]::ASCII.GetBytes($headers)
    $Stream.Write($bytes,0,$bytes.Length)
    $Stream.Flush()
}

function Read-Request {
    param([System.Net.Sockets.NetworkStream]$Stream)
    $reader = New-Object System.IO.StreamReader($Stream,[System.Text.Encoding]::UTF8,$false,4096,$true)
    $requestLine = $reader.ReadLine()
    if([string]::IsNullOrWhiteSpace($requestLine)){ return $null }
    $parts = $requestLine.Split(' ')
    if($parts.Count -lt 2){ return $null }
    $headers = @{}
    while($true){
        $line = $reader.ReadLine()
        if($null -eq $line -or $line -eq ''){ break }
        $idx = $line.IndexOf(':')
        if($idx -gt 0){
            $headers[$line.Substring(0,$idx).Trim().ToLowerInvariant()] = $line.Substring($idx+1).Trim()
        }
    }
    $body = ""
    $len = 0
    if($headers.ContainsKey('content-length')){ [int]::TryParse($headers['content-length'],[ref]$len) | Out-Null }
    if($len -gt 0){
        $buf = New-Object char[] $len
        $read = 0
        while($read -lt $len){
            $n = $reader.Read($buf,$read,$len-$read)
            if($n -le 0){ break }
            $read += $n
        }
        if($read -gt 0){ $body = -join $buf[0..($read-1)] }
    }
    return [pscustomobject]@{ Method=$parts[0]; Path=$parts[1]; Headers=$headers; Body=$body }
}

function New-SqlConnection {
    param([string]$Server,[string]$Auth,[string]$User,[string]$Password)
    if($Auth -eq "windows"){
        $cs = "Data Source=$Server;Initial Catalog=master;Integrated Security=True;TrustServerCertificate=True;Connect Timeout=7;"
        return New-Object System.Data.SqlClient.SqlConnection($cs)
    }
    if([string]::IsNullOrWhiteSpace($User) -or [string]::IsNullOrWhiteSpace($Password)){
        throw "Completá usuario y contrasena SQL."
    }
    $secure = ConvertTo-SecureString $Password -AsPlainText -Force
    $secure.MakeReadOnly()
    $cred = New-Object System.Data.SqlClient.SqlCredential($User,$secure)
    $cn = New-Object System.Data.SqlClient.SqlConnection
    $cn.ConnectionString = "Data Source=$Server;Initial Catalog=master;TrustServerCertificate=True;Connect Timeout=7;"
    $cn.Credential = $cred
    return $cn
}


function Save-SqlProfile {
    param([string]$Server,[string]$Auth,[string]$User,[string]$Password,[string]$Database)
    $protectedPassword = ""
    if($Auth -eq "sql"){
        if(-not [string]::IsNullOrWhiteSpace($Password)){
            $secure = ConvertTo-SecureString $Password -AsPlainText -Force
            $protectedPassword = ConvertFrom-SecureString $secure
        } elseif(Test-Path $ProfilePath) {
            try {
                $old = Get-Content $ProfilePath -Raw | ConvertFrom-Json
                if(([string]$old.server -eq $Server) -and ([string]$old.auth -eq $Auth) -and ([string]$old.user -eq $User)){
                    $protectedPassword = [string]$old.passwordProtected
                }
            } catch {}
        }
    }
    $profile = [ordered]@{
        server = $Server
        auth = $Auth
        user = $User
        passwordProtected = $protectedPassword
        database = $Database
        savedAt = (Get-Date).ToString("o")
    }
    [IO.File]::WriteAllText($ProfilePath,($profile | ConvertTo-Json -Depth 4),[Text.Encoding]::UTF8)
}

function Load-SqlProfile {
    if(-not (Test-Path $ProfilePath)){ return $null }
    try {
        $p = Get-Content $ProfilePath -Raw | ConvertFrom-Json
        if([string]::IsNullOrWhiteSpace([string]$p.server)){ return $null }
        return $p
    } catch {
        return $null
    }
}

function Unprotect-ProfilePassword {
    param($Profile)
    if($null -eq $Profile -or [string]$Profile.auth -ne "sql"){ return "" }
    $raw = [string]$Profile.passwordProtected
    if([string]::IsNullOrWhiteSpace($raw)){ return "" }
    try {
        $secure = ConvertTo-SecureString $raw
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
    } catch { return "" }
}

function Open-SqlSession {
    param([string]$Server,[string]$Auth,[string]$User,[string]$Password)
    $serverToUse = $Server
    try {
        if($Server -match '^([^\\]+)\\(.+)
    $cmd = $cn.CreateCommand()
    $cmd.CommandText = "SELECT name FROM sys.databases WHERE state_desc='ONLINE' AND HAS_DBACCESS(name)=1 ORDER BY name;"
    $reader = $cmd.ExecuteReader()
    $dbs = @()
    while($reader.Read()){ $dbs += [string]$reader.GetString(0) }
    $reader.Close()

    $sid = [guid]::NewGuid().ToString()
    $Sessions[$sid] = @{ connection=$cn; databases=$dbs; server=$Server; auth=$Auth; user=$User }
    $script:ActiveSessionId = $sid
    return @{sessionId=$sid;server=$Server;auth=$Auth;user=$User;databases=$dbs}
}

function Ensure-ActiveSession {
    if($script:ActiveSessionId -and $Sessions.ContainsKey($script:ActiveSessionId)){
        try {
            $sess = $Sessions[$script:ActiveSessionId]
            if($sess.connection.State -eq [System.Data.ConnectionState]::Open){
                $db = ""
                if($sess.ContainsKey("database")){ $db = [string]$sess.database }
                return @{sessionId=$script:ActiveSessionId;server=$sess.server;auth=$sess.auth;user=$sess.user;databases=$sess.databases;database=$db}
            }
        } catch {}
    }
    return $null
}

function Get-HomeHtml {
@"
<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Capitan Rodolfo - SQL local</title>
<style>
:root{--bg:#0d0d0f;--card:#17171b;--line:#34343b;--orange:#ff7a00;--text:#f5f5f6;--muted:#aaaab2;--ok:#35d07f;--bad:#ff6b6b}
*{box-sizing:border-box}body{margin:0;background:radial-gradient(circle at 30% 0,#21170f,#0d0d0f 42%);color:var(--text);font-family:Segoe UI,Arial,sans-serif;min-height:100vh}
.wrap{width:min(1120px,94vw);margin:28px auto}.top{display:flex;justify-content:space-between;align-items:center;margin-bottom:18px}.ver{background:var(--orange);color:#111;padding:7px 10px;border-radius:999px;font-weight:900;font-size:12px}
.grid{display:grid;grid-template-columns:350px 1fr;gap:16px}.card{background:#15130ff2;border:1px solid #6e583a55;border-radius:16px;padding:18px}
h1{margin:0 0 4px}.muted{color:var(--muted);font-size:13px;line-height:1.5}label{display:block;font-size:12px;color:var(--muted);margin:13px 0 6px}
input,select{width:100%;background:#0f0f12;border:1px solid #3a3a41;color:white;padding:12px;border-radius:11px}
button{width:100%;border:0;border-radius:12px;padding:13px;margin-top:14px;background:linear-gradient(135deg,#ff7a00,#ff9630);font-weight:900;cursor:pointer}
.status{margin-top:14px;padding:11px;border:1px solid var(--line);border-radius:11px;color:var(--muted);font-size:13px}.ok{color:#86e8b2;border-color:#235f43}.bad{color:#ffaaaa;border-color:#6b2a2a}
.cols{display:grid;grid-template-columns:1fr 1fr;gap:16px}.list{display:grid;gap:8px;max-height:520px;overflow:auto}.item,.table{border:1px solid #34343b;background:#121216;color:#eee;padding:10px;border-radius:10px}.item{cursor:pointer}.item:hover,.item.active{border-color:var(--orange);background:#21170f}
.note{margin-top:15px;font-size:12px;color:var(--muted)}
.heroTop{display:flex;align-items:center;justify-content:space-between;gap:18px}
.rodolfoMini{display:none}
.rCap{position:absolute;left:22px;top:2px;width:76px;height:34px;background:var(--orange);border:4px solid #111116;border-radius:50% 50% 12% 12%;z-index:3}
.rCap:after{content:"";position:absolute;right:-28px;bottom:-3px;width:48px;height:11px;background:var(--orange);border:4px solid #111116;border-radius:50%}
.rHead{position:absolute;left:35px;top:28px;width:58px;height:64px;background:#f0aa78;border:4px solid #111116;border-radius:44% 44% 46% 46%}
.rEye{position:absolute;top:51px;width:6px;height:8px;background:#111;border-radius:50%;z-index:4}.rEye.l{left:52px}.rEye.r{left:74px}
.rMust{position:absolute;left:49px;top:70px;width:32px;height:10px;background:#19191d;border-radius:50%;z-index:4}
.rBody{position:absolute;left:28px;bottom:0;width:72px;height:32px;background:#2b2b33;border:4px solid #111116;border-radius:14px 14px 8px 8px}
.rTie{position:absolute;left:60px;bottom:2px;width:12px;height:30px;background:var(--orange);clip-path:polygon(35% 0,65% 0,85% 75%,50% 100%,15% 75%);z-index:4}
.dispatchCard{margin-top:18px;background:#17171bf2;border:1px solid var(--line);border-radius:20px;padding:20px}
.dispatchHead{display:flex;justify-content:space-between;align-items:center;gap:12px;margin-bottom:12px}.dispatchHead h2{margin:0}.query{font-size:11px;color:#ffb06a}
.tableWrap{overflow:auto;max-height:420px;border:1px solid #34343b;border-radius:12px}.dataGrid{border-collapse:collapse;width:100%;font-size:12px;min-width:720px}.dataGrid th,.dataGrid td{padding:9px 10px;border-bottom:1px solid #2b2b31;border-right:1px solid #24242a;text-align:left;white-space:nowrap}.dataGrid th{position:sticky;top:0;background:#21170f;color:#ffb06a;z-index:1}.dataGrid td{background:#111116}
.continueMap{display:none;margin-top:14px;background:linear-gradient(135deg,#2dd9ff,#34f5a5);color:#061116}.continueMap.show{display:block}
@media(max-width:900px){.grid,.cols{grid-template-columns:1fr}.rodolfoMini{transform:scale(.9);transform-origin:right center}}
</style>
</head>
<body>
<div class="wrap">
<div class="top"><div><strong>DoingLio - CAPITÁN RODOLFO</strong><div class="muted">Conector SQL local</div></div><span class="ver">v$Version</span></div>
<div class="grid">
<section class="card">
<div class="heroTop">
<div><div style="font-size:9px;letter-spacing:.22em;color:#ff9630;font-weight:900">CAPITÁN RODOLFO · NÚCLEO · DATOS</div><h1>Conexion SQL</h1><div class="muted">Servicio local en segundo plano. La conexión queda guardada en esta PC.</div></div>
<div class="rodolfoMini" aria-label="Capitan Rodolfo">
  <div class="rCap"></div><div class="rHead"></div><div class="rEye l"></div><div class="rEye r"></div><div class="rMust"></div><div class="rBody"></div><div class="rTie"></div>
</div>
</div>
<div id="status" class="status">Servicio SQL local v$Version listo.</div><label>Servidor / instancia</label><input id="server" value="$env:COMPUTERNAME\SQLEXPRESS" autocomplete="off">
<label>Autenticacion</label>
<select id="auth"><option value="sql">Usuario y contrasena SQL Server</option><option value="windows">Windows</option></select>
<div id="sqlCreds"><label>Usuario SQL</label><input id="user" autocomplete="username"><label>Contraseña</label><input id="password" type="password" autocomplete="current-password" placeholder="Ingresá la contraseña la primera vez"></div>
<div id="credentialState" class="note">Buscando conexión guardada…</div>
<button id="connect">Conectar y guardar</button>
<button id="detectSql" type="button" style="background:#24211c;color:#ffd0a0;border:1px solid #6e583a55">Detectar SQL Server de esta PC</button>
<div id="diag" class="status">Diagnóstico: esperando prueba.</div>
<button id="goMap" class="continueMap" type="button">Continuar al Mapa Vivo -></button>
<div class="note">La contraseña queda protegida por Windows. El archivo sql_profile.json se crea recién después de una conexión correcta.</div>
</section>
<section class="card">
<div class="cols"><div><h3>Bases</h3><div id="dbs" class="list"><div class="item">Conectate para ver bases</div></div></div><div><h3>Tablas</h3><div id="tables" class="list"><div class="table">Selecciona una base</div></div></div></div>
</section>
</div>
<section class="dispatchCard">
  <div class="dispatchHead"><h2>Tabla SURPLA</h2><span class="query">SELECT * FROM dbo.SURPLA</span></div>
  <div id="surpla" class="muted">Conectate y elegí una base para ver SURPLA.</div>
</section>
<section class="dispatchCard">
  <div class="dispatchHead"><h2>Despachos abiertos</h2><span class="query">SELECT * FROM Despachos WHERE estadovta = 0</span></div>
  <div id="dispatches" class="muted">Selecciona una base para ver los despachos.</div>
</section>
</div>
<script>
let sessionId=null;
const s=document.getElementById('status'), dbs=document.getElementById('dbs'), tables=document.getElementById('tables'), surpla=document.getElementById('surpla'), dispatches=document.getElementById('dispatches'), goMap=document.getElementById('goMap'), credentialState=document.getElementById('credentialState');
const serverInput=document.getElementById('server'),authInput=document.getElementById('auth'),userInput=document.getElementById('user'),passwordInput=document.getElementById('password');
let selectedDatabase=null;
function status(m,k=''){s.textContent=m;s.className='status '+k}
function updateAuth(){document.getElementById('sqlCreds').style.display=authInput.value==='windows'?'none':'block'}
authInput.onchange=updateAuth;
async function api(path,body){
 const r=await fetch(path,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body||{})});
 const j=await r.json().catch(()=>({})); if(!r.ok) throw new Error(j.error||('HTTP '+r.status)); return j;
}
async function getJson(path){
 const r=await fetch(path,{cache:'no-store'});const j=await r.json().catch(()=>({}));if(!r.ok)throw new Error(j.error||('HTTP '+r.status));return j;
}
function showDatabases(d,autoDb){
 sessionId=d.sessionId;
 dbs.innerHTML='';
 (d.databases||[]).forEach(name=>{
   const b=document.createElement('button');b.className='item';b.textContent=name;b.onclick=()=>loadTables(name,b);dbs.appendChild(b);
   if(autoDb&&name===autoDb)setTimeout(()=>loadTables(name,b),0);
 });
}
async function restoreSaved(){
 try{
  const p=await getJson('/api/profile-status');
  if(p.saved){
    serverInput.value=p.server||serverInput.value;authInput.value=p.auth||'sql';userInput.value=p.user||'';updateAuth();
    if(p.hasPassword){passwordInput.value='';passwordInput.placeholder='Contraseña guardada y protegida por Windows';credentialState.textContent='Usuario '+(p.user||'(Windows)')+' · contraseña guardada de forma segura · base '+(p.database||'sin elegir');}
    else credentialState.textContent='Conexión guardada sin contraseña SQL.';
  }else{
    credentialState.textContent='Todavía no hay usuario/contraseña guardados en esta PC.';
  }
  let state=await getJson('/api/state');
  if(!state.connected&&p.saved){
    status('Reconectando automáticamente…');
    state=await api('/api/reconnect-saved',{});
  }
  if(state.connected){
    serverInput.value=state.server||serverInput.value;authInput.value=state.auth||authInput.value;userInput.value=state.user||userInput.value;updateAuth();
    showDatabases(state,state.database||p.database);
    if(state.database) status('SQL conectado automáticamente · '+state.database,'ok');
    else status('SQL conectado automáticamente · elegí una base','ok');
  }
 }catch(e){status('Servicio activo, pero no pude recuperar la conexión guardada: '+e.message,'bad')}
}
document.getElementById('detectSql').onclick=async()=>{
 try{
  const r=await fetch('/api/local-sql',{cache:'no-store'}); const d=await r.json();
  const diag=document.getElementById('diag');
  if(d.instances&&d.instances.length){
   document.getElementById('server').value=d.instances[0].server;
   diag.textContent='Detectado: '+d.instances.map(x=>x.server+' ['+x.status+']').join(' · '); diag.className='status ok';
  }else{diag.textContent='No se detectó ninguna instancia SQL Server registrada en esta PC.';diag.className='status bad'}
 }catch(e){const diag=document.getElementById('diag');diag.textContent='Error de diagnóstico: '+e.message;diag.className='status bad'}
};
document.getElementById('connect').onclick=async()=>{
 try{
  status('Conectando…');
  const payload={server:serverInput.value.trim(),auth:authInput.value,user:userInput.value.trim(),password:passwordInput.value};
  const d=await api('/api/connect',payload); passwordInput.value=''; passwordInput.placeholder='Contraseña guardada y protegida por Windows'; credentialState.textContent='Usuario '+(payload.user||'(Windows)')+' · contraseña protegida y guardada localmente'; status('Conectado a '+d.server+' - elegí una base','ok');
  showDatabases(d,null);
 }catch(e){status('No se pudo conectar. '+e.message,'bad');const d=document.getElementById('diag');d.textContent='ERROR SQL: '+e.message;d.className='status bad'}
};
restoreSaved();
async function loadTables(database,el){
 try{
  selectedDatabase=database;
  [...document.querySelectorAll('#dbs .item')].forEach(x=>x.classList.remove('active'));el.classList.add('active');
  tables.innerHTML='<div class="table">Validando base…</div>';
  const d=await api('/api/tables',{sessionId,database});
  tables.innerHTML='';d.tables.forEach(t=>{const row=document.createElement('div');row.className='table';row.textContent=t.schema+'.'+t.name;tables.appendChild(row)});
  status('Base '+database+' conectada. Mostrando SELECT * FROM dbo.SURPLA','ok');
  const result=await api('/api/surpla',{sessionId,database});
  renderGrid(surpla,result,'SURPLA no tiene filas.');
  goMap.classList.add('show');
 }catch(e){
  status('Error: '+e.message,'bad')
 }
}
function renderGrid(container,data,emptyText){
 container.innerHTML='';
 if(!data.rows||!data.rows.length){container.innerHTML='<div class="muted">'+emptyText+'</div>';return}
 const wrap=document.createElement('div');wrap.className='tableWrap';
 const table=document.createElement('table');table.className='dataGrid';
 const thead=document.createElement('thead'),trh=document.createElement('tr');
 data.columns.forEach(c=>{const th=document.createElement('th');th.textContent=c;trh.appendChild(th)});thead.appendChild(trh);table.appendChild(thead);
 const tbody=document.createElement('tbody');
 data.rows.forEach(row=>{const tr=document.createElement('tr');data.columns.forEach(c=>{const td=document.createElement('td');const v=row[c];td.textContent=(v===null||v===undefined)?'':String(v);tr.appendChild(td)});tbody.appendChild(tr)});
 table.appendChild(tbody);wrap.appendChild(table);container.appendChild(wrap);
}
function renderDispatches(data){
 dispatches.innerHTML='';
 if(!data.rows||!data.rows.length){dispatches.innerHTML='<div class="muted">No hay despachos con estadovta = 0.</div>';return}
 const wrap=document.createElement('div');wrap.className='tableWrap';
 const table=document.createElement('table');table.className='dataGrid';
 const thead=document.createElement('thead'),trh=document.createElement('tr');
 data.columns.forEach(c=>{const th=document.createElement('th');th.textContent=c;trh.appendChild(th)});thead.appendChild(trh);table.appendChild(thead);
 const tbody=document.createElement('tbody');
 data.rows.forEach(row=>{const tr=document.createElement('tr');data.columns.forEach(c=>{const td=document.createElement('td');const v=row[c];td.textContent=(v===null||v===undefined)?'':String(v);tr.appendChild(td)});tbody.appendChild(tr)});
 table.appendChild(tbody);wrap.appendChild(table);dispatches.appendChild(wrap);
}
goMap.textContent='Ver tanques y surtidores →'; goMap.onclick=()=>{if(sessionId&&selectedDatabase) location.href='/mapa-vivo?sessionId='+encodeURIComponent(sessionId)+'&database='+encodeURIComponent(selectedDatabase)};
</script>
</body></html>
"@
}

try {
    $profile = Load-SqlProfile
    if($null -ne $profile){
        $savedPassword = Unprotect-ProfilePassword -Profile $profile
        $restored = Open-SqlSession -Server ([string]$profile.server) -Auth ([string]$profile.auth) -User ([string]$profile.user) -Password $savedPassword
        $savedDb = [string]$profile.database
        if(-not [string]::IsNullOrWhiteSpace($savedDb) -and $restored.databases -contains $savedDb){
            $Sessions[$restored.sessionId]["database"] = $savedDb
        }
        Write-Host "Conexion SQL restaurada: $([string]$profile.server) / $savedDb"
    }
} catch {
    $script:LastRestoreError = $_.Exception.Message
    Write-Host "No se pudo restaurar la conexion SQL guardada: $script:LastRestoreError"
}

try {
    $statusState = Ensure-ActiveSession
    if($null -ne $statusState){
        Write-ServiceStatus -State "running-connected" -Database ([string]$statusState.database) -Server ([string]$statusState.server) -User ([string]$statusState.user)
    } else {
        Write-ServiceStatus -State "running-no-sql" -ErrorMessage ([string]$script:LastRestoreError)
    }
} catch {
    Write-ServiceStatus -State "running-no-sql" -ErrorMessage $_.Exception.Message
}

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback,$Port)
$listener.Start()
Write-Host "Capitan Rodolfo local v$Version escuchando en http://127.0.0.1:$Port/"

try {
  while($true){
    $client = $listener.AcceptTcpClient()
    try {
      $stream = $client.GetStream()
      $req = Read-Request -Stream $stream
      if($null -eq $req){ continue }
      $script:CurrentOrigin = ""
      if($req.Headers.ContainsKey('origin')){ $script:CurrentOrigin = [string]$req.Headers['origin'] }

      $pathOnly = ($req.Path -split '\?')[0]
      if($req.Method -eq 'OPTIONS'){
        Send-Response $stream 204 'text/plain' ''
      }
      elseif($req.Method -eq 'GET' -and $pathOnly -eq '/health'){
        $st = Ensure-ActiveSession
        $db = ""
        if($null -ne $st){ $db = [string]$st.database }
        Send-Json $stream 200 @{ok=$true;service='Capitan Rodolfo Local';version=$Version;mode='background';scheduledTask=$TaskName;statusFile=$ServiceStatusPath;profileSaved=(Test-Path $ProfilePath);connected=($null -ne $st);database=$db}
      }
      elseif($req.Method -eq 'GET' -and $pathOnly -eq '/api/local-sql'){
        $instances = @()
        foreach($regPath in @('HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Microsoft SQL Server\Instance Names\SQL')){
          try {
            $props = Get-ItemProperty -Path $regPath -ErrorAction Stop
            foreach($prop in $props.PSObject.Properties){
              if($prop.Name -like 'PS*'){ continue }
              $instance = [string]$prop.Name
              $serviceName = 'MSSQLSERVER'
              if($instance -ne 'MSSQLSERVER'){ $serviceName = 'MSSQL
        $p = Load-SqlProfile
        if($null -eq $p){
          Send-Json $stream 200 @{saved=$false;server='';auth='sql';user='';database='';hasPassword=$false}
        } else {
          Send-Json $stream 200 @{
            saved=$true
            server=[string]$p.server
            auth=[string]$p.auth
            user=[string]$p.user
            database=[string]$p.database
            hasPassword=(-not [string]::IsNullOrWhiteSpace([string]$p.passwordProtected))
          }
        }
      }
      elseif($req.Method -eq 'POST' -and $pathOnly -eq '/api/reconnect-saved'){
        try {
          $p = Load-SqlProfile
          if($null -eq $p){ throw 'No hay una conexión SQL guardada en este equipo.' }
          $savedPassword = Unprotect-ProfilePassword -Profile $p
          $state = Open-SqlSession -Server ([string]$p.server) -Auth ([string]$p.auth) -User ([string]$p.user) -Password $savedPassword
          $savedDb = [string]$p.database
          if(-not [string]::IsNullOrWhiteSpace($savedDb) -and $state.databases -contains $savedDb){
            $Sessions[$state.sessionId]["database"] = $savedDb
          }
          $script:LastRestoreError = ''
          Write-ServiceStatus -State 'running-connected' -Database $savedDb -Server ([string]$p.server) -User ([string]$p.user)
          Send-Json $stream 200 @{sessionId=$state.sessionId;server=$state.server;auth=$state.auth;user=$state.user;databases=$state.databases;database=$savedDb;restored=$true}
        } catch {
          $script:LastRestoreError = $_.Exception.Message
          Write-ServiceStatus -State 'running-no-sql' -ErrorMessage $script:LastRestoreError
          Send-Json $stream 500 @{error=$_.Exception.Message}
        }
      }
      elseif($req.Method -eq 'GET' -and $pathOnly -eq '/api/openai/status'){
        Send-Json $stream 200 @{configured=(-not [string]::IsNullOrWhiteSpace((Get-OpenAIKey)));defaultEngine='openai';model='gpt-realtime-2.1'}
      }
      elseif($req.Method -eq 'POST' -and $pathOnly -eq '/api/openai/config'){
        try {$data=$req.Body|ConvertFrom-Json;Save-OpenAIKey -ApiKey ([string]$data.apiKey);Send-Json $stream 200 @{ok=$true;configured=$true;defaultEngine='openai'}} catch {Send-Json $stream 400 @{error=$_.Exception.Message}}
      }
      elseif($req.Method -eq 'POST' -and $pathOnly -eq '/api/openai/realtime-secret'){
        try {$key=Get-OpenAIKey;if([string]::IsNullOrWhiteSpace($key)){throw 'Configurá la clave de OpenAI en Núcleo → Inteligencia.'};Send-Json $stream 200 (New-OpenAIRealtimeSecret -ApiKey $key)} catch {Send-Json $stream 500 @{error=$_.Exception.Message}}
      }
      elseif($req.Method -eq 'POST' -and $pathOnly -eq '/api/ai/sql-read'){
        try {$data=$req.Body|ConvertFrom-Json;Send-Json $stream 200 (Invoke-ReadOnlySql -SessionId ([string]$data.sessionId) -Database ([string]$data.database) -Sql ([string]$data.sql))} catch {Send-Json $stream 400 @{error=$_.Exception.Message}}
      }
      elseif($req.Method -eq 'GET' -and $pathOnly -eq '/api/station-summary'){
        try {
          $state = Ensure-ActiveSession
          if($null -eq $state -or [string]::IsNullOrWhiteSpace([string]$state.database)){
            Send-Json $stream 200 @{
              connected=$false
              bridge=$true
              serviceMode='background'
              scheduledTask=$TaskName
              statusFile=$ServiceStatusPath
              profileSaved=(Test-Path $ProfilePath)
              restoreError=[string]$script:LastRestoreError
            }
            continue
          }
          $cn = $Sessions[$state.sessionId].connection
          $cn.ChangeDatabase([string]$state.database)

          $q = $cn.CreateCommand()
          $q.CommandText = "IF OBJECT_ID('dbo.Tanque') IS NULL SELECT 0 ELSE SELECT COUNT(*) FROM dbo.Tanque"
          $tankCount = [int]$q.ExecuteScalar()

          $q = $cn.CreateCommand()
          $q.CommandText = "IF OBJECT_ID('dbo.Surtan') IS NULL SELECT 0 ELSE SELECT COUNT(*) FROM dbo.Surtan"
          $hoseCount = [int]$q.ExecuteScalar()

          $q = $cn.CreateCommand()
          $q.CommandText = "IF OBJECT_ID('dbo.Surtan') IS NULL OR COL_LENGTH('dbo.Surtan','SURTIDOR') IS NULL SELECT 0 ELSE EXEC('SELECT COUNT(DISTINCT SURTIDOR) FROM dbo.Surtan WHERE SURTIDOR IS NOT NULL')"
          $pumpCount = [int]$q.ExecuteScalar()

          $q = $cn.CreateCommand()
          $q.CommandText = "IF OBJECT_ID('dbo.Despachos') IS NULL SELECT 0 AS cantidad,CAST(0 AS decimal(18,2)) AS litros,CAST(0 AS decimal(18,2)) AS pesos ELSE SELECT COUNT(*) cantidad,ISNULL(SUM(CAST(Litros AS decimal(18,2))),0) litros,ISNULL(SUM(CAST(pesos AS decimal(18,2))),0) pesos FROM dbo.Despachos"
          $rdr = $q.ExecuteReader()
          $dispatchCount = 0; $liters = 0; $pesos = 0
          if($rdr.Read()){
            $dispatchCount = [int]$rdr["cantidad"]
            $liters = [decimal]$rdr["litros"]
            $pesos = [decimal]$rdr["pesos"]
          }
          $rdr.Close()

          Send-Json $stream 200 @{
            connected=$true
            bridge=$true
            serviceMode='background'
            scheduledTask=$TaskName
            statusFile=$ServiceStatusPath
            database=[string]$state.database
            server=[string]$state.server
            tankCount=$tankCount
            hoseCount=$hoseCount
            pumpCount=$pumpCount
            dispatchCount=$dispatchCount
            liters=$liters
            pesos=$pesos
          }
        } catch {
          Send-Json $stream 500 @{error=$_.Exception.Message}
        }
      }
      elseif($req.Method -eq 'GET' -and $pathOnly -eq '/api/tanks'){
        try {
          $state = Ensure-ActiveSession
          if($null -eq $state -or [string]::IsNullOrWhiteSpace([string]$state.database)){
            Send-Json $stream 200 @{connected=$false}
            continue
          }

          $cn = $Sessions[$state.sessionId].connection
          $cn.ChangeDatabase([string]$state.database)

          $existsCmd = $cn.CreateCommand()
          $existsCmd.CommandText = "SELECT CASE WHEN OBJECT_ID('dbo.Tanque','U') IS NULL THEN 0 ELSE 1 END"
          $tableExists = ([int]$existsCmd.ExecuteScalar() -eq 1)
          if(-not $tableExists){
            Send-Json $stream 200 @{connected=$true;database=[string]$state.database;table='dbo.Tanque';tableExists=$false;columns=@();rowCount=0;rows=@()}
            continue
          }

          $q = $cn.CreateCommand()
          $q.CommandText = "SELECT TOP (200) * FROM dbo.Tanque"
          $q.CommandTimeout = 15
          $rdr = $q.ExecuteReader()
          try {
            $columns = New-Object System.Collections.Generic.List[string]
            for($i=0;$i -lt $rdr.FieldCount;$i++){ $columns.Add($rdr.GetName($i)) }

            $rows = New-Object System.Collections.Generic.List[object]
            while($rdr.Read()){
              $row = [ordered]@{}
              for($i=0;$i -lt $rdr.FieldCount;$i++){
                $value = $rdr.GetValue($i)
                if($value -is [DBNull]){ $value = $null }
                $row[$rdr.GetName($i)] = $value
              }
              $rows.Add([pscustomobject]$row)
            }

            Send-Json $stream 200 @{
              connected=$true
              database=[string]$state.database
              table='dbo.Tanque'
              tableExists=$true
              columns=$columns
              rowCount=$rows.Count
              rows=$rows
            }
          } finally {
            $rdr.Close()
          }
        } catch {
          Send-Json $stream 500 @{error=$_.Exception.Message}
        }
      }
      elseif($req.Method -eq 'GET' -and $pathOnly -eq '/api/state'){
        $state = Ensure-ActiveSession
        if($null -eq $state){
          Send-Json $stream 200 @{connected=$false}
        } else {
          Send-Json $stream 200 @{connected=$true;sessionId=$state.sessionId;server=$state.server;auth=$state.auth;user=$state.user;databases=$state.databases;database=$state.database}
        }
      }
      elseif($req.Method -eq 'GET' -and ($pathOnly -eq '/' -or $pathOnly -eq '/index.html')){
        Send-Response $stream 200 "text/html; charset=utf-8" (Get-HomeHtml)
      }
      elseif($req.Method -eq 'GET' -and $pathOnly -eq '/mapa-vivo'){
        try {
          $query = [System.Web.HttpUtility]::ParseQueryString(([uri]("http://127.0.0.1" + $req.Path)).Query)
          $sid = [string]$query['sessionId']
          $database = [string]$query['database']
          if(-not $Sessions.ContainsKey($sid)){ throw "Sesion SQL no valida." }
          $sess = $Sessions[$sid]
          if($sess.databases -notcontains $database){ throw "Base no autorizada." }

          $cn = $sess.connection
          $cn.ChangeDatabase($database)

          $dispatchIdColumn = $null
          $idMetaCmd = $cn.CreateCommand()
          $idMetaCmd.CommandText = @"
SELECT TOP 1 c.name
FROM sys.columns c
WHERE c.object_id = OBJECT_ID('dbo.Despachos')
  AND (
    LOWER(REPLACE(c.name,'_','')) IN ('iddespacho','iddespcho')
    OR LOWER(c.name) LIKE '%id%desp%'
    OR LOWER(c.name) LIKE '%desp%id%'
  )
ORDER BY CASE WHEN LOWER(REPLACE(c.name,'_',''))='iddespacho' THEN 0
              WHEN LOWER(REPLACE(c.name,'_',''))='iddespcho' THEN 1
              ELSE 2 END, c.column_id;
"@
          $dispatchIdValue = $idMetaCmd.ExecuteScalar()
          if($null -ne $dispatchIdValue -and $dispatchIdValue -isnot [DBNull]){
            $dispatchIdColumn = [string]$dispatchIdValue
          }

          $dispatchIdSelect = "NULL AS id_despacho"
          if(-not [string]::IsNullOrWhiteSpace($dispatchIdColumn)){
            $dispatchIdSelect = "d.[" + $dispatchIdColumn.Replace("]","]]") + "] AS id_despacho"
          }

          $cmd = $cn.CreateCommand()
          $cmd.CommandText = "SELECT " + $dispatchIdSelect + ", id_sale venta, surtidor, manguera, d.codart, p.descriimpresion, Litros, PPU, pesos, d.Ultime fecha, Ultime as hora FROM Despachos d INNER JOIN prod p ON d.codart = p.codart;"
          $reader = $cmd.ExecuteReader()
          $dispatchRows = New-Object System.Collections.Generic.List[object]
          while($reader.Read()){
            $dispatchRows.Add([pscustomobject]@{
              id_despacho = if($reader["id_despacho"] -is [DBNull]){""}else{[string]$reader["id_despacho"]}
              venta = if($reader["venta"] -is [DBNull]){""}else{[string]$reader["venta"]}
              surtidor = if($reader["surtidor"] -is [DBNull]){""}else{[string]$reader["surtidor"]}
              manguera = if($reader["manguera"] -is [DBNull]){""}else{[string]$reader["manguera"]}
              codart = if($reader["codart"] -is [DBNull]){""}else{[string]$reader["codart"]}
              producto = if($reader["descriimpresion"] -is [DBNull]){""}else{[string]$reader["descriimpresion"]}
              litros = if($reader["Litros"] -is [DBNull]){""}else{[string]$reader["Litros"]}
              ppu = if($reader["PPU"] -is [DBNull]){""}else{[string]$reader["PPU"]}
              pesos = if($reader["pesos"] -is [DBNull]){""}else{[string]$reader["pesos"]}
              fecha = if($reader["fecha"] -is [DBNull]){""}elseif($reader["fecha"] -is [DateTime]){([DateTime]$reader["fecha"]).ToString("dd/MM/yyyy HH:mm:ss")}else{[string]$reader["fecha"]}
              hora = if($reader["hora"] -is [DBNull]){""}elseif($reader["hora"] -is [DateTime]){([DateTime]$reader["hora"]).ToString("HH:mm:ss")}else{[string]$reader["hora"]}
            })
          }
          $reader.Close()

          $tankCmd = $cn.CreateCommand()
          $tankCmd.CommandText = "SELECT t.N_TANQUE, t.DENOMINACION, p.DESCRIIMPRESION, t.CAPACIDAD FROM Tanque t INNER JOIN prod p ON t.CODART = p.codart;"
          $tankReader = $tankCmd.ExecuteReader()
          $tankRows = New-Object System.Collections.Generic.List[object]
          while($tankReader.Read()){
            $tankRows.Add([pscustomobject]@{
              numero = if($tankReader["N_TANQUE"] -is [DBNull]){""}else{[string]$tankReader["N_TANQUE"]}
              denominacion = if($tankReader["DENOMINACION"] -is [DBNull]){""}else{[string]$tankReader["DENOMINACION"]}
              producto = if($tankReader["DESCRIIMPRESION"] -is [DBNull]){""}else{[string]$tankReader["DESCRIIMPRESION"]}
              capacidad = if($tankReader["CAPACIDAD"] -is [DBNull]){""}else{[string]$tankReader["CAPACIDAD"]}
            })
          }
          $tankReader.Close()
          $tankCount = $tankRows.Count

          $hoseSurtidorSelect = "NULL"
          $hoseMetaCmd = $cn.CreateCommand()
          $hoseMetaCmd.CommandText = "SELECT COUNT(*) FROM sys.columns WHERE object_id=OBJECT_ID('dbo.Surtan') AND UPPER(name)='SURTIDOR';"
          if(([int]$hoseMetaCmd.ExecuteScalar()) -gt 0){ $hoseSurtidorSelect = "s.SURTIDOR" }
          $hoseCmd = $cn.CreateCommand()
          $hoseCmd.CommandText = "SELECT s.N_TANQUE, t.DENOMINACION, " + $hoseSurtidorSelect + " AS SURTIDOR, s.MANGUERA, p.DESCRIIMPRESION FROM Surtan s INNER JOIN Tanque t ON s.N_TANQUE = t.N_TANQUE INNER JOIN prod p ON s.CODART = p.Codart;"
          $hoseReader = $hoseCmd.ExecuteReader()
          $hoseRows = New-Object System.Collections.Generic.List[object]
          while($hoseReader.Read()){
            $hoseRows.Add([pscustomobject]@{
              tanque = if($hoseReader["N_TANQUE"] -is [DBNull]){""}else{[string]$hoseReader["N_TANQUE"]}
              denominacion = if($hoseReader["DENOMINACION"] -is [DBNull]){""}else{[string]$hoseReader["DENOMINACION"]}
              surtidor = if($hoseReader["SURTIDOR"] -is [DBNull]){""}else{[string]$hoseReader["SURTIDOR"]}
              manguera = if($hoseReader["MANGUERA"] -is [DBNull]){""}else{[string]$hoseReader["MANGUERA"]}
              producto = if($hoseReader["DESCRIIMPRESION"] -is [DBNull]){""}else{[string]$hoseReader["DESCRIIMPRESION"]}
            })
          }
          $hoseReader.Close()
          $hoseCount = $hoseRows.Count

          $realSurtidores = @($hoseRows | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.surtidor) } | ForEach-Object { [string]$_.surtidor } | Sort-Object -Unique)
          $surtidorCountText = if($realSurtidores.Count -gt 0){ [string]$realSurtidores.Count } else { "?" }

          $hoseCards = ""
          foreach($h in $hoseRows){
            $ht = [System.Net.WebUtility]::HtmlEncode([string]$h.tanque)
            $hd = [System.Net.WebUtility]::HtmlEncode([string]$h.denominacion)
            $hs = [System.Net.WebUtility]::HtmlEncode([string]$h.surtidor)
            $hm = [System.Net.WebUtility]::HtmlEncode([string]$h.manguera)
            $hp = [System.Net.WebUtility]::HtmlEncode([string]$h.producto)
            $surtidorLabel = if([string]::IsNullOrWhiteSpace($hs)){ "S?" } else { "S$hs" }
            $hoseCards += "<div class='hoseRow'><b>T$ht</b><span class='arrow'>&rarr;</span><strong>$surtidorLabel</strong><span class='arrow'>&rarr;</span><strong>M$hm</strong><span class='hoseProduct'>$hp</span><small>$hd</small></div>"
          }
          if([string]::IsNullOrWhiteSpace($hoseCards)){
            $hoseCards = "<div class='empty'>Sin relaciones Tanque → Surtidor → Manguera para mostrar.</div>"
          }

          $tankCards = ""
          foreach($t in $tankRows){
            $tn = [System.Net.WebUtility]::HtmlEncode([string]$t.numero)
            $td = [System.Net.WebUtility]::HtmlEncode([string]$t.denominacion)
            $tp = [System.Net.WebUtility]::HtmlEncode([string]$t.producto)
            $tc = [System.Net.WebUtility]::HtmlEncode([string]$t.capacidad)
            $tankHoses = @($hoseRows | Where-Object { [string]$_.tanque -eq [string]$t.numero })
            $tankHoseText = ""
            foreach($th in $tankHoses){
              if($tankHoseText){ $tankHoseText += " | " }
              $tankHoseText += "S$([System.Net.WebUtility]::HtmlEncode([string]$th.surtidor)) / M$([System.Net.WebUtility]::HtmlEncode([string]$th.manguera)) - $([System.Net.WebUtility]::HtmlEncode([string]$th.producto))"
            }
            if(-not $tankHoseText){ $tankHoseText = "Sin mangueras asociadas" }
            $tankCards += "<button type='button' class='tankRow tankPick' data-num='$tn' data-den='$td' data-prod='$tp' data-cap='$tc' data-hoses='$tankHoseText'><b>T$tn</b><span class='tankName'>$td</span><span class='tankProduct'>$tp</span><strong>$tc L</strong></button>"
          }
          if([string]::IsNullOrWhiteSpace($tankCards)){
            $tankCards = "<div class='empty'>Sin tanques para mostrar.</div>"
          }

          $safeDb = [System.Net.WebUtility]::HtmlEncode($database)
          $cards = ""
          foreach($d in $dispatchRows){
            $idDespacho = [System.Net.WebUtility]::HtmlEncode([string]$d.id_despacho)
            $venta = [System.Net.WebUtility]::HtmlEncode([string]$d.venta)
            $surt = [System.Net.WebUtility]::HtmlEncode([string]$d.surtidor)
            $mang = [System.Net.WebUtility]::HtmlEncode([string]$d.manguera)
            $prod = [System.Net.WebUtility]::HtmlEncode([string]$d.producto)
            $lit = [System.Net.WebUtility]::HtmlEncode([string]$d.litros)
            $ppu = [System.Net.WebUtility]::HtmlEncode([string]$d.ppu)
            $pes = [System.Net.WebUtility]::HtmlEncode([string]$d.pesos)
            $hora = [System.Net.WebUtility]::HtmlEncode([string]$d.hora)
            $cards += "<button type='button' class='dispatchRow salePick' data-id-despacho='$idDespacho' data-venta='$venta' data-surtidor='$surt' data-manguera='$mang' data-producto='$prod' data-litros='$lit' data-ppu='$ppu' data-pesos='$pes' data-hora='$hora'><b>#$venta</b><span>Surt. $surt - Mang. $mang</span><span class='product'>$prod</span><span>$lit L - PPU $ppu - <strong>&#36;$pes</strong></span><small>$hora</small></button>"
          }
          if([string]::IsNullOrWhiteSpace($cards)){
            $cards = "<div class='empty'>Sin despachos para mostrar.</div>"
          }
          $dispatchCount = $dispatchRows.Count

          $html = @"
<!doctype html>
<html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Mapa Vivo - Capitan Rodolfo</title>
<style>
:root{--bg:#050b12;--panel:#09141e;--line:#254154;--orange:#ff7138;--cyan:#2dd9ff;--green:#34f5a5;--text:#eaf6ff;--muted:#7ea2bb}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font-family:Segoe UI,Arial,sans-serif}
.top{display:flex;justify-content:space-between;align-items:center;gap:12px;padding:12px 18px;background:#07111a;border-bottom:1px solid var(--line);position:sticky;top:0;z-index:5}
.left{display:flex;align-items:center;gap:12px;flex-wrap:wrap}.badge{background:#11212c;border:1px solid #2b5267;border-radius:999px;padding:7px 11px;font-size:12px}.ok{color:var(--green)}.ver{color:#061116;background:var(--orange);border-radius:999px;padding:6px 9px;font-size:12px;font-weight:900}.navlink{color:#ccefff;text-decoration:none;border:1px solid #2b5267;border-radius:999px;padding:7px 11px;font-size:12px;font-weight:800}.navlink:hover{border-color:#2dd9ff;color:#fff}
.stage{padding:14px}.mapWrap{position:relative;max-width:1600px;margin:auto}.mapWrap>img{display:block;width:100%;height:auto;border:1px solid #173244;border-radius:18px;background:#050b12}
.dispatchOverlay{position:absolute;left:64.4%;top:60.4%;width:31.3%;height:18.5%;background:#07131df7;border:2px solid #2dd9ff;border-radius:18px;padding:12px 14px;overflow:hidden;box-shadow:0 8px 24px #0009}
.dispatchTitle{display:flex;justify-content:space-between;gap:10px;align-items:center;margin-bottom:8px;font-size:12px;letter-spacing:2px;color:#89a9bd}.dispatchTitle strong{color:#eaf6ff;letter-spacing:0}
.dispatchList{height:calc(100% - 28px);overflow:auto;padding-right:5px}.dispatchRow{display:grid;width:100%;grid-template-columns:auto auto 1fr auto auto;gap:8px;align-items:center;border:0;border-bottom:1px solid #173244;padding:6px 0;font-size:11px;white-space:nowrap;background:transparent;color:#eaf6ff;text-align:left;cursor:pointer}.dispatchRow:hover,.dispatchRow.active{background:#0d2633}.dispatchRow b{color:#34f5a5}.dispatchRow .product{overflow:hidden;text-overflow:ellipsis}.dispatchRow strong{color:#ffb06a}.dispatchRow small{color:#7ea2bb}.empty{color:#7ea2bb;padding:14px 0}
.tankOverlay{position:absolute;left:26.3%;top:31%;width:19.5%;max-height:31%;background:#09141ef2;border:2px solid #ff7138;border-radius:16px;padding:10px 12px;overflow:hidden;box-shadow:0 8px 24px #0009}
.tankTitle{display:flex;justify-content:space-between;align-items:center;gap:8px;margin-bottom:7px;font-size:11px;letter-spacing:2px;color:#89a9bd}.tankTitle strong{color:#eaf6ff;letter-spacing:0}
.tankList{max-height:210px;overflow:auto;padding-right:4px}.tankRow{display:grid;width:100%;grid-template-columns:auto 1fr auto;gap:6px;align-items:center;border:0;border-bottom:1px solid #173244;padding:5px 0;font-size:10px;background:transparent;color:#eaf6ff;text-align:left;cursor:pointer}.tankRow:hover,.tankRow.active{background:#2a1710}.tankRow b{color:#ff9d2e}.tankName{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.tankProduct{grid-column:1/-1;color:#7ea2bb;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.tankRow strong{color:#2dd9ff}
.hoseOverlay{position:absolute;left:46%;top:26%;width:17%;max-height:28%;background:#07131df2;border:2px solid #34f5a5;border-radius:16px;padding:10px 12px;overflow:hidden;box-shadow:0 8px 24px #0009}
.hoseTitle{display:flex;justify-content:space-between;align-items:center;gap:8px;margin-bottom:7px;font-size:10px;letter-spacing:1.5px;color:#89a9bd}.hoseTitle strong{color:#eaf6ff;letter-spacing:0}
.hoseList{max-height:180px;overflow:auto;padding-right:4px}.hoseRow{display:grid;grid-template-columns:auto auto auto auto auto 1fr;gap:5px;align-items:center;border-bottom:1px solid #173244;padding:5px 0;font-size:10px}.hoseRow b{color:#ff9d2e}.hoseRow strong{color:#34f5a5}.hoseRow .arrow{color:#2dd9ff}.hoseProduct{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.hoseRow small{grid-column:1/-1;color:#7ea2bb;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.tankHotspot{position:absolute;left:26.2%;top:23.8%;width:18.8%;height:6.5%;border:1px dashed #ff7138;background:#ff713812;color:#ffb06a;border-radius:10px;cursor:pointer;font-weight:900;letter-spacing:2px;z-index:3}
.hoseHotspot{position:absolute;left:46%;top:18%;width:17%;height:6.5%;border:1px dashed #34f5a5;background:#34f5a512;color:#8fffd0;border-radius:10px;cursor:pointer;font-weight:900;letter-spacing:1.4px;z-index:3}
.dispatchHotspot{position:absolute;left:70%;top:55%;width:22%;height:5.5%;border:1px dashed #2dd9ff;background:#2dd9ff12;color:#8fefff;border-radius:10px;cursor:pointer;font-weight:900;letter-spacing:1.2px;z-index:3}
.parentClose{border:0;background:transparent;color:#fff;cursor:pointer;font-size:15px;font-weight:900;padding:0 3px;margin:0;width:auto}
.detailCard{position:absolute;z-index:6;background:#07131df7;border:2px solid #ff7138;border-radius:16px;padding:12px 14px;box-shadow:0 10px 30px #000b;display:none}.detailCard.show{display:block}
#tankDetail{left:27%;top:64%;width:30%}#saleOnPump{left:50.3%;top:30%;width:20%;border-color:#34f5a5}
.detailTitle{font-size:11px;letter-spacing:1.5px;color:#89a9bd;margin-bottom:8px}.detailGrid{display:grid;grid-template-columns:auto 1fr;gap:6px 10px;font-size:12px}.detailGrid b{color:#fff}.detailGrid span{color:#8fb3c9}.detailClose{position:absolute;right:8px;top:7px;border:0;background:transparent;color:#fff;cursor:pointer;font-size:16px}
.paymentBtn{width:100%;margin-top:12px;border:0;border-radius:10px;padding:10px 12px;background:linear-gradient(135deg,#ff7138,#ff9d2e);color:#101010;font-weight:900;cursor:pointer}
#paymentPanel{left:50.3%;top:54%;width:20%;border-color:#ff7138}
.paymentPending{color:#ffb06a;font-size:12px;line-height:1.5}
.pumpCountBadge{position:absolute;left:48.7%;top:19.2%;z-index:4;background:#07131de8;border:1px solid #2dd9ff;color:#b9efff;border-radius:999px;padding:7px 11px;font-size:11px;font-weight:900;letter-spacing:1px}.pumpCountBadge strong{color:#fff}
.truckHotspot{position:absolute;left:3.5%;top:34%;width:23%;height:31%;z-index:4;border:1px solid transparent;background:transparent;border-radius:18px;cursor:pointer;color:transparent}.truckHotspot:hover{border-color:#ff7138;background:#ff71380c;box-shadow:0 0 26px #ff713833}.truckHotspot.feed{animation:truckFeedPulse .75s ease}
@keyframes truckFeedPulse{0%,100%{box-shadow:none}45%{box-shadow:0 0 0 10px #ff713822,0 0 38px #ff713888}}
.receiptModal{position:fixed;inset:0;z-index:60;display:none;place-items:center;background:#000b;padding:18px}.receiptModal.show{display:grid}
.receiptBox{width:min(650px,94vw);max-height:90vh;overflow:auto;background:#101820;border:1px solid #2d4759;border-radius:20px;padding:22px;box-shadow:0 30px 80px #000c;position:relative}.receiptBox h2{margin:0 0 8px}.receiptBox p{color:#8fb3c9;line-height:1.5}
.receiptClose{position:absolute;right:12px;top:10px;width:auto;margin:0;border:0;background:transparent;color:#fff;font-size:22px;cursor:pointer}
.receiptUpload{display:block;border:1px dashed #ff7138;background:#ff71380d;border-radius:14px;padding:18px;text-align:center;font-weight:900;cursor:pointer}.receiptUpload input{display:none}
.receiptStatus{margin-top:12px;border:1px solid #29495e;border-radius:11px;padding:10px;color:#a8c6d8;font-size:12px}.receiptStatus.ok{border-color:#247450;color:#8df0b8}.receiptStatus.bad{border-color:#7c3131;color:#ffb2b2}
.receiptPreview{margin-top:12px;border:1px solid #29495e;border-radius:12px;padding:10px;display:none}.receiptPreview.show{display:block}.receiptPreview img{max-width:100%;max-height:260px;display:block;margin:auto;border-radius:8px}.receiptPreview .pdf{padding:18px;text-align:center;color:#ffb06a;font-weight:900}
.revalLogin{display:none;margin-top:14px;padding:14px;border:1px solid #67482c;border-radius:12px;background:#1b1510}.revalLogin.show{display:block}.revalLogin input{width:100%;margin-top:7px;padding:11px;border-radius:9px;border:1px solid #3b4650;background:#091018;color:#fff}.revalLogin button{width:100%;margin-top:10px;padding:11px;border:0;border-radius:9px;background:#ff7138;font-weight:900;cursor:pointer}
.receiptResult{display:none;margin-top:14px}.receiptResult.show{display:block}
.invoice-paper{background:#fff;color:#1c2330;border-radius:14px;overflow:hidden;box-shadow:0 16px 50px #0008;border:1px solid #dfe5ea;font-family:Segoe UI,Arial,sans-serif}
.invoice-head{display:flex;justify-content:space-between;gap:16px;padding:18px 20px;border-bottom:1px solid #e4e8ec;background:linear-gradient(135deg,#fbfcfd,#f1f5f7)}
.invoice-head span{font-size:10px;letter-spacing:1.6px;color:#718092;font-weight:900}.invoice-head h3{margin:5px 0 3px;color:#17202b;font-size:19px}.invoice-head p{margin:0;color:#667483;font-size:11px}
.invoice-type{text-align:right}.invoice-type b{display:block;color:#ff5a3d;font-size:16px}.invoice-type small{display:block;margin-top:5px;color:#667483}
.invoice-meta{display:grid;grid-template-columns:repeat(3,1fr);gap:1px;background:#e6eaee}.invoice-meta>div{background:#fff;padding:11px 14px}.invoice-meta span,.invoice-footer span,.document-flow span{display:block;color:#788797;font-size:9px;text-transform:uppercase;letter-spacing:1px}.invoice-meta b{display:block;margin-top:3px;font-size:12px}
.document-flow{display:grid;grid-template-columns:1fr auto 1fr;gap:10px;align-items:center;padding:14px 18px;border-bottom:1px solid #e5e9ed}.document-flow b{display:block;margin:4px 0;font-size:12px}.document-flow small{display:block;color:#778491;font-size:10px}.flow-arrow{font-size:22px;color:#ff5a3d;font-weight:900}
.invoice-lines{padding:14px 18px}.invoice-line{display:grid;grid-template-columns:1fr 70px 95px 95px;gap:8px;padding:7px 0;border-bottom:1px solid #edf0f2;font-size:10px}.invoice-line-head{font-weight:900;color:#718092;text-transform:uppercase;letter-spacing:.7px}.invoice-line span:not(:first-child){text-align:right}
.invoice-totals{padding:10px 18px 14px;margin-left:auto;width:min(360px,100%)}.invoice-totals>div{display:flex;justify-content:space-between;gap:16px;padding:5px 0;color:#566473;font-size:11px}.invoice-grand{margin-top:5px;padding-top:10px!important;border-top:2px solid #1d2630;color:#111!important;font-size:15px!important}.invoice-grand b{color:#ff5a3d;font-size:18px}
.invoice-footer{display:grid;grid-template-columns:1fr 1fr;gap:12px;padding:12px 18px;background:#f5f7f8;border-top:1px solid #e5e9ed}.invoice-footer b{display:block;color:#273443;margin-top:3px;font-size:10px}
.invoice-empty{padding:16px;color:#667483;text-align:center;font-size:11px}
@media(max-width:650px){.invoice-line{grid-template-columns:1fr 48px 70px 75px;font-size:9px}.invoice-head{padding:14px}.invoice-meta{grid-template-columns:1fr}.invoice-footer{grid-template-columns:1fr}}
.receiptFly{position:fixed;z-index:90;width:180px;padding:10px;border:2px solid #ff7138;border-radius:12px;background:#fff;color:#111;font-weight:900;font-size:11px;box-shadow:0 12px 30px #0008;pointer-events:none;transition:transform .78s cubic-bezier(.2,.8,.2,1),opacity .78s ease;transform-origin:center}
.note{padding:0 18px 18px;color:var(--muted);font-size:13px}
@media(max-width:900px){.dispatchOverlay,.tankOverlay,.hoseOverlay,.detailCard{position:static;width:auto;height:auto;max-height:none;margin-top:12px}.tankHotspot,.hoseHotspot,.dispatchHotspot,.truckHotspot{display:none}.pumpCountBadge{position:static;display:inline-block;margin:8px 0}.tankList,.hoseList{max-height:260px}.dispatchRow{grid-template-columns:1fr 1fr}.dispatchRow .product{grid-column:1/-1}.detailCard{display:none}.detailCard.show{display:block}}
</style></head>
<body>
<header class="top"><div class="left"><a class="navlink" href="http://127.0.0.1:8790/">← DoingLio</a><a class="navlink" href="http://127.0.0.1:8790/capitan-rodolfo/index.html">← Capitán</a><span class="badge ok"><span style="color:#34f5a5">&#9679;</span> SQL conectado</span><span class="badge">Base: $safeDb</span></div><span class="ver">v$Version</span></header>
<main class="stage">
  <div class="mapWrap">
    <img src="http://127.0.0.1:8790/capitan-rodolfo/assets/capitan-rodolfo-mapa-vivo.svg" alt="Mapa Vivo de Capitan Rodolfo">
    <button id="truckHotspot" class="truckHotspot" type="button" title="Subir comprobante al camion" aria-label="Subir comprobante al camion">CAMION</button>
    <div class="pumpCountBadge">SURTIDORES (<strong>$surtidorCountText</strong>)</div>
    <button id="tankHotspot" class="tankHotspot" type="button">TANQUES ($tankCount)</button>
    <section id="tankPanel" class="tankOverlay" style="display:none">
      <div class="tankTitle"><span>TANQUES REALES</span><span><strong>$tankCount</strong> <button id="closeTankPanel" class="parentClose" type="button">x</button></span></div>
      <div class="tankList">$tankCards</div>
    </section>
    <button id="hoseHotspot" class="hoseHotspot" type="button">TANQUE &rarr; SURTIDOR &rarr; MANGUERA ($hoseCount)</button>
    <section id="hosePanel" class="hoseOverlay" style="display:none">
      <div class="hoseTitle"><span>TANQUE &rarr; SURTIDOR &rarr; MANGUERA</span><span><strong>$hoseCount</strong> <button id="closeHosePanel" class="parentClose" type="button">x</button></span></div>
      <div class="hoseList">$hoseCards</div>
    </section>
    <button id="dispatchHotspot" class="dispatchHotspot" type="button" style="display:none">VENTAS / DESPACHOS ($dispatchCount)</button>
    <section id="dispatchPanel" class="dispatchOverlay">
      <div class="dispatchTitle"><span>VENTAS / DESPACHOS</span><span><strong>$dispatchCount</strong> <button id="closeDispatchPanel" class="parentClose" type="button">x</button></span></div>
      <div class="dispatchList">$cards</div>
    </section>
    <section id="tankDetail" class="detailCard">
      <button class="detailClose" type="button" data-close="tankDetail">x</button>
      <div class="detailTitle">DETALLE DEL TANQUE</div>
      <div id="tankDetailBody" class="detailGrid"></div>
    </section>
    <section id="saleOnPump" class="detailCard">
      <button class="detailClose" type="button" data-close="saleOnPump">x</button>
      <div id="salePumpTitle" class="detailTitle">VENTA EN SURTIDOR</div>
      <div id="salePumpBody" class="detailGrid"></div>
      <button id="viewPaymentBtn" class="paymentBtn" type="button">VER PAGO</button>
    </section>
    <section id="paymentPanel" class="detailCard">
      <button class="detailClose" type="button" data-close="paymentPanel">x</button>
      <div class="detailTitle">PAGO DE LA VENTA</div>
      <div id="paymentBody" class="detailGrid"></div>
      <div class="paymentPending">Consulta de pago pendiente de definir. No se muestran datos inventados.</div>
    </section>
  </div>
</main>
<div id="receiptModal" class="receiptModal">
  <section class="receiptBox">
    <button id="receiptClose" class="receiptClose" type="button">x</button>
    <h2>Comprobante del camion</h2>
    <p>Subi una factura, recibo, transferencia, ticket o PDF. El camion recibe el archivo y Revalsoft IA lo analiza con la misma logica de TEST.</p>
    <label id="receiptUploadLabel" class="receiptUpload">SUBIR COMPROBANTE
      <input id="receiptFile" type="file" accept="image/*,.pdf">
    </label>
    <div id="receiptStatus" class="receiptStatus">Esperando archivo...</div>
    <div id="receiptPreview" class="receiptPreview"></div>
    <div id="revalLogin" class="revalLogin">
      <b>Iniciar sesion Revalsoft IA</b>
      <div style="font-size:12px;color:#b69c84;margin-top:4px">Se pide solo si este navegador local todavia no tiene una sesion valida.</div>
      <input id="revalEmail" type="email" autocomplete="username" placeholder="Email">
      <input id="revalPassword" type="password" autocomplete="current-password" placeholder="Contrasena">
      <button id="revalLoginBtn" type="button">INGRESAR Y ANALIZAR</button>
    </div>
    <div id="receiptResult" class="receiptResult">
      <h3>Comprobante analizado</h3>
      <div id="receiptResultBody" class="receiptResultGrid"></div>
    </div>
  </section>
</div>
<div class="note">Las ventanas padre controlan a sus hijas: al cerrar TANQUES se cierra el detalle; al cerrar VENTAS / DESPACHOS se cierran la venta seleccionada y VER PAGO.</div>
<script>
(function(){
  const tankPanel=document.getElementById('tankPanel');
  const tankHotspot=document.getElementById('tankHotspot');
  const hosePanel=document.getElementById('hosePanel');
  const hoseHotspot=document.getElementById('hoseHotspot');
  const closeTankPanel=document.getElementById('closeTankPanel');
  const closeHosePanel=document.getElementById('closeHosePanel');
  const dispatchPanel=document.getElementById('dispatchPanel');
  const dispatchHotspot=document.getElementById('dispatchHotspot');
  const closeDispatchPanel=document.getElementById('closeDispatchPanel');
  const tankDetail=document.getElementById('tankDetail');
  const tankBody=document.getElementById('tankDetailBody');
  const saleCard=document.getElementById('saleOnPump');
  const saleBody=document.getElementById('salePumpBody');
  const saleTitle=document.getElementById('salePumpTitle');
  const viewPaymentBtn=document.getElementById('viewPaymentBtn');
  const paymentPanel=document.getElementById('paymentPanel');
  const paymentBody=document.getElementById('paymentBody');
  const truckHotspot=document.getElementById('truckHotspot');
  const receiptModal=document.getElementById('receiptModal');
  const receiptClose=document.getElementById('receiptClose');
  const receiptFile=document.getElementById('receiptFile');
  const receiptUploadLabel=document.getElementById('receiptUploadLabel');
  const receiptStatus=document.getElementById('receiptStatus');
  const receiptPreview=document.getElementById('receiptPreview');
  const revalLogin=document.getElementById('revalLogin');
  const revalEmail=document.getElementById('revalEmail');
  const revalPassword=document.getElementById('revalPassword');
  const revalLoginBtn=document.getElementById('revalLoginBtn');
  const receiptResult=document.getElementById('receiptResult');
  const receiptResultBody=document.getElementById('receiptResultBody');
  const SB_URL='https://apqgrwudkfytwikrsivd.supabase.co';
  const SB_KEY='sb_publishable_B9NdjnzOKu9BhZGmTM6LGg_wDB3n8lY';
  let pendingReceipt=null;
  let selectedSale=null;

  function closeTankHierarchy(){
    tankPanel.style.display='none';
    tankDetail.classList.remove('show');
    document.querySelectorAll('.tankPick').forEach(x=>x.classList.remove('active'));
  }
  function closeSaleHierarchy(){
    dispatchPanel.style.display='none';
    dispatchHotspot.style.display='block';
    saleCard.classList.remove('show');
    paymentPanel.classList.remove('show');
    selectedSale=null;
    document.querySelectorAll('.salePick').forEach(x=>x.classList.remove('active'));
  }

  if(tankHotspot){
    tankHotspot.addEventListener('click',()=>{
      if(tankPanel.style.display==='none'){
        tankPanel.style.display='block';
      }else{
        closeTankHierarchy();
      }
    });
  }
  if(closeTankPanel){ closeTankPanel.addEventListener('click',closeTankHierarchy); }

  if(hoseHotspot){
    hoseHotspot.addEventListener('click',()=>{ hosePanel.style.display=(hosePanel.style.display==='none')?'block':'none'; });
  }
  if(closeHosePanel){ closeHosePanel.addEventListener('click',()=>{hosePanel.style.display='none';}); }

  if(closeDispatchPanel){ closeDispatchPanel.addEventListener('click',closeSaleHierarchy); }
  if(dispatchHotspot){
    dispatchHotspot.addEventListener('click',()=>{
      dispatchPanel.style.display='block';
      dispatchHotspot.style.display='none';
    });
  }

  document.querySelectorAll('.tankPick').forEach(btn=>{
    btn.addEventListener('click',()=>{
      document.querySelectorAll('.tankPick').forEach(x=>x.classList.remove('active')); btn.classList.add('active');
      tankBody.innerHTML=
        '<span>Tanque</span><b>'+btn.dataset.num+'</b>'+
        '<span>Denominacion</span><b>'+btn.dataset.den+'</b>'+
        '<span>Producto</span><b>'+btn.dataset.prod+'</b>'+
        '<span>Capacidad</span><b>'+btn.dataset.cap+' L</b>'+
        '<span>Mangueras</span><b>'+btn.dataset.hoses+'</b>';
      tankDetail.classList.add('show');
    });
  });

  document.querySelectorAll('.salePick').forEach(btn=>{
    btn.addEventListener('click',()=>{
      document.querySelectorAll('.salePick').forEach(x=>x.classList.remove('active')); btn.classList.add('active');
      selectedSale={
        idDespacho:btn.dataset.idDespacho||'',
        venta:btn.dataset.venta,
        surtidor:btn.dataset.surtidor,
        manguera:btn.dataset.manguera,
        producto:btn.dataset.producto,
        litros:btn.dataset.litros,
        ppu:btn.dataset.ppu,
        pesos:btn.dataset.pesos,
        hora:btn.dataset.hora
      };
      saleTitle.textContent='VENTA #'+btn.dataset.venta+' - SURTIDOR '+btn.dataset.surtidor;
      saleBody.innerHTML=
        '<span>Venta</span><b>#'+btn.dataset.venta+'</b>'+
        '<span>Surtidor</span><b>'+btn.dataset.surtidor+'</b>'+
        '<span>Manguera</span><b>'+btn.dataset.manguera+'</b>'+
        '<span>Producto</span><b>'+btn.dataset.producto+'</b>'+
        '<span>Litros</span><b>'+btn.dataset.litros+' L</b>'+
        '<span>PPU</span><b>'+btn.dataset.ppu+'</b>'+
        '<span>Pesos</span><b>$ '+btn.dataset.pesos+'</b>'+
        '<span>Hora</span><b>'+btn.dataset.hora+'</b>';
      saleCard.classList.add('show');
    });
  });

  if(viewPaymentBtn){
    viewPaymentBtn.addEventListener('click',async()=>{
      if(!selectedSale) return;
      paymentPanel.classList.add('show');
      paymentBody.innerHTML=
        '<span>Venta</span><b>#'+selectedSale.venta+'</b>'+
        '<span>Surtidor</span><b>'+selectedSale.surtidor+'</b>'+
        '<span>Importe</span><b>$ '+selectedSale.pesos+'</b>'+
        '<span>Pago</span><b>Buscando comprobante relacionado...</b>';
      try{
        const r=await fetch('/api/payment',{
          method:'POST',
          headers:{'Content-Type':'application/json'},
          body:JSON.stringify({sessionId:'$sid',database:'$safeDb',idDespacho:selectedSale.idDespacho,venta:selectedSale.venta})
        });
        const d=await r.json();
        if(!r.ok) throw new Error(d.error||('HTTP '+r.status));
        if(!d.resolved){
          paymentBody.innerHTML=
            '<span>Venta</span><b>#'+selectedSale.venta+'</b>'+
            '<span>id_despacho</span><b>'+escHtml(selectedSale.idDespacho||'NO DETECTADO')+'</b>'+
            '<span>Relacion</span><b>No pude resolver automaticamente el comprobante.</b>'+
            '<span>Columnas encontradas</span><b>'+escHtml((d.columns||[]).join(', '))+'</b>'+
            '<span>Detalle</span><b>'+escHtml(d.reason||'Sin detalle')+'</b>';
          return;
        }
        const p=d.payment||{};
        const c=d.comprobante||{};
        paymentBody.innerHTML=
          '<span>Comprobante</span><b>'+escHtml((c.letra||'')+' '+(c.sucursal||'')+'-'+(c.numero||''))+'</b>'+
          '<span>Mercado Pago</span><b>$ '+escHtml(p.MercadoPago||0)+'</b>'+
          '<span>App YPF</span><b>$ '+escHtml(p.AppYPF||0)+'</b>'+
          '<span>Shell Box</span><b>$ '+escHtml(p.ShellBox||0)+'</b>'+
          '<span>App Puma</span><b>$ '+escHtml(p.AppPuma||0)+'</b>'+
          '<span>Clover</span><b>$ '+escHtml(p.Clover||0)+'</b>'+
          '<span>PayWay</span><b>$ '+escHtml(p.PayWay||0)+'</b>'+
          '<span>Cheques</span><b>$ '+escHtml(p.Cheques||0)+'</b>'+
          '<span>Efectivo</span><b>$ '+escHtml(p.Efectivo||0)+'</b>'+
          '<span>Total</span><b>$ '+escHtml(p.TOTAL||selectedSale.pesos||0)+'</b>'+
          '<span>Vendedor</span><b>'+escHtml(p.Vendedor||'-')+'</b>';
        const pending=document.querySelector('#paymentPanel .paymentPending');
        if(pending) pending.textContent='Forma de pago obtenida desde RelacionCptsDespachos y la logica de PA_VentasFormasPago.';
      }catch(e){
        paymentBody.innerHTML=
          '<span>Venta</span><b>#'+selectedSale.venta+'</b>'+
          '<span>Error</span><b>'+escHtml(e.message||'No se pudo obtener la forma de pago')+'</b>';
      }
    });
  }

  function escHtml(v){
    return String(v==null?'':v).replace(/[&<>"']/g,function(ch){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]});
  }

  function setReceiptStatus(message,kind){
    receiptStatus.textContent=message;
    receiptStatus.className='receiptStatus'+(kind?' '+kind:'');
  }

  function readAsDataUrl(file){
    return new Promise(function(resolve,reject){
      const fr=new FileReader();
      fr.onload=function(){resolve(fr.result)};
      fr.onerror=reject;
      fr.readAsDataURL(file);
    });
  }

  async function refreshRevalsoftToken(){
    const refresh=localStorage.getItem('rodolfo.sb.refresh_token');
    if(!refresh) return null;
    try{
      const r=await fetch(SB_URL+'/auth/v1/token?grant_type=refresh_token',{
        method:'POST',
        headers:{'Content-Type':'application/json','apikey':SB_KEY},
        body:JSON.stringify({refresh_token:refresh})
      });
      const d=await r.json();
      if(!r.ok||!d.access_token) return null;
      localStorage.setItem('rodolfo.sb.access_token',d.access_token);
      if(d.refresh_token) localStorage.setItem('rodolfo.sb.refresh_token',d.refresh_token);
      localStorage.setItem('rodolfo.sb.expires_at',String(Date.now()+((d.expires_in||3600)*1000)));
      return d.access_token;
    }catch(_){return null}
  }

  async function getRevalsoftToken(){
    const token=localStorage.getItem('rodolfo.sb.access_token');
    const expires=Number(localStorage.getItem('rodolfo.sb.expires_at')||0);
    if(token && expires>Date.now()+30000) return token;
    return refreshRevalsoftToken();
  }

  async function loginRevalsoft(){
    const email=revalEmail.value.trim();
    const password=revalPassword.value;
    if(!email||!password) throw new Error('Completa email y contrasena.');
    const r=await fetch(SB_URL+'/auth/v1/token?grant_type=password',{
      method:'POST',
      headers:{'Content-Type':'application/json','apikey':SB_KEY},
      body:JSON.stringify({email:email,password:password})
    });
    const d=await r.json();
    if(!r.ok||!d.access_token) throw new Error(d.error_description||d.msg||d.error||'No se pudo iniciar sesion.');
    localStorage.setItem('rodolfo.sb.access_token',d.access_token);
    if(d.refresh_token) localStorage.setItem('rodolfo.sb.refresh_token',d.refresh_token);
    localStorage.setItem('rodolfo.sb.expires_at',String(Date.now()+((d.expires_in||3600)*1000)));
    revalPassword.value='';
    return d.access_token;
  }

  function normalizeKey(value){
    return String(value||'').toLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g,'').replace(/[^a-z0-9]/g,'');
  }
  function findValue(source,names,depth){
    depth=depth||0;
    if(!source||typeof source!=='object'||depth>7) return undefined;
    const wanted=names.map(normalizeKey);
    for(const key of Object.keys(source)){
      const value=source[key];
      if(wanted.includes(normalizeKey(key)) && value!==null && value!=='' && typeof value!=='object') return value;
    }
    for(const value of Object.values(source)){
      const found=findValue(value,names,depth+1);
      if(found!==undefined) return found;
    }
  }
  function findItems(source,depth){
    depth=depth||0;
    if(!source||typeof source!=='object'||depth>7) return [];
    for(const key of Object.keys(source)){
      const value=source[key];
      if(['items','item','detalle','detalles','lineas','conceptos','productos'].includes(normalizeKey(key)) && Array.isArray(value)) return value;
    }
    for(const value of Object.values(source)){
      const found=findItems(value,depth+1);
      if(found.length) return found;
    }
    return [];
  }
  function docText(data,names,fallback){
    const v=findValue(data,names,0);
    return v===undefined?(fallback===undefined?'-':fallback):String(v);
  }
  function docMoney(data,names){
    const value=findValue(data,names,0);
    const raw=String(value==null?'':value).trim();
    const number=Number(raw.replace(/\.(?=\d{3}(?:\D|$))/g,'').replace(',','.').replace(/[^0-9.-]/g,''));
    if(!Number.isFinite(number)||!raw) return '-';
    const currency=docText(data,['moneda'],'ARS')==='USD'?'USD':'ARS';
    try{return new Intl.NumberFormat('es-AR',{style:'currency',currency:currency,maximumFractionDigits:2}).format(number)}
    catch(_){return raw}
  }
  function renderReceiptResult(data){
    const type=docText(data,['tipo_documento','tipoDocumento','tipo_comprobante','tipoComprobante'],'COMPROBANTE').toUpperCase();
    const items=findItems(data,0);
    const isTransfer=type.includes('TRANSFER');
    const isReceipt=type.includes('RECIB');
    const issuer=isTransfer?docText(data,['plataforma'],'Transferencia'):docText(data,['proveedor','emisor','origen_nombre'],type);
    const headerSub=isTransfer
      ? 'Operacion: '+docText(data,['numero_operacion','codigo_identificacion'])
      : 'CUIT: '+docText(data,['proveedor_cuit','emisor_cuit','cuit']);
    let html='<div class="invoice-paper">';
    html+='<div class="invoice-head"><div><span>COMPROBANTE PROCESADO</span><h3>'+escHtml(issuer)+'</h3><p>'+escHtml(headerSub)+'</p></div>';
    html+='<div class="invoice-type"><b>'+escHtml(type)+'</b><small>'+escHtml(docText(data,['numero_comprobante','numero_operacion','numero','nro']))+'</small></div></div>';
    html+='<div class="invoice-meta"><div><span>Fecha</span><b>'+escHtml(docText(data,['fecha','fecha_emision']))+'</b></div><div><span>Hora</span><b>'+escHtml(docText(data,['hora']))+'</b></div><div><span>Moneda</span><b>'+escHtml(docText(data,['moneda'],'ARS'))+'</b></div></div>';
    if(isTransfer){
      html+='<div class="document-flow"><div><span>ORIGEN</span><b>'+escHtml(docText(data,['origen_nombre','emisor']))+'</b><small>'+escHtml(docText(data,['origen_cuit','emisor_cuit']))+'</small><small>'+escHtml(docText(data,['origen_cuenta']))+'</small></div><div class="flow-arrow">&rarr;</div><div><span>DESTINO</span><b>'+escHtml(docText(data,['destino_nombre','receptor']))+'</b><small>'+escHtml(docText(data,['destino_cuit','receptor_cuit']))+'</small><small>'+escHtml(docText(data,['destino_cuenta']))+'</small></div></div>';
    }else if(isReceipt){
      html+='<div class="document-flow"><div><span>RECIBIDO DE</span><b>'+escHtml(docText(data,['emisor','origen_nombre','cliente']))+'</b><small>'+escHtml(docText(data,['emisor_cuit','origen_cuit','cliente_cuit']))+'</small></div><div class="flow-arrow">&rarr;</div><div><span>RECIBIDO POR</span><b>'+escHtml(docText(data,['receptor','destino_nombre','proveedor']))+'</b><small>'+escHtml(docText(data,['receptor_cuit','destino_cuit','proveedor_cuit']))+'</small></div></div>';
    }
    if(items.length){
      html+='<div class="invoice-lines"><div class="invoice-line invoice-line-head"><span>Detalle</span><span>Cant.</span><span>Precio</span><span>Importe</span></div>';
      items.slice(0,10).forEach(function(item){
        html+='<div class="invoice-line"><span>'+escHtml(docText(item,['descripcion','nombre','producto','detalle'],'Item'))+'</span><span>'+escHtml(docText(item,['cantidad','quantity','canti'],'1'))+'</span><span>'+escHtml(docMoney(item,['precio_unitario','precio','price']))+'</span><span>'+escHtml(docMoney(item,['importe','total','subtotal']))+'</span></div>';
      });
      html+='</div>';
    }
    html+='<div class="invoice-totals">';
    if(!isTransfer&&!isReceipt){
      html+='<div><span>Subtotal</span><b>'+escHtml(docMoney(data,['subtotal','neto','importe_neto']))+'</b></div>';
      html+='<div><span>IVA</span><b>'+escHtml(docMoney(data,['total_iva','iva','importe_iva']))+'</b></div>';
      html+='<div><span>Impuestos / percepciones</span><b>'+escHtml(docMoney(data,['percepciones','impuestos','otros_impuestos']))+'</b></div>';
    }
    const totalLabel=isTransfer?'IMPORTE TRANSFERIDO':(isReceipt?'IMPORTE RECIBIDO':'TOTAL');
    html+='<div class="invoice-grand"><span>'+totalLabel+'</span><b>'+escHtml(docMoney(data,['importe','total','importe_total','monto_total']))+'</b></div></div>';
    html+='<div class="invoice-footer">';
    if(isTransfer||isReceipt){
      html+='<span>Medio<b>'+escHtml(docText(data,['medio_pago','plataforma']))+'</b></span><span>Motivo<b>'+escHtml(docText(data,['motivo','observaciones']))+'</b></span>';
    }else{
      html+='<span>CAE<b>'+escHtml(docText(data,['cae']))+'</b></span><span>Vencimiento CAE<b>'+escHtml(docText(data,['cae_vencimiento','vencimiento_cae']))+'</b></span>';
    }
    html+='</div></div>';
    receiptResultBody.innerHTML=html;
    receiptResult.classList.add('show');
  }

  async function analyzeReceipt(file){
    pendingReceipt=file;
    let token=await getRevalsoftToken();
    if(!token){
      revalLogin.classList.add('show');
      setReceiptStatus('Comprobante recibido por el camion. Inicia sesion Revalsoft IA para analizarlo.','ok');
      return;
    }
    revalLogin.classList.remove('show');
    setReceiptStatus('Camion recibio el comprobante. Analizando con Revalsoft IA TEST...');
    const base64=await readAsDataUrl(file);
    let r=await fetch(SB_URL+'/functions/v1/extract-document-json',{
      method:'POST',
      headers:{'Content-Type':'application/json','apikey':SB_KEY,'Authorization':'Bearer '+token},
      body:JSON.stringify({file_name:file.name,mime_type:file.type||'application/octet-stream',base64:base64})
    });
    if(r.status===401){
      localStorage.removeItem('rodolfo.sb.access_token');
      token=await refreshRevalsoftToken();
      if(token){
        r=await fetch(SB_URL+'/functions/v1/extract-document-json',{
          method:'POST',
          headers:{'Content-Type':'application/json','apikey':SB_KEY,'Authorization':'Bearer '+token},
          body:JSON.stringify({file_name:file.name,mime_type:file.type||'application/octet-stream',base64:base64})
        });
      }
    }
    const out=await r.json().catch(function(){return {}});
    if(!r.ok||!out.ok){
      if(r.status===401){
        revalLogin.classList.add('show');
        throw new Error('Sesion Revalsoft IA vencida. Inicia sesion nuevamente.');
      }
      throw new Error(out.error||'No se pudo analizar el comprobante.');
    }
    renderReceiptResult(out.data||{});
    setReceiptStatus('Comprobante analizado correctamente.','ok');
  }

  function animateReceiptToTruck(file){
    return new Promise(function(resolve){
      const source=receiptUploadLabel.getBoundingClientRect();
      const target=truckHotspot.getBoundingClientRect();
      const fly=document.createElement('div');
      fly.className='receiptFly';
      fly.textContent='COMPROBANTE - '+file.name;
      fly.style.left=(source.left+source.width/2-90)+'px';
      fly.style.top=(source.top+source.height/2-20)+'px';
      document.body.appendChild(fly);
      const dx=(target.left+target.width/2)-(source.left+source.width/2);
      const dy=(target.top+target.height/2)-(source.top+source.height/2);
      requestAnimationFrame(function(){
        requestAnimationFrame(function(){
          fly.style.transform='translate('+dx+'px,'+dy+'px) scale(.08) rotate(-10deg)';
          fly.style.opacity='0';
          truckHotspot.classList.add('feed');
        });
      });
      setTimeout(function(){
        fly.remove();
        truckHotspot.classList.remove('feed');
        resolve();
      },820);
    });
  }

  if(truckHotspot){
    truckHotspot.addEventListener('click',function(){
      receiptModal.classList.add('show');
      receiptResult.classList.remove('show');
      setReceiptStatus('Esperando archivo...');
    });
  }

  if(receiptClose){
    receiptClose.addEventListener('click',function(){receiptModal.classList.remove('show')});
  }
  receiptModal.addEventListener('click',function(e){if(e.target===receiptModal)receiptModal.classList.remove('show')});

  if(receiptFile){
    receiptFile.addEventListener('change',async function(){
      const file=receiptFile.files&&receiptFile.files[0];
      if(!file) return;
      pendingReceipt=file;
      receiptResult.classList.remove('show');
      receiptPreview.innerHTML='';
      if(file.type&&file.type.indexOf('image/')===0){
        const img=document.createElement('img');
        img.src=URL.createObjectURL(file);
        img.onload=function(){setTimeout(function(){URL.revokeObjectURL(img.src)},1000)};
        receiptPreview.appendChild(img);
      }else{
        receiptPreview.innerHTML='<div class="pdf">PDF - '+escHtml(file.name)+'</div>';
      }
      receiptPreview.classList.add('show');
      setReceiptStatus(file.name+' - '+(file.size/1024/1024).toFixed(2)+' MB');
      await animateReceiptToTruck(file);
      try{await analyzeReceipt(file)}catch(e){setReceiptStatus(e.message||'Error al analizar.','bad')}
    });
  }

  if(revalLoginBtn){
    revalLoginBtn.addEventListener('click',async function(){
      try{
        revalLoginBtn.disabled=true;
        setReceiptStatus('Iniciando sesion Revalsoft IA...');
        await loginRevalsoft();
        revalLogin.classList.remove('show');
        if(pendingReceipt) await analyzeReceipt(pendingReceipt);
      }catch(e){
        setReceiptStatus(e.message||'No se pudo iniciar sesion.','bad');
      }finally{
        revalLoginBtn.disabled=false;
      }
    });
  }

  document.querySelectorAll('[data-close]').forEach(btn=>{
    btn.addEventListener('click',()=>{
      const id=btn.dataset.close;
      document.getElementById(id).classList.remove('show');
      if(id==='saleOnPump'){
        paymentPanel.classList.remove('show');
        selectedSale=null;
        document.querySelectorAll('.salePick').forEach(x=>x.classList.remove('active'));
      }
    });
  });
})();
</script>
</body></html>
"@
          Send-Response $stream 200 "text/html; charset=utf-8" $html
        } catch {
          Send-Response $stream 401 "text/html; charset=utf-8" "<h2>Sesion SQL no valida</h2><p>$([System.Net.WebUtility]::HtmlEncode($_.Exception.Message))</p><p>Volver a abrir Capitan Rodolfo para reconectar.</p>"
        }
      }
      elseif($req.Method -eq 'POST' -and $pathOnly -eq '/api/connect'){
        try {
          $data = $req.Body | ConvertFrom-Json
          $server = [string]$data.server
          $auth = [string]$data.auth
          $user = [string]$data.user
          $password = [string]$data.password
          if([string]::IsNullOrWhiteSpace($server)){ throw "Completá servidor/instancia." }
          if($auth -eq 'sql' -and [string]::IsNullOrWhiteSpace($password)){
            $saved = Load-SqlProfile
            if($null -ne $saved -and [string]$saved.server -eq $server -and [string]$saved.auth -eq $auth -and [string]$saved.user -eq $user){
              $password = Unprotect-ProfilePassword -Profile $saved
            }
          }

          $state = Open-SqlSession -Server $server -Auth $auth -User $user -Password $password
          Save-SqlProfile -Server $server -Auth $auth -User $user -Password $password -Database ""
          $script:LastRestoreError = ""
          Write-ServiceStatus -State "running-connected" -Database "" -Server $server -User $user
          Send-Json $stream 200 $state
        } catch {
          $script:LastRestoreError = $_.Exception.Message
          try { Write-ServiceStatus -State 'running-no-sql' -Server $server -User $user -ErrorMessage $script:LastRestoreError } catch {}
          Send-Json $stream 500 @{error=$_.Exception.Message}
        }
      }
      elseif($req.Method -eq 'POST' -and $pathOnly -eq '/api/tables'){
        try {
          $data = $req.Body | ConvertFrom-Json
          $sid = [string]$data.sessionId
          $database = [string]$data.database
          if(-not $Sessions.ContainsKey($sid)){ Send-Json $stream 401 @{error='Sesion vencida. Volver a conectar.'}; continue }
          $sess = $Sessions[$sid]
          if($sess.databases -notcontains $database){ Send-Json $stream 403 @{error='Base no autorizada.'}; continue }

          $cn = $sess.connection
          $cn.ChangeDatabase($database)
          $cmd = $cn.CreateCommand()
          $cmd.CommandText = @"
SELECT s.name AS esquema, t.name AS tabla
FROM sys.tables AS t
INNER JOIN sys.schemas AS s ON s.schema_id=t.schema_id
ORDER BY s.name,t.name;
"@
          $reader = $cmd.ExecuteReader()
          $rows = @()
          while($reader.Read()){ $rows += @{schema=[string]$reader.GetString(0);name=[string]$reader.GetString(1)} }
          $reader.Close()
          $sess["database"] = $database
          Save-SqlProfile -Server ([string]$sess.server) -Auth ([string]$sess.auth) -User ([string]$sess.user) -Password "" -Database $database
          Write-ServiceStatus -State "running-connected" -Database $database -Server ([string]$sess.server) -User ([string]$sess.user)
          Send-Json $stream 200 @{database=$database;tables=$rows}
        } catch {
          Send-Json $stream 500 @{error=$_.Exception.Message}
        }
      }
      elseif($req.Method -eq 'POST' -and $pathOnly -eq '/api/surpla'){
        try {
          $data = $req.Body | ConvertFrom-Json
          $sid = [string]$data.sessionId
          $database = [string]$data.database
          if(-not $Sessions.ContainsKey($sid)){ Send-Json $stream 401 @{error='Sesion vencida. Volver a conectar.'}; continue }
          $sess = $Sessions[$sid]
          if($sess.databases -notcontains $database){ Send-Json $stream 403 @{error='Base no autorizada.'}; continue }
          $cn = $sess.connection
          $cn.ChangeDatabase($database)
          $cmd = $cn.CreateCommand()
          $cmd.CommandText = 'SELECT * FROM dbo.SURPLA;'
          $cmd.CommandTimeout = 30
          $reader = $cmd.ExecuteReader()
          $columns = @()
          for($i=0;$i -lt $reader.FieldCount;$i++){ $columns += [string]$reader.GetName($i) }
          $rows = @()
          while($reader.Read()){
            $row = [ordered]@{}
            for($i=0;$i -lt $reader.FieldCount;$i++){
              $value = $reader.GetValue($i)
              if($value -is [DBNull]){ $value = $null }
              elseif($value -is [DateTime]){ $value = ([DateTime]$value).ToString('dd/MM/yyyy HH:mm:ss') }
              $row[$columns[$i]] = $value
            }
            $rows += [pscustomobject]$row
          }
          $reader.Close()
          Send-Json $stream 200 @{database=$database;query='SELECT * FROM dbo.SURPLA';columns=$columns;rows=$rows;rowCount=$rows.Count}
        } catch {
          Send-Json $stream 500 @{error=$_.Exception.Message}
        }
      }
      elseif($req.Method -eq 'POST' -and $pathOnly -eq '/api/payment'){
        try {
          $data = $req.Body | ConvertFrom-Json
          $sid = [string]$data.sessionId
          $database = [string]$data.database
          $idDespacho = [string]$data.idDespacho
          if(-not $Sessions.ContainsKey($sid)){ Send-Json $stream 401 @{error='Sesion vencida. Volver a conectar.'}; continue }
          $sess = $Sessions[$sid]
          if($sess.databases -notcontains $database){ Send-Json $stream 403 @{error='Base no autorizada.'}; continue }
          $cn = $sess.connection
          $cn.ChangeDatabase($database)

          $metaCmd = $cn.CreateCommand()
          $metaCmd.CommandText = "SELECT c.name FROM sys.columns c WHERE c.object_id=OBJECT_ID('dbo.RelacionCptsDespachos') ORDER BY c.column_id;"
          $mr = $metaCmd.ExecuteReader()
          $relationColumns = @()
          while($mr.Read()){ $relationColumns += [string]$mr.GetString(0) }
          $mr.Close()
          if($relationColumns.Count -eq 0){
            Send-Json $stream 200 @{resolved=$false;reason='No existe dbo.RelacionCptsDespachos o no tiene columnas visibles.';columns=@()}
            continue
          }

          function Normalize-LocalName([string]$name){
            return ($name.ToLowerInvariant() -replace '[^a-z0-9]','')
          }
          function Pick-RelationColumn($columns,[string[]]$exact,[string[]]$contains){
            foreach($e in $exact){
              foreach($c in $columns){ if((Normalize-LocalName $c) -eq $e){ return $c } }
            }
            foreach($needle in $contains){
              foreach($c in $columns){ if((Normalize-LocalName $c).Contains($needle)){ return $c } }
            }
            return $null
          }

          $dispatchCol = Pick-RelationColumn $relationColumns @('iddespacho','iddespcho') @('iddesp','despachoid','despacho')
          if([string]::IsNullOrWhiteSpace($dispatchCol)){
            Send-Json $stream 200 @{resolved=$false;reason='No pude identificar la columna que relaciona con Despachos.';columns=$relationColumns}
            continue
          }
          if([string]::IsNullOrWhiteSpace($idDespacho)){
            Send-Json $stream 200 @{resolved=$false;reason='El registro de Despachos no expuso su ID interno.';columns=$relationColumns}
            continue
          }

          $relCmd = $cn.CreateCommand()
          $relCmd.CommandText = "SELECT TOP 1 * FROM dbo.RelacionCptsDespachos WHERE ["+$dispatchCol.Replace("]","]]")+"] = @id;"
          $null = $relCmd.Parameters.Add("@id",[System.Data.SqlDbType]::VarChar,100)
          $relCmd.Parameters["@id"].Value = $idDespacho
          $rr = $relCmd.ExecuteReader()
          if(-not $rr.Read()){
            $rr.Close()
            Send-Json $stream 200 @{resolved=$false;reason='No encontre una fila en RelacionCptsDespachos para id_despacho='+$idDespacho;columns=$relationColumns}
            continue
          }
          $rel = @{}
          for($i=0;$i -lt $rr.FieldCount;$i++){
            $name=[string]$rr.GetName($i)
            $val=$rr.GetValue($i)
            if($val -is [DBNull]){ $val=$null }
            $rel[$name]=$val
          }
          $rr.Close()

          $letterCol = Pick-RelationColumn $relationColumns @('letra','letter') @('letracomp','letracpte')
          $branchCol = Pick-RelationColumn $relationColumns @('sucursal','pos') @('sucursalcomp','poscomp')
          $numberCol = Pick-RelationColumn $relationColumns @('ncompro','numero','nrocompro','nrocomprobante','invoicenumber') @('ncompro','numerocomp','nrocomp','invoice')
          $typeCol = Pick-RelationColumn $relationColumns @('tipo','type','tipocpte','tipocomprobante') @('tipocomp','tipocpte')

          $letra = if($letterCol){[string]$rel[$letterCol]}else{''}
          $sucursal = if($branchCol){[string]$rel[$branchCol]}else{''}
          $numero = if($numberCol){[string]$rel[$numberCol]}else{''}
          $tipo = if($typeCol){[string]$rel[$typeCol]}else{''}

          if([string]::IsNullOrWhiteSpace($sucursal) -or [string]::IsNullOrWhiteSpace($numero)){
            Send-Json $stream 200 @{resolved=$false;reason='Encontre la relacion, pero no pude identificar sucursal/numero de comprobante.';columns=$relationColumns;relation=$rel}
            continue
          }

          $isTicket = (($tipo.ToUpperInvariant()).Contains('TICKET') -or $letra.ToUpperInvariant() -eq 'T')
          $payCmd = $cn.CreateCommand()

          if($isTicket){
            $payCmd.CommandText = @"
SELECT TOP 1
 'T' AS letra,
 MT.sucursal,
 MT.Numero AS NCOMPRO,
 MT.turno AS Turno,
 ISNULL(ROUND(MP_O.amount,2),0) AS MercadoPago,
 ISNULL(ROUND(ypf_P.amount,2),0) AS AppYPF,
 ISNULL(ROUND(SH_P.TotalAmount,2),0) AS ShellBox,
 ISNULL(ROUND(PU_P.TotalTransaction-PU_P.Discounts,2),0) AS AppPuma,
 ISNULL(ROUND(C_P.Amount,2),0) AS Clover,
 ISNULL(ROUND(ISNULL(T.IMPORTETAR,0)-ISNULL(T.Extraccion,0),2),0) AS PayWay,
 CAST(0 AS decimal(18,2)) AS Cheques,
 ROUND(MT.TOTAL-(
   ISNULL(ROUND(C_P.Amount,2),0)+ISNULL(ROUND(MP_O.amount,2),0)+ISNULL(ROUND(ypf_P.amount,2),0)+
   ISNULL(ROUND(ISNULL(T.IMPORTETAR,0)-ISNULL(T.Extraccion,0),2),0)+
   ISNULL(ROUND(SH_P.TotalAmount,2),0)+ISNULL(ROUND(PU_P.TotalTransaction,2),0)
 ),2) AS Efectivo,
 MT.TOTAL,
 ISNULL(CAST(MT.Vendedor AS VARCHAR(8)),'0')+' - '+ISNULL(MV.RAZONSOC,'SIN VENDEDOR') AS Vendedor
FROM (
 SELECT Sucursal,Numero,turno,SUM(TOTAL) TOTAL,VENDEDOR
 FROM Maetic
 WHERE Sucursal=@Sucursal AND Numero=@Numero
 GROUP BY Sucursal,Numero,turno,VENDEDOR
) MT
LEFT JOIN MP_OrdenPagoComprobante MP_C ON MT.SUCURSAL=MP_C.Sucursal AND MT.NUMERO=MP_C.Numero AND MP_C.Tipo='TICKET'
LEFT JOIN MP_OrdenPago MP_O ON MP_C.ID_OrdenPago=MP_O.ID
LEFT JOIN YPF_PaymentIntentionComprobante ypf_C ON MT.SUCURSAL=ypf_C.Sucursal AND MT.NUMERO=ypf_C.Numero AND ypf_C.Tipo='TICKET'
LEFT JOIN YPF_PaymentIntention ypf_P ON ypf_P.ID=ypf_C.ID_PaymentIntention
LEFT JOIN Shell_PayOrderComprobante SH_C ON MT.SUCURSAL=SH_C.Sucursal AND MT.NUMERO=SH_C.Numero AND SH_C.Tipo='TICKET'
LEFT JOIN Shell_PayOrder SH_P ON SH_C.PayOrderId=SH_P.ID
LEFT JOIN PUMA_PaymentComprobante PU_C ON MT.SUCURSAL=PU_C.Sucursal AND MT.NUMERO=PU_C.Numero AND PU_C.Tipo='TICKET'
LEFT JOIN PUMA_Payment PU_P ON PU_C.PaymentId=PU_P.ID
LEFT JOIN Tarjet T ON T.Letra='T' AND MT.SUCURSAL=T.Sucursal AND MT.NUMERO=T.NFACT
LEFT JOIN Clover_PaymentInvoices C_PI ON MT.SUCURSAL=C_PI.Pos AND MT.NUMERO=C_PI.InvoiceNumber AND C_PI.Type='TICKET'
LEFT JOIN Clover_Payments C_P ON C_P.Id=C_PI.CloverPaymentId
LEFT JOIN Maeven MV ON MV.VENDEDOR=MT.VENDEDOR;
"@
          } else {
            if([string]::IsNullOrWhiteSpace($letra)){
              Send-Json $stream 200 @{resolved=$false;reason='Encontre sucursal y numero, pero falta letra/tipo para distinguir factura de ticket.';columns=$relationColumns;relation=$rel}
              continue
            }
            $payCmd.CommandText = @"
SELECT TOP 1
 M.letra,M.sucursal,M.NCOMPRO,M.turno AS Turno,
 ISNULL(ROUND(MP_O.amount,2),0.00) AS MercadoPago,
 ISNULL(ROUND(ypf_P.amount,2),0) AS AppYPF,
 ISNULL(ROUND(SH_P.TotalAmount,2),0) AS ShellBox,
 ISNULL(ROUND(PU_P.TotalTransaction-PU_P.Discounts,2),0) AS AppPuma,
 ISNULL(ROUND(C_P.Amount,2),0) AS Clover,
 ISNULL(ROUND(ISNULL(T.IMPORTETAR,0)-ISNULL(T.Extraccion,0),2),0) AS PayWay,
 M.cheques AS Cheques,
 CASE M.CONDVTA WHEN 2 THEN 0 ELSE
 ROUND((M.TOTAL-(
   ISNULL(ROUND(C_P.Amount,2),0)+ISNULL(ROUND(MP_O.amount,2),0)+ISNULL(ROUND(ypf_P.amount,2),0)+
   ISNULL(ROUND(ISNULL(T.IMPORTETAR,0)-ISNULL(T.Extraccion,0),2),0)+
   ISNULL(ROUND(SH_P.TotalAmount,2),0)+ISNULL(ROUND(PU_P.TotalTransaction,2),0)
 )),2) END AS Efectivo,
 M.TOTAL,
 ISNULL(CAST(M.Vendedor AS VARCHAR(8)),'0')+' - '+ISNULL(MV.RAZONSOC,'SIN VENDEDOR') AS Vendedor
FROM Maefac M
LEFT JOIN MP_OrdenPagoComprobante MP_C ON M.LETRA=MP_C.Letra AND M.SUCURSAL=MP_C.Sucursal AND M.NCOMPRO=MP_C.Numero
LEFT JOIN MP_OrdenPago MP_O ON MP_C.ID_OrdenPago=MP_O.ID
LEFT JOIN YPF_PaymentIntentionComprobante ypf_C ON M.LETRA=ypf_C.Letra AND M.SUCURSAL=ypf_C.Sucursal AND M.NCOMPRO=ypf_C.Numero
LEFT JOIN YPF_PaymentIntention ypf_P ON ypf_P.ID=ypf_C.ID_PaymentIntention
LEFT JOIN Tarjet T ON M.LETRA=T.Letra AND M.SUCURSAL=T.Sucursal AND M.NCOMPRO=T.NFACT
LEFT JOIN Shell_PayOrderComprobante SH_C ON M.LETRA=SH_C.Letra AND M.SUCURSAL=SH_C.Sucursal AND M.NCOMPRO=SH_C.Numero
LEFT JOIN Shell_PayOrder SH_P ON SH_C.PayOrderId=SH_P.ID
LEFT JOIN PUMA_PaymentComprobante PU_C ON M.LETRA=PU_C.Letra AND M.SUCURSAL=PU_C.Sucursal AND M.NCOMPRO=PU_C.Numero
LEFT JOIN PUMA_Payment PU_P ON PU_C.PaymentId=PU_P.ID
LEFT JOIN Clover_PaymentInvoices C_PI ON M.SUCURSAL=C_PI.Pos AND M.NCOMPRO=C_PI.InvoiceNumber AND C_PI.Letter=M.LETRA
LEFT JOIN Clover_Payments C_P ON C_P.Id=C_PI.CloverPaymentId
LEFT JOIN Maeven MV ON MV.VENDEDOR=M.VENDEDOR
WHERE M.LETRA=@Letra AND M.SUCURSAL=@Sucursal AND M.NCOMPRO=@Numero;
"@
            $null=$payCmd.Parameters.Add("@Letra",[System.Data.SqlDbType]::VarChar,10)
            $payCmd.Parameters["@Letra"].Value=$letra
          }

          $null=$payCmd.Parameters.Add("@Sucursal",[System.Data.SqlDbType]::VarChar,30)
          $payCmd.Parameters["@Sucursal"].Value=$sucursal
          $null=$payCmd.Parameters.Add("@Numero",[System.Data.SqlDbType]::VarChar,50)
          $payCmd.Parameters["@Numero"].Value=$numero

          $pr=$payCmd.ExecuteReader()
          if(-not $pr.Read()){
            $pr.Close()
            Send-Json $stream 200 @{resolved=$false;reason='La relacion existe, pero no encontre el comprobante en Maefac/Maetic.';columns=$relationColumns;relation=$rel}
            continue
          }
          $payment=@{}
          for($i=0;$i -lt $pr.FieldCount;$i++){
            $name=[string]$pr.GetName($i)
            $val=$pr.GetValue($i)
            if($val -is [DBNull]){$val=0}
            $payment[$name]=$val
          }
          $pr.Close()
          Send-Json $stream 200 @{
            resolved=$true
            dispatchColumn=$dispatchCol
            relation=$rel
            comprobante=@{letra=$letra;sucursal=$sucursal;numero=$numero;tipo=$tipo}
            payment=$payment
          }
        } catch {
          Send-Json $stream 500 @{error=$_.Exception.Message}
        }
      }
      elseif($req.Method -eq 'POST' -and $pathOnly -eq '/api/dispatches'){
        try {
          $data = $req.Body | ConvertFrom-Json
          $sid = [string]$data.sessionId
          $database = [string]$data.database
          if(-not $Sessions.ContainsKey($sid)){ Send-Json $stream 401 @{error='Sesion vencida. Volver a conectar.'}; continue }
          $sess = $Sessions[$sid]
          if($sess.databases -notcontains $database){ Send-Json $stream 403 @{error='Base no autorizada.'}; continue }

          $cn = $sess.connection
          $cn.ChangeDatabase($database)
          $cmd = $cn.CreateCommand()
          $cmd.CommandText = "SELECT id_sale venta, surtidor, manguera, d.codart, p.descriimpresion, Litros, PPU, pesos, d.Ultime fecha, Ultime as hora FROM Despachos d INNER JOIN prod p ON d.codart = p.codart;"
          $reader = $cmd.ExecuteReader()

          $cols = @()
          for($i=0; $i -lt $reader.FieldCount; $i++){ $cols += [string]$reader.GetName($i) }
          $rows = @()
          while($reader.Read()){
            $row = [ordered]@{}
            for($i=0; $i -lt $reader.FieldCount; $i++){
              $v = $reader.GetValue($i)
              if($v -is [System.DBNull]){ $v = $null }
              elseif($v -is [DateTime]){ $v = $v.ToString("yyyy-MM-dd HH:mm:ss") }
              elseif($v -is [byte[]]){ $v = "[binario]" }
              $row[$cols[$i]] = $v
            }
            $rows += [pscustomobject]$row
          }
          $reader.Close()
          Send-Json $stream 200 @{database=$database;columns=$cols;rows=$rows}
        } catch {
          Send-Json $stream 500 @{error=$_.Exception.Message}
        }
      }
      else {
        Send-Json $stream 404 @{error='Ruta no encontrada'}
      }
    } catch {
      try { Send-Json $stream 500 @{error=$_.Exception.Message} } catch {}
    } finally {
      try { $client.Close() } catch {}
    }
  }
}
finally {
  foreach($k in @($Sessions.Keys)){ try { $Sessions[$k].connection.Dispose() } catch {} }
  $listener.Stop()
}
){
            $hostPart = [string]$matches[1]
            $instancePart = [string]$matches[2]
            if($hostPart -eq '.' -or $hostPart -ieq 'localhost' -or $hostPart -ieq $env:COMPUTERNAME){
                $serverToUse = '.\\' + $instancePart
            }
        }
    } catch {}
    $cn = New-SqlConnection -Server $serverToUse -Auth $Auth -User $User -Password $Password
    $cn.Open()
    $cmd = $cn.CreateCommand()
    $cmd.CommandText = "SELECT name FROM sys.databases WHERE state_desc='ONLINE' AND HAS_DBACCESS(name)=1 ORDER BY name;"
    $reader = $cmd.ExecuteReader()
    $dbs = @()
    while($reader.Read()){ $dbs += [string]$reader.GetString(0) }
    $reader.Close()

    $sid = [guid]::NewGuid().ToString()
    $Sessions[$sid] = @{ connection=$cn; databases=$dbs; server=$Server; auth=$Auth; user=$User }
    $script:ActiveSessionId = $sid
    return @{sessionId=$sid;server=$Server;auth=$Auth;user=$User;databases=$dbs}
}

function Ensure-ActiveSession {
    if($script:ActiveSessionId -and $Sessions.ContainsKey($script:ActiveSessionId)){
        try {
            $sess = $Sessions[$script:ActiveSessionId]
            if($sess.connection.State -eq [System.Data.ConnectionState]::Open){
                $db = ""
                if($sess.ContainsKey("database")){ $db = [string]$sess.database }
                return @{sessionId=$script:ActiveSessionId;server=$sess.server;auth=$sess.auth;user=$sess.user;databases=$sess.databases;database=$db}
            }
        } catch {}
    }
    return $null
}

function Get-HomeHtml {
@"
<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Capitan Rodolfo - SQL local</title>
<style>
:root{--bg:#0d0d0f;--card:#17171b;--line:#34343b;--orange:#ff7a00;--text:#f5f5f6;--muted:#aaaab2;--ok:#35d07f;--bad:#ff6b6b}
*{box-sizing:border-box}body{margin:0;background:radial-gradient(circle at 30% 0,#21170f,#0d0d0f 42%);color:var(--text);font-family:Segoe UI,Arial,sans-serif;min-height:100vh}
.wrap{width:min(1120px,94vw);margin:28px auto}.top{display:flex;justify-content:space-between;align-items:center;margin-bottom:18px}.ver{background:var(--orange);color:#111;padding:7px 10px;border-radius:999px;font-weight:900;font-size:12px}
.grid{display:grid;grid-template-columns:390px 1fr;gap:18px}.card{background:#17171bf2;border:1px solid var(--line);border-radius:20px;padding:20px}
h1{margin:0 0 4px}.muted{color:var(--muted);font-size:13px;line-height:1.5}label{display:block;font-size:12px;color:var(--muted);margin:13px 0 6px}
input,select{width:100%;background:#0f0f12;border:1px solid #3a3a41;color:white;padding:12px;border-radius:11px}
button{width:100%;border:0;border-radius:12px;padding:13px;margin-top:14px;background:linear-gradient(135deg,#ff7a00,#ff9630);font-weight:900;cursor:pointer}
.status{margin-top:14px;padding:11px;border:1px solid var(--line);border-radius:11px;color:var(--muted);font-size:13px}.ok{color:#86e8b2;border-color:#235f43}.bad{color:#ffaaaa;border-color:#6b2a2a}
.cols{display:grid;grid-template-columns:1fr 1fr;gap:16px}.list{display:grid;gap:8px;max-height:520px;overflow:auto}.item,.table{border:1px solid #34343b;background:#121216;color:#eee;padding:10px;border-radius:10px}.item{cursor:pointer}.item:hover,.item.active{border-color:var(--orange);background:#21170f}
.note{margin-top:15px;font-size:12px;color:var(--muted)}
.heroTop{display:flex;align-items:center;justify-content:space-between;gap:18px}
.rodolfoMini{position:relative;width:118px;height:108px;flex:0 0 118px}
.rCap{position:absolute;left:22px;top:2px;width:76px;height:34px;background:var(--orange);border:4px solid #111116;border-radius:50% 50% 12% 12%;z-index:3}
.rCap:after{content:"";position:absolute;right:-28px;bottom:-3px;width:48px;height:11px;background:var(--orange);border:4px solid #111116;border-radius:50%}
.rHead{position:absolute;left:35px;top:28px;width:58px;height:64px;background:#f0aa78;border:4px solid #111116;border-radius:44% 44% 46% 46%}
.rEye{position:absolute;top:51px;width:6px;height:8px;background:#111;border-radius:50%;z-index:4}.rEye.l{left:52px}.rEye.r{left:74px}
.rMust{position:absolute;left:49px;top:70px;width:32px;height:10px;background:#19191d;border-radius:50%;z-index:4}
.rBody{position:absolute;left:28px;bottom:0;width:72px;height:32px;background:#2b2b33;border:4px solid #111116;border-radius:14px 14px 8px 8px}
.rTie{position:absolute;left:60px;bottom:2px;width:12px;height:30px;background:var(--orange);clip-path:polygon(35% 0,65% 0,85% 75%,50% 100%,15% 75%);z-index:4}
.dispatchCard{margin-top:18px;background:#17171bf2;border:1px solid var(--line);border-radius:20px;padding:20px}
.dispatchHead{display:flex;justify-content:space-between;align-items:center;gap:12px;margin-bottom:12px}.dispatchHead h2{margin:0}.query{font-size:11px;color:#ffb06a}
.tableWrap{overflow:auto;max-height:420px;border:1px solid #34343b;border-radius:12px}.dataGrid{border-collapse:collapse;width:100%;font-size:12px;min-width:720px}.dataGrid th,.dataGrid td{padding:9px 10px;border-bottom:1px solid #2b2b31;border-right:1px solid #24242a;text-align:left;white-space:nowrap}.dataGrid th{position:sticky;top:0;background:#21170f;color:#ffb06a;z-index:1}.dataGrid td{background:#111116}
.continueMap{display:none;margin-top:14px;background:linear-gradient(135deg,#2dd9ff,#34f5a5);color:#061116}.continueMap.show{display:block}
@media(max-width:900px){.grid,.cols{grid-template-columns:1fr}.rodolfoMini{transform:scale(.9);transform-origin:right center}}
</style>
</head>
<body>
<div class="wrap">
<div class="top"><div><strong>DoingLio - CAPITÁN RODOLFO</strong><div class="muted">Conector SQL local</div></div><span class="ver">v$Version</span></div>
<div class="grid">
<section class="card">
<div class="heroTop">
<div><h1>Conexion SQL</h1><div class="muted">Esta pantalla corre dentro de tu PC. No depende de CORS ni del acceso a red local del navegador.</div></div>
<div class="rodolfoMini" aria-label="Capitan Rodolfo">
  <div class="rCap"></div><div class="rHead"></div><div class="rEye l"></div><div class="rEye r"></div><div class="rMust"></div><div class="rBody"></div><div class="rTie"></div>
</div>
</div>
<label>Servidor / instancia</label><input id="server" value="DUILIO\SQLEXPRESS" autocomplete="off">
<label>Autenticacion</label>
<select id="auth"><option value="sql">Usuario y contrasena SQL Server</option><option value="windows">Windows</option></select>
<div id="sqlCreds"><label>Usuario SQL</label><input id="user" autocomplete="username"><label>Contraseña</label><input id="password" type="password" autocomplete="current-password" placeholder="Ingresá la contraseña la primera vez"></div>
<div id="credentialState" class="note">Buscando conexión guardada…</div>
<button id="connect">Conectar y guardar</button>
<div id="status" class="status">Servicio SQL local v$Version listo.</div>
<button id="goMap" class="continueMap" type="button">Continuar al Mapa Vivo -></button>
<div class="note">La conexión queda guardada localmente y protegida con tu usuario de Windows. Al volver a abrir Capitán Rodolfo intenta reconectarse automáticamente a la última base elegida.</div>
</section>
<section class="card">
<div class="cols"><div><h3>Bases</h3><div id="dbs" class="list"><div class="item">Conectate para ver bases</div></div></div><div><h3>Tablas</h3><div id="tables" class="list"><div class="table">Selecciona una base</div></div></div></div>
</section>
</div>
<section class="dispatchCard">
  <div class="dispatchHead"><h2>Tabla SURPLA</h2><span class="query">SELECT * FROM dbo.SURPLA</span></div>
  <div id="surpla" class="muted">Conectate y elegí una base para ver SURPLA.</div>
</section>
<section class="dispatchCard">
  <div class="dispatchHead"><h2>Despachos abiertos</h2><span class="query">SELECT * FROM Despachos WHERE estadovta = 0</span></div>
  <div id="dispatches" class="muted">Selecciona una base para ver los despachos.</div>
</section>
</div>
<script>
let sessionId=null;
const s=document.getElementById('status'), dbs=document.getElementById('dbs'), tables=document.getElementById('tables'), surpla=document.getElementById('surpla'), dispatches=document.getElementById('dispatches'), goMap=document.getElementById('goMap'), credentialState=document.getElementById('credentialState');
const serverInput=document.getElementById('server'),authInput=document.getElementById('auth'),userInput=document.getElementById('user'),passwordInput=document.getElementById('password');
let selectedDatabase=null;
function status(m,k=''){s.textContent=m;s.className='status '+k}
function updateAuth(){document.getElementById('sqlCreds').style.display=authInput.value==='windows'?'none':'block'}
authInput.onchange=updateAuth;
async function api(path,body){
 const r=await fetch(path,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body||{})});
 const j=await r.json().catch(()=>({})); if(!r.ok) throw new Error(j.error||('HTTP '+r.status)); return j;
}
async function getJson(path){
 const r=await fetch(path,{cache:'no-store'});const j=await r.json().catch(()=>({}));if(!r.ok)throw new Error(j.error||('HTTP '+r.status));return j;
}
function showDatabases(d,autoDb){
 sessionId=d.sessionId;
 dbs.innerHTML='';
 (d.databases||[]).forEach(name=>{
   const b=document.createElement('button');b.className='item';b.textContent=name;b.onclick=()=>loadTables(name,b);dbs.appendChild(b);
   if(autoDb&&name===autoDb)setTimeout(()=>loadTables(name,b),0);
 });
}
async function restoreSaved(){
 try{
  const p=await getJson('/api/profile-status');
  if(p.saved){
    serverInput.value=p.server||serverInput.value;authInput.value=p.auth||'sql';userInput.value=p.user||'';updateAuth();
    if(p.hasPassword){passwordInput.value='';passwordInput.placeholder='Contraseña guardada y protegida por Windows';credentialState.textContent='Usuario '+(p.user||'(Windows)')+' · contraseña guardada de forma segura · base '+(p.database||'sin elegir');}
    else credentialState.textContent='Conexión guardada sin contraseña SQL.';
  }else{
    credentialState.textContent='Todavía no hay usuario/contraseña guardados en esta PC.';
  }
  let state=await getJson('/api/state');
  if(!state.connected&&p.saved){
    status('Reconectando automáticamente…');
    state=await api('/api/reconnect-saved',{});
  }
  if(state.connected){
    serverInput.value=state.server||serverInput.value;authInput.value=state.auth||authInput.value;userInput.value=state.user||userInput.value;updateAuth();
    showDatabases(state,state.database||p.database);
    if(state.database) status('SQL conectado automáticamente · '+state.database,'ok');
    else status('SQL conectado automáticamente · elegí una base','ok');
  }
 }catch(e){status('Servicio activo, pero no pude recuperar la conexión guardada: '+e.message,'bad')}
}
document.getElementById('connect').onclick=async()=>{
 try{
  status('Conectando…');
  const payload={server:serverInput.value.trim(),auth:authInput.value,user:userInput.value.trim(),password:passwordInput.value};
  const d=await api('/api/connect',payload); passwordInput.value=''; passwordInput.placeholder='Contraseña guardada y protegida por Windows'; credentialState.textContent='Usuario '+(payload.user||'(Windows)')+' · contraseña protegida y guardada localmente'; status('Conectado a '+d.server+' - elegí una base','ok');
  showDatabases(d,null);
 }catch(e){status('No se pudo conectar. '+e.message,'bad')}
};
restoreSaved();
async function loadTables(database,el){
 try{
  selectedDatabase=database;
  [...document.querySelectorAll('#dbs .item')].forEach(x=>x.classList.remove('active'));el.classList.add('active');
  tables.innerHTML='<div class="table">Validando base…</div>';
  const d=await api('/api/tables',{sessionId,database});
  tables.innerHTML='';d.tables.forEach(t=>{const row=document.createElement('div');row.className='table';row.textContent=t.schema+'.'+t.name;tables.appendChild(row)});
  status('Base '+database+' conectada. Mostrando SELECT * FROM dbo.SURPLA','ok');
  const result=await api('/api/surpla',{sessionId,database});
  renderGrid(surpla,result,'SURPLA no tiene filas.');
  goMap.classList.add('show');
 }catch(e){
  status('Error: '+e.message,'bad')
 }
}
function renderGrid(container,data,emptyText){
 container.innerHTML='';
 if(!data.rows||!data.rows.length){container.innerHTML='<div class="muted">'+emptyText+'</div>';return}
 const wrap=document.createElement('div');wrap.className='tableWrap';
 const table=document.createElement('table');table.className='dataGrid';
 const thead=document.createElement('thead'),trh=document.createElement('tr');
 data.columns.forEach(c=>{const th=document.createElement('th');th.textContent=c;trh.appendChild(th)});thead.appendChild(trh);table.appendChild(thead);
 const tbody=document.createElement('tbody');
 data.rows.forEach(row=>{const tr=document.createElement('tr');data.columns.forEach(c=>{const td=document.createElement('td');const v=row[c];td.textContent=(v===null||v===undefined)?'':String(v);tr.appendChild(td)});tbody.appendChild(tr)});
 table.appendChild(tbody);wrap.appendChild(table);container.appendChild(wrap);
}
function renderDispatches(data){
 dispatches.innerHTML='';
 if(!data.rows||!data.rows.length){dispatches.innerHTML='<div class="muted">No hay despachos con estadovta = 0.</div>';return}
 const wrap=document.createElement('div');wrap.className='tableWrap';
 const table=document.createElement('table');table.className='dataGrid';
 const thead=document.createElement('thead'),trh=document.createElement('tr');
 data.columns.forEach(c=>{const th=document.createElement('th');th.textContent=c;trh.appendChild(th)});thead.appendChild(trh);table.appendChild(thead);
 const tbody=document.createElement('tbody');
 data.rows.forEach(row=>{const tr=document.createElement('tr');data.columns.forEach(c=>{const td=document.createElement('td');const v=row[c];td.textContent=(v===null||v===undefined)?'':String(v);tr.appendChild(td)});tbody.appendChild(tr)});
 table.appendChild(tbody);wrap.appendChild(table);dispatches.appendChild(wrap);
}
goMap.textContent='Ver tanques y surtidores →'; goMap.onclick=()=>{if(sessionId&&selectedDatabase) location.href='/mapa-vivo?sessionId='+encodeURIComponent(sessionId)+'&database='+encodeURIComponent(selectedDatabase)};
</script>
</body></html>
"@
}

try {
    $profile = Load-SqlProfile
    if($null -ne $profile){
        $savedPassword = Unprotect-ProfilePassword -Profile $profile
        $restored = Open-SqlSession -Server ([string]$profile.server) -Auth ([string]$profile.auth) -User ([string]$profile.user) -Password $savedPassword
        $savedDb = [string]$profile.database
        if(-not [string]::IsNullOrWhiteSpace($savedDb) -and $restored.databases -contains $savedDb){
            $Sessions[$restored.sessionId]["database"] = $savedDb
        }
        Write-Host "Conexion SQL restaurada: $([string]$profile.server) / $savedDb"
    }
} catch {
    $script:LastRestoreError = $_.Exception.Message
    Write-Host "No se pudo restaurar la conexion SQL guardada: $script:LastRestoreError"
}

try {
    $statusState = Ensure-ActiveSession
    if($null -ne $statusState){
        Write-ServiceStatus -State "running-connected" -Database ([string]$statusState.database) -Server ([string]$statusState.server) -User ([string]$statusState.user)
    } else {
        Write-ServiceStatus -State "running-no-sql" -ErrorMessage ([string]$script:LastRestoreError)
    }
} catch {
    Write-ServiceStatus -State "running-no-sql" -ErrorMessage $_.Exception.Message
}

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback,$Port)
$listener.Start()
Write-Host "Capitan Rodolfo local v$Version escuchando en http://127.0.0.1:$Port/"

try {
  while($true){
    $client = $listener.AcceptTcpClient()
    try {
      $stream = $client.GetStream()
      $req = Read-Request -Stream $stream
      if($null -eq $req){ continue }
      $script:CurrentOrigin = ""
      if($req.Headers.ContainsKey('origin')){ $script:CurrentOrigin = [string]$req.Headers['origin'] }

      $pathOnly = ($req.Path -split '\?')[0]
      if($req.Method -eq 'OPTIONS'){
        Send-Response $stream 204 'text/plain' ''
      }
      elseif($req.Method -eq 'GET' -and $pathOnly -eq '/health'){
        $st = Ensure-ActiveSession
        $db = ""
        if($null -ne $st){ $db = [string]$st.database }
        Send-Json $stream 200 @{ok=$true;service='Capitan Rodolfo Local';version=$Version;mode='background';scheduledTask=$TaskName;statusFile=$ServiceStatusPath;profileSaved=(Test-Path $ProfilePath);connected=($null -ne $st);database=$db}
      }
      elseif($req.Method -eq 'GET' -and $pathOnly -eq '/api/profile-status'){
        $p = Load-SqlProfile
        if($null -eq $p){
          Send-Json $stream 200 @{saved=$false;server='';auth='sql';user='';database='';hasPassword=$false}
        } else {
          Send-Json $stream 200 @{
            saved=$true
            server=[string]$p.server
            auth=[string]$p.auth
            user=[string]$p.user
            database=[string]$p.database
            hasPassword=(-not [string]::IsNullOrWhiteSpace([string]$p.passwordProtected))
          }
        }
      }
      elseif($req.Method -eq 'POST' -and $pathOnly -eq '/api/reconnect-saved'){
        try {
          $p = Load-SqlProfile
          if($null -eq $p){ throw 'No hay una conexión SQL guardada en este equipo.' }
          $savedPassword = Unprotect-ProfilePassword -Profile $p
          $state = Open-SqlSession -Server ([string]$p.server) -Auth ([string]$p.auth) -User ([string]$p.user) -Password $savedPassword
          $savedDb = [string]$p.database
          if(-not [string]::IsNullOrWhiteSpace($savedDb) -and $state.databases -contains $savedDb){
            $Sessions[$state.sessionId]["database"] = $savedDb
          }
          $script:LastRestoreError = ''
          Write-ServiceStatus -State 'running-connected' -Database $savedDb -Server ([string]$p.server) -User ([string]$p.user)
          Send-Json $stream 200 @{sessionId=$state.sessionId;server=$state.server;auth=$state.auth;user=$state.user;databases=$state.databases;database=$savedDb;restored=$true}
        } catch {
          $script:LastRestoreError = $_.Exception.Message
          Write-ServiceStatus -State 'running-no-sql' -ErrorMessage $script:LastRestoreError
          Send-Json $stream 500 @{error=$_.Exception.Message}
        }
      }
      elseif($req.Method -eq 'GET' -and $pathOnly -eq '/api/openai/status'){
        Send-Json $stream 200 @{configured=(-not [string]::IsNullOrWhiteSpace((Get-OpenAIKey)));defaultEngine='openai';model='gpt-realtime-2.1'}
      }
      elseif($req.Method -eq 'POST' -and $pathOnly -eq '/api/openai/config'){
        try {$data=$req.Body|ConvertFrom-Json;Save-OpenAIKey -ApiKey ([string]$data.apiKey);Send-Json $stream 200 @{ok=$true;configured=$true;defaultEngine='openai'}} catch {Send-Json $stream 400 @{error=$_.Exception.Message}}
      }
      elseif($req.Method -eq 'POST' -and $pathOnly -eq '/api/openai/realtime-secret'){
        try {$key=Get-OpenAIKey;if([string]::IsNullOrWhiteSpace($key)){throw 'Configurá la clave de OpenAI en Núcleo → Inteligencia.'};Send-Json $stream 200 (New-OpenAIRealtimeSecret -ApiKey $key)} catch {Send-Json $stream 500 @{error=$_.Exception.Message}}
      }
      elseif($req.Method -eq 'POST' -and $pathOnly -eq '/api/ai/sql-read'){
        try {$data=$req.Body|ConvertFrom-Json;Send-Json $stream 200 (Invoke-ReadOnlySql -SessionId ([string]$data.sessionId) -Database ([string]$data.database) -Sql ([string]$data.sql))} catch {Send-Json $stream 400 @{error=$_.Exception.Message}}
      }
      elseif($req.Method -eq 'GET' -and $pathOnly -eq '/api/station-summary'){
        try {
          $state = Ensure-ActiveSession
          if($null -eq $state -or [string]::IsNullOrWhiteSpace([string]$state.database)){
            Send-Json $stream 200 @{
              connected=$false
              bridge=$true
              serviceMode='background'
              scheduledTask=$TaskName
              statusFile=$ServiceStatusPath
              profileSaved=(Test-Path $ProfilePath)
              restoreError=[string]$script:LastRestoreError
            }
            continue
          }
          $cn = $Sessions[$state.sessionId].connection
          $cn.ChangeDatabase([string]$state.database)

          $q = $cn.CreateCommand()
          $q.CommandText = "IF OBJECT_ID('dbo.Tanque') IS NULL SELECT 0 ELSE SELECT COUNT(*) FROM dbo.Tanque"
          $tankCount = [int]$q.ExecuteScalar()

          $q = $cn.CreateCommand()
          $q.CommandText = "IF OBJECT_ID('dbo.Surtan') IS NULL SELECT 0 ELSE SELECT COUNT(*) FROM dbo.Surtan"
          $hoseCount = [int]$q.ExecuteScalar()

          $q = $cn.CreateCommand()
          $q.CommandText = "IF OBJECT_ID('dbo.Surtan') IS NULL OR COL_LENGTH('dbo.Surtan','SURTIDOR') IS NULL SELECT 0 ELSE EXEC('SELECT COUNT(DISTINCT SURTIDOR) FROM dbo.Surtan WHERE SURTIDOR IS NOT NULL')"
          $pumpCount = [int]$q.ExecuteScalar()

          $q = $cn.CreateCommand()
          $q.CommandText = "IF OBJECT_ID('dbo.Despachos') IS NULL SELECT 0 AS cantidad,CAST(0 AS decimal(18,2)) AS litros,CAST(0 AS decimal(18,2)) AS pesos ELSE SELECT COUNT(*) cantidad,ISNULL(SUM(CAST(Litros AS decimal(18,2))),0) litros,ISNULL(SUM(CAST(pesos AS decimal(18,2))),0) pesos FROM dbo.Despachos"
          $rdr = $q.ExecuteReader()
          $dispatchCount = 0; $liters = 0; $pesos = 0
          if($rdr.Read()){
            $dispatchCount = [int]$rdr["cantidad"]
            $liters = [decimal]$rdr["litros"]
            $pesos = [decimal]$rdr["pesos"]
          }
          $rdr.Close()

          Send-Json $stream 200 @{
            connected=$true
            bridge=$true
            serviceMode='background'
            scheduledTask=$TaskName
            statusFile=$ServiceStatusPath
            database=[string]$state.database
            server=[string]$state.server
            tankCount=$tankCount
            hoseCount=$hoseCount
            pumpCount=$pumpCount
            dispatchCount=$dispatchCount
            liters=$liters
            pesos=$pesos
          }
        } catch {
          Send-Json $stream 500 @{error=$_.Exception.Message}
        }
      }
      elseif($req.Method -eq 'GET' -and $pathOnly -eq '/api/tanks'){
        try {
          $state = Ensure-ActiveSession
          if($null -eq $state -or [string]::IsNullOrWhiteSpace([string]$state.database)){
            Send-Json $stream 200 @{connected=$false}
            continue
          }

          $cn = $Sessions[$state.sessionId].connection
          $cn.ChangeDatabase([string]$state.database)

          $existsCmd = $cn.CreateCommand()
          $existsCmd.CommandText = "SELECT CASE WHEN OBJECT_ID('dbo.Tanque','U') IS NULL THEN 0 ELSE 1 END"
          $tableExists = ([int]$existsCmd.ExecuteScalar() -eq 1)
          if(-not $tableExists){
            Send-Json $stream 200 @{connected=$true;database=[string]$state.database;table='dbo.Tanque';tableExists=$false;columns=@();rowCount=0;rows=@()}
            continue
          }

          $q = $cn.CreateCommand()
          $q.CommandText = "SELECT TOP (200) * FROM dbo.Tanque"
          $q.CommandTimeout = 15
          $rdr = $q.ExecuteReader()
          try {
            $columns = New-Object System.Collections.Generic.List[string]
            for($i=0;$i -lt $rdr.FieldCount;$i++){ $columns.Add($rdr.GetName($i)) }

            $rows = New-Object System.Collections.Generic.List[object]
            while($rdr.Read()){
              $row = [ordered]@{}
              for($i=0;$i -lt $rdr.FieldCount;$i++){
                $value = $rdr.GetValue($i)
                if($value -is [DBNull]){ $value = $null }
                $row[$rdr.GetName($i)] = $value
              }
              $rows.Add([pscustomobject]$row)
            }

            Send-Json $stream 200 @{
              connected=$true
              database=[string]$state.database
              table='dbo.Tanque'
              tableExists=$true
              columns=$columns
              rowCount=$rows.Count
              rows=$rows
            }
          } finally {
            $rdr.Close()
          }
        } catch {
          Send-Json $stream 500 @{error=$_.Exception.Message}
        }
      }
      elseif($req.Method -eq 'GET' -and $pathOnly -eq '/api/state'){
        $state = Ensure-ActiveSession
        if($null -eq $state){
          Send-Json $stream 200 @{connected=$false}
        } else {
          Send-Json $stream 200 @{connected=$true;sessionId=$state.sessionId;server=$state.server;auth=$state.auth;user=$state.user;databases=$state.databases;database=$state.database}
        }
      }
      elseif($req.Method -eq 'GET' -and ($pathOnly -eq '/' -or $pathOnly -eq '/index.html')){
        Send-Response $stream 200 "text/html; charset=utf-8" (Get-HomeHtml)
      }
      elseif($req.Method -eq 'GET' -and $pathOnly -eq '/mapa-vivo'){
        try {
          $query = [System.Web.HttpUtility]::ParseQueryString(([uri]("http://127.0.0.1" + $req.Path)).Query)
          $sid = [string]$query['sessionId']
          $database = [string]$query['database']
          if(-not $Sessions.ContainsKey($sid)){ throw "Sesion SQL no valida." }
          $sess = $Sessions[$sid]
          if($sess.databases -notcontains $database){ throw "Base no autorizada." }

          $cn = $sess.connection
          $cn.ChangeDatabase($database)

          $dispatchIdColumn = $null
          $idMetaCmd = $cn.CreateCommand()
          $idMetaCmd.CommandText = @"
SELECT TOP 1 c.name
FROM sys.columns c
WHERE c.object_id = OBJECT_ID('dbo.Despachos')
  AND (
    LOWER(REPLACE(c.name,'_','')) IN ('iddespacho','iddespcho')
    OR LOWER(c.name) LIKE '%id%desp%'
    OR LOWER(c.name) LIKE '%desp%id%'
  )
ORDER BY CASE WHEN LOWER(REPLACE(c.name,'_',''))='iddespacho' THEN 0
              WHEN LOWER(REPLACE(c.name,'_',''))='iddespcho' THEN 1
              ELSE 2 END, c.column_id;
"@
          $dispatchIdValue = $idMetaCmd.ExecuteScalar()
          if($null -ne $dispatchIdValue -and $dispatchIdValue -isnot [DBNull]){
            $dispatchIdColumn = [string]$dispatchIdValue
          }

          $dispatchIdSelect = "NULL AS id_despacho"
          if(-not [string]::IsNullOrWhiteSpace($dispatchIdColumn)){
            $dispatchIdSelect = "d.[" + $dispatchIdColumn.Replace("]","]]") + "] AS id_despacho"
          }

          $cmd = $cn.CreateCommand()
          $cmd.CommandText = "SELECT " + $dispatchIdSelect + ", id_sale venta, surtidor, manguera, d.codart, p.descriimpresion, Litros, PPU, pesos, d.Ultime fecha, Ultime as hora FROM Despachos d INNER JOIN prod p ON d.codart = p.codart;"
          $reader = $cmd.ExecuteReader()
          $dispatchRows = New-Object System.Collections.Generic.List[object]
          while($reader.Read()){
            $dispatchRows.Add([pscustomobject]@{
              id_despacho = if($reader["id_despacho"] -is [DBNull]){""}else{[string]$reader["id_despacho"]}
              venta = if($reader["venta"] -is [DBNull]){""}else{[string]$reader["venta"]}
              surtidor = if($reader["surtidor"] -is [DBNull]){""}else{[string]$reader["surtidor"]}
              manguera = if($reader["manguera"] -is [DBNull]){""}else{[string]$reader["manguera"]}
              codart = if($reader["codart"] -is [DBNull]){""}else{[string]$reader["codart"]}
              producto = if($reader["descriimpresion"] -is [DBNull]){""}else{[string]$reader["descriimpresion"]}
              litros = if($reader["Litros"] -is [DBNull]){""}else{[string]$reader["Litros"]}
              ppu = if($reader["PPU"] -is [DBNull]){""}else{[string]$reader["PPU"]}
              pesos = if($reader["pesos"] -is [DBNull]){""}else{[string]$reader["pesos"]}
              fecha = if($reader["fecha"] -is [DBNull]){""}elseif($reader["fecha"] -is [DateTime]){([DateTime]$reader["fecha"]).ToString("dd/MM/yyyy HH:mm:ss")}else{[string]$reader["fecha"]}
              hora = if($reader["hora"] -is [DBNull]){""}elseif($reader["hora"] -is [DateTime]){([DateTime]$reader["hora"]).ToString("HH:mm:ss")}else{[string]$reader["hora"]}
            })
          }
          $reader.Close()

          $tankCmd = $cn.CreateCommand()
          $tankCmd.CommandText = "SELECT t.N_TANQUE, t.DENOMINACION, p.DESCRIIMPRESION, t.CAPACIDAD FROM Tanque t INNER JOIN prod p ON t.CODART = p.codart;"
          $tankReader = $tankCmd.ExecuteReader()
          $tankRows = New-Object System.Collections.Generic.List[object]
          while($tankReader.Read()){
            $tankRows.Add([pscustomobject]@{
              numero = if($tankReader["N_TANQUE"] -is [DBNull]){""}else{[string]$tankReader["N_TANQUE"]}
              denominacion = if($tankReader["DENOMINACION"] -is [DBNull]){""}else{[string]$tankReader["DENOMINACION"]}
              producto = if($tankReader["DESCRIIMPRESION"] -is [DBNull]){""}else{[string]$tankReader["DESCRIIMPRESION"]}
              capacidad = if($tankReader["CAPACIDAD"] -is [DBNull]){""}else{[string]$tankReader["CAPACIDAD"]}
            })
          }
          $tankReader.Close()
          $tankCount = $tankRows.Count

          $hoseSurtidorSelect = "NULL"
          $hoseMetaCmd = $cn.CreateCommand()
          $hoseMetaCmd.CommandText = "SELECT COUNT(*) FROM sys.columns WHERE object_id=OBJECT_ID('dbo.Surtan') AND UPPER(name)='SURTIDOR';"
          if(([int]$hoseMetaCmd.ExecuteScalar()) -gt 0){ $hoseSurtidorSelect = "s.SURTIDOR" }
          $hoseCmd = $cn.CreateCommand()
          $hoseCmd.CommandText = "SELECT s.N_TANQUE, t.DENOMINACION, " + $hoseSurtidorSelect + " AS SURTIDOR, s.MANGUERA, p.DESCRIIMPRESION FROM Surtan s INNER JOIN Tanque t ON s.N_TANQUE = t.N_TANQUE INNER JOIN prod p ON s.CODART = p.Codart;"
          $hoseReader = $hoseCmd.ExecuteReader()
          $hoseRows = New-Object System.Collections.Generic.List[object]
          while($hoseReader.Read()){
            $hoseRows.Add([pscustomobject]@{
              tanque = if($hoseReader["N_TANQUE"] -is [DBNull]){""}else{[string]$hoseReader["N_TANQUE"]}
              denominacion = if($hoseReader["DENOMINACION"] -is [DBNull]){""}else{[string]$hoseReader["DENOMINACION"]}
              surtidor = if($hoseReader["SURTIDOR"] -is [DBNull]){""}else{[string]$hoseReader["SURTIDOR"]}
              manguera = if($hoseReader["MANGUERA"] -is [DBNull]){""}else{[string]$hoseReader["MANGUERA"]}
              producto = if($hoseReader["DESCRIIMPRESION"] -is [DBNull]){""}else{[string]$hoseReader["DESCRIIMPRESION"]}
            })
          }
          $hoseReader.Close()
          $hoseCount = $hoseRows.Count

          $realSurtidores = @($hoseRows | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.surtidor) } | ForEach-Object { [string]$_.surtidor } | Sort-Object -Unique)
          $surtidorCountText = if($realSurtidores.Count -gt 0){ [string]$realSurtidores.Count } else { "?" }

          $hoseCards = ""
          foreach($h in $hoseRows){
            $ht = [System.Net.WebUtility]::HtmlEncode([string]$h.tanque)
            $hd = [System.Net.WebUtility]::HtmlEncode([string]$h.denominacion)
            $hs = [System.Net.WebUtility]::HtmlEncode([string]$h.surtidor)
            $hm = [System.Net.WebUtility]::HtmlEncode([string]$h.manguera)
            $hp = [System.Net.WebUtility]::HtmlEncode([string]$h.producto)
            $surtidorLabel = if([string]::IsNullOrWhiteSpace($hs)){ "S?" } else { "S$hs" }
            $hoseCards += "<div class='hoseRow'><b>T$ht</b><span class='arrow'>&rarr;</span><strong>$surtidorLabel</strong><span class='arrow'>&rarr;</span><strong>M$hm</strong><span class='hoseProduct'>$hp</span><small>$hd</small></div>"
          }
          if([string]::IsNullOrWhiteSpace($hoseCards)){
            $hoseCards = "<div class='empty'>Sin relaciones Tanque → Surtidor → Manguera para mostrar.</div>"
          }

          $tankCards = ""
          foreach($t in $tankRows){
            $tn = [System.Net.WebUtility]::HtmlEncode([string]$t.numero)
            $td = [System.Net.WebUtility]::HtmlEncode([string]$t.denominacion)
            $tp = [System.Net.WebUtility]::HtmlEncode([string]$t.producto)
            $tc = [System.Net.WebUtility]::HtmlEncode([string]$t.capacidad)
            $tankHoses = @($hoseRows | Where-Object { [string]$_.tanque -eq [string]$t.numero })
            $tankHoseText = ""
            foreach($th in $tankHoses){
              if($tankHoseText){ $tankHoseText += " | " }
              $tankHoseText += "S$([System.Net.WebUtility]::HtmlEncode([string]$th.surtidor)) / M$([System.Net.WebUtility]::HtmlEncode([string]$th.manguera)) - $([System.Net.WebUtility]::HtmlEncode([string]$th.producto))"
            }
            if(-not $tankHoseText){ $tankHoseText = "Sin mangueras asociadas" }
            $tankCards += "<button type='button' class='tankRow tankPick' data-num='$tn' data-den='$td' data-prod='$tp' data-cap='$tc' data-hoses='$tankHoseText'><b>T$tn</b><span class='tankName'>$td</span><span class='tankProduct'>$tp</span><strong>$tc L</strong></button>"
          }
          if([string]::IsNullOrWhiteSpace($tankCards)){
            $tankCards = "<div class='empty'>Sin tanques para mostrar.</div>"
          }

          $safeDb = [System.Net.WebUtility]::HtmlEncode($database)
          $cards = ""
          foreach($d in $dispatchRows){
            $idDespacho = [System.Net.WebUtility]::HtmlEncode([string]$d.id_despacho)
            $venta = [System.Net.WebUtility]::HtmlEncode([string]$d.venta)
            $surt = [System.Net.WebUtility]::HtmlEncode([string]$d.surtidor)
            $mang = [System.Net.WebUtility]::HtmlEncode([string]$d.manguera)
            $prod = [System.Net.WebUtility]::HtmlEncode([string]$d.producto)
            $lit = [System.Net.WebUtility]::HtmlEncode([string]$d.litros)
            $ppu = [System.Net.WebUtility]::HtmlEncode([string]$d.ppu)
            $pes = [System.Net.WebUtility]::HtmlEncode([string]$d.pesos)
            $hora = [System.Net.WebUtility]::HtmlEncode([string]$d.hora)
            $cards += "<button type='button' class='dispatchRow salePick' data-id-despacho='$idDespacho' data-venta='$venta' data-surtidor='$surt' data-manguera='$mang' data-producto='$prod' data-litros='$lit' data-ppu='$ppu' data-pesos='$pes' data-hora='$hora'><b>#$venta</b><span>Surt. $surt - Mang. $mang</span><span class='product'>$prod</span><span>$lit L - PPU $ppu - <strong>&#36;$pes</strong></span><small>$hora</small></button>"
          }
          if([string]::IsNullOrWhiteSpace($cards)){
            $cards = "<div class='empty'>Sin despachos para mostrar.</div>"
          }
          $dispatchCount = $dispatchRows.Count

          $html = @"
<!doctype html>
<html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Mapa Vivo - Capitan Rodolfo</title>
<style>
:root{--bg:#050b12;--panel:#09141e;--line:#254154;--orange:#ff7138;--cyan:#2dd9ff;--green:#34f5a5;--text:#eaf6ff;--muted:#7ea2bb}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font-family:Segoe UI,Arial,sans-serif}
.top{display:flex;justify-content:space-between;align-items:center;gap:12px;padding:12px 18px;background:#07111a;border-bottom:1px solid var(--line);position:sticky;top:0;z-index:5}
.left{display:flex;align-items:center;gap:12px;flex-wrap:wrap}.badge{background:#11212c;border:1px solid #2b5267;border-radius:999px;padding:7px 11px;font-size:12px}.ok{color:var(--green)}.ver{color:#061116;background:var(--orange);border-radius:999px;padding:6px 9px;font-size:12px;font-weight:900}.navlink{color:#ccefff;text-decoration:none;border:1px solid #2b5267;border-radius:999px;padding:7px 11px;font-size:12px;font-weight:800}.navlink:hover{border-color:#2dd9ff;color:#fff}
.stage{padding:14px}.mapWrap{position:relative;max-width:1600px;margin:auto}.mapWrap>img{display:block;width:100%;height:auto;border:1px solid #173244;border-radius:18px;background:#050b12}
.dispatchOverlay{position:absolute;left:64.4%;top:60.4%;width:31.3%;height:18.5%;background:#07131df7;border:2px solid #2dd9ff;border-radius:18px;padding:12px 14px;overflow:hidden;box-shadow:0 8px 24px #0009}
.dispatchTitle{display:flex;justify-content:space-between;gap:10px;align-items:center;margin-bottom:8px;font-size:12px;letter-spacing:2px;color:#89a9bd}.dispatchTitle strong{color:#eaf6ff;letter-spacing:0}
.dispatchList{height:calc(100% - 28px);overflow:auto;padding-right:5px}.dispatchRow{display:grid;width:100%;grid-template-columns:auto auto 1fr auto auto;gap:8px;align-items:center;border:0;border-bottom:1px solid #173244;padding:6px 0;font-size:11px;white-space:nowrap;background:transparent;color:#eaf6ff;text-align:left;cursor:pointer}.dispatchRow:hover,.dispatchRow.active{background:#0d2633}.dispatchRow b{color:#34f5a5}.dispatchRow .product{overflow:hidden;text-overflow:ellipsis}.dispatchRow strong{color:#ffb06a}.dispatchRow small{color:#7ea2bb}.empty{color:#7ea2bb;padding:14px 0}
.tankOverlay{position:absolute;left:26.3%;top:31%;width:19.5%;max-height:31%;background:#09141ef2;border:2px solid #ff7138;border-radius:16px;padding:10px 12px;overflow:hidden;box-shadow:0 8px 24px #0009}
.tankTitle{display:flex;justify-content:space-between;align-items:center;gap:8px;margin-bottom:7px;font-size:11px;letter-spacing:2px;color:#89a9bd}.tankTitle strong{color:#eaf6ff;letter-spacing:0}
.tankList{max-height:210px;overflow:auto;padding-right:4px}.tankRow{display:grid;width:100%;grid-template-columns:auto 1fr auto;gap:6px;align-items:center;border:0;border-bottom:1px solid #173244;padding:5px 0;font-size:10px;background:transparent;color:#eaf6ff;text-align:left;cursor:pointer}.tankRow:hover,.tankRow.active{background:#2a1710}.tankRow b{color:#ff9d2e}.tankName{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.tankProduct{grid-column:1/-1;color:#7ea2bb;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.tankRow strong{color:#2dd9ff}
.hoseOverlay{position:absolute;left:46%;top:26%;width:17%;max-height:28%;background:#07131df2;border:2px solid #34f5a5;border-radius:16px;padding:10px 12px;overflow:hidden;box-shadow:0 8px 24px #0009}
.hoseTitle{display:flex;justify-content:space-between;align-items:center;gap:8px;margin-bottom:7px;font-size:10px;letter-spacing:1.5px;color:#89a9bd}.hoseTitle strong{color:#eaf6ff;letter-spacing:0}
.hoseList{max-height:180px;overflow:auto;padding-right:4px}.hoseRow{display:grid;grid-template-columns:auto auto auto auto auto 1fr;gap:5px;align-items:center;border-bottom:1px solid #173244;padding:5px 0;font-size:10px}.hoseRow b{color:#ff9d2e}.hoseRow strong{color:#34f5a5}.hoseRow .arrow{color:#2dd9ff}.hoseProduct{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.hoseRow small{grid-column:1/-1;color:#7ea2bb;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.tankHotspot{position:absolute;left:26.2%;top:23.8%;width:18.8%;height:6.5%;border:1px dashed #ff7138;background:#ff713812;color:#ffb06a;border-radius:10px;cursor:pointer;font-weight:900;letter-spacing:2px;z-index:3}
.hoseHotspot{position:absolute;left:46%;top:18%;width:17%;height:6.5%;border:1px dashed #34f5a5;background:#34f5a512;color:#8fffd0;border-radius:10px;cursor:pointer;font-weight:900;letter-spacing:1.4px;z-index:3}
.dispatchHotspot{position:absolute;left:70%;top:55%;width:22%;height:5.5%;border:1px dashed #2dd9ff;background:#2dd9ff12;color:#8fefff;border-radius:10px;cursor:pointer;font-weight:900;letter-spacing:1.2px;z-index:3}
.parentClose{border:0;background:transparent;color:#fff;cursor:pointer;font-size:15px;font-weight:900;padding:0 3px;margin:0;width:auto}
.detailCard{position:absolute;z-index:6;background:#07131df7;border:2px solid #ff7138;border-radius:16px;padding:12px 14px;box-shadow:0 10px 30px #000b;display:none}.detailCard.show{display:block}
#tankDetail{left:27%;top:64%;width:30%}#saleOnPump{left:50.3%;top:30%;width:20%;border-color:#34f5a5}
.detailTitle{font-size:11px;letter-spacing:1.5px;color:#89a9bd;margin-bottom:8px}.detailGrid{display:grid;grid-template-columns:auto 1fr;gap:6px 10px;font-size:12px}.detailGrid b{color:#fff}.detailGrid span{color:#8fb3c9}.detailClose{position:absolute;right:8px;top:7px;border:0;background:transparent;color:#fff;cursor:pointer;font-size:16px}
.paymentBtn{width:100%;margin-top:12px;border:0;border-radius:10px;padding:10px 12px;background:linear-gradient(135deg,#ff7138,#ff9d2e);color:#101010;font-weight:900;cursor:pointer}
#paymentPanel{left:50.3%;top:54%;width:20%;border-color:#ff7138}
.paymentPending{color:#ffb06a;font-size:12px;line-height:1.5}
.pumpCountBadge{position:absolute;left:48.7%;top:19.2%;z-index:4;background:#07131de8;border:1px solid #2dd9ff;color:#b9efff;border-radius:999px;padding:7px 11px;font-size:11px;font-weight:900;letter-spacing:1px}.pumpCountBadge strong{color:#fff}
.truckHotspot{position:absolute;left:3.5%;top:34%;width:23%;height:31%;z-index:4;border:1px solid transparent;background:transparent;border-radius:18px;cursor:pointer;color:transparent}.truckHotspot:hover{border-color:#ff7138;background:#ff71380c;box-shadow:0 0 26px #ff713833}.truckHotspot.feed{animation:truckFeedPulse .75s ease}
@keyframes truckFeedPulse{0%,100%{box-shadow:none}45%{box-shadow:0 0 0 10px #ff713822,0 0 38px #ff713888}}
.receiptModal{position:fixed;inset:0;z-index:60;display:none;place-items:center;background:#000b;padding:18px}.receiptModal.show{display:grid}
.receiptBox{width:min(650px,94vw);max-height:90vh;overflow:auto;background:#101820;border:1px solid #2d4759;border-radius:20px;padding:22px;box-shadow:0 30px 80px #000c;position:relative}.receiptBox h2{margin:0 0 8px}.receiptBox p{color:#8fb3c9;line-height:1.5}
.receiptClose{position:absolute;right:12px;top:10px;width:auto;margin:0;border:0;background:transparent;color:#fff;font-size:22px;cursor:pointer}
.receiptUpload{display:block;border:1px dashed #ff7138;background:#ff71380d;border-radius:14px;padding:18px;text-align:center;font-weight:900;cursor:pointer}.receiptUpload input{display:none}
.receiptStatus{margin-top:12px;border:1px solid #29495e;border-radius:11px;padding:10px;color:#a8c6d8;font-size:12px}.receiptStatus.ok{border-color:#247450;color:#8df0b8}.receiptStatus.bad{border-color:#7c3131;color:#ffb2b2}
.receiptPreview{margin-top:12px;border:1px solid #29495e;border-radius:12px;padding:10px;display:none}.receiptPreview.show{display:block}.receiptPreview img{max-width:100%;max-height:260px;display:block;margin:auto;border-radius:8px}.receiptPreview .pdf{padding:18px;text-align:center;color:#ffb06a;font-weight:900}
.revalLogin{display:none;margin-top:14px;padding:14px;border:1px solid #67482c;border-radius:12px;background:#1b1510}.revalLogin.show{display:block}.revalLogin input{width:100%;margin-top:7px;padding:11px;border-radius:9px;border:1px solid #3b4650;background:#091018;color:#fff}.revalLogin button{width:100%;margin-top:10px;padding:11px;border:0;border-radius:9px;background:#ff7138;font-weight:900;cursor:pointer}
.receiptResult{display:none;margin-top:14px}.receiptResult.show{display:block}
.invoice-paper{background:#fff;color:#1c2330;border-radius:14px;overflow:hidden;box-shadow:0 16px 50px #0008;border:1px solid #dfe5ea;font-family:Segoe UI,Arial,sans-serif}
.invoice-head{display:flex;justify-content:space-between;gap:16px;padding:18px 20px;border-bottom:1px solid #e4e8ec;background:linear-gradient(135deg,#fbfcfd,#f1f5f7)}
.invoice-head span{font-size:10px;letter-spacing:1.6px;color:#718092;font-weight:900}.invoice-head h3{margin:5px 0 3px;color:#17202b;font-size:19px}.invoice-head p{margin:0;color:#667483;font-size:11px}
.invoice-type{text-align:right}.invoice-type b{display:block;color:#ff5a3d;font-size:16px}.invoice-type small{display:block;margin-top:5px;color:#667483}
.invoice-meta{display:grid;grid-template-columns:repeat(3,1fr);gap:1px;background:#e6eaee}.invoice-meta>div{background:#fff;padding:11px 14px}.invoice-meta span,.invoice-footer span,.document-flow span{display:block;color:#788797;font-size:9px;text-transform:uppercase;letter-spacing:1px}.invoice-meta b{display:block;margin-top:3px;font-size:12px}
.document-flow{display:grid;grid-template-columns:1fr auto 1fr;gap:10px;align-items:center;padding:14px 18px;border-bottom:1px solid #e5e9ed}.document-flow b{display:block;margin:4px 0;font-size:12px}.document-flow small{display:block;color:#778491;font-size:10px}.flow-arrow{font-size:22px;color:#ff5a3d;font-weight:900}
.invoice-lines{padding:14px 18px}.invoice-line{display:grid;grid-template-columns:1fr 70px 95px 95px;gap:8px;padding:7px 0;border-bottom:1px solid #edf0f2;font-size:10px}.invoice-line-head{font-weight:900;color:#718092;text-transform:uppercase;letter-spacing:.7px}.invoice-line span:not(:first-child){text-align:right}
.invoice-totals{padding:10px 18px 14px;margin-left:auto;width:min(360px,100%)}.invoice-totals>div{display:flex;justify-content:space-between;gap:16px;padding:5px 0;color:#566473;font-size:11px}.invoice-grand{margin-top:5px;padding-top:10px!important;border-top:2px solid #1d2630;color:#111!important;font-size:15px!important}.invoice-grand b{color:#ff5a3d;font-size:18px}
.invoice-footer{display:grid;grid-template-columns:1fr 1fr;gap:12px;padding:12px 18px;background:#f5f7f8;border-top:1px solid #e5e9ed}.invoice-footer b{display:block;color:#273443;margin-top:3px;font-size:10px}
.invoice-empty{padding:16px;color:#667483;text-align:center;font-size:11px}
@media(max-width:650px){.invoice-line{grid-template-columns:1fr 48px 70px 75px;font-size:9px}.invoice-head{padding:14px}.invoice-meta{grid-template-columns:1fr}.invoice-footer{grid-template-columns:1fr}}
.receiptFly{position:fixed;z-index:90;width:180px;padding:10px;border:2px solid #ff7138;border-radius:12px;background:#fff;color:#111;font-weight:900;font-size:11px;box-shadow:0 12px 30px #0008;pointer-events:none;transition:transform .78s cubic-bezier(.2,.8,.2,1),opacity .78s ease;transform-origin:center}
.note{padding:0 18px 18px;color:var(--muted);font-size:13px}
@media(max-width:900px){.dispatchOverlay,.tankOverlay,.hoseOverlay,.detailCard{position:static;width:auto;height:auto;max-height:none;margin-top:12px}.tankHotspot,.hoseHotspot,.dispatchHotspot,.truckHotspot{display:none}.pumpCountBadge{position:static;display:inline-block;margin:8px 0}.tankList,.hoseList{max-height:260px}.dispatchRow{grid-template-columns:1fr 1fr}.dispatchRow .product{grid-column:1/-1}.detailCard{display:none}.detailCard.show{display:block}}
</style></head>
<body>
<header class="top"><div class="left"><a class="navlink" href="http://127.0.0.1:8790/">← DoingLio</a><a class="navlink" href="http://127.0.0.1:8790/capitan-rodolfo/index.html">← Capitán</a><span class="badge ok"><span style="color:#34f5a5">&#9679;</span> SQL conectado</span><span class="badge">Base: $safeDb</span></div><span class="ver">v$Version</span></header>
<main class="stage">
  <div class="mapWrap">
    <img src="http://127.0.0.1:8790/capitan-rodolfo/assets/capitan-rodolfo-mapa-vivo.svg" alt="Mapa Vivo de Capitan Rodolfo">
    <button id="truckHotspot" class="truckHotspot" type="button" title="Subir comprobante al camion" aria-label="Subir comprobante al camion">CAMION</button>
    <div class="pumpCountBadge">SURTIDORES (<strong>$surtidorCountText</strong>)</div>
    <button id="tankHotspot" class="tankHotspot" type="button">TANQUES ($tankCount)</button>
    <section id="tankPanel" class="tankOverlay" style="display:none">
      <div class="tankTitle"><span>TANQUES REALES</span><span><strong>$tankCount</strong> <button id="closeTankPanel" class="parentClose" type="button">x</button></span></div>
      <div class="tankList">$tankCards</div>
    </section>
    <button id="hoseHotspot" class="hoseHotspot" type="button">TANQUE &rarr; SURTIDOR &rarr; MANGUERA ($hoseCount)</button>
    <section id="hosePanel" class="hoseOverlay" style="display:none">
      <div class="hoseTitle"><span>TANQUE &rarr; SURTIDOR &rarr; MANGUERA</span><span><strong>$hoseCount</strong> <button id="closeHosePanel" class="parentClose" type="button">x</button></span></div>
      <div class="hoseList">$hoseCards</div>
    </section>
    <button id="dispatchHotspot" class="dispatchHotspot" type="button" style="display:none">VENTAS / DESPACHOS ($dispatchCount)</button>
    <section id="dispatchPanel" class="dispatchOverlay">
      <div class="dispatchTitle"><span>VENTAS / DESPACHOS</span><span><strong>$dispatchCount</strong> <button id="closeDispatchPanel" class="parentClose" type="button">x</button></span></div>
      <div class="dispatchList">$cards</div>
    </section>
    <section id="tankDetail" class="detailCard">
      <button class="detailClose" type="button" data-close="tankDetail">x</button>
      <div class="detailTitle">DETALLE DEL TANQUE</div>
      <div id="tankDetailBody" class="detailGrid"></div>
    </section>
    <section id="saleOnPump" class="detailCard">
      <button class="detailClose" type="button" data-close="saleOnPump">x</button>
      <div id="salePumpTitle" class="detailTitle">VENTA EN SURTIDOR</div>
      <div id="salePumpBody" class="detailGrid"></div>
      <button id="viewPaymentBtn" class="paymentBtn" type="button">VER PAGO</button>
    </section>
    <section id="paymentPanel" class="detailCard">
      <button class="detailClose" type="button" data-close="paymentPanel">x</button>
      <div class="detailTitle">PAGO DE LA VENTA</div>
      <div id="paymentBody" class="detailGrid"></div>
      <div class="paymentPending">Consulta de pago pendiente de definir. No se muestran datos inventados.</div>
    </section>
  </div>
</main>
<div id="receiptModal" class="receiptModal">
  <section class="receiptBox">
    <button id="receiptClose" class="receiptClose" type="button">x</button>
    <h2>Comprobante del camion</h2>
    <p>Subi una factura, recibo, transferencia, ticket o PDF. El camion recibe el archivo y Revalsoft IA lo analiza con la misma logica de TEST.</p>
    <label id="receiptUploadLabel" class="receiptUpload">SUBIR COMPROBANTE
      <input id="receiptFile" type="file" accept="image/*,.pdf">
    </label>
    <div id="receiptStatus" class="receiptStatus">Esperando archivo...</div>
    <div id="receiptPreview" class="receiptPreview"></div>
    <div id="revalLogin" class="revalLogin">
      <b>Iniciar sesion Revalsoft IA</b>
      <div style="font-size:12px;color:#b69c84;margin-top:4px">Se pide solo si este navegador local todavia no tiene una sesion valida.</div>
      <input id="revalEmail" type="email" autocomplete="username" placeholder="Email">
      <input id="revalPassword" type="password" autocomplete="current-password" placeholder="Contrasena">
      <button id="revalLoginBtn" type="button">INGRESAR Y ANALIZAR</button>
    </div>
    <div id="receiptResult" class="receiptResult">
      <h3>Comprobante analizado</h3>
      <div id="receiptResultBody" class="receiptResultGrid"></div>
    </div>
  </section>
</div>
<div class="note">Las ventanas padre controlan a sus hijas: al cerrar TANQUES se cierra el detalle; al cerrar VENTAS / DESPACHOS se cierran la venta seleccionada y VER PAGO.</div>
<script>
(function(){
  const tankPanel=document.getElementById('tankPanel');
  const tankHotspot=document.getElementById('tankHotspot');
  const hosePanel=document.getElementById('hosePanel');
  const hoseHotspot=document.getElementById('hoseHotspot');
  const closeTankPanel=document.getElementById('closeTankPanel');
  const closeHosePanel=document.getElementById('closeHosePanel');
  const dispatchPanel=document.getElementById('dispatchPanel');
  const dispatchHotspot=document.getElementById('dispatchHotspot');
  const closeDispatchPanel=document.getElementById('closeDispatchPanel');
  const tankDetail=document.getElementById('tankDetail');
  const tankBody=document.getElementById('tankDetailBody');
  const saleCard=document.getElementById('saleOnPump');
  const saleBody=document.getElementById('salePumpBody');
  const saleTitle=document.getElementById('salePumpTitle');
  const viewPaymentBtn=document.getElementById('viewPaymentBtn');
  const paymentPanel=document.getElementById('paymentPanel');
  const paymentBody=document.getElementById('paymentBody');
  const truckHotspot=document.getElementById('truckHotspot');
  const receiptModal=document.getElementById('receiptModal');
  const receiptClose=document.getElementById('receiptClose');
  const receiptFile=document.getElementById('receiptFile');
  const receiptUploadLabel=document.getElementById('receiptUploadLabel');
  const receiptStatus=document.getElementById('receiptStatus');
  const receiptPreview=document.getElementById('receiptPreview');
  const revalLogin=document.getElementById('revalLogin');
  const revalEmail=document.getElementById('revalEmail');
  const revalPassword=document.getElementById('revalPassword');
  const revalLoginBtn=document.getElementById('revalLoginBtn');
  const receiptResult=document.getElementById('receiptResult');
  const receiptResultBody=document.getElementById('receiptResultBody');
  const SB_URL='https://apqgrwudkfytwikrsivd.supabase.co';
  const SB_KEY='sb_publishable_B9NdjnzOKu9BhZGmTM6LGg_wDB3n8lY';
  let pendingReceipt=null;
  let selectedSale=null;

  function closeTankHierarchy(){
    tankPanel.style.display='none';
    tankDetail.classList.remove('show');
    document.querySelectorAll('.tankPick').forEach(x=>x.classList.remove('active'));
  }
  function closeSaleHierarchy(){
    dispatchPanel.style.display='none';
    dispatchHotspot.style.display='block';
    saleCard.classList.remove('show');
    paymentPanel.classList.remove('show');
    selectedSale=null;
    document.querySelectorAll('.salePick').forEach(x=>x.classList.remove('active'));
  }

  if(tankHotspot){
    tankHotspot.addEventListener('click',()=>{
      if(tankPanel.style.display==='none'){
        tankPanel.style.display='block';
      }else{
        closeTankHierarchy();
      }
    });
  }
  if(closeTankPanel){ closeTankPanel.addEventListener('click',closeTankHierarchy); }

  if(hoseHotspot){
    hoseHotspot.addEventListener('click',()=>{ hosePanel.style.display=(hosePanel.style.display==='none')?'block':'none'; });
  }
  if(closeHosePanel){ closeHosePanel.addEventListener('click',()=>{hosePanel.style.display='none';}); }

  if(closeDispatchPanel){ closeDispatchPanel.addEventListener('click',closeSaleHierarchy); }
  if(dispatchHotspot){
    dispatchHotspot.addEventListener('click',()=>{
      dispatchPanel.style.display='block';
      dispatchHotspot.style.display='none';
    });
  }

  document.querySelectorAll('.tankPick').forEach(btn=>{
    btn.addEventListener('click',()=>{
      document.querySelectorAll('.tankPick').forEach(x=>x.classList.remove('active')); btn.classList.add('active');
      tankBody.innerHTML=
        '<span>Tanque</span><b>'+btn.dataset.num+'</b>'+
        '<span>Denominacion</span><b>'+btn.dataset.den+'</b>'+
        '<span>Producto</span><b>'+btn.dataset.prod+'</b>'+
        '<span>Capacidad</span><b>'+btn.dataset.cap+' L</b>'+
        '<span>Mangueras</span><b>'+btn.dataset.hoses+'</b>';
      tankDetail.classList.add('show');
    });
  });

  document.querySelectorAll('.salePick').forEach(btn=>{
    btn.addEventListener('click',()=>{
      document.querySelectorAll('.salePick').forEach(x=>x.classList.remove('active')); btn.classList.add('active');
      selectedSale={
        idDespacho:btn.dataset.idDespacho||'',
        venta:btn.dataset.venta,
        surtidor:btn.dataset.surtidor,
        manguera:btn.dataset.manguera,
        producto:btn.dataset.producto,
        litros:btn.dataset.litros,
        ppu:btn.dataset.ppu,
        pesos:btn.dataset.pesos,
        hora:btn.dataset.hora
      };
      saleTitle.textContent='VENTA #'+btn.dataset.venta+' - SURTIDOR '+btn.dataset.surtidor;
      saleBody.innerHTML=
        '<span>Venta</span><b>#'+btn.dataset.venta+'</b>'+
        '<span>Surtidor</span><b>'+btn.dataset.surtidor+'</b>'+
        '<span>Manguera</span><b>'+btn.dataset.manguera+'</b>'+
        '<span>Producto</span><b>'+btn.dataset.producto+'</b>'+
        '<span>Litros</span><b>'+btn.dataset.litros+' L</b>'+
        '<span>PPU</span><b>'+btn.dataset.ppu+'</b>'+
        '<span>Pesos</span><b>$ '+btn.dataset.pesos+'</b>'+
        '<span>Hora</span><b>'+btn.dataset.hora+'</b>';
      saleCard.classList.add('show');
    });
  });

  if(viewPaymentBtn){
    viewPaymentBtn.addEventListener('click',async()=>{
      if(!selectedSale) return;
      paymentPanel.classList.add('show');
      paymentBody.innerHTML=
        '<span>Venta</span><b>#'+selectedSale.venta+'</b>'+
        '<span>Surtidor</span><b>'+selectedSale.surtidor+'</b>'+
        '<span>Importe</span><b>$ '+selectedSale.pesos+'</b>'+
        '<span>Pago</span><b>Buscando comprobante relacionado...</b>';
      try{
        const r=await fetch('/api/payment',{
          method:'POST',
          headers:{'Content-Type':'application/json'},
          body:JSON.stringify({sessionId:'$sid',database:'$safeDb',idDespacho:selectedSale.idDespacho,venta:selectedSale.venta})
        });
        const d=await r.json();
        if(!r.ok) throw new Error(d.error||('HTTP '+r.status));
        if(!d.resolved){
          paymentBody.innerHTML=
            '<span>Venta</span><b>#'+selectedSale.venta+'</b>'+
            '<span>id_despacho</span><b>'+escHtml(selectedSale.idDespacho||'NO DETECTADO')+'</b>'+
            '<span>Relacion</span><b>No pude resolver automaticamente el comprobante.</b>'+
            '<span>Columnas encontradas</span><b>'+escHtml((d.columns||[]).join(', '))+'</b>'+
            '<span>Detalle</span><b>'+escHtml(d.reason||'Sin detalle')+'</b>';
          return;
        }
        const p=d.payment||{};
        const c=d.comprobante||{};
        paymentBody.innerHTML=
          '<span>Comprobante</span><b>'+escHtml((c.letra||'')+' '+(c.sucursal||'')+'-'+(c.numero||''))+'</b>'+
          '<span>Mercado Pago</span><b>$ '+escHtml(p.MercadoPago||0)+'</b>'+
          '<span>App YPF</span><b>$ '+escHtml(p.AppYPF||0)+'</b>'+
          '<span>Shell Box</span><b>$ '+escHtml(p.ShellBox||0)+'</b>'+
          '<span>App Puma</span><b>$ '+escHtml(p.AppPuma||0)+'</b>'+
          '<span>Clover</span><b>$ '+escHtml(p.Clover||0)+'</b>'+
          '<span>PayWay</span><b>$ '+escHtml(p.PayWay||0)+'</b>'+
          '<span>Cheques</span><b>$ '+escHtml(p.Cheques||0)+'</b>'+
          '<span>Efectivo</span><b>$ '+escHtml(p.Efectivo||0)+'</b>'+
          '<span>Total</span><b>$ '+escHtml(p.TOTAL||selectedSale.pesos||0)+'</b>'+
          '<span>Vendedor</span><b>'+escHtml(p.Vendedor||'-')+'</b>';
        const pending=document.querySelector('#paymentPanel .paymentPending');
        if(pending) pending.textContent='Forma de pago obtenida desde RelacionCptsDespachos y la logica de PA_VentasFormasPago.';
      }catch(e){
        paymentBody.innerHTML=
          '<span>Venta</span><b>#'+selectedSale.venta+'</b>'+
          '<span>Error</span><b>'+escHtml(e.message||'No se pudo obtener la forma de pago')+'</b>';
      }
    });
  }

  function escHtml(v){
    return String(v==null?'':v).replace(/[&<>"']/g,function(ch){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]});
  }

  function setReceiptStatus(message,kind){
    receiptStatus.textContent=message;
    receiptStatus.className='receiptStatus'+(kind?' '+kind:'');
  }

  function readAsDataUrl(file){
    return new Promise(function(resolve,reject){
      const fr=new FileReader();
      fr.onload=function(){resolve(fr.result)};
      fr.onerror=reject;
      fr.readAsDataURL(file);
    });
  }

  async function refreshRevalsoftToken(){
    const refresh=localStorage.getItem('rodolfo.sb.refresh_token');
    if(!refresh) return null;
    try{
      const r=await fetch(SB_URL+'/auth/v1/token?grant_type=refresh_token',{
        method:'POST',
        headers:{'Content-Type':'application/json','apikey':SB_KEY},
        body:JSON.stringify({refresh_token:refresh})
      });
      const d=await r.json();
      if(!r.ok||!d.access_token) return null;
      localStorage.setItem('rodolfo.sb.access_token',d.access_token);
      if(d.refresh_token) localStorage.setItem('rodolfo.sb.refresh_token',d.refresh_token);
      localStorage.setItem('rodolfo.sb.expires_at',String(Date.now()+((d.expires_in||3600)*1000)));
      return d.access_token;
    }catch(_){return null}
  }

  async function getRevalsoftToken(){
    const token=localStorage.getItem('rodolfo.sb.access_token');
    const expires=Number(localStorage.getItem('rodolfo.sb.expires_at')||0);
    if(token && expires>Date.now()+30000) return token;
    return refreshRevalsoftToken();
  }

  async function loginRevalsoft(){
    const email=revalEmail.value.trim();
    const password=revalPassword.value;
    if(!email||!password) throw new Error('Completa email y contrasena.');
    const r=await fetch(SB_URL+'/auth/v1/token?grant_type=password',{
      method:'POST',
      headers:{'Content-Type':'application/json','apikey':SB_KEY},
      body:JSON.stringify({email:email,password:password})
    });
    const d=await r.json();
    if(!r.ok||!d.access_token) throw new Error(d.error_description||d.msg||d.error||'No se pudo iniciar sesion.');
    localStorage.setItem('rodolfo.sb.access_token',d.access_token);
    if(d.refresh_token) localStorage.setItem('rodolfo.sb.refresh_token',d.refresh_token);
    localStorage.setItem('rodolfo.sb.expires_at',String(Date.now()+((d.expires_in||3600)*1000)));
    revalPassword.value='';
    return d.access_token;
  }

  function normalizeKey(value){
    return String(value||'').toLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g,'').replace(/[^a-z0-9]/g,'');
  }
  function findValue(source,names,depth){
    depth=depth||0;
    if(!source||typeof source!=='object'||depth>7) return undefined;
    const wanted=names.map(normalizeKey);
    for(const key of Object.keys(source)){
      const value=source[key];
      if(wanted.includes(normalizeKey(key)) && value!==null && value!=='' && typeof value!=='object') return value;
    }
    for(const value of Object.values(source)){
      const found=findValue(value,names,depth+1);
      if(found!==undefined) return found;
    }
  }
  function findItems(source,depth){
    depth=depth||0;
    if(!source||typeof source!=='object'||depth>7) return [];
    for(const key of Object.keys(source)){
      const value=source[key];
      if(['items','item','detalle','detalles','lineas','conceptos','productos'].includes(normalizeKey(key)) && Array.isArray(value)) return value;
    }
    for(const value of Object.values(source)){
      const found=findItems(value,depth+1);
      if(found.length) return found;
    }
    return [];
  }
  function docText(data,names,fallback){
    const v=findValue(data,names,0);
    return v===undefined?(fallback===undefined?'-':fallback):String(v);
  }
  function docMoney(data,names){
    const value=findValue(data,names,0);
    const raw=String(value==null?'':value).trim();
    const number=Number(raw.replace(/\.(?=\d{3}(?:\D|$))/g,'').replace(',','.').replace(/[^0-9.-]/g,''));
    if(!Number.isFinite(number)||!raw) return '-';
    const currency=docText(data,['moneda'],'ARS')==='USD'?'USD':'ARS';
    try{return new Intl.NumberFormat('es-AR',{style:'currency',currency:currency,maximumFractionDigits:2}).format(number)}
    catch(_){return raw}
  }
  function renderReceiptResult(data){
    const type=docText(data,['tipo_documento','tipoDocumento','tipo_comprobante','tipoComprobante'],'COMPROBANTE').toUpperCase();
    const items=findItems(data,0);
    const isTransfer=type.includes('TRANSFER');
    const isReceipt=type.includes('RECIB');
    const issuer=isTransfer?docText(data,['plataforma'],'Transferencia'):docText(data,['proveedor','emisor','origen_nombre'],type);
    const headerSub=isTransfer
      ? 'Operacion: '+docText(data,['numero_operacion','codigo_identificacion'])
      : 'CUIT: '+docText(data,['proveedor_cuit','emisor_cuit','cuit']);
    let html='<div class="invoice-paper">';
    html+='<div class="invoice-head"><div><span>COMPROBANTE PROCESADO</span><h3>'+escHtml(issuer)+'</h3><p>'+escHtml(headerSub)+'</p></div>';
    html+='<div class="invoice-type"><b>'+escHtml(type)+'</b><small>'+escHtml(docText(data,['numero_comprobante','numero_operacion','numero','nro']))+'</small></div></div>';
    html+='<div class="invoice-meta"><div><span>Fecha</span><b>'+escHtml(docText(data,['fecha','fecha_emision']))+'</b></div><div><span>Hora</span><b>'+escHtml(docText(data,['hora']))+'</b></div><div><span>Moneda</span><b>'+escHtml(docText(data,['moneda'],'ARS'))+'</b></div></div>';
    if(isTransfer){
      html+='<div class="document-flow"><div><span>ORIGEN</span><b>'+escHtml(docText(data,['origen_nombre','emisor']))+'</b><small>'+escHtml(docText(data,['origen_cuit','emisor_cuit']))+'</small><small>'+escHtml(docText(data,['origen_cuenta']))+'</small></div><div class="flow-arrow">&rarr;</div><div><span>DESTINO</span><b>'+escHtml(docText(data,['destino_nombre','receptor']))+'</b><small>'+escHtml(docText(data,['destino_cuit','receptor_cuit']))+'</small><small>'+escHtml(docText(data,['destino_cuenta']))+'</small></div></div>';
    }else if(isReceipt){
      html+='<div class="document-flow"><div><span>RECIBIDO DE</span><b>'+escHtml(docText(data,['emisor','origen_nombre','cliente']))+'</b><small>'+escHtml(docText(data,['emisor_cuit','origen_cuit','cliente_cuit']))+'</small></div><div class="flow-arrow">&rarr;</div><div><span>RECIBIDO POR</span><b>'+escHtml(docText(data,['receptor','destino_nombre','proveedor']))+'</b><small>'+escHtml(docText(data,['receptor_cuit','destino_cuit','proveedor_cuit']))+'</small></div></div>';
    }
    if(items.length){
      html+='<div class="invoice-lines"><div class="invoice-line invoice-line-head"><span>Detalle</span><span>Cant.</span><span>Precio</span><span>Importe</span></div>';
      items.slice(0,10).forEach(function(item){
        html+='<div class="invoice-line"><span>'+escHtml(docText(item,['descripcion','nombre','producto','detalle'],'Item'))+'</span><span>'+escHtml(docText(item,['cantidad','quantity','canti'],'1'))+'</span><span>'+escHtml(docMoney(item,['precio_unitario','precio','price']))+'</span><span>'+escHtml(docMoney(item,['importe','total','subtotal']))+'</span></div>';
      });
      html+='</div>';
    }
    html+='<div class="invoice-totals">';
    if(!isTransfer&&!isReceipt){
      html+='<div><span>Subtotal</span><b>'+escHtml(docMoney(data,['subtotal','neto','importe_neto']))+'</b></div>';
      html+='<div><span>IVA</span><b>'+escHtml(docMoney(data,['total_iva','iva','importe_iva']))+'</b></div>';
      html+='<div><span>Impuestos / percepciones</span><b>'+escHtml(docMoney(data,['percepciones','impuestos','otros_impuestos']))+'</b></div>';
    }
    const totalLabel=isTransfer?'IMPORTE TRANSFERIDO':(isReceipt?'IMPORTE RECIBIDO':'TOTAL');
    html+='<div class="invoice-grand"><span>'+totalLabel+'</span><b>'+escHtml(docMoney(data,['importe','total','importe_total','monto_total']))+'</b></div></div>';
    html+='<div class="invoice-footer">';
    if(isTransfer||isReceipt){
      html+='<span>Medio<b>'+escHtml(docText(data,['medio_pago','plataforma']))+'</b></span><span>Motivo<b>'+escHtml(docText(data,['motivo','observaciones']))+'</b></span>';
    }else{
      html+='<span>CAE<b>'+escHtml(docText(data,['cae']))+'</b></span><span>Vencimiento CAE<b>'+escHtml(docText(data,['cae_vencimiento','vencimiento_cae']))+'</b></span>';
    }
    html+='</div></div>';
    receiptResultBody.innerHTML=html;
    receiptResult.classList.add('show');
  }

  async function analyzeReceipt(file){
    pendingReceipt=file;
    let token=await getRevalsoftToken();
    if(!token){
      revalLogin.classList.add('show');
      setReceiptStatus('Comprobante recibido por el camion. Inicia sesion Revalsoft IA para analizarlo.','ok');
      return;
    }
    revalLogin.classList.remove('show');
    setReceiptStatus('Camion recibio el comprobante. Analizando con Revalsoft IA TEST...');
    const base64=await readAsDataUrl(file);
    let r=await fetch(SB_URL+'/functions/v1/extract-document-json',{
      method:'POST',
      headers:{'Content-Type':'application/json','apikey':SB_KEY,'Authorization':'Bearer '+token},
      body:JSON.stringify({file_name:file.name,mime_type:file.type||'application/octet-stream',base64:base64})
    });
    if(r.status===401){
      localStorage.removeItem('rodolfo.sb.access_token');
      token=await refreshRevalsoftToken();
      if(token){
        r=await fetch(SB_URL+'/functions/v1/extract-document-json',{
          method:'POST',
          headers:{'Content-Type':'application/json','apikey':SB_KEY,'Authorization':'Bearer '+token},
          body:JSON.stringify({file_name:file.name,mime_type:file.type||'application/octet-stream',base64:base64})
        });
      }
    }
    const out=await r.json().catch(function(){return {}});
    if(!r.ok||!out.ok){
      if(r.status===401){
        revalLogin.classList.add('show');
        throw new Error('Sesion Revalsoft IA vencida. Inicia sesion nuevamente.');
      }
      throw new Error(out.error||'No se pudo analizar el comprobante.');
    }
    renderReceiptResult(out.data||{});
    setReceiptStatus('Comprobante analizado correctamente.','ok');
  }

  function animateReceiptToTruck(file){
    return new Promise(function(resolve){
      const source=receiptUploadLabel.getBoundingClientRect();
      const target=truckHotspot.getBoundingClientRect();
      const fly=document.createElement('div');
      fly.className='receiptFly';
      fly.textContent='COMPROBANTE - '+file.name;
      fly.style.left=(source.left+source.width/2-90)+'px';
      fly.style.top=(source.top+source.height/2-20)+'px';
      document.body.appendChild(fly);
      const dx=(target.left+target.width/2)-(source.left+source.width/2);
      const dy=(target.top+target.height/2)-(source.top+source.height/2);
      requestAnimationFrame(function(){
        requestAnimationFrame(function(){
          fly.style.transform='translate('+dx+'px,'+dy+'px) scale(.08) rotate(-10deg)';
          fly.style.opacity='0';
          truckHotspot.classList.add('feed');
        });
      });
      setTimeout(function(){
        fly.remove();
        truckHotspot.classList.remove('feed');
        resolve();
      },820);
    });
  }

  if(truckHotspot){
    truckHotspot.addEventListener('click',function(){
      receiptModal.classList.add('show');
      receiptResult.classList.remove('show');
      setReceiptStatus('Esperando archivo...');
    });
  }

  if(receiptClose){
    receiptClose.addEventListener('click',function(){receiptModal.classList.remove('show')});
  }
  receiptModal.addEventListener('click',function(e){if(e.target===receiptModal)receiptModal.classList.remove('show')});

  if(receiptFile){
    receiptFile.addEventListener('change',async function(){
      const file=receiptFile.files&&receiptFile.files[0];
      if(!file) return;
      pendingReceipt=file;
      receiptResult.classList.remove('show');
      receiptPreview.innerHTML='';
      if(file.type&&file.type.indexOf('image/')===0){
        const img=document.createElement('img');
        img.src=URL.createObjectURL(file);
        img.onload=function(){setTimeout(function(){URL.revokeObjectURL(img.src)},1000)};
        receiptPreview.appendChild(img);
      }else{
        receiptPreview.innerHTML='<div class="pdf">PDF - '+escHtml(file.name)+'</div>';
      }
      receiptPreview.classList.add('show');
      setReceiptStatus(file.name+' - '+(file.size/1024/1024).toFixed(2)+' MB');
      await animateReceiptToTruck(file);
      try{await analyzeReceipt(file)}catch(e){setReceiptStatus(e.message||'Error al analizar.','bad')}
    });
  }

  if(revalLoginBtn){
    revalLoginBtn.addEventListener('click',async function(){
      try{
        revalLoginBtn.disabled=true;
        setReceiptStatus('Iniciando sesion Revalsoft IA...');
        await loginRevalsoft();
        revalLogin.classList.remove('show');
        if(pendingReceipt) await analyzeReceipt(pendingReceipt);
      }catch(e){
        setReceiptStatus(e.message||'No se pudo iniciar sesion.','bad');
      }finally{
        revalLoginBtn.disabled=false;
      }
    });
  }

  document.querySelectorAll('[data-close]').forEach(btn=>{
    btn.addEventListener('click',()=>{
      const id=btn.dataset.close;
      document.getElementById(id).classList.remove('show');
      if(id==='saleOnPump'){
        paymentPanel.classList.remove('show');
        selectedSale=null;
        document.querySelectorAll('.salePick').forEach(x=>x.classList.remove('active'));
      }
    });
  });
})();
</script>
</body></html>
"@
          Send-Response $stream 200 "text/html; charset=utf-8" $html
        } catch {
          Send-Response $stream 401 "text/html; charset=utf-8" "<h2>Sesion SQL no valida</h2><p>$([System.Net.WebUtility]::HtmlEncode($_.Exception.Message))</p><p>Volver a abrir Capitan Rodolfo para reconectar.</p>"
        }
      }
      elseif($req.Method -eq 'POST' -and $pathOnly -eq '/api/connect'){
        try {
          $data = $req.Body | ConvertFrom-Json
          $server = [string]$data.server
          $auth = [string]$data.auth
          $user = [string]$data.user
          $password = [string]$data.password
          if([string]::IsNullOrWhiteSpace($server)){ throw "Completá servidor/instancia." }
          if($auth -eq 'sql' -and [string]::IsNullOrWhiteSpace($password)){
            $saved = Load-SqlProfile
            if($null -ne $saved -and [string]$saved.server -eq $server -and [string]$saved.auth -eq $auth -and [string]$saved.user -eq $user){
              $password = Unprotect-ProfilePassword -Profile $saved
            }
          }

          $state = Open-SqlSession -Server $server -Auth $auth -User $user -Password $password
          Save-SqlProfile -Server $server -Auth $auth -User $user -Password $password -Database ""
          $script:LastRestoreError = ""
          Write-ServiceStatus -State "running-connected" -Database "" -Server $server -User $user
          Send-Json $stream 200 $state
        } catch {
          Send-Json $stream 500 @{error=$_.Exception.Message}
        }
      }
      elseif($req.Method -eq 'POST' -and $pathOnly -eq '/api/tables'){
        try {
          $data = $req.Body | ConvertFrom-Json
          $sid = [string]$data.sessionId
          $database = [string]$data.database
          if(-not $Sessions.ContainsKey($sid)){ Send-Json $stream 401 @{error='Sesion vencida. Volver a conectar.'}; continue }
          $sess = $Sessions[$sid]
          if($sess.databases -notcontains $database){ Send-Json $stream 403 @{error='Base no autorizada.'}; continue }

          $cn = $sess.connection
          $cn.ChangeDatabase($database)
          $cmd = $cn.CreateCommand()
          $cmd.CommandText = @"
SELECT s.name AS esquema, t.name AS tabla
FROM sys.tables AS t
INNER JOIN sys.schemas AS s ON s.schema_id=t.schema_id
ORDER BY s.name,t.name;
"@
          $reader = $cmd.ExecuteReader()
          $rows = @()
          while($reader.Read()){ $rows += @{schema=[string]$reader.GetString(0);name=[string]$reader.GetString(1)} }
          $reader.Close()
          $sess["database"] = $database
          Save-SqlProfile -Server ([string]$sess.server) -Auth ([string]$sess.auth) -User ([string]$sess.user) -Password "" -Database $database
          Write-ServiceStatus -State "running-connected" -Database $database -Server ([string]$sess.server) -User ([string]$sess.user)
          Send-Json $stream 200 @{database=$database;tables=$rows}
        } catch {
          Send-Json $stream 500 @{error=$_.Exception.Message}
        }
      }
      elseif($req.Method -eq 'POST' -and $pathOnly -eq '/api/surpla'){
        try {
          $data = $req.Body | ConvertFrom-Json
          $sid = [string]$data.sessionId
          $database = [string]$data.database
          if(-not $Sessions.ContainsKey($sid)){ Send-Json $stream 401 @{error='Sesion vencida. Volver a conectar.'}; continue }
          $sess = $Sessions[$sid]
          if($sess.databases -notcontains $database){ Send-Json $stream 403 @{error='Base no autorizada.'}; continue }
          $cn = $sess.connection
          $cn.ChangeDatabase($database)
          $cmd = $cn.CreateCommand()
          $cmd.CommandText = 'SELECT * FROM dbo.SURPLA;'
          $cmd.CommandTimeout = 30
          $reader = $cmd.ExecuteReader()
          $columns = @()
          for($i=0;$i -lt $reader.FieldCount;$i++){ $columns += [string]$reader.GetName($i) }
          $rows = @()
          while($reader.Read()){
            $row = [ordered]@{}
            for($i=0;$i -lt $reader.FieldCount;$i++){
              $value = $reader.GetValue($i)
              if($value -is [DBNull]){ $value = $null }
              elseif($value -is [DateTime]){ $value = ([DateTime]$value).ToString('dd/MM/yyyy HH:mm:ss') }
              $row[$columns[$i]] = $value
            }
            $rows += [pscustomobject]$row
          }
          $reader.Close()
          Send-Json $stream 200 @{database=$database;query='SELECT * FROM dbo.SURPLA';columns=$columns;rows=$rows;rowCount=$rows.Count}
        } catch {
          Send-Json $stream 500 @{error=$_.Exception.Message}
        }
      }
      elseif($req.Method -eq 'POST' -and $pathOnly -eq '/api/payment'){
        try {
          $data = $req.Body | ConvertFrom-Json
          $sid = [string]$data.sessionId
          $database = [string]$data.database
          $idDespacho = [string]$data.idDespacho
          if(-not $Sessions.ContainsKey($sid)){ Send-Json $stream 401 @{error='Sesion vencida. Volver a conectar.'}; continue }
          $sess = $Sessions[$sid]
          if($sess.databases -notcontains $database){ Send-Json $stream 403 @{error='Base no autorizada.'}; continue }
          $cn = $sess.connection
          $cn.ChangeDatabase($database)

          $metaCmd = $cn.CreateCommand()
          $metaCmd.CommandText = "SELECT c.name FROM sys.columns c WHERE c.object_id=OBJECT_ID('dbo.RelacionCptsDespachos') ORDER BY c.column_id;"
          $mr = $metaCmd.ExecuteReader()
          $relationColumns = @()
          while($mr.Read()){ $relationColumns += [string]$mr.GetString(0) }
          $mr.Close()
          if($relationColumns.Count -eq 0){
            Send-Json $stream 200 @{resolved=$false;reason='No existe dbo.RelacionCptsDespachos o no tiene columnas visibles.';columns=@()}
            continue
          }

          function Normalize-LocalName([string]$name){
            return ($name.ToLowerInvariant() -replace '[^a-z0-9]','')
          }
          function Pick-RelationColumn($columns,[string[]]$exact,[string[]]$contains){
            foreach($e in $exact){
              foreach($c in $columns){ if((Normalize-LocalName $c) -eq $e){ return $c } }
            }
            foreach($needle in $contains){
              foreach($c in $columns){ if((Normalize-LocalName $c).Contains($needle)){ return $c } }
            }
            return $null
          }

          $dispatchCol = Pick-RelationColumn $relationColumns @('iddespacho','iddespcho') @('iddesp','despachoid','despacho')
          if([string]::IsNullOrWhiteSpace($dispatchCol)){
            Send-Json $stream 200 @{resolved=$false;reason='No pude identificar la columna que relaciona con Despachos.';columns=$relationColumns}
            continue
          }
          if([string]::IsNullOrWhiteSpace($idDespacho)){
            Send-Json $stream 200 @{resolved=$false;reason='El registro de Despachos no expuso su ID interno.';columns=$relationColumns}
            continue
          }

          $relCmd = $cn.CreateCommand()
          $relCmd.CommandText = "SELECT TOP 1 * FROM dbo.RelacionCptsDespachos WHERE ["+$dispatchCol.Replace("]","]]")+"] = @id;"
          $null = $relCmd.Parameters.Add("@id",[System.Data.SqlDbType]::VarChar,100)
          $relCmd.Parameters["@id"].Value = $idDespacho
          $rr = $relCmd.ExecuteReader()
          if(-not $rr.Read()){
            $rr.Close()
            Send-Json $stream 200 @{resolved=$false;reason='No encontre una fila en RelacionCptsDespachos para id_despacho='+$idDespacho;columns=$relationColumns}
            continue
          }
          $rel = @{}
          for($i=0;$i -lt $rr.FieldCount;$i++){
            $name=[string]$rr.GetName($i)
            $val=$rr.GetValue($i)
            if($val -is [DBNull]){ $val=$null }
            $rel[$name]=$val
          }
          $rr.Close()

          $letterCol = Pick-RelationColumn $relationColumns @('letra','letter') @('letracomp','letracpte')
          $branchCol = Pick-RelationColumn $relationColumns @('sucursal','pos') @('sucursalcomp','poscomp')
          $numberCol = Pick-RelationColumn $relationColumns @('ncompro','numero','nrocompro','nrocomprobante','invoicenumber') @('ncompro','numerocomp','nrocomp','invoice')
          $typeCol = Pick-RelationColumn $relationColumns @('tipo','type','tipocpte','tipocomprobante') @('tipocomp','tipocpte')

          $letra = if($letterCol){[string]$rel[$letterCol]}else{''}
          $sucursal = if($branchCol){[string]$rel[$branchCol]}else{''}
          $numero = if($numberCol){[string]$rel[$numberCol]}else{''}
          $tipo = if($typeCol){[string]$rel[$typeCol]}else{''}

          if([string]::IsNullOrWhiteSpace($sucursal) -or [string]::IsNullOrWhiteSpace($numero)){
            Send-Json $stream 200 @{resolved=$false;reason='Encontre la relacion, pero no pude identificar sucursal/numero de comprobante.';columns=$relationColumns;relation=$rel}
            continue
          }

          $isTicket = (($tipo.ToUpperInvariant()).Contains('TICKET') -or $letra.ToUpperInvariant() -eq 'T')
          $payCmd = $cn.CreateCommand()

          if($isTicket){
            $payCmd.CommandText = @"
SELECT TOP 1
 'T' AS letra,
 MT.sucursal,
 MT.Numero AS NCOMPRO,
 MT.turno AS Turno,
 ISNULL(ROUND(MP_O.amount,2),0) AS MercadoPago,
 ISNULL(ROUND(ypf_P.amount,2),0) AS AppYPF,
 ISNULL(ROUND(SH_P.TotalAmount,2),0) AS ShellBox,
 ISNULL(ROUND(PU_P.TotalTransaction-PU_P.Discounts,2),0) AS AppPuma,
 ISNULL(ROUND(C_P.Amount,2),0) AS Clover,
 ISNULL(ROUND(ISNULL(T.IMPORTETAR,0)-ISNULL(T.Extraccion,0),2),0) AS PayWay,
 CAST(0 AS decimal(18,2)) AS Cheques,
 ROUND(MT.TOTAL-(
   ISNULL(ROUND(C_P.Amount,2),0)+ISNULL(ROUND(MP_O.amount,2),0)+ISNULL(ROUND(ypf_P.amount,2),0)+
   ISNULL(ROUND(ISNULL(T.IMPORTETAR,0)-ISNULL(T.Extraccion,0),2),0)+
   ISNULL(ROUND(SH_P.TotalAmount,2),0)+ISNULL(ROUND(PU_P.TotalTransaction,2),0)
 ),2) AS Efectivo,
 MT.TOTAL,
 ISNULL(CAST(MT.Vendedor AS VARCHAR(8)),'0')+' - '+ISNULL(MV.RAZONSOC,'SIN VENDEDOR') AS Vendedor
FROM (
 SELECT Sucursal,Numero,turno,SUM(TOTAL) TOTAL,VENDEDOR
 FROM Maetic
 WHERE Sucursal=@Sucursal AND Numero=@Numero
 GROUP BY Sucursal,Numero,turno,VENDEDOR
) MT
LEFT JOIN MP_OrdenPagoComprobante MP_C ON MT.SUCURSAL=MP_C.Sucursal AND MT.NUMERO=MP_C.Numero AND MP_C.Tipo='TICKET'
LEFT JOIN MP_OrdenPago MP_O ON MP_C.ID_OrdenPago=MP_O.ID
LEFT JOIN YPF_PaymentIntentionComprobante ypf_C ON MT.SUCURSAL=ypf_C.Sucursal AND MT.NUMERO=ypf_C.Numero AND ypf_C.Tipo='TICKET'
LEFT JOIN YPF_PaymentIntention ypf_P ON ypf_P.ID=ypf_C.ID_PaymentIntention
LEFT JOIN Shell_PayOrderComprobante SH_C ON MT.SUCURSAL=SH_C.Sucursal AND MT.NUMERO=SH_C.Numero AND SH_C.Tipo='TICKET'
LEFT JOIN Shell_PayOrder SH_P ON SH_C.PayOrderId=SH_P.ID
LEFT JOIN PUMA_PaymentComprobante PU_C ON MT.SUCURSAL=PU_C.Sucursal AND MT.NUMERO=PU_C.Numero AND PU_C.Tipo='TICKET'
LEFT JOIN PUMA_Payment PU_P ON PU_C.PaymentId=PU_P.ID
LEFT JOIN Tarjet T ON T.Letra='T' AND MT.SUCURSAL=T.Sucursal AND MT.NUMERO=T.NFACT
LEFT JOIN Clover_PaymentInvoices C_PI ON MT.SUCURSAL=C_PI.Pos AND MT.NUMERO=C_PI.InvoiceNumber AND C_PI.Type='TICKET'
LEFT JOIN Clover_Payments C_P ON C_P.Id=C_PI.CloverPaymentId
LEFT JOIN Maeven MV ON MV.VENDEDOR=MT.VENDEDOR;
"@
          } else {
            if([string]::IsNullOrWhiteSpace($letra)){
              Send-Json $stream 200 @{resolved=$false;reason='Encontre sucursal y numero, pero falta letra/tipo para distinguir factura de ticket.';columns=$relationColumns;relation=$rel}
              continue
            }
            $payCmd.CommandText = @"
SELECT TOP 1
 M.letra,M.sucursal,M.NCOMPRO,M.turno AS Turno,
 ISNULL(ROUND(MP_O.amount,2),0.00) AS MercadoPago,
 ISNULL(ROUND(ypf_P.amount,2),0) AS AppYPF,
 ISNULL(ROUND(SH_P.TotalAmount,2),0) AS ShellBox,
 ISNULL(ROUND(PU_P.TotalTransaction-PU_P.Discounts,2),0) AS AppPuma,
 ISNULL(ROUND(C_P.Amount,2),0) AS Clover,
 ISNULL(ROUND(ISNULL(T.IMPORTETAR,0)-ISNULL(T.Extraccion,0),2),0) AS PayWay,
 M.cheques AS Cheques,
 CASE M.CONDVTA WHEN 2 THEN 0 ELSE
 ROUND((M.TOTAL-(
   ISNULL(ROUND(C_P.Amount,2),0)+ISNULL(ROUND(MP_O.amount,2),0)+ISNULL(ROUND(ypf_P.amount,2),0)+
   ISNULL(ROUND(ISNULL(T.IMPORTETAR,0)-ISNULL(T.Extraccion,0),2),0)+
   ISNULL(ROUND(SH_P.TotalAmount,2),0)+ISNULL(ROUND(PU_P.TotalTransaction,2),0)
 )),2) END AS Efectivo,
 M.TOTAL,
 ISNULL(CAST(M.Vendedor AS VARCHAR(8)),'0')+' - '+ISNULL(MV.RAZONSOC,'SIN VENDEDOR') AS Vendedor
FROM Maefac M
LEFT JOIN MP_OrdenPagoComprobante MP_C ON M.LETRA=MP_C.Letra AND M.SUCURSAL=MP_C.Sucursal AND M.NCOMPRO=MP_C.Numero
LEFT JOIN MP_OrdenPago MP_O ON MP_C.ID_OrdenPago=MP_O.ID
LEFT JOIN YPF_PaymentIntentionComprobante ypf_C ON M.LETRA=ypf_C.Letra AND M.SUCURSAL=ypf_C.Sucursal AND M.NCOMPRO=ypf_C.Numero
LEFT JOIN YPF_PaymentIntention ypf_P ON ypf_P.ID=ypf_C.ID_PaymentIntention
LEFT JOIN Tarjet T ON M.LETRA=T.Letra AND M.SUCURSAL=T.Sucursal AND M.NCOMPRO=T.NFACT
LEFT JOIN Shell_PayOrderComprobante SH_C ON M.LETRA=SH_C.Letra AND M.SUCURSAL=SH_C.Sucursal AND M.NCOMPRO=SH_C.Numero
LEFT JOIN Shell_PayOrder SH_P ON SH_C.PayOrderId=SH_P.ID
LEFT JOIN PUMA_PaymentComprobante PU_C ON M.LETRA=PU_C.Letra AND M.SUCURSAL=PU_C.Sucursal AND M.NCOMPRO=PU_C.Numero
LEFT JOIN PUMA_Payment PU_P ON PU_C.PaymentId=PU_P.ID
LEFT JOIN Clover_PaymentInvoices C_PI ON M.SUCURSAL=C_PI.Pos AND M.NCOMPRO=C_PI.InvoiceNumber AND C_PI.Letter=M.LETRA
LEFT JOIN Clover_Payments C_P ON C_P.Id=C_PI.CloverPaymentId
LEFT JOIN Maeven MV ON MV.VENDEDOR=M.VENDEDOR
WHERE M.LETRA=@Letra AND M.SUCURSAL=@Sucursal AND M.NCOMPRO=@Numero;
"@
            $null=$payCmd.Parameters.Add("@Letra",[System.Data.SqlDbType]::VarChar,10)
            $payCmd.Parameters["@Letra"].Value=$letra
          }

          $null=$payCmd.Parameters.Add("@Sucursal",[System.Data.SqlDbType]::VarChar,30)
          $payCmd.Parameters["@Sucursal"].Value=$sucursal
          $null=$payCmd.Parameters.Add("@Numero",[System.Data.SqlDbType]::VarChar,50)
          $payCmd.Parameters["@Numero"].Value=$numero

          $pr=$payCmd.ExecuteReader()
          if(-not $pr.Read()){
            $pr.Close()
            Send-Json $stream 200 @{resolved=$false;reason='La relacion existe, pero no encontre el comprobante en Maefac/Maetic.';columns=$relationColumns;relation=$rel}
            continue
          }
          $payment=@{}
          for($i=0;$i -lt $pr.FieldCount;$i++){
            $name=[string]$pr.GetName($i)
            $val=$pr.GetValue($i)
            if($val -is [DBNull]){$val=0}
            $payment[$name]=$val
          }
          $pr.Close()
          Send-Json $stream 200 @{
            resolved=$true
            dispatchColumn=$dispatchCol
            relation=$rel
            comprobante=@{letra=$letra;sucursal=$sucursal;numero=$numero;tipo=$tipo}
            payment=$payment
          }
        } catch {
          Send-Json $stream 500 @{error=$_.Exception.Message}
        }
      }
      elseif($req.Method -eq 'POST' -and $pathOnly -eq '/api/dispatches'){
        try {
          $data = $req.Body | ConvertFrom-Json
          $sid = [string]$data.sessionId
          $database = [string]$data.database
          if(-not $Sessions.ContainsKey($sid)){ Send-Json $stream 401 @{error='Sesion vencida. Volver a conectar.'}; continue }
          $sess = $Sessions[$sid]
          if($sess.databases -notcontains $database){ Send-Json $stream 403 @{error='Base no autorizada.'}; continue }

          $cn = $sess.connection
          $cn.ChangeDatabase($database)
          $cmd = $cn.CreateCommand()
          $cmd.CommandText = "SELECT id_sale venta, surtidor, manguera, d.codart, p.descriimpresion, Litros, PPU, pesos, d.Ultime fecha, Ultime as hora FROM Despachos d INNER JOIN prod p ON d.codart = p.codart;"
          $reader = $cmd.ExecuteReader()

          $cols = @()
          for($i=0; $i -lt $reader.FieldCount; $i++){ $cols += [string]$reader.GetName($i) }
          $rows = @()
          while($reader.Read()){
            $row = [ordered]@{}
            for($i=0; $i -lt $reader.FieldCount; $i++){
              $v = $reader.GetValue($i)
              if($v -is [System.DBNull]){ $v = $null }
              elseif($v -is [DateTime]){ $v = $v.ToString("yyyy-MM-dd HH:mm:ss") }
              elseif($v -is [byte[]]){ $v = "[binario]" }
              $row[$cols[$i]] = $v
            }
            $rows += [pscustomobject]$row
          }
          $reader.Close()
          Send-Json $stream 200 @{database=$database;columns=$cols;rows=$rows}
        } catch {
          Send-Json $stream 500 @{error=$_.Exception.Message}
        }
      }
      else {
        Send-Json $stream 404 @{error='Ruta no encontrada'}
      }
    } catch {
      try { Send-Json $stream 500 @{error=$_.Exception.Message} } catch {}
    } finally {
      try { $client.Close() } catch {}
    }
  }
}
finally {
  foreach($k in @($Sessions.Keys)){ try { $Sessions[$k].connection.Dispose() } catch {} }
  $listener.Stop()
}
 + $instance }
              $status = 'unknown'
              try { $status = [string](Get-Service -Name $serviceName -ErrorAction Stop).Status } catch {}
              $serverName = $env:COMPUTERNAME
              if($instance -ne 'MSSQLSERVER'){ $serverName = $env:COMPUTERNAME + '\' + $instance }
              $exists = $false
              foreach($x in $instances){ if([string]$x.server -eq $serverName){ $exists=$true } }
              if(-not $exists){ $instances += [pscustomobject]@{instance=$instance;server=$serverName;service=$serviceName;status=$status} }
            }
          } catch {}
        }
        Send-Json $stream 200 @{machine=$env:COMPUTERNAME;instances=$instances}
      }
      elseif($req.Method -eq 'GET' -and $pathOnly -eq '/api/profile-status'){
        $p = Load-SqlProfile
        if($null -eq $p){
          Send-Json $stream 200 @{saved=$false;server='';auth='sql';user='';database='';hasPassword=$false}
        } else {
          Send-Json $stream 200 @{
            saved=$true
            server=[string]$p.server
            auth=[string]$p.auth
            user=[string]$p.user
            database=[string]$p.database
            hasPassword=(-not [string]::IsNullOrWhiteSpace([string]$p.passwordProtected))
          }
        }
      }
      elseif($req.Method -eq 'POST' -and $pathOnly -eq '/api/reconnect-saved'){
        try {
          $p = Load-SqlProfile
          if($null -eq $p){ throw 'No hay una conexión SQL guardada en este equipo.' }
          $savedPassword = Unprotect-ProfilePassword -Profile $p
          $state = Open-SqlSession -Server ([string]$p.server) -Auth ([string]$p.auth) -User ([string]$p.user) -Password $savedPassword
          $savedDb = [string]$p.database
          if(-not [string]::IsNullOrWhiteSpace($savedDb) -and $state.databases -contains $savedDb){
            $Sessions[$state.sessionId]["database"] = $savedDb
          }
          $script:LastRestoreError = ''
          Write-ServiceStatus -State 'running-connected' -Database $savedDb -Server ([string]$p.server) -User ([string]$p.user)
          Send-Json $stream 200 @{sessionId=$state.sessionId;server=$state.server;auth=$state.auth;user=$state.user;databases=$state.databases;database=$savedDb;restored=$true}
        } catch {
          $script:LastRestoreError = $_.Exception.Message
          Write-ServiceStatus -State 'running-no-sql' -ErrorMessage $script:LastRestoreError
          Send-Json $stream 500 @{error=$_.Exception.Message}
        }
      }
      elseif($req.Method -eq 'GET' -and $pathOnly -eq '/api/openai/status'){
        Send-Json $stream 200 @{configured=(-not [string]::IsNullOrWhiteSpace((Get-OpenAIKey)));defaultEngine='openai';model='gpt-realtime-2.1'}
      }
      elseif($req.Method -eq 'POST' -and $pathOnly -eq '/api/openai/config'){
        try {$data=$req.Body|ConvertFrom-Json;Save-OpenAIKey -ApiKey ([string]$data.apiKey);Send-Json $stream 200 @{ok=$true;configured=$true;defaultEngine='openai'}} catch {Send-Json $stream 400 @{error=$_.Exception.Message}}
      }
      elseif($req.Method -eq 'POST' -and $pathOnly -eq '/api/openai/realtime-secret'){
        try {$key=Get-OpenAIKey;if([string]::IsNullOrWhiteSpace($key)){throw 'Configurá la clave de OpenAI en Núcleo → Inteligencia.'};Send-Json $stream 200 (New-OpenAIRealtimeSecret -ApiKey $key)} catch {Send-Json $stream 500 @{error=$_.Exception.Message}}
      }
      elseif($req.Method -eq 'POST' -and $pathOnly -eq '/api/ai/sql-read'){
        try {$data=$req.Body|ConvertFrom-Json;Send-Json $stream 200 (Invoke-ReadOnlySql -SessionId ([string]$data.sessionId) -Database ([string]$data.database) -Sql ([string]$data.sql))} catch {Send-Json $stream 400 @{error=$_.Exception.Message}}
      }
      elseif($req.Method -eq 'GET' -and $pathOnly -eq '/api/station-summary'){
        try {
          $state = Ensure-ActiveSession
          if($null -eq $state -or [string]::IsNullOrWhiteSpace([string]$state.database)){
            Send-Json $stream 200 @{
              connected=$false
              bridge=$true
              serviceMode='background'
              scheduledTask=$TaskName
              statusFile=$ServiceStatusPath
              profileSaved=(Test-Path $ProfilePath)
              restoreError=[string]$script:LastRestoreError
            }
            continue
          }
          $cn = $Sessions[$state.sessionId].connection
          $cn.ChangeDatabase([string]$state.database)

          $q = $cn.CreateCommand()
          $q.CommandText = "IF OBJECT_ID('dbo.Tanque') IS NULL SELECT 0 ELSE SELECT COUNT(*) FROM dbo.Tanque"
          $tankCount = [int]$q.ExecuteScalar()

          $q = $cn.CreateCommand()
          $q.CommandText = "IF OBJECT_ID('dbo.Surtan') IS NULL SELECT 0 ELSE SELECT COUNT(*) FROM dbo.Surtan"
          $hoseCount = [int]$q.ExecuteScalar()

          $q = $cn.CreateCommand()
          $q.CommandText = "IF OBJECT_ID('dbo.Surtan') IS NULL OR COL_LENGTH('dbo.Surtan','SURTIDOR') IS NULL SELECT 0 ELSE EXEC('SELECT COUNT(DISTINCT SURTIDOR) FROM dbo.Surtan WHERE SURTIDOR IS NOT NULL')"
          $pumpCount = [int]$q.ExecuteScalar()

          $q = $cn.CreateCommand()
          $q.CommandText = "IF OBJECT_ID('dbo.Despachos') IS NULL SELECT 0 AS cantidad,CAST(0 AS decimal(18,2)) AS litros,CAST(0 AS decimal(18,2)) AS pesos ELSE SELECT COUNT(*) cantidad,ISNULL(SUM(CAST(Litros AS decimal(18,2))),0) litros,ISNULL(SUM(CAST(pesos AS decimal(18,2))),0) pesos FROM dbo.Despachos"
          $rdr = $q.ExecuteReader()
          $dispatchCount = 0; $liters = 0; $pesos = 0
          if($rdr.Read()){
            $dispatchCount = [int]$rdr["cantidad"]
            $liters = [decimal]$rdr["litros"]
            $pesos = [decimal]$rdr["pesos"]
          }
          $rdr.Close()

          Send-Json $stream 200 @{
            connected=$true
            bridge=$true
            serviceMode='background'
            scheduledTask=$TaskName
            statusFile=$ServiceStatusPath
            database=[string]$state.database
            server=[string]$state.server
            tankCount=$tankCount
            hoseCount=$hoseCount
            pumpCount=$pumpCount
            dispatchCount=$dispatchCount
            liters=$liters
            pesos=$pesos
          }
        } catch {
          Send-Json $stream 500 @{error=$_.Exception.Message}
        }
      }
      elseif($req.Method -eq 'GET' -and $pathOnly -eq '/api/tanks'){
        try {
          $state = Ensure-ActiveSession
          if($null -eq $state -or [string]::IsNullOrWhiteSpace([string]$state.database)){
            Send-Json $stream 200 @{connected=$false}
            continue
          }

          $cn = $Sessions[$state.sessionId].connection
          $cn.ChangeDatabase([string]$state.database)

          $existsCmd = $cn.CreateCommand()
          $existsCmd.CommandText = "SELECT CASE WHEN OBJECT_ID('dbo.Tanque','U') IS NULL THEN 0 ELSE 1 END"
          $tableExists = ([int]$existsCmd.ExecuteScalar() -eq 1)
          if(-not $tableExists){
            Send-Json $stream 200 @{connected=$true;database=[string]$state.database;table='dbo.Tanque';tableExists=$false;columns=@();rowCount=0;rows=@()}
            continue
          }

          $q = $cn.CreateCommand()
          $q.CommandText = "SELECT TOP (200) * FROM dbo.Tanque"
          $q.CommandTimeout = 15
          $rdr = $q.ExecuteReader()
          try {
            $columns = New-Object System.Collections.Generic.List[string]
            for($i=0;$i -lt $rdr.FieldCount;$i++){ $columns.Add($rdr.GetName($i)) }

            $rows = New-Object System.Collections.Generic.List[object]
            while($rdr.Read()){
              $row = [ordered]@{}
              for($i=0;$i -lt $rdr.FieldCount;$i++){
                $value = $rdr.GetValue($i)
                if($value -is [DBNull]){ $value = $null }
                $row[$rdr.GetName($i)] = $value
              }
              $rows.Add([pscustomobject]$row)
            }

            Send-Json $stream 200 @{
              connected=$true
              database=[string]$state.database
              table='dbo.Tanque'
              tableExists=$true
              columns=$columns
              rowCount=$rows.Count
              rows=$rows
            }
          } finally {
            $rdr.Close()
          }
        } catch {
          Send-Json $stream 500 @{error=$_.Exception.Message}
        }
      }
      elseif($req.Method -eq 'GET' -and $pathOnly -eq '/api/state'){
        $state = Ensure-ActiveSession
        if($null -eq $state){
          Send-Json $stream 200 @{connected=$false}
        } else {
          Send-Json $stream 200 @{connected=$true;sessionId=$state.sessionId;server=$state.server;auth=$state.auth;user=$state.user;databases=$state.databases;database=$state.database}
        }
      }
      elseif($req.Method -eq 'GET' -and ($pathOnly -eq '/' -or $pathOnly -eq '/index.html')){
        Send-Response $stream 200 "text/html; charset=utf-8" (Get-HomeHtml)
      }
      elseif($req.Method -eq 'GET' -and $pathOnly -eq '/mapa-vivo'){
        try {
          $query = [System.Web.HttpUtility]::ParseQueryString(([uri]("http://127.0.0.1" + $req.Path)).Query)
          $sid = [string]$query['sessionId']
          $database = [string]$query['database']
          if(-not $Sessions.ContainsKey($sid)){ throw "Sesion SQL no valida." }
          $sess = $Sessions[$sid]
          if($sess.databases -notcontains $database){ throw "Base no autorizada." }

          $cn = $sess.connection
          $cn.ChangeDatabase($database)

          $dispatchIdColumn = $null
          $idMetaCmd = $cn.CreateCommand()
          $idMetaCmd.CommandText = @"
SELECT TOP 1 c.name
FROM sys.columns c
WHERE c.object_id = OBJECT_ID('dbo.Despachos')
  AND (
    LOWER(REPLACE(c.name,'_','')) IN ('iddespacho','iddespcho')
    OR LOWER(c.name) LIKE '%id%desp%'
    OR LOWER(c.name) LIKE '%desp%id%'
  )
ORDER BY CASE WHEN LOWER(REPLACE(c.name,'_',''))='iddespacho' THEN 0
              WHEN LOWER(REPLACE(c.name,'_',''))='iddespcho' THEN 1
              ELSE 2 END, c.column_id;
"@
          $dispatchIdValue = $idMetaCmd.ExecuteScalar()
          if($null -ne $dispatchIdValue -and $dispatchIdValue -isnot [DBNull]){
            $dispatchIdColumn = [string]$dispatchIdValue
          }

          $dispatchIdSelect = "NULL AS id_despacho"
          if(-not [string]::IsNullOrWhiteSpace($dispatchIdColumn)){
            $dispatchIdSelect = "d.[" + $dispatchIdColumn.Replace("]","]]") + "] AS id_despacho"
          }

          $cmd = $cn.CreateCommand()
          $cmd.CommandText = "SELECT " + $dispatchIdSelect + ", id_sale venta, surtidor, manguera, d.codart, p.descriimpresion, Litros, PPU, pesos, d.Ultime fecha, Ultime as hora FROM Despachos d INNER JOIN prod p ON d.codart = p.codart;"
          $reader = $cmd.ExecuteReader()
          $dispatchRows = New-Object System.Collections.Generic.List[object]
          while($reader.Read()){
            $dispatchRows.Add([pscustomobject]@{
              id_despacho = if($reader["id_despacho"] -is [DBNull]){""}else{[string]$reader["id_despacho"]}
              venta = if($reader["venta"] -is [DBNull]){""}else{[string]$reader["venta"]}
              surtidor = if($reader["surtidor"] -is [DBNull]){""}else{[string]$reader["surtidor"]}
              manguera = if($reader["manguera"] -is [DBNull]){""}else{[string]$reader["manguera"]}
              codart = if($reader["codart"] -is [DBNull]){""}else{[string]$reader["codart"]}
              producto = if($reader["descriimpresion"] -is [DBNull]){""}else{[string]$reader["descriimpresion"]}
              litros = if($reader["Litros"] -is [DBNull]){""}else{[string]$reader["Litros"]}
              ppu = if($reader["PPU"] -is [DBNull]){""}else{[string]$reader["PPU"]}
              pesos = if($reader["pesos"] -is [DBNull]){""}else{[string]$reader["pesos"]}
              fecha = if($reader["fecha"] -is [DBNull]){""}elseif($reader["fecha"] -is [DateTime]){([DateTime]$reader["fecha"]).ToString("dd/MM/yyyy HH:mm:ss")}else{[string]$reader["fecha"]}
              hora = if($reader["hora"] -is [DBNull]){""}elseif($reader["hora"] -is [DateTime]){([DateTime]$reader["hora"]).ToString("HH:mm:ss")}else{[string]$reader["hora"]}
            })
          }
          $reader.Close()

          $tankCmd = $cn.CreateCommand()
          $tankCmd.CommandText = "SELECT t.N_TANQUE, t.DENOMINACION, p.DESCRIIMPRESION, t.CAPACIDAD FROM Tanque t INNER JOIN prod p ON t.CODART = p.codart;"
          $tankReader = $tankCmd.ExecuteReader()
          $tankRows = New-Object System.Collections.Generic.List[object]
          while($tankReader.Read()){
            $tankRows.Add([pscustomobject]@{
              numero = if($tankReader["N_TANQUE"] -is [DBNull]){""}else{[string]$tankReader["N_TANQUE"]}
              denominacion = if($tankReader["DENOMINACION"] -is [DBNull]){""}else{[string]$tankReader["DENOMINACION"]}
              producto = if($tankReader["DESCRIIMPRESION"] -is [DBNull]){""}else{[string]$tankReader["DESCRIIMPRESION"]}
              capacidad = if($tankReader["CAPACIDAD"] -is [DBNull]){""}else{[string]$tankReader["CAPACIDAD"]}
            })
          }
          $tankReader.Close()
          $tankCount = $tankRows.Count

          $hoseSurtidorSelect = "NULL"
          $hoseMetaCmd = $cn.CreateCommand()
          $hoseMetaCmd.CommandText = "SELECT COUNT(*) FROM sys.columns WHERE object_id=OBJECT_ID('dbo.Surtan') AND UPPER(name)='SURTIDOR';"
          if(([int]$hoseMetaCmd.ExecuteScalar()) -gt 0){ $hoseSurtidorSelect = "s.SURTIDOR" }
          $hoseCmd = $cn.CreateCommand()
          $hoseCmd.CommandText = "SELECT s.N_TANQUE, t.DENOMINACION, " + $hoseSurtidorSelect + " AS SURTIDOR, s.MANGUERA, p.DESCRIIMPRESION FROM Surtan s INNER JOIN Tanque t ON s.N_TANQUE = t.N_TANQUE INNER JOIN prod p ON s.CODART = p.Codart;"
          $hoseReader = $hoseCmd.ExecuteReader()
          $hoseRows = New-Object System.Collections.Generic.List[object]
          while($hoseReader.Read()){
            $hoseRows.Add([pscustomobject]@{
              tanque = if($hoseReader["N_TANQUE"] -is [DBNull]){""}else{[string]$hoseReader["N_TANQUE"]}
              denominacion = if($hoseReader["DENOMINACION"] -is [DBNull]){""}else{[string]$hoseReader["DENOMINACION"]}
              surtidor = if($hoseReader["SURTIDOR"] -is [DBNull]){""}else{[string]$hoseReader["SURTIDOR"]}
              manguera = if($hoseReader["MANGUERA"] -is [DBNull]){""}else{[string]$hoseReader["MANGUERA"]}
              producto = if($hoseReader["DESCRIIMPRESION"] -is [DBNull]){""}else{[string]$hoseReader["DESCRIIMPRESION"]}
            })
          }
          $hoseReader.Close()
          $hoseCount = $hoseRows.Count

          $realSurtidores = @($hoseRows | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.surtidor) } | ForEach-Object { [string]$_.surtidor } | Sort-Object -Unique)
          $surtidorCountText = if($realSurtidores.Count -gt 0){ [string]$realSurtidores.Count } else { "?" }

          $hoseCards = ""
          foreach($h in $hoseRows){
            $ht = [System.Net.WebUtility]::HtmlEncode([string]$h.tanque)
            $hd = [System.Net.WebUtility]::HtmlEncode([string]$h.denominacion)
            $hs = [System.Net.WebUtility]::HtmlEncode([string]$h.surtidor)
            $hm = [System.Net.WebUtility]::HtmlEncode([string]$h.manguera)
            $hp = [System.Net.WebUtility]::HtmlEncode([string]$h.producto)
            $surtidorLabel = if([string]::IsNullOrWhiteSpace($hs)){ "S?" } else { "S$hs" }
            $hoseCards += "<div class='hoseRow'><b>T$ht</b><span class='arrow'>&rarr;</span><strong>$surtidorLabel</strong><span class='arrow'>&rarr;</span><strong>M$hm</strong><span class='hoseProduct'>$hp</span><small>$hd</small></div>"
          }
          if([string]::IsNullOrWhiteSpace($hoseCards)){
            $hoseCards = "<div class='empty'>Sin relaciones Tanque → Surtidor → Manguera para mostrar.</div>"
          }

          $tankCards = ""
          foreach($t in $tankRows){
            $tn = [System.Net.WebUtility]::HtmlEncode([string]$t.numero)
            $td = [System.Net.WebUtility]::HtmlEncode([string]$t.denominacion)
            $tp = [System.Net.WebUtility]::HtmlEncode([string]$t.producto)
            $tc = [System.Net.WebUtility]::HtmlEncode([string]$t.capacidad)
            $tankHoses = @($hoseRows | Where-Object { [string]$_.tanque -eq [string]$t.numero })
            $tankHoseText = ""
            foreach($th in $tankHoses){
              if($tankHoseText){ $tankHoseText += " | " }
              $tankHoseText += "S$([System.Net.WebUtility]::HtmlEncode([string]$th.surtidor)) / M$([System.Net.WebUtility]::HtmlEncode([string]$th.manguera)) - $([System.Net.WebUtility]::HtmlEncode([string]$th.producto))"
            }
            if(-not $tankHoseText){ $tankHoseText = "Sin mangueras asociadas" }
            $tankCards += "<button type='button' class='tankRow tankPick' data-num='$tn' data-den='$td' data-prod='$tp' data-cap='$tc' data-hoses='$tankHoseText'><b>T$tn</b><span class='tankName'>$td</span><span class='tankProduct'>$tp</span><strong>$tc L</strong></button>"
          }
          if([string]::IsNullOrWhiteSpace($tankCards)){
            $tankCards = "<div class='empty'>Sin tanques para mostrar.</div>"
          }

          $safeDb = [System.Net.WebUtility]::HtmlEncode($database)
          $cards = ""
          foreach($d in $dispatchRows){
            $idDespacho = [System.Net.WebUtility]::HtmlEncode([string]$d.id_despacho)
            $venta = [System.Net.WebUtility]::HtmlEncode([string]$d.venta)
            $surt = [System.Net.WebUtility]::HtmlEncode([string]$d.surtidor)
            $mang = [System.Net.WebUtility]::HtmlEncode([string]$d.manguera)
            $prod = [System.Net.WebUtility]::HtmlEncode([string]$d.producto)
            $lit = [System.Net.WebUtility]::HtmlEncode([string]$d.litros)
            $ppu = [System.Net.WebUtility]::HtmlEncode([string]$d.ppu)
            $pes = [System.Net.WebUtility]::HtmlEncode([string]$d.pesos)
            $hora = [System.Net.WebUtility]::HtmlEncode([string]$d.hora)
            $cards += "<button type='button' class='dispatchRow salePick' data-id-despacho='$idDespacho' data-venta='$venta' data-surtidor='$surt' data-manguera='$mang' data-producto='$prod' data-litros='$lit' data-ppu='$ppu' data-pesos='$pes' data-hora='$hora'><b>#$venta</b><span>Surt. $surt - Mang. $mang</span><span class='product'>$prod</span><span>$lit L - PPU $ppu - <strong>&#36;$pes</strong></span><small>$hora</small></button>"
          }
          if([string]::IsNullOrWhiteSpace($cards)){
            $cards = "<div class='empty'>Sin despachos para mostrar.</div>"
          }
          $dispatchCount = $dispatchRows.Count

          $html = @"
<!doctype html>
<html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Mapa Vivo - Capitan Rodolfo</title>
<style>
:root{--bg:#050b12;--panel:#09141e;--line:#254154;--orange:#ff7138;--cyan:#2dd9ff;--green:#34f5a5;--text:#eaf6ff;--muted:#7ea2bb}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font-family:Segoe UI,Arial,sans-serif}
.top{display:flex;justify-content:space-between;align-items:center;gap:12px;padding:12px 18px;background:#07111a;border-bottom:1px solid var(--line);position:sticky;top:0;z-index:5}
.left{display:flex;align-items:center;gap:12px;flex-wrap:wrap}.badge{background:#11212c;border:1px solid #2b5267;border-radius:999px;padding:7px 11px;font-size:12px}.ok{color:var(--green)}.ver{color:#061116;background:var(--orange);border-radius:999px;padding:6px 9px;font-size:12px;font-weight:900}.navlink{color:#ccefff;text-decoration:none;border:1px solid #2b5267;border-radius:999px;padding:7px 11px;font-size:12px;font-weight:800}.navlink:hover{border-color:#2dd9ff;color:#fff}
.stage{padding:14px}.mapWrap{position:relative;max-width:1600px;margin:auto}.mapWrap>img{display:block;width:100%;height:auto;border:1px solid #173244;border-radius:18px;background:#050b12}
.dispatchOverlay{position:absolute;left:64.4%;top:60.4%;width:31.3%;height:18.5%;background:#07131df7;border:2px solid #2dd9ff;border-radius:18px;padding:12px 14px;overflow:hidden;box-shadow:0 8px 24px #0009}
.dispatchTitle{display:flex;justify-content:space-between;gap:10px;align-items:center;margin-bottom:8px;font-size:12px;letter-spacing:2px;color:#89a9bd}.dispatchTitle strong{color:#eaf6ff;letter-spacing:0}
.dispatchList{height:calc(100% - 28px);overflow:auto;padding-right:5px}.dispatchRow{display:grid;width:100%;grid-template-columns:auto auto 1fr auto auto;gap:8px;align-items:center;border:0;border-bottom:1px solid #173244;padding:6px 0;font-size:11px;white-space:nowrap;background:transparent;color:#eaf6ff;text-align:left;cursor:pointer}.dispatchRow:hover,.dispatchRow.active{background:#0d2633}.dispatchRow b{color:#34f5a5}.dispatchRow .product{overflow:hidden;text-overflow:ellipsis}.dispatchRow strong{color:#ffb06a}.dispatchRow small{color:#7ea2bb}.empty{color:#7ea2bb;padding:14px 0}
.tankOverlay{position:absolute;left:26.3%;top:31%;width:19.5%;max-height:31%;background:#09141ef2;border:2px solid #ff7138;border-radius:16px;padding:10px 12px;overflow:hidden;box-shadow:0 8px 24px #0009}
.tankTitle{display:flex;justify-content:space-between;align-items:center;gap:8px;margin-bottom:7px;font-size:11px;letter-spacing:2px;color:#89a9bd}.tankTitle strong{color:#eaf6ff;letter-spacing:0}
.tankList{max-height:210px;overflow:auto;padding-right:4px}.tankRow{display:grid;width:100%;grid-template-columns:auto 1fr auto;gap:6px;align-items:center;border:0;border-bottom:1px solid #173244;padding:5px 0;font-size:10px;background:transparent;color:#eaf6ff;text-align:left;cursor:pointer}.tankRow:hover,.tankRow.active{background:#2a1710}.tankRow b{color:#ff9d2e}.tankName{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.tankProduct{grid-column:1/-1;color:#7ea2bb;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.tankRow strong{color:#2dd9ff}
.hoseOverlay{position:absolute;left:46%;top:26%;width:17%;max-height:28%;background:#07131df2;border:2px solid #34f5a5;border-radius:16px;padding:10px 12px;overflow:hidden;box-shadow:0 8px 24px #0009}
.hoseTitle{display:flex;justify-content:space-between;align-items:center;gap:8px;margin-bottom:7px;font-size:10px;letter-spacing:1.5px;color:#89a9bd}.hoseTitle strong{color:#eaf6ff;letter-spacing:0}
.hoseList{max-height:180px;overflow:auto;padding-right:4px}.hoseRow{display:grid;grid-template-columns:auto auto auto auto auto 1fr;gap:5px;align-items:center;border-bottom:1px solid #173244;padding:5px 0;font-size:10px}.hoseRow b{color:#ff9d2e}.hoseRow strong{color:#34f5a5}.hoseRow .arrow{color:#2dd9ff}.hoseProduct{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.hoseRow small{grid-column:1/-1;color:#7ea2bb;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.tankHotspot{position:absolute;left:26.2%;top:23.8%;width:18.8%;height:6.5%;border:1px dashed #ff7138;background:#ff713812;color:#ffb06a;border-radius:10px;cursor:pointer;font-weight:900;letter-spacing:2px;z-index:3}
.hoseHotspot{position:absolute;left:46%;top:18%;width:17%;height:6.5%;border:1px dashed #34f5a5;background:#34f5a512;color:#8fffd0;border-radius:10px;cursor:pointer;font-weight:900;letter-spacing:1.4px;z-index:3}
.dispatchHotspot{position:absolute;left:70%;top:55%;width:22%;height:5.5%;border:1px dashed #2dd9ff;background:#2dd9ff12;color:#8fefff;border-radius:10px;cursor:pointer;font-weight:900;letter-spacing:1.2px;z-index:3}
.parentClose{border:0;background:transparent;color:#fff;cursor:pointer;font-size:15px;font-weight:900;padding:0 3px;margin:0;width:auto}
.detailCard{position:absolute;z-index:6;background:#07131df7;border:2px solid #ff7138;border-radius:16px;padding:12px 14px;box-shadow:0 10px 30px #000b;display:none}.detailCard.show{display:block}
#tankDetail{left:27%;top:64%;width:30%}#saleOnPump{left:50.3%;top:30%;width:20%;border-color:#34f5a5}
.detailTitle{font-size:11px;letter-spacing:1.5px;color:#89a9bd;margin-bottom:8px}.detailGrid{display:grid;grid-template-columns:auto 1fr;gap:6px 10px;font-size:12px}.detailGrid b{color:#fff}.detailGrid span{color:#8fb3c9}.detailClose{position:absolute;right:8px;top:7px;border:0;background:transparent;color:#fff;cursor:pointer;font-size:16px}
.paymentBtn{width:100%;margin-top:12px;border:0;border-radius:10px;padding:10px 12px;background:linear-gradient(135deg,#ff7138,#ff9d2e);color:#101010;font-weight:900;cursor:pointer}
#paymentPanel{left:50.3%;top:54%;width:20%;border-color:#ff7138}
.paymentPending{color:#ffb06a;font-size:12px;line-height:1.5}
.pumpCountBadge{position:absolute;left:48.7%;top:19.2%;z-index:4;background:#07131de8;border:1px solid #2dd9ff;color:#b9efff;border-radius:999px;padding:7px 11px;font-size:11px;font-weight:900;letter-spacing:1px}.pumpCountBadge strong{color:#fff}
.truckHotspot{position:absolute;left:3.5%;top:34%;width:23%;height:31%;z-index:4;border:1px solid transparent;background:transparent;border-radius:18px;cursor:pointer;color:transparent}.truckHotspot:hover{border-color:#ff7138;background:#ff71380c;box-shadow:0 0 26px #ff713833}.truckHotspot.feed{animation:truckFeedPulse .75s ease}
@keyframes truckFeedPulse{0%,100%{box-shadow:none}45%{box-shadow:0 0 0 10px #ff713822,0 0 38px #ff713888}}
.receiptModal{position:fixed;inset:0;z-index:60;display:none;place-items:center;background:#000b;padding:18px}.receiptModal.show{display:grid}
.receiptBox{width:min(650px,94vw);max-height:90vh;overflow:auto;background:#101820;border:1px solid #2d4759;border-radius:20px;padding:22px;box-shadow:0 30px 80px #000c;position:relative}.receiptBox h2{margin:0 0 8px}.receiptBox p{color:#8fb3c9;line-height:1.5}
.receiptClose{position:absolute;right:12px;top:10px;width:auto;margin:0;border:0;background:transparent;color:#fff;font-size:22px;cursor:pointer}
.receiptUpload{display:block;border:1px dashed #ff7138;background:#ff71380d;border-radius:14px;padding:18px;text-align:center;font-weight:900;cursor:pointer}.receiptUpload input{display:none}
.receiptStatus{margin-top:12px;border:1px solid #29495e;border-radius:11px;padding:10px;color:#a8c6d8;font-size:12px}.receiptStatus.ok{border-color:#247450;color:#8df0b8}.receiptStatus.bad{border-color:#7c3131;color:#ffb2b2}
.receiptPreview{margin-top:12px;border:1px solid #29495e;border-radius:12px;padding:10px;display:none}.receiptPreview.show{display:block}.receiptPreview img{max-width:100%;max-height:260px;display:block;margin:auto;border-radius:8px}.receiptPreview .pdf{padding:18px;text-align:center;color:#ffb06a;font-weight:900}
.revalLogin{display:none;margin-top:14px;padding:14px;border:1px solid #67482c;border-radius:12px;background:#1b1510}.revalLogin.show{display:block}.revalLogin input{width:100%;margin-top:7px;padding:11px;border-radius:9px;border:1px solid #3b4650;background:#091018;color:#fff}.revalLogin button{width:100%;margin-top:10px;padding:11px;border:0;border-radius:9px;background:#ff7138;font-weight:900;cursor:pointer}
.receiptResult{display:none;margin-top:14px}.receiptResult.show{display:block}
.invoice-paper{background:#fff;color:#1c2330;border-radius:14px;overflow:hidden;box-shadow:0 16px 50px #0008;border:1px solid #dfe5ea;font-family:Segoe UI,Arial,sans-serif}
.invoice-head{display:flex;justify-content:space-between;gap:16px;padding:18px 20px;border-bottom:1px solid #e4e8ec;background:linear-gradient(135deg,#fbfcfd,#f1f5f7)}
.invoice-head span{font-size:10px;letter-spacing:1.6px;color:#718092;font-weight:900}.invoice-head h3{margin:5px 0 3px;color:#17202b;font-size:19px}.invoice-head p{margin:0;color:#667483;font-size:11px}
.invoice-type{text-align:right}.invoice-type b{display:block;color:#ff5a3d;font-size:16px}.invoice-type small{display:block;margin-top:5px;color:#667483}
.invoice-meta{display:grid;grid-template-columns:repeat(3,1fr);gap:1px;background:#e6eaee}.invoice-meta>div{background:#fff;padding:11px 14px}.invoice-meta span,.invoice-footer span,.document-flow span{display:block;color:#788797;font-size:9px;text-transform:uppercase;letter-spacing:1px}.invoice-meta b{display:block;margin-top:3px;font-size:12px}
.document-flow{display:grid;grid-template-columns:1fr auto 1fr;gap:10px;align-items:center;padding:14px 18px;border-bottom:1px solid #e5e9ed}.document-flow b{display:block;margin:4px 0;font-size:12px}.document-flow small{display:block;color:#778491;font-size:10px}.flow-arrow{font-size:22px;color:#ff5a3d;font-weight:900}
.invoice-lines{padding:14px 18px}.invoice-line{display:grid;grid-template-columns:1fr 70px 95px 95px;gap:8px;padding:7px 0;border-bottom:1px solid #edf0f2;font-size:10px}.invoice-line-head{font-weight:900;color:#718092;text-transform:uppercase;letter-spacing:.7px}.invoice-line span:not(:first-child){text-align:right}
.invoice-totals{padding:10px 18px 14px;margin-left:auto;width:min(360px,100%)}.invoice-totals>div{display:flex;justify-content:space-between;gap:16px;padding:5px 0;color:#566473;font-size:11px}.invoice-grand{margin-top:5px;padding-top:10px!important;border-top:2px solid #1d2630;color:#111!important;font-size:15px!important}.invoice-grand b{color:#ff5a3d;font-size:18px}
.invoice-footer{display:grid;grid-template-columns:1fr 1fr;gap:12px;padding:12px 18px;background:#f5f7f8;border-top:1px solid #e5e9ed}.invoice-footer b{display:block;color:#273443;margin-top:3px;font-size:10px}
.invoice-empty{padding:16px;color:#667483;text-align:center;font-size:11px}
@media(max-width:650px){.invoice-line{grid-template-columns:1fr 48px 70px 75px;font-size:9px}.invoice-head{padding:14px}.invoice-meta{grid-template-columns:1fr}.invoice-footer{grid-template-columns:1fr}}
.receiptFly{position:fixed;z-index:90;width:180px;padding:10px;border:2px solid #ff7138;border-radius:12px;background:#fff;color:#111;font-weight:900;font-size:11px;box-shadow:0 12px 30px #0008;pointer-events:none;transition:transform .78s cubic-bezier(.2,.8,.2,1),opacity .78s ease;transform-origin:center}
.note{padding:0 18px 18px;color:var(--muted);font-size:13px}
@media(max-width:900px){.dispatchOverlay,.tankOverlay,.hoseOverlay,.detailCard{position:static;width:auto;height:auto;max-height:none;margin-top:12px}.tankHotspot,.hoseHotspot,.dispatchHotspot,.truckHotspot{display:none}.pumpCountBadge{position:static;display:inline-block;margin:8px 0}.tankList,.hoseList{max-height:260px}.dispatchRow{grid-template-columns:1fr 1fr}.dispatchRow .product{grid-column:1/-1}.detailCard{display:none}.detailCard.show{display:block}}
</style></head>
<body>
<header class="top"><div class="left"><a class="navlink" href="http://127.0.0.1:8790/">← DoingLio</a><a class="navlink" href="http://127.0.0.1:8790/capitan-rodolfo/index.html">← Capitán</a><span class="badge ok"><span style="color:#34f5a5">&#9679;</span> SQL conectado</span><span class="badge">Base: $safeDb</span></div><span class="ver">v$Version</span></header>
<main class="stage">
  <div class="mapWrap">
    <img src="http://127.0.0.1:8790/capitan-rodolfo/assets/capitan-rodolfo-mapa-vivo.svg" alt="Mapa Vivo de Capitan Rodolfo">
    <button id="truckHotspot" class="truckHotspot" type="button" title="Subir comprobante al camion" aria-label="Subir comprobante al camion">CAMION</button>
    <div class="pumpCountBadge">SURTIDORES (<strong>$surtidorCountText</strong>)</div>
    <button id="tankHotspot" class="tankHotspot" type="button">TANQUES ($tankCount)</button>
    <section id="tankPanel" class="tankOverlay" style="display:none">
      <div class="tankTitle"><span>TANQUES REALES</span><span><strong>$tankCount</strong> <button id="closeTankPanel" class="parentClose" type="button">x</button></span></div>
      <div class="tankList">$tankCards</div>
    </section>
    <button id="hoseHotspot" class="hoseHotspot" type="button">TANQUE &rarr; SURTIDOR &rarr; MANGUERA ($hoseCount)</button>
    <section id="hosePanel" class="hoseOverlay" style="display:none">
      <div class="hoseTitle"><span>TANQUE &rarr; SURTIDOR &rarr; MANGUERA</span><span><strong>$hoseCount</strong> <button id="closeHosePanel" class="parentClose" type="button">x</button></span></div>
      <div class="hoseList">$hoseCards</div>
    </section>
    <button id="dispatchHotspot" class="dispatchHotspot" type="button" style="display:none">VENTAS / DESPACHOS ($dispatchCount)</button>
    <section id="dispatchPanel" class="dispatchOverlay">
      <div class="dispatchTitle"><span>VENTAS / DESPACHOS</span><span><strong>$dispatchCount</strong> <button id="closeDispatchPanel" class="parentClose" type="button">x</button></span></div>
      <div class="dispatchList">$cards</div>
    </section>
    <section id="tankDetail" class="detailCard">
      <button class="detailClose" type="button" data-close="tankDetail">x</button>
      <div class="detailTitle">DETALLE DEL TANQUE</div>
      <div id="tankDetailBody" class="detailGrid"></div>
    </section>
    <section id="saleOnPump" class="detailCard">
      <button class="detailClose" type="button" data-close="saleOnPump">x</button>
      <div id="salePumpTitle" class="detailTitle">VENTA EN SURTIDOR</div>
      <div id="salePumpBody" class="detailGrid"></div>
      <button id="viewPaymentBtn" class="paymentBtn" type="button">VER PAGO</button>
    </section>
    <section id="paymentPanel" class="detailCard">
      <button class="detailClose" type="button" data-close="paymentPanel">x</button>
      <div class="detailTitle">PAGO DE LA VENTA</div>
      <div id="paymentBody" class="detailGrid"></div>
      <div class="paymentPending">Consulta de pago pendiente de definir. No se muestran datos inventados.</div>
    </section>
  </div>
</main>
<div id="receiptModal" class="receiptModal">
  <section class="receiptBox">
    <button id="receiptClose" class="receiptClose" type="button">x</button>
    <h2>Comprobante del camion</h2>
    <p>Subi una factura, recibo, transferencia, ticket o PDF. El camion recibe el archivo y Revalsoft IA lo analiza con la misma logica de TEST.</p>
    <label id="receiptUploadLabel" class="receiptUpload">SUBIR COMPROBANTE
      <input id="receiptFile" type="file" accept="image/*,.pdf">
    </label>
    <div id="receiptStatus" class="receiptStatus">Esperando archivo...</div>
    <div id="receiptPreview" class="receiptPreview"></div>
    <div id="revalLogin" class="revalLogin">
      <b>Iniciar sesion Revalsoft IA</b>
      <div style="font-size:12px;color:#b69c84;margin-top:4px">Se pide solo si este navegador local todavia no tiene una sesion valida.</div>
      <input id="revalEmail" type="email" autocomplete="username" placeholder="Email">
      <input id="revalPassword" type="password" autocomplete="current-password" placeholder="Contrasena">
      <button id="revalLoginBtn" type="button">INGRESAR Y ANALIZAR</button>
    </div>
    <div id="receiptResult" class="receiptResult">
      <h3>Comprobante analizado</h3>
      <div id="receiptResultBody" class="receiptResultGrid"></div>
    </div>
  </section>
</div>
<div class="note">Las ventanas padre controlan a sus hijas: al cerrar TANQUES se cierra el detalle; al cerrar VENTAS / DESPACHOS se cierran la venta seleccionada y VER PAGO.</div>
<script>
(function(){
  const tankPanel=document.getElementById('tankPanel');
  const tankHotspot=document.getElementById('tankHotspot');
  const hosePanel=document.getElementById('hosePanel');
  const hoseHotspot=document.getElementById('hoseHotspot');
  const closeTankPanel=document.getElementById('closeTankPanel');
  const closeHosePanel=document.getElementById('closeHosePanel');
  const dispatchPanel=document.getElementById('dispatchPanel');
  const dispatchHotspot=document.getElementById('dispatchHotspot');
  const closeDispatchPanel=document.getElementById('closeDispatchPanel');
  const tankDetail=document.getElementById('tankDetail');
  const tankBody=document.getElementById('tankDetailBody');
  const saleCard=document.getElementById('saleOnPump');
  const saleBody=document.getElementById('salePumpBody');
  const saleTitle=document.getElementById('salePumpTitle');
  const viewPaymentBtn=document.getElementById('viewPaymentBtn');
  const paymentPanel=document.getElementById('paymentPanel');
  const paymentBody=document.getElementById('paymentBody');
  const truckHotspot=document.getElementById('truckHotspot');
  const receiptModal=document.getElementById('receiptModal');
  const receiptClose=document.getElementById('receiptClose');
  const receiptFile=document.getElementById('receiptFile');
  const receiptUploadLabel=document.getElementById('receiptUploadLabel');
  const receiptStatus=document.getElementById('receiptStatus');
  const receiptPreview=document.getElementById('receiptPreview');
  const revalLogin=document.getElementById('revalLogin');
  const revalEmail=document.getElementById('revalEmail');
  const revalPassword=document.getElementById('revalPassword');
  const revalLoginBtn=document.getElementById('revalLoginBtn');
  const receiptResult=document.getElementById('receiptResult');
  const receiptResultBody=document.getElementById('receiptResultBody');
  const SB_URL='https://apqgrwudkfytwikrsivd.supabase.co';
  const SB_KEY='sb_publishable_B9NdjnzOKu9BhZGmTM6LGg_wDB3n8lY';
  let pendingReceipt=null;
  let selectedSale=null;

  function closeTankHierarchy(){
    tankPanel.style.display='none';
    tankDetail.classList.remove('show');
    document.querySelectorAll('.tankPick').forEach(x=>x.classList.remove('active'));
  }
  function closeSaleHierarchy(){
    dispatchPanel.style.display='none';
    dispatchHotspot.style.display='block';
    saleCard.classList.remove('show');
    paymentPanel.classList.remove('show');
    selectedSale=null;
    document.querySelectorAll('.salePick').forEach(x=>x.classList.remove('active'));
  }

  if(tankHotspot){
    tankHotspot.addEventListener('click',()=>{
      if(tankPanel.style.display==='none'){
        tankPanel.style.display='block';
      }else{
        closeTankHierarchy();
      }
    });
  }
  if(closeTankPanel){ closeTankPanel.addEventListener('click',closeTankHierarchy); }

  if(hoseHotspot){
    hoseHotspot.addEventListener('click',()=>{ hosePanel.style.display=(hosePanel.style.display==='none')?'block':'none'; });
  }
  if(closeHosePanel){ closeHosePanel.addEventListener('click',()=>{hosePanel.style.display='none';}); }

  if(closeDispatchPanel){ closeDispatchPanel.addEventListener('click',closeSaleHierarchy); }
  if(dispatchHotspot){
    dispatchHotspot.addEventListener('click',()=>{
      dispatchPanel.style.display='block';
      dispatchHotspot.style.display='none';
    });
  }

  document.querySelectorAll('.tankPick').forEach(btn=>{
    btn.addEventListener('click',()=>{
      document.querySelectorAll('.tankPick').forEach(x=>x.classList.remove('active')); btn.classList.add('active');
      tankBody.innerHTML=
        '<span>Tanque</span><b>'+btn.dataset.num+'</b>'+
        '<span>Denominacion</span><b>'+btn.dataset.den+'</b>'+
        '<span>Producto</span><b>'+btn.dataset.prod+'</b>'+
        '<span>Capacidad</span><b>'+btn.dataset.cap+' L</b>'+
        '<span>Mangueras</span><b>'+btn.dataset.hoses+'</b>';
      tankDetail.classList.add('show');
    });
  });

  document.querySelectorAll('.salePick').forEach(btn=>{
    btn.addEventListener('click',()=>{
      document.querySelectorAll('.salePick').forEach(x=>x.classList.remove('active')); btn.classList.add('active');
      selectedSale={
        idDespacho:btn.dataset.idDespacho||'',
        venta:btn.dataset.venta,
        surtidor:btn.dataset.surtidor,
        manguera:btn.dataset.manguera,
        producto:btn.dataset.producto,
        litros:btn.dataset.litros,
        ppu:btn.dataset.ppu,
        pesos:btn.dataset.pesos,
        hora:btn.dataset.hora
      };
      saleTitle.textContent='VENTA #'+btn.dataset.venta+' - SURTIDOR '+btn.dataset.surtidor;
      saleBody.innerHTML=
        '<span>Venta</span><b>#'+btn.dataset.venta+'</b>'+
        '<span>Surtidor</span><b>'+btn.dataset.surtidor+'</b>'+
        '<span>Manguera</span><b>'+btn.dataset.manguera+'</b>'+
        '<span>Producto</span><b>'+btn.dataset.producto+'</b>'+
        '<span>Litros</span><b>'+btn.dataset.litros+' L</b>'+
        '<span>PPU</span><b>'+btn.dataset.ppu+'</b>'+
        '<span>Pesos</span><b>$ '+btn.dataset.pesos+'</b>'+
        '<span>Hora</span><b>'+btn.dataset.hora+'</b>';
      saleCard.classList.add('show');
    });
  });

  if(viewPaymentBtn){
    viewPaymentBtn.addEventListener('click',async()=>{
      if(!selectedSale) return;
      paymentPanel.classList.add('show');
      paymentBody.innerHTML=
        '<span>Venta</span><b>#'+selectedSale.venta+'</b>'+
        '<span>Surtidor</span><b>'+selectedSale.surtidor+'</b>'+
        '<span>Importe</span><b>$ '+selectedSale.pesos+'</b>'+
        '<span>Pago</span><b>Buscando comprobante relacionado...</b>';
      try{
        const r=await fetch('/api/payment',{
          method:'POST',
          headers:{'Content-Type':'application/json'},
          body:JSON.stringify({sessionId:'$sid',database:'$safeDb',idDespacho:selectedSale.idDespacho,venta:selectedSale.venta})
        });
        const d=await r.json();
        if(!r.ok) throw new Error(d.error||('HTTP '+r.status));
        if(!d.resolved){
          paymentBody.innerHTML=
            '<span>Venta</span><b>#'+selectedSale.venta+'</b>'+
            '<span>id_despacho</span><b>'+escHtml(selectedSale.idDespacho||'NO DETECTADO')+'</b>'+
            '<span>Relacion</span><b>No pude resolver automaticamente el comprobante.</b>'+
            '<span>Columnas encontradas</span><b>'+escHtml((d.columns||[]).join(', '))+'</b>'+
            '<span>Detalle</span><b>'+escHtml(d.reason||'Sin detalle')+'</b>';
          return;
        }
        const p=d.payment||{};
        const c=d.comprobante||{};
        paymentBody.innerHTML=
          '<span>Comprobante</span><b>'+escHtml((c.letra||'')+' '+(c.sucursal||'')+'-'+(c.numero||''))+'</b>'+
          '<span>Mercado Pago</span><b>$ '+escHtml(p.MercadoPago||0)+'</b>'+
          '<span>App YPF</span><b>$ '+escHtml(p.AppYPF||0)+'</b>'+
          '<span>Shell Box</span><b>$ '+escHtml(p.ShellBox||0)+'</b>'+
          '<span>App Puma</span><b>$ '+escHtml(p.AppPuma||0)+'</b>'+
          '<span>Clover</span><b>$ '+escHtml(p.Clover||0)+'</b>'+
          '<span>PayWay</span><b>$ '+escHtml(p.PayWay||0)+'</b>'+
          '<span>Cheques</span><b>$ '+escHtml(p.Cheques||0)+'</b>'+
          '<span>Efectivo</span><b>$ '+escHtml(p.Efectivo||0)+'</b>'+
          '<span>Total</span><b>$ '+escHtml(p.TOTAL||selectedSale.pesos||0)+'</b>'+
          '<span>Vendedor</span><b>'+escHtml(p.Vendedor||'-')+'</b>';
        const pending=document.querySelector('#paymentPanel .paymentPending');
        if(pending) pending.textContent='Forma de pago obtenida desde RelacionCptsDespachos y la logica de PA_VentasFormasPago.';
      }catch(e){
        paymentBody.innerHTML=
          '<span>Venta</span><b>#'+selectedSale.venta+'</b>'+
          '<span>Error</span><b>'+escHtml(e.message||'No se pudo obtener la forma de pago')+'</b>';
      }
    });
  }

  function escHtml(v){
    return String(v==null?'':v).replace(/[&<>"']/g,function(ch){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]});
  }

  function setReceiptStatus(message,kind){
    receiptStatus.textContent=message;
    receiptStatus.className='receiptStatus'+(kind?' '+kind:'');
  }

  function readAsDataUrl(file){
    return new Promise(function(resolve,reject){
      const fr=new FileReader();
      fr.onload=function(){resolve(fr.result)};
      fr.onerror=reject;
      fr.readAsDataURL(file);
    });
  }

  async function refreshRevalsoftToken(){
    const refresh=localStorage.getItem('rodolfo.sb.refresh_token');
    if(!refresh) return null;
    try{
      const r=await fetch(SB_URL+'/auth/v1/token?grant_type=refresh_token',{
        method:'POST',
        headers:{'Content-Type':'application/json','apikey':SB_KEY},
        body:JSON.stringify({refresh_token:refresh})
      });
      const d=await r.json();
      if(!r.ok||!d.access_token) return null;
      localStorage.setItem('rodolfo.sb.access_token',d.access_token);
      if(d.refresh_token) localStorage.setItem('rodolfo.sb.refresh_token',d.refresh_token);
      localStorage.setItem('rodolfo.sb.expires_at',String(Date.now()+((d.expires_in||3600)*1000)));
      return d.access_token;
    }catch(_){return null}
  }

  async function getRevalsoftToken(){
    const token=localStorage.getItem('rodolfo.sb.access_token');
    const expires=Number(localStorage.getItem('rodolfo.sb.expires_at')||0);
    if(token && expires>Date.now()+30000) return token;
    return refreshRevalsoftToken();
  }

  async function loginRevalsoft(){
    const email=revalEmail.value.trim();
    const password=revalPassword.value;
    if(!email||!password) throw new Error('Completa email y contrasena.');
    const r=await fetch(SB_URL+'/auth/v1/token?grant_type=password',{
      method:'POST',
      headers:{'Content-Type':'application/json','apikey':SB_KEY},
      body:JSON.stringify({email:email,password:password})
    });
    const d=await r.json();
    if(!r.ok||!d.access_token) throw new Error(d.error_description||d.msg||d.error||'No se pudo iniciar sesion.');
    localStorage.setItem('rodolfo.sb.access_token',d.access_token);
    if(d.refresh_token) localStorage.setItem('rodolfo.sb.refresh_token',d.refresh_token);
    localStorage.setItem('rodolfo.sb.expires_at',String(Date.now()+((d.expires_in||3600)*1000)));
    revalPassword.value='';
    return d.access_token;
  }

  function normalizeKey(value){
    return String(value||'').toLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g,'').replace(/[^a-z0-9]/g,'');
  }
  function findValue(source,names,depth){
    depth=depth||0;
    if(!source||typeof source!=='object'||depth>7) return undefined;
    const wanted=names.map(normalizeKey);
    for(const key of Object.keys(source)){
      const value=source[key];
      if(wanted.includes(normalizeKey(key)) && value!==null && value!=='' && typeof value!=='object') return value;
    }
    for(const value of Object.values(source)){
      const found=findValue(value,names,depth+1);
      if(found!==undefined) return found;
    }
  }
  function findItems(source,depth){
    depth=depth||0;
    if(!source||typeof source!=='object'||depth>7) return [];
    for(const key of Object.keys(source)){
      const value=source[key];
      if(['items','item','detalle','detalles','lineas','conceptos','productos'].includes(normalizeKey(key)) && Array.isArray(value)) return value;
    }
    for(const value of Object.values(source)){
      const found=findItems(value,depth+1);
      if(found.length) return found;
    }
    return [];
  }
  function docText(data,names,fallback){
    const v=findValue(data,names,0);
    return v===undefined?(fallback===undefined?'-':fallback):String(v);
  }
  function docMoney(data,names){
    const value=findValue(data,names,0);
    const raw=String(value==null?'':value).trim();
    const number=Number(raw.replace(/\.(?=\d{3}(?:\D|$))/g,'').replace(',','.').replace(/[^0-9.-]/g,''));
    if(!Number.isFinite(number)||!raw) return '-';
    const currency=docText(data,['moneda'],'ARS')==='USD'?'USD':'ARS';
    try{return new Intl.NumberFormat('es-AR',{style:'currency',currency:currency,maximumFractionDigits:2}).format(number)}
    catch(_){return raw}
  }
  function renderReceiptResult(data){
    const type=docText(data,['tipo_documento','tipoDocumento','tipo_comprobante','tipoComprobante'],'COMPROBANTE').toUpperCase();
    const items=findItems(data,0);
    const isTransfer=type.includes('TRANSFER');
    const isReceipt=type.includes('RECIB');
    const issuer=isTransfer?docText(data,['plataforma'],'Transferencia'):docText(data,['proveedor','emisor','origen_nombre'],type);
    const headerSub=isTransfer
      ? 'Operacion: '+docText(data,['numero_operacion','codigo_identificacion'])
      : 'CUIT: '+docText(data,['proveedor_cuit','emisor_cuit','cuit']);
    let html='<div class="invoice-paper">';
    html+='<div class="invoice-head"><div><span>COMPROBANTE PROCESADO</span><h3>'+escHtml(issuer)+'</h3><p>'+escHtml(headerSub)+'</p></div>';
    html+='<div class="invoice-type"><b>'+escHtml(type)+'</b><small>'+escHtml(docText(data,['numero_comprobante','numero_operacion','numero','nro']))+'</small></div></div>';
    html+='<div class="invoice-meta"><div><span>Fecha</span><b>'+escHtml(docText(data,['fecha','fecha_emision']))+'</b></div><div><span>Hora</span><b>'+escHtml(docText(data,['hora']))+'</b></div><div><span>Moneda</span><b>'+escHtml(docText(data,['moneda'],'ARS'))+'</b></div></div>';
    if(isTransfer){
      html+='<div class="document-flow"><div><span>ORIGEN</span><b>'+escHtml(docText(data,['origen_nombre','emisor']))+'</b><small>'+escHtml(docText(data,['origen_cuit','emisor_cuit']))+'</small><small>'+escHtml(docText(data,['origen_cuenta']))+'</small></div><div class="flow-arrow">&rarr;</div><div><span>DESTINO</span><b>'+escHtml(docText(data,['destino_nombre','receptor']))+'</b><small>'+escHtml(docText(data,['destino_cuit','receptor_cuit']))+'</small><small>'+escHtml(docText(data,['destino_cuenta']))+'</small></div></div>';
    }else if(isReceipt){
      html+='<div class="document-flow"><div><span>RECIBIDO DE</span><b>'+escHtml(docText(data,['emisor','origen_nombre','cliente']))+'</b><small>'+escHtml(docText(data,['emisor_cuit','origen_cuit','cliente_cuit']))+'</small></div><div class="flow-arrow">&rarr;</div><div><span>RECIBIDO POR</span><b>'+escHtml(docText(data,['receptor','destino_nombre','proveedor']))+'</b><small>'+escHtml(docText(data,['receptor_cuit','destino_cuit','proveedor_cuit']))+'</small></div></div>';
    }
    if(items.length){
      html+='<div class="invoice-lines"><div class="invoice-line invoice-line-head"><span>Detalle</span><span>Cant.</span><span>Precio</span><span>Importe</span></div>';
      items.slice(0,10).forEach(function(item){
        html+='<div class="invoice-line"><span>'+escHtml(docText(item,['descripcion','nombre','producto','detalle'],'Item'))+'</span><span>'+escHtml(docText(item,['cantidad','quantity','canti'],'1'))+'</span><span>'+escHtml(docMoney(item,['precio_unitario','precio','price']))+'</span><span>'+escHtml(docMoney(item,['importe','total','subtotal']))+'</span></div>';
      });
      html+='</div>';
    }
    html+='<div class="invoice-totals">';
    if(!isTransfer&&!isReceipt){
      html+='<div><span>Subtotal</span><b>'+escHtml(docMoney(data,['subtotal','neto','importe_neto']))+'</b></div>';
      html+='<div><span>IVA</span><b>'+escHtml(docMoney(data,['total_iva','iva','importe_iva']))+'</b></div>';
      html+='<div><span>Impuestos / percepciones</span><b>'+escHtml(docMoney(data,['percepciones','impuestos','otros_impuestos']))+'</b></div>';
    }
    const totalLabel=isTransfer?'IMPORTE TRANSFERIDO':(isReceipt?'IMPORTE RECIBIDO':'TOTAL');
    html+='<div class="invoice-grand"><span>'+totalLabel+'</span><b>'+escHtml(docMoney(data,['importe','total','importe_total','monto_total']))+'</b></div></div>';
    html+='<div class="invoice-footer">';
    if(isTransfer||isReceipt){
      html+='<span>Medio<b>'+escHtml(docText(data,['medio_pago','plataforma']))+'</b></span><span>Motivo<b>'+escHtml(docText(data,['motivo','observaciones']))+'</b></span>';
    }else{
      html+='<span>CAE<b>'+escHtml(docText(data,['cae']))+'</b></span><span>Vencimiento CAE<b>'+escHtml(docText(data,['cae_vencimiento','vencimiento_cae']))+'</b></span>';
    }
    html+='</div></div>';
    receiptResultBody.innerHTML=html;
    receiptResult.classList.add('show');
  }

  async function analyzeReceipt(file){
    pendingReceipt=file;
    let token=await getRevalsoftToken();
    if(!token){
      revalLogin.classList.add('show');
      setReceiptStatus('Comprobante recibido por el camion. Inicia sesion Revalsoft IA para analizarlo.','ok');
      return;
    }
    revalLogin.classList.remove('show');
    setReceiptStatus('Camion recibio el comprobante. Analizando con Revalsoft IA TEST...');
    const base64=await readAsDataUrl(file);
    let r=await fetch(SB_URL+'/functions/v1/extract-document-json',{
      method:'POST',
      headers:{'Content-Type':'application/json','apikey':SB_KEY,'Authorization':'Bearer '+token},
      body:JSON.stringify({file_name:file.name,mime_type:file.type||'application/octet-stream',base64:base64})
    });
    if(r.status===401){
      localStorage.removeItem('rodolfo.sb.access_token');
      token=await refreshRevalsoftToken();
      if(token){
        r=await fetch(SB_URL+'/functions/v1/extract-document-json',{
          method:'POST',
          headers:{'Content-Type':'application/json','apikey':SB_KEY,'Authorization':'Bearer '+token},
          body:JSON.stringify({file_name:file.name,mime_type:file.type||'application/octet-stream',base64:base64})
        });
      }
    }
    const out=await r.json().catch(function(){return {}});
    if(!r.ok||!out.ok){
      if(r.status===401){
        revalLogin.classList.add('show');
        throw new Error('Sesion Revalsoft IA vencida. Inicia sesion nuevamente.');
      }
      throw new Error(out.error||'No se pudo analizar el comprobante.');
    }
    renderReceiptResult(out.data||{});
    setReceiptStatus('Comprobante analizado correctamente.','ok');
  }

  function animateReceiptToTruck(file){
    return new Promise(function(resolve){
      const source=receiptUploadLabel.getBoundingClientRect();
      const target=truckHotspot.getBoundingClientRect();
      const fly=document.createElement('div');
      fly.className='receiptFly';
      fly.textContent='COMPROBANTE - '+file.name;
      fly.style.left=(source.left+source.width/2-90)+'px';
      fly.style.top=(source.top+source.height/2-20)+'px';
      document.body.appendChild(fly);
      const dx=(target.left+target.width/2)-(source.left+source.width/2);
      const dy=(target.top+target.height/2)-(source.top+source.height/2);
      requestAnimationFrame(function(){
        requestAnimationFrame(function(){
          fly.style.transform='translate('+dx+'px,'+dy+'px) scale(.08) rotate(-10deg)';
          fly.style.opacity='0';
          truckHotspot.classList.add('feed');
        });
      });
      setTimeout(function(){
        fly.remove();
        truckHotspot.classList.remove('feed');
        resolve();
      },820);
    });
  }

  if(truckHotspot){
    truckHotspot.addEventListener('click',function(){
      receiptModal.classList.add('show');
      receiptResult.classList.remove('show');
      setReceiptStatus('Esperando archivo...');
    });
  }

  if(receiptClose){
    receiptClose.addEventListener('click',function(){receiptModal.classList.remove('show')});
  }
  receiptModal.addEventListener('click',function(e){if(e.target===receiptModal)receiptModal.classList.remove('show')});

  if(receiptFile){
    receiptFile.addEventListener('change',async function(){
      const file=receiptFile.files&&receiptFile.files[0];
      if(!file) return;
      pendingReceipt=file;
      receiptResult.classList.remove('show');
      receiptPreview.innerHTML='';
      if(file.type&&file.type.indexOf('image/')===0){
        const img=document.createElement('img');
        img.src=URL.createObjectURL(file);
        img.onload=function(){setTimeout(function(){URL.revokeObjectURL(img.src)},1000)};
        receiptPreview.appendChild(img);
      }else{
        receiptPreview.innerHTML='<div class="pdf">PDF - '+escHtml(file.name)+'</div>';
      }
      receiptPreview.classList.add('show');
      setReceiptStatus(file.name+' - '+(file.size/1024/1024).toFixed(2)+' MB');
      await animateReceiptToTruck(file);
      try{await analyzeReceipt(file)}catch(e){setReceiptStatus(e.message||'Error al analizar.','bad')}
    });
  }

  if(revalLoginBtn){
    revalLoginBtn.addEventListener('click',async function(){
      try{
        revalLoginBtn.disabled=true;
        setReceiptStatus('Iniciando sesion Revalsoft IA...');
        await loginRevalsoft();
        revalLogin.classList.remove('show');
        if(pendingReceipt) await analyzeReceipt(pendingReceipt);
      }catch(e){
        setReceiptStatus(e.message||'No se pudo iniciar sesion.','bad');
      }finally{
        revalLoginBtn.disabled=false;
      }
    });
  }

  document.querySelectorAll('[data-close]').forEach(btn=>{
    btn.addEventListener('click',()=>{
      const id=btn.dataset.close;
      document.getElementById(id).classList.remove('show');
      if(id==='saleOnPump'){
        paymentPanel.classList.remove('show');
        selectedSale=null;
        document.querySelectorAll('.salePick').forEach(x=>x.classList.remove('active'));
      }
    });
  });
})();
</script>
</body></html>
"@
          Send-Response $stream 200 "text/html; charset=utf-8" $html
        } catch {
          Send-Response $stream 401 "text/html; charset=utf-8" "<h2>Sesion SQL no valida</h2><p>$([System.Net.WebUtility]::HtmlEncode($_.Exception.Message))</p><p>Volver a abrir Capitan Rodolfo para reconectar.</p>"
        }
      }
      elseif($req.Method -eq 'POST' -and $pathOnly -eq '/api/connect'){
        try {
          $data = $req.Body | ConvertFrom-Json
          $server = [string]$data.server
          $auth = [string]$data.auth
          $user = [string]$data.user
          $password = [string]$data.password
          if([string]::IsNullOrWhiteSpace($server)){ throw "Completá servidor/instancia." }
          if($auth -eq 'sql' -and [string]::IsNullOrWhiteSpace($password)){
            $saved = Load-SqlProfile
            if($null -ne $saved -and [string]$saved.server -eq $server -and [string]$saved.auth -eq $auth -and [string]$saved.user -eq $user){
              $password = Unprotect-ProfilePassword -Profile $saved
            }
          }

          $state = Open-SqlSession -Server $server -Auth $auth -User $user -Password $password
          Save-SqlProfile -Server $server -Auth $auth -User $user -Password $password -Database ""
          $script:LastRestoreError = ""
          Write-ServiceStatus -State "running-connected" -Database "" -Server $server -User $user
          Send-Json $stream 200 $state
        } catch {
          Send-Json $stream 500 @{error=$_.Exception.Message}
        }
      }
      elseif($req.Method -eq 'POST' -and $pathOnly -eq '/api/tables'){
        try {
          $data = $req.Body | ConvertFrom-Json
          $sid = [string]$data.sessionId
          $database = [string]$data.database
          if(-not $Sessions.ContainsKey($sid)){ Send-Json $stream 401 @{error='Sesion vencida. Volver a conectar.'}; continue }
          $sess = $Sessions[$sid]
          if($sess.databases -notcontains $database){ Send-Json $stream 403 @{error='Base no autorizada.'}; continue }

          $cn = $sess.connection
          $cn.ChangeDatabase($database)
          $cmd = $cn.CreateCommand()
          $cmd.CommandText = @"
SELECT s.name AS esquema, t.name AS tabla
FROM sys.tables AS t
INNER JOIN sys.schemas AS s ON s.schema_id=t.schema_id
ORDER BY s.name,t.name;
"@
          $reader = $cmd.ExecuteReader()
          $rows = @()
          while($reader.Read()){ $rows += @{schema=[string]$reader.GetString(0);name=[string]$reader.GetString(1)} }
          $reader.Close()
          $sess["database"] = $database
          Save-SqlProfile -Server ([string]$sess.server) -Auth ([string]$sess.auth) -User ([string]$sess.user) -Password "" -Database $database
          Write-ServiceStatus -State "running-connected" -Database $database -Server ([string]$sess.server) -User ([string]$sess.user)
          Send-Json $stream 200 @{database=$database;tables=$rows}
        } catch {
          Send-Json $stream 500 @{error=$_.Exception.Message}
        }
      }
      elseif($req.Method -eq 'POST' -and $pathOnly -eq '/api/surpla'){
        try {
          $data = $req.Body | ConvertFrom-Json
          $sid = [string]$data.sessionId
          $database = [string]$data.database
          if(-not $Sessions.ContainsKey($sid)){ Send-Json $stream 401 @{error='Sesion vencida. Volver a conectar.'}; continue }
          $sess = $Sessions[$sid]
          if($sess.databases -notcontains $database){ Send-Json $stream 403 @{error='Base no autorizada.'}; continue }
          $cn = $sess.connection
          $cn.ChangeDatabase($database)
          $cmd = $cn.CreateCommand()
          $cmd.CommandText = 'SELECT * FROM dbo.SURPLA;'
          $cmd.CommandTimeout = 30
          $reader = $cmd.ExecuteReader()
          $columns = @()
          for($i=0;$i -lt $reader.FieldCount;$i++){ $columns += [string]$reader.GetName($i) }
          $rows = @()
          while($reader.Read()){
            $row = [ordered]@{}
            for($i=0;$i -lt $reader.FieldCount;$i++){
              $value = $reader.GetValue($i)
              if($value -is [DBNull]){ $value = $null }
              elseif($value -is [DateTime]){ $value = ([DateTime]$value).ToString('dd/MM/yyyy HH:mm:ss') }
              $row[$columns[$i]] = $value
            }
            $rows += [pscustomobject]$row
          }
          $reader.Close()
          Send-Json $stream 200 @{database=$database;query='SELECT * FROM dbo.SURPLA';columns=$columns;rows=$rows;rowCount=$rows.Count}
        } catch {
          Send-Json $stream 500 @{error=$_.Exception.Message}
        }
      }
      elseif($req.Method -eq 'POST' -and $pathOnly -eq '/api/payment'){
        try {
          $data = $req.Body | ConvertFrom-Json
          $sid = [string]$data.sessionId
          $database = [string]$data.database
          $idDespacho = [string]$data.idDespacho
          if(-not $Sessions.ContainsKey($sid)){ Send-Json $stream 401 @{error='Sesion vencida. Volver a conectar.'}; continue }
          $sess = $Sessions[$sid]
          if($sess.databases -notcontains $database){ Send-Json $stream 403 @{error='Base no autorizada.'}; continue }
          $cn = $sess.connection
          $cn.ChangeDatabase($database)

          $metaCmd = $cn.CreateCommand()
          $metaCmd.CommandText = "SELECT c.name FROM sys.columns c WHERE c.object_id=OBJECT_ID('dbo.RelacionCptsDespachos') ORDER BY c.column_id;"
          $mr = $metaCmd.ExecuteReader()
          $relationColumns = @()
          while($mr.Read()){ $relationColumns += [string]$mr.GetString(0) }
          $mr.Close()
          if($relationColumns.Count -eq 0){
            Send-Json $stream 200 @{resolved=$false;reason='No existe dbo.RelacionCptsDespachos o no tiene columnas visibles.';columns=@()}
            continue
          }

          function Normalize-LocalName([string]$name){
            return ($name.ToLowerInvariant() -replace '[^a-z0-9]','')
          }
          function Pick-RelationColumn($columns,[string[]]$exact,[string[]]$contains){
            foreach($e in $exact){
              foreach($c in $columns){ if((Normalize-LocalName $c) -eq $e){ return $c } }
            }
            foreach($needle in $contains){
              foreach($c in $columns){ if((Normalize-LocalName $c).Contains($needle)){ return $c } }
            }
            return $null
          }

          $dispatchCol = Pick-RelationColumn $relationColumns @('iddespacho','iddespcho') @('iddesp','despachoid','despacho')
          if([string]::IsNullOrWhiteSpace($dispatchCol)){
            Send-Json $stream 200 @{resolved=$false;reason='No pude identificar la columna que relaciona con Despachos.';columns=$relationColumns}
            continue
          }
          if([string]::IsNullOrWhiteSpace($idDespacho)){
            Send-Json $stream 200 @{resolved=$false;reason='El registro de Despachos no expuso su ID interno.';columns=$relationColumns}
            continue
          }

          $relCmd = $cn.CreateCommand()
          $relCmd.CommandText = "SELECT TOP 1 * FROM dbo.RelacionCptsDespachos WHERE ["+$dispatchCol.Replace("]","]]")+"] = @id;"
          $null = $relCmd.Parameters.Add("@id",[System.Data.SqlDbType]::VarChar,100)
          $relCmd.Parameters["@id"].Value = $idDespacho
          $rr = $relCmd.ExecuteReader()
          if(-not $rr.Read()){
            $rr.Close()
            Send-Json $stream 200 @{resolved=$false;reason='No encontre una fila en RelacionCptsDespachos para id_despacho='+$idDespacho;columns=$relationColumns}
            continue
          }
          $rel = @{}
          for($i=0;$i -lt $rr.FieldCount;$i++){
            $name=[string]$rr.GetName($i)
            $val=$rr.GetValue($i)
            if($val -is [DBNull]){ $val=$null }
            $rel[$name]=$val
          }
          $rr.Close()

          $letterCol = Pick-RelationColumn $relationColumns @('letra','letter') @('letracomp','letracpte')
          $branchCol = Pick-RelationColumn $relationColumns @('sucursal','pos') @('sucursalcomp','poscomp')
          $numberCol = Pick-RelationColumn $relationColumns @('ncompro','numero','nrocompro','nrocomprobante','invoicenumber') @('ncompro','numerocomp','nrocomp','invoice')
          $typeCol = Pick-RelationColumn $relationColumns @('tipo','type','tipocpte','tipocomprobante') @('tipocomp','tipocpte')

          $letra = if($letterCol){[string]$rel[$letterCol]}else{''}
          $sucursal = if($branchCol){[string]$rel[$branchCol]}else{''}
          $numero = if($numberCol){[string]$rel[$numberCol]}else{''}
          $tipo = if($typeCol){[string]$rel[$typeCol]}else{''}

          if([string]::IsNullOrWhiteSpace($sucursal) -or [string]::IsNullOrWhiteSpace($numero)){
            Send-Json $stream 200 @{resolved=$false;reason='Encontre la relacion, pero no pude identificar sucursal/numero de comprobante.';columns=$relationColumns;relation=$rel}
            continue
          }

          $isTicket = (($tipo.ToUpperInvariant()).Contains('TICKET') -or $letra.ToUpperInvariant() -eq 'T')
          $payCmd = $cn.CreateCommand()

          if($isTicket){
            $payCmd.CommandText = @"
SELECT TOP 1
 'T' AS letra,
 MT.sucursal,
 MT.Numero AS NCOMPRO,
 MT.turno AS Turno,
 ISNULL(ROUND(MP_O.amount,2),0) AS MercadoPago,
 ISNULL(ROUND(ypf_P.amount,2),0) AS AppYPF,
 ISNULL(ROUND(SH_P.TotalAmount,2),0) AS ShellBox,
 ISNULL(ROUND(PU_P.TotalTransaction-PU_P.Discounts,2),0) AS AppPuma,
 ISNULL(ROUND(C_P.Amount,2),0) AS Clover,
 ISNULL(ROUND(ISNULL(T.IMPORTETAR,0)-ISNULL(T.Extraccion,0),2),0) AS PayWay,
 CAST(0 AS decimal(18,2)) AS Cheques,
 ROUND(MT.TOTAL-(
   ISNULL(ROUND(C_P.Amount,2),0)+ISNULL(ROUND(MP_O.amount,2),0)+ISNULL(ROUND(ypf_P.amount,2),0)+
   ISNULL(ROUND(ISNULL(T.IMPORTETAR,0)-ISNULL(T.Extraccion,0),2),0)+
   ISNULL(ROUND(SH_P.TotalAmount,2),0)+ISNULL(ROUND(PU_P.TotalTransaction,2),0)
 ),2) AS Efectivo,
 MT.TOTAL,
 ISNULL(CAST(MT.Vendedor AS VARCHAR(8)),'0')+' - '+ISNULL(MV.RAZONSOC,'SIN VENDEDOR') AS Vendedor
FROM (
 SELECT Sucursal,Numero,turno,SUM(TOTAL) TOTAL,VENDEDOR
 FROM Maetic
 WHERE Sucursal=@Sucursal AND Numero=@Numero
 GROUP BY Sucursal,Numero,turno,VENDEDOR
) MT
LEFT JOIN MP_OrdenPagoComprobante MP_C ON MT.SUCURSAL=MP_C.Sucursal AND MT.NUMERO=MP_C.Numero AND MP_C.Tipo='TICKET'
LEFT JOIN MP_OrdenPago MP_O ON MP_C.ID_OrdenPago=MP_O.ID
LEFT JOIN YPF_PaymentIntentionComprobante ypf_C ON MT.SUCURSAL=ypf_C.Sucursal AND MT.NUMERO=ypf_C.Numero AND ypf_C.Tipo='TICKET'
LEFT JOIN YPF_PaymentIntention ypf_P ON ypf_P.ID=ypf_C.ID_PaymentIntention
LEFT JOIN Shell_PayOrderComprobante SH_C ON MT.SUCURSAL=SH_C.Sucursal AND MT.NUMERO=SH_C.Numero AND SH_C.Tipo='TICKET'
LEFT JOIN Shell_PayOrder SH_P ON SH_C.PayOrderId=SH_P.ID
LEFT JOIN PUMA_PaymentComprobante PU_C ON MT.SUCURSAL=PU_C.Sucursal AND MT.NUMERO=PU_C.Numero AND PU_C.Tipo='TICKET'
LEFT JOIN PUMA_Payment PU_P ON PU_C.PaymentId=PU_P.ID
LEFT JOIN Tarjet T ON T.Letra='T' AND MT.SUCURSAL=T.Sucursal AND MT.NUMERO=T.NFACT
LEFT JOIN Clover_PaymentInvoices C_PI ON MT.SUCURSAL=C_PI.Pos AND MT.NUMERO=C_PI.InvoiceNumber AND C_PI.Type='TICKET'
LEFT JOIN Clover_Payments C_P ON C_P.Id=C_PI.CloverPaymentId
LEFT JOIN Maeven MV ON MV.VENDEDOR=MT.VENDEDOR;
"@
          } else {
            if([string]::IsNullOrWhiteSpace($letra)){
              Send-Json $stream 200 @{resolved=$false;reason='Encontre sucursal y numero, pero falta letra/tipo para distinguir factura de ticket.';columns=$relationColumns;relation=$rel}
              continue
            }
            $payCmd.CommandText = @"
SELECT TOP 1
 M.letra,M.sucursal,M.NCOMPRO,M.turno AS Turno,
 ISNULL(ROUND(MP_O.amount,2),0.00) AS MercadoPago,
 ISNULL(ROUND(ypf_P.amount,2),0) AS AppYPF,
 ISNULL(ROUND(SH_P.TotalAmount,2),0) AS ShellBox,
 ISNULL(ROUND(PU_P.TotalTransaction-PU_P.Discounts,2),0) AS AppPuma,
 ISNULL(ROUND(C_P.Amount,2),0) AS Clover,
 ISNULL(ROUND(ISNULL(T.IMPORTETAR,0)-ISNULL(T.Extraccion,0),2),0) AS PayWay,
 M.cheques AS Cheques,
 CASE M.CONDVTA WHEN 2 THEN 0 ELSE
 ROUND((M.TOTAL-(
   ISNULL(ROUND(C_P.Amount,2),0)+ISNULL(ROUND(MP_O.amount,2),0)+ISNULL(ROUND(ypf_P.amount,2),0)+
   ISNULL(ROUND(ISNULL(T.IMPORTETAR,0)-ISNULL(T.Extraccion,0),2),0)+
   ISNULL(ROUND(SH_P.TotalAmount,2),0)+ISNULL(ROUND(PU_P.TotalTransaction,2),0)
 )),2) END AS Efectivo,
 M.TOTAL,
 ISNULL(CAST(M.Vendedor AS VARCHAR(8)),'0')+' - '+ISNULL(MV.RAZONSOC,'SIN VENDEDOR') AS Vendedor
FROM Maefac M
LEFT JOIN MP_OrdenPagoComprobante MP_C ON M.LETRA=MP_C.Letra AND M.SUCURSAL=MP_C.Sucursal AND M.NCOMPRO=MP_C.Numero
LEFT JOIN MP_OrdenPago MP_O ON MP_C.ID_OrdenPago=MP_O.ID
LEFT JOIN YPF_PaymentIntentionComprobante ypf_C ON M.LETRA=ypf_C.Letra AND M.SUCURSAL=ypf_C.Sucursal AND M.NCOMPRO=ypf_C.Numero
LEFT JOIN YPF_PaymentIntention ypf_P ON ypf_P.ID=ypf_C.ID_PaymentIntention
LEFT JOIN Tarjet T ON M.LETRA=T.Letra AND M.SUCURSAL=T.Sucursal AND M.NCOMPRO=T.NFACT
LEFT JOIN Shell_PayOrderComprobante SH_C ON M.LETRA=SH_C.Letra AND M.SUCURSAL=SH_C.Sucursal AND M.NCOMPRO=SH_C.Numero
LEFT JOIN Shell_PayOrder SH_P ON SH_C.PayOrderId=SH_P.ID
LEFT JOIN PUMA_PaymentComprobante PU_C ON M.LETRA=PU_C.Letra AND M.SUCURSAL=PU_C.Sucursal AND M.NCOMPRO=PU_C.Numero
LEFT JOIN PUMA_Payment PU_P ON PU_C.PaymentId=PU_P.ID
LEFT JOIN Clover_PaymentInvoices C_PI ON M.SUCURSAL=C_PI.Pos AND M.NCOMPRO=C_PI.InvoiceNumber AND C_PI.Letter=M.LETRA
LEFT JOIN Clover_Payments C_P ON C_P.Id=C_PI.CloverPaymentId
LEFT JOIN Maeven MV ON MV.VENDEDOR=M.VENDEDOR
WHERE M.LETRA=@Letra AND M.SUCURSAL=@Sucursal AND M.NCOMPRO=@Numero;
"@
            $null=$payCmd.Parameters.Add("@Letra",[System.Data.SqlDbType]::VarChar,10)
            $payCmd.Parameters["@Letra"].Value=$letra
          }

          $null=$payCmd.Parameters.Add("@Sucursal",[System.Data.SqlDbType]::VarChar,30)
          $payCmd.Parameters["@Sucursal"].Value=$sucursal
          $null=$payCmd.Parameters.Add("@Numero",[System.Data.SqlDbType]::VarChar,50)
          $payCmd.Parameters["@Numero"].Value=$numero

          $pr=$payCmd.ExecuteReader()
          if(-not $pr.Read()){
            $pr.Close()
            Send-Json $stream 200 @{resolved=$false;reason='La relacion existe, pero no encontre el comprobante en Maefac/Maetic.';columns=$relationColumns;relation=$rel}
            continue
          }
          $payment=@{}
          for($i=0;$i -lt $pr.FieldCount;$i++){
            $name=[string]$pr.GetName($i)
            $val=$pr.GetValue($i)
            if($val -is [DBNull]){$val=0}
            $payment[$name]=$val
          }
          $pr.Close()
          Send-Json $stream 200 @{
            resolved=$true
            dispatchColumn=$dispatchCol
            relation=$rel
            comprobante=@{letra=$letra;sucursal=$sucursal;numero=$numero;tipo=$tipo}
            payment=$payment
          }
        } catch {
          Send-Json $stream 500 @{error=$_.Exception.Message}
        }
      }
      elseif($req.Method -eq 'POST' -and $pathOnly -eq '/api/dispatches'){
        try {
          $data = $req.Body | ConvertFrom-Json
          $sid = [string]$data.sessionId
          $database = [string]$data.database
          if(-not $Sessions.ContainsKey($sid)){ Send-Json $stream 401 @{error='Sesion vencida. Volver a conectar.'}; continue }
          $sess = $Sessions[$sid]
          if($sess.databases -notcontains $database){ Send-Json $stream 403 @{error='Base no autorizada.'}; continue }

          $cn = $sess.connection
          $cn.ChangeDatabase($database)
          $cmd = $cn.CreateCommand()
          $cmd.CommandText = "SELECT id_sale venta, surtidor, manguera, d.codart, p.descriimpresion, Litros, PPU, pesos, d.Ultime fecha, Ultime as hora FROM Despachos d INNER JOIN prod p ON d.codart = p.codart;"
          $reader = $cmd.ExecuteReader()

          $cols = @()
          for($i=0; $i -lt $reader.FieldCount; $i++){ $cols += [string]$reader.GetName($i) }
          $rows = @()
          while($reader.Read()){
            $row = [ordered]@{}
            for($i=0; $i -lt $reader.FieldCount; $i++){
              $v = $reader.GetValue($i)
              if($v -is [System.DBNull]){ $v = $null }
              elseif($v -is [DateTime]){ $v = $v.ToString("yyyy-MM-dd HH:mm:ss") }
              elseif($v -is [byte[]]){ $v = "[binario]" }
              $row[$cols[$i]] = $v
            }
            $rows += [pscustomobject]$row
          }
          $reader.Close()
          Send-Json $stream 200 @{database=$database;columns=$cols;rows=$rows}
        } catch {
          Send-Json $stream 500 @{error=$_.Exception.Message}
        }
      }
      else {
        Send-Json $stream 404 @{error='Ruta no encontrada'}
      }
    } catch {
      try { Send-Json $stream 500 @{error=$_.Exception.Message} } catch {}
    } finally {
      try { $client.Close() } catch {}
    }
  }
}
finally {
  foreach($k in @($Sessions.Keys)){ try { $Sessions[$k].connection.Dispose() } catch {} }
  $listener.Stop()
}
){
            $hostPart = [string]$matches[1]
            $instancePart = [string]$matches[2]
            if($hostPart -eq '.' -or $hostPart -ieq 'localhost' -or $hostPart -ieq $env:COMPUTERNAME){
                $serverToUse = '.\\' + $instancePart
            }
        }
    } catch {}
    $cn = New-SqlConnection -Server $serverToUse -Auth $Auth -User $User -Password $Password
    $cn.Open()
    $cmd = $cn.CreateCommand()
    $cmd.CommandText = "SELECT name FROM sys.databases WHERE state_desc='ONLINE' AND HAS_DBACCESS(name)=1 ORDER BY name;"
    $reader = $cmd.ExecuteReader()
    $dbs = @()
    while($reader.Read()){ $dbs += [string]$reader.GetString(0) }
    $reader.Close()

    $sid = [guid]::NewGuid().ToString()
    $Sessions[$sid] = @{ connection=$cn; databases=$dbs; server=$Server; auth=$Auth; user=$User }
    $script:ActiveSessionId = $sid
    return @{sessionId=$sid;server=$Server;auth=$Auth;user=$User;databases=$dbs}
}

function Ensure-ActiveSession {
    if($script:ActiveSessionId -and $Sessions.ContainsKey($script:ActiveSessionId)){
        try {
            $sess = $Sessions[$script:ActiveSessionId]
            if($sess.connection.State -eq [System.Data.ConnectionState]::Open){
                $db = ""
                if($sess.ContainsKey("database")){ $db = [string]$sess.database }
                return @{sessionId=$script:ActiveSessionId;server=$sess.server;auth=$sess.auth;user=$sess.user;databases=$sess.databases;database=$db}
            }
        } catch {}
    }
    return $null
}

function Get-HomeHtml {
@"
<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Capitan Rodolfo - SQL local</title>
<style>
:root{--bg:#0d0d0f;--card:#17171b;--line:#34343b;--orange:#ff7a00;--text:#f5f5f6;--muted:#aaaab2;--ok:#35d07f;--bad:#ff6b6b}
*{box-sizing:border-box}body{margin:0;background:radial-gradient(circle at 30% 0,#21170f,#0d0d0f 42%);color:var(--text);font-family:Segoe UI,Arial,sans-serif;min-height:100vh}
.wrap{width:min(1120px,94vw);margin:28px auto}.top{display:flex;justify-content:space-between;align-items:center;margin-bottom:18px}.ver{background:var(--orange);color:#111;padding:7px 10px;border-radius:999px;font-weight:900;font-size:12px}
.grid{display:grid;grid-template-columns:390px 1fr;gap:18px}.card{background:#17171bf2;border:1px solid var(--line);border-radius:20px;padding:20px}
h1{margin:0 0 4px}.muted{color:var(--muted);font-size:13px;line-height:1.5}label{display:block;font-size:12px;color:var(--muted);margin:13px 0 6px}
input,select{width:100%;background:#0f0f12;border:1px solid #3a3a41;color:white;padding:12px;border-radius:11px}
button{width:100%;border:0;border-radius:12px;padding:13px;margin-top:14px;background:linear-gradient(135deg,#ff7a00,#ff9630);font-weight:900;cursor:pointer}
.status{margin-top:14px;padding:11px;border:1px solid var(--line);border-radius:11px;color:var(--muted);font-size:13px}.ok{color:#86e8b2;border-color:#235f43}.bad{color:#ffaaaa;border-color:#6b2a2a}
.cols{display:grid;grid-template-columns:1fr 1fr;gap:16px}.list{display:grid;gap:8px;max-height:520px;overflow:auto}.item,.table{border:1px solid #34343b;background:#121216;color:#eee;padding:10px;border-radius:10px}.item{cursor:pointer}.item:hover,.item.active{border-color:var(--orange);background:#21170f}
.note{margin-top:15px;font-size:12px;color:var(--muted)}
.heroTop{display:flex;align-items:center;justify-content:space-between;gap:18px}
.rodolfoMini{position:relative;width:118px;height:108px;flex:0 0 118px}
.rCap{position:absolute;left:22px;top:2px;width:76px;height:34px;background:var(--orange);border:4px solid #111116;border-radius:50% 50% 12% 12%;z-index:3}
.rCap:after{content:"";position:absolute;right:-28px;bottom:-3px;width:48px;height:11px;background:var(--orange);border:4px solid #111116;border-radius:50%}
.rHead{position:absolute;left:35px;top:28px;width:58px;height:64px;background:#f0aa78;border:4px solid #111116;border-radius:44% 44% 46% 46%}
.rEye{position:absolute;top:51px;width:6px;height:8px;background:#111;border-radius:50%;z-index:4}.rEye.l{left:52px}.rEye.r{left:74px}
.rMust{position:absolute;left:49px;top:70px;width:32px;height:10px;background:#19191d;border-radius:50%;z-index:4}
.rBody{position:absolute;left:28px;bottom:0;width:72px;height:32px;background:#2b2b33;border:4px solid #111116;border-radius:14px 14px 8px 8px}
.rTie{position:absolute;left:60px;bottom:2px;width:12px;height:30px;background:var(--orange);clip-path:polygon(35% 0,65% 0,85% 75%,50% 100%,15% 75%);z-index:4}
.dispatchCard{margin-top:18px;background:#17171bf2;border:1px solid var(--line);border-radius:20px;padding:20px}
.dispatchHead{display:flex;justify-content:space-between;align-items:center;gap:12px;margin-bottom:12px}.dispatchHead h2{margin:0}.query{font-size:11px;color:#ffb06a}
.tableWrap{overflow:auto;max-height:420px;border:1px solid #34343b;border-radius:12px}.dataGrid{border-collapse:collapse;width:100%;font-size:12px;min-width:720px}.dataGrid th,.dataGrid td{padding:9px 10px;border-bottom:1px solid #2b2b31;border-right:1px solid #24242a;text-align:left;white-space:nowrap}.dataGrid th{position:sticky;top:0;background:#21170f;color:#ffb06a;z-index:1}.dataGrid td{background:#111116}
.continueMap{display:none;margin-top:14px;background:linear-gradient(135deg,#2dd9ff,#34f5a5);color:#061116}.continueMap.show{display:block}
@media(max-width:900px){.grid,.cols{grid-template-columns:1fr}.rodolfoMini{transform:scale(.9);transform-origin:right center}}
</style>
</head>
<body>
<div class="wrap">
<div class="top"><div><strong>DoingLio - CAPITÁN RODOLFO</strong><div class="muted">Conector SQL local</div></div><span class="ver">v$Version</span></div>
<div class="grid">
<section class="card">
<div class="heroTop">
<div><h1>Conexion SQL</h1><div class="muted">Esta pantalla corre dentro de tu PC. No depende de CORS ni del acceso a red local del navegador.</div></div>
<div class="rodolfoMini" aria-label="Capitan Rodolfo">
  <div class="rCap"></div><div class="rHead"></div><div class="rEye l"></div><div class="rEye r"></div><div class="rMust"></div><div class="rBody"></div><div class="rTie"></div>
</div>
</div>
<label>Servidor / instancia</label><input id="server" value="DUILIO\SQLEXPRESS" autocomplete="off">
<label>Autenticacion</label>
<select id="auth"><option value="sql">Usuario y contrasena SQL Server</option><option value="windows">Windows</option></select>
<div id="sqlCreds"><label>Usuario SQL</label><input id="user" autocomplete="username"><label>Contraseña</label><input id="password" type="password" autocomplete="current-password" placeholder="Ingresá la contraseña la primera vez"></div>
<div id="credentialState" class="note">Buscando conexión guardada…</div>
<button id="connect">Conectar y guardar</button>
<div id="status" class="status">Servicio SQL local v$Version listo.</div>
<button id="goMap" class="continueMap" type="button">Continuar al Mapa Vivo -></button>
<div class="note">La conexión queda guardada localmente y protegida con tu usuario de Windows. Al volver a abrir Capitán Rodolfo intenta reconectarse automáticamente a la última base elegida.</div>
</section>
<section class="card">
<div class="cols"><div><h3>Bases</h3><div id="dbs" class="list"><div class="item">Conectate para ver bases</div></div></div><div><h3>Tablas</h3><div id="tables" class="list"><div class="table">Selecciona una base</div></div></div></div>
</section>
</div>
<section class="dispatchCard">
  <div class="dispatchHead"><h2>Tabla SURPLA</h2><span class="query">SELECT * FROM dbo.SURPLA</span></div>
  <div id="surpla" class="muted">Conectate y elegí una base para ver SURPLA.</div>
</section>
<section class="dispatchCard">
  <div class="dispatchHead"><h2>Despachos abiertos</h2><span class="query">SELECT * FROM Despachos WHERE estadovta = 0</span></div>
  <div id="dispatches" class="muted">Selecciona una base para ver los despachos.</div>
</section>
</div>
<script>
let sessionId=null;
const s=document.getElementById('status'), dbs=document.getElementById('dbs'), tables=document.getElementById('tables'), surpla=document.getElementById('surpla'), dispatches=document.getElementById('dispatches'), goMap=document.getElementById('goMap'), credentialState=document.getElementById('credentialState');
const serverInput=document.getElementById('server'),authInput=document.getElementById('auth'),userInput=document.getElementById('user'),passwordInput=document.getElementById('password');
let selectedDatabase=null;
function status(m,k=''){s.textContent=m;s.className='status '+k}
function updateAuth(){document.getElementById('sqlCreds').style.display=authInput.value==='windows'?'none':'block'}
authInput.onchange=updateAuth;
async function api(path,body){
 const r=await fetch(path,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body||{})});
 const j=await r.json().catch(()=>({})); if(!r.ok) throw new Error(j.error||('HTTP '+r.status)); return j;
}
async function getJson(path){
 const r=await fetch(path,{cache:'no-store'});const j=await r.json().catch(()=>({}));if(!r.ok)throw new Error(j.error||('HTTP '+r.status));return j;
}
function showDatabases(d,autoDb){
 sessionId=d.sessionId;
 dbs.innerHTML='';
 (d.databases||[]).forEach(name=>{
   const b=document.createElement('button');b.className='item';b.textContent=name;b.onclick=()=>loadTables(name,b);dbs.appendChild(b);
   if(autoDb&&name===autoDb)setTimeout(()=>loadTables(name,b),0);
 });
}
async function restoreSaved(){
 try{
  const p=await getJson('/api/profile-status');
  if(p.saved){
    serverInput.value=p.server||serverInput.value;authInput.value=p.auth||'sql';userInput.value=p.user||'';updateAuth();
    if(p.hasPassword){passwordInput.value='';passwordInput.placeholder='Contraseña guardada y protegida por Windows';credentialState.textContent='Usuario '+(p.user||'(Windows)')+' · contraseña guardada de forma segura · base '+(p.database||'sin elegir');}
    else credentialState.textContent='Conexión guardada sin contraseña SQL.';
  }else{
    credentialState.textContent='Todavía no hay usuario/contraseña guardados en esta PC.';
  }
  let state=await getJson('/api/state');
  if(!state.connected&&p.saved){
    status('Reconectando automáticamente…');
    state=await api('/api/reconnect-saved',{});
  }
  if(state.connected){
    serverInput.value=state.server||serverInput.value;authInput.value=state.auth||authInput.value;userInput.value=state.user||userInput.value;updateAuth();
    showDatabases(state,state.database||p.database);
    if(state.database) status('SQL conectado automáticamente · '+state.database,'ok');
    else status('SQL conectado automáticamente · elegí una base','ok');
  }
 }catch(e){status('Servicio activo, pero no pude recuperar la conexión guardada: '+e.message,'bad')}
}
document.getElementById('connect').onclick=async()=>{
 try{
  status('Conectando…');
  const payload={server:serverInput.value.trim(),auth:authInput.value,user:userInput.value.trim(),password:passwordInput.value};
  const d=await api('/api/connect',payload); passwordInput.value=''; passwordInput.placeholder='Contraseña guardada y protegida por Windows'; credentialState.textContent='Usuario '+(payload.user||'(Windows)')+' · contraseña protegida y guardada localmente'; status('Conectado a '+d.server+' - elegí una base','ok');
  showDatabases(d,null);
 }catch(e){status('No se pudo conectar. '+e.message,'bad')}
};
restoreSaved();
async function loadTables(database,el){
 try{
  selectedDatabase=database;
  [...document.querySelectorAll('#dbs .item')].forEach(x=>x.classList.remove('active'));el.classList.add('active');
  tables.innerHTML='<div class="table">Validando base…</div>';
  const d=await api('/api/tables',{sessionId,database});
  tables.innerHTML='';d.tables.forEach(t=>{const row=document.createElement('div');row.className='table';row.textContent=t.schema+'.'+t.name;tables.appendChild(row)});
  status('Base '+database+' conectada. Mostrando SELECT * FROM dbo.SURPLA','ok');
  const result=await api('/api/surpla',{sessionId,database});
  renderGrid(surpla,result,'SURPLA no tiene filas.');
  goMap.classList.add('show');
 }catch(e){
  status('Error: '+e.message,'bad')
 }
}
function renderGrid(container,data,emptyText){
 container.innerHTML='';
 if(!data.rows||!data.rows.length){container.innerHTML='<div class="muted">'+emptyText+'</div>';return}
 const wrap=document.createElement('div');wrap.className='tableWrap';
 const table=document.createElement('table');table.className='dataGrid';
 const thead=document.createElement('thead'),trh=document.createElement('tr');
 data.columns.forEach(c=>{const th=document.createElement('th');th.textContent=c;trh.appendChild(th)});thead.appendChild(trh);table.appendChild(thead);
 const tbody=document.createElement('tbody');
 data.rows.forEach(row=>{const tr=document.createElement('tr');data.columns.forEach(c=>{const td=document.createElement('td');const v=row[c];td.textContent=(v===null||v===undefined)?'':String(v);tr.appendChild(td)});tbody.appendChild(tr)});
 table.appendChild(tbody);wrap.appendChild(table);container.appendChild(wrap);
}
function renderDispatches(data){
 dispatches.innerHTML='';
 if(!data.rows||!data.rows.length){dispatches.innerHTML='<div class="muted">No hay despachos con estadovta = 0.</div>';return}
 const wrap=document.createElement('div');wrap.className='tableWrap';
 const table=document.createElement('table');table.className='dataGrid';
 const thead=document.createElement('thead'),trh=document.createElement('tr');
 data.columns.forEach(c=>{const th=document.createElement('th');th.textContent=c;trh.appendChild(th)});thead.appendChild(trh);table.appendChild(thead);
 const tbody=document.createElement('tbody');
 data.rows.forEach(row=>{const tr=document.createElement('tr');data.columns.forEach(c=>{const td=document.createElement('td');const v=row[c];td.textContent=(v===null||v===undefined)?'':String(v);tr.appendChild(td)});tbody.appendChild(tr)});
 table.appendChild(tbody);wrap.appendChild(table);dispatches.appendChild(wrap);
}
goMap.textContent='Ver tanques y surtidores →'; goMap.onclick=()=>{if(sessionId&&selectedDatabase) location.href='/mapa-vivo?sessionId='+encodeURIComponent(sessionId)+'&database='+encodeURIComponent(selectedDatabase)};
</script>
</body></html>
"@
}

try {
    $profile = Load-SqlProfile
    if($null -ne $profile){
        $savedPassword = Unprotect-ProfilePassword -Profile $profile
        $restored = Open-SqlSession -Server ([string]$profile.server) -Auth ([string]$profile.auth) -User ([string]$profile.user) -Password $savedPassword
        $savedDb = [string]$profile.database
        if(-not [string]::IsNullOrWhiteSpace($savedDb) -and $restored.databases -contains $savedDb){
            $Sessions[$restored.sessionId]["database"] = $savedDb
        }
        Write-Host "Conexion SQL restaurada: $([string]$profile.server) / $savedDb"
    }
} catch {
    $script:LastRestoreError = $_.Exception.Message
    Write-Host "No se pudo restaurar la conexion SQL guardada: $script:LastRestoreError"
}

try {
    $statusState = Ensure-ActiveSession
    if($null -ne $statusState){
        Write-ServiceStatus -State "running-connected" -Database ([string]$statusState.database) -Server ([string]$statusState.server) -User ([string]$statusState.user)
    } else {
        Write-ServiceStatus -State "running-no-sql" -ErrorMessage ([string]$script:LastRestoreError)
    }
} catch {
    Write-ServiceStatus -State "running-no-sql" -ErrorMessage $_.Exception.Message
}

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback,$Port)
$listener.Start()
Write-Host "Capitan Rodolfo local v$Version escuchando en http://127.0.0.1:$Port/"

try {
  while($true){
    $client = $listener.AcceptTcpClient()
    try {
      $stream = $client.GetStream()
      $req = Read-Request -Stream $stream
      if($null -eq $req){ continue }
      $script:CurrentOrigin = ""
      if($req.Headers.ContainsKey('origin')){ $script:CurrentOrigin = [string]$req.Headers['origin'] }

      $pathOnly = ($req.Path -split '\?')[0]
      if($req.Method -eq 'OPTIONS'){
        Send-Response $stream 204 'text/plain' ''
      }
      elseif($req.Method -eq 'GET' -and $pathOnly -eq '/health'){
        $st = Ensure-ActiveSession
        $db = ""
        if($null -ne $st){ $db = [string]$st.database }
        Send-Json $stream 200 @{ok=$true;service='Capitan Rodolfo Local';version=$Version;mode='background';scheduledTask=$TaskName;statusFile=$ServiceStatusPath;profileSaved=(Test-Path $ProfilePath);connected=($null -ne $st);database=$db}
      }
      elseif($req.Method -eq 'GET' -and $pathOnly -eq '/api/profile-status'){
        $p = Load-SqlProfile
        if($null -eq $p){
          Send-Json $stream 200 @{saved=$false;server='';auth='sql';user='';database='';hasPassword=$false}
        } else {
          Send-Json $stream 200 @{
            saved=$true
            server=[string]$p.server
            auth=[string]$p.auth
            user=[string]$p.user
            database=[string]$p.database
            hasPassword=(-not [string]::IsNullOrWhiteSpace([string]$p.passwordProtected))
          }
        }
      }
      elseif($req.Method -eq 'POST' -and $pathOnly -eq '/api/reconnect-saved'){
        try {
          $p = Load-SqlProfile
          if($null -eq $p){ throw 'No hay una conexión SQL guardada en este equipo.' }
          $savedPassword = Unprotect-ProfilePassword -Profile $p
          $state = Open-SqlSession -Server ([string]$p.server) -Auth ([string]$p.auth) -User ([string]$p.user) -Password $savedPassword
          $savedDb = [string]$p.database
          if(-not [string]::IsNullOrWhiteSpace($savedDb) -and $state.databases -contains $savedDb){
            $Sessions[$state.sessionId]["database"] = $savedDb
          }
          $script:LastRestoreError = ''
          Write-ServiceStatus -State 'running-connected' -Database $savedDb -Server ([string]$p.server) -User ([string]$p.user)
          Send-Json $stream 200 @{sessionId=$state.sessionId;server=$state.server;auth=$state.auth;user=$state.user;databases=$state.databases;database=$savedDb;restored=$true}
        } catch {
          $script:LastRestoreError = $_.Exception.Message
          Write-ServiceStatus -State 'running-no-sql' -ErrorMessage $script:LastRestoreError
          Send-Json $stream 500 @{error=$_.Exception.Message}
        }
      }
      elseif($req.Method -eq 'GET' -and $pathOnly -eq '/api/openai/status'){
        Send-Json $stream 200 @{configured=(-not [string]::IsNullOrWhiteSpace((Get-OpenAIKey)));defaultEngine='openai';model='gpt-realtime-2.1'}
      }
      elseif($req.Method -eq 'POST' -and $pathOnly -eq '/api/openai/config'){
        try {$data=$req.Body|ConvertFrom-Json;Save-OpenAIKey -ApiKey ([string]$data.apiKey);Send-Json $stream 200 @{ok=$true;configured=$true;defaultEngine='openai'}} catch {Send-Json $stream 400 @{error=$_.Exception.Message}}
      }
      elseif($req.Method -eq 'POST' -and $pathOnly -eq '/api/openai/realtime-secret'){
        try {$key=Get-OpenAIKey;if([string]::IsNullOrWhiteSpace($key)){throw 'Configurá la clave de OpenAI en Núcleo → Inteligencia.'};Send-Json $stream 200 (New-OpenAIRealtimeSecret -ApiKey $key)} catch {Send-Json $stream 500 @{error=$_.Exception.Message}}
      }
      elseif($req.Method -eq 'POST' -and $pathOnly -eq '/api/ai/sql-read'){
        try {$data=$req.Body|ConvertFrom-Json;Send-Json $stream 200 (Invoke-ReadOnlySql -SessionId ([string]$data.sessionId) -Database ([string]$data.database) -Sql ([string]$data.sql))} catch {Send-Json $stream 400 @{error=$_.Exception.Message}}
      }
      elseif($req.Method -eq 'GET' -and $pathOnly -eq '/api/station-summary'){
        try {
          $state = Ensure-ActiveSession
          if($null -eq $state -or [string]::IsNullOrWhiteSpace([string]$state.database)){
            Send-Json $stream 200 @{
              connected=$false
              bridge=$true
              serviceMode='background'
              scheduledTask=$TaskName
              statusFile=$ServiceStatusPath
              profileSaved=(Test-Path $ProfilePath)
              restoreError=[string]$script:LastRestoreError
            }
            continue
          }
          $cn = $Sessions[$state.sessionId].connection
          $cn.ChangeDatabase([string]$state.database)

          $q = $cn.CreateCommand()
          $q.CommandText = "IF OBJECT_ID('dbo.Tanque') IS NULL SELECT 0 ELSE SELECT COUNT(*) FROM dbo.Tanque"
          $tankCount = [int]$q.ExecuteScalar()

          $q = $cn.CreateCommand()
          $q.CommandText = "IF OBJECT_ID('dbo.Surtan') IS NULL SELECT 0 ELSE SELECT COUNT(*) FROM dbo.Surtan"
          $hoseCount = [int]$q.ExecuteScalar()

          $q = $cn.CreateCommand()
          $q.CommandText = "IF OBJECT_ID('dbo.Surtan') IS NULL OR COL_LENGTH('dbo.Surtan','SURTIDOR') IS NULL SELECT 0 ELSE EXEC('SELECT COUNT(DISTINCT SURTIDOR) FROM dbo.Surtan WHERE SURTIDOR IS NOT NULL')"
          $pumpCount = [int]$q.ExecuteScalar()

          $q = $cn.CreateCommand()
          $q.CommandText = "IF OBJECT_ID('dbo.Despachos') IS NULL SELECT 0 AS cantidad,CAST(0 AS decimal(18,2)) AS litros,CAST(0 AS decimal(18,2)) AS pesos ELSE SELECT COUNT(*) cantidad,ISNULL(SUM(CAST(Litros AS decimal(18,2))),0) litros,ISNULL(SUM(CAST(pesos AS decimal(18,2))),0) pesos FROM dbo.Despachos"
          $rdr = $q.ExecuteReader()
          $dispatchCount = 0; $liters = 0; $pesos = 0
          if($rdr.Read()){
            $dispatchCount = [int]$rdr["cantidad"]
            $liters = [decimal]$rdr["litros"]
            $pesos = [decimal]$rdr["pesos"]
          }
          $rdr.Close()

          Send-Json $stream 200 @{
            connected=$true
            bridge=$true
            serviceMode='background'
            scheduledTask=$TaskName
            statusFile=$ServiceStatusPath
            database=[string]$state.database
            server=[string]$state.server
            tankCount=$tankCount
            hoseCount=$hoseCount
            pumpCount=$pumpCount
            dispatchCount=$dispatchCount
            liters=$liters
            pesos=$pesos
          }
        } catch {
          Send-Json $stream 500 @{error=$_.Exception.Message}
        }
      }
      elseif($req.Method -eq 'GET' -and $pathOnly -eq '/api/tanks'){
        try {
          $state = Ensure-ActiveSession
          if($null -eq $state -or [string]::IsNullOrWhiteSpace([string]$state.database)){
            Send-Json $stream 200 @{connected=$false}
            continue
          }

          $cn = $Sessions[$state.sessionId].connection
          $cn.ChangeDatabase([string]$state.database)

          $existsCmd = $cn.CreateCommand()
          $existsCmd.CommandText = "SELECT CASE WHEN OBJECT_ID('dbo.Tanque','U') IS NULL THEN 0 ELSE 1 END"
          $tableExists = ([int]$existsCmd.ExecuteScalar() -eq 1)
          if(-not $tableExists){
            Send-Json $stream 200 @{connected=$true;database=[string]$state.database;table='dbo.Tanque';tableExists=$false;columns=@();rowCount=0;rows=@()}
            continue
          }

          $q = $cn.CreateCommand()
          $q.CommandText = "SELECT TOP (200) * FROM dbo.Tanque"
          $q.CommandTimeout = 15
          $rdr = $q.ExecuteReader()
          try {
            $columns = New-Object System.Collections.Generic.List[string]
            for($i=0;$i -lt $rdr.FieldCount;$i++){ $columns.Add($rdr.GetName($i)) }

            $rows = New-Object System.Collections.Generic.List[object]
            while($rdr.Read()){
              $row = [ordered]@{}
              for($i=0;$i -lt $rdr.FieldCount;$i++){
                $value = $rdr.GetValue($i)
                if($value -is [DBNull]){ $value = $null }
                $row[$rdr.GetName($i)] = $value
              }
              $rows.Add([pscustomobject]$row)
            }

            Send-Json $stream 200 @{
              connected=$true
              database=[string]$state.database
              table='dbo.Tanque'
              tableExists=$true
              columns=$columns
              rowCount=$rows.Count
              rows=$rows
            }
          } finally {
            $rdr.Close()
          }
        } catch {
          Send-Json $stream 500 @{error=$_.Exception.Message}
        }
      }
      elseif($req.Method -eq 'GET' -and $pathOnly -eq '/api/state'){
        $state = Ensure-ActiveSession
        if($null -eq $state){
          Send-Json $stream 200 @{connected=$false}
        } else {
          Send-Json $stream 200 @{connected=$true;sessionId=$state.sessionId;server=$state.server;auth=$state.auth;user=$state.user;databases=$state.databases;database=$state.database}
        }
      }
      elseif($req.Method -eq 'GET' -and ($pathOnly -eq '/' -or $pathOnly -eq '/index.html')){
        Send-Response $stream 200 "text/html; charset=utf-8" (Get-HomeHtml)
      }
      elseif($req.Method -eq 'GET' -and $pathOnly -eq '/mapa-vivo'){
        try {
          $query = [System.Web.HttpUtility]::ParseQueryString(([uri]("http://127.0.0.1" + $req.Path)).Query)
          $sid = [string]$query['sessionId']
          $database = [string]$query['database']
          if(-not $Sessions.ContainsKey($sid)){ throw "Sesion SQL no valida." }
          $sess = $Sessions[$sid]
          if($sess.databases -notcontains $database){ throw "Base no autorizada." }

          $cn = $sess.connection
          $cn.ChangeDatabase($database)

          $dispatchIdColumn = $null
          $idMetaCmd = $cn.CreateCommand()
          $idMetaCmd.CommandText = @"
SELECT TOP 1 c.name
FROM sys.columns c
WHERE c.object_id = OBJECT_ID('dbo.Despachos')
  AND (
    LOWER(REPLACE(c.name,'_','')) IN ('iddespacho','iddespcho')
    OR LOWER(c.name) LIKE '%id%desp%'
    OR LOWER(c.name) LIKE '%desp%id%'
  )
ORDER BY CASE WHEN LOWER(REPLACE(c.name,'_',''))='iddespacho' THEN 0
              WHEN LOWER(REPLACE(c.name,'_',''))='iddespcho' THEN 1
              ELSE 2 END, c.column_id;
"@
          $dispatchIdValue = $idMetaCmd.ExecuteScalar()
          if($null -ne $dispatchIdValue -and $dispatchIdValue -isnot [DBNull]){
            $dispatchIdColumn = [string]$dispatchIdValue
          }

          $dispatchIdSelect = "NULL AS id_despacho"
          if(-not [string]::IsNullOrWhiteSpace($dispatchIdColumn)){
            $dispatchIdSelect = "d.[" + $dispatchIdColumn.Replace("]","]]") + "] AS id_despacho"
          }

          $cmd = $cn.CreateCommand()
          $cmd.CommandText = "SELECT " + $dispatchIdSelect + ", id_sale venta, surtidor, manguera, d.codart, p.descriimpresion, Litros, PPU, pesos, d.Ultime fecha, Ultime as hora FROM Despachos d INNER JOIN prod p ON d.codart = p.codart;"
          $reader = $cmd.ExecuteReader()
          $dispatchRows = New-Object System.Collections.Generic.List[object]
          while($reader.Read()){
            $dispatchRows.Add([pscustomobject]@{
              id_despacho = if($reader["id_despacho"] -is [DBNull]){""}else{[string]$reader["id_despacho"]}
              venta = if($reader["venta"] -is [DBNull]){""}else{[string]$reader["venta"]}
              surtidor = if($reader["surtidor"] -is [DBNull]){""}else{[string]$reader["surtidor"]}
              manguera = if($reader["manguera"] -is [DBNull]){""}else{[string]$reader["manguera"]}
              codart = if($reader["codart"] -is [DBNull]){""}else{[string]$reader["codart"]}
              producto = if($reader["descriimpresion"] -is [DBNull]){""}else{[string]$reader["descriimpresion"]}
              litros = if($reader["Litros"] -is [DBNull]){""}else{[string]$reader["Litros"]}
              ppu = if($reader["PPU"] -is [DBNull]){""}else{[string]$reader["PPU"]}
              pesos = if($reader["pesos"] -is [DBNull]){""}else{[string]$reader["pesos"]}
              fecha = if($reader["fecha"] -is [DBNull]){""}elseif($reader["fecha"] -is [DateTime]){([DateTime]$reader["fecha"]).ToString("dd/MM/yyyy HH:mm:ss")}else{[string]$reader["fecha"]}
              hora = if($reader["hora"] -is [DBNull]){""}elseif($reader["hora"] -is [DateTime]){([DateTime]$reader["hora"]).ToString("HH:mm:ss")}else{[string]$reader["hora"]}
            })
          }
          $reader.Close()

          $tankCmd = $cn.CreateCommand()
          $tankCmd.CommandText = "SELECT t.N_TANQUE, t.DENOMINACION, p.DESCRIIMPRESION, t.CAPACIDAD FROM Tanque t INNER JOIN prod p ON t.CODART = p.codart;"
          $tankReader = $tankCmd.ExecuteReader()
          $tankRows = New-Object System.Collections.Generic.List[object]
          while($tankReader.Read()){
            $tankRows.Add([pscustomobject]@{
              numero = if($tankReader["N_TANQUE"] -is [DBNull]){""}else{[string]$tankReader["N_TANQUE"]}
              denominacion = if($tankReader["DENOMINACION"] -is [DBNull]){""}else{[string]$tankReader["DENOMINACION"]}
              producto = if($tankReader["DESCRIIMPRESION"] -is [DBNull]){""}else{[string]$tankReader["DESCRIIMPRESION"]}
              capacidad = if($tankReader["CAPACIDAD"] -is [DBNull]){""}else{[string]$tankReader["CAPACIDAD"]}
            })
          }
          $tankReader.Close()
          $tankCount = $tankRows.Count

          $hoseSurtidorSelect = "NULL"
          $hoseMetaCmd = $cn.CreateCommand()
          $hoseMetaCmd.CommandText = "SELECT COUNT(*) FROM sys.columns WHERE object_id=OBJECT_ID('dbo.Surtan') AND UPPER(name)='SURTIDOR';"
          if(([int]$hoseMetaCmd.ExecuteScalar()) -gt 0){ $hoseSurtidorSelect = "s.SURTIDOR" }
          $hoseCmd = $cn.CreateCommand()
          $hoseCmd.CommandText = "SELECT s.N_TANQUE, t.DENOMINACION, " + $hoseSurtidorSelect + " AS SURTIDOR, s.MANGUERA, p.DESCRIIMPRESION FROM Surtan s INNER JOIN Tanque t ON s.N_TANQUE = t.N_TANQUE INNER JOIN prod p ON s.CODART = p.Codart;"
          $hoseReader = $hoseCmd.ExecuteReader()
          $hoseRows = New-Object System.Collections.Generic.List[object]
          while($hoseReader.Read()){
            $hoseRows.Add([pscustomobject]@{
              tanque = if($hoseReader["N_TANQUE"] -is [DBNull]){""}else{[string]$hoseReader["N_TANQUE"]}
              denominacion = if($hoseReader["DENOMINACION"] -is [DBNull]){""}else{[string]$hoseReader["DENOMINACION"]}
              surtidor = if($hoseReader["SURTIDOR"] -is [DBNull]){""}else{[string]$hoseReader["SURTIDOR"]}
              manguera = if($hoseReader["MANGUERA"] -is [DBNull]){""}else{[string]$hoseReader["MANGUERA"]}
              producto = if($hoseReader["DESCRIIMPRESION"] -is [DBNull]){""}else{[string]$hoseReader["DESCRIIMPRESION"]}
            })
          }
          $hoseReader.Close()
          $hoseCount = $hoseRows.Count

          $realSurtidores = @($hoseRows | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.surtidor) } | ForEach-Object { [string]$_.surtidor } | Sort-Object -Unique)
          $surtidorCountText = if($realSurtidores.Count -gt 0){ [string]$realSurtidores.Count } else { "?" }

          $hoseCards = ""
          foreach($h in $hoseRows){
            $ht = [System.Net.WebUtility]::HtmlEncode([string]$h.tanque)
            $hd = [System.Net.WebUtility]::HtmlEncode([string]$h.denominacion)
            $hs = [System.Net.WebUtility]::HtmlEncode([string]$h.surtidor)
            $hm = [System.Net.WebUtility]::HtmlEncode([string]$h.manguera)
            $hp = [System.Net.WebUtility]::HtmlEncode([string]$h.producto)
            $surtidorLabel = if([string]::IsNullOrWhiteSpace($hs)){ "S?" } else { "S$hs" }
            $hoseCards += "<div class='hoseRow'><b>T$ht</b><span class='arrow'>&rarr;</span><strong>$surtidorLabel</strong><span class='arrow'>&rarr;</span><strong>M$hm</strong><span class='hoseProduct'>$hp</span><small>$hd</small></div>"
          }
          if([string]::IsNullOrWhiteSpace($hoseCards)){
            $hoseCards = "<div class='empty'>Sin relaciones Tanque → Surtidor → Manguera para mostrar.</div>"
          }

          $tankCards = ""
          foreach($t in $tankRows){
            $tn = [System.Net.WebUtility]::HtmlEncode([string]$t.numero)
            $td = [System.Net.WebUtility]::HtmlEncode([string]$t.denominacion)
            $tp = [System.Net.WebUtility]::HtmlEncode([string]$t.producto)
            $tc = [System.Net.WebUtility]::HtmlEncode([string]$t.capacidad)
            $tankHoses = @($hoseRows | Where-Object { [string]$_.tanque -eq [string]$t.numero })
            $tankHoseText = ""
            foreach($th in $tankHoses){
              if($tankHoseText){ $tankHoseText += " | " }
              $tankHoseText += "S$([System.Net.WebUtility]::HtmlEncode([string]$th.surtidor)) / M$([System.Net.WebUtility]::HtmlEncode([string]$th.manguera)) - $([System.Net.WebUtility]::HtmlEncode([string]$th.producto))"
            }
            if(-not $tankHoseText){ $tankHoseText = "Sin mangueras asociadas" }
            $tankCards += "<button type='button' class='tankRow tankPick' data-num='$tn' data-den='$td' data-prod='$tp' data-cap='$tc' data-hoses='$tankHoseText'><b>T$tn</b><span class='tankName'>$td</span><span class='tankProduct'>$tp</span><strong>$tc L</strong></button>"
          }
          if([string]::IsNullOrWhiteSpace($tankCards)){
            $tankCards = "<div class='empty'>Sin tanques para mostrar.</div>"
          }

          $safeDb = [System.Net.WebUtility]::HtmlEncode($database)
          $cards = ""
          foreach($d in $dispatchRows){
            $idDespacho = [System.Net.WebUtility]::HtmlEncode([string]$d.id_despacho)
            $venta = [System.Net.WebUtility]::HtmlEncode([string]$d.venta)
            $surt = [System.Net.WebUtility]::HtmlEncode([string]$d.surtidor)
            $mang = [System.Net.WebUtility]::HtmlEncode([string]$d.manguera)
            $prod = [System.Net.WebUtility]::HtmlEncode([string]$d.producto)
            $lit = [System.Net.WebUtility]::HtmlEncode([string]$d.litros)
            $ppu = [System.Net.WebUtility]::HtmlEncode([string]$d.ppu)
            $pes = [System.Net.WebUtility]::HtmlEncode([string]$d.pesos)
            $hora = [System.Net.WebUtility]::HtmlEncode([string]$d.hora)
            $cards += "<button type='button' class='dispatchRow salePick' data-id-despacho='$idDespacho' data-venta='$venta' data-surtidor='$surt' data-manguera='$mang' data-producto='$prod' data-litros='$lit' data-ppu='$ppu' data-pesos='$pes' data-hora='$hora'><b>#$venta</b><span>Surt. $surt - Mang. $mang</span><span class='product'>$prod</span><span>$lit L - PPU $ppu - <strong>&#36;$pes</strong></span><small>$hora</small></button>"
          }
          if([string]::IsNullOrWhiteSpace($cards)){
            $cards = "<div class='empty'>Sin despachos para mostrar.</div>"
          }
          $dispatchCount = $dispatchRows.Count

          $html = @"
<!doctype html>
<html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Mapa Vivo - Capitan Rodolfo</title>
<style>
:root{--bg:#050b12;--panel:#09141e;--line:#254154;--orange:#ff7138;--cyan:#2dd9ff;--green:#34f5a5;--text:#eaf6ff;--muted:#7ea2bb}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font-family:Segoe UI,Arial,sans-serif}
.top{display:flex;justify-content:space-between;align-items:center;gap:12px;padding:12px 18px;background:#07111a;border-bottom:1px solid var(--line);position:sticky;top:0;z-index:5}
.left{display:flex;align-items:center;gap:12px;flex-wrap:wrap}.badge{background:#11212c;border:1px solid #2b5267;border-radius:999px;padding:7px 11px;font-size:12px}.ok{color:var(--green)}.ver{color:#061116;background:var(--orange);border-radius:999px;padding:6px 9px;font-size:12px;font-weight:900}.navlink{color:#ccefff;text-decoration:none;border:1px solid #2b5267;border-radius:999px;padding:7px 11px;font-size:12px;font-weight:800}.navlink:hover{border-color:#2dd9ff;color:#fff}
.stage{padding:14px}.mapWrap{position:relative;max-width:1600px;margin:auto}.mapWrap>img{display:block;width:100%;height:auto;border:1px solid #173244;border-radius:18px;background:#050b12}
.dispatchOverlay{position:absolute;left:64.4%;top:60.4%;width:31.3%;height:18.5%;background:#07131df7;border:2px solid #2dd9ff;border-radius:18px;padding:12px 14px;overflow:hidden;box-shadow:0 8px 24px #0009}
.dispatchTitle{display:flex;justify-content:space-between;gap:10px;align-items:center;margin-bottom:8px;font-size:12px;letter-spacing:2px;color:#89a9bd}.dispatchTitle strong{color:#eaf6ff;letter-spacing:0}
.dispatchList{height:calc(100% - 28px);overflow:auto;padding-right:5px}.dispatchRow{display:grid;width:100%;grid-template-columns:auto auto 1fr auto auto;gap:8px;align-items:center;border:0;border-bottom:1px solid #173244;padding:6px 0;font-size:11px;white-space:nowrap;background:transparent;color:#eaf6ff;text-align:left;cursor:pointer}.dispatchRow:hover,.dispatchRow.active{background:#0d2633}.dispatchRow b{color:#34f5a5}.dispatchRow .product{overflow:hidden;text-overflow:ellipsis}.dispatchRow strong{color:#ffb06a}.dispatchRow small{color:#7ea2bb}.empty{color:#7ea2bb;padding:14px 0}
.tankOverlay{position:absolute;left:26.3%;top:31%;width:19.5%;max-height:31%;background:#09141ef2;border:2px solid #ff7138;border-radius:16px;padding:10px 12px;overflow:hidden;box-shadow:0 8px 24px #0009}
.tankTitle{display:flex;justify-content:space-between;align-items:center;gap:8px;margin-bottom:7px;font-size:11px;letter-spacing:2px;color:#89a9bd}.tankTitle strong{color:#eaf6ff;letter-spacing:0}
.tankList{max-height:210px;overflow:auto;padding-right:4px}.tankRow{display:grid;width:100%;grid-template-columns:auto 1fr auto;gap:6px;align-items:center;border:0;border-bottom:1px solid #173244;padding:5px 0;font-size:10px;background:transparent;color:#eaf6ff;text-align:left;cursor:pointer}.tankRow:hover,.tankRow.active{background:#2a1710}.tankRow b{color:#ff9d2e}.tankName{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.tankProduct{grid-column:1/-1;color:#7ea2bb;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.tankRow strong{color:#2dd9ff}
.hoseOverlay{position:absolute;left:46%;top:26%;width:17%;max-height:28%;background:#07131df2;border:2px solid #34f5a5;border-radius:16px;padding:10px 12px;overflow:hidden;box-shadow:0 8px 24px #0009}
.hoseTitle{display:flex;justify-content:space-between;align-items:center;gap:8px;margin-bottom:7px;font-size:10px;letter-spacing:1.5px;color:#89a9bd}.hoseTitle strong{color:#eaf6ff;letter-spacing:0}
.hoseList{max-height:180px;overflow:auto;padding-right:4px}.hoseRow{display:grid;grid-template-columns:auto auto auto auto auto 1fr;gap:5px;align-items:center;border-bottom:1px solid #173244;padding:5px 0;font-size:10px}.hoseRow b{color:#ff9d2e}.hoseRow strong{color:#34f5a5}.hoseRow .arrow{color:#2dd9ff}.hoseProduct{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.hoseRow small{grid-column:1/-1;color:#7ea2bb;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.tankHotspot{position:absolute;left:26.2%;top:23.8%;width:18.8%;height:6.5%;border:1px dashed #ff7138;background:#ff713812;color:#ffb06a;border-radius:10px;cursor:pointer;font-weight:900;letter-spacing:2px;z-index:3}
.hoseHotspot{position:absolute;left:46%;top:18%;width:17%;height:6.5%;border:1px dashed #34f5a5;background:#34f5a512;color:#8fffd0;border-radius:10px;cursor:pointer;font-weight:900;letter-spacing:1.4px;z-index:3}
.dispatchHotspot{position:absolute;left:70%;top:55%;width:22%;height:5.5%;border:1px dashed #2dd9ff;background:#2dd9ff12;color:#8fefff;border-radius:10px;cursor:pointer;font-weight:900;letter-spacing:1.2px;z-index:3}
.parentClose{border:0;background:transparent;color:#fff;cursor:pointer;font-size:15px;font-weight:900;padding:0 3px;margin:0;width:auto}
.detailCard{position:absolute;z-index:6;background:#07131df7;border:2px solid #ff7138;border-radius:16px;padding:12px 14px;box-shadow:0 10px 30px #000b;display:none}.detailCard.show{display:block}
#tankDetail{left:27%;top:64%;width:30%}#saleOnPump{left:50.3%;top:30%;width:20%;border-color:#34f5a5}
.detailTitle{font-size:11px;letter-spacing:1.5px;color:#89a9bd;margin-bottom:8px}.detailGrid{display:grid;grid-template-columns:auto 1fr;gap:6px 10px;font-size:12px}.detailGrid b{color:#fff}.detailGrid span{color:#8fb3c9}.detailClose{position:absolute;right:8px;top:7px;border:0;background:transparent;color:#fff;cursor:pointer;font-size:16px}
.paymentBtn{width:100%;margin-top:12px;border:0;border-radius:10px;padding:10px 12px;background:linear-gradient(135deg,#ff7138,#ff9d2e);color:#101010;font-weight:900;cursor:pointer}
#paymentPanel{left:50.3%;top:54%;width:20%;border-color:#ff7138}
.paymentPending{color:#ffb06a;font-size:12px;line-height:1.5}
.pumpCountBadge{position:absolute;left:48.7%;top:19.2%;z-index:4;background:#07131de8;border:1px solid #2dd9ff;color:#b9efff;border-radius:999px;padding:7px 11px;font-size:11px;font-weight:900;letter-spacing:1px}.pumpCountBadge strong{color:#fff}
.truckHotspot{position:absolute;left:3.5%;top:34%;width:23%;height:31%;z-index:4;border:1px solid transparent;background:transparent;border-radius:18px;cursor:pointer;color:transparent}.truckHotspot:hover{border-color:#ff7138;background:#ff71380c;box-shadow:0 0 26px #ff713833}.truckHotspot.feed{animation:truckFeedPulse .75s ease}
@keyframes truckFeedPulse{0%,100%{box-shadow:none}45%{box-shadow:0 0 0 10px #ff713822,0 0 38px #ff713888}}
.receiptModal{position:fixed;inset:0;z-index:60;display:none;place-items:center;background:#000b;padding:18px}.receiptModal.show{display:grid}
.receiptBox{width:min(650px,94vw);max-height:90vh;overflow:auto;background:#101820;border:1px solid #2d4759;border-radius:20px;padding:22px;box-shadow:0 30px 80px #000c;position:relative}.receiptBox h2{margin:0 0 8px}.receiptBox p{color:#8fb3c9;line-height:1.5}
.receiptClose{position:absolute;right:12px;top:10px;width:auto;margin:0;border:0;background:transparent;color:#fff;font-size:22px;cursor:pointer}
.receiptUpload{display:block;border:1px dashed #ff7138;background:#ff71380d;border-radius:14px;padding:18px;text-align:center;font-weight:900;cursor:pointer}.receiptUpload input{display:none}
.receiptStatus{margin-top:12px;border:1px solid #29495e;border-radius:11px;padding:10px;color:#a8c6d8;font-size:12px}.receiptStatus.ok{border-color:#247450;color:#8df0b8}.receiptStatus.bad{border-color:#7c3131;color:#ffb2b2}
.receiptPreview{margin-top:12px;border:1px solid #29495e;border-radius:12px;padding:10px;display:none}.receiptPreview.show{display:block}.receiptPreview img{max-width:100%;max-height:260px;display:block;margin:auto;border-radius:8px}.receiptPreview .pdf{padding:18px;text-align:center;color:#ffb06a;font-weight:900}
.revalLogin{display:none;margin-top:14px;padding:14px;border:1px solid #67482c;border-radius:12px;background:#1b1510}.revalLogin.show{display:block}.revalLogin input{width:100%;margin-top:7px;padding:11px;border-radius:9px;border:1px solid #3b4650;background:#091018;color:#fff}.revalLogin button{width:100%;margin-top:10px;padding:11px;border:0;border-radius:9px;background:#ff7138;font-weight:900;cursor:pointer}
.receiptResult{display:none;margin-top:14px}.receiptResult.show{display:block}
.invoice-paper{background:#fff;color:#1c2330;border-radius:14px;overflow:hidden;box-shadow:0 16px 50px #0008;border:1px solid #dfe5ea;font-family:Segoe UI,Arial,sans-serif}
.invoice-head{display:flex;justify-content:space-between;gap:16px;padding:18px 20px;border-bottom:1px solid #e4e8ec;background:linear-gradient(135deg,#fbfcfd,#f1f5f7)}
.invoice-head span{font-size:10px;letter-spacing:1.6px;color:#718092;font-weight:900}.invoice-head h3{margin:5px 0 3px;color:#17202b;font-size:19px}.invoice-head p{margin:0;color:#667483;font-size:11px}
.invoice-type{text-align:right}.invoice-type b{display:block;color:#ff5a3d;font-size:16px}.invoice-type small{display:block;margin-top:5px;color:#667483}
.invoice-meta{display:grid;grid-template-columns:repeat(3,1fr);gap:1px;background:#e6eaee}.invoice-meta>div{background:#fff;padding:11px 14px}.invoice-meta span,.invoice-footer span,.document-flow span{display:block;color:#788797;font-size:9px;text-transform:uppercase;letter-spacing:1px}.invoice-meta b{display:block;margin-top:3px;font-size:12px}
.document-flow{display:grid;grid-template-columns:1fr auto 1fr;gap:10px;align-items:center;padding:14px 18px;border-bottom:1px solid #e5e9ed}.document-flow b{display:block;margin:4px 0;font-size:12px}.document-flow small{display:block;color:#778491;font-size:10px}.flow-arrow{font-size:22px;color:#ff5a3d;font-weight:900}
.invoice-lines{padding:14px 18px}.invoice-line{display:grid;grid-template-columns:1fr 70px 95px 95px;gap:8px;padding:7px 0;border-bottom:1px solid #edf0f2;font-size:10px}.invoice-line-head{font-weight:900;color:#718092;text-transform:uppercase;letter-spacing:.7px}.invoice-line span:not(:first-child){text-align:right}
.invoice-totals{padding:10px 18px 14px;margin-left:auto;width:min(360px,100%)}.invoice-totals>div{display:flex;justify-content:space-between;gap:16px;padding:5px 0;color:#566473;font-size:11px}.invoice-grand{margin-top:5px;padding-top:10px!important;border-top:2px solid #1d2630;color:#111!important;font-size:15px!important}.invoice-grand b{color:#ff5a3d;font-size:18px}
.invoice-footer{display:grid;grid-template-columns:1fr 1fr;gap:12px;padding:12px 18px;background:#f5f7f8;border-top:1px solid #e5e9ed}.invoice-footer b{display:block;color:#273443;margin-top:3px;font-size:10px}
.invoice-empty{padding:16px;color:#667483;text-align:center;font-size:11px}
@media(max-width:650px){.invoice-line{grid-template-columns:1fr 48px 70px 75px;font-size:9px}.invoice-head{padding:14px}.invoice-meta{grid-template-columns:1fr}.invoice-footer{grid-template-columns:1fr}}
.receiptFly{position:fixed;z-index:90;width:180px;padding:10px;border:2px solid #ff7138;border-radius:12px;background:#fff;color:#111;font-weight:900;font-size:11px;box-shadow:0 12px 30px #0008;pointer-events:none;transition:transform .78s cubic-bezier(.2,.8,.2,1),opacity .78s ease;transform-origin:center}
.note{padding:0 18px 18px;color:var(--muted);font-size:13px}
@media(max-width:900px){.dispatchOverlay,.tankOverlay,.hoseOverlay,.detailCard{position:static;width:auto;height:auto;max-height:none;margin-top:12px}.tankHotspot,.hoseHotspot,.dispatchHotspot,.truckHotspot{display:none}.pumpCountBadge{position:static;display:inline-block;margin:8px 0}.tankList,.hoseList{max-height:260px}.dispatchRow{grid-template-columns:1fr 1fr}.dispatchRow .product{grid-column:1/-1}.detailCard{display:none}.detailCard.show{display:block}}
</style></head>
<body>
<header class="top"><div class="left"><a class="navlink" href="http://127.0.0.1:8790/">← DoingLio</a><a class="navlink" href="http://127.0.0.1:8790/capitan-rodolfo/index.html">← Capitán</a><span class="badge ok"><span style="color:#34f5a5">&#9679;</span> SQL conectado</span><span class="badge">Base: $safeDb</span></div><span class="ver">v$Version</span></header>
<main class="stage">
  <div class="mapWrap">
    <img src="http://127.0.0.1:8790/capitan-rodolfo/assets/capitan-rodolfo-mapa-vivo.svg" alt="Mapa Vivo de Capitan Rodolfo">
    <button id="truckHotspot" class="truckHotspot" type="button" title="Subir comprobante al camion" aria-label="Subir comprobante al camion">CAMION</button>
    <div class="pumpCountBadge">SURTIDORES (<strong>$surtidorCountText</strong>)</div>
    <button id="tankHotspot" class="tankHotspot" type="button">TANQUES ($tankCount)</button>
    <section id="tankPanel" class="tankOverlay" style="display:none">
      <div class="tankTitle"><span>TANQUES REALES</span><span><strong>$tankCount</strong> <button id="closeTankPanel" class="parentClose" type="button">x</button></span></div>
      <div class="tankList">$tankCards</div>
    </section>
    <button id="hoseHotspot" class="hoseHotspot" type="button">TANQUE &rarr; SURTIDOR &rarr; MANGUERA ($hoseCount)</button>
    <section id="hosePanel" class="hoseOverlay" style="display:none">
      <div class="hoseTitle"><span>TANQUE &rarr; SURTIDOR &rarr; MANGUERA</span><span><strong>$hoseCount</strong> <button id="closeHosePanel" class="parentClose" type="button">x</button></span></div>
      <div class="hoseList">$hoseCards</div>
    </section>
    <button id="dispatchHotspot" class="dispatchHotspot" type="button" style="display:none">VENTAS / DESPACHOS ($dispatchCount)</button>
    <section id="dispatchPanel" class="dispatchOverlay">
      <div class="dispatchTitle"><span>VENTAS / DESPACHOS</span><span><strong>$dispatchCount</strong> <button id="closeDispatchPanel" class="parentClose" type="button">x</button></span></div>
      <div class="dispatchList">$cards</div>
    </section>
    <section id="tankDetail" class="detailCard">
      <button class="detailClose" type="button" data-close="tankDetail">x</button>
      <div class="detailTitle">DETALLE DEL TANQUE</div>
      <div id="tankDetailBody" class="detailGrid"></div>
    </section>
    <section id="saleOnPump" class="detailCard">
      <button class="detailClose" type="button" data-close="saleOnPump">x</button>
      <div id="salePumpTitle" class="detailTitle">VENTA EN SURTIDOR</div>
      <div id="salePumpBody" class="detailGrid"></div>
      <button id="viewPaymentBtn" class="paymentBtn" type="button">VER PAGO</button>
    </section>
    <section id="paymentPanel" class="detailCard">
      <button class="detailClose" type="button" data-close="paymentPanel">x</button>
      <div class="detailTitle">PAGO DE LA VENTA</div>
      <div id="paymentBody" class="detailGrid"></div>
      <div class="paymentPending">Consulta de pago pendiente de definir. No se muestran datos inventados.</div>
    </section>
  </div>
</main>
<div id="receiptModal" class="receiptModal">
  <section class="receiptBox">
    <button id="receiptClose" class="receiptClose" type="button">x</button>
    <h2>Comprobante del camion</h2>
    <p>Subi una factura, recibo, transferencia, ticket o PDF. El camion recibe el archivo y Revalsoft IA lo analiza con la misma logica de TEST.</p>
    <label id="receiptUploadLabel" class="receiptUpload">SUBIR COMPROBANTE
      <input id="receiptFile" type="file" accept="image/*,.pdf">
    </label>
    <div id="receiptStatus" class="receiptStatus">Esperando archivo...</div>
    <div id="receiptPreview" class="receiptPreview"></div>
    <div id="revalLogin" class="revalLogin">
      <b>Iniciar sesion Revalsoft IA</b>
      <div style="font-size:12px;color:#b69c84;margin-top:4px">Se pide solo si este navegador local todavia no tiene una sesion valida.</div>
      <input id="revalEmail" type="email" autocomplete="username" placeholder="Email">
      <input id="revalPassword" type="password" autocomplete="current-password" placeholder="Contrasena">
      <button id="revalLoginBtn" type="button">INGRESAR Y ANALIZAR</button>
    </div>
    <div id="receiptResult" class="receiptResult">
      <h3>Comprobante analizado</h3>
      <div id="receiptResultBody" class="receiptResultGrid"></div>
    </div>
  </section>
</div>
<div class="note">Las ventanas padre controlan a sus hijas: al cerrar TANQUES se cierra el detalle; al cerrar VENTAS / DESPACHOS se cierran la venta seleccionada y VER PAGO.</div>
<script>
(function(){
  const tankPanel=document.getElementById('tankPanel');
  const tankHotspot=document.getElementById('tankHotspot');
  const hosePanel=document.getElementById('hosePanel');
  const hoseHotspot=document.getElementById('hoseHotspot');
  const closeTankPanel=document.getElementById('closeTankPanel');
  const closeHosePanel=document.getElementById('closeHosePanel');
  const dispatchPanel=document.getElementById('dispatchPanel');
  const dispatchHotspot=document.getElementById('dispatchHotspot');
  const closeDispatchPanel=document.getElementById('closeDispatchPanel');
  const tankDetail=document.getElementById('tankDetail');
  const tankBody=document.getElementById('tankDetailBody');
  const saleCard=document.getElementById('saleOnPump');
  const saleBody=document.getElementById('salePumpBody');
  const saleTitle=document.getElementById('salePumpTitle');
  const viewPaymentBtn=document.getElementById('viewPaymentBtn');
  const paymentPanel=document.getElementById('paymentPanel');
  const paymentBody=document.getElementById('paymentBody');
  const truckHotspot=document.getElementById('truckHotspot');
  const receiptModal=document.getElementById('receiptModal');
  const receiptClose=document.getElementById('receiptClose');
  const receiptFile=document.getElementById('receiptFile');
  const receiptUploadLabel=document.getElementById('receiptUploadLabel');
  const receiptStatus=document.getElementById('receiptStatus');
  const receiptPreview=document.getElementById('receiptPreview');
  const revalLogin=document.getElementById('revalLogin');
  const revalEmail=document.getElementById('revalEmail');
  const revalPassword=document.getElementById('revalPassword');
  const revalLoginBtn=document.getElementById('revalLoginBtn');
  const receiptResult=document.getElementById('receiptResult');
  const receiptResultBody=document.getElementById('receiptResultBody');
  const SB_URL='https://apqgrwudkfytwikrsivd.supabase.co';
  const SB_KEY='sb_publishable_B9NdjnzOKu9BhZGmTM6LGg_wDB3n8lY';
  let pendingReceipt=null;
  let selectedSale=null;

  function closeTankHierarchy(){
    tankPanel.style.display='none';
    tankDetail.classList.remove('show');
    document.querySelectorAll('.tankPick').forEach(x=>x.classList.remove('active'));
  }
  function closeSaleHierarchy(){
    dispatchPanel.style.display='none';
    dispatchHotspot.style.display='block';
    saleCard.classList.remove('show');
    paymentPanel.classList.remove('show');
    selectedSale=null;
    document.querySelectorAll('.salePick').forEach(x=>x.classList.remove('active'));
  }

  if(tankHotspot){
    tankHotspot.addEventListener('click',()=>{
      if(tankPanel.style.display==='none'){
        tankPanel.style.display='block';
      }else{
        closeTankHierarchy();
      }
    });
  }
  if(closeTankPanel){ closeTankPanel.addEventListener('click',closeTankHierarchy); }

  if(hoseHotspot){
    hoseHotspot.addEventListener('click',()=>{ hosePanel.style.display=(hosePanel.style.display==='none')?'block':'none'; });
  }
  if(closeHosePanel){ closeHosePanel.addEventListener('click',()=>{hosePanel.style.display='none';}); }

  if(closeDispatchPanel){ closeDispatchPanel.addEventListener('click',closeSaleHierarchy); }
  if(dispatchHotspot){
    dispatchHotspot.addEventListener('click',()=>{
      dispatchPanel.style.display='block';
      dispatchHotspot.style.display='none';
    });
  }

  document.querySelectorAll('.tankPick').forEach(btn=>{
    btn.addEventListener('click',()=>{
      document.querySelectorAll('.tankPick').forEach(x=>x.classList.remove('active')); btn.classList.add('active');
      tankBody.innerHTML=
        '<span>Tanque</span><b>'+btn.dataset.num+'</b>'+
        '<span>Denominacion</span><b>'+btn.dataset.den+'</b>'+
        '<span>Producto</span><b>'+btn.dataset.prod+'</b>'+
        '<span>Capacidad</span><b>'+btn.dataset.cap+' L</b>'+
        '<span>Mangueras</span><b>'+btn.dataset.hoses+'</b>';
      tankDetail.classList.add('show');
    });
  });

  document.querySelectorAll('.salePick').forEach(btn=>{
    btn.addEventListener('click',()=>{
      document.querySelectorAll('.salePick').forEach(x=>x.classList.remove('active')); btn.classList.add('active');
      selectedSale={
        idDespacho:btn.dataset.idDespacho||'',
        venta:btn.dataset.venta,
        surtidor:btn.dataset.surtidor,
        manguera:btn.dataset.manguera,
        producto:btn.dataset.producto,
        litros:btn.dataset.litros,
        ppu:btn.dataset.ppu,
        pesos:btn.dataset.pesos,
        hora:btn.dataset.hora
      };
      saleTitle.textContent='VENTA #'+btn.dataset.venta+' - SURTIDOR '+btn.dataset.surtidor;
      saleBody.innerHTML=
        '<span>Venta</span><b>#'+btn.dataset.venta+'</b>'+
        '<span>Surtidor</span><b>'+btn.dataset.surtidor+'</b>'+
        '<span>Manguera</span><b>'+btn.dataset.manguera+'</b>'+
        '<span>Producto</span><b>'+btn.dataset.producto+'</b>'+
        '<span>Litros</span><b>'+btn.dataset.litros+' L</b>'+
        '<span>PPU</span><b>'+btn.dataset.ppu+'</b>'+
        '<span>Pesos</span><b>$ '+btn.dataset.pesos+'</b>'+
        '<span>Hora</span><b>'+btn.dataset.hora+'</b>';
      saleCard.classList.add('show');
    });
  });

  if(viewPaymentBtn){
    viewPaymentBtn.addEventListener('click',async()=>{
      if(!selectedSale) return;
      paymentPanel.classList.add('show');
      paymentBody.innerHTML=
        '<span>Venta</span><b>#'+selectedSale.venta+'</b>'+
        '<span>Surtidor</span><b>'+selectedSale.surtidor+'</b>'+
        '<span>Importe</span><b>$ '+selectedSale.pesos+'</b>'+
        '<span>Pago</span><b>Buscando comprobante relacionado...</b>';
      try{
        const r=await fetch('/api/payment',{
          method:'POST',
          headers:{'Content-Type':'application/json'},
          body:JSON.stringify({sessionId:'$sid',database:'$safeDb',idDespacho:selectedSale.idDespacho,venta:selectedSale.venta})
        });
        const d=await r.json();
        if(!r.ok) throw new Error(d.error||('HTTP '+r.status));
        if(!d.resolved){
          paymentBody.innerHTML=
            '<span>Venta</span><b>#'+selectedSale.venta+'</b>'+
            '<span>id_despacho</span><b>'+escHtml(selectedSale.idDespacho||'NO DETECTADO')+'</b>'+
            '<span>Relacion</span><b>No pude resolver automaticamente el comprobante.</b>'+
            '<span>Columnas encontradas</span><b>'+escHtml((d.columns||[]).join(', '))+'</b>'+
            '<span>Detalle</span><b>'+escHtml(d.reason||'Sin detalle')+'</b>';
          return;
        }
        const p=d.payment||{};
        const c=d.comprobante||{};
        paymentBody.innerHTML=
          '<span>Comprobante</span><b>'+escHtml((c.letra||'')+' '+(c.sucursal||'')+'-'+(c.numero||''))+'</b>'+
          '<span>Mercado Pago</span><b>$ '+escHtml(p.MercadoPago||0)+'</b>'+
          '<span>App YPF</span><b>$ '+escHtml(p.AppYPF||0)+'</b>'+
          '<span>Shell Box</span><b>$ '+escHtml(p.ShellBox||0)+'</b>'+
          '<span>App Puma</span><b>$ '+escHtml(p.AppPuma||0)+'</b>'+
          '<span>Clover</span><b>$ '+escHtml(p.Clover||0)+'</b>'+
          '<span>PayWay</span><b>$ '+escHtml(p.PayWay||0)+'</b>'+
          '<span>Cheques</span><b>$ '+escHtml(p.Cheques||0)+'</b>'+
          '<span>Efectivo</span><b>$ '+escHtml(p.Efectivo||0)+'</b>'+
          '<span>Total</span><b>$ '+escHtml(p.TOTAL||selectedSale.pesos||0)+'</b>'+
          '<span>Vendedor</span><b>'+escHtml(p.Vendedor||'-')+'</b>';
        const pending=document.querySelector('#paymentPanel .paymentPending');
        if(pending) pending.textContent='Forma de pago obtenida desde RelacionCptsDespachos y la logica de PA_VentasFormasPago.';
      }catch(e){
        paymentBody.innerHTML=
          '<span>Venta</span><b>#'+selectedSale.venta+'</b>'+
          '<span>Error</span><b>'+escHtml(e.message||'No se pudo obtener la forma de pago')+'</b>';
      }
    });
  }

  function escHtml(v){
    return String(v==null?'':v).replace(/[&<>"']/g,function(ch){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]});
  }

  function setReceiptStatus(message,kind){
    receiptStatus.textContent=message;
    receiptStatus.className='receiptStatus'+(kind?' '+kind:'');
  }

  function readAsDataUrl(file){
    return new Promise(function(resolve,reject){
      const fr=new FileReader();
      fr.onload=function(){resolve(fr.result)};
      fr.onerror=reject;
      fr.readAsDataURL(file);
    });
  }

  async function refreshRevalsoftToken(){
    const refresh=localStorage.getItem('rodolfo.sb.refresh_token');
    if(!refresh) return null;
    try{
      const r=await fetch(SB_URL+'/auth/v1/token?grant_type=refresh_token',{
        method:'POST',
        headers:{'Content-Type':'application/json','apikey':SB_KEY},
        body:JSON.stringify({refresh_token:refresh})
      });
      const d=await r.json();
      if(!r.ok||!d.access_token) return null;
      localStorage.setItem('rodolfo.sb.access_token',d.access_token);
      if(d.refresh_token) localStorage.setItem('rodolfo.sb.refresh_token',d.refresh_token);
      localStorage.setItem('rodolfo.sb.expires_at',String(Date.now()+((d.expires_in||3600)*1000)));
      return d.access_token;
    }catch(_){return null}
  }

  async function getRevalsoftToken(){
    const token=localStorage.getItem('rodolfo.sb.access_token');
    const expires=Number(localStorage.getItem('rodolfo.sb.expires_at')||0);
    if(token && expires>Date.now()+30000) return token;
    return refreshRevalsoftToken();
  }

  async function loginRevalsoft(){
    const email=revalEmail.value.trim();
    const password=revalPassword.value;
    if(!email||!password) throw new Error('Completa email y contrasena.');
    const r=await fetch(SB_URL+'/auth/v1/token?grant_type=password',{
      method:'POST',
      headers:{'Content-Type':'application/json','apikey':SB_KEY},
      body:JSON.stringify({email:email,password:password})
    });
    const d=await r.json();
    if(!r.ok||!d.access_token) throw new Error(d.error_description||d.msg||d.error||'No se pudo iniciar sesion.');
    localStorage.setItem('rodolfo.sb.access_token',d.access_token);
    if(d.refresh_token) localStorage.setItem('rodolfo.sb.refresh_token',d.refresh_token);
    localStorage.setItem('rodolfo.sb.expires_at',String(Date.now()+((d.expires_in||3600)*1000)));
    revalPassword.value='';
    return d.access_token;
  }

  function normalizeKey(value){
    return String(value||'').toLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g,'').replace(/[^a-z0-9]/g,'');
  }
  function findValue(source,names,depth){
    depth=depth||0;
    if(!source||typeof source!=='object'||depth>7) return undefined;
    const wanted=names.map(normalizeKey);
    for(const key of Object.keys(source)){
      const value=source[key];
      if(wanted.includes(normalizeKey(key)) && value!==null && value!=='' && typeof value!=='object') return value;
    }
    for(const value of Object.values(source)){
      const found=findValue(value,names,depth+1);
      if(found!==undefined) return found;
    }
  }
  function findItems(source,depth){
    depth=depth||0;
    if(!source||typeof source!=='object'||depth>7) return [];
    for(const key of Object.keys(source)){
      const value=source[key];
      if(['items','item','detalle','detalles','lineas','conceptos','productos'].includes(normalizeKey(key)) && Array.isArray(value)) return value;
    }
    for(const value of Object.values(source)){
      const found=findItems(value,depth+1);
      if(found.length) return found;
    }
    return [];
  }
  function docText(data,names,fallback){
    const v=findValue(data,names,0);
    return v===undefined?(fallback===undefined?'-':fallback):String(v);
  }
  function docMoney(data,names){
    const value=findValue(data,names,0);
    const raw=String(value==null?'':value).trim();
    const number=Number(raw.replace(/\.(?=\d{3}(?:\D|$))/g,'').replace(',','.').replace(/[^0-9.-]/g,''));
    if(!Number.isFinite(number)||!raw) return '-';
    const currency=docText(data,['moneda'],'ARS')==='USD'?'USD':'ARS';
    try{return new Intl.NumberFormat('es-AR',{style:'currency',currency:currency,maximumFractionDigits:2}).format(number)}
    catch(_){return raw}
  }
  function renderReceiptResult(data){
    const type=docText(data,['tipo_documento','tipoDocumento','tipo_comprobante','tipoComprobante'],'COMPROBANTE').toUpperCase();
    const items=findItems(data,0);
    const isTransfer=type.includes('TRANSFER');
    const isReceipt=type.includes('RECIB');
    const issuer=isTransfer?docText(data,['plataforma'],'Transferencia'):docText(data,['proveedor','emisor','origen_nombre'],type);
    const headerSub=isTransfer
      ? 'Operacion: '+docText(data,['numero_operacion','codigo_identificacion'])
      : 'CUIT: '+docText(data,['proveedor_cuit','emisor_cuit','cuit']);
    let html='<div class="invoice-paper">';
    html+='<div class="invoice-head"><div><span>COMPROBANTE PROCESADO</span><h3>'+escHtml(issuer)+'</h3><p>'+escHtml(headerSub)+'</p></div>';
    html+='<div class="invoice-type"><b>'+escHtml(type)+'</b><small>'+escHtml(docText(data,['numero_comprobante','numero_operacion','numero','nro']))+'</small></div></div>';
    html+='<div class="invoice-meta"><div><span>Fecha</span><b>'+escHtml(docText(data,['fecha','fecha_emision']))+'</b></div><div><span>Hora</span><b>'+escHtml(docText(data,['hora']))+'</b></div><div><span>Moneda</span><b>'+escHtml(docText(data,['moneda'],'ARS'))+'</b></div></div>';
    if(isTransfer){
      html+='<div class="document-flow"><div><span>ORIGEN</span><b>'+escHtml(docText(data,['origen_nombre','emisor']))+'</b><small>'+escHtml(docText(data,['origen_cuit','emisor_cuit']))+'</small><small>'+escHtml(docText(data,['origen_cuenta']))+'</small></div><div class="flow-arrow">&rarr;</div><div><span>DESTINO</span><b>'+escHtml(docText(data,['destino_nombre','receptor']))+'</b><small>'+escHtml(docText(data,['destino_cuit','receptor_cuit']))+'</small><small>'+escHtml(docText(data,['destino_cuenta']))+'</small></div></div>';
    }else if(isReceipt){
      html+='<div class="document-flow"><div><span>RECIBIDO DE</span><b>'+escHtml(docText(data,['emisor','origen_nombre','cliente']))+'</b><small>'+escHtml(docText(data,['emisor_cuit','origen_cuit','cliente_cuit']))+'</small></div><div class="flow-arrow">&rarr;</div><div><span>RECIBIDO POR</span><b>'+escHtml(docText(data,['receptor','destino_nombre','proveedor']))+'</b><small>'+escHtml(docText(data,['receptor_cuit','destino_cuit','proveedor_cuit']))+'</small></div></div>';
    }
    if(items.length){
      html+='<div class="invoice-lines"><div class="invoice-line invoice-line-head"><span>Detalle</span><span>Cant.</span><span>Precio</span><span>Importe</span></div>';
      items.slice(0,10).forEach(function(item){
        html+='<div class="invoice-line"><span>'+escHtml(docText(item,['descripcion','nombre','producto','detalle'],'Item'))+'</span><span>'+escHtml(docText(item,['cantidad','quantity','canti'],'1'))+'</span><span>'+escHtml(docMoney(item,['precio_unitario','precio','price']))+'</span><span>'+escHtml(docMoney(item,['importe','total','subtotal']))+'</span></div>';
      });
      html+='</div>';
    }
    html+='<div class="invoice-totals">';
    if(!isTransfer&&!isReceipt){
      html+='<div><span>Subtotal</span><b>'+escHtml(docMoney(data,['subtotal','neto','importe_neto']))+'</b></div>';
      html+='<div><span>IVA</span><b>'+escHtml(docMoney(data,['total_iva','iva','importe_iva']))+'</b></div>';
      html+='<div><span>Impuestos / percepciones</span><b>'+escHtml(docMoney(data,['percepciones','impuestos','otros_impuestos']))+'</b></div>';
    }
    const totalLabel=isTransfer?'IMPORTE TRANSFERIDO':(isReceipt?'IMPORTE RECIBIDO':'TOTAL');
    html+='<div class="invoice-grand"><span>'+totalLabel+'</span><b>'+escHtml(docMoney(data,['importe','total','importe_total','monto_total']))+'</b></div></div>';
    html+='<div class="invoice-footer">';
    if(isTransfer||isReceipt){
      html+='<span>Medio<b>'+escHtml(docText(data,['medio_pago','plataforma']))+'</b></span><span>Motivo<b>'+escHtml(docText(data,['motivo','observaciones']))+'</b></span>';
    }else{
      html+='<span>CAE<b>'+escHtml(docText(data,['cae']))+'</b></span><span>Vencimiento CAE<b>'+escHtml(docText(data,['cae_vencimiento','vencimiento_cae']))+'</b></span>';
    }
    html+='</div></div>';
    receiptResultBody.innerHTML=html;
    receiptResult.classList.add('show');
  }

  async function analyzeReceipt(file){
    pendingReceipt=file;
    let token=await getRevalsoftToken();
    if(!token){
      revalLogin.classList.add('show');
      setReceiptStatus('Comprobante recibido por el camion. Inicia sesion Revalsoft IA para analizarlo.','ok');
      return;
    }
    revalLogin.classList.remove('show');
    setReceiptStatus('Camion recibio el comprobante. Analizando con Revalsoft IA TEST...');
    const base64=await readAsDataUrl(file);
    let r=await fetch(SB_URL+'/functions/v1/extract-document-json',{
      method:'POST',
      headers:{'Content-Type':'application/json','apikey':SB_KEY,'Authorization':'Bearer '+token},
      body:JSON.stringify({file_name:file.name,mime_type:file.type||'application/octet-stream',base64:base64})
    });
    if(r.status===401){
      localStorage.removeItem('rodolfo.sb.access_token');
      token=await refreshRevalsoftToken();
      if(token){
        r=await fetch(SB_URL+'/functions/v1/extract-document-json',{
          method:'POST',
          headers:{'Content-Type':'application/json','apikey':SB_KEY,'Authorization':'Bearer '+token},
          body:JSON.stringify({file_name:file.name,mime_type:file.type||'application/octet-stream',base64:base64})
        });
      }
    }
    const out=await r.json().catch(function(){return {}});
    if(!r.ok||!out.ok){
      if(r.status===401){
        revalLogin.classList.add('show');
        throw new Error('Sesion Revalsoft IA vencida. Inicia sesion nuevamente.');
      }
      throw new Error(out.error||'No se pudo analizar el comprobante.');
    }
    renderReceiptResult(out.data||{});
    setReceiptStatus('Comprobante analizado correctamente.','ok');
  }

  function animateReceiptToTruck(file){
    return new Promise(function(resolve){
      const source=receiptUploadLabel.getBoundingClientRect();
      const target=truckHotspot.getBoundingClientRect();
      const fly=document.createElement('div');
      fly.className='receiptFly';
      fly.textContent='COMPROBANTE - '+file.name;
      fly.style.left=(source.left+source.width/2-90)+'px';
      fly.style.top=(source.top+source.height/2-20)+'px';
      document.body.appendChild(fly);
      const dx=(target.left+target.width/2)-(source.left+source.width/2);
      const dy=(target.top+target.height/2)-(source.top+source.height/2);
      requestAnimationFrame(function(){
        requestAnimationFrame(function(){
          fly.style.transform='translate('+dx+'px,'+dy+'px) scale(.08) rotate(-10deg)';
          fly.style.opacity='0';
          truckHotspot.classList.add('feed');
        });
      });
      setTimeout(function(){
        fly.remove();
        truckHotspot.classList.remove('feed');
        resolve();
      },820);
    });
  }

  if(truckHotspot){
    truckHotspot.addEventListener('click',function(){
      receiptModal.classList.add('show');
      receiptResult.classList.remove('show');
      setReceiptStatus('Esperando archivo...');
    });
  }

  if(receiptClose){
    receiptClose.addEventListener('click',function(){receiptModal.classList.remove('show')});
  }
  receiptModal.addEventListener('click',function(e){if(e.target===receiptModal)receiptModal.classList.remove('show')});

  if(receiptFile){
    receiptFile.addEventListener('change',async function(){
      const file=receiptFile.files&&receiptFile.files[0];
      if(!file) return;
      pendingReceipt=file;
      receiptResult.classList.remove('show');
      receiptPreview.innerHTML='';
      if(file.type&&file.type.indexOf('image/')===0){
        const img=document.createElement('img');
        img.src=URL.createObjectURL(file);
        img.onload=function(){setTimeout(function(){URL.revokeObjectURL(img.src)},1000)};
        receiptPreview.appendChild(img);
      }else{
        receiptPreview.innerHTML='<div class="pdf">PDF - '+escHtml(file.name)+'</div>';
      }
      receiptPreview.classList.add('show');
      setReceiptStatus(file.name+' - '+(file.size/1024/1024).toFixed(2)+' MB');
      await animateReceiptToTruck(file);
      try{await analyzeReceipt(file)}catch(e){setReceiptStatus(e.message||'Error al analizar.','bad')}
    });
  }

  if(revalLoginBtn){
    revalLoginBtn.addEventListener('click',async function(){
      try{
        revalLoginBtn.disabled=true;
        setReceiptStatus('Iniciando sesion Revalsoft IA...');
        await loginRevalsoft();
        revalLogin.classList.remove('show');
        if(pendingReceipt) await analyzeReceipt(pendingReceipt);
      }catch(e){
        setReceiptStatus(e.message||'No se pudo iniciar sesion.','bad');
      }finally{
        revalLoginBtn.disabled=false;
      }
    });
  }

  document.querySelectorAll('[data-close]').forEach(btn=>{
    btn.addEventListener('click',()=>{
      const id=btn.dataset.close;
      document.getElementById(id).classList.remove('show');
      if(id==='saleOnPump'){
        paymentPanel.classList.remove('show');
        selectedSale=null;
        document.querySelectorAll('.salePick').forEach(x=>x.classList.remove('active'));
      }
    });
  });
})();
</script>
</body></html>
"@
          Send-Response $stream 200 "text/html; charset=utf-8" $html
        } catch {
          Send-Response $stream 401 "text/html; charset=utf-8" "<h2>Sesion SQL no valida</h2><p>$([System.Net.WebUtility]::HtmlEncode($_.Exception.Message))</p><p>Volver a abrir Capitan Rodolfo para reconectar.</p>"
        }
      }
      elseif($req.Method -eq 'POST' -and $pathOnly -eq '/api/connect'){
        try {
          $data = $req.Body | ConvertFrom-Json
          $server = [string]$data.server
          $auth = [string]$data.auth
          $user = [string]$data.user
          $password = [string]$data.password
          if([string]::IsNullOrWhiteSpace($server)){ throw "Completá servidor/instancia." }
          if($auth -eq 'sql' -and [string]::IsNullOrWhiteSpace($password)){
            $saved = Load-SqlProfile
            if($null -ne $saved -and [string]$saved.server -eq $server -and [string]$saved.auth -eq $auth -and [string]$saved.user -eq $user){
              $password = Unprotect-ProfilePassword -Profile $saved
            }
          }

          $state = Open-SqlSession -Server $server -Auth $auth -User $user -Password $password
          Save-SqlProfile -Server $server -Auth $auth -User $user -Password $password -Database ""
          $script:LastRestoreError = ""
          Write-ServiceStatus -State "running-connected" -Database "" -Server $server -User $user
          Send-Json $stream 200 $state
        } catch {
          Send-Json $stream 500 @{error=$_.Exception.Message}
        }
      }
      elseif($req.Method -eq 'POST' -and $pathOnly -eq '/api/tables'){
        try {
          $data = $req.Body | ConvertFrom-Json
          $sid = [string]$data.sessionId
          $database = [string]$data.database
          if(-not $Sessions.ContainsKey($sid)){ Send-Json $stream 401 @{error='Sesion vencida. Volver a conectar.'}; continue }
          $sess = $Sessions[$sid]
          if($sess.databases -notcontains $database){ Send-Json $stream 403 @{error='Base no autorizada.'}; continue }

          $cn = $sess.connection
          $cn.ChangeDatabase($database)
          $cmd = $cn.CreateCommand()
          $cmd.CommandText = @"
SELECT s.name AS esquema, t.name AS tabla
FROM sys.tables AS t
INNER JOIN sys.schemas AS s ON s.schema_id=t.schema_id
ORDER BY s.name,t.name;
"@
          $reader = $cmd.ExecuteReader()
          $rows = @()
          while($reader.Read()){ $rows += @{schema=[string]$reader.GetString(0);name=[string]$reader.GetString(1)} }
          $reader.Close()
          $sess["database"] = $database
          Save-SqlProfile -Server ([string]$sess.server) -Auth ([string]$sess.auth) -User ([string]$sess.user) -Password "" -Database $database
          Write-ServiceStatus -State "running-connected" -Database $database -Server ([string]$sess.server) -User ([string]$sess.user)
          Send-Json $stream 200 @{database=$database;tables=$rows}
        } catch {
          Send-Json $stream 500 @{error=$_.Exception.Message}
        }
      }
      elseif($req.Method -eq 'POST' -and $pathOnly -eq '/api/surpla'){
        try {
          $data = $req.Body | ConvertFrom-Json
          $sid = [string]$data.sessionId
          $database = [string]$data.database
          if(-not $Sessions.ContainsKey($sid)){ Send-Json $stream 401 @{error='Sesion vencida. Volver a conectar.'}; continue }
          $sess = $Sessions[$sid]
          if($sess.databases -notcontains $database){ Send-Json $stream 403 @{error='Base no autorizada.'}; continue }
          $cn = $sess.connection
          $cn.ChangeDatabase($database)
          $cmd = $cn.CreateCommand()
          $cmd.CommandText = 'SELECT * FROM dbo.SURPLA;'
          $cmd.CommandTimeout = 30
          $reader = $cmd.ExecuteReader()
          $columns = @()
          for($i=0;$i -lt $reader.FieldCount;$i++){ $columns += [string]$reader.GetName($i) }
          $rows = @()
          while($reader.Read()){
            $row = [ordered]@{}
            for($i=0;$i -lt $reader.FieldCount;$i++){
              $value = $reader.GetValue($i)
              if($value -is [DBNull]){ $value = $null }
              elseif($value -is [DateTime]){ $value = ([DateTime]$value).ToString('dd/MM/yyyy HH:mm:ss') }
              $row[$columns[$i]] = $value
            }
            $rows += [pscustomobject]$row
          }
          $reader.Close()
          Send-Json $stream 200 @{database=$database;query='SELECT * FROM dbo.SURPLA';columns=$columns;rows=$rows;rowCount=$rows.Count}
        } catch {
          Send-Json $stream 500 @{error=$_.Exception.Message}
        }
      }
      elseif($req.Method -eq 'POST' -and $pathOnly -eq '/api/payment'){
        try {
          $data = $req.Body | ConvertFrom-Json
          $sid = [string]$data.sessionId
          $database = [string]$data.database
          $idDespacho = [string]$data.idDespacho
          if(-not $Sessions.ContainsKey($sid)){ Send-Json $stream 401 @{error='Sesion vencida. Volver a conectar.'}; continue }
          $sess = $Sessions[$sid]
          if($sess.databases -notcontains $database){ Send-Json $stream 403 @{error='Base no autorizada.'}; continue }
          $cn = $sess.connection
          $cn.ChangeDatabase($database)

          $metaCmd = $cn.CreateCommand()
          $metaCmd.CommandText = "SELECT c.name FROM sys.columns c WHERE c.object_id=OBJECT_ID('dbo.RelacionCptsDespachos') ORDER BY c.column_id;"
          $mr = $metaCmd.ExecuteReader()
          $relationColumns = @()
          while($mr.Read()){ $relationColumns += [string]$mr.GetString(0) }
          $mr.Close()
          if($relationColumns.Count -eq 0){
            Send-Json $stream 200 @{resolved=$false;reason='No existe dbo.RelacionCptsDespachos o no tiene columnas visibles.';columns=@()}
            continue
          }

          function Normalize-LocalName([string]$name){
            return ($name.ToLowerInvariant() -replace '[^a-z0-9]','')
          }
          function Pick-RelationColumn($columns,[string[]]$exact,[string[]]$contains){
            foreach($e in $exact){
              foreach($c in $columns){ if((Normalize-LocalName $c) -eq $e){ return $c } }
            }
            foreach($needle in $contains){
              foreach($c in $columns){ if((Normalize-LocalName $c).Contains($needle)){ return $c } }
            }
            return $null
          }

          $dispatchCol = Pick-RelationColumn $relationColumns @('iddespacho','iddespcho') @('iddesp','despachoid','despacho')
          if([string]::IsNullOrWhiteSpace($dispatchCol)){
            Send-Json $stream 200 @{resolved=$false;reason='No pude identificar la columna que relaciona con Despachos.';columns=$relationColumns}
            continue
          }
          if([string]::IsNullOrWhiteSpace($idDespacho)){
            Send-Json $stream 200 @{resolved=$false;reason='El registro de Despachos no expuso su ID interno.';columns=$relationColumns}
            continue
          }

          $relCmd = $cn.CreateCommand()
          $relCmd.CommandText = "SELECT TOP 1 * FROM dbo.RelacionCptsDespachos WHERE ["+$dispatchCol.Replace("]","]]")+"] = @id;"
          $null = $relCmd.Parameters.Add("@id",[System.Data.SqlDbType]::VarChar,100)
          $relCmd.Parameters["@id"].Value = $idDespacho
          $rr = $relCmd.ExecuteReader()
          if(-not $rr.Read()){
            $rr.Close()
            Send-Json $stream 200 @{resolved=$false;reason='No encontre una fila en RelacionCptsDespachos para id_despacho='+$idDespacho;columns=$relationColumns}
            continue
          }
          $rel = @{}
          for($i=0;$i -lt $rr.FieldCount;$i++){
            $name=[string]$rr.GetName($i)
            $val=$rr.GetValue($i)
            if($val -is [DBNull]){ $val=$null }
            $rel[$name]=$val
          }
          $rr.Close()

          $letterCol = Pick-RelationColumn $relationColumns @('letra','letter') @('letracomp','letracpte')
          $branchCol = Pick-RelationColumn $relationColumns @('sucursal','pos') @('sucursalcomp','poscomp')
          $numberCol = Pick-RelationColumn $relationColumns @('ncompro','numero','nrocompro','nrocomprobante','invoicenumber') @('ncompro','numerocomp','nrocomp','invoice')
          $typeCol = Pick-RelationColumn $relationColumns @('tipo','type','tipocpte','tipocomprobante') @('tipocomp','tipocpte')

          $letra = if($letterCol){[string]$rel[$letterCol]}else{''}
          $sucursal = if($branchCol){[string]$rel[$branchCol]}else{''}
          $numero = if($numberCol){[string]$rel[$numberCol]}else{''}
          $tipo = if($typeCol){[string]$rel[$typeCol]}else{''}

          if([string]::IsNullOrWhiteSpace($sucursal) -or [string]::IsNullOrWhiteSpace($numero)){
            Send-Json $stream 200 @{resolved=$false;reason='Encontre la relacion, pero no pude identificar sucursal/numero de comprobante.';columns=$relationColumns;relation=$rel}
            continue
          }

          $isTicket = (($tipo.ToUpperInvariant()).Contains('TICKET') -or $letra.ToUpperInvariant() -eq 'T')
          $payCmd = $cn.CreateCommand()

          if($isTicket){
            $payCmd.CommandText = @"
SELECT TOP 1
 'T' AS letra,
 MT.sucursal,
 MT.Numero AS NCOMPRO,
 MT.turno AS Turno,
 ISNULL(ROUND(MP_O.amount,2),0) AS MercadoPago,
 ISNULL(ROUND(ypf_P.amount,2),0) AS AppYPF,
 ISNULL(ROUND(SH_P.TotalAmount,2),0) AS ShellBox,
 ISNULL(ROUND(PU_P.TotalTransaction-PU_P.Discounts,2),0) AS AppPuma,
 ISNULL(ROUND(C_P.Amount,2),0) AS Clover,
 ISNULL(ROUND(ISNULL(T.IMPORTETAR,0)-ISNULL(T.Extraccion,0),2),0) AS PayWay,
 CAST(0 AS decimal(18,2)) AS Cheques,
 ROUND(MT.TOTAL-(
   ISNULL(ROUND(C_P.Amount,2),0)+ISNULL(ROUND(MP_O.amount,2),0)+ISNULL(ROUND(ypf_P.amount,2),0)+
   ISNULL(ROUND(ISNULL(T.IMPORTETAR,0)-ISNULL(T.Extraccion,0),2),0)+
   ISNULL(ROUND(SH_P.TotalAmount,2),0)+ISNULL(ROUND(PU_P.TotalTransaction,2),0)
 ),2) AS Efectivo,
 MT.TOTAL,
 ISNULL(CAST(MT.Vendedor AS VARCHAR(8)),'0')+' - '+ISNULL(MV.RAZONSOC,'SIN VENDEDOR') AS Vendedor
FROM (
 SELECT Sucursal,Numero,turno,SUM(TOTAL) TOTAL,VENDEDOR
 FROM Maetic
 WHERE Sucursal=@Sucursal AND Numero=@Numero
 GROUP BY Sucursal,Numero,turno,VENDEDOR
) MT
LEFT JOIN MP_OrdenPagoComprobante MP_C ON MT.SUCURSAL=MP_C.Sucursal AND MT.NUMERO=MP_C.Numero AND MP_C.Tipo='TICKET'
LEFT JOIN MP_OrdenPago MP_O ON MP_C.ID_OrdenPago=MP_O.ID
LEFT JOIN YPF_PaymentIntentionComprobante ypf_C ON MT.SUCURSAL=ypf_C.Sucursal AND MT.NUMERO=ypf_C.Numero AND ypf_C.Tipo='TICKET'
LEFT JOIN YPF_PaymentIntention ypf_P ON ypf_P.ID=ypf_C.ID_PaymentIntention
LEFT JOIN Shell_PayOrderComprobante SH_C ON MT.SUCURSAL=SH_C.Sucursal AND MT.NUMERO=SH_C.Numero AND SH_C.Tipo='TICKET'
LEFT JOIN Shell_PayOrder SH_P ON SH_C.PayOrderId=SH_P.ID
LEFT JOIN PUMA_PaymentComprobante PU_C ON MT.SUCURSAL=PU_C.Sucursal AND MT.NUMERO=PU_C.Numero AND PU_C.Tipo='TICKET'
LEFT JOIN PUMA_Payment PU_P ON PU_C.PaymentId=PU_P.ID
LEFT JOIN Tarjet T ON T.Letra='T' AND MT.SUCURSAL=T.Sucursal AND MT.NUMERO=T.NFACT
LEFT JOIN Clover_PaymentInvoices C_PI ON MT.SUCURSAL=C_PI.Pos AND MT.NUMERO=C_PI.InvoiceNumber AND C_PI.Type='TICKET'
LEFT JOIN Clover_Payments C_P ON C_P.Id=C_PI.CloverPaymentId
LEFT JOIN Maeven MV ON MV.VENDEDOR=MT.VENDEDOR;
"@
          } else {
            if([string]::IsNullOrWhiteSpace($letra)){
              Send-Json $stream 200 @{resolved=$false;reason='Encontre sucursal y numero, pero falta letra/tipo para distinguir factura de ticket.';columns=$relationColumns;relation=$rel}
              continue
            }
            $payCmd.CommandText = @"
SELECT TOP 1
 M.letra,M.sucursal,M.NCOMPRO,M.turno AS Turno,
 ISNULL(ROUND(MP_O.amount,2),0.00) AS MercadoPago,
 ISNULL(ROUND(ypf_P.amount,2),0) AS AppYPF,
 ISNULL(ROUND(SH_P.TotalAmount,2),0) AS ShellBox,
 ISNULL(ROUND(PU_P.TotalTransaction-PU_P.Discounts,2),0) AS AppPuma,
 ISNULL(ROUND(C_P.Amount,2),0) AS Clover,
 ISNULL(ROUND(ISNULL(T.IMPORTETAR,0)-ISNULL(T.Extraccion,0),2),0) AS PayWay,
 M.cheques AS Cheques,
 CASE M.CONDVTA WHEN 2 THEN 0 ELSE
 ROUND((M.TOTAL-(
   ISNULL(ROUND(C_P.Amount,2),0)+ISNULL(ROUND(MP_O.amount,2),0)+ISNULL(ROUND(ypf_P.amount,2),0)+
   ISNULL(ROUND(ISNULL(T.IMPORTETAR,0)-ISNULL(T.Extraccion,0),2),0)+
   ISNULL(ROUND(SH_P.TotalAmount,2),0)+ISNULL(ROUND(PU_P.TotalTransaction,2),0)
 )),2) END AS Efectivo,
 M.TOTAL,
 ISNULL(CAST(M.Vendedor AS VARCHAR(8)),'0')+' - '+ISNULL(MV.RAZONSOC,'SIN VENDEDOR') AS Vendedor
FROM Maefac M
LEFT JOIN MP_OrdenPagoComprobante MP_C ON M.LETRA=MP_C.Letra AND M.SUCURSAL=MP_C.Sucursal AND M.NCOMPRO=MP_C.Numero
LEFT JOIN MP_OrdenPago MP_O ON MP_C.ID_OrdenPago=MP_O.ID
LEFT JOIN YPF_PaymentIntentionComprobante ypf_C ON M.LETRA=ypf_C.Letra AND M.SUCURSAL=ypf_C.Sucursal AND M.NCOMPRO=ypf_C.Numero
LEFT JOIN YPF_PaymentIntention ypf_P ON ypf_P.ID=ypf_C.ID_PaymentIntention
LEFT JOIN Tarjet T ON M.LETRA=T.Letra AND M.SUCURSAL=T.Sucursal AND M.NCOMPRO=T.NFACT
LEFT JOIN Shell_PayOrderComprobante SH_C ON M.LETRA=SH_C.Letra AND M.SUCURSAL=SH_C.Sucursal AND M.NCOMPRO=SH_C.Numero
LEFT JOIN Shell_PayOrder SH_P ON SH_C.PayOrderId=SH_P.ID
LEFT JOIN PUMA_PaymentComprobante PU_C ON M.LETRA=PU_C.Letra AND M.SUCURSAL=PU_C.Sucursal AND M.NCOMPRO=PU_C.Numero
LEFT JOIN PUMA_Payment PU_P ON PU_C.PaymentId=PU_P.ID
LEFT JOIN Clover_PaymentInvoices C_PI ON M.SUCURSAL=C_PI.Pos AND M.NCOMPRO=C_PI.InvoiceNumber AND C_PI.Letter=M.LETRA
LEFT JOIN Clover_Payments C_P ON C_P.Id=C_PI.CloverPaymentId
LEFT JOIN Maeven MV ON MV.VENDEDOR=M.VENDEDOR
WHERE M.LETRA=@Letra AND M.SUCURSAL=@Sucursal AND M.NCOMPRO=@Numero;
"@
            $null=$payCmd.Parameters.Add("@Letra",[System.Data.SqlDbType]::VarChar,10)
            $payCmd.Parameters["@Letra"].Value=$letra
          }

          $null=$payCmd.Parameters.Add("@Sucursal",[System.Data.SqlDbType]::VarChar,30)
          $payCmd.Parameters["@Sucursal"].Value=$sucursal
          $null=$payCmd.Parameters.Add("@Numero",[System.Data.SqlDbType]::VarChar,50)
          $payCmd.Parameters["@Numero"].Value=$numero

          $pr=$payCmd.ExecuteReader()
          if(-not $pr.Read()){
            $pr.Close()
            Send-Json $stream 200 @{resolved=$false;reason='La relacion existe, pero no encontre el comprobante en Maefac/Maetic.';columns=$relationColumns;relation=$rel}
            continue
          }
          $payment=@{}
          for($i=0;$i -lt $pr.FieldCount;$i++){
            $name=[string]$pr.GetName($i)
            $val=$pr.GetValue($i)
            if($val -is [DBNull]){$val=0}
            $payment[$name]=$val
          }
          $pr.Close()
          Send-Json $stream 200 @{
            resolved=$true
            dispatchColumn=$dispatchCol
            relation=$rel
            comprobante=@{letra=$letra;sucursal=$sucursal;numero=$numero;tipo=$tipo}
            payment=$payment
          }
        } catch {
          Send-Json $stream 500 @{error=$_.Exception.Message}
        }
      }
      elseif($req.Method -eq 'POST' -and $pathOnly -eq '/api/dispatches'){
        try {
          $data = $req.Body | ConvertFrom-Json
          $sid = [string]$data.sessionId
          $database = [string]$data.database
          if(-not $Sessions.ContainsKey($sid)){ Send-Json $stream 401 @{error='Sesion vencida. Volver a conectar.'}; continue }
          $sess = $Sessions[$sid]
          if($sess.databases -notcontains $database){ Send-Json $stream 403 @{error='Base no autorizada.'}; continue }

          $cn = $sess.connection
          $cn.ChangeDatabase($database)
          $cmd = $cn.CreateCommand()
          $cmd.CommandText = "SELECT id_sale venta, surtidor, manguera, d.codart, p.descriimpresion, Litros, PPU, pesos, d.Ultime fecha, Ultime as hora FROM Despachos d INNER JOIN prod p ON d.codart = p.codart;"
          $reader = $cmd.ExecuteReader()

          $cols = @()
          for($i=0; $i -lt $reader.FieldCount; $i++){ $cols += [string]$reader.GetName($i) }
          $rows = @()
          while($reader.Read()){
            $row = [ordered]@{}
            for($i=0; $i -lt $reader.FieldCount; $i++){
              $v = $reader.GetValue($i)
              if($v -is [System.DBNull]){ $v = $null }
              elseif($v -is [DateTime]){ $v = $v.ToString("yyyy-MM-dd HH:mm:ss") }
              elseif($v -is [byte[]]){ $v = "[binario]" }
              $row[$cols[$i]] = $v
            }
            $rows += [pscustomobject]$row
          }
          $reader.Close()
          Send-Json $stream 200 @{database=$database;columns=$cols;rows=$rows}
        } catch {
          Send-Json $stream 500 @{error=$_.Exception.Message}
        }
      }
      else {
        Send-Json $stream 404 @{error='Ruta no encontrada'}
      }
    } catch {
      try { Send-Json $stream 500 @{error=$_.Exception.Message} } catch {}
    } finally {
      try { $client.Close() } catch {}
    }
  }
}
finally {
  foreach($k in @($Sessions.Keys)){ try { $Sessions[$k].connection.Dispose() } catch {} }
  $listener.Stop()
}
