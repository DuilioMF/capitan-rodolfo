// Fixture de contrato SOLO para CI. Nunca toca SiSRL real.
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
 if(req.url==='/health')return body(res,200,{ok:true,service:'Capitan Rodolfo Local',version:'94',connected:true,database:'SiSRL'});
 if(req.url==='/api/state')return body(res,200,{connected:true,database:'SiSRL'});
 if(req.url==='/api/station/ids')return body(res,200,{stations:[1]});
 if(req.url==='/api/station/payments'){
   if(failure)return body(res,422,{error:'SP no disponible en SiSRL: permiso EXECUTE faltante'});
   if(data.fechaDesde!=='2026-09-28'||data.fechaHasta!=='2026-09-28'||data.idEstacion!==1)
     return body(res,400,{error:'Parametros erroneos'});
   return body(res,200,{
     database:'SiSRL',source:'dbo.PA_VentasFormasPago',fechaDesde:'2026-09-28',
     fechaHasta:'2026-09-28',station:1,version:'94',truncated:false,
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
