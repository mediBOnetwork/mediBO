// mediBO self-destruct service worker — unregisters itself and purges all caches.
// Exists so browsers with an OLD Flutter SW installed (pre-#238) fetch this on their
// ~24h update check, install it, immediately self-unregister, and release control.
// No new SW is registered (flutter_bootstrap has serviceWorkerVersion:null), so this
// is a one-time cleanup that ages out on its own.
self.addEventListener('install', function (e) { self.skipWaiting(); });
self.addEventListener('activate', function (e) {
  e.waitUntil((async function () {
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
// Never serve from cache — always passthrough to network.
self.addEventListener('fetch', function (e) { return; });
