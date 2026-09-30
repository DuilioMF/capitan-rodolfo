const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const read=p=>fs.readFileSync(path.resolve(__dirname,'..',p),'utf8');

test('Principal, Cobros y Datos usan el mismo resolvedor de conexión',()=>{
  const manager=read('connection-manager.js');
  const index=read('index.html');
  const cobros=read('cobros.js');
  const datos=read('conexion-sql.html');
  assert.match(manager,/version===expected/);
  assert.match(manager,/requiredDatabase===undefined\?'SiSRL'/);
  assert.match(index,/CapitanConnectionManager/);
  assert.match(index,/requiredDatabase:'SiSRL'/);
  assert.match(cobros,/CapitanConnectionManager/);
  assert.match(cobros,/requiredDatabase:'SiSRL'/);
  assert.match(datos,/CapitanConnectionManager/);
  assert.match(datos,/requireConnected:false,requiredDatabase:null/);
});

test('Los endpoints operativos de Rodolfo exigen SiSRL',()=>{
  const bridge=read('bridge/capitan_rodolfo_local.ps1');
  const ids=bridge.split("elseif($req.Method -eq 'GET' -and $pathOnly -eq '/api/station/ids')")[1]
    .split("elseif($req.Method -eq 'POST' -and $pathOnly -eq '/api/station/payment-sale')")[0];
  const circuit=bridge.split("elseif($req.Method -eq 'POST' -and $pathOnly -eq '/api/station/circuit')")[1]
    .split("elseif($req.Method -eq 'GET' -and $pathOnly -eq '/api/station-summary')")[0];
  assert.match(ids,/state\.database -ine 'SiSRL'/);
  assert.match(ids,/Database 'SiSRL'/);
  assert.match(circuit,/state\.database -ine 'SiSRL'/);
  assert.match(circuit,/\$dbName='SiSRL'/);
});

test('El conector expone un estado único de Capitán',()=>{
  const bridge=read('bridge/capitan_rodolfo_local.ps1');
  assert.match(bridge,/\/api\/capitan\/status/);
  assert.match(bridge,/requiredDatabase='SiSRL'/);
  assert.match(bridge,/operational=\(\$connected -and \$db -ieq 'SiSRL'\)/);
  assert.match(bridge,/paymentsProcedureAllowed/);
});

test('El paquete publicado incluye el resolvedor compartido',()=>{
  for(const workflow of ['.github/workflows/pages.yml','.github/workflows/release-check.yml']){
    assert.match(read(workflow),/connection-manager\.js/);
  }
});
