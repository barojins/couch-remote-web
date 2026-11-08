import test from 'node:test';
import assert from 'node:assert/strict';
import {Gesture, Motion, coalesce, movementDefaults, movementSettings, loadMovement, saveMovement} from '../Web/gesture.js';
test('single tap and two-finger tap remain separate',()=>{
  const g=new Gesture(); g.down(1,10,10,0); assert.equal(g.up(1,100),'click');
  g.down(1,10,10,200);g.down(2,30,10,210);assert.equal(g.up(1,240),null);assert.equal(g.up(2,250),'rightClick');
});
test('movement cannot become a click; scroll cannot move the pointer',()=>{
  const g=new Gesture();g.down(1,10,10,0);assert.equal(g.move(1,30,10,50).type,'move');assert.equal(g.up(1,100),null);
  g.down(1,10,10,200);g.down(2,30,10,210);assert.equal(g.move(2,30,30,250).type,'scroll');
  g.up(2,260);assert.equal(g.move(1,50,10,280),null);assert.equal(g.up(1,300),null);
});
test('fractional motion, direction and coalescing retain intent',()=>{
  const m=new Motion();let sum=0;for(let i=0;i<10;i++)sum+=m.delta(.625,0,20)?.x??0;assert.equal(sum,5);
  assert.deepEqual(coalesce({type:'move',x:3,y:-4},{type:'move',x:-1,y:2}),{type:'move',x:2,y:-2});
  assert.equal(coalesce({type:'move',x:1,y:1},{type:'rightClick'}),null);
  assert.equal(coalesce({type:'move',x:1,y:1},{type:'scroll',x:1,y:1}),null);
});
test('cancelled or unknown touches cannot click',()=>{
  const g=new Gesture();assert.equal(g.up(9,1),null);g.down(1,0,0,0);g.reset();assert.equal(g.up(1,50),null);
});

const {loadConnection,saveConnection,forgetConnection,retryDelay}=await import('../Web/connection.js');
test('approved connection survives reload and can be forgotten',()=>{
  const values=new Map(), storage={getItem:k=>values.get(k),setItem:(k,v)=>values.set(k,v),removeItem:k=>values.delete(k)};
  const token='a'.repeat(43),client='01234567-89ab-4def-8123-456789abcdef';
  assert.equal(loadConnection(storage),null);
  assert.equal(saveConnection(storage,token,client),true);
  assert.deepEqual(loadConnection(storage),{token,client});
  forgetConnection(storage);
  assert.equal(loadConnection(storage),null);
});
test('blocked storage and malformed credentials do not break remote',()=>{
  assert.equal(loadConnection(undefined),null);
  assert.equal(saveConnection(undefined,'token','client'),false);
  assert.equal(loadConnection({getItem:()=>'{'}),null);
  assert.equal(loadConnection({getItem:()=>JSON.stringify({token:'bad',client:'bad'})}),null);
  assert.deepEqual([0,1,2,3,4,5,50].map(retryDelay),[1000,2000,4000,8000,16000,30000,30000]);
});

