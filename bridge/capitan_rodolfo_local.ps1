param(
  [int]$Port = 8787,
  [string]$DefaultServer = "DUILIO\SQLEXPRESS"
)

$ErrorActionPreference = "Stop"
$Version = "31"
$Sessions = @{}
$ActiveSessionId = $null
$AppDir = Join-Path $env:LOCALAPPDATA "CapitanRodolfo"
$ProfilePath = Join-Path $AppDir "sql_profile.json"
if(-not (Test-Path $AppDir)){ New-Item -ItemType Directory -Path $AppDir -Force | Out-Null }

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
    $enc = ""
    if($Auth -eq "sql" -and -not [string]::IsNullOrWhiteSpace($Password)){
        $enc = ConvertTo-SecureString $Password -AsPlainText -Force | ConvertFrom-SecureString
    } elseif($Auth -eq "sql" -and (Test-Path $ProfilePath)) {
        try { $old = Get-Content $ProfilePath -Raw | ConvertFrom-Json; $enc = [string]$old.password } catch {}
    }
    $obj = [ordered]@{
        server=$Server
        auth=$Auth
        user=$User
        password=$enc
        database=$Database
    }
    $obj | ConvertTo-Json | Set-Content -Path $ProfilePath -Encoding UTF8
}

function Load-SqlProfile {
    if(-not (Test-Path $ProfilePath)){ return $null }
    try { return (Get-Content $ProfilePath -Raw | ConvertFrom-Json) } catch { return $null }
}

function Unprotect-ProfilePassword {
    param($Profile)
    if($null -eq $Profile -or [string]::IsNullOrWhiteSpace([string]$Profile.password)){ return "" }
    try {
        $ss = ConvertTo-SecureString ([string]$Profile.password)
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
        try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    } catch { return "" }
}

function Open-SqlSession {
    param([string]$Server,[string]$Auth,[string]$User,[string]$Password)
    $cn = New-SqlConnection -Server $Server -Auth $Auth -User $User -Password $Password
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
                $p = Load-SqlProfile
                $db = ""
                if($p){ $db = [string]$p.database }
                return @{sessionId=$script:ActiveSessionId;server=$sess.server;auth=$sess.auth;user=$sess.user;databases=$sess.databases;database=$db}
            }
        } catch {}
    }

    $p = Load-SqlProfile
    if($null -eq $p -or [string]::IsNullOrWhiteSpace([string]$p.server)){ return $null }
    $pw = Unprotect-ProfilePassword $p
    try {
        $state = Open-SqlSession -Server ([string]$p.server) -Auth ([string]$p.auth) -User ([string]$p.user) -Password $pw
        $state["database"] = [string]$p.database
        return $state
    } catch {
        return $null
    }
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
<div class="top"><div><strong>DoingLio - CAPITÁN RODOLFO</strong><div class="muted">Conector SQL local</div></div><span class="ver">v31</span></div>
<div class="grid">
<section class="card">
<div class="heroTop">
<div><h1>Conexion SQL</h1><div class="muted">Esta pantalla corre dentro de tu PC. No depende de CORS ni del acceso a red local del navegador.</div></div>
<div class="rodolfoMini" aria-label="Capitan Rodolfo">
  <div class="rCap"></div><div class="rHead"></div><div class="rEye l"></div><div class="rEye r"></div><div class="rMust"></div><div class="rBody"></div><div class="rTie"></div>
