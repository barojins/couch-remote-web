const key='couch-remote-device-v1';
const validToken=value=>typeof value==='string' && /^[A-Za-z0-9_-]{43}$/.test(value);
export function loadConnection(storage) {
  try {
    const value=JSON.parse(storage.getItem(key));
    return value && validToken(value.token) && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value.client) ? value : null;
  } catch { return null; }
}
export function saveConnection(storage, token, client) {
  try { storage.setItem(key,JSON.stringify({token,client})); return true; } catch { return false; }
}
export function forgetConnection(storage) { try { storage.removeItem(key); } catch {} }
export function retryDelay(attempt) { return Math.min(1000*2**Math.min(attempt,5),30000); }
