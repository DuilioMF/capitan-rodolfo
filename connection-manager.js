/* Capitán Rodolfo · resolvedor único de conexión local SQL. */
(()=>{
'use strict';

const PORTS=[8787,8797,18787,27877,37877,48787,57877];
const isLocalHost=()=>['127.0.0.1','localhost'].includes(location.hostname);
const expectedVersion=()=>{
  const raw=document.body?.dataset?.capitanBuild||'';
  const value=Number.parseInt(String(raw),10);
  if(!Number.isInteger(value)||value<=0)throw new Error('La pantalla no informa una versión válida de Capitán.');
  return value;
};
const candidates=()=>[
  ...(isLocalHost()?[location.origin,location.origin+'/_doinglio_sql']:[]),
  ...PORTS.map(port=>'http://127.0.0.1:'+port)
];
async function localFetch(url,options={}){
  return fetch(url,{
    cache:'no-store',
    ...options,
    ...(isLocalHost()?{}:{targetAddressSpace:'local'})
  });
}
async function probe(base,timeout=1800){
  const ctrl=new AbortController();
  const timer=setTimeout(()=>ctrl.abort(),timeout);
  try{
    const response=await localFetch(base+'/health',{signal:ctrl.signal});
    if(!response.ok)return null;
    const health=await response.json().catch(()=>null);
    if(!health||health.ok!==true||health.service!=='Capitan Rodolfo Local'||health.apiSqlObject!==true)return null;
    return {
      base,
      version:Number.parseInt(String(health.version),10)||0,
      connected:health.connected===true,
      database:String(health.database||''),
      health
    };
  }catch(_){
    return null;
  }finally{
    clearTimeout(timer);
  }
}
async function probeAll(){
  const results=await Promise.all(candidates().map(base=>probe(base)));
  return results.filter(Boolean);
}
function portRank(base){
  try{
    const url=new URL(base);
    if(url.pathname.includes('_doinglio_sql'))return 0;
    const port=Number(url.port);
    const idx=PORTS.indexOf(port);
    return idx<0?999:idx+1;
  }catch(_){return 999}
}
async function resolve(options={}){
  const requireConnected=options.requireConnected!==false;
  const requiredDatabase=options.requiredDatabase===undefined?null:options.requiredDatabase;
  const expected=expectedVersion();
  const all=await probeAll();
  const exact=all.filter(item=>item.version===expected);

  if(!exact.length){
    if(all.length){
      const seen=[...new Set(all.map(item=>'C'+item.version))].join(', ');
      throw new Error('Pantalla C'+expected+' y conector '+seen+' no coinciden. Actualizá el conector desde Núcleo → Datos.');
    }
    throw new Error('No responde el conector SQL local C'+expected+'. Abrí Núcleo → Datos.');
  }

  let usable=exact;
  if(requireConnected)usable=usable.filter(item=>item.connected);
  if(requiredDatabase){
    const wanted=String(requiredDatabase).toLowerCase();
    usable=usable.filter(item=>String(item.database||'').toLowerCase()===wanted);
  }

  if(!usable.length){
    if(requireConnected&&exact.every(item=>!item.connected)){
      throw new Error('Conector C'+expected+' encontrado, pero SQL está desconectado. Abrí Núcleo → Datos.');
    }
    if(requiredDatabase){
      const dbs=[...new Set(exact.filter(item=>item.connected).map(item=>item.database||'sin base'))].join(', ');
      throw new Error('La operación pidió la base '+requiredDatabase+', pero la conexión única está en '+(dbs||'sin base')+'.');
    }
    throw new Error('El conector C'+expected+' no está listo para esta operación.');
  }

  usable.sort((a,b)=>Number(b.connected)-Number(a.connected)||portRank(a.base)-portRank(b.base));
  const selected=usable[0];
  window.capitanSqlBridge=selected.base;
  window.capitanConnectionState=selected;
  return selected;
}

window.CapitanConnectionManager={
  ports:[...PORTS],
  candidates,
  expectedVersion,
  localFetch,
  probeAll,
  resolve
};
})();
