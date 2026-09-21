param(
  [int]$Port = 8787,
  [string]$DefaultServer = "DUILIO\SQLEXPRESS"
)

$ErrorActionPreference = "Stop"
$Version = "22"
$Sessions = @{}

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
    $headers = "HTTP/1.1 $StatusCode $statusText" + $nl +
      "Content-Type: $ContentType" + $nl +
      "Content-Length: $($bytes.Length)" + $nl +
      "Cache-Control: no-store" + $nl +
      "Connection: close" + $nl + $nl
    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($headers)
    $Stream.Write($headerBytes,0,$headerBytes.Length)
    if($bytes.Length -gt 0){ $Stream.Write($bytes,0,$bytes.Length) }
    $Stream.Flush()
}

function Send-Json {
    param($Stream, [int]$StatusCode, $Object)
    $json = $Object | ConvertTo-Json -Depth 6 -Compress
    Send-Response -Stream $Stream -StatusCode $StatusCode -ContentType "application/json; charset=utf-8" -Body $json
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
        throw "Completá usuario y contraseña SQL."
    }
    $secure = ConvertTo-SecureString $Password -AsPlainText -Force
    $secure.MakeReadOnly()
    $cred = New-Object System.Data.SqlClient.SqlCredential($User,$secure)
    $cn = New-Object System.Data.SqlClient.SqlConnection
    $cn.ConnectionString = "Data Source=$Server;Initial Catalog=master;TrustServerCertificate=True;Connect Timeout=7;"
    $cn.Credential = $cred
    return $cn
}

function Get-HomeHtml {
@"
<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Capitán Rodolfo · SQL local</title>
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
.note{margin-top:15px;font-size:12px;color:var(--muted)}@media(max-width:900px){.grid,.cols{grid-template-columns:1fr}}
</style>
</head>
<body>
<div class="wrap">
<div class="top"><div><strong>DoingLio · CAPITÁN RODOLFO</strong><div class="muted">Conector SQL local</div></div><span class="ver">v22</span></div>
<div class="grid">
<section class="card">
<h1>Conexión SQL</h1>
<div class="muted">Esta pantalla corre dentro de tu PC. No depende de CORS ni del acceso a red local del navegador.</div>
<label>Servidor / instancia</label><input id="server" value="$DefaultServer">
<label>Autenticación</label>
<select id="auth"><option value="sql">Usuario y contraseña SQL Server</option><option value="windows">Windows</option></select>
<div id="sqlCreds"><label>Usuario SQL</label><input id="user"><label>Contraseña</label><input id="password" type="password"></div>
<button id="connect">Conectar y ver bases</button>
<div id="status" class="status">Conector local v22 listo.</div>
<div class="note">La contraseña solo se usa para abrir la conexión SQL y no se guarda en esta página.</div>
</section>
<section class="card">
<div class="cols"><div><h3>Bases</h3><div id="dbs" class="list"><div class="item">Conectate para ver bases</div></div></div><div><h3>Tablas</h3><div id="tables" class="list"><div class="table">Seleccioná una base</div></div></div></div>
</section>
</div>
</div>
<script>
let sessionId=null;
const s=document.getElementById('status'), dbs=document.getElementById('dbs'), tables=document.getElementById('tables');
function status(m,k=''){s.textContent=m;s.className='status '+k}
document.getElementById('auth').onchange=e=>document.getElementById('sqlCreds').style.display=e.target.value==='windows'?'none':'block';
async function api(path,body){
 const r=await fetch(path,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
 const j=await r.json().catch(()=>({})); if(!r.ok) throw new Error(j.error||('HTTP '+r.status)); return j;
}
document.getElementById('connect').onclick=async()=>{
 try{
  status('Conectando…');
  const payload={server:document.getElementById('server').value.trim(),auth:document.getElementById('auth').value,user:document.getElementById('user').value.trim(),password:document.getElementById('password').value};
  const d=await api('/api/connect',payload); sessionId=d.sessionId; status('Conectado a '+d.server+' · elegí una base','ok');
  dbs.innerHTML=''; d.databases.forEach(name=>{const b=document.createElement('button');b.className='item';b.textContent=name;b.onclick=()=>loadTables(name,b);dbs.appendChild(b)});
 }catch(e){status('No se pudo conectar. '+e.message,'bad')}
};
async function loadTables(database,el){
 try{
  [...document.querySelectorAll('#dbs .item')].forEach(x=>x.classList.remove('active'));el.classList.add('active');tables.innerHTML='<div class="table">Cargando…</div>';
  const d=await api('/api/tables',{sessionId,database});tables.innerHTML='';
  d.tables.forEach(x=>{const t=document.createElement('div');t.className='table';t.textContent=x.schema+'.'+x.name;tables.appendChild(t)});
  status('Base '+database+' validada · '+d.tables.length+' tablas','ok');
 }catch(e){status('Error: '+e.message,'bad')}
}
</script>
</body></html>
"@
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

      $pathOnly = ($req.Path -split '\?')[0]
      if($req.Method -eq 'GET' -and $pathOnly -eq '/health'){
        Send-Json $stream 200 @{ok=$true;service='Capitan Rodolfo Local';version=$Version}
      }
      elseif($req.Method -eq 'GET' -and ($pathOnly -eq '/' -or $pathOnly -eq '/index.html')){
        Send-Response $stream 200 "text/html; charset=utf-8" (Get-HomeHtml)
      }
      elseif($req.Method -eq 'POST' -and $pathOnly -eq '/api/connect'){
        try {
          $data = $req.Body | ConvertFrom-Json
          $server = [string]$data.server
          $auth = [string]$data.auth
          $user = [string]$data.user
          $password = [string]$data.password
          if([string]::IsNullOrWhiteSpace($server)){ throw "Completá servidor/instancia." }

          $cn = New-SqlConnection -Server $server -Auth $auth -User $user -Password $password
          $cn.Open()
          $cmd = $cn.CreateCommand()
          $cmd.CommandText = "SELECT name FROM sys.databases WHERE state_desc='ONLINE' AND HAS_DBACCESS(name)=1 ORDER BY name;"
          $reader = $cmd.ExecuteReader()
          $dbs = @()
          while($reader.Read()){ $dbs += [string]$reader.GetString(0) }
          $reader.Close()

          $sid = [guid]::NewGuid().ToString()
          $Sessions[$sid] = @{ connection=$cn; databases=$dbs; server=$server }
          Send-Json $stream 200 @{sessionId=$sid;server=$server;databases=$dbs}
        } catch {
          Send-Json $stream 500 @{error=$_.Exception.Message}
        }
      }
      elseif($req.Method -eq 'POST' -and $pathOnly -eq '/api/tables'){
        try {
          $data = $req.Body | ConvertFrom-Json
          $sid = [string]$data.sessionId
          $database = [string]$data.database
          if(-not $Sessions.ContainsKey($sid)){ Send-Json $stream 401 @{error='Sesión vencida. Volvé a conectar.'}; continue }
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
          Send-Json $stream 200 @{database=$database;tables=$rows}
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
