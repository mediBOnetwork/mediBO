// firebase-messaging-sw.js  — FCM service worker for mediBO admin web push
// ─────────────────────────────────────────────────────────────────────────────
// SETUP REQUIRED (Firebase Console → Project Settings → General → Your apps):
//   Replace the FIREBASE_CONFIG placeholder below with your actual config.
//   Also replace VAPID_KEY in index.html with your Web Push certificate key.
// ─────────────────────────────────────────────────────────────────────────────

// Activate immediately and take control of all clients so updates reach users
// without requiring a tab close. This SW does NOT intercept fetch requests (no
// fetch handler) so it cannot serve stale app shell.
self.addEventListener('install', e => e.waitUntil(self.skipWaiting()));
self.addEventListener('activate', e => e.waitUntil(clients.claim()));

importScripts('https://www.gstatic.com/firebasejs/10.12.2/firebase-app-compat.js');
importScripts('https://www.gstatic.com/firebasejs/10.12.2/firebase-messaging-compat.js');

// ── PLACEHOLDER — fill in your Firebase project credentials ─────────────────
const FIREBASE_CONFIG = {
  apiKey:            "REPLACE_WITH_FIREBASE_API_KEY",
  authDomain:        "REPLACE_WITH_PROJECT_ID.firebaseapp.com",
  projectId:         "REPLACE_WITH_PROJECT_ID",
  storageBucket:     "REPLACE_WITH_PROJECT_ID.appspot.com",
  messagingSenderId: "REPLACE_WITH_SENDER_ID",
  appId:             "REPLACE_WITH_APP_ID",
};
// ─────────────────────────────────────────────────────────────────────────────

const ADMIN_PATH = '/';          // change to '/admin' if you host admin separately
const PENDING_TAB_HASH = '#/customers/pending';

let messaging;
try {
  firebase.initializeApp(FIREBASE_CONFIG);
  messaging = firebase.messaging();
} catch (e) {
  console.warn('[FCM-SW] Firebase init failed — credentials not configured:', e.message);
}

// ── Background push handler ───────────────────────────────────────────────────
self.addEventListener('push', event => {
  if (!event.data) return;
  let payload;
  try { payload = event.data.json(); } catch (_) { return; }

  const data    = payload.data    || {};
  const notif   = payload.notification || {};
  const title   = notif.title || data.title || 'New mediBO Registration';
  const body    = notif.body  || data.body  || 'A new pharmacy registration is waiting for approval.';
  const regId   = data.regId  || '';

  event.waitUntil(
    clients.matchAll({ type: 'window', includeUncontrolled: true }).then(clientList => {
      // Dedup: if any window client is open and visible, post a message to it
      // and SKIP the OS notification (the in-app realtime popup already fires).
      const focusedClient = clientList.find(
        c => c.visibilityState === 'visible'
      );
      if (focusedClient) {
        // App is open & focused — send message, suppress OS notif
        focusedClient.postMessage({ type: 'new_registration', regId });
        return;
      }

      // App is backgrounded or closed — show OS notification
      return self.registration.showNotification(title, {
        body,
        icon:  '/icons/Icon-192.png',
        badge: '/icons/Icon-maskable-192.png',
        tag:   'medibo-new-reg-' + regId,      // replace if new push arrives
        renotify: false,
        data:  { regId, url: ADMIN_PATH + '?tab=pending' },
        actions: [
          { action: 'approve', title: 'Open Admin' },
        ],
        requireInteraction: true,              // stay visible until tapped
      });
    })
  );
});

// ── Notification click → open / focus admin tab ───────────────────────────────
self.addEventListener('notificationclick', event => {
  event.notification.close();
  const targetUrl = (event.notification.data && event.notification.data.url)
    ? event.notification.data.url
    : ADMIN_PATH;

  event.waitUntil(
    clients.matchAll({ type: 'window', includeUncontrolled: true }).then(clientList => {
      // Focus existing admin tab
      for (const client of clientList) {
        if (client.url.includes(location.origin) && 'focus' in client) {
          client.postMessage({
            type: 'navigate_to_pending',
            regId: event.notification.data?.regId || '',
          });
          return client.focus();
        }
      }
      // Open new tab
      if (clients.openWindow) return clients.openWindow(targetUrl);
    })
  );
});

// ── FCM background message (when Firebase messaging is active) ────────────────
if (messaging) {
  messaging.onBackgroundMessage(payload => {
    // Already handled by the 'push' event above; this is the FCM compat path.
    console.log('[FCM-SW] background message', payload);
  });
}
