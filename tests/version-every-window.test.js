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
