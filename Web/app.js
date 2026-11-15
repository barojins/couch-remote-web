import {Gesture, coalesce, movementDefaults, loadMovement, saveMovement} from './gesture.js';
import {loadConnection, saveConnection, forgetConnection, retryDelay} from './connection.js';
const $ = id => document.getElementById(id);
let storage; try { storage=localStorage; } catch {}
const saved=loadConnection(storage);
let deviceName=""; try { deviceName=storage.getItem("couch-remote-name") || ""; } catch {}
let needsName=!saved && !deviceName;
let qrToken = location.hash.slice(1);
let token = (saved && saved.token) || qrToken;
history.replaceState(null, '', location.pathname);
// Persist only a credential issued after explicit Mac approval, never the QR token.
const random = crypto.getRandomValues(new Uint8Array(16));
random[6] = (random[6] & 15) | 64; random[8] = (random[8] & 63) | 128;
const hex = [...random].map(x=>x.toString(16).padStart(2,'0')).join('');
const client = (saved && saved.client) || `${hex.slice(0,8)}-${hex.slice(8,12)}-${hex.slice(12,16)}-${hex.slice(16,20)}-${hex.slice(20)}`;
let ready=false, active=false, queue=[], sending=false, polling=null, frame=null, tapTimer=null, lastTap=0, textBusy=false, generation=0;
let retryTimer=null, attempts=0, connecting=false, pairingAttempt=null;
let approvalExpired=false, retryingApproval=false, approvalTimer=null, approvalDeadline=null, textRequest=null, textWarning='', composing=false;
let tuning=loadMovement(storage);
let scrollContact=null, scrollTimer=null, scrollFraction=0;
const gesture = new Gesture(tuning);
function setMessage(text) { $('status').textContent=text; }
function controls() {
  $('main').classList.toggle('connected',ready);
  $('trackpad').classList.toggle('ready',ready);
  $('scrollRail').classList.toggle('ready',ready && !textBusy);
  $('scrollUp').disabled=$('scrollDown').disabled=!ready || textBusy;
  if(!ready || textBusy)cancelScroll();
  $('send').disabled=!ready || textBusy || !$('text').value;
  $('text').disabled=!ready || textBusy;
  $('composer').setAttribute('aria-busy',String(textBusy));
  document.querySelectorAll('[data-key]').forEach(b=>b.disabled=!ready || textBusy);
}
async function api(path,body={}) {
  const controller=new AbortController(), timeout=setTimeout(()=>controller.abort(),8000);
  try {
    const response=await fetch(path,{method:'POST',headers:{'Content-Type':'application/json','Authorization':`Bearer ${token}`,'X-Couch-Client':client},body:JSON.stringify(body),signal:controller.signal,cache:'no-store'});
    const result=await response.json();
    if(!response.ok) { const error=new Error(result.error || 'Connection failed.'); error.status=response.status; error.reason=result.reason; throw error; }
    return result;
  } finally { clearTimeout(timeout); }
}
function apply(result) {
  if(result.deviceToken) {
    token=result.deviceToken;
    qrToken='';
    saveConnection(storage,token,client);
  }
  ready=result.state==='ready';
  approvalExpired=false;
  retryingApproval=false;
  attempts=0;
  $('entry').hidden=true; $('pairing').hidden=result.state!=='pending'; $('code').textContent=result.code;
  setMessage(result.state==='ready' && textWarning ? textWarning : {ready:'Connected over Wi-Fi',pending:'Approve the code on your Mac.',permission:'Enable Accessibility access on your Mac.',disconnected:'Disconnected. Scan the Mac’s QR code again.'}[result.state] || 'Connecting…');
  clearTimeout(approvalTimer); approvalTimer=null;
  approvalDeadline=result.state==='pending' && Number.isFinite(result.expiresIn) ? Date.now()+result.expiresIn*1000 : null;
  if(approvalDeadline!==null)updateApprovalCountdown(generation);
  if(!ready) { queue=[]; gesture.reset(); }
  controls();
}
function updateApprovalCountdown(current) {
  if(current!==generation || approvalDeadline===null)return;
  const remaining=Math.max(0,Math.ceil((approvalDeadline-Date.now())/1000));
  $('pairingStatus').textContent=`Approve on your Mac within ${remaining} seconds.`;
  if(!remaining){expireApproval();return;}
  approvalTimer=setTimeout(()=>updateApprovalCountdown(current),1000);
}
function expireApproval() {
  stop('Approval expired. Choose Connect again to request a new code.');
  approvalExpired=true;
  retryingApproval=false;
  $('connect').hidden=false; $('connect').textContent='Connect again'; $('entry').hidden=true;
}
function stop(message) {
  cancelScroll();
  generation++; connecting=false; clearTimeout(retryTimer); retryTimer=null; ready=false; active=false; queue=[]; gesture.reset();
  clearTimeout(polling); clearTimeout(tapTimer); tapTimer=null; cancelAnimationFrame(frame); frame=null; textBusy=!!textRequest;
  clearTimeout(approvalTimer); approvalTimer=null; approvalDeadline=null;
  $('connect').textContent='Reconnect';
  $('pairing').hidden=true; $('entry').hidden=!!token || !!pairingAttempt; $('connect').hidden=!token && !pairingAttempt; setMessage(message); controls();
}
function recover(message) {
  stop(message);
  if((token || pairingAttempt) && !document.hidden && !approvalExpired)retryTimer=setTimeout(()=>connect(),retryDelay(attempts++));
}
async function poll() {
  if(!active) return;
  const current=generation;
  try { const r=await api('/api/status'); if(current!==generation)return; apply(r); if(current!==generation || !active)return; if(r.state==='disconnected'){recover('Reconnecting…');return;} }
  catch(error) { if(current===generation){if(error.reason==='approvalExpired')expireApproval();else recover('Waiting for your Mac… Reconnecting automatically.');} return; }
  polling=setTimeout(poll,2000);
}
async function connect(retryApproval=false) {
  if(needsName){stop("Name this device to continue.");$("deviceSetup").hidden=false;$("entry").hidden=true;$("connect").hidden=true;return;}
  if(document.hidden || connecting || active)return;
  if(approvalExpired && !retryApproval)return;
  if(retryApproval && approvalExpired){approvalExpired=false;retryingApproval=true;}
  if(!token && pairingAttempt)return pair(pairingAttempt,retryingApproval);
  if(!token) {stop('Enter the connection code shown on your Mac.');return;}
  stop('Connecting…'); connecting=true; const current=generation; $('connect').hidden=true;
  try {
    let result;
    try { result=await api('/api/connect',{deviceName,...(retryingApproval?{retryApproval:true}:{})}); }
    catch(error) {
      if(current!==generation)return;
      if(error.status!==403)throw error;
      // Approval may have happened while Safari was suspended. The bootstrap
      // token can still collect this client's credential through status.
      result=await api('/api/status');
    }
    if(current!==generation)return;
    connecting=false; active=true; apply(result); poll();
  } catch(error) {
    if(current!==generation)return;
    if(error.reason==='approvalExpired'){expireApproval();return;}
    if(error.status===403) {
      forgetConnection(storage);
      if(qrToken && token!==qrToken) {
        // Keep a newly scanned link available when a saved approval was revoked.
        token=qrToken; qrToken=''; connecting=false;
        return connect();
      }
      token=''; qrToken='';
      stop('Approve this phone again using the code on your Mac.');
    } else recover(error.message);
  }
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
  finally{
    sending=false;
    // A frame already collected these inputs while the request was in flight.
    // Send them now instead of adding another frame of latency after every RTT.
    if(ready && queue.length){cancelAnimationFrame(frame);frame=null;flush();}
  }
}
const pad=$('trackpad');
function down(id,x,y,time) {
  gesture.down(id,x,y,time);
  if(gesture.maxTouches===2)flushTap();
}
function flushTap(){if(tapTimer){clearTimeout(tapTimer);tapTimer=null;enqueue({type:'click'});}}
function movePointer(command){if(command){flushTap();enqueue(command);}}
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
  pad.addEventListener('pointermove',e=>{if(!ready)return;e.preventDefault();movePointer(gesture.move(e.pointerId,e.clientX,e.clientY,e.timeStamp));});
  pad.addEventListener('pointerup',e=>{if(!ready)return;e.preventDefault();up(e.pointerId,e.timeStamp);});
  pad.addEventListener('pointercancel',cancelGesture);
} else {
  // iOS 12 has Touch Events but no Pointer Events. Register only one input path.
  ['touchstart','touchmove','touchend'].forEach(name=>pad.addEventListener(name,e=>{
    if(!ready)return;
    e.preventDefault();
    Array.from(e.changedTouches).forEach(t=>{
      if(name==='touchstart')down(t.identifier,t.clientX,t.clientY,e.timeStamp);
      else if(name==='touchmove')movePointer(gesture.move(t.identifier,t.clientX,t.clientY,e.timeStamp));
      else up(t.identifier,e.timeStamp);
    });
  },{passive:false}));
  pad.addEventListener('touchcancel',cancelGesture,{passive:false});
}
pad.addEventListener('contextmenu',e=>e.preventDefault());
pad.addEventListener('keydown',e=>{if(['Enter',' '].includes(e.key)){e.preventDefault();flushTap();enqueue({type:e.shiftKey?'rightClick':'click'});}});
function cancelScroll() {
  clearTimeout(scrollTimer); scrollTimer=null; scrollContact=null; scrollFraction=0;
}
function scrollBy(amount,speed=tuning.scrollSpeed) {
  if(!ready || textBusy)return;
  scrollFraction+=amount*speed;
  const y=Math.trunc(scrollFraction); scrollFraction-=y;
  if(y)enqueue({type:'scroll',x:0,y:Math.max(-8192,Math.min(8192,y))});
}
function startScroll(id,direction) {
  if(!ready || textBusy || scrollContact)return false;
  flushTap();cancelGesture();
  scrollContact={id};
  scrollBy(direction*40);
  const repeat=()=>{
    if(!scrollContact || !ready || textBusy)return;
    // Use the maximum speed (3x), regardless of the saved tap/gesture speed.
    // Avoid accumulating held input while the network is busy, so releasing
    // the button cannot replay a backlog of high-speed scroll commands.
    if(!sending && !queue.length)scrollBy(direction*40,3);
    if(scrollContact)scrollTimer=setTimeout(repeat,16);
  };
  scrollTimer=setTimeout(repeat,350);
  return true;
}
function endScroll(id) { if(scrollContact && scrollContact.id===id)cancelScroll(); }
[['scrollUp',1],['scrollDown',-1]].forEach(([id,direction])=>{
  const element=$(id);
  if(typeof PointerEvent!=='undefined') {
    element.addEventListener('pointerdown',e=>{
      if(e.button!==0 || !startScroll(e.pointerId,direction))return;
      e.preventDefault(); element.setPointerCapture(e.pointerId);
    });
    ['pointerup','pointercancel','lostpointercapture'].forEach(name=>element.addEventListener(name,e=>endScroll(e.pointerId)));
  } else {
    element.addEventListener('touchstart',e=>{
      const touch=e.changedTouches[0];
      if(touch && startScroll(touch.identifier,direction))e.preventDefault();
    },{passive:false});
    element.addEventListener('touchmove',e=>e.preventDefault(),{passive:false});
    ['touchend','touchcancel'].forEach(name=>element.addEventListener(name,e=>{
      Array.from(e.changedTouches).forEach(t=>endScroll(t.identifier));
    }));
  }
  element.addEventListener('contextmenu',e=>e.preventDefault());
  // Keyboard and assistive-technology clicks have no pointer press to handle.
  element.onclick=e=>{if(e.detail===0)scrollBy(direction*40);};
});
addEventListener('blur',cancelScroll);
function bindDialog(dialogID,openID,closeID,focusID) {
  const dialog=$(dialogID);
  function close(){
    if(typeof dialog.close==='function')dialog.close();
    else {dialog.removeAttribute('open');$('main').removeAttribute('aria-hidden');}
    $(openID).focus();
  }
  $(openID).onclick=()=>{
    flushTap();cancelGesture();cancelScroll();
    if(typeof dialog.showModal==='function')dialog.showModal();
    else {dialog.setAttribute('open','');$('main').setAttribute('aria-hidden','true');}
    $(focusID).focus();
  };
  $(closeID).onclick=close;
  dialog.addEventListener('keydown',e=>{
    if(typeof dialog.showModal==='function')return;
    if(e.key==='Escape' && !textBusy){e.preventDefault();close();}
    if(e.key==='Tab'){
      const items=Array.from(dialog.querySelectorAll('button, textarea, input, summary')).filter(el=>!el.disabled);
      const first=items[0],last=items[items.length-1];
      if(e.shiftKey && document.activeElement===first){e.preventDefault();last.focus();}
      else if(!e.shiftKey && document.activeElement===last){e.preventDefault();first.focus();}
    }
  });
}
bindDialog('settingsDialog','settings','settingsDone','sensitivity');
bindDialog('helpDialog','help','helpDone','helpDone');
function showTuning(){
  ['sensitivity','acceleration','smoothing','scrollSpeed'].forEach(key=>{
    $(key).value=tuning[key];
    $(key+'Value').textContent=key==='smoothing'?tuning[key]+' ms':tuning[key].toFixed(2)+'×';
  });
}
function updateTuning(){
  cancelGesture();cancelScroll();gesture.configure(tuning);showTuning();
  $('settingsStatus').textContent=saveMovement(storage,tuning)?'':'Applies now; browser storage is unavailable.';
}
['sensitivity','acceleration','smoothing','scrollSpeed'].forEach(key=>$(key).oninput=()=>{tuning[key]=Number($(key).value);updateTuning();});
$('resetMovement').onclick=()=>{tuning=Object.assign({},movementDefaults);updateTuning();};
showTuning();
$('text').oninput=controls;
$('text').addEventListener('compositionstart',()=>{composing=true;});
$('text').addEventListener('compositionend',()=>{composing=false;});
$('text').addEventListener('keydown',e=>{
  if(e.key==='Enter' && (composing || e.isComposing || e.keyCode===229))e.preventDefault();
});
function updateViewport() {
  const viewport=typeof visualViewport==='undefined'?null:visualViewport;
  const height=viewport?viewport.height:innerHeight, top=viewport?viewport.offsetTop:0;
  document.documentElement.style.setProperty('--remote-height',Math.round(height)+'px');
  document.documentElement.style.setProperty('--remote-top',Math.round(top)+'px');
  const focused=document.activeElement===$('text');
  $('main').classList.toggle('keyboard-open',focused);
  if(focused)requestAnimationFrame(()=>{
    const rect=$('text').getBoundingClientRect();
    if(rect.bottom>top+height || rect.top<top)$('text').scrollIntoView(false);
  });
}
$('text').addEventListener('focus',()=>{flushTap();cancelGesture();cancelScroll();updateViewport();});
$('text').addEventListener('blur',()=>{composing=false;updateViewport();});
addEventListener('resize',updateViewport);
if(typeof visualViewport!=='undefined' && visualViewport){visualViewport.addEventListener('resize',updateViewport);visualViewport.addEventListener('scroll',updateViewport);}
updateViewport();
document.querySelectorAll('[data-key]').forEach(b=>b.onclick=()=>{flushTap();enqueue({type:'key',key:b.dataset.key});});
$('composer').onsubmit=async e=>{
  e.preventDefault(); if(composing || !ready || textBusy || !$('text').value)return;
  if(sending || queue.length){setMessage('Wait for the previous input to finish, then send.');return;}
  const text=$('text').value;
  if(new TextEncoder().encode(text).length>4096){setMessage('Send up to 4 KB at a time.');return;}
  const request={};textRequest=request;textWarning='';textBusy=true; controls(); const current=generation;
  try{const r=await api('/api/commands',[{type:'text',text},{type:'key',key:'returnKey'}]);if(textRequest===request && $('text').value===text)$('text').value='';if(current!==generation)return;apply(r);}
  catch(error){
    textWarning=error.message+' Text may be partially sent; check the Mac before sending it again.';
    if(current===generation)recover(textWarning);
    else if(!document.hidden)setMessage(textWarning);
  }
  finally{if(textRequest===request){textRequest=null;textBusy=false;controls();}}
};
function suspend(){
  // Safari can freeze or kill this page. Release only local input state; the Mac
  // expires the live session, while the approved device credential remains valid.
  stop('Ready to reconnect when you return.');
}
$('deviceSetup').onsubmit=e=>{
  e.preventDefault();deviceName=$('deviceName').value.trim().slice(0,40);
  if(!deviceName)return;
  try {storage.setItem('couch-remote-name',deviceName);} catch {}
  needsName=false;$('deviceSetup').hidden=true;connect();
};
$('connect').onclick=()=>connect(true);
function newPairingSecret() {
  return btoa(Array.from(crypto.getRandomValues(new Uint8Array(32)),value=>String.fromCharCode(value)).join('')).replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');
}
async function pair(attempt,retryApproval=false) {
  stop('Connecting…');connecting=true;const current=generation; $('pairButton').disabled=true;
  try {
    const result=await api('/api/pair',{...attempt,deviceName,...(retryApproval?{retryApproval:true}:{})});
    if(current!==generation)return;
    pairingAttempt=null;token=result.token; $('entryCode').value=''; connecting=false;active=true; apply(result); poll();
  } catch(error){
    if(current!==generation)return;
    if(error.reason==='approvalExpired')expireApproval();
    else if(error.status===403 || error.status===400 || error.status===429){pairingAttempt=null;stop(error.message);}
    else recover('Connection interrupted. Retrying this pairing request…');
  } finally{$('pairButton').disabled=false;}
}
$('entry').onsubmit=async e=>{
  e.preventDefault();if(connecting)return; const code=$('entryCode').value.trim();
  if(!/^[0-9]{8}$/.test(code)){setMessage('Enter the 8-digit code shown on your Mac.');return;}
  pairingAttempt={code,pairingSecret:newPairingSecret()};approvalExpired=false;retryingApproval=false;
  return pair(pairingAttempt);
};
addEventListener('pagehide',suspend);
addEventListener('pageshow',()=>{if(!document.hidden)connect();});
addEventListener('online',()=>{if(!active)connect();});
document.addEventListener('visibilitychange',()=>{if(document.hidden)suspend();else connect();});
connect();
