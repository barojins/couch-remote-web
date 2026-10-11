import test from 'node:test';
import assert from 'node:assert/strict';
import {Gesture, Motion, coalesce} from '../Web/gesture.js';
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
function browserHarness({saved=false,fail=false}={}) {
  const token='t'.repeat(43), client='01234567-89ab-4def-8123-456789abcdef';
  const values=new Map(), storage={getItem:k=>values.get(k),setItem:(k,v)=>values.set(k,v),removeItem:k=>values.delete(k)};
  if(saved)saveConnection(storage,token,client);
  const elements=new Map(), listeners={}, timers=new Map(), calls=[];
  let timerID=0;
  const get=id=>{
    if(!elements.has(id))elements.set(id,{hidden:false,disabled:false,value:'',textContent:'',style:{},classList:{toggle(){}},addEventListener(){},focus(){},showModal(){},close(){}});
    return elements.get(id);
  };
  const document={hidden:false,getElementById:get,querySelectorAll:()=>[],addEventListener:(name,fn)=>listeners[name]=fn};
  let state='ready', failure=fail, rejected=false;
  const context={document,location:{hash:saved?'':'#'+'q'.repeat(43),pathname:'/'},history:{replaceState(){}},localStorage:storage,
    crypto:webcrypto,Gesture,coalesce,loadConnection,saveConnection,forgetConnection,retryDelay,AbortController,TextEncoder,
    setTimeout:(fn,ms)=>{const id=++timerID;timers.set(id,{fn,ms});return id;},clearTimeout:id=>timers.delete(id),
    requestAnimationFrame:fn=>{const id=++timerID;timers.set(id,{fn,ms:16});return id;},cancelAnimationFrame:id=>timers.delete(id),
    addEventListener:(name,fn)=>listeners[name]=fn,
    fetch:async(path,options)=>{
      calls.push({path,options});
      if(failure)throw new Error('offline');
      return {ok:!rejected,status:rejected?403:200,json:async()=>rejected?{error:'revoked'}:{state,code:'',...(!saved && path==='/api/status'?{deviceToken:token}:{})}};
    }
  };
  runInNewContext(appSource,context);
  return {get,document,listeners,timers,calls,storage,token,
    setFailure:value=>failure=value,setRejected:value=>rejected=value,setState:value=>state=value};
}
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
