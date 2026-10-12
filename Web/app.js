import {Gesture, coalesce} from './gesture.js';
import {loadConnection, saveConnection, forgetConnection, retryDelay} from './connection.js';
const $ = id => document.getElementById(id);
let storage; try { storage=localStorage; } catch {}
const saved=loadConnection(storage);
let token = (saved && saved.token) || location.hash.slice(1);
history.replaceState(null, '', location.pathname);
// Persist only a credential issued after explicit Mac approval, never the QR token.
const random = crypto.getRandomValues(new Uint8Array(16));
random[6] = (random[6] & 15) | 64; random[8] = (random[8] & 63) | 128;
const hex = [...random].map(x=>x.toString(16).padStart(2,'0')).join('');
const client = (saved && saved.client) || `${hex.slice(0,8)}-${hex.slice(8,12)}-${hex.slice(12,16)}-${hex.slice(16,20)}-${hex.slice(20)}`;
let ready=false, active=false, queue=[], sending=false, polling=null, frame=null, tapTimer=null, lastTap=0, textBusy=false, generation=0;
let retryTimer=null, attempts=0, connecting=false;
const gesture = new Gesture();
function setMessage(text) { $('status').textContent=text; $('keyboardStatus').textContent=text; }
function controls() {
  $('trackpad').classList.toggle('ready',ready); $('keyboard').disabled=!ready;
  $('send').disabled=!ready || textBusy || !$('text').value;
  $('text').disabled=textBusy; $('done').disabled=textBusy;
  document.querySelectorAll('[data-key]').forEach(b=>b.disabled=!ready || textBusy);
}
async function api(path,body={}) {
  const controller=new AbortController(), timeout=setTimeout(()=>controller.abort(),8000);
  try {
    const response=await fetch(path,{method:'POST',headers:{'Content-Type':'application/json','Authorization':`Bearer ${token}`,'X-Couch-Client':client},body:JSON.stringify(body),signal:controller.signal,cache:'no-store'});
    const result=await response.json();
    if(!response.ok) { const error=new Error(result.error || 'Connection failed.'); error.status=response.status; throw error; }
    return result;
  } finally { clearTimeout(timeout); }
}
function apply(result) {
  if(result.deviceToken) {
    token=result.deviceToken;
    saveConnection(storage,token,client);
  }
  ready=result.state==='ready';
  attempts=0;
  $('entry').hidden=true; $('pairing').hidden=result.state!=='pending'; $('code').textContent=result.code;
  setMessage({ready:'Connected over Wi-Fi',pending:'Approve the code on your Mac.',permission:'Enable Accessibility access on your Mac.',disconnected:'Disconnected. Scan the Mac’s QR code again.'}[result.state] || 'Connecting…');
  if(!ready) { queue=[]; gesture.reset(); }
  controls();
}
function stop(message) {
  generation++; connecting=false; clearTimeout(retryTimer); retryTimer=null; ready=false; active=false; queue=[]; gesture.reset();
  clearTimeout(polling); clearTimeout(tapTimer); tapTimer=null; cancelAnimationFrame(frame); frame=null; textBusy=false;
  $('pairing').hidden=true; $('entry').hidden=!!token; $('connect').hidden=!token; setMessage(message); controls();
}
function recover(message) {
  stop(message);
  if(token && !document.hidden)retryTimer=setTimeout(connect,retryDelay(attempts++));
}
async function poll() {
  if(!active) return;
  const current=generation;
  try { const r=await api('/api/status'); if(current!==generation)return; apply(r); if(r.state==='disconnected'){recover('Reconnecting…');return;} }
  catch { if(current===generation)recover('Waiting for your Mac… Reconnecting automatically.'); return; }
  polling=setTimeout(poll,2000);
}
async function connect() {
  if(document.hidden || connecting || active)return;
  if(!token) {stop('Enter the connection code shown on your Mac.');return;}
  stop('Connecting…'); connecting=true; const current=generation; $('connect').hidden=true;
  try {const r=await api('/api/connect'); if(current!==generation)return; connecting=false; active=true; apply(r); poll();}
  catch(error){if(current===generation){if(error.status===403){token='';forgetConnection(storage);stop('Approve this phone again using the code on your Mac.');}else recover(error.message);}}
}
function enqueue(command) {
  if(!ready || textBusy || !command)return;
  const merged=coalesce(queue[queue.length-1],command);
  if(merged)queue[queue.length-1]=merged;
  else if(queue.length<256)queue.push(command);
  else {recover('Connection too slow. Reconnecting…');return;}
  schedule();
}
function schedule(){if(frame===null)frame=requestAnimationFrame(()=>{frame=null;flush();});}
async function flush(){
  if(sending || !ready || !queue.length)return;
  sending=true; const current=generation; const batch=queue.splice(0,32);
  try{const r=await api('/api/commands',batch);if(current===generation)apply(r);}
  catch(error){if(current===generation)recover(error.message+' Input was not replayed.');}
  finally{sending=false;if(queue.length)schedule();}
}
const pad=$('trackpad');
function down(id,x,y,time) {
  gesture.down(id,x,y,time);
  if(gesture.maxTouches===2){clearTimeout(tapTimer);tapTimer=null;}
}
function up(id,time) {
  const kind=gesture.up(id,time);
  if(kind==='rightClick'){clearTimeout(tapTimer);tapTimer=null;enqueue({type:kind});}
  else if(kind==='click'){
    if(tapTimer && time-lastTap<280){clearTimeout(tapTimer);tapTimer=null;enqueue({type:'doubleClick'});}
    else{lastTap=time;tapTimer=setTimeout(()=>{tapTimer=null;enqueue({type:'click'});},280);}
  }
}
function cancelGesture(){gesture.reset();clearTimeout(tapTimer);tapTimer=null;}
if(typeof PointerEvent!=='undefined') {
  pad.addEventListener('pointerdown',e=>{if(!ready)return;e.preventDefault();pad.setPointerCapture(e.pointerId);down(e.pointerId,e.clientX,e.clientY,e.timeStamp);});
  pad.addEventListener('pointermove',e=>{if(!ready)return;e.preventDefault();enqueue(gesture.move(e.pointerId,e.clientX,e.clientY,e.timeStamp));});
  pad.addEventListener('pointerup',e=>{if(!ready)return;e.preventDefault();up(e.pointerId,e.timeStamp);});
  pad.addEventListener('pointercancel',cancelGesture);
} else {
  // iOS 12 has Touch Events but no Pointer Events. Register only one input path.
  ['touchstart','touchmove','touchend'].forEach(name=>pad.addEventListener(name,e=>{
    if(!ready)return;
    e.preventDefault();
    Array.from(e.changedTouches).forEach(t=>{
      if(name==='touchstart')down(t.identifier,t.clientX,t.clientY,e.timeStamp);
      else if(name==='touchmove')enqueue(gesture.move(t.identifier,t.clientX,t.clientY,e.timeStamp));
      else up(t.identifier,e.timeStamp);
    });
  },{passive:false}));
  pad.addEventListener('touchcancel',cancelGesture,{passive:false});
}
pad.addEventListener('contextmenu',e=>e.preventDefault());
pad.addEventListener('keydown',e=>{if(['Enter',' '].includes(e.key)){e.preventDefault();enqueue({type:e.shiftKey?'rightClick':'click'});}});
const keyboardDialog=$('keyboardDialog');
function closeKeyboard(){
  if(typeof keyboardDialog.close==='function')keyboardDialog.close();
  else {keyboardDialog.removeAttribute('open');$('main').removeAttribute('aria-hidden');}
  $('keyboard').focus();
}
$('keyboard').onclick=()=>{
  cancelGesture();
  if(typeof keyboardDialog.showModal==='function')keyboardDialog.showModal();
  else {keyboardDialog.setAttribute('open','');$('main').setAttribute('aria-hidden','true');}
  $('text').focus();
};
$('done').onclick=closeKeyboard;
keyboardDialog.addEventListener('keydown',e=>{
  if(typeof keyboardDialog.showModal==='function')return;
  if(e.key==='Escape' && !textBusy){e.preventDefault();closeKeyboard();}
  if(e.key==='Tab'){
    const items=Array.from(keyboardDialog.querySelectorAll('button, textarea')).filter(el=>!el.disabled);
    const first=items[0],last=items[items.length-1];
    if(e.shiftKey && document.activeElement===first){e.preventDefault();last.focus();}
    else if(!e.shiftKey && document.activeElement===last){e.preventDefault();first.focus();}
  }
});
$('keyboardDialog').addEventListener('cancel',e=>{if(textBusy)e.preventDefault();});
$('text').oninput=()=>{$('text').style.height='auto';$('text').style.height=Math.min(160,$('text').scrollHeight)+'px';controls();};
document.querySelectorAll('[data-key]').forEach(b=>b.onclick=()=>enqueue({type:'key',key:b.dataset.key}));
$('composer').onsubmit=async e=>{
  e.preventDefault(); if(!ready || textBusy || !$('text').value)return;
  if(sending || queue.length){setMessage('Wait for the previous input to finish, then send.');return;}
  const text=$('text').value;
  if(new TextEncoder().encode(text).length>4096){setMessage('Send up to 4 KB at a time.');return;}
  textBusy=true; controls(); const current=generation;
  try{const r=await api('/api/commands',[{type:'text',text}]);if(current!==generation)return;$('text').value='';apply(r);}
  catch(error){if(current===generation)recover(error.message+' Text may be partially sent; check the Mac before sending it again.');}
  finally{textBusy=false;controls();}
};
function suspend(){
  // Safari can freeze or kill this page. Release only local input state; the Mac
  // expires the live session, while the approved device credential remains valid.
  stop('Ready to reconnect when you return.');
}
$('connect').onclick=connect;
$('entry').onsubmit=async e=>{
  e.preventDefault(); const code=$('entryCode').value.trim();
  if(!/^[0-9]{8}$/.test(code)){setMessage('Enter the 8-digit code shown on your Mac.');return;}
  stop('Connecting…'); const current=generation; $('pairButton').disabled=true;
  try {
    const result=await api('/api/pair',{code});
    if(current!==generation)return;
    token=result.token; $('entryCode').value=''; active=true; apply(result); poll();
  } catch(error){if(current===generation)stop(error.message);}
  finally{$('pairButton').disabled=false;}
};
addEventListener('pagehide',suspend);
addEventListener('pageshow',()=>{if(!document.hidden)connect();});
addEventListener('online',()=>{if(!active)connect();});
document.addEventListener('visibilitychange',()=>{if(document.hidden)suspend();else connect();});
connect();
