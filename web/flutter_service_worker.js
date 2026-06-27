'use strict';
// mediBO kill-SW: immediately activates and unregisters itself + clears caches.
// Deployed instead of deleted so PWA clients always receive a fresh SW on their
// periodic update check. Once activated, it unregisters and reloads all tabs.

self.addEventListener('install', () => {
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    (async () => {
      // Clear every cache entry so stale Flutter bundles are gone.
      try {
        const keys = await caches.keys();
        await Promise.all(keys.map((k) => caches.delete(k)));
      } catch (e) {
        console.warn('[mediBO-killSW] cache clear failed', e);
      }

      // Unregister this SW so no future requests are intercepted.
      try {
        await self.registration.unregister();
      } catch (e) {
        console.warn('[mediBO-killSW] unregister failed', e);
      }

      // Reload all open tabs so they fetch fresh HTML + JS.
      try {
        const clients = await self.clients.matchAll({ type: 'window' });
        clients.forEach((client) => {
          if (client.url && 'navigate' in client) {
            client.navigate(client.url);
          }
        });
      } catch (e) {
        console.warn('[mediBO-killSW] client reload failed', e);
      }
    })()
  );
});
