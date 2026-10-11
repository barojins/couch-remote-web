import {Gesture, coalesce} from './gesture.js';
const $ = id => document.getElementById(id);
const token = location.hash.slice(1);
history.replaceState(null, '', location.pathname);
// The secret stays in memory; a fresh page load needs a fresh scan.
const random = crypto.getRandomValues(new Uint8Array(16));
random[6] = (random[6] & 15) | 64; random[8] = (random[8] & 63) | 128;
const hex = [...random].map(x=>x.toString(16).padStart(2,'0')).join('');
const client = `${hex.slice(0,8)}-${hex.slice(8,12)}-${hex.slice(12,16)}-${hex.slice(16,20)}-${hex.slice(20)}`;
let ready=false, active=false, queue=[], sending=false, polling=null, frame=null, tapTimer=null, lastTap=0, textBusy=false, generation=0;
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
    if(!response.ok) throw new Error(result.error || 'Connection failed.');
    return result;
  } finally { clearTimeout(timeout); }
}
function apply(result) {
  ready=result.state==='ready';
  $('pairing').hidden=result.state!=='pending'; $('code').textContent=result.code;
  setMessage({ready:'Connected over Wi-Fi',pending:'Approve the code on your Mac.',permission:'Enable Accessibility access on your Mac.',disconnected:'Disconnected. Scan the Mac’s QR code again.'}[result.state] || 'Connecting…');
  if(!ready) { queue=[]; gesture.reset(); }
  controls();
}
function stop(message) {
  generation++; ready=false; active=false; queue=[]; gesture.reset();
  clearTimeout(polling); clearTimeout(tapTimer); cancelAnimationFrame(frame); frame=null; textBusy=false;
  $('pairing').hidden=true; $('connect').hidden=!token; setMessage(message); controls();
}
async function poll() {
  if(!active) return;
  const current=generation;
  try { const r=await api('/api/status'); if(current!==generation)return; apply(r); if(r.state==='disconnected'){stop('Disconnected. Reconnect or scan the Mac’s QR code.');return;} }
  catch { if(current===generation)stop('Connection lost. Text may be partially sent; check the Mac before retrying.'); return; }
  polling=setTimeout(poll,2000);
}
async function connect() {
  if(!token) {stop('Scan the QR code shown in Couch Remote Web on your Mac.');return;}
  stop('Connecting…'); const current=generation; $('connect').hidden=true;
  try {const r=await api('/api/connect'); if(current!==generation)return; active=true; apply(r); poll();}
  catch(error){if(current===generation)stop(error.message);}
}
function enqueue(command) {
  if(!ready || textBusy || !command)return;
  const merged=coalesce(queue.at(-1),command);
  if(merged)queue[queue.length-1]=merged;
  else if(queue.length<256)queue.push(command);
  else {stop('Connection too slow. Reconnect to continue.');return;}
  schedule();
}
function schedule(){if(frame===null)frame=requestAnimationFrame(()=>{frame=null;flush();});}
async function flush(){
  if(sending || !ready || !queue.length)return;
  sending=true; const current=generation; const batch=queue.splice(0,32);
  try{const r=await api('/api/commands',batch);if(current===generation)apply(r);}
  catch(error){if(current===generation)stop(error.message+' Check the Mac before retrying.');}
  finally{sending=false;if(queue.length)schedule();}
}
$('trackpad').addEventListener('pointerdown',e=>{if(!ready)return;e.preventDefault();$('trackpad').setPointerCapture(e.pointerId);gesture.down(e.pointerId,e.clientX,e.clientY,e.timeStamp);if(gesture.maxTouches===2){clearTimeout(tapTimer);tapTimer=null;}});
$('trackpad').addEventListener('pointermove',e=>{if(!ready)return;e.preventDefault();enqueue(gesture.move(e.pointerId,e.clientX,e.clientY,e.timeStamp));});
$('trackpad').addEventListener('pointerup',e=>{if(!ready)return;e.preventDefault();const kind=gesture.up(e.pointerId,e.timeStamp);if(kind==='rightClick'){clearTimeout(tapTimer);tapTimer=null;enqueue({type:kind});}else if(kind==='click'){if(tapTimer && e.timeStamp-lastTap<280){clearTimeout(tapTimer);tapTimer=null;enqueue({type:'doubleClick'});}else{lastTap=e.timeStamp;tapTimer=setTimeout(()=>{tapTimer=null;enqueue({type:'click'});},280);}}});
$('trackpad').addEventListener('pointercancel',()=>gesture.reset());
$('trackpad').addEventListener('contextmenu',e=>e.preventDefault());
$('trackpad').addEventListener('keydown',e=>{if(['Enter',' '].includes(e.key)){e.preventDefault();enqueue({type:e.shiftKey?'rightClick':'click'});}});
$('keyboard').onclick=()=>{$('keyboardDialog').showModal();$('text').focus();};
$('done').onclick=()=>$('keyboardDialog').close();
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
  catch(error){if(current===generation)stop(error.message+' Text may be partially sent; check the Mac before retrying.');}
  finally{textBusy=false;controls();}
};
function disconnect(){
  if(active)fetch('/api/disconnect',{method:'POST',headers:{'Content-Type':'application/json','Authorization':`Bearer ${token}`,'X-Couch-Client':client},body:'{}',keepalive:true}).catch(()=>{});
  stop('Disconnected. Reconnect when you’re ready.');
}
$('disconnect').onclick=disconnect; $('connect').onclick=connect;
addEventListener('pagehide',disconnect);
document.addEventListener('visibilitychange',()=>{if(document.hidden)disconnect();});
connect();
