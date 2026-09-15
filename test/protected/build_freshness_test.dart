// CHANGE #657 — every deploy must show on the FIRST load.
//
// Two independent mechanisms keep a browser off a stale bundle, and this file
// pins both because each one covers a hole the other cannot see:
//
//   1. THE DOCUMENT is never cached. web/_headers serves `/`, `/index.html`,
//      `/version.json`, `/flutter_bootstrap.js` and `/main.dart.js` with
//      `no-store`, and the real bundle is fingerprinted per deploy
//      (main.<commit>.dart.js), so a new document can never reference an old
//      bundle. Flutter's caching service worker is switched OFF
//      (`serviceWorkerSettings: null`) and index.html unregisters any service
//      worker and deletes every cache on load — a stronger guarantee than
//      skipWaiting/clients.claim, which still leave a caching layer in place.
//
//   2. THE RUNNING JAVASCRIPT knows which build it is. Everything in (1) is
//      read out of the DOCUMENT, so a browser that boots a stale document reads
//      a stale marker, fetches a fresh /version.json and concludes nothing is
//      wrong. `kBuiltChange` is compiled into main.dart.js by dart2js, so the
//      comparison is running-code against live-build with no cached document in
//      the path. deploy.sh bakes it in with --dart-define=MEDIBO_CHANGE.
//
// The web/ assertions are file-content assertions on purpose: this suite runs on
// the Dart VM with no network and no browser, and a header rule that silently
// disappears is exactly how a stale bundle came back before.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/build_info.dart';

String _read(String path) {
  final f = File(path);
  expect(f.existsSync(), isTrue, reason: '$path must exist');
  return f.readAsStringSync();
}

void main() {
  group('the running bundle carries its own build identity', () {
    test('kBuiltChange is a compile-time define, empty when unstamped', () {
      // In `flutter test` no define is passed, so this is the honest fallback —
      // and it must be treated as "no identity", never as a mismatch.
      expect(kBuiltChange, isA<String>());
      expect(hasBuiltChange, kBuiltChange.isNotEmpty);
    });

    test('deploy.sh stamps MEDIBO_CHANGE into the release build', () {
      final sh = _read('scripts/deploy.sh');
      expect(sh.contains('--dart-define=MEDIBO_CHANGE='), isTrue,
          reason: 'without this define the bundle has no build identity');
      // It must be the CHANGE number, not the commit: deploy.sh creates the
      // commit AFTER the build, so a commit define would always be one behind.
      expect(sh.contains(r'--dart-define=MEDIBO_CHANGE="${N}"'), isTrue);
    });

    test('version_watcher compares the running build, not the first fetch', () {
      final vw = _read('lib/services/version_watcher.dart');
      expect(vw.contains('kBuiltChange'), isTrue);
      expect(vw.contains('hasBuiltChange'), isTrue);
      // One reload, never a loop.
      expect(vw.contains('_staleBundleHandled'), isTrue);
    });
  });

  group('the document is never served from a cache', () {
    test('_headers keeps every entry point no-store', () {
      final h = _read('web/_headers');
      for (final path in const [
        '/index.html',
        '/version.json',
        '/flutter_bootstrap.js',
        '/main.dart.js',
      ]) {
        final i = h.indexOf('\n$path\n');
        expect(i, greaterThan(-1), reason: '$path must have a header rule');
        final block = h.substring(i, i + 160);
        expect(block.contains('no-store'), isTrue,
            reason: '$path must be no-store');
      }
    });

    test('no caching service worker is registered', () {
      // skipWaiting/clients.claim would only make a cache turn over faster.
      // Not having the cache at all is what makes the first load correct.
      expect(_read('web/flutter_bootstrap.js').contains('serviceWorkerSettings: null'),
          isTrue);
      final idx = _read('web/index.html');
      expect(idx.contains('serviceWorker'), isTrue);
      expect(idx.contains('r.unregister()'), isTrue,
          reason: 'index.html must unregister any service worker on load');
      expect(idx.contains('caches.delete(n)'), isTrue,
          reason: 'index.html must drop every cache on load');
    });

    test('index.html reloads once when its stamp is behind version.json', () {
      final idx = _read('web/index.html');
      expect(idx.contains('__MEDIBO_BUILD_COMMIT__'), isTrue,
          reason: 'deploy.sh stamps this placeholder');
      expect(idx.contains('c220_pwa_reloaded'), isTrue,
          reason: 'the sessionStorage guard is what makes it ONE reload');
    });

    test('deploy.sh fingerprints the bundle per build', () {
      final sh = _read('scripts/deploy.sh');
      expect(sh.contains(r'H="main.$SHORT.dart.js"'), isTrue,
          reason: 'a per-deploy filename is what no cache can serve stale');
    });
  });
}
