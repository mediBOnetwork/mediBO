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

// CMD #1989 — the order card's fallbacks. The live values come from the
// payload (`alert.notif`); these only cover a push that predates this worker.
const ORDER_TAG   = 'medibo_orders';
const ORDER_PATH  = '/admin/order-alerts';
const ORDER_ICON  = '/icons/medibo-monogram-192.png';
const ORDER_BADGE = '/icons/medibo-monogram-72.png';

let messaging;
try {
  firebase.initializeApp(FIREBASE_CONFIG);
  messaging = firebase.messaging();
} catch (e) {
  console.warn('[FCM-SW] Firebase init failed — credentials not configured:', e.message);
}

// ── Background push handler ───────────────────────────────────────────────────
//
// CMD #1989 — an order alert is DRAWN here, never composed here. Everything the
// card shows arrives in `alert.notif`, rendered by order_alert_notif(): the
// title is the shop, the body is the money, the single action's word, the
// summary line when several are waiting, the channel, the tag that groups them
// and the brand accent. This worker joins no strings and pluralises nothing.
self.addEventListener('push', event => {
  if (!event.data) return;
  let payload;
  try { payload = event.data.json(); } catch (_) { return; }

  const data  = payload.data || {};
  const notif = payload.notification || {};
  let alert = data.alert || payload.alert || null;
  if (typeof alert === 'string') { try { alert = JSON.parse(alert); } catch (_) { alert = null; } }

  // ── An ORDER alert: the designed card ──────────────────────────────────────
  if (alert && (alert.kind === 'order_alert' || alert.notif)) {
    event.waitUntil(showOrderCard(alert, notif, data));
    return;
  }

  // ── Anything else keeps the registration behaviour it has always had ───────
  const title = notif.title || data.title || 'New mediBO Registration';
  const body  = notif.body  || data.body  || 'A new pharmacy registration is waiting for approval.';
  const regId = data.regId  || '';

  event.waitUntil(
    clients.matchAll({ type: 'window', includeUncontrolled: true }).then(clientList => {
      const focusedClient = clientList.find(c => c.visibilityState === 'visible');
      if (focusedClient) {
        focusedClient.postMessage({ type: 'new_registration', regId });
        return;
      }
      return self.registration.showNotification(title, {
        body,
        icon:  '/icons/Icon-192.png',
        badge: '/icons/Icon-maskable-192.png',
        tag:   'medibo-new-reg-' + regId,
        renotify: false,
        data:  { regId, url: ADMIN_PATH + '?tab=pending' },
        actions: [{ action: 'approve', title: 'Open Admin' }],
        requireInteraction: true,
      });
    })
  );
});

// The order card. ONE tag, so several waiting orders collapse into a single
// entry in the tray (item 8); the backend's summary line replaces the body the
// moment there is more than one, so the tray never lies about how many wait.
function showOrderCard(alert, notif, data) {
  const n = alert.notif || {};
  const title = n.title || alert.push_title || notif.title || data.title || '';
  const body  = (n.count > 1 && n.summary) ? n.summary
              : (n.body || alert.push_body || notif.body || data.body || '');
  const actions = Array.isArray(n.actions) && n.actions.length
    ? n.actions.map(a => ({ action: a.action, title: a.title }))
    : [{ action: 'open', title: n.open_label || alert.open_label || 'Open' }];

  return self.registration.showNotification(title, {
    body,
    icon:  n.icon  || ORDER_ICON,
    badge: n.badge || ORDER_BADGE,
    tag: n.tag || ORDER_TAG,
    renotify: n.renotify !== false,
    // "Ongoing while unactioned" — the card does not fade away on its own.
    requireInteraction: n.require_interaction !== false,
    silent: alert.silent === true,
    actions: actions.slice(0, 1),   // item 7 — ONE action, and it only opens
    data: {
      kind: 'order_alert',
      orderId: n.order_id || alert.order_id || '',
      orderCode: n.order_code || alert.order_code || '',
      url: (n.deep_link || alert.deep_link || ORDER_PATH),
    },
  });
}

// ── Item 8 — it clears when the order is opened ANYWHERE ─────────────────────
// The app posts this the moment order_alert_seen() succeeds, on whichever
// device opened the order.
self.addEventListener('message', event => {
  const msg = event.data || {};
  if (msg.type !== 'order_alert_seen') return;
  event.waitUntil(closeOrderCards(msg.orderId || ''));
});

function closeOrderCards(orderId) {
  return self.registration.getNotifications()
    .then(all => {
      all.forEach(nf => {
        const d = nf.data || {};
        if (d.kind !== 'order_alert') return;
        // No id means "clear the order cards" — the backend has already
        // stamped the row, so the tray is the only stale copy left.
        if (!orderId || !d.orderId || d.orderId === orderId) nf.close();
      });
    })
    .catch(() => {});
}

// ── Notification click → open / focus the right screen ───────────────────────
self.addEventListener('notificationclick', event => {
  const d = event.notification.data || {};
  event.notification.close();

  if (d.kind === 'order_alert') {
    // Opening it IS the action, whether the card or its one button was tapped.
    event.waitUntil(
      closeOrderCards(d.orderId || '').then(() =>
        clients.matchAll({ type: 'window', includeUncontrolled: true }).then(clientList => {
          for (const client of clientList) {
            if (client.url.includes(location.origin) && 'focus' in client) {
              client.postMessage({ type: 'open_order_alert', orderId: d.orderId || '' });
              return client.focus();
            }
          }
          if (clients.openWindow) return clients.openWindow(d.url || ORDER_PATH);
        })
      )
    );
    return;
  }

  const targetUrl = d.url ? d.url : ADMIN_PATH;
  event.waitUntil(
    clients.matchAll({ type: 'window', includeUncontrolled: true }).then(clientList => {
      for (const client of clientList) {
        if (client.url.includes(location.origin) && 'focus' in client) {
          client.postMessage({ type: 'navigate_to_pending', regId: d.regId || '' });
          return client.focus();
        }
      }
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