</div>
</div>
<label>Servidor / instancia</label><input id="server" value="$DefaultServer">
<label>Autenticacion</label>
<select id="auth"><option value="sql">Usuario y contrasena SQL Server</option><option value="windows">Windows</option></select>
<div id="sqlCreds"><label>Usuario SQL</label><input id="user"><label>Contraseña</label><input id="password" type="password"></div>
<button id="connect">Conectar y ver bases</button>
<div id="status" class="status">Conector local v31 listo.</div>
<button id="goMap" class="continueMap" type="button">Continuar al Mapa Vivo -></button>
<div class="note">La conexión queda recordada en esta PC. Si usás usuario SQL, la contrasena se guarda cifrada por Windows para tu usuario.</div>
</section>
<section class="card">
<div class="cols"><div><h3>Bases</h3><div id="dbs" class="list"><div class="item">Conectate para ver bases</div></div></div><div><h3>Tablas</h3><div id="tables" class="list"><div class="table">Selecciona una base</div></div></div></div>
</section>
</div>
<section class="dispatchCard">
  <div class="dispatchHead"><h2>Despachos abiertos</h2><span class="query">SELECT * FROM Despachos WHERE estadovta = 0</span></div>
  <div id="dispatches" class="muted">Selecciona una base para ver los despachos.</div>
