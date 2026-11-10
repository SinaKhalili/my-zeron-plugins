-- Webamp's pinned bundle and this page run locally in the plugin's own web view.
-- A stable base URL supplied by the host gives the library its IndexedDB origin.
return function(vendor)
    local safe_vendor = string.gsub(vendor, "</[sS][cC][rR][iI][pP][tT]", "<\\/script")
    return [====[<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; media-src blob: data:; connect-src blob: data:; font-src data:; worker-src blob:; base-uri 'none'; form-action 'none'">
<title>Headamp</title>
<style>
:root{color-scheme:dark;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color:#f1f3f2;background:transparent;font-size:12px}
*{box-sizing:border-box}html,body{margin:0;padding:0;width:550px;height:261px;background:transparent;overflow:hidden}
#stage{width:550px;height:261px;position:relative;overflow:hidden;margin:0;padding:0;border:0;border-radius:0;background:transparent}
#app{position:absolute;inset:0}#webamp{z-index:1!important}
#controls,#empty,#library,#dropzone,#message,input[type=file]{display:none}
#message.error{display:block;position:fixed;left:8px;right:8px;bottom:7px;margin:0;padding:5px 7px;border-radius:3px;background:#141713ed;color:#e2b78b;font-size:10px;line-height:14px;z-index:2147483647}
</style></head><body>
<div id="controls" hidden><button id="add" disabled>Add music</button><button id="folder" disabled>Open folder</button><span id="library"></span><span id="empty"></span><span id="dropzone"></span></div>
<div id="stage"><div id="app"></div></div><div id="message" role="status"></div>
<input id="files" aria-label="Choose audio files" type="file" multiple accept="audio/*,.mp3,.m4a,.aac,.flac,.wav,.ogg,.opus,.aiff,.aif,.wma,.webm">
<input id="folders" aria-label="Choose a music folder" type="file" multiple webkitdirectory directory>
<script>
]====] .. safe_vendor .. [====[
</script><script>
(function(){
  'use strict';
  const $ = id => document.getElementById(id);
  const audioFile = file => /^audio\//i.test(file.type || '') || /\.(mp3|m4a|aac|flac|wav|ogg|opus|aiff?|wma|webm)$/i.test(file.name || '');
  let player = null, ready = false, fatalError = '', db = null, restoring = true, importing = false;
  let savedQueue = new Set(), persistTimer = null, previousPersist = '', pendingPersist = '', previousPost = '', dragDepth = 0;
  let cleanupTimer = null, previousReferences = '';
  let layoutPending = true;
  const localFiles = new Map();
  const observedURLs = new Set();
  const persistedFiles = new Set();
  const queueWarning = 'Library changes could not be saved. Playback continues for this session.';
  // The folder library: tracks listed from the folders in Settings. A track's
  // bytes come from the plugin's helper as it is about to play, a part at a
  // time, and are never copied into the saved library.
  const FOLDER = 'headamp-folder:';
  const folderByPath = new Map(), folderByURL = new Map(), held = [];
  let folderCount = 0, pendingLibrary = null, job = null, jobCount = 0, loadTurn = 0, bulk = false, unread = false, endedAt = '';
  const bounded = (value, fallback=0) => Number.isFinite(Number(value)) ? Number(value) : fallback;
  function note(text, error){ $('message').textContent = text; $('message').className = error ? 'error' : ''; }
  function fileID(){ return (crypto.randomUUID && crypto.randomUUID()) || Date.now().toString(36)+'-'+Math.random().toString(36).slice(2); }
  function tracks(){ try { return player ? player.getPlaylistTracks() : []; } catch (_) { return []; } }
  // Webamp's audio stays silent until its own page is clicked, and the top
  // bar's buttons are not on it: wake it whenever the deck is used. A track
  // can be "playing" with no sound otherwise. Never while the page is out of
  // sight: WebKit leaves that start pending, and a page whose audio was
  // started that way stayed silent for good.
  function audioState(){try{return String(player.media._context.state || '');}catch(_){return '';}}
  function wake(){
    try{
      const context=player.media._context;
      if(document.hidden || !context || context.state==='running' || typeof context.resume!=='function')return;
      context.resume().catch(()=>{});
    }catch(_){}
  }
  document.addEventListener('visibilitychange',()=>{if(!document.hidden && player && player.getMediaStatus()==='PLAYING')wake();});
  // For when a track plays and nothing is heard: the state of each stage,
  // and how loud the sound is before the volume (`played`) and after it, as
  // it leaves the page (`heard`), from 0 to 1.
  let meter=null;
  function diagnose(){
    const out={};
    try{
      const media=player.media, context=media._context, audio=media._source._audio;
      const level=node=>{const data=new Float32Array(node.fftSize);node.getFloatTimeDomainData(data);let peak=0;for(const v of data)peak=Math.max(peak,Math.abs(v));return Math.round(peak*10000)/10000;};
      if(!meter){meter=context.createAnalyser();meter.fftSize=2048;media._gainNode.connect(meter);}
      out.context={state:context.state,rate:context.sampleRate,time:Math.round(context.currentTime*10)/10,channels:context.destination.channelCount};
      out.element={paused:audio.paused,muted:audio.muted,volume:audio.volume,time:Math.round(audio.currentTime*10)/10,ready:audio.readyState,source:String(audio.src).split(':')[0]};
      out.gain=media._gainNode.gain.value;out.played=level(media._analyser);out.heard=level(meter);
    }catch(error){out.error=String(error);}
    return out;
  }
  function snapshot(){
    const state = player && player.store ? player.store.getState() : null;
    const current = state && state.playlist && state.tracks ? state.tracks[state.playlist.currentTrack] : null;
    let position = 0, duration = current ? bounded(current.duration) : 0;
    try { position = bounded(player.media.timeElapsed()); duration = bounded(player.media.duration(), duration); } catch (_) {}
    return {ready:ready,title:current ? current.title || current.defaultName || 'Untitled track' : '',artist:current ? current.artist || '' : '',
      sourceURL:current ? current.url || '' : '',fileName:current ? current.defaultName || '' : '',artworkSource:current ? current.albumArtUrl || '' : '',
      status:player ? player.getMediaStatus() || 'STOPPED' : 'STOPPED',position:Math.max(0,Math.floor(position)),duration:Math.max(0,duration),
      volume:state && state.media ? bounded(state.media.volume,70) : 70,count:tracks().length,error:fatalError,audio:audioState()};
  }
  function publish(force){
    const data = snapshot(), serialized = JSON.stringify(data);
    if (force || serialized !== previousPost){
      previousPost = serialized;
      if (window.zgx && typeof window.zgx.postMessage === 'function') window.zgx.postMessage(Object.assign({kind:'headamp.state'},data));
    }
    $('empty').style.display = data.count ? 'none' : '';
    const savedCount=tracks().filter(track=>{const file=localFiles.get(track.url);return file && persistedFiles.has(file.id) && savedQueue.has(file.id);}).length;
    const storage=(!db || !savedCount) ? 'This session' : savedCount===data.count ? 'Library saved on this device' : savedCount+' saved · '+(data.count-savedCount)+' session only';
    $('library').textContent = data.count ? data.count + (data.count === 1 ? ' track' : ' tracks') + ' · ' + storage : 'Your playlist is empty';
  }
  function requestResult(request){ return new Promise((resolve,reject)=>{request.onsuccess=()=>resolve(request.result);request.onerror=()=>reject(request.error);}); }
  function transactionDone(tx){return new Promise((resolve,reject)=>{tx.oncomplete=resolve;tx.onerror=()=>reject(tx.error);tx.onabort=()=>reject(tx.error || new Error('Storage cancelled'));});}
  async function openLibrary(){
    try {
      const request = indexedDB.open('headamp-library',1);
      request.onupgradeneeded = () => { const store=request.result;store.createObjectStore('files',{keyPath:'id'});store.createObjectStore('settings',{keyPath:'key'}); };
      db = await requestResult(request);
      const tx = db.transaction(['files','settings'],'readonly');
      const [records,queue,volume] = await Promise.all([requestResult(tx.objectStore('files').getAll()),requestResult(tx.objectStore('settings').get('queue')),requestResult(tx.objectStore('settings').get('volume'))]);
      const byID = new Map(records.map(record=>[record.id,record]));
      const restored = (queue && Array.isArray(queue.value) ? queue.value : []).map(id=>byID.get(id)).filter(Boolean);
      for(const record of records)persistedFiles.add(record.id);
      savedQueue = new Set(restored.map(record=>record.id));
      if(volume && Number.isFinite(volume.value)) player.setVolume(Math.max(0,Math.min(100,volume.value)));
      if(restored.length) player.appendTracks(restored.map(makeTrack));
    } catch (_) {
      if(db){try{db.close();}catch(_){}db=null;}
      note('Music stays in this session; saved library storage is unavailable.',false);
    }
  }
  function makeTrack(record){
    const url = URL.createObjectURL(record.blob);
    localFiles.set(url,record);
    return {url:url,defaultName:record.name};
  }
  async function rememberFiles(records){
    if(!db)return false;
    try {
      const tx=db.transaction('files','readwrite'),done=transactionDone(tx);
      for(const record of records)tx.objectStore('files').put(record);
      await done;
      for(const record of records)persistedFiles.add(record.id);
      return true;
    }catch(_){return false;}
  }
  function persistQueue(){
    if(!db || restoring || importing || !player)return;
    const ids=tracks().map(track=>localFiles.get(track.url)).filter(record=>record && persistedFiles.has(record.id)).map(record=>record.id);
    const volume=snapshot().volume, key=JSON.stringify([ids,volume]);
    if(key===previousPersist || key===pendingPersist)return;
    clearTimeout(persistTimer);
    pendingPersist=key;
    persistTimer=setTimeout(async()=>{
      if(!db || restoring || importing){if(pendingPersist===key)pendingPersist='';return;}
      const removed=Array.from(savedQueue).filter(id=>!ids.includes(id));
      try {
        const tx=db.transaction(['files','settings'],'readwrite'), done=transactionDone(tx);
        tx.objectStore('settings').put({key:'queue',value:ids});
        tx.objectStore('settings').put({key:'volume',value:volume});
        for(const id of removed)tx.objectStore('files').delete(id);
        await done; savedQueue=new Set(ids);previousPersist=key;
        if($('message').textContent===queueWarning)note('Library saved on this device.',false);
      }catch(_){note(queueWarning,true);}
      finally{if(pendingPersist===key)pendingPersist='';publish(false);}
    },350);
  }
  function cleanupRemoved(){
    const playlist=tracks(), urls=playlist.map(track=>track.url);
    for(const url of urls)observedURLs.add(url);
    if(restoring || importing || !player)return;
    const state=player.store.getState(), current=state.tracks[state.playlist.currentTrack];
    const key=JSON.stringify([urls,current && current.url]);
    if(key===previousReferences)return;
    previousReferences=key;clearTimeout(cleanupTimer);
    cleanupTimer=setTimeout(()=>{
      if(restoring || importing)return;
      const kept=new Set(tracks().map(track=>track.url)), now=player.store.getState();
      const active=now.tracks[now.playlist.currentTrack];
      if(active && active.url)kept.add(active.url);
      const removed=[];
      for(const [url,record] of localFiles){
        // A newly imported URL may still be waiting for its metadata to load.
        // Only release references which were in the playlist and have left it;
        // always protect the current decoder's URL, even if its row was removed.
        if(observedURLs.has(url) && !kept.has(url)){
          URL.revokeObjectURL(url);localFiles.delete(url);observedURLs.delete(url);persistedFiles.delete(record.id);removed.push(record.id);
        }
      }
      if(db && removed.length){
        try{
          const tx=db.transaction('files','readwrite');
          for(const id of removed)tx.objectStore('files').delete(id);
          tx.onerror=()=>note('A removed track could not be cleared from the saved library.',true);
        }catch(_){}
      }
    },250);
  }
  function placeDeck(){
    if(!player)return;
    const width=$('app').clientWidth || 0,height=$('app').clientHeight || 0;
    // Webamp restacks its windows if the eager/offscreen page is too small.
    // Apply the documented layout after its actual viewport can hold it,
    // and again only if a hidden/narrow viewport forced another reset.
    if(width<550 || height<261){layoutPending=true;return;}
    if(!layoutPending)return;
    layoutPending=false;
    const x=Math.floor((width-550)/2),y=Math.max(0,Math.floor((height-261)/2));
    // Pinned Webamp2.3.1 reducer actions, matching setWindowLayout's source.
    player.store.dispatch({type:'WINDOW_SIZE_CHANGED',windowId:'playlist',size:[0,5]});
    player.store.dispatch({type:'UPDATE_WINDOW_POSITIONS',absolute:true,positions:{main:{x:x,y:y},equalizer:{x:x,y:y+116},playlist:{x:x+275,y:y}}});
  }
  function applyBareLayout(){
    layoutPending=true;placeDeck();return snapshot();
  }
  async function importFiles(input){
    if(!ready || importing)return;
    const files=Array.from(input || []).filter(audioFile).sort((a,b)=>(a.webkitRelativePath || a.name).localeCompare(b.webkitRelativePath || b.name,undefined,{numeric:true}));
    if(!files.length){note('No supported audio files found. Try MP3, M4A, FLAC, WAV or OGG.',true);return;}
    importing=true; $('add').disabled=$('folder').disabled=true;
    note('Adding '+files.length+(files.length===1?' track…':' tracks…'),false);
    try {
      const records=files.map(file=>({id:fileID(),name:file.name,blob:file}));
      const saved=await rememberFiles(records);
      player.appendTracks(records.map(makeTrack));
      note('Added '+files.length+(files.length===1?' track.':' tracks.')+(saved ? ' Press play when you’re ready.' : ' These tracks are session-only; they could not be saved on this device.'),!saved);
    }catch(_){note('Could not add those files. Try a smaller selection or another format.',true);}
    finally{importing=false;$('add').disabled=$('folder').disabled=false;cleanupRemoved();persistQueue();publish(true);}
  }
  function trackID(item){
    const all=player.store.getState().tracks;
    if(item.id!=null && all[item.id] && all[item.id].url===item.url)return item.id;
    item.id=null;
    for(const id in all)if(all[id].url===item.url){item.id=Number(id);break;}
    return item.id;
  }
  function audioSource(){try{return player.media._source._audio.src || '';}catch(_){return '';}}
  function forget(item){
    folderByPath.delete(item.path);folderByURL.delete(item.url);
    const at=held.indexOf(item);if(at>=0)held.splice(at,1);
    if(job && job.item===item){const dropped=job;job=null;dropped.fail(new Error('removed'));}
    if(item.blobURL && item.blobURL!==audioSource())URL.revokeObjectURL(item.blobURL);
    if(item.art)URL.revokeObjectURL(item.art);
    item.blobURL=item.art='';
  }
  // Keep the playing track, the one read ahead and the one before; let the rest go.
  function hold(item){
    const at=held.indexOf(item);if(at>=0)held.splice(at,1);
    held.push(item);
    const state=player.store.getState(), current=state.tracks[state.playlist.currentTrack], playing=audioSource();
    for(let i=0;held.length>3 && i<held.length;){
      const old=held[i];
      if(old===item || old.blobURL===playing || (current && current.url===old.url)){i++;continue;}
      URL.revokeObjectURL(old.blobURL);old.blobURL='';held.splice(i,1);
    }
  }
  // Every scan is the whole library: new files join the end of the playlist,
  // and files that have gone leave it.
  function setLibrary(rows){
    if(!Array.isArray(rows))return null;
    if(!ready){pendingLibrary=rows;return rows.length;}
    const state=player.store.getState(), current=state.playlist.currentTrack;
    const listed=new Set(), queued=new Map(), imported=new Set(), add=[], gone=[];
    for(const id of state.playlist.trackOrder){const track=state.tracks[id];if(track)queued.set(track.url,id);}
    // A file already imported into the saved library is not listed twice.
    for(const record of localFiles.values())imported.add(record.name+'\u0000'+(record.blob ? record.blob.size : -1));
    for(const row of rows){
      if(!Array.isArray(row) || typeof row[0]!=='string')continue;
      const path=row[0], name=path.slice(path.lastIndexOf('/')+1);
      if(imported.has(name+'\u0000'+row[8]))continue;
      listed.add(path);
      let item=folderByPath.get(path);
      if(!item){
        item={path:path,name:name,url:FOLDER+(++folderCount),id:null,blobURL:'',art:'',artAsked:false};
        folderByPath.set(path,item);folderByURL.set(item.url,item);
      }
      item.title=String(row[1] || name);item.artist=String(row[2] || '');item.album=String(row[3] || '');
      item.duration=bounded(row[4]);item.bitrate=bounded(row[5]);item.sampleRate=bounded(row[6]);item.channels=bounded(row[7]);
      if(!queued.has(item.url))add.push(item);
    }
    for(const [path,item] of Array.from(folderByPath)){
      if(listed.has(path))continue;
      const id=queued.get(item.url);
      if(id!=null && id===current)continue;
      if(id!=null)gone.push(id);
      forget(item);
    }
    bulk=true;
    try{
      if(gone.length)player.store.dispatch({type:'REMOVE_TRACKS',ids:gone});
      // Tags and length come with the scan, so nothing is read to list a track.
      if(add.length)player.appendTracks(add.map(item=>({url:item.url,defaultName:item.name,duration:item.duration || undefined,
        metaData:{title:item.title,artist:item.artist,album:item.album}})));
    }finally{bulk=false;}
    publish(true);
    return listed.size;
  }
  function bytes(text){
    const raw=atob(text), out=new Uint8Array(raw.length);
    for(let i=0;i<raw.length;i++)out[i]=raw.charCodeAt(i);
    return out;
  }
  // One file is read at a time. A track about to play takes over from one
  // being read ahead, or from a track the listener has already skipped past.
  function demand(item,urgent){
    if(item.blobURL)return Promise.resolve();
    if(job && job.item===item)return job.done;
    if(job){
      if(!urgent)return Promise.reject(new Error('busy'));
      const dropped=job;job=null;dropped.fail(new Error('superseded'));
    }
    const next={seq:++jobCount,item:item,parts:[],received:0};
    next.done=new Promise((pass,fail)=>{next.pass=pass;next.fail=fail;});
    next.done.catch(()=>{});
    job=next;
    if(window.zgx && typeof window.zgx.postMessage==='function')window.zgx.postMessage({kind:'headamp.want'});
    return next.done;
  }
  // What the plugin should read next, asked by it; `feed` answers with the
  // next offset while there is more of that file to come.
  function want(){
    return job ? {seq:job.seq,path:job.item.path,offset:job.received,art:!job.item.artAsked} : null;
  }
  function feed(seq,head,data){
    const mine=job;
    if(!mine || mine.seq!==seq || !head || typeof data!=='string')return null;
    if(head.offset!==mine.received)return mine.received;
    const item=mine.item;
    let part;
    try{
      if(Array.isArray(head.art) && !item.art)item.art=URL.createObjectURL(new Blob([bytes(head.art[1])],{type:String(head.art[0])}));
      part=bytes(data);
    }catch(error){job=null;mine.fail(error);return null;}
    item.artAsked=true;
    mine.parts.push(part);mine.received+=part.length;
    if(part.length && mine.received<bounded(head.size))return mine.received;
    job=null;
    item.blobURL=URL.createObjectURL(new Blob(mine.parts,{type:String(head.mime || '')}));
    hold(item);mine.pass();
    return null;
  }
  function failed(seq){
    const mine=job;
    if(mine && mine.seq===seq){job=null;mine.fail(new Error('unreadable'));}
    return null;
  }
  // The file's real format and its cover, once it has been read.
  function describe(item){
    const id=trackID(item);if(id==null)return;
    player.store.dispatch({type:'SET_MEDIA_TAGS',id:id,title:item.title,artist:item.artist,album:item.album,albumArtUrl:item.art || null,
      numberOfChannels:item.channels || null,bitrate:item.bitrate || null,sampleRate:item.sampleRate || null});
    try{
      if(item.art && 'mediaSession' in navigator && player.store.getState().playlist.currentTrack===id){
        navigator.mediaSession.metadata=new MediaMetadata({title:item.title,artist:item.artist || undefined,album:item.album || undefined,artwork:[{src:item.art}]});
      }
    }catch(_){}
  }
  // Read the track that follows while this one plays, so it starts at once.
  function readAhead(item){
    const state=player.store.getState(), order=state.playlist.trackOrder;
    if(state.media.shuffle || order.length<2)return;
    const at=order.indexOf(trackID(item));if(at<0)return;
    const id=at+1<order.length ? order[at+1] : (state.media.repeat ? order[0] : null);
    const next=id==null || !state.tracks[id] ? null : folderByURL.get(state.tracks[id].url);
    if(next && !next.blobURL)demand(next,false).catch(()=>{});
  }
  function installFolderLoader(){
    const media=player.media, load=media.loadFromUrl.bind(media), play=media.play.bind(media);
    // Webamp's Play plays whatever its audio last held. A listed library
    // starts with no track chosen: Play then starts the first one.
    // So is a listed track that could not be read: Play tries it again.
    media.play=function(){
      wake();
      const state=player.store.getState(), list=state.playlist;
      if(list.currentTrack==null && list.trackOrder.length){player.store.dispatch({type:'PLAY_TRACK',id:list.trackOrder[0]});return Promise.resolve();}
      const track=state.tracks[list.currentTrack], item=track ? folderByURL.get(track.url) : null;
      if(item && (!item.blobURL || item.blobURL!==audioSource()))return media.loadFromUrl(track.url,true);
      return play();
    };
    media.loadFromUrl=async function(url,autoPlay){
      const turn=++loadTurn, item=folderByURL.get(url);
      if(!item)return load(url,autoPlay);
      if(!item.blobURL){
        // Quiet the last track at once, as loading a file would have.
        try{media._source._audio.pause();}catch(_){}
        media._emitter.trigger('waiting');
        try{await demand(item,true);}
        catch(_){
          if(turn===loadTurn){
            media._emitter.trigger('stopWaiting');player.stop();unread=true;
            note('Could not read “'+item.name+'”. Check that its folder is still there.',true);publish(true);
          }
          return;
        }
        if(turn!==loadTurn)return;
      }
      if(unread){unread=false;note('',false);}
      hold(item);describe(item);
      await load(item.blobURL,autoPlay);
      readAhead(item);
    };
  }
  window.headamp = {
    snapshot:snapshot,
    diagnose:diagnose,
    applyBareLayout:applyBareLayout,
    library:setLibrary,
    want:want,
    feed:feed,
    failed:failed,
    command:function(command,value){
      if(!ready || !player)return snapshot();
      wake();
      try {
        if(command==='playpause'){
          if(!tracks().length){note('Add music to the playlist before pressing play.',false);return snapshot();}
          if(player.getMediaStatus()==='PLAYING')player.pause();else player.play();
        }else if(command==='play')player.play();
        else if(command==='pause')player.pause();
        else if(command==='next')player.nextTrack();
        else if(command==='previous')player.previousTrack();
        else if(command==='stop')player.stop();
        else if(command==='volume')player.setVolume(Math.max(0,Math.min(100,bounded(value,70))));
        else if(command==='seek')player.seekToTime(Math.max(0,bounded(value)));
        else if(command==='reopen')player.reopen();
        else if(command==='files')$('files').click();
        else if(command==='folder')$('folders').click();
        else if(command==='shuffle')player.toggleShuffle();
        else if(command==='repeat')player.toggleRepeat();
        else if(command==='layout'){layoutPending=true;placeDeck();}
        else if(command==='bare')applyBareLayout();
      }catch(_){note('That action is unavailable right now. Try the deck controls.',true);}
      publish(true);persistQueue();return snapshot();
    }
  };
  $('add').addEventListener('click',()=>$('files').click());
  $('folder').addEventListener('click',()=>$('folders').click());
  $('files').addEventListener('change',event=>{importFiles(event.target.files);event.target.value='';});
  $('folders').addEventListener('change',event=>{importFiles(event.target.files);event.target.value='';});
  if(!('webkitdirectory' in $('folders')))$('folder').style.display='none';
  // Catch the classic deck's file picker too, so its imported tracks share
  // the same local library and the same deliberate, non-autoplay behavior.
  document.addEventListener('change',event=>{
    const input=event.target;
    if(input && input.type==='file' && input!==$('files') && input!==$('folders') && Array.from(input.files || []).some(audioFile)){
      event.stopImmediatePropagation();importFiles(input.files);input.value='';
    }
  },true);
  document.addEventListener('dragenter',event=>{event.preventDefault();dragDepth++;document.body.classList.add('dragging');},true);
  document.addEventListener('dragover',event=>event.preventDefault(),true);
  document.addEventListener('dragleave',()=>{dragDepth=Math.max(0,dragDepth-1);if(!dragDepth)document.body.classList.remove('dragging');},true);
  document.addEventListener('drop',event=>{event.preventDefault();event.stopImmediatePropagation();dragDepth=0;document.body.classList.remove('dragging');importFiles(event.dataTransfer.files);},true);
  document.addEventListener('keydown',event=>{
    if(event.key==='Escape'){
      event.preventDefault();event.stopImmediatePropagation();
      if(window.zgx)window.zgx.postMessage({kind:'headamp.close'});
    }
  },true);
  async function boot(){
    try{
      if(!window.Webamp || !Webamp.browserIsSupported())throw new Error('Audio playback is unavailable in this web view.');
      player=new Webamp({initialTracks:[],enableHotkeys:false,enableMediaSession:true,
        windowLayout:{main:{position:{top:0,left:0}},equalizer:{position:{top:116,left:0}},playlist:{position:{top:0,left:275},size:{extraWidth:0,extraHeight:5}}},
        handleAddUrlEvent:()=>{note('Headamp plays local music. Use Add music or Open folder.',false);return null;}
      });
      player.setVolume(70);
      installFolderLoader();
      await player.renderInto($('app'));
      placeDeck();
      if(typeof ResizeObserver==='function')new ResizeObserver(placeDeck).observe($('app'));
      window.addEventListener('resize',placeDeck);
      player.onTrackDidChange(()=>publish(true));
      player.onWillClose(cancel=>{cancel();if(window.zgx)window.zgx.postMessage({kind:'headamp.close'});});
      player.onMinimize(()=>{if(window.zgx)window.zgx.postMessage({kind:'headamp.close'});});
      player.store.subscribe(()=>{if(bulk)return;publish(false);cleanupRemoved();persistQueue();});
      await openLibrary();
      restoring=false;ready=true;$('add').disabled=$('folder').disabled=false;
      cleanupRemoved();publish(true);
      if(pendingLibrary){const rows=pendingLibrary;pendingLibrary=null;setLibrary(rows);}
      setInterval(()=>{
        if(!player || player.getMediaStatus()!=='PLAYING'){endedAt='';return;}
        publish(false);
        // WebKit can reach the end of a FLAC it has seeked in without saying
        // so. Still at the end of the current track a second later: say it.
        const state=player.store.getState(), track=state.tracks[state.playlist.currentTrack];
        const item=track ? folderByURL.get(track.url) : null, source=track ? (item ? item.blobURL : track.url) : '';
        let audio=null;try{audio=player.media._source._audio;}catch(_){}
        if(!audio || !audio.ended || !source || audio.src!==source){endedAt='';return;}
        if(endedAt!==source){endedAt=source;return;}
        endedAt='';audio.dispatchEvent(new Event('ended'));
      },1000);
    }catch(error){
      fatalError='Could not start the audio player. Reopen Headamp to try again.';
      $('library').textContent='Headamp could not start';note(error && error.message ? error.message : fatalError,true);publish(true);
    }
  }
  boot();
})();
</script></body></html>]====]
end
