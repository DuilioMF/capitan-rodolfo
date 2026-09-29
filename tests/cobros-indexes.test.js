const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const p='sql/cobros/';
const p1=fs.readFileSync(p+'01_TARJET_PRIMERO.sql','utf8');
const p2=fs.readFileSync(p+'02_Y_VPF_MP_CLOVER_DESPUES.sql','utf8');
const rollback=fs.readFileSync(p+'90_DESHACER_INDICES_COBROS.sql','utf8');
const indexNames=[
 'IX_Tarjet_Cobros_Comprobante',
 'IX_YPF_Cobros_Factura','IX_YPF_Cobros_Ticket',
 'IX_MP_Cobros_Factura','IX_MP_Cobros_Ticket',
 'IX_Clover_Cobros_Comprobante'
];
test('Primera fase: solo crea índice de comprobante Tarjet',()=>{
 assert.match(p1,/USE SiSRL;/i);
 assert.match(p1,/IF NOT EXISTS\s*\(SELECT 1 FROM sys\.indexes/i);
 assert.match(p1,/ON dbo\.Tarjet \(Letra, Sucursal, NFACT\)/i);
 assert.match(p1,/INCLUDE \(IMPORTETAR, Extraccion\)/i);
 assert.equal((p1.match(/CREATE NONCLUSTERED INDEX/ig)||[]).length,1);
});
test('Segunda fase: índices diferencian factura y ticket sin ejecutar SP',()=>{
 assert.match(p2,/ON dbo\.YPF_PaymentIntentionComprobante \(Letra,Sucursal,Numero\)/);
 assert.match(p2,/ON dbo\.YPF_PaymentIntentionComprobante \(Tipo,Sucursal,Numero\)/);
 assert.match(p2,/ON dbo\.MP_OrdenPagoComprobante \(Letra,Sucursal,Numero\)/);
 assert.match(p2,/ON dbo\.MP_OrdenPagoComprobante \(Tipo,Sucursal,Numero\)/);
 assert.match(p2,/ON dbo\.Clover_PaymentInvoices \(Pos,InvoiceNumber\)/);
 assert.equal((p2.match(/CREATE NONCLUSTERED INDEX/ig)||[]).length,5);
});
test('Migraciones no alteran el SP productivo, incluyen prechequeo y rollback',()=>{
 for(const s of [p1,p2]){
   assert.doesNotMatch(s,/\bALTER\s+PROCEDURE\b|\bEXEC(?:UTE)?\s+dbo\.PA_VentasFormasPago\b|\bTRY_CONVERT\b|\bTHROW\b|\bCREATE\s+OR\s+ALTER\b/i);
   assert.match(s,/OBJECT_ID\(/i);
   assert.match(s,/COL_LENGTH\(/i);
 }
 for (const name of indexNames) assert.ok(rollback.includes('DROP INDEX '+name),'falta rollback para '+name);
 assert.equal((rollback.match(/\bDROP INDEX\b/ig)||[]).length,6);
});