const {readFile}=await import('node:fs/promises');
const {runInNewContext}=await import('node:vm');
const {webcrypto}=await import('node:crypto');
const appSource=(await readFile(new URL('../Web/app.js',import.meta.url),'utf8')).replace(/^import .*;\n/gm,'');
const settle=()=>new Promise(resolve=>setImmediate(resolve));
function browserHarness({saved=false,fail=false,legacy=false,commandGate=null,unnamed=false,hash=saved?'':'#'+'q'.repeat(43),respond=null}={}) {
  const token='t'.repeat(43), client='01234567-89ab-4def-8123-456789abcdef';
  const values=new Map(), storage={getItem:k=>values.get(k),setItem:(k,v)=>values.set(k,v),removeItem:k=>values.delete(k)};
  if(saved)saveConnection(storage,token,client);
  if(!unnamed)storage.setItem("couch-remote-name","Test phone");
  const elements=new Map(), listeners={}, timers=new Map(), calls=[];
  let timerID=0;
  const get=id=>{
    if(!elements.has(id)) {
      const handlers={},attributes=new Map();
      elements.set(id,{hidden:false,disabled:false,value:'',textContent:'',style:{},classList:{toggle(){}},handlers,
        addEventListener:(name,fn)=>handlers[name]=fn,focus(){},setPointerCapture(){},
        setAttribute:(key,value)=>attributes.set(key,value),removeAttribute:key=>attributes.delete(key),hasAttribute:key=>attributes.has(key),
        ...(!legacy?{showModal(){},close(){}}:{})});
    }
    return elements.get(id);
  };
  const document={hidden:false,getElementById:get,querySelectorAll:selector=>selector==='[data-key]'?['volumeDown','mute','volumeUp'].map(key=>{const b=get(key);b.dataset={key};return b;}):[],addEventListener:(name,fn)=>listeners[name]=fn};
  let state='ready', failure=fail, rejected=false;
  const context={document,location:{hash,pathname:'/'},history:{replaceState(){}},localStorage:storage,
    ...(legacy?{}:{PointerEvent:function(){}}),crypto:webcrypto,Gesture,coalesce,movementDefaults,loadMovement,saveMovement,loadConnection,saveConnection,forgetConnection,retryDelay,AbortController,TextEncoder,
    setTimeout:(fn,ms)=>{const id=++timerID;timers.set(id,{fn,ms});return id;},clearTimeout:id=>timers.delete(id),
    requestAnimationFrame:fn=>{const id=++timerID;timers.set(id,{fn,ms:16});return id;},cancelAnimationFrame:id=>timers.delete(id),
    addEventListener:(name,fn)=>listeners[name]=fn,
    fetch:async(path,options)=>{
      calls.push({path,options});
      if(path==='/api/commands' && commandGate)await commandGate();
      if(failure)throw new Error('offline');
      if(respond) {
        const {status=200,body}=await respond(path,options);
        return {ok:status===200,status,json:async()=>body};
      }
      return {ok:!rejected,status:rejected?403:200,json:async()=>rejected?{error:'revoked'}:{state,code:'',...(!saved && path==='/api/status'?{deviceToken:token}:{})}};
    }
  };
  runInNewContext(appSource,context);
  return {get,document,listeners,timers,calls,storage,token,
    setFailure:value=>failure=value,setRejected:value=>rejected=value,setState:value=>state=value};
}

// Model the receiver's bootstrap restrictions: approval permits credential
// collection through status, but connect requires the issued credential.
function pairingReceiver() {
  const bootstrap='q'.repeat(43), credential='n'.repeat(43);
  let owner=null, approved=false;
  return {bootstrap,credential,approve(){approved=true;},respond(path,options) {
    const token=options.headers.Authorization.slice(7), client=options.headers['X-Couch-Client'];
    const trusted=token===credential;
    if(token!==bootstrap && !trusted)return {status:403,body:{error:'revoked'}};
    if(approved && !trusted && !(path==='/api/status' && owner===client))
      return {status:403,body:{error:'Use approved credential'}};
    if(path==='/api/connect')owner=client;
    else if(owner!==client)return {status:401,body:{error:'Connection expired'}};
    return {body:{state:approved?'ready':'pending',code:approved?'':'123456',
      ...(approved && !trusted && path==='/api/status'?{deviceToken:credential}:{})}};
  }};
}
test('fresh QR survives rejection of a saved revoked credential',async()=>{
  const receiver=pairingReceiver();
  const page=browserHarness({saved:true,hash:'#'+receiver.bootstrap,respond:receiver.respond});
  await settle();
  assert.equal(page.get('pairing').hidden,false);
  assert.equal(page.get('entry').hidden,true);
  assert.equal(loadConnection(page.storage),null,'bootstrap credentials must not be persisted');
  assert.ok(page.calls.some(c=>c.path==='/api/connect' && c.options.headers.Authorization==='Bearer '+receiver.bootstrap));
  receiver.approve();
  const poll=[...page.timers.values()].find(t=>t.ms===2000);assert.ok(poll);poll.fn();await settle();
  assert.equal(loadConnection(page.storage).token,receiver.credential);
  assert.equal(page.get('keyboard').disabled,false);
});
test('approval while hidden is collected on resume without pairing again',async()=>{
  const receiver=pairingReceiver();
  const page=browserHarness({respond:receiver.respond});await settle();
  assert.equal(page.get('pairing').hidden,false);
  page.document.hidden=true;page.listeners.visibilitychange();
  receiver.approve();
  page.document.hidden=false;page.listeners.visibilitychange();await settle();
  assert.equal(page.get('keyboard').disabled,false);
  assert.equal(loadConnection(page.storage).token,receiver.credential);
  assert.equal(page.get('entry').hidden,true);
  assert.equal(page.calls.some(c=>c.path==='/api/commands'),false);
});
test('page hide does not disconnect; returning reuses approved credential without replaying input',async()=>{
  const page=browserHarness();
  await settle();
  assert.equal(loadConnection(page.storage).token,page.token);
  page.document.hidden=true;page.listeners.visibilitychange();
  assert.equal(page.get('keyboard').disabled,true);
  assert.equal(page.calls.some(c=>c.path==='/api/disconnect'),false);
  page.document.hidden=false;page.listeners.visibilitychange();
  await settle();
  assert.equal(page.calls.filter(c=>c.path==='/api/connect').at(-1).options.headers.Authorization,`Bearer ${page.token}`);
  assert.equal(page.get('keyboard').disabled,false);
  assert.equal(page.calls.some(c=>c.path==='/api/commands'),false);
});
test('saved phone reconnects after network failure and stops retrying after revocation',async()=>{
  const page=browserHarness({saved:true,fail:true});
  await settle();
  const retry=[...page.timers.values()].find(t=>t.ms===1000);
  assert.ok(retry);
  page.setFailure(false);retry.fn();await settle();
  assert.equal(page.get('status').textContent,'Connected over Wi-Fi');
  page.document.hidden=true;page.listeners.visibilitychange();
  page.setRejected(true);page.document.hidden=false;page.listeners.visibilitychange();await settle();
  assert.equal(loadConnection(page.storage),null);
  assert.equal(page.get('entry').hidden,false);
  assert.equal(page.timers.size,0);
});

