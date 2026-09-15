// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;

void reloadPage() => html.window.location.reload();

/// CMD #2028 — "Update Now" on the web: drop every cache the browser is
/// holding for this origin, then reload.
///
/// index.html already unregisters service workers on load and the document
/// itself is served no-store, but a tab that has been open for hours may be
/// sitting on a CacheStorage entry or a service worker registered by an OLDER
/// build. Clearing both before the reload is what makes one press enough.
///
/// Every step is individually guarded and the reload happens regardless: a
/// browser that refuses `caches` (private mode, site data blocked) must still
/// get the new bundle.
void hardReloadPage() {
  Future<void> clear() async {
    try {
      final sw = html.window.navigator.serviceWorker;
      if (sw != null) {
        final regs = await sw.getRegistrations();
        for (final r in regs) {
          try {
            await (r as dynamic).unregister();
          } catch (_) {}
        }
      }
    } catch (_) {}
    try {
      final caches = html.window.caches;
      if (caches != null) {
        final keys = await caches.keys();
        for (final k in keys) {
          try {
            await caches.delete(k as String);
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  clear().whenComplete(() {
    try {
      html.window.location.reload();
    } catch (_) {}
  });
}
