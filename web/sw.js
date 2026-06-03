// EagleCraft service worker — caches everything in the browser so the games and
// EagleCraft keep working offline after the first visit, and all data lives in
// the browser (never the server). Bump CACHE to force a refresh after updates.
const CACHE = 'eaglecraft-v1';

self.addEventListener('install', e => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil((async () => {
  // drop old caches
  for (const k of await caches.keys()) if (k !== CACHE) await caches.delete(k);
  await self.clients.claim();
})()));

self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  // Never cache the API or anything off-origin — those must hit the network.
  if (url.origin !== location.origin || url.pathname.startsWith('/api/')) return;

  e.respondWith((async () => {
    const cache = await caches.open(CACHE);
    const cached = await cache.match(req);
    // Cache-first (so it works offline); refresh in the background when online.
    const network = fetch(req).then(resp => {
      if (resp && resp.status === 200) cache.put(req, resp.clone()).catch(() => {});
      return resp;
    }).catch(() => null);
    return cached || (await network) ||
      new Response('Offline and not cached yet.', { status: 503 });
  })());
});
