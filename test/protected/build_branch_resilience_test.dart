// test/protected/build_branch_resilience_test.dart — CHANGE #1149
//
// Holds down the one layer that keeps every screen alive while the backend
// blinks. The rules it pins:
//   * a healthy answer is cached AND passed through untouched;
//   * a 503 on a request we have seen answers the LAST GOOD BODY, marked
//     x-medibo-cached, and raises the Reconnecting flag;
//   * a 503 on a request we have never seen is passed through (no invented
//     data) and still raises the flag;
//   * a later 2xx clears the flag;
//   * auth / storage / non-REST traffic is never cached;
//   * the banner prints the backend's copy while down and nothing when up;
//   * the Runner control card prints build_branch_state().display verbatim
//     ("branch: on · 2h 14m") and draws no branch line when none was sent.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pharma_b2b/services/resilient_http.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/dev_queue_service.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/dev_queue_workers.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthClientOptions, SupabaseClient;
import 'package:pharma_b2b/services/ui_copy.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/reconnecting_banner.dart';

void main() {
  setUpAll(() {
    RenderLog.flushEnabled = false;
  });
  setUp(() => Reconnecting.instance.reset());

  final rpc = Uri.parse('https://x.supabase.co/rest/v1/rpc/home_feed');
  final auth = Uri.parse('https://x.supabase.co/auth/v1/token');

  ResilientClient clientWith(int Function(int call) statusFor,
      {String body = '{"ok":true,"rows":[1,2]}'}) {
    var n = 0;
    return ResilientClient(
      MockClient((req) async {
        n++;
        final s = statusFor(n);
        return http.Response(s == 200 ? body : 'unavailable', s,
            headers: {'content-type': 'application/json'});
      }),
      persist: false,
    );
  }

  Future<String> post(http.Client c, Uri u) async {
    final r = await c.post(u, body: '{"p_zone":1}', headers: {'Authorization': 'Bearer t'});
    return '${r.statusCode}|${r.headers[ResilientClient.cachedHeader] ?? ''}|${r.body}';
  }

  group('ResilientClient — cache instead of spin', () {
    test('a healthy answer is cached and passed through', () async {
      final c = clientWith((_) => 200);
      expect(await post(c, rpc), '200||{"ok":true,"rows":[1,2]}');
      expect(c.memoryEntries, 1);
      expect(Reconnecting.instance.down, isFalse);
    });

    test('a 503 on a known request serves the last good body and raises the flag', () async {
      final c = clientWith((n) => n == 1 ? 200 : 503);
      await post(c, rpc);
      final again = await post(c, rpc);
      expect(again, '200|1|{"ok":true,"rows":[1,2]}');
      expect(Reconnecting.instance.down, isTrue);
      expect(Reconnecting.instance.servedFromCache, 1);
    });

    test('a 503 on an unseen request is passed through — nothing is invented', () async {
      final c = clientWith((_) => 503);
      final r = await c.post(rpc, body: '{}');
      expect(r.statusCode, 503);
      expect(r.headers[ResilientClient.cachedHeader], isNull);
      expect(jsonDecode(r.body)['code'], 'PGRST002');
      expect(Reconnecting.instance.down, isTrue);
    });

    test('a later 2xx clears the flag', () async {
      final c = clientWith((n) => n == 2 ? 503 : 200);
      await post(c, rpc);
      await post(c, rpc);
      expect(Reconnecting.instance.down, isTrue);
      await post(c, rpc);
      expect(Reconnecting.instance.down, isFalse);
    });

    test('a different body is a different request', () async {
      final c = clientWith((n) => n <= 2 ? 200 : 503);
      await c.post(rpc, body: '{"p_zone":1}');
      await c.post(rpc, body: '{"p_zone":2}');
      expect(c.memoryEntries, 2);
    });

    test('auth traffic is never cached, even when healthy', () async {
      final c = clientWith((_) => 200);
      await c.post(auth, body: 'grant_type=password');
      expect(c.memoryEntries, 0);
      expect(ResilientClient.cacheable(http.Request('POST', auth)), isFalse);
      expect(ResilientClient.cacheable(http.Request('DELETE', rpc)), isFalse);
      expect(ResilientClient.cacheable(http.Request('GET',
          Uri.parse('https://x.supabase.co/rest/v1/orders?select=id'))), isTrue);
    });

    test('a 4xx is the backend\'s own answer: passed through, not cached, no flag', () async {
      final c = clientWith((_) => 401, body: '');
      final r = await c.post(rpc, body: '{}');
      expect(r.statusCode, 401);
      expect(c.memoryEntries, 0);
      expect(Reconnecting.instance.down, isFalse);
    });
  });

  group('ReconnectingBanner', () {
    testWidgets('draws nothing while up, the copy key while down', (t) async {
      final f = Reconnecting.instance;
      await t.pumpWidget(MaterialApp(home: Scaffold(body: ReconnectingBanner(flag: f))));
      expect(find.byType(Row), findsNothing);
      f.markDown('http 503');
      await t.pump();
      expect(find.byType(Row), findsOneWidget);
      // The sentence is whatever the copy layer holds for 'app.reconnecting'
      // — on the VM nothing is loaded, so c() answers '' and the strip prints
      // '' — never a Dart literal. Asserting equality with c() is the proof.
      final txt = t.widget<Text>(find.byType(Text));
      expect(txt.data, c('app.reconnecting'));
      expect(txt.data, isNot(contains('Reconnecting')));
      f.markUp();
      await t.pump();
      expect(find.byType(Row), findsNothing);
    });
  });

  group('CHANGE #1149 — the control card prints the branch line verbatim', () {
    Widget card(Map<String, dynamic> state) => MaterialApp(
          home: Scaffold(
            body: WorkerGridCard(
              pool: {'config': const {'cap': 3}, 'state': state},
              // A bare client: no auth refresh timer, no realtime socket —
              // the card never calls it in these tests.
              service: DevQueueService(
                  client: SupabaseClient('https://x.supabase.co', 'anon',
                      authOptions:
                          const AuthClientOptions(autoRefreshToken: false))),
              onChanged: () {},
            ),
          ),
        );

    testWidgets('branch_display is the backend sentence, byte for byte',
        (tester) async {
      await tester.pumpWidget(card({
        'active_workers': 2,
        'branch_display': 'branch: on · 2h 14m',
        'quota_display': 'Usage 41%',
      }));
      await tester.pump();
      final line = find.byKey(const Key('c1149_branch_line'));
      expect(line, findsOneWidget);
      expect(tester.widget<Text>(line).data, 'branch: on · 2h 14m');
      expect(find.text('Usage 41%'), findsOneWidget);
    });

    testWidgets('no branch_display → no branch line, not an invented "off"',
        (tester) async {
      await tester.pumpWidget(card({'active_workers': 1}));
      await tester.pump();
      expect(find.byKey(const Key('c1149_branch_line')), findsNothing);
      expect(find.textContaining('branch'), findsNothing);
    });
  });
}
