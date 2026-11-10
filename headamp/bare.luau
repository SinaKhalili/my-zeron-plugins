-- Restyle an already playing, retained page without replacing its Webamp instance.
return [====[(function(){
  'use strict';
  const api=window.headamp;
  if(api && typeof api.applyBareLayout==='function')return api.applyBareLayout();
  const css=`
html,body{margin:0!important;padding:0!important;width:550px!important;min-width:550px!important;height:261px!important;background:transparent!important;overflow:hidden!important}
#stage{position:relative!important;width:550px!important;min-width:550px!important;height:261px!important;margin:0!important;padding:0!important;border:0!important;border-radius:0!important;background:transparent!important;overflow:hidden!important}
#app{position:absolute!important;inset:0!important}
.head,.foot,#empty,#library,#add,#folder,#dropzone,#message{display:none!important}
#message.error{display:block!important;position:fixed!important;left:8px!important;right:8px!important;bottom:7px!important;margin:0!important;padding:5px 7px!important;min-height:0!important;border-radius:3px!important;background:#141713ed!important;color:#e2b78b!important;font:10px/14px -apple-system,BlinkMacSystemFont,sans-serif!important;z-index:2147483647!important}
/* The retained v1 layout function uses an 8px top inset. Move only its root,
   preserving the live decoder, player state and each window's relative drag. */
#webamp{transform:translateY(-8px)!important}
`;
  function apply(){
    let style=document.getElementById('headamp-bare-style');
    if(!style){style=document.createElement('style');style.id='headamp-bare-style';document.head.appendChild(style);}
    style.textContent=css;
    if(api)api.command('layout');
    return api ? api.snapshot() : null;
  }
  if(api){
    const previous=api.command;
    api.command=function(command,value){return command==='bare' ? apply() : previous(command,value);};
    api.applyBareLayout=apply;
  }
  return apply();
})()]====]