test('iOS 12 touch path sends movement and right click, and opens fallback keyboard',async()=>{
  const page=browserHarness({saved:true,legacy:true});await settle();
  const pad=page.get('trackpad');
  assert.equal(pad.handlers.pointerdown,undefined);
  const touch=(name,points,time)=>pad.handlers[name]({changedTouches:points.map(([identifier,clientX,clientY])=>({identifier,clientX,clientY})),timeStamp:time,preventDefault(){}});
  const flush=async()=>{const entry=[...page.timers.entries()].find(([,t])=>t.ms===16);assert.ok(entry);page.timers.delete(entry[0]);entry[1].fn();await settle();};
  touch('touchstart',[[1,0,0]],0);touch('touchmove',[[1,20,0]],50);touch('touchend',[[1,20,0]],80);
  await flush();
  assert.equal(JSON.parse(page.calls.filter(c=>c.path==='/api/commands').at(-1).options.body)[0].type,'move');
  touch('touchstart',[[1,0,0],[2,20,0]],200);touch('touchend',[[1,0,0],[2,20,0]],250);
  await flush();
  assert.deepEqual(JSON.parse(page.calls.filter(c=>c.path==='/api/commands').at(-1).options.body),[{type:'rightClick'}]);
  touch('touchstart',[[1,0,0]],400);pad.handlers.touchcancel();touch('touchend',[[1,0,0]],450);
  assert.equal([...page.timers.values()].some(t=>t.ms===280),false);
  page.get('keyboard').onclick();
  assert.equal(page.get('keyboardDialog').hasAttribute('open'),true);
  assert.equal(page.get('main').hasAttribute('aria-hidden'),true);
  page.get('done').onclick();
  assert.equal(page.get('keyboardDialog').hasAttribute('open'),false);
  assert.equal(page.get('main').hasAttribute('aria-hidden'),false);
});
test('modern browsers register only pointer input and retain native keyboard dialog',async()=>{
  const page=browserHarness({saved:true});await settle();
  assert.equal(page.get('trackpad').handlers.touchstart,undefined);
  assert.equal(typeof page.get('trackpad').handlers.pointerdown,'function');
  let opened=false;page.get('keyboardDialog').showModal=()=>opened=true;
  page.get('keyboard').onclick();assert.equal(opened,true);
  assert.equal(page.get('main').hasAttribute('aria-hidden'),false);
});

test('speed filtering reduces acceleration jitter without delaying position or adding momentum',()=>{
  const m=new Motion();m.delta(1,0,200,false,1/60);
  const deltas=[];
  for(let i=0;i<60;i++)deltas.push(m.delta(10,0,i%2?100:700,false,1/60).x);
  assert.ok(Math.max(...deltas)-Math.min(...deltas)<=6);
  assert.equal(m.delta(0,0,0,false,1/60),null);
  const precise=new Motion();let total=0;
  for(let i=0;i<100;i++){const d=precise.delta(.125,0,20);if(d)total+=d.x;}
  assert.ok(Math.abs(total-10)<=1);
  assert.equal(new Motion().delta(100,0,5000).x,200);
});
test('speed filter tracks elapsed time consistently across touch sampling rates',()=>{
  function atRate(hz){const m=new Motion();m.delta(0,0,100);for(let i=0;i<hz/2;i++)m.delta(1,0,600,false,1/hz);return m.speed;}
  assert.ok(Math.abs(atRate(30)-atRate(120))<.001);
  const g=new Gesture();g.down(1,0,0,0);g.move(1,40,0,20);g.up(1,30);
  g.down(1,0,0,100);const precise=g.move(1,2,0,200);assert.equal(precise.x,1);
});