</section>
</div>
<script>
let sessionId=null;
const s=document.getElementById('status'), dbs=document.getElementById('dbs'), tables=document.getElementById('tables'), dispatches=document.getElementById('dispatches'), goMap=document.getElementById('goMap');
let selectedDatabase=null;
function status(m,k=''){s.textContent=m;s.className='status '+k}
document.getElementById('auth').onchange=e=>document.getElementById('sqlCreds').style.display=e.target.value==='windows'?'none':'block';
async function api(path,body){
 const r=await fetch(path,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
 const j=await r.json().catch(()=>({})); if(!r.ok) throw new Error(j.error||('HTTP '+r.status)); return j;
}
async function restoreConnection(){
 try{
  const r=await fetch('/api/state',{cache:'no-store'});
  const d=await r.json();
  if(!d.connected){return}
  sessionId=d.sessionId;
  document.getElementById('server').value=d.server||'';
  document.getElementById('auth').value=d.auth||'sql';
  document.getElementById('user').value=d.user||'';
  document.getElementById('sqlCreds').style.display=(d.auth==='windows')?'none':'block';
  status('Conectado automaticamente a '+d.server,'ok');
  dbs.innerHTML='';
  d.databases.forEach(name=>{
    const b=document.createElement('button');b.className='item';b.textContent=name;b.onclick=()=>loadTables(name,b);dbs.appendChild(b);
    if(d.database && name===d.database){ setTimeout(()=>loadTables(name,b),100); }
  });
 }catch(_){}
}

document.getElementById('connect').onclick=async()=>{
 try{
  status('Conectando…');
  const payload={server:document.getElementById('server').value.trim(),auth:document.getElementById('auth').value,user:document.getElementById('user').value.trim(),password:document.getElementById('password').value};
  const d=await api('/api/connect',payload); sessionId=d.sessionId; status('Conectado a '+d.server+' - elegi una base','ok');
  dbs.innerHTML=''; d.databases.forEach(name=>{const b=document.createElement('button');b.className='item';b.textContent=name;b.onclick=()=>loadTables(name,b);dbs.appendChild(b)});
 }catch(e){status('No se pudo conectar. '+e.message,'bad')}
};
async function loadTables(database,el){
 try{
  selectedDatabase=database;
  [...document.querySelectorAll('#dbs .item')].forEach(x=>x.classList.remove('active'));el.classList.add('active');
  tables.innerHTML='<div class="table">Validando base…</div>';
  const d=await api('/api/tables',{sessionId,database});
  status('Base '+database+' validada - entrando a Capitan Rodolfo…','ok');
  setTimeout(()=>{ location.href='/mapa-vivo?sessionId='+encodeURIComponent(sessionId)+'&database='+encodeURIComponent(database); },350);
 }catch(e){
  status('Error: '+e.message,'bad')
 }
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
goMap.onclick=()=>{if(sessionId&&selectedDatabase) location.href='/mapa-vivo?sessionId='+encodeURIComponent(sessionId)+'&database='+encodeURIComponent(selectedDatabase)};
restoreConnection();
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
      elseif($req.Method -eq 'GET' -and $pathOnly -eq '/api/state'){
        $state = Ensure-ActiveSession
        if($null -eq $state){
          Send-Json $stream 200 @{connected=$false}
        } else {
          Send-Json $stream 200 @{connected=$true;sessionId=$state.sessionId;server=$state.server;auth=$state.auth;user=$state.user;databases=$state.databases;database=$state.database}
        }
      }
      elseif($req.Method -eq 'GET' -and ($pathOnly -eq '/' -or $pathOnly -eq '/index.html')){
        $state = Ensure-ActiveSession
        if($state -and -not [string]::IsNullOrWhiteSpace([string]$state.database)){
          $target = "/mapa-vivo?sessionId=$([uri]::EscapeDataString([string]$state.sessionId))&database=$([uri]::EscapeDataString([string]$state.database))"
          Send-Redirect $stream $target
        } else {
          Send-Response $stream 200 "text/html; charset=utf-8" (Get-HomeHtml)
        }
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
          $cmd = $cn.CreateCommand()
          $cmd.CommandText = "SELECT id_sale venta, surtidor, manguera, d.codart, p.descriimpresion, Litros, PPU, pesos, d.Ultime fecha, Ultime as hora FROM Despachos d INNER JOIN prod p ON d.codart = p.codart;"
          $reader = $cmd.ExecuteReader()
          $dispatchRows = New-Object System.Collections.Generic.List[object]
          while($reader.Read()){
            $dispatchRows.Add([pscustomobject]@{
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

          $hoseCmd = $cn.CreateCommand()
          $hoseCmd.CommandText = "SELECT s.N_TANQUE, t.DENOMINACION, s.MANGUERA, p.DESCRIIMPRESION FROM Surtan s INNER JOIN Tanque t ON s.N_TANQUE = t.N_TANQUE INNER JOIN prod p ON s.CODART = p.Codart;"
          $hoseReader = $hoseCmd.ExecuteReader()
          $hoseRows = New-Object System.Collections.Generic.List[object]
          while($hoseReader.Read()){
            $hoseRows.Add([pscustomobject]@{
              tanque = if($hoseReader["N_TANQUE"] -is [DBNull]){""}else{[string]$hoseReader["N_TANQUE"]}
              denominacion = if($hoseReader["DENOMINACION"] -is [DBNull]){""}else{[string]$hoseReader["DENOMINACION"]}
              manguera = if($hoseReader["MANGUERA"] -is [DBNull]){""}else{[string]$hoseReader["MANGUERA"]}
              producto = if($hoseReader["DESCRIIMPRESION"] -is [DBNull]){""}else{[string]$hoseReader["DESCRIIMPRESION"]}
            })
          }
          $hoseReader.Close()
          $hoseCount = $hoseRows.Count

          $hoseCards = ""
          foreach($h in $hoseRows){
            $ht = [System.Net.WebUtility]::HtmlEncode([string]$h.tanque)
            $hd = [System.Net.WebUtility]::HtmlEncode([string]$h.denominacion)
            $hm = [System.Net.WebUtility]::HtmlEncode([string]$h.manguera)
            $hp = [System.Net.WebUtility]::HtmlEncode([string]$h.producto)
            $hoseCards += "<div class='hoseRow'><b>T$ht</b><span class='arrow'>&rarr;</span><strong>M$hm</strong><span class='hoseProduct'>$hp</span><small>$hd</small></div>"
          }
          if([string]::IsNullOrWhiteSpace($hoseCards)){
            $hoseCards = "<div class='empty'>Sin relaciones tanque/manguera para mostrar.</div>"
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
              $tankHoseText += "M$([System.Net.WebUtility]::HtmlEncode([string]$th.manguera)) - $([System.Net.WebUtility]::HtmlEncode([string]$th.producto))"
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
            $venta = [System.Net.WebUtility]::HtmlEncode([string]$d.venta)
            $surt = [System.Net.WebUtility]::HtmlEncode([string]$d.surtidor)
            $mang = [System.Net.WebUtility]::HtmlEncode([string]$d.manguera)
            $prod = [System.Net.WebUtility]::HtmlEncode([string]$d.producto)
            $lit = [System.Net.WebUtility]::HtmlEncode([string]$d.litros)
            $ppu = [System.Net.WebUtility]::HtmlEncode([string]$d.ppu)
            $pes = [System.Net.WebUtility]::HtmlEncode([string]$d.pesos)
            $hora = [System.Net.WebUtility]::HtmlEncode([string]$d.hora)
            $cards += "<button type='button' class='dispatchRow salePick' data-venta='$venta' data-surtidor='$surt' data-manguera='$mang' data-producto='$prod' data-litros='$lit' data-ppu='$ppu' data-pesos='$pes' data-hora='$hora'><b>#$venta</b><span>Surt. $surt - Mang. $mang</span><span class='product'>$prod</span><span>$lit L - PPU $ppu - <strong>&#36;$pes</strong></span><small>$hora</small></button>"
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
.left{display:flex;align-items:center;gap:12px}.badge{background:#11212c;border:1px solid #2b5267;border-radius:999px;padding:7px 11px;font-size:12px}.ok{color:var(--green)}.ver{color:#061116;background:var(--orange);border-radius:999px;padding:6px 9px;font-size:12px;font-weight:900}
.stage{padding:14px}.mapWrap{position:relative;max-width:1600px;margin:auto}.mapWrap>img{display:block;width:100%;height:auto;border:1px solid #173244;border-radius:18px;background:#050b12}
.dispatchOverlay{position:absolute;left:64.4%;top:60.4%;width:31.3%;height:18.5%;background:#07131df7;border:2px solid #2dd9ff;border-radius:18px;padding:12px 14px;overflow:hidden;box-shadow:0 8px 24px #0009}
.dispatchTitle{display:flex;justify-content:space-between;gap:10px;align-items:center;margin-bottom:8px;font-size:12px;letter-spacing:2px;color:#89a9bd}.dispatchTitle strong{color:#eaf6ff;letter-spacing:0}
.dispatchList{height:calc(100% - 28px);overflow:auto;padding-right:5px}.dispatchRow{display:grid;width:100%;grid-template-columns:auto auto 1fr auto auto;gap:8px;align-items:center;border:0;border-bottom:1px solid #173244;padding:6px 0;font-size:11px;white-space:nowrap;background:transparent;color:#eaf6ff;text-align:left;cursor:pointer}.dispatchRow:hover,.dispatchRow.active{background:#0d2633}.dispatchRow b{color:#34f5a5}.dispatchRow .product{overflow:hidden;text-overflow:ellipsis}.dispatchRow strong{color:#ffb06a}.dispatchRow small{color:#7ea2bb}.empty{color:#7ea2bb;padding:14px 0}
.tankOverlay{position:absolute;left:26.3%;top:31%;width:19.5%;max-height:31%;background:#09141ef2;border:2px solid #ff7138;border-radius:16px;padding:10px 12px;overflow:hidden;box-shadow:0 8px 24px #0009}
.tankTitle{display:flex;justify-content:space-between;align-items:center;gap:8px;margin-bottom:7px;font-size:11px;letter-spacing:2px;color:#89a9bd}.tankTitle strong{color:#eaf6ff;letter-spacing:0}
.tankList{max-height:210px;overflow:auto;padding-right:4px}.tankRow{display:grid;width:100%;grid-template-columns:auto 1fr auto;gap:6px;align-items:center;border:0;border-bottom:1px solid #173244;padding:5px 0;font-size:10px;background:transparent;color:#eaf6ff;text-align:left;cursor:pointer}.tankRow:hover,.tankRow.active{background:#2a1710}.tankRow b{color:#ff9d2e}.tankName{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.tankProduct{grid-column:1/-1;color:#7ea2bb;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.tankRow strong{color:#2dd9ff}
.hoseOverlay{position:absolute;left:46%;top:26%;width:17%;max-height:28%;background:#07131df2;border:2px solid #34f5a5;border-radius:16px;padding:10px 12px;overflow:hidden;box-shadow:0 8px 24px #0009}
.hoseTitle{display:flex;justify-content:space-between;align-items:center;gap:8px;margin-bottom:7px;font-size:10px;letter-spacing:1.5px;color:#89a9bd}.hoseTitle strong{color:#eaf6ff;letter-spacing:0}
.hoseList{max-height:180px;overflow:auto;padding-right:4px}.hoseRow{display:grid;grid-template-columns:auto auto auto 1fr;gap:5px;align-items:center;border-bottom:1px solid #173244;padding:5px 0;font-size:10px}.hoseRow b{color:#ff9d2e}.hoseRow strong{color:#34f5a5}.hoseRow .arrow{color:#2dd9ff}.hoseProduct{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.hoseRow small{grid-column:1/-1;color:#7ea2bb;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
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
.note{padding:0 18px 18px;color:var(--muted);font-size:13px}
@media(max-width:900px){.dispatchOverlay,.tankOverlay,.hoseOverlay,.detailCard{position:static;width:auto;height:auto;max-height:none;margin-top:12px}.tankHotspot,.hoseHotspot,.dispatchHotspot{display:none}.tankList,.hoseList{max-height:260px}.dispatchRow{grid-template-columns:1fr 1fr}.dispatchRow .product{grid-column:1/-1}.detailCard{display:none}.detailCard.show{display:block}}
</style></head>
<body>
<header class="top"><div class="left"><span class="badge ok"><span style="color:#34f5a5">&#9679;</span> SQL conectado</span><span class="badge">Base: $safeDb</span></div><span class="ver">v31</span></header>
<main class="stage">
  <div class="mapWrap">
    <img src="https://duiliomf.github.io/capitan-rodolfo/assets/capitan-rodolfo-mapa-vivo.svg" alt="Mapa Vivo de Capitan Rodolfo">
    <button id="tankHotspot" class="tankHotspot" type="button">TANQUES ($tankCount)</button>
    <section id="tankPanel" class="tankOverlay" style="display:none">
      <div class="tankTitle"><span>TANQUES REALES</span><span><strong>$tankCount</strong> <button id="closeTankPanel" class="parentClose" type="button">x</button></span></div>
      <div class="tankList">$tankCards</div>
    </section>
    <button id="hoseHotspot" class="hoseHotspot" type="button">TANQUE &rarr; MANGUERA ($hoseCount)</button>
    <section id="hosePanel" class="hoseOverlay" style="display:none">
      <div class="hoseTitle"><span>TANQUE &rarr; MANGUERA</span><span><strong>$hoseCount</strong> <button id="closeHosePanel" class="parentClose" type="button">x</button></span></div>
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
    viewPaymentBtn.addEventListener('click',()=>{
      if(!selectedSale) return;
      paymentBody.innerHTML=
        '<span>Venta</span><b>#'+selectedSale.venta+'</b>'+
        '<span>Surtidor</span><b>'+selectedSale.surtidor+'</b>'+
        '<span>Importe</span><b>$ '+selectedSale.pesos+'</b>';
      paymentPanel.classList.add('show');
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

          $state = Open-SqlSession -Server $server -Auth $auth -User $user -Password $password
          Save-SqlProfile -Server $server -Auth $auth -User $user -Password $password -Database ""
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
          $p = Load-SqlProfile
          if($p){ Save-SqlProfile -Server ([string]$p.server) -Auth ([string]$p.auth) -User ([string]$p.user) -Password "" -Database $database }
          Send-Json $stream 200 @{database=$database;tables=$rows}
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
