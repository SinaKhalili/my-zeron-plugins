-- Install on the retained page: use only its current embedded artwork, never
-- an album lookup. Decoding is cached by the artwork's local object URL.
return [====[(function(){
  'use strict';
  const VERSION=3;
  if(window.__headampArtwork && window.__headampArtwork.version===VERSION){window.__headampArtwork.refresh();return;}
  if(window.__headampArtwork && window.__headampArtwork.stop)window.__headampArtwork.stop();
  let api=null,baseSnapshot=null,originalPost=null,timer=null;
  let currentKey='',currentArt='',currentPixels='',generation=0;
  const cache=new Map(),localImage=src=>typeof src==='string' && /^(blob:|data:image\/)/i.test(src);
  const EMPTY={jpeg:'',pixels:''},hex=Array.from({length:256},(_,value)=>value.toString(16).padStart(2,'0'));
  const normalized=value=>String(value || '').trim();
  function raw(){try{return baseSnapshot ? baseSnapshot() : null;}catch(_){return null;}}
  function source(state){
    if(!state || !state.title)return '';
    if(localImage(state.artworkSource))return state.artworkSource;
    try{
      const metadata=navigator.mediaSession && navigator.mediaSession.metadata;
      // MediaSession is updated by Webamp from its current track. Check both
      // labels so a briefly stale OS metadata record cannot show the last cover.
      if(!metadata || normalized(metadata.title)!==normalized(state.title) || normalized(metadata.artist)!==normalized(state.artist))return '';
      const item=Array.from(metadata.artwork || []).find(art=>localImage(art.src));
      return item ? item.src : '';
    }catch(_){return '';}
  }
  function thumbnail(src){
    return new Promise(resolve=>{
      const image=new Image();
      image.onload=()=>{
        try{
          const width=image.naturalWidth,height=image.naturalHeight;
          if(!width || !height){resolve(EMPTY);return;}
          const canvas=document.createElement('canvas');canvas.width=canvas.height=64;
          const context=canvas.getContext('2d');if(!context){resolve(EMPTY);return;}
          context.fillStyle='#141414';context.fillRect(0,0,64,64);
          const edge=Math.min(width,height);
          context.drawImage(image,(width-edge)/2,(height-edge)/2,edge,edge,0,0,64,64);
          let data=canvas.toDataURL('image/jpeg',0.74);
          if(data.length>16000)data=canvas.toDataURL('image/jpeg',0.45);
          const pixels=document.createElement('canvas');pixels.width=pixels.height=40;
          const pixelContext=pixels.getContext('2d');if(!pixelContext){resolve(EMPTY);return;}
          pixelContext.drawImage(canvas,0,0,40,40);
          const rgba=pixelContext.getImageData(0,0,40,40).data,parts=[];
          for(let i=0;i<rgba.length;i+=4)parts.push(hex[rgba[i]],hex[rgba[i+1]],hex[rgba[i+2]]);
          const rgb=parts.join('');
          resolve({jpeg:data.length<=16000 ? data : '',pixels:rgb.length===9600 ? rgb : ''});
        }catch(_){resolve(EMPTY);}
      };
      image.onerror=()=>resolve(EMPTY);image.src=src;
    });
  }
  function enriched(state){return Object.assign({},state,{artwork:currentArt,artworkPixels:currentPixels});}
  function publish(){
    const state=raw();if(!state || !originalPost)return;
    originalPost(Object.assign({kind:'headamp.state'},enriched(state)));
  }
  function refresh(state){
    state=state || raw();if(!state)return;
    const src=source(state),key=String(state.sourceURL || state.title || '')+'\u0000'+String(state.artist || '')+'\u0000'+src;
    if(key===currentKey)return;
    currentKey=key;currentArt='';currentPixels='';const mine=++generation;
    if(!src){publish();return;}
    if(cache.has(src)){const kept=cache.get(src);currentArt=kept.jpeg;currentPixels=kept.pixels;publish();return;}
    thumbnail(src).then(data=>{
      cache.set(src,data);
      while(cache.size>48)cache.delete(cache.keys().next().value);
      if(mine!==generation)return;
      currentArt=data.jpeg;currentPixels=data.pixels;publish();
    });
  }
  function install(){
    const candidate=window.headamp;
    if(!candidate || typeof candidate.snapshot!=='function')return false;
    api=candidate;baseSnapshot=api.snapshot.bind(api);
    api.snapshot=function(){const state=raw();refresh(state);return enriched(state || {});};
    // zgx freezes its native bridge. Send artwork updates through it without
    // replacing it; native code keeps art for posts which omit this field.
    if(window.zgx && typeof window.zgx.postMessage==='function')originalPost=window.zgx.postMessage.bind(window.zgx);
    refresh();return true;
  }
  function debug(){
    const state=raw() || {},out={version:VERSION,ready:state.ready===true,
      stateTitle:String(state.title || '').slice(0,120),stateArtist:String(state.artist || '').slice(0,120),
      stateSourcePresent:!!state.sourceURL,artSourcePresent:!!state.artworkSource,
      cacheLength:cache.size,currentArtLength:currentArt.length,currentPixelsLength:currentPixels.length,currentKeyPresent:!!currentKey};
    try{
      out.mediaSessionExists='mediaSession' in navigator;
      const metadata=navigator.mediaSession && navigator.mediaSession.metadata;
      out.metadataExists=!!metadata;
      out.metaTitle=String(metadata && metadata.title || '').slice(0,120);
      out.metaArtist=String(metadata && metadata.artist || '').slice(0,120);
      const artwork=Array.from(metadata && metadata.artwork || []);
      out.artworkCount=Math.min(100,artwork.length);
      out.artworkSchemes=artwork.slice(0,8).map(item=>String(item.src || '').split(':')[0].slice(0,16));
      out.labelsMatch=!!metadata && normalized(metadata.title)===normalized(state.title) && normalized(metadata.artist)===normalized(state.artist);
      out.selectedSourcePresent=!!source(state);
    }catch(error){out.metadataError=String(error && error.message || error).slice(0,120);}
    return out;
  }
  const installed=install();
  timer=setInterval(()=>{if(!api){install();return;}refresh();},1500);
  window.__headampArtwork={version:VERSION,debug:debug,refresh:()=>{if(!api)install();else refresh();},stop:()=>{
    clearInterval(timer);
    if(api && baseSnapshot)api.snapshot=baseSnapshot;
  }};
  return installed;
})()]====]
