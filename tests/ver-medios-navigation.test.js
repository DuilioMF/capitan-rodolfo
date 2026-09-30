// Regresión v87: el acceso a medios no depende del NCOMPRO del circuito.
// Ejecutar: node --test tests/ver-medios-navigation.test.js
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const root=path.join(__dirname,'..');
const html=fs.readFileSync(path.join(root,'index.html'),'utf8');
const js=fs.readFileSync(path.join(root,'cobros.js'),'utf8');
const bridge=fs.readFileSync(path.join(root,'bridge','capitan_rodolfo_local.ps1'),'utf8');
test('Ver medios permanece habilitado aunque Numero venga vacío',()=>{
 const cell=html.match(/\{label:'Formas de pago',[\s\S]*?hint:'Abrir Cobros[^']*'\}/);
 assert.ok(cell,'falta columna Formas de pago');
 assert.match(cell[0],/value:\(\)=>sale/);
 assert.match(cell[0],/capitanOpenCobrosForDispatch\?\.\(sale\)/);
 assert.doesNotMatch(cell[0],/value:r=>r\.Numero/);
});
test('Cobros abre inmediatamente y consulta el ID_SALE real',()=>{
 assert.match(js,/function openForDispatch\(sale\)/);
 assert.match(js,/\$\('paymentsShiftFrom'\)\.value='0'/);
 assert.match(js,/\$\('paymentsShiftTo'\)\.value='99999'/);
 assert.match(js,/showModal\(\);\s*searchBySale\(\);/);
 assert.match(js,/window\.capitanOpenCobrosForDispatch=openForDispatch/);
});
test('El conector verifica ID_DESPACHO y ULDATE/FECHA antes de atribuir cobros',()=>{
 assert.match(bridge,/pathOnly -eq '\/api\/station\/payment-sale'/);
 assert.match(bridge,/d\.ID_DESPACHO=r\.'\+\$rkey\+' AND d\.ULDATE=r\.FECHA/);
 assert.match(js,/entries\.filter\(r=>Number\(r\.estadoVta\)===1\)/);
 assert.match(js,/invoiceEq\(id\.numero,saleFilter\.numero\)/);
});

test('Cobros comparte exactamente la base activa de la sesión',()=>{
 const evidence=bridge.slice(bridge.indexOf('function Get-VerifiedPaymentEvidence'),bridge.indexOf('function Invoke-AllowedStoredProcedure'));
 assert.match(evidence,/param\(\$Connection,\[string\]\$Database/);
 assert.match(evidence,/ChangeDatabase\(\$Database\)/);
 const payments=bridge.slice(bridge.indexOf("'/api/station/payments'"),bridge.indexOf("'/api/station/today-dispatches'"));
 assert.match(payments,/\$db=\[string\]\$state\.database/);
 assert.match(payments,/-Database \$db -Procedure 'dbo.PA_VentasFormasPago'/);
 assert.doesNotMatch(payments,/SiSRL|Maestros/i);
 assert.doesNotMatch(evidence,/SiSRL|Maestros/i);
});
test('La fecha de Cobros es de Argentina y el SP toma el rango elegido',()=>{
 assert.match(js,/America\/Argentina\/Buenos_Aires/);
 assert.match(js,/fechaDesde:a,fechaHasta:b/);
 assert.ok(js.includes("$('paymentsFrom').value=date[1]"));
 assert.ok(js.includes("$('paymentsTo').value=date[1]"));
});
