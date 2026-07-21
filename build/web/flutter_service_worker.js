// mediBO self-destruct service worker — unregisters itself and purges all caches.
// c409_sw_autoupdate: clients.claim() so an activating instance takes control of
// already-open tabs immediately, making the forced client.navigate() below reach
// every open tab reliably.
self.addEventListener('install', function (e) { self.skipWaiting(); });
self.addEventListener('activate', function (e) {
  e.waitUntil((async function () {
    try {
      await self.clients.claim();
    } catch (err) {}
    try {
      var keys = await caches.keys();
      await Promise.all(keys.map(function (k) { return caches.delete(k); }));
    } catch (err) {}
    try {
      await self.registration.unregister();
    } catch (err) {}
    try {
      var clients = await self.clients.matchAll({ type: 'window' });
      clients.forEach(function (c) { c.navigate(c.url); });
    } catch (err) {}
  })());
});
self.addEventListener('fetch', function (e) { return; });
