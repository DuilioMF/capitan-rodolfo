const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const sql=fs.readFileSync('sql/PA_VentasFormasPago_OPT_PRUEBA_COMPATIBLE.sql','utf8');
const compare=fs.readFileSync('sql/COMPARAR_PA_VentasFormasPago.sql','utf8');
test('SP de prueba no usa sintaxis introducida después de SQL Server 2008',()=>{
 assert.doesNotMatch(sql,/\bCREATE\s+OR\s+ALTER\b|\bTHROW\b/i);
 assert.match(sql,/IF OBJECT_ID\(N'dbo\.PA_VentasFormasPago_OPT_PRUEBA', N'P'\) IS NULL/);
 assert.match(sql,/\bGO\s+ALTER PROCEDURE dbo\.PA_VentasFormasPago_OPT_PRUEBA\b/i);
 assert.match(sql,/\bRAISERROR\s*\(/i);
 assert.match(sql,/\bRETURN\s*;/i);
});
test('Conserva los siete parámetros oficiales y no altera el SP productivo',()=>{
 const def=sql.match(/ALTER PROCEDURE dbo\.PA_VentasFormasPago_OPT_PRUEBA\s*\(([^]*?)\)\s*AS\s*BEGIN/i);
 assert.ok(def,'No aparece la cabecera esperada');
 const names=[...def[1].matchAll(/@(\w+)\s+(?:DATETIME|INT)\b/gi)].map(m=>m[1]);
 assert.deepEqual(names,['FechaDesde','FechaHasta','IdEstacion','TurnoDesde','TurnoHasta','VendedorDesde','VendedorHasta']);
 assert.doesNotMatch(sql,/ALTER\s+PROCEDURE\s+dbo\.PA_VentasFormasPago\s*\(/i);
});
test('Comparación arranca con la versión de prueba y deja el SP lento comentado',()=>{
 assert.match(compare,/SET @FechaDesde='20260928'/);
 assert.match(compare,/SET @IdEstacion=1/);
 assert.match(compare,/SET STATISTICS IO ON/);
 assert.match(compare,/SET STATISTICS TIME ON/);
 assert.match(compare,/EXEC dbo\.PA_VentasFormasPago_OPT_PRUEBA/);
 const begin=compare.indexOf('/* Descomentar');
 const original=compare.indexOf('EXEC dbo.PA_VentasFormasPago',begin);
 const end=compare.indexOf('*/',begin);
 assert.ok(begin>=0&&original>begin&&end>original,'El SP productivo no debe lanzarse automáticamente');
});
