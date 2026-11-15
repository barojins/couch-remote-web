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
const appHTML=await readFile(new URL('../Web/index.html',import.meta.url),'utf8');
const keyControls=[...appHTML.matchAll(/<button\b([^>]*)data-key="([^"]+)"([^>]*)>/g)].map(([,before,key,after])=>({key,id:(before+after).match(/\bid="([^"]+)"/)?.[1] || key}));
const settle=()=>new Promise(resolve=>setImmediate(resolve));
function browserHarness({saved=false,fail=false,legacy=false,commandGate=null,unnamed=false,hash=saved?'':'#'+'q'.repeat(43),respond=null,viewport=null}={}) {
  const token='t'.repeat(43), client='01234567-89ab-4def-8123-456789abcdef';
  const values=new Map(), storage={getItem:k=>values.get(k),setItem:(k,v)=>values.set(k,v),removeItem:k=>values.delete(k)};
  if(saved)saveConnection(storage,token,client);
  if(!unnamed)storage.setItem("couch-remote-name","Test phone");
  const elements=new Map(), listeners={}, timers=new Map(), calls=[];
  let timerID=0,now=0;
  class HarnessDate extends Date {static now(){return now;}}
  const get=id=>{
    if(!elements.has(id)) {
      const handlers={},attributes=new Map(),classes=new Set();
      elements.set(id,{hidden:false,disabled:false,value:'',textContent:'',style:{},classList:{toggle(name,on){if(on)classes.add(name);else classes.delete(name);},contains:name=>classes.has(name)},handlers,
        addEventListener:(name,fn)=>handlers[name]=fn,focus(){document.activeElement=this;handlers.focus?.();},blur(){document.activeElement=null;handlers.blur?.();},getBoundingClientRect(){return {top:0,bottom:48};},scrollIntoView(){this.scrolled=true;},setPointerCapture(){},
        setAttribute:(key,value)=>attributes.set(key,value),removeAttribute:key=>attributes.delete(key),hasAttribute:key=>attributes.has(key),getAttribute:key=>attributes.get(key) ?? null,
        ...(!legacy?{showModal(){},close(){}}:{})});
    }
    return elements.get(id);
  };
  const cssVariables=new Map();
  const document={documentElement:{style:{setProperty:(key,value)=>cssVariables.set(key,value)}},activeElement:null,hidden:false,getElementById:get,querySelectorAll:selector=>selector==='[data-key]'?keyControls.map(({id,key})=>{const b=get(id);b.dataset={key};return b;}):[],addEventListener:(name,fn)=>listeners[name]=fn};
  let state='ready', failure=fail, rejected=false;
  const viewportHandlers={};
  if(viewport)viewport.addEventListener=(name,fn)=>viewportHandlers[name]=fn;
  const context={document,innerHeight:844,...(viewport?{visualViewport:viewport}:{}),location:{hash,pathname:'/'},history:{replaceState(){}},localStorage:storage,
    ...(legacy?{}:{PointerEvent:function(){}}),crypto:webcrypto,Gesture,coalesce,movementDefaults,loadMovement,saveMovement,loadConnection,saveConnection,forgetConnection,retryDelay,AbortController,TextEncoder,btoa,Date:HarnessDate,
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
  return {get,document,listeners,timers,calls,storage,token,cssVariables,viewportHandlers,
    advanceTime:ms=>now+=ms,
    setFailure:value=>failure=value,setRejected:value=>rejected=value,setState:value=>state=value};
}

// A shared receiver model lets independent browser pages pair and poll without
// replacing each other's approval or credential delivery.
function pairingReceiver() {
  const bootstrap='q'.repeat(43), clients=new Map();
  const create=client=>{
    if(!clients.has(client))clients.set(client,{code:String(123456+clients.size),approved:false,acknowledged:false});
    return clients.get(client);
  };
  return {bootstrap,get credential(){return [...clients.values()][0]?.credential;},
    approve(client=[...clients.keys()].find(id=>!clients.get(id).approved)) {
      const session=clients.get(client);assert.ok(session,'Expected a pending client');
      session.approved=true;session.credential=String.fromCharCode(110+[...clients.keys()].indexOf(client)).repeat(43);
      return session.credential;
    },respond(path,options) {
      const token=options.headers.Authorization.slice(7), client=options.headers['X-Couch-Client'];
      if(path==='/api/pair') {
        if(JSON.parse(options.body).code!=='12345678')return {status:403,body:{error:'Incorrect code'}};
        const session=create(client);
        return {body:{token:bootstrap,state:'pending',code:session.code}};
      }
      let session=clients.get(client);
      const trusted=session?.credential===token;
      if(token!==bootstrap && !trusted)return {status:403,body:{error:'revoked'}};
      if(session?.approved && !trusted && !(path==='/api/status' && !session.acknowledged))
        return {status:403,body:{error:'Use approved credential'}};
      if(path==='/api/connect')session=create(client);
      else if(!session)return {status:401,body:{error:'Connection expired'}};
      if(path==='/api/commands' && (!session.approved || !trusted))return {status:403,body:{error:'Approval required'}};
      if(trusted)session.acknowledged=true;
      return {body:{state:session.approved?'ready':'pending',code:session.approved?'':session.code,
        ...(session.approved && !trusted && path==='/api/status'?{deviceToken:session.credential}:{})}};
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
  assert.equal(page.get('navLeft').disabled,false);
});
test('approval while hidden is collected on resume without pairing again',async()=>{
  const receiver=pairingReceiver();
  const page=browserHarness({respond:receiver.respond});await settle();
  assert.equal(page.get('pairing').hidden,false);
  page.document.hidden=true;page.listeners.visibilitychange();
  receiver.approve();
  page.document.hidden=false;page.listeners.visibilitychange();await settle();
  assert.equal(page.get('navLeft').disabled,false);
  assert.equal(loadConnection(page.storage).token,receiver.credential);
  assert.equal(page.get('entry').hidden,true);
  assert.equal(page.calls.some(c=>c.path==='/api/commands'),false);
});
test('two QR phones pair independently and send commands with separate credentials',async()=>{
  const receiver=pairingReceiver();
  const first=browserHarness({respond:receiver.respond}),second=browserHarness({respond:receiver.respond});
  await settle();
  const firstClient=first.calls[0].options.headers['X-Couch-Client'],secondClient=second.calls[0].options.headers['X-Couch-Client'];
  assert.notEqual(firstClient,secondClient);
  assert.notEqual(first.get('code').textContent,second.get('code').textContent);
  for(const page of [first,second]) {
    assert.equal(page.get('pairing').hidden,false);
    assert.equal(page.get('navLeft').disabled,true);
    assert.equal(loadConnection(page.storage),null);
    page.get('volumeUp').onclick();await settle();
    assert.equal(page.calls.some(c=>c.path==='/api/commands'),false);
  }
  const firstCredential=receiver.approve(firstClient);await runTimer(first,2000);
  assert.equal(first.get('navLeft').disabled,false);
  assert.equal(second.get('navLeft').disabled,true);
  const secondCredential=receiver.approve(secondClient);await runTimer(second,2000);
  assert.notEqual(firstCredential,secondCredential);
  for(const [page,credential] of [[first,firstCredential],[second,secondCredential]]) {
    assert.equal(page.get('navLeft').disabled,false);
    assert.equal(loadConnection(page.storage).token,credential);
    page.get('volumeUp').onclick();await runTimer(page,16);
    assert.equal(page.calls.filter(c=>c.path==='/api/commands').at(-1).options.headers.Authorization,'Bearer '+credential);
  }
});
test('a new Home Screen phone pairs by code while an approved QR phone stays connected',async()=>{
  const receiver=pairingReceiver(),first=browserHarness({respond:receiver.respond});await settle();
  receiver.approve();await runTimer(first,2000);
  const original=loadConnection(first.storage);
  const second=browserHarness({unnamed:true,hash:'',respond:receiver.respond});await settle();
  second.get('deviceName').value='New phone';second.get('deviceSetup').onsubmit({preventDefault(){}});await settle();
  assert.equal(second.get('entry').hidden,false);
  second.get('entryCode').value='12345678';await second.get('entry').onsubmit({preventDefault(){}});await settle();
  const pair=second.calls.find(c=>c.path==='/api/pair');
  assert.equal(JSON.parse(pair.options.body).deviceName,'New phone');
  assert.equal(second.get('pairing').hidden,false);
  assert.equal(loadConnection(second.storage),null);
  await runTimer(first,2000);
  assert.equal(first.get('navLeft').disabled,false);
  assert.deepEqual(loadConnection(first.storage),original);
  receiver.approve(pair.options.headers['X-Couch-Client']);await runTimer(second,2000);
  await runTimer(first,2000);
  for(const page of [first,second]) {
    assert.equal(page.get('navLeft').disabled,false);
    assert.equal(page.get('status').textContent,'Connected over Wi-Fi');
    assert.equal(page.calls.some(c=>c.path==='/api/commands'),false);
  }
  assert.notEqual(loadConnection(first.storage).token,loadConnection(second.storage).token);
});
test('one phone acknowledging its credential does not consume another phone’s approval',async()=>{
  const receiver=pairingReceiver(),first=browserHarness({respond:receiver.respond}),second=browserHarness({respond:receiver.respond});
  await settle();
  const firstClient=first.calls[0].options.headers['X-Couch-Client'],secondClient=second.calls[0].options.headers['X-Couch-Client'];
  const firstCredential=receiver.approve(firstClient),secondCredential=receiver.approve(secondClient);
  await runTimer(first,2000);await runTimer(first,2000);
  assert.equal(first.calls.at(-1).options.headers.Authorization,'Bearer '+firstCredential);
  assert.equal(loadConnection(second.storage),null);
  await runTimer(second,2000);
  assert.equal(loadConnection(second.storage).token,secondCredential);
  assert.equal(first.get('navLeft').disabled,false);
  assert.equal(second.get('navLeft').disabled,false);
  second.document.hidden=true;second.listeners.visibilitychange();
  assert.equal(first.get('navLeft').disabled,false);
  second.document.hidden=false;second.listeners.visibilitychange();await settle();
  assert.equal(second.calls.filter(c=>c.path==='/api/connect').at(-1).options.headers.Authorization,'Bearer '+secondCredential);
  assert.equal(second.get('navLeft').disabled,false);
});
test('page hide does not disconnect; returning reuses approved credential without replaying input',async()=>{
  const page=browserHarness();
  await settle();
  assert.equal(loadConnection(page.storage).token,page.token);
  page.document.hidden=true;page.listeners.visibilitychange();
  assert.equal(page.get('navLeft').disabled,true);
  assert.equal(page.calls.some(c=>c.path==='/api/disconnect'),false);
  page.document.hidden=false;page.listeners.visibilitychange();
  await settle();
  assert.equal(page.calls.filter(c=>c.path==='/api/connect').at(-1).options.headers.Authorization,`Bearer ${page.token}`);
  assert.equal(page.get('navLeft').disabled,false);
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

test('iOS 12 touch path sends movement and right click, and opens fallback help',async()=>{
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
  page.get('help').onclick();
  assert.equal(page.get('helpDialog').hasAttribute('open'),true);
  assert.equal(page.get('main').hasAttribute('aria-hidden'),true);
  page.get('helpDone').onclick();
  assert.equal(page.get('helpDialog').hasAttribute('open'),false);
  assert.equal(page.get('main').hasAttribute('aria-hidden'),false);
});
test('modern browsers register only pointer input and retain native help dialog',async()=>{
  const page=browserHarness({saved:true});await settle();
  assert.equal(page.get('trackpad').handlers.touchstart,undefined);
  assert.equal(typeof page.get('trackpad').handlers.pointerdown,'function');
  let opened=false;page.get('helpDialog').showModal=()=>opened=true;
  page.get('help').onclick();assert.equal(opened,true);
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
  page.timers.delete(entry[0]);page.advanceTime(ms);entry[1].fn();await settle();
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

for(const legacy of [false,true])test(`a pending tap is sent before subsequent movement (${legacy?'touch':'pointer'})`,async()=>{
  const page=browserHarness({saved:true,legacy});await settle();
  const handlers=page.get('trackpad').handlers;
  const event=(x,time)=>legacy?{changedTouches:[{identifier:1,clientX:x,clientY:0}],timeStamp:time,preventDefault(){}}:{pointerId:1,clientX:x,clientY:0,timeStamp:time,preventDefault(){}};
  handlers[legacy?'touchstart':'pointerdown'](event(0,0));handlers[legacy?'touchend':'pointerup'](event(0,80));
  handlers[legacy?'touchstart':'pointerdown'](event(0,140));handlers[legacy?'touchmove':'pointermove'](event(50,160));
  await runTimer(page,16);
  assert.deepEqual(scrollCommands(page).map(c=>c.type),['click','move']);
  assert.equal([...page.timers.values()].some(t=>t.ms===280),false);
});
test('focusing Search or sending a navigation key preserves the preceding tap',async()=>{
  for(const action of ['search','navLeft']) {
    const page=browserHarness({saved:true});await settle();
    const handlers=page.get('trackpad').handlers,event=time=>({pointerId:1,clientX:0,clientY:0,timeStamp:time,preventDefault(){}});
    handlers.pointerdown(event(0));handlers.pointerup(event(80));if(action==='search')page.get('text').focus();else page.get(action).onclick();await runTimer(page,16);
    const commands=scrollCommands(page);
    assert.equal(commands[0].type,'click');
    assert.deepEqual(commands.slice(1),action==='navLeft'?[{type:'key',key:'left'}]:[]);
    assert.equal([...page.timers.values()].some(t=>t.ms===280),false);
  }
});
test('two quick taps still become one double click',async()=>{
  const page=browserHarness({saved:true});await settle();
  const handlers=page.get('trackpad').handlers,event=time=>({pointerId:1,clientX:0,clientY:0,timeStamp:time,preventDefault(){}});
  handlers.pointerdown(event(0));handlers.pointerup(event(70));handlers.pointerdown(event(140));handlers.pointerup(event(210));
  await runTimer(page,16);
  assert.deepEqual(scrollCommands(page),[{type:'doubleClick'}]);
});
test('suspending an in-flight text send cannot unlock a second send or resend confirmed text',async()=>{
  let release;const gate=new Promise(resolve=>release=resolve);
  const page=browserHarness({saved:true,commandGate:()=>gate});await settle();
  page.get('text').value='first';const pending=page.get('composer').onsubmit({preventDefault(){}});await settle();
  page.document.hidden=true;page.listeners.visibilitychange();page.document.hidden=false;page.listeners.visibilitychange();await settle();
  assert.equal(page.get('text').disabled,true);assert.equal(page.get('send').disabled,true);
  await page.get('composer').onsubmit({preventDefault(){}});await settle();
  assert.equal(page.calls.filter(c=>c.path==='/api/commands').length,1);
  release();await pending;
  assert.equal(page.get('text').disabled,false);
  assert.equal(page.get('text').value,'');
  assert.equal(page.get('send').disabled,true);
});
test('a lost manual-pair response retries the same code and secret without another user action',async()=>{
  const receiver=pairingReceiver();let first=true;
  const page=browserHarness({hash:'',respond:(path,options)=>{
    const result=receiver.respond(path,options);
    if(path==='/api/pair' && first){first=false;throw new Error('Response lost after acceptance');}
    return result;
  }});await settle();
  page.get('entryCode').value='12345678';await page.get('entry').onsubmit({preventDefault(){}});await settle();
  const initial=JSON.parse(page.calls[0].options.body);
  assert.match(initial.pairingSecret,/^[A-Za-z0-9_-]{43}$/);
  assert.equal(page.get('pairButton').disabled,false);
  await runTimer(page,1000);
  const retries=page.calls.filter(c=>c.path==='/api/pair');
  assert.equal(retries.length,2);assert.deepEqual(JSON.parse(retries[1].options.body),initial);
  assert.equal(page.get('pairing').hidden,false);
  receiver.approve();await runTimer(page,2000);
  assert.equal(page.get('navLeft').disabled,false);
});
test('pending approval counts down and waits for an explicit retry after expiry',async()=>{
  const page=browserHarness({respond:()=>({body:{state:'pending',code:'123456',expiresIn:3}})});await settle();
  assert.equal(page.get('pairingStatus').textContent,'Approve on your Mac within 3 seconds.');
  await runTimer(page,1000);assert.equal(page.get('pairingStatus').textContent,'Approve on your Mac within 2 seconds.');
  await runTimer(page,1000);await runTimer(page,1000);
  assert.equal(page.get('pairing').hidden,true);
  assert.match(page.get('status').textContent,/Approval expired/);
  assert.equal(page.get('connect').hidden,false);
  assert.equal(page.timers.size,0);
  const count=page.calls.length;page.listeners.online();page.listeners.pageshow();await settle();
  assert.equal(page.calls.length,count,'online/pageshow must not silently replace an expired code');
  await page.get('connect').onclick();await settle();
  assert.equal(JSON.parse(page.calls.filter(c=>c.path==='/api/connect').at(-1).options.body).retryApproval,true);
  assert.equal(page.get('pairing').hidden,false);
});
test('server expiry stops retries and hiding cancels stale countdown callbacks',async()=>{
  let expired=false;
  const page=browserHarness({respond:()=>expired?{status:401,body:{reason:'approvalExpired',error:'Approval expired'}}:{body:{state:'pending',code:'123456',expiresIn:10}}});await settle();
  const oldCountdown=[...page.timers.values()].find(t=>t.ms===1000).fn;
  page.document.hidden=true;page.listeners.visibilitychange();oldCountdown();
  assert.equal(page.get('status').textContent,'Ready to reconnect when you return.');
  page.document.hidden=false;page.listeners.visibilitychange();await settle();
  expired=true;await runTimer(page,2000);
  assert.match(page.get('status').textContent,/Approval expired/);
  assert.equal(page.timers.size,0);
});
for(const legacy of [false,true])test(`playback controls send distinct keys and disable when suspended (${legacy?'touch':'pointer'})`,async()=>{
  const page=browserHarness({saved:true,legacy});await settle();
  const keys=[['navLeft','left'],['playPause','playPause'],['navRight','right']];
  for(const [id] of keys){assert.equal(page.get(id).disabled,false);page.get(id).onclick();}
  await runTimer(page,16);
  assert.deepEqual(scrollCommands(page),keys.map(([,key])=>({type:'key',key})));
  assert.equal(page.get('main').classList.contains('connected'),true);
  page.document.hidden=true;page.listeners.visibilitychange();
  for(const [id] of keys)assert.equal(page.get(id).disabled,true);
  assert.equal(page.get('main').classList.contains('connected'),false);
  assert.ok(appHTML.indexOf('id="navigation"')<appHTML.indexOf('id="composer"'));
  assert.equal((appHTML.match(/data-key="left"/g)||[]).length,1);
  assert.equal((appHTML.match(/data-key="playPause"/g)||[]).length,1);
  assert.equal(/data-key="(?:up|down)"/.test(appHTML),false);
});
test('a text send with an unknown outcome keeps the draft and warning after reconnecting',async()=>{
  let reject;const gate=new Promise((resolve,rejectRequest)=>reject=rejectRequest);
  const page=browserHarness({saved:true,commandGate:()=>gate});await settle();
  page.get('text').value='check before retrying';const pending=page.get('composer').onsubmit({preventDefault(){}});await settle();
  page.document.hidden=true;page.listeners.visibilitychange();page.document.hidden=false;page.listeners.visibilitychange();await settle();
  reject(new Error('Connection lost'));await pending;
  assert.equal(page.get('text').value,'check before retrying');
  assert.equal(page.get('text').disabled,false);assert.equal(page.get('composer').getAttribute('aria-busy'),'false');
  assert.match(page.get('status').textContent,/check the Mac before sending it again/);
  await runTimer(page,2000);
  assert.match(page.get('status').textContent,/check the Mac before sending it again/);
  assert.equal(page.calls.filter(c=>c.path==='/api/commands').length,1);
});
test('an explicit expired-approval retry keeps its intent across a transient network failure',async()=>{
  let expired=false,failRetry=true;
  const page=browserHarness({respond:(path,options)=>{
    if(expired && JSON.parse(options.body).retryApproval) {
      if(failRetry){failRetry=false;throw new Error('Temporary outage');}
      expired=false;
    }
    return expired?{status:401,body:{reason:'approvalExpired',error:'Approval expired'}}:{body:{state:'pending',code:'123456',expiresIn:60}};
  }});await settle();
  expired=true;await runTimer(page,2000);
  await page.get('connect').onclick();await settle();
  await runTimer(page,1000);
  const attempts=page.calls.filter(c=>c.path==='/api/connect').slice(-2);
  for(const attempt of attempts)assert.equal(JSON.parse(attempt.options.body).retryApproval,true);
  assert.equal(page.get('pairing').hidden,false);
});
test('manual pairing can collect approval when its original response was lost',async()=>{
  let requests=0;const credential='n'.repeat(43),bootstrap='q'.repeat(43);
  const page=browserHarness({hash:'',respond:(path,options)=>{
    if(path==='/api/pair'){
      if(++requests===1)throw new Error('Response lost after approval');
      return {body:{state:'ready',code:'',token:bootstrap,deviceToken:credential}};
    }
    assert.equal(options.headers.Authorization,'Bearer '+credential);
    return {body:{state:'ready',code:''}};
  }});await settle();
  page.get('entryCode').value='12345678';await page.get('entry').onsubmit({preventDefault(){}});await settle();
  assert.equal(page.get('entry').hidden,true);
  assert.equal(page.get('connect').hidden,false);
  await runTimer(page,1000);
  assert.equal(loadConnection(page.storage).token,credential);
  assert.equal(page.get('navLeft').disabled,false);
});
test('an expired manual request with a lost token retries explicitly using its original secret',async()=>{
  let requests=0;
  const page=browserHarness({hash:'',respond:(path,options)=>{
    if(path==='/api/pair'){
      if(++requests===1)throw new Error('Original response lost');
      if(requests===2)return {status:401,body:{reason:'approvalExpired',error:'Approval expired'}};
      assert.equal(JSON.parse(options.body).retryApproval,true);
      return {body:{state:'pending',code:'654321',token:'q'.repeat(43),expiresIn:60}};
    }
    return {body:{state:'pending',code:'654321',expiresIn:60}};
  }});await settle();
  page.get('entryCode').value='12345678';await page.get('entry').onsubmit({preventDefault(){}});await settle();
  await runTimer(page,1000);
  assert.match(page.get('status').textContent,/Approval expired/);
  assert.equal(page.timers.size,0);
  await page.get('connect').onclick();await settle();
  const attempts=page.calls.filter(c=>c.path==='/api/pair').map(c=>JSON.parse(c.options.body));
  assert.equal(attempts.length,3);
  assert.ok(attempts.every(body=>body.pairingSecret===attempts[0].pairingSecret));
  assert.equal(page.get('code').textContent,'654321');
});
test('a zero-second approval response leaves no polling timer after expiring',async()=>{
  let remaining=60;
  const page=browserHarness({respond:()=>({body:{state:'pending',code:'123456',expiresIn:remaining}})});await settle();
  remaining=0;await runTimer(page,2000);
  assert.match(page.get('status').textContent,/Approval expired/);
  assert.equal(page.timers.size,0);
});

test('the English remote uses one compact header and an inline native search input',()=>{
  const header=appHTML.match(/<header\b[^>]*>([\s\S]*?)<\/header>/)[1];
  assert.equal((header.match(/<button\b/g)||[]).length,5);
  assert.ok(header.indexOf('id="help"')<header.indexOf('id="settings"'));
  assert.ok(header.indexOf('data-key="mute"')<header.indexOf('data-key="volumeDown"'));
  assert.ok(header.indexOf('data-key="volumeDown"')<header.indexOf('data-key="volumeUp"'));
  assert.equal(/id="(?:keyboard|keyboardDialog)"/.test(appHTML),false);
  assert.match(appHTML,/<input id="text" type="search" enterkeyhint="search"/);
  assert.equal(/<textarea|data-key="(?:space|tab)"/.test(appHTML),false);
});
test('Search sends the text followed by Enter in one ordered batch',async()=>{
  const page=browserHarness({saved:true});await settle();
  page.get('text').value='A movie 🎬';page.get('text').oninput();
  assert.equal(page.get('send').disabled,false);
  await page.get('composer').onsubmit({preventDefault(){}});
  assert.deepEqual(scrollCommands(page),[{type:'text',text:'A movie 🎬'},{type:'key',key:'returnKey'}]);
  assert.equal(page.get('text').value,'');assert.equal(page.get('send').disabled,true);
  await page.get('composer').onsubmit({preventDefault(){}});
  assert.equal(page.calls.filter(c=>c.path==='/api/commands').length,1);
});
test('IME confirmation cannot prematurely submit a search',async()=>{
  const page=browserHarness({saved:true});await settle();
  const text=page.get('text');text.value='검색';text.handlers.compositionstart();
  let prevented=false;text.handlers.keydown({key:'Enter',isComposing:true,preventDefault(){prevented=true;}});
  assert.equal(prevented,true);
  await page.get('composer').onsubmit({preventDefault(){}});
  assert.equal(page.calls.some(c=>c.path==='/api/commands'),false);
  text.handlers.compositionend();
  prevented=false;text.handlers.keydown({key:'Enter',keyCode:229,preventDefault(){prevented=true;}});assert.equal(prevented,true);
  await page.get('composer').onsubmit({preventDefault(){}});
  assert.deepEqual(scrollCommands(page),[{type:'text',text:'검색'},{type:'key',key:'returnKey'}]);
});
test('the visual viewport shrinks the remote and scrolls the focused native input into view',async()=>{
  const viewport={height:844,offsetTop:0};const page=browserHarness({saved:true,viewport});await settle();
  assert.equal(page.cssVariables.get('--remote-height'),'844px');
  viewport.height=400;viewport.offsetTop=10;page.viewportHandlers.resize();
  page.get('text').getBoundingClientRect=()=>({top:700,bottom:748});page.get('text').focus();await runTimer(page,16);
  assert.equal(page.cssVariables.get('--remote-height'),'400px');assert.equal(page.cssVariables.get('--remote-top'),'10px');
  assert.equal(page.get('main').classList.contains('keyboard-open'),true);
  assert.equal(page.get('text').scrolled,true);
  page.get('text').blur();assert.equal(page.get('main').classList.contains('keyboard-open'),false);
});
