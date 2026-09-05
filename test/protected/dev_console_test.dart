// PROTECTED — CHANGE #1761.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes where the Dev Queue talks, never to make an unrelated
// change go green.
//
// What this holds down — the Dev Queue's RPCs go to the CONTROL PLANE
// (medibo-dev), never to production, and the app holds no dev URL or key:
//
//   1. The ticket is the backend's. `DevConsoleToken` is built from
//      `dev_console_token()`'s payload (url, anon_key, token, exp) and the
//      only decision Dart makes is WHEN to ask again — from the backend's `exp`.
//   2. One mint per life. Two `client()` calls inside the ticket's life mint
//      once; a clock past `exp` minus the margin mints again; the client sent
//      to medibo-dev carries the `x-dev-console` header and the dev URL.
//   3. A refused mint keeps its words. When production's RPC throws, the
//      service rethrows that exact message — no Dart reassurance, no fallback
//      to production for a dev RPC.
//   4. Routing is a name lookup. `DevQueueService.clientFor` sends a
//      control-plane RPC to the dev client and each name in
//      `productionRpcs` (production's own cron, DB lane, regression guard and
//      diagnostics) to production; storage stays on production.
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:pharma_b2b/screens/admin/dev_queue/dev_queue_service.dart';
import 'package:pharma_b2b/services/dev_console.dart';

Map<String, dynamic> _ticket({int? exp, String url = 'https://dev.invalid'}) => {
      'ok': true,
      'token': 'v1.$exp.b64email.deadbeef',
      'exp': exp ?? 4102444800, // 2100-01-01, far future
      'url': url,
      'anon_key': 'anon-dev-key',
      'email': 'om@example.invalid',
      'project': 'medibo-dev',
    };

void main() {
  group('DevConsoleToken — the ticket is the backend\'s', () {
    test('needsRefresh is decided from exp alone', () {
      final t = DevConsoleToken.fromPayload(_ticket(exp: 1_000_000));
      expect(t.isUsable, isTrue);
      expect(t.headers, {'x-dev-console': 'v1.1000000.b64email.deadbeef'});
      // 11 minutes of life left → still good; 9 minutes → refresh.
      expect(t.needsRefresh(DateTime.fromMillisecondsSinceEpoch((1_000_000 - 660) * 1000, isUtc: true)), isFalse);
      expect(t.needsRefresh(DateTime.fromMillisecondsSinceEpoch((1_000_000 - 540) * 1000, isUtc: true)), isTrue);
      expect(t.needsRefresh(DateTime.fromMillisecondsSinceEpoch(1_000_001 * 1000, isUtc: true)), isTrue);
    });

    test('a payload without url/key/token is not usable', () {
      expect(DevConsoleToken.fromPayload({'ok': false}).isUsable, isFalse);
      expect(DevConsoleToken.fromPayload(_ticket(url: '')).isUsable, isFalse);
    });
  });

  group('DevConsole — one mint per life', () {
    test('mints once, reuses inside the life, re-mints when the backend exp nears', () async {
      var now = DateTime.utc(2026, 9, 5, 18, 0);
      final exp = now.millisecondsSinceEpoch ~/ 1000 + 3600;
      var mints = 0;
      final console = DevConsole(
        mint: () async {
          mints += 1;
          return _ticket(exp: exp);
        },
        clock: () => now,
      );
      final a = await console.client();
      final b = await console.client();
      expect(mints, 1);
      expect(identical(a, b), isTrue);
      expect(a.rest.url, 'https://dev.invalid/rest/v1');
      expect(a.headers['x-dev-console'], 'v1.$exp.b64email.deadbeef');
      expect(console.mints, 1);

      now = now.add(const Duration(minutes: 55)); // 5 min left < 10 min margin
      final c = await console.client();
      expect(mints, 2);
      expect(identical(a, c), isFalse);
    });

    test('a refused mint surfaces the backend\'s own message', () async {
      final console = DevConsole(
        mint: () async => throw const PostgrestException(message: 'dev_console: super admin only'),
        clock: () => DateTime.utc(2026, 9, 5),
      );
      await expectLater(
        console.client(),
        throwsA(isA<PostgrestException>().having((e) => e.message, 'message', 'dev_console: super admin only')),
      );
      expect(console.mints, 0);
    });
  });

  group('DevQueueService — routing is a name lookup', () {
    test('control-plane RPCs use the dev client; production-health RPCs and storage use production',
        () async {
      final dev = SupabaseClient('https://dev.invalid', 'anon-dev');
      final prod = SupabaseClient('https://prod.invalid', 'anon-prod');
      final svc = DevQueueService(client: dev, storageClient: prod);

      expect((await svc.clientFor('dev_cmd_list')).rest.url, 'https://dev.invalid/rest/v1');
      expect((await svc.clientFor('pool_set')).rest.url, 'https://dev.invalid/rest/v1');
      expect((await svc.clientFor('journeys_get')).rest.url, 'https://dev.invalid/rest/v1');
      for (final fn in DevQueueService.productionRpcs) {
        expect((await svc.clientFor(fn)).rest.url, 'https://prod.invalid/rest/v1', reason: fn);
      }
      expect(svc.storageClient.rest.url, 'https://prod.invalid/rest/v1');
      expect(DevQueueService.productionRpcs, containsAll(['cron_health', 'db_health_status', 'rg_guard_card']));
      dev.dispose();
      prod.dispose();
    });

    test('without a pinned client the service mints through DevConsole', () async {
      var mints = 0;
      final console = DevConsole(
        mint: () async {
          mints += 1;
          return _ticket();
        },
        clock: () => DateTime.utc(2026, 9, 5),
      );
      final prod = SupabaseClient('https://prod.invalid', 'anon-prod');
      final svc = DevQueueService(storageClient: prod, console: console);
      final c = await svc.rpcClient();
      expect(mints, 1);
      expect(c.rest.url, 'https://dev.invalid/rest/v1');
      expect(c.headers.containsKey('x-dev-console'), isTrue);
      prod.dispose();
    });
  });
}