test('movement accumulated in flight is sent immediately after response, in order',async()=>{
  let release;
  const gate=new Promise(resolve=>release=resolve);
  const page=browserHarness({saved:true,commandGate:()=>gate});await settle();
  const handlers=page.get('trackpad').handlers;
  const event=(x,time)=>({pointerId:1,clientX:x,clientY:0,timeStamp:time,preventDefault(){}});
  handlers.pointerdown(event(0,0));handlers.pointermove(event(10,16));
  const frame=[...page.timers.entries()].find(([,t])=>t.ms===16);
  page.timers.delete(frame[0]);frame[1].fn();await settle();
  assert.equal(page.calls.filter(c=>c.path==='/api/commands').length,1);
  handlers.pointermove(event(20,32));
  release();await settle();
  assert.equal(page.calls.filter(c=>c.path==='/api/commands').length,2);
  assert.equal([...page.timers.values()].some(t=>t.ms===16),false);
});

test('volume buttons enqueue commands when connected and disable when suspended',async()=>{
  const page=browserHarness({saved:true,legacy:true});await settle();
  for(const key of ['volumeDown','mute','volumeUp']) {
    assert.equal(page.get(key).disabled,false);page.get(key).onclick();
  }
  const frame=[...page.timers.entries()].find(([,t])=>t.ms===16);page.timers.delete(frame[0]);frame[1].fn();await settle();
  const sent=page.calls.filter(c=>c.path==='/api/commands');
  assert.deepEqual(JSON.parse(sent[0].options.body),['volumeDown','mute','volumeUp'].map(key=>({type:'key',key})));
  page.document.hidden=true;page.listeners.visibilitychange();
  for(const key of ['volumeDown','mute','volumeUp'])assert.equal(page.get(key).disabled,true);
});

test('movement settings clamp invalid values, persist, and preserve defaults',()=>{
  assert.deepEqual(movementSettings({sensitivity:20,acceleration:-1,smoothing:'x',scrollSpeed:99}),{sensitivity:2,acceleration:0,smoothing:40,scrollSpeed:3});
  assert.deepEqual(loadMovement(undefined),movementDefaults);
  assert.equal(saveMovement(undefined,movementDefaults),false);
  let stored;const storage={getItem:()=>stored,setItem:(key,value)=>stored=value};
  const settings={sensitivity:.5,acceleration:0,smoothing:0,scrollSpeed:1};
  assert.equal(saveMovement(storage,settings),true);assert.deepEqual(loadMovement(storage),settings);
  assert.equal(new Motion(settings).delta(10,0,5000).x,4);
  assert.equal(new Motion(settings).delta(10,0,10).x,4);
  const gesture=new Gesture(settings);gesture.down(1,0,0,0);gesture.up(1,100);
  gesture.down(1,0,0,200);assert.equal(gesture.move(1,10,0,220).x,4);
});
test('legacy settings and help open and close; tuning saves and resets',async()=>{
  const page=browserHarness({saved:true,legacy:true});await settle();
  page.get('settings').onclick();assert.equal(page.get('settingsDialog').hasAttribute('open'),true);
  page.get('sensitivity').value='0.5';page.get('sensitivity').oninput();
  assert.equal(loadMovement(page.storage).sensitivity,.5);
  assert.equal(page.get('sensitivityValue').textContent,'0.50×');
  page.get('resetMovement').onclick();assert.deepEqual(loadMovement(page.storage),movementDefaults);
  page.get('settingsDone').onclick();assert.equal(page.get('main').hasAttribute('aria-hidden'),false);
  page.get('help').onclick();assert.equal(page.get('helpDialog').hasAttribute('open'),true);
  page.get('helpDone').onclick();assert.equal(page.get('helpDialog').hasAttribute('open'),false);
});

test('first pairing asks for a name before connecting and sends it to the Mac',async()=>{
  const page=browserHarness({unnamed:true});await settle();
  assert.equal(page.calls.length,0);
  assert.equal(page.get('deviceSetup').hidden,false);
  page.get('deviceName').value='iPhone 5s';page.get('deviceSetup').onsubmit({preventDefault(){}});await settle();
  assert.equal(page.get('deviceSetup').hidden,true);
  assert.equal(JSON.parse(page.calls[0].options.body).deviceName,'iPhone 5s');
  assert.equal(page.storage.getItem('couch-remote-name'),'iPhone 5s');
});

