/* Capitán Rodolfo v83 · medios de pago exclusivamente desde SQL autorizado. */
(()=>{
'use strict';
const $=id=>document.getElementById(id);
const methods=[
 {id:'all',name:'Todos',icon:'◎',color:'#f7a348',keys:[]},
 {id:'cash',name:'Efectivo',icon:'$',color:'#55df9a',keys:['Efectivo']},
 {id:'mp',name:'Mercado Pago',icon:'MP',color:'#52a9ff',keys:['MercadoPago','Mercado_Pago']},
 {id:'ypf',name:'App YPF',icon:'YPF',color:'#428dff',keys:['AppYPF','YPF']},
 {id:'clover',name:'Clover',icon:'✤',color:'#86df91',keys:['Clover']},
 {id:'cc',name:'Cuenta Corriente',icon:'▤',color:'#f4f0e6',keys:['CuentaCorriente','CuentasCorrientes']},
 {id:'cards',name:'Tarjetas',icon:'▣',color:'#d4aaff',keys:['Tarjeta','Tarjetas','Tarjet']},
 {id:'payway',name:'PayWay',icon:'PW',color:'#82baff',keys:['PayWay']},
 {id:'shell',name:'Shell Box',icon:'S',color:'#ffdf72',keys:['ShellBox']},
 {id:'puma',name:'App Puma',icon:'P',color:'#f7a5ae',keys:['AppPuma']},
 {id:'cheques',name:'Cheques',icon:'≡',color:'#aab6c4',keys:['Cheques']}
];
const norm=x=>String(x??'').normalize('NFD').replace(/[\u0300-\u036f]/g,'').replace(/[^a-z0-9]/gi,'').toLowerCase();
const money=new Intl.NumberFormat('es-AR',{style:'currency',currency:'ARS',maximumFractionDigits:2});
const whole=new Intl.NumberFormat('es-AR',{maximumFractionDigits:0});
const eq=(a,b)=>String(a??'').trim()===String(b??'').trim();
const parse=x=>{
 if(typeof x==='number')return Number.isFinite(x)?x:null;
 if(x===null||x===undefined||x==='')return null;
 let s=String(x).trim().replace(/\s/g,'').replace(/\$/g,'');
 if(!s)return null;
 const dot=s.lastIndexOf('.'),comma=s.lastIndexOf(',');
 if(comma>=0&&dot>=0)s=comma>dot?s.replace(/\./g,'').replace(',','.'):s.replace(/,/g,'');
 else if(comma>=0)s=s.replace(',','.');
 const value=Number(s);return Number.isFinite(value)?value:null;
};
const safeValue=x=>x===null||x===undefined||x===''?'—':String(x);
const pick=(row,aliases)=>{
 if(!row)return null;
 for(const alias of aliases){
   const key=Object.keys(row).find(k=>norm(k)===norm(alias));
   if(key&&row[key]!==null&&row[key]!==undefined)return row[key];
 }
 return null;
};
const today=()=>{
 const d=new Date(),n=x=>String(x).padStart(2,'0');
 return d.getFullYear()+'-'+n(d.getMonth()+1)+'-'+n(d.getDate());
};
const modal=$('paymentsModal');
let data=null,rows=[],columnNames=[],method='all',visible=50,paramsKey='',working=false;
let latestRequest=0;
$('paymentsFrom').value=today();$('paymentsTo').value=today();
function notice(message,type=''){
 const el=$('paymentsNotice');el.className='payments-notice'+(type?' '+type:'');el.textContent=message;
}
function available(m){return m.id==='all'||columnNames.some(c=>m.keys.some(a=>norm(a)===norm(c)))}
function amount(row,m){
 for(const key of m.keys){
   const v=pick(row,[key]);if(v!==null)return parse(v);
 }
 return null;
}
function movements(m){return rows.filter(r=>{
 const n=amount(r,m);
 return n!==null&&n!==0;
}).map(r=>({row:r,method:m,amount:amount(r,m)}))}
function allMovements(){
 const out=[];
 for(const row of rows)for(const m of methods.slice(1))if(available(m)){
   const value=amount(row,m);
   if(value!==null&&value!==0)out.push({row,method:m,amount:value});
 }
 return out;
}
function total(arr){return arr.reduce((s,x)=>s+x.amount,0)}
function station(){const n=Number($('stationId')?.value);return Number.isInteger(n)&&n>0?n:null}
function range(){
 const a=$('paymentsFrom').value,b=$('paymentsTo').value;
 if(!/^\d{4}-\d\d-\d\d$/.test(a)||!/^\d{4}-\d\d-\d\d$/.test(b)||b<a)throw Error('Seleccioná un período válido.');
 const first=new Date(a+'T12:00:00'),last=new Date(b+'T12:00:00');
 if((last-first)/86400000>31)throw Error('Consultá un período de hasta 32 días.');
 const t1=$('paymentsShiftFrom').value,t2=$('paymentsShiftTo').value;
 if(!/^\d{1,5}$/.test(t1)||!/^\d{1,5}$/.test(t2)||Number(t1)>Number(t2))
   throw Error('Turnos inválidos: ingresá desde y hasta entre 0 y 99999.');
 return {idEstacion:station(),fechaDesde:a,fechaHasta:b,turnoDesde:Number(t1),turnoHasta:Number(t2)};
}
async function api(path,body){
 const base=window.capitanSqlBridge;
 if(!base)throw Error('No hay conector SQL activo. Abrí DoingLio desde el cerebro y conectá SiSRL en Núcleo → Datos.');
 const r=await fetch(base+path,{
   method:'POST',cache:'no-store',headers:{'Content-Type':'application/json'},
   body:JSON.stringify(body),
   ...(['127.0.0.1','localhost'].includes(location.hostname)?{}:{targetAddressSpace:'local'})
 });
 const d=await r.json().catch(()=>({}));
 if(!r.ok)throw Error(d.error||'HTTP '+r.status);
 return d;
}
function methodButtons(){
 const root=$('paymentsMethods');root.replaceChildren();
 for(const m of methods){
   const active=method===m.id;
   const known=m.id==='all'||available(m);
   const list=m.id==='all'?allMovements():known?movements(m):[];
   const b=document.createElement('button');b.className='payments-method';b.type='button';
   b.setAttribute('aria-pressed',String(active));b.title=known?'Mostrar '+m.name:'El SP aún no devuelve '+m.name;
   const logo=document.createElement('span');logo.className='payments-method-icon';logo.style.color=m.color;
   logo.textContent=m.icon;
   const center=document.createElement('span');
   const name=document.createElement('span');name.className='payments-method-name';name.textContent=m.name;
   const value=document.createElement('strong');value.className=known?'payments-method-amount':'payments-method-unavailable';
   value.textContent=!data?'—':!known?'No informado':money.format(total(list));
   center.append(name,value);
   const badge=document.createElement('span');badge.className='payments-method-count'+(known?'':' off');
   badge.textContent=data&&known?whole.format(list.length):'—';
   b.append(logo,center,badge);
   b.addEventListener('click',()=>{method=m.id;visible=50;render();if(m.id==='cards'||m.id==='payway')loadCards()});
   root.appendChild(b);
 }
}
function invoice(row){
 return {
  letra:pick(row,['LETRA']),
  sucursal:pick(row,['SUCURSAL']),
  numero:pick(row,['NCOMPRO','NCOMPROBANTE','NUMERO','NCOMP','NUM_COMPROBANTE']),
  fecha:pick(row,['FECHA','FEC_EMISION','FECHA_EMISION']),
  turno:pick(row,['TURNO'])
 };
}
function invoiceName(row){
 const id=invoice(row);
 if(id.letra!==null&&id.sucursal!==null&&id.numero!==null){
    return safeValue(id.letra)+' '+safeValue(id.sucursal)+'-'+safeValue(id.numero);
 }
 const sale=pick(row,['ID_SALE','IDSALE','VENTA']);
 return sale!==null?'Venta '+sale:'Comprobante sin identificación';
}
function showEvidencePanel(title,message){
 const div=$('paymentsEvidence');div.hidden=false;div.replaceChildren();
 const h=document.createElement('h4');h.textContent=title;
 const p=document.createElement('p');p.textContent=message;
 div.append(h,p);div.scrollIntoView({behavior:'smooth',block:'nearest'});
}
function showEvidenceObjects(title,objects,subtitle){
 const div=$('paymentsEvidence');div.hidden=false;div.replaceChildren();
 const h=document.createElement('h4');h.textContent=title;div.appendChild(h);
 if(subtitle){const p=document.createElement('p');p.textContent=subtitle;div.appendChild(p)}
 for(const ob of objects){
  const dl=document.createElement('dl');
  for(const [key,val] of Object.entries(ob)){
   const dt=document.createElement('dt'),dd=document.createElement('dd');
   dt.textContent=key;dd.textContent=safeValue(val);dl.append(dt,dd);
  }
  div.appendChild(dl);
 }
 div.scrollIntoView({behavior:'smooth',block:'nearest'});
}
async function checkOperation(e){
 const id=invoice(e.row),m=e.method;
 const output=[
  {Comprobante:invoiceName(e.row),Medio:m.name,Importe:money.format(e.amount),Turno:safeValue(id.turno),Fecha:safeValue(id.fecha)}
 ];
 showEvidenceObjects('Comprobante del movimiento',output,'Estos datos proceden exclusivamente de PA_VentasFormasPago.');
 if(m.id!=='mp'&&m.id!=='ypf')return;
 if(id.letra===null||id.sucursal===null||id.numero===null){
    showEvidenceObjects('Comprobante del movimiento',output,'Sin letra, sucursal y número no puedo unir de forma segura la operación con la pasarela.');
    return;
 }
 try{
   const evidence=await api('/api/station/payment-evidence',{
     idEstacion:station(),method:m.id==='mp'?'MercadoPago':'AppYPF',
     letra:String(id.letra),sucursal:String(id.sucursal),numero:String(id.numero)
   });
   if(!Array.isArray(evidence.rows)||!evidence.rows.length){
      showEvidenceObjects('Comprobante del movimiento',output,'No apareció una operación confirmada en las tablas de la pasarela para esta factura y estación.');
      return;
   }
   showEvidenceObjects('Comprobante y operación de '+m.name,
      output.concat(evidence.rows),'Relación confirmada por comprobante y estación con los identificadores de la pasarela.');
 }catch(err){
   showEvidenceObjects('Comprobante del movimiento',output,'No pude verificar la operación externa: '+err.message);
 }
}
let cardRequest=0;
async function loadCards(){
 const request=++cardRequest;
 if(!data||!['cards','payway'].includes(method))return;
 const body=range();
 const before=$('paymentsEvidence');
 showEvidencePanel('Tarjetas por turno','Buscando el reporte real PA_ListarTarjXTurno…');
 try{
   const report=await api('/api/station/payment-cards',body);
   if(request!==cardRequest||!['cards','payway'].includes(method))return;
   const set=Array.isArray(report.resultSets)?report.resultSets.find(s=>Array.isArray(s.rows)&&s.columns?.length):null;
   if(!set){showEvidencePanel('Tarjetas por turno','El SP no devolvió filas; los montos anteriores corresponden a PA_VentasFormasPago.');return}
   const allow=['LETRA','SUCURSAL','NCOMPRO','NUMERO','FECHA','TURNO','CODTAR','DESCRIPCION',
     'TARJETA','IMPORTE','MONTO','TOTAL','LOTE','NRO_CUPON','NUM_CUPON'];
   const safeCols=(set.columns||[]).filter(c=>allow.some(a=>norm(a)===norm(c)));
   const cleaned=(set.rows||[]).slice(0,80).map(row=>Object.fromEntries(safeCols.map(c=>[c,row[c]])));
   showEvidenceObjects('Tarjetas por turno',cleaned,
      cleaned.length+' movimientos del reporte PA_ListarTarjXTurno.'+
      ' Es un listado por período, estación y turno; no atribuyo cada fila a una factura sin claves verificadas.'+
      (set.truncated?' El resultado alcanza el límite de lectura; acotá las fechas.':''));
 }catch(err){
   if(request===cardRequest)showEvidencePanel('Tarjetas por turno','No pude consultar el SP de tarjetas: '+err.message);
 }
}
function showRows(list){
 const root=$('paymentsList');root.replaceChildren();
 if(!data){
   const p=document.createElement('p');p.className='payments-empty';
   p.textContent='Consultá los cobros de la estación seleccionada para ver importes reales.';
   root.appendChild(p);$('paymentsMore').hidden=true;return;
 }
 if(!list.length){
   const p=document.createElement('p');p.className='payments-empty';
   p.textContent=!available(methods.find(m=>m.id===method))?
     'PA_VentasFormasPago no devolvió esta forma de pago. No muestro un cero ficticio.':
     'No hay movimientos de este medio en el período consultado.';
   root.appendChild(p);$('paymentsMore').hidden=true;return;
 }
 const fragment=document.createDocumentFragment();
 for(const entry of list.slice(0,visible)){
   const item=document.createElement('div');item.className='payments-row';
   const main=document.createElement('div'),reference=document.createElement('div'),sub=document.createElement('span');
   reference.className='ref';reference.textContent=invoiceName(entry.row);
   sub.className='hint';const i=invoice(entry.row);
   sub.textContent='Turno: '+safeValue(i.turno)+' · '+(i.fecha===null?'Fecha no informada':String(i.fecha).slice(0,16));
   main.append(reference,sub);
   const methodLabel=document.createElement('div');methodLabel.className='method';
   methodLabel.textContent=entry.method.name;
   const amountText=document.createElement('div');amountText.className='amount';
   amountText.textContent=money.format(entry.amount);
   const button=document.createElement('button');button.type='button';button.textContent='Ver ↗';
   button.title='Ver factura y buscar operación de cobro cuando exista vínculo';
   button.addEventListener('click',()=>checkOperation(entry));
   item.append(main,methodLabel,amountText,button);fragment.appendChild(item);
 }
 root.appendChild(fragment);
 $('paymentsMore').hidden=list.length<=visible;
 $('paymentsMore').textContent='Mostrar 50 más · '+whole.format(visible)+' / '+whole.format(list.length);
}
function render(){
 methodButtons();
 const m=methods.find(x=>x.id===method)||methods[0],list=method==='all'?allMovements():available(m)?movements(m):[];
 $('paymentsMethodTitle').textContent=method==='all'?'Todas las formas de pago':m.name;
 $('paymentsAmount').textContent=!data||!available(m)?'—':money.format(total(list));
 $('paymentsCount').textContent=!data||!available(m)?'—':whole.format(list.length);
 $('paymentsStation').textContent=station()?'Estación '+station():'—';
 $('paymentsSource').textContent=data?'PA_VentasFormasPago · '+data.fechaDesde+' a '+data.fechaHasta:'Sin consultar';
 $('paymentsEvidence').hidden=true;$('paymentsEvidence').replaceChildren();
 showRows(list);
}
async function search(){
 if(working)return;
 let p;try{p=range()}catch(e){notice(e.message,'error');return}
 if(!p.idEstacion){notice('Elegí la estación en el tablero antes de consultar cobros.','error');return}
 const request=++latestRequest;
 working=true;$('paymentsSearch').disabled=true;
 notice('Consultando PA_VentasFormasPago en SiSRL…');
 $('paymentsEvidence').hidden=true;
 try{
   const response=await api('/api/station/payments',p);
   if(request!==latestRequest)return;
   const sets=Array.isArray(response.resultSets)?response.resultSets:[];
   const s=sets.find(x=>Array.isArray(x.columns)&&x.columns.some(c=>methods.slice(1).some(m=>m.keys.some(a=>norm(a)===norm(c)))));
   data=response;rows=s&&Array.isArray(s.rows)?s.rows:[];columnNames=s?s.columns:[];
   paramsKey=JSON.stringify(p);visible=50;method='all';
   const incomplete=!!(response.truncated||s?.truncated);
   if(!s)notice('El SP respondió, pero no devolvió columnas reconocibles de medios de pago. Revisá su resultado real.','warn');
   else if(incomplete)notice('ATENCIÓN: se alcanzó el límite de 5.000 filas. Los totales son PARCIALES; acotá las fechas.','error');
   else if(sets.length>1)notice('Se muestra un único resultado del SP para evitar duplicar importes de otros conjuntos.','warn');
   else notice('Cobros consultados de la estación '+p.idEstacion+'. Importes reales del procedimiento.');
   render();
 }catch(err){
   if(request===latestRequest){
    data=null;rows=[];columnNames=[];paramsKey='';render();notice(err.message,'error');
   }
 }finally{
   working=false;$('paymentsSearch').disabled=false;
 }
}
function open(){
 if(modal.classList.contains('open'))return;
 modal.classList.add('open');modal.setAttribute('aria-hidden','false');
 $('paymentsClose').focus();
 const p=range();
 if(!data||paramsKey!==JSON.stringify(p))search();else render();
}
function close(){modal.classList.remove('open');modal.setAttribute('aria-hidden','true')}
$('paymentsClose').addEventListener('click',close);
modal.addEventListener('click',e=>{if(e.target===modal)close()});
document.addEventListener('keydown',e=>{if(e.key==='Escape'&&modal.classList.contains('open'))close()});
$('paymentsSearch').addEventListener('click',search);
$('paymentsMore').addEventListener('click',()=>{
 const m=methods.find(x=>x.id===method)||methods[0];
 visible+=50;showRows(method==='all'?allMovements():movements(m));
});
$('stationId')?.addEventListener('change',()=>{
 ++latestRequest;++cardRequest;data=null;rows=[];columnNames=[];paramsKey='';
 if(modal.classList.contains('open')){render();notice('Cambió la estación. Consultá sus cobros.','warn')}
});
window.capitanOpenCobros=open;
render();
})();
