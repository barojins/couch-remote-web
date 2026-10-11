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
