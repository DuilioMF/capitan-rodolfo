// Contrato de versión canónica: cada ventana muestra la versión exacta del HTML y el bridge.
// Pruebas estáticas: no reemplazan la comprobación con SiSRL real.
const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const root=path.resolve(__dirname,'..');
const file=name=>fs.readFileSync(path.join(root,name),'utf8');
const v=file('VERSION').trim();

test('La versión publicada es numérica y cada página marca su propio HTML',()=>{
 assert.match(v,/^\d+$/);
 for(const html of ['index.html','nucleo.html','conexion-sql.html','mapa-vivo.html','documentos.html']){
   assert.ok(file(html).includes('data-capitan-build="'+v+'"'),html+' no identifica el HTML realmente cargado');
 }
 assert.ok(file('index.html').includes('R·'+v),'La portada no indica su versión fija');
 assert.ok(file('nucleo.html').includes('id="nucleoVersion">'+v),'Núcleo desfasado');
 assert.ok(file('conexion-sql.html').includes('DATOS · v'+v),'Datos desfasado');
 assert.ok(file('documentos.html').includes('LECTOR · CAPITÁN v'+v),'Lector desfasado');
});

test('Las 7 ventanas del tablero tienen indicador propio de pantalla y conector',()=>{
 const html=file('index.html');
 const shared=file('theme.js');
 const styles=file('theme.css');
 for(const id of ['truckModal','tankModal','pumpModal','dispatchModal','productModal','receiptModal','paymentsModal']){
   assert.ok(html.includes('id="'+id+'"'),id+' no existe');
 }
 assert.match(shared,/querySelectorAll\('\.tank-modal \.tank-head'\)/);
 assert.match(shared,/badge\.className='capitan-modal-version'/);
 assert.match(styles,/\.capitan-modal-version/);
 assert.match(styles,/\.capitan-version-status/);
});

test('El indicador no confunde pantalla vieja con VERSION publicada ni conector antiguo',()=>{
 const js=file('theme.js');
 for(const fragment of ['dataset.capitanBuild','VERSION?ts=','staleWeb','staleSql',
   "+'/health'","service==='Capitan Rodolfo Local'",
   'ACTUALIZAR CONECTOR','setInterval(checkVersions,60000)']){
   assert.ok(js.includes(fragment),'Falta control de versiones: '+fragment);
 }
 assert.match(js,/capitanSqlBridge/);
 const index=file('index.html');
 assert.ok(index.includes("window.dispatchEvent(new Event('capitan:bridge-changed'))"));
});

test('Todas las páginas comparten JS nuevo; el lector y mapa no dependen de VERSION remoto',()=>{
 for(const page of ['index.html','nucleo.html','conexion-sql.html','mapa-vivo.html']){
   assert.ok(file(page).includes('theme.js?v='+v),page+' usa JS cacheado');
 }
 for(const page of ['index.html','nucleo.html','conexion-sql.html','mapa-vivo.html']){
   assert.ok(file(page).includes('theme.css?v='+v),page+' usa estilos cacheados');
 }
 const index=file('index.html');
 assert.ok(index.includes('cobros.js?v='+v),'Cobros JS desfasado');
 assert.ok(index.includes('cobros.css?v='+v),'Cobros CSS desfasado');
 for(const page of ['documentos.html','mapa-vivo.html']){
   assert.ok(file(page).includes('document.body.dataset.capitanBuild'),page+' usa una versión remota como versión propia');
 }
 assert.ok(file('documentos.html').includes('docConnectorVersion'),'Lector no muestra versión SQL');
});

test('C95: Núcleo no vincula una estación con un conector de otra versión',()=>{
 const page=file('nucleo.html');
 assert.ok(page.includes('found.filter(x=>x.version===Number(document.body.dataset.capitanBuild))'));
 assert.ok(page.includes('no coinciden. Actualizá la pantalla o el conector'));
});
test('El paquete tiene compuerta HTTP y n8n espera el despliegue real',()=>{
 const pages=file('.github/workflows/pages.yml');
 const sync=file('.github/workflows/sync-version.yml');
 assert.ok(pages.includes('Verificar VERSION publicado después de Pages'));
 assert.ok(pages.includes('PUBLIC_VERSION_URL: https://duiliomf.github.io/capitan-rodolfo/VERSION'));
 assert.ok(sync.includes('workflow_run:'),'La sincronización no puede suceder antes del deploy');
 assert.ok(sync.includes('publication_verified'), 'Exigir evidencia de publicación');
});
test('Ninguna de las cinco pantallas mantiene referencias de versión del release anterior',()=>{
 const previous=String(Number(v)-1);
 for(const name of ['index.html','nucleo.html','conexion-sql.html','mapa-vivo.html','documentos.html']){
  const page=file(name);
  assert.ok(!page.includes('data-capitan-build="'+previous+'"'),name+' conserva build anterior');
  assert.ok(!page.includes('theme.js?v='+previous),name+' conserva JS anterior');
  assert.ok(!page.includes('theme.css?v='+previous),name+' conserva CSS anterior');
 }
});
