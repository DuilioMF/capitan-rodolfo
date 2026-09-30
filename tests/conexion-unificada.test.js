const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const read=p=>fs.readFileSync(path.resolve(__dirname,'..',p),'utf8');

test('Principal, Cobros y Datos usan el mismo resolvedor sin base fija',()=>{
  const manager=read('connection-manager.js');
  const index=read('index.html');
  const cobros=read('cobros.js');
  const datos=read('conexion-sql.html');
  assert.match(manager,/version===expected/);
  assert.match(manager,/requiredDatabase===undefined\?null/);
  assert.match(index,/CapitanConnectionManager/);
  assert.match(index,/resolve\(\{requireConnected:true\}\)/);
  assert.match(cobros,/CapitanConnectionManager/);
  assert.match(cobros,/resolve\(\{requireConnected:true\}\)/);
  assert.match(datos,/CapitanConnectionManager/);
  assert.match(datos,/requireConnected:false,requiredDatabase:null/);
});

test('Los endpoints operativos usan exclusivamente state.database de la sesión',()=>{
  const bridge=read('bridge/capitan_rodolfo_local.ps1');
  const ids=bridge.split("elseif($req.Method -eq 'GET' -and $pathOnly -eq '/api/station/ids')")[1]
    .split("elseif($req.Method -eq 'POST' -and $pathOnly -eq '/api/station/payment-sale')")[0];
  const circuit=bridge.split("elseif($req.Method -eq 'POST' -and $pathOnly -eq '/api/station/circuit')")[1]
    .split("elseif($req.Method -eq 'GET' -and $pathOnly -eq '/api/station-summary')")[0];
  assert.match(ids,/\$db=\[string\]\$state\.database/);
  assert.match(ids,/Get-StationOptions -Connection \$cn -Database \$db/);
  assert.match(circuit,/\$dbName=\[string\]\$state\.database/);
  assert.match(circuit,/Get-StationOptions -Connection \$cn -Database \$dbName/);
});

test('El conector expone un estado único cuya base proviene de la sesión',()=>{
  const bridge=read('bridge/capitan_rodolfo_local.ps1');
  assert.match(bridge,/\/api\/capitan\/status/);
  assert.match(bridge,/requiredDatabase=\$db/);
  assert.match(bridge,/operational=\(\$connected -and -not \[string\]::IsNullOrWhiteSpace\(\$db\)\)/);
  assert.match(bridge,/paymentsProcedureAllowed/);
});

test('No hay nombre de base operativo fijado en código de ejecución',()=>{
  const files=['connection-manager.js','index.html','cobros.js','conexion-sql.html',
    'bridge/capitan_rodolfo_local.ps1','sql/PA_CapitanRodolfo_CircuitoEstacion.sql',
    'sql/INSTALAR_Y_HABILITAR_CIRCUITO.sql','sql/DIAGNOSTICO_PERMISOS_CircuitoEstacion.sql'];
  for(const name of files){
    const content=read(name);
    assert.doesNotMatch(content,/SiSRL|Maestros/i,name+' contiene un nombre de base fijo');
  }
});

test('El paquete publicado incluye el resolvedor compartido',()=>{
  for(const workflow of ['.github/workflows/pages.yml','.github/workflows/release-check.yml']){
    assert.match(read(workflow),/connection-manager\.js/);
  }
});