async function runTimer(page,ms) {
  const entry=[...page.timers.entries()].find(([,timer])=>timer.ms===ms);
  assert.ok(entry,`Expected ${ms}ms timer`);
  page.timers.delete(entry[0]);entry[1].fn();await settle();
}
const scrollCommands=page=>page.calls.filter(c=>c.path==='/api/commands').flatMap(c=>JSON.parse(c.options.body));
for(const legacy of [false,true])test(`scroll rail drags vertically without moving or clicking the pointer (${legacy?'touch':'pointer'})`,async()=>{
  const page=browserHarness({saved:true,legacy});await settle();
  page.get('scrollSpeed').value='0.25';page.get('scrollSpeed').oninput();
  const handlers=page.get('scrollDrag').handlers;
  const event=y=>legacy?{changedTouches:[{identifier:1,clientY:y}],preventDefault(){}}:{pointerId:1,button:0,clientY:y,preventDefault(){}};
  handlers[legacy?'touchstart':'pointerdown'](event(0));
  for(let y=1;y<=8;y++)handlers[legacy?'touchmove':'pointermove'](event(y));
  await runTimer(page,16);
  handlers[legacy?'touchmove':'pointermove'](event(0));await runTimer(page,16);
  handlers[legacy?'touchend':'pointerup'](event(0));
  assert.deepEqual(scrollCommands(page),[{type:'scroll',x:0,y:2},{type:'scroll',x:0,y:-2}]);
  assert.equal([...page.timers.values()].some(t=>t.ms===280),false);
  assert.equal(loadMovement(page.storage).scrollSpeed,.25);
});
test('scroll arrows step, repeat after a hold, and stop on release or cancellation',async()=>{
  const page=browserHarness({saved:true});await settle();
  const event={pointerId:1,button:0,clientY:0,preventDefault(){}};
  const up=page.get('scrollUp'),down=page.get('scrollDown');
  up.handlers.pointerdown(event);await runTimer(page,16);
  await runTimer(page,350);await runTimer(page,16);
  await runTimer(page,60);await runTimer(page,16);
  up.handlers.pointerup(event);
  assert.deepEqual(scrollCommands(page).map(c=>c.y),[40,12,12]);
  assert.equal([...page.timers.values()].some(t=>[350,60].includes(t.ms)),false);
  // A synthetic click after the physical press must not duplicate the step.
  up.onclick({detail:1});assert.equal([...page.timers.values()].some(t=>t.ms===16),false);
  down.onclick({detail:0});await runTimer(page,16);
  assert.equal(scrollCommands(page).at(-1).y,-40);
  for(const reason of ['pointercancel','lostpointercapture']) {
    down.handlers.pointerdown(event);await runTimer(page,16);down.handlers[reason](event);
    assert.equal([...page.timers.values()].some(t=>[350,60].includes(t.ms)),false);
  }
});
test('held legacy scroll stops when hidden, opening a dialog, or losing permission',async()=>{
  const page=browserHarness({saved:true,legacy:true});await settle();
  const arrow=page.get('scrollDown');
  const event={changedTouches:[{identifier:1,clientY:0}],preventDefault(){}};
  arrow.handlers.touchstart(event);await runTimer(page,16);
  page.document.hidden=true;page.listeners.visibilitychange();
  assert.equal(arrow.disabled,true);
  assert.equal([...page.timers.values()].some(t=>[350,60].includes(t.ms)),false);
  page.document.hidden=false;page.listeners.visibilitychange();await settle();
  arrow.handlers.touchstart(event);await runTimer(page,16);page.get('settings').onclick();
  assert.equal([...page.timers.values()].some(t=>[350,60].includes(t.ms)),false);
  page.get('settingsDone').onclick();
  arrow.handlers.touchstart(event);await runTimer(page,16);page.setState('permission');await runTimer(page,2000);
  assert.equal(arrow.disabled,true);
  assert.equal([...page.timers.values()].some(t=>[350,60].includes(t.ms)),false);
  const count=scrollCommands(page).length;
  arrow.handlers.touchstart(event);await settle();
  assert.equal(scrollCommands(page).length,count);
});
test('scroll speed migrates old preferences and scales two-finger scrolling independently',()=>{
  assert.equal(loadMovement({getItem:()=>'{"sensitivity":2}'}).scrollSpeed,1);
  const motion=new Motion({sensitivity:2,scrollSpeed:.25});
  assert.deepEqual(motion.delta(0,10,100,true),{type:'scroll',x:0,y:2});
  assert.deepEqual(motion.delta(0,10,100,true),{type:'scroll',x:0,y:3});
});
