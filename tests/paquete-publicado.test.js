// Controla el ARTEFACTO generado en CI, no el snapshot antiguo de dist en Git.
const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const read=p=>fs.readFileSync(path.resolve(__dirname,'..',p),'utf8');
const v=read('VERSION').trim();
const pages=['index.html','nucleo.html','conexion-sql.html','mapa-vivo.html','documentos.html'];
const copied=[...pages,'VERSION','theme.css','theme.js','connection-manager.js','cobros.css','cobros.js',
  'CAPITAN_RODOLFO.bat','bridge/capitan_rodolfo_local.ps1','bridge/doinglio_sql_queue_worker.ps1'];
test('Paquete emitido idéntico a las fuentes canónicas del mismo commit',()=>{
 assert.match(v,/^\d+$/);
 for(const file of copied){
   assert.equal(read('dist/'+file),read(file),'Paquete desfasado: '+file);
 }
});
test('Cada pantalla publicada conserva su número de compilación',()=>{
 for(const file of pages){
   const html=read('dist/'+file);
   assert.ok(html.includes('data-capitan-build="'+v+'"'),file+' publica otro número');
 }
});
test('Barra compartida distingue pantalla instalada y servicio SQL',()=>{
 const shared=read('dist/theme.js');
 for(const token of ['dataset.capitanBuild','VERSION?ts=','staleWeb','staleSql',
   'capitan-modal-version','ACTUALIZAR CONECTOR']){
   assert.ok(shared.includes(token),'Falta diagnóstico: '+token);
 }
 const bridge=read('dist/bridge/capitan_rodolfo_local.ps1');
 assert.ok(bridge.includes('Join-Path $AppDir "VERSION"'),'El conector debe leer el VERSION instalado');
});
