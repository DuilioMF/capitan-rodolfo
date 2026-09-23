(function(){
 const STORAGE_THEME='doinglio.theme';
 const STORAGE_STYLE='doinglio.style';
 const STYLES=[
   {id:'leon',label:'León',icon:'🦁'},
   {id:'chaty',label:'Chaty',icon:'✨'}
 ];

 const controls=document.createElement('nav');
 controls.className='site-controls';
 controls.setAttribute('aria-label','Tema, estilo y navegación');

 const modeRow=document.createElement('div');
 modeRow.className='theme-mode-row';

 const lightButton=document.createElement('button');
 lightButton.type='button';
 lightButton.className='theme-mode-button';
 lightButton.dataset.themeOption='light';
 lightButton.textContent='☀ Claro';

 const darkButton=document.createElement('button');
 darkButton.type='button';
 darkButton.className='theme-mode-button';
 darkButton.dataset.themeOption='dark';
 darkButton.textContent='🌙 Oscuro';

 modeRow.append(lightButton,darkButton);
 controls.appendChild(modeRow);

 const styleMenu=document.createElement('div');
 styleMenu.className='theme-style-menu';
 styleMenu.hidden=true;

 const menuTitle=document.createElement('div');
 menuTitle.className='theme-style-title';
 styleMenu.appendChild(menuTitle);

 const styleGrid=document.createElement('div');
 styleGrid.className='theme-style-grid';
 styleMenu.appendChild(styleGrid);
 controls.appendChild(styleMenu);

 let pendingTheme=null;

 function safeGet(key,fallback){
   try{return localStorage.getItem(key)||fallback}catch(_){return fallback}
 }
 function safeSet(key,value){
   try{localStorage.setItem(key,value)}catch(_){}
 }

 function validStyle(value){
   return STYLES.some(s=>s.id===value)?value:'leon';
 }

 function updateControls(){
   const theme=document.documentElement.dataset.theme==='light'?'light':'dark';
   const style=validStyle(document.documentElement.dataset.style||'leon');
   lightButton.classList.toggle('is-current',theme==='light');
   darkButton.classList.toggle('is-current',theme==='dark');
   lightButton.setAttribute('aria-pressed',theme==='light'?'true':'false');
   darkButton.setAttribute('aria-pressed',theme==='dark'?'true':'false');

   styleGrid.querySelectorAll('[data-style-option]').forEach(btn=>{
     const active=btn.dataset.styleOption===style && pendingTheme===theme;
     btn.classList.toggle('is-current',active);
   });
 }

 function apply(theme,style,save){
   const normalizedTheme=theme==='light'?'light':'dark';
   const normalizedStyle=validStyle(style);
   document.documentElement.dataset.theme=normalizedTheme;
   document.documentElement.dataset.style=normalizedStyle;
   if(save){
     safeSet(STORAGE_THEME,normalizedTheme);
     safeSet(STORAGE_STYLE,normalizedStyle);
   }
   document.querySelector('meta[name="theme-color"]')?.setAttribute(
     'content',
     normalizedStyle==='chaty'
       ? (normalizedTheme==='light'?'#eef8ff':'#070b16')
       : (normalizedTheme==='light'?'#f3ecdf':'#090907')
   );
   updateControls();
 }

 function closeMenu(){
   styleMenu.hidden=true;
   pendingTheme=null;
   lightButton.setAttribute('aria-expanded','false');
   darkButton.setAttribute('aria-expanded','false');
 }

 function openMenu(theme){
   pendingTheme=theme;
   menuTitle.textContent=(theme==='light'?'CLARO':'OSCURO')+' · ELEGÍ ESTILO';
   styleGrid.innerHTML='';
   STYLES.forEach(style=>{
     const btn=document.createElement('button');
     btn.type='button';
     btn.className='theme-style-option';
     btn.dataset.styleOption=style.id;
     btn.innerHTML='<span class="theme-style-icon">'+style.icon+'</span><span>'+style.label+'</span>';
     btn.addEventListener('click',()=>{
       apply(theme,style.id,true);
       closeMenu();
     });
     styleGrid.appendChild(btn);
   });
   styleMenu.hidden=false;
   lightButton.setAttribute('aria-expanded',theme==='light'?'true':'false');
   darkButton.setAttribute('aria-expanded',theme==='dark'?'true':'false');
   updateControls();
 }

 function toggleMenu(theme){
   if(!styleMenu.hidden && pendingTheme===theme){closeMenu();return}
   openMenu(theme);
 }

 lightButton.addEventListener('click',()=>toggleMenu('light'));
 darkButton.addEventListener('click',()=>toggleMenu('dark'));

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

 document.body.appendChild(controls);

 const initialTheme=safeGet(STORAGE_THEME,document.documentElement.dataset.theme||'dark');
 const initialStyle=validStyle(safeGet(STORAGE_STYLE,document.documentElement.dataset.style||'leon'));
 apply(initialTheme,initialStyle,false);

 document.addEventListener('click',event=>{
   if(!controls.contains(event.target)) closeMenu();
 });
 document.addEventListener('keydown',event=>{
   if(event.key==='Escape') closeMenu();
 });
})();