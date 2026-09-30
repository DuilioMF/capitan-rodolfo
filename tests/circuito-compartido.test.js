const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const bridge=fs.readFileSync('bridge/capitan_rodolfo_local.ps1','utf8');
const worker=fs.readFileSync('bridge/doinglio_sql_queue_worker.ps1','utf8');
const route=bridge.split("elseif($req.Method -eq 'POST' -and $pathOnly -eq '/api/station/circuit'){")[1]?.split("elseif($req.Method -eq 'GET' -and $pathOnly -eq '/api/station-summary'){")[0];
const latest=worker.split('if([string]$job.intent -eq "latest_dispatch"){')[1]?.split('$result=Invoke-RestMethod -Uri ($base+"/api/station/circuit")')[0];
test('Circuito de página y WhatsApp comparten ruta y la base activa de la sesión',()=>{
  assert.ok(route&&latest,'Se localizaron los dos bloques');
  assert.match(route,/\$dbName=\[string\]\$state\.database/);
  assert.match(route,/Get-StationOptions -Connection \$cn -Database \$dbName/);
  assert.match(route,/Invoke-AllowedStoredProcedure -Connection \$cn -Database \$dbName/);
  assert.match(latest,/\$base\+"\/api\/station\/circuit"/);
  assert.doesNotMatch(latest,/latest-dispatch/);
  assert.doesNotMatch(route,/SiSRL|Maestros/i);
});
test('Fallback de lectura verifica estación y fecha, no mezcla datos históricos',()=>{
  assert.match(route,/Get-StationReadOnlyCircuit -Connection \$cn -Database \$dbName -Station \$station/);
  assert.match(route,/\$fallback\['verified'\]=\$true/);
  assert.match(bridge,/AND d\.ULDATE>=@Day AND d\.ULDATE<@NextDay/);
  assert.match(bridge,/\$dispatchSet=Read-StationReadOnlyQuery -Connection \$Connection -Sql \$dispatchSql -Station \$Station -Day \$Day/);
  assert.match(route,/\[int\]\$row\.IdEstacion -ne \$station/);
  assert.match(route,/FechaDespacho\)\.StartsWith\(\$sqlDay\)/);
  assert.match(latest,/\[int\]\$row\.IdEstacion -ne \[int\]\$job\.idEstacion/);
});
test('Respuestas a usuarios no exponen el nombre interno de la base',()=>{
  assert.doesNotMatch(latest,/reply\s*\+=.*database/i);
  assert.match(latest,/Ultimo despacho de los/);
});
