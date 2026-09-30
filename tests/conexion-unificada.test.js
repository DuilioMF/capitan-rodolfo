const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const read=p=>fs.readFileSync(path.resolve(__dirname,'..',p),'utf8');
const forbiddenDatabase=['Si','SRL'].join('');

test('Principal, Cobros y Datos usan el mismo resolvedor de conexión',()=>{
  const manager=read('connection-manager.js');
  const index=read('index.html');
  const cobros=read('cobros.js');
  const datos=read('conexion-sql.html');
  assert.match(manager,/version===expected/);
  assert.match(manager,/requiredDatabase===undefined\?null/);
  assert.match(index,/CapitanConnectionManager/);
  assert.match(index,/requiredDatabase:null/);
  assert.match(cobros,/CapitanConnectionManager/);
  assert.match(cobros,/requiredDatabase:null/);
  assert.match(datos,/CapitanConnectionManager/);
  assert.match(datos,/requireConnected:false,requiredDatabase:null/);
});

test('Los endpoints operativos reutilizan la base activa de la sesión',()=>{
  const bridge=read('bridge/capitan_rodolfo_local.ps1');
  assert.ok(!bridge.toLowerCase().includes(forbiddenDatabase.toLowerCase()));
  const ids=bridge.split("elseif($req.Method -eq 'GET' -and $pathOnly -eq '/api/station/ids')")[1]
    .split("elseif($req.Method -eq 'POST' -and $pathOnly -eq '/api/station/payment-sale')")[0];
  const circuit=bridge.split("elseif($req.Method -eq 'POST' -and $pathOnly -eq '/api/station/circuit')")[1]
    .split("elseif($req.Method -eq 'GET' -and $pathOnly -eq '/api/station-summary')")[0];
  assert.match(ids,/\$dbName=\[string\]\$state\.database/);
  assert.match(ids,/Database \$dbName/);
  assert.match(circuit,/\$dbName=\[string\]\$state\.database/);
  assert.match(circuit,/Database \$dbName/);
});

test('El conector expone un único estado y no exige un nombre de base',()=>{
  const bridge=read('bridge/capitan_rodolfo_local.ps1');
  assert.match(bridge,/\/api\/capitan\/status/);
  assert.match(bridge,/requiredDatabase=\$null/);
  assert.match(bridge,/operational=\(\$connected -and -not \[string\]::IsNullOrWhiteSpace\(\$db\)\)/);
  assert.match(bridge,/paymentsProcedureAllowed/);
});

test('El conector Node legado no puede abrir otra conexión SQL',()=>{
  const legacy=read('connector-node/server.js');
  assert.doesNotMatch(legacy,/mssql|ConnectionPool|connectionConfig/);
  assert.match(legacy,/Conector SQL Node retirado/);
});

test('El paquete publicado incluye el resolvedor compartido',()=>{
  for(const workflow of ['.github/workflows/pages.yml','.github/workflows/release-check.yml']){
    assert.match(read(workflow),/connection-manager\.js/);
  }
});


test('C98 abre Capitán local y conserva el diagnóstico técnico aparte',()=>{
  const bat=read('CAPITAN_RODOLFO.bat');
  const bridge=read('bridge/capitan_rodolfo_local.ps1');
  const manager=read('connection-manager.js');
  assert.match(bat,/\/app\//);
  assert.match(bridge,/\/diagnostico/);
  assert.match(bridge,/function Send-AppAsset/);
  assert.match(manager,/location\.origin,location\.origin\+'\/_doinglio_sql'/);
});

test('C98 descubre estaciones sin depender exclusivamente de ParamStock',()=>{
  const bridge=read('bridge/capitan_rodolfo_local.ps1');
  for(const source of ['dbo.ParamStock','dbo.Tanque','dbo.Despachos','dbo.Surpla']){
    assert.ok(bridge.includes(source),source+' no participa del descubrimiento');
  }
});
