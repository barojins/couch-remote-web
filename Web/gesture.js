export const movementDefaults = {sensitivity:1, acceleration:1, smoothing:40};
export function movementSettings(value) {
  const result = {};
  for (const [key,min,max] of [['sensitivity',.25,2],['acceleration',0,2],['smoothing',0,100]]) {
    const number = value && value[key];
    result[key] = typeof number === 'number' && Number.isFinite(number) ? Math.max(min,Math.min(max,number)) : movementDefaults[key];
  }
  return result;
}
export function loadMovement(storage) {
  try { return movementSettings(JSON.parse(storage.getItem('couch-remote-movement-v1'))); }
  catch { return movementSettings(null); }
}
export function saveMovement(storage,value) {
  try { storage.setItem('couch-remote-movement-v1',JSON.stringify(movementSettings(value))); return true; }
  catch { return false; }
}
export function coalesce(previous, next) {
  if (!previous || !['move', 'scroll'].includes(next.type) || previous.type !== next.type) return null;
  const x = previous.x + next.x, y = previous.y + next.y;
  return Math.abs(x) <= 8192 && Math.abs(y) <= 8192 ? {...next, x, y} : null;
}
export class Motion {
  constructor(settings) { this.settings = movementSettings(settings); this.x = 0; this.y = 0; this.speed = null; }
  delta(x, y, speed, scrolling = false, dt = 1/60) {
    // Filter speed, not position: stabilize acceleration without adding cursor
    // lag, momentum after lift-off, or losing tiny fractional movements.
    const weight = this.settings.smoothing === 0 ? 1 : 1 - Math.exp(-Math.max(0, dt) / (this.settings.smoothing/1000));
    this.speed = this.speed === null ? speed : this.speed + weight * (speed - this.speed);
    const t = Math.min(1, Math.max(0, (this.speed - 40) / 760));
    const gain = scrolling ? 1 : this.settings.sensitivity * (.8 + 1.2 * this.settings.acceleration * t * t * (3 - 2 * t));
    this.x += x * gain; this.y += y * gain;
    const dx = Math.trunc(this.x), dy = Math.trunc(this.y);
    this.x -= dx; this.y -= dy;
    if (!dx && !dy) return null;
    return {type: scrolling ? 'scroll' : 'move', x: Math.max(-8192, Math.min(8192, dx)), y: Math.max(-8192, Math.min(8192, dy))};
  }
}
export class Gesture {
  constructor(settings) { this.settings = movementSettings(settings); this.reset(); }
  configure(settings) { this.settings = movementSettings(settings); this.reset(); }
  reset() { this.points = new Map(); this.maxTouches = 0; this.travel = 0; this.start = 0; this.lastTime = 0; this.motion = new Motion(this.settings); this.moving = false; this.pendingX = 0; this.pendingY = 0; }
  center() { const p = [...this.points.values()]; return {x: p.reduce((a,v)=>a+v.x,0)/p.length, y:p.reduce((a,v)=>a+v.y,0)/p.length}; }
  down(id,x,y,time) {
    if (!this.points.size) { this.reset(); this.start = time; }
    this.points.set(id,{x,y}); this.maxTouches = Math.max(this.maxTouches,this.points.size);
    this.lastTime = time; this.motion = new Motion(this.settings); this.pendingX = 0; this.pendingY = 0;
  }
  move(id,x,y,time) {
    if (!this.points.has(id)) return null;
    const before = this.center(); this.points.set(id,{x,y}); const after = this.center();
    if (this.points.size !== this.maxTouches || this.maxTouches > 2) return null;
    const dx = after.x-before.x, dy = after.y-before.y;
    const dt = Math.max(.002, (time-this.lastTime)/1000); this.lastTime = time;
    this.travel += Math.hypot(dx,dy); this.pendingX += dx; this.pendingY += dy;
    if (!this.moving && this.travel < 2) return null;
    this.moving = true;
    const result = this.motion.delta(this.pendingX,this.pendingY,Math.hypot(dx,dy)/dt,this.maxTouches===2,dt);
    this.pendingX=0; this.pendingY=0; return result;
  }
  up(id,time) {
    if(!this.points.has(id)) return null;
    this.points.delete(id); if(this.points.size) return null;
    const tap = !this.moving && time-this.start<350 && this.maxTouches<=2;
    const type = this.maxTouches===2?'rightClick':'click'; this.reset();
    return tap ? type : null;
  }
}
