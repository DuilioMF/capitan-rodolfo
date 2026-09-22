(function(){
 const controls=document.createElement('nav');controls.className='site-controls';controls.setAttribute('aria-label','Tema y navegación');
 const button=document.createElement('button');button.type='button';
 function apply(theme,save){document.documentElement.dataset.theme=theme;if(save){try{localStorage.setItem('doinglio.theme',theme)}catch(_){}}const light=theme==='light';button.textContent=light?'🌙 Activar oscuro':'☀ Activar claro';button.setAttribute('aria-label',button.textContent);document.querySelector('meta[name="theme-color"]')?.setAttribute('content',light?'#f3ecdf':'#090907');}
 button.onclick=()=>apply(document.documentElement.dataset.theme==='light'?'dark':'light',true);
 controls.appendChild(button);
 let oldBack=document.querySelector('a.doinglio-home,a.back,.top a[href="index.html"]');
 if(!oldBack){
   oldBack=document.createElement('a');
   oldBack.href='https://duiliomf.github.io/doinglio/';
   oldBack.target='_self';
   oldBack.textContent='← Volver a DoingLio';
   oldBack.setAttribute('aria-label','Volver a DoingLio');
 }
 oldBack.className='control-back';
 controls.appendChild(oldBack);
 document.body.appendChild(controls);apply(document.documentElement.dataset.theme==='light'?'light':'dark',false);
})();