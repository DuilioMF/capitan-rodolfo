// Fixture de contrato SOLO para CI. Nunca toca BASE_ACTIVA real.
const http=require('node:http');
const failure=process.argv.includes('--fail-payments');
const body=(res,code,data)=>{
 res.writeHead(code,{'content-type':'application/json'});
 res.end(JSON.stringify(data));
};
const server=http.createServer(async(req,res)=>{
 const chunks=[];
 for await(const chunk of req)chunks.push(chunk);
 let data={};try{data=JSON.parse(Buffer.concat(chunks).toString('utf8'))}catch{}
 if(req.url==='/health')return body(res,200,{ok:true,service:'Capitan Rodolfo Local',version:'97',connected:true,database:'BASE_ACTIVA'});
 if(req.url==='/api/state')return body(res,200,{connected:true,database:'BASE_ACTIVA',sessionId:'simulada-ci'});
 if(req.url==='/api/ai/sql-read'){
   if(data.database!=='BASE_ACTIVA'||data.sessionId!=='simulada-ci')return body(res,403,{error:'Sesion/base incorrectas'});
   const q=String(data.sql||'');
   if(q.includes('HAS_PERMS_BY_NAME'))return body(res,200,{rows:[{base:'BASE_ACTIVA',objeto:1,puedeEjecutar:1,puedeVerCodigo:1}]});
   if(q.includes('sys.parameters'))return body(res,200,{rows:[{parameter_id:1,name:'@FechaDesde',tipo:'datetime'}]});
   if(q.includes('sys.sql_modules'))return body(res,200,{rows:[{definition:'CREATE PROCEDURE dbo.PA_VentasFormasPago AS SELECT 1'}]});
   if(q.includes('sys.dm_exec_procedure_stats'))return body(res,200,{rows:[]});
   if(q.includes('sys.sql_expression_dependencies'))return body(res,200,{rows:[]});
   return body(res,400,{error:'Consulta no simulada'});
 }
 if(req.url==='/api/station/ids')return body(res,200,{stations:[1]});
 if(req.url==='/api/station/payments'){
   if(failure)return body(res,422,{error:'SP no disponible en BASE_ACTIVA: permiso EXECUTE faltante'});
   if(data.fechaDesde!=='2026-09-28'||data.fechaHasta!=='2026-09-28'||data.idEstacion!==1)
     return body(res,400,{error:'Parametros erroneos'});
   return body(res,200,{
     database:'BASE_ACTIVA',source:'dbo.PA_VentasFormasPago',fechaDesde:'2026-09-28',
     fechaHasta:'2026-09-28',station:1,version:'97',truncated:false,
     resultSets:[{columns:['LETRA','SUCURSAL','NCOMPRO','MercadoPago','Efectivo'],
       rows:[{LETRA:'B',SUCURSAL:17,NCOMPRO:154291,MercadoPago:30000,Efectivo:0}],truncated:false}]
   });
 }
 if(req.url==='/api/station/today-dispatches')return body(res,200,{
   connected:true,fecha:'2026-09-28',station:1,total:1,
   lastFive:[{IdSale:5781,ESTADOVTA:1}]
 });
 if(req.url==='/api/station/payment-sale')return body(res,200,{
   rows:[{estadoVta:1,letra:'B',sucursal:17,numero:154291}],count:1
 });
 return body(res,404,{error:'NOT_FOUND'});
});
server.listen(8787,'127.0.0.1',()=>console.log('Mock local only ready'));
