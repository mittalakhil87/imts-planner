// ExpoWalk service worker — makes the planner installable and lets it open with no network.
// Network-first: always tries the live site, falls back to the last good copy. Never touches /api/.
const CACHE = 'expowalk-v1';
self.addEventListener('install', e => { self.skipWaiting(); e.waitUntil(caches.open(CACHE).then(c => c.addAll(['/imts2026']).catch(() => {}))); });
self.addEventListener('activate', e => { e.waitUntil((async () => { for (const k of await caches.keys()) if (k !== CACHE) await caches.delete(k); await self.clients.claim(); })()); });
self.addEventListener('fetch', e => {
  const req = e.request; const u = new URL(req.url);
  if (req.method !== 'GET' || u.origin !== self.location.origin || u.pathname.startsWith('/api/')) return;
  e.respondWith((async () => {
    try {
      const r = await fetch(req);
      if (r.ok) { const c = await caches.open(CACHE); c.put(req, r.clone()).catch(() => {}); }
      return r;
    } catch (err) {
      const c = await caches.open(CACHE);
      return (await c.match(req)) || (await c.match(u.pathname)) || (u.pathname.startsWith('/imts2026') ? await c.match('/imts2026') : undefined) || Response.error();
    }
  })());
});
