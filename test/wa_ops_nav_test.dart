// WhatsApp Ops — the screen, and every WhatsApp screen being reachable.
//
// TWO THINGS ARE UNDER TEST HERE, and both have already cost deploys.
//
// A. NAV MEMBERSHIP. A nav destination needs BOTH a row in a list here AND a
//    case in _handleAdminNav in home_shell.dart. #645/#646 shipped screens with
//    neither surface wired, then a surface with no route case — a row that
//    renders perfectly and does nothing on tap. This file can assert the list
//    half; the switch half is asserted by the build (a missing case is a dead
//    key, a wrong screen name is a compile error).
//
//    home_shell.dart is deliberately NOT imported: it transitively pulls in
//    web-only libraries and cannot load on the Dart VM. That is the whole
//    reason the nav lists live in admin_nav_entries.dart, which imports nothing
//    heavier than material.dart and RenderLog.
//
// B. THE OPS SCREEN RENDERS THE BACKEND'S SENTENCES. stage_label, pipeline_note,
//    templates_label, free_from_label are printed as given, and the template
//    bar sits where templates_pct put it. Nothing here checks a sentence this
//    app assembled, because this app assembles none.
//
// Fixtures mirror the real wa_event_routes_screen() / wa_waba_status() /
// wa_contact_ledger() payloads, read off pg_get_functiondef on 2026-08-04.
// Every RPC is stubbed inline: no network, no Supabase, no goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/admin_nav_entries.dart';
import 'package:pharma_b2b/screens/admin/wa_ops_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

// ── fixtures ─────────────────────────────────────────────────────────────────

Map<String, dynamic> _route({
  String eventKey = 'order_placed',
  String label = 'Order placed',
  String description = 'Sent to the customer the moment an order is accepted.',
  bool autoManage = true,
  String stageLabel = 'Waiting on Meta approval',
  String stageTone = 'warn',
  String pipelineNote = 'The template was submitted to Meta and is queued for '
      'review. It switches on by itself once approved.',
  bool enabled = false,
}) =>
    {
      'event_key': eventKey,
      'label': label,
      'description': description,
      'template_name': 'order_placed_v2',
      'language': 'en',
      'enabled': enabled,
      'status_label': enabled ? 'On' : 'Off',
      'status_tone': enabled ? 'good' : 'muted',
      'window_label': 'Sends any time — transactional',
      'variable_map': {'1': 'order_no'},
      'sent_30d': 412,
      'languages_live': ['en'],
      'updated_label': '04 Aug, 11:20 AM',
      'auto_manage': autoManage,
      'auto_template_name': 'order_placed_v2',
      'pipeline_note': pipelineNote,
      'meta_status': 'PENDING',
      'stage': 'waiting_meta',
      'stage_label': stageLabel,
      'stage_tone': stageTone,
      'bypass_send_window': true,
      'dedupe_minutes': 45,
    };

Map<String, dynamic> _routesPayload({List<Map<String, dynamic>>? rows}) => {
      'rows': rows ?? [_route()],
      'approved_templates': [
        {
          'id': 't-1',
          'name': 'order_placed_v2',
          'language': 'en',
          'category': 'UTILITY',
          'label': 'order_placed_v2 (en)',
        },
      ],
      'note': 'Each event sends the approved template you pick here.',
    };

Map<String, dynamic> _wabaPayload({
  num pct = 42,
  String templatesLabel = '105 of 250 templates used',
  String? error,
}) =>
    {
      'waba_name': 'mediBO',
      'review_status': 'APPROVED',
      'templates_label': templatesLabel,
      'templates_used': 105,
      'templates_limit': 250,
      'templates_pct': pct,
      'templates_tone': 'good',
      'tier_label': 'Messaging tier: TIER_10K',
      'quality_label': 'Number quality: GREEN',
      'quality_tone': 'good',
      'checked_label': 'Checked 04 Aug, 09:00 AM',
      'error': error,
      'note': 'Meta caps a WhatsApp Business Account at 250 templates.',
    };

Map<String, dynamic> _ledgerPayload({List<Map<String, dynamic>>? rows}) => {
      'window_days': 30,
      'cap_days': 3,
      'contacts': rows?.length ?? 1,
      'summary': '1 contact(s) messaged in the last 30 days; marketing cap is '
          'one per 3 days across every campaign',
      'rows': rows ??
          [
            {
              'phone': '919876543210',
              'messages': 6,
              'marketing': 2,
              'campaigns': 2,
              'last_marketing_label': '03 Aug, 06:10 PM',
              'last_any_label': '04 Aug, 10:02 AM',
              'blocked_now': true,
              'free_from_label': 'Marketing allowed again 06 Aug, 06:10 PM',
              'tone': 'warn',
            },
          ],
    };

/// Pumps the whole screen with every RPC stubbed. `refreshDelay` is zero so the
/// Refresh path never sits on a real three-second timer in a test.
Future<List<Map<String, dynamic>>> _pumpOps(
  WidgetTester tester, {
  Map<String, dynamic>? routes,
  Map<String, dynamic>? waba,
  Map<String, dynamic>? ledger,
  Map<String, dynamic>? saveResult,
}) async {
  // Widget tests default to an 800 px-tall viewport; the ops screen is taller
  // than that, so give it room rather than letting sections fall off-screen.
  tester.view.physicalSize = const Size(500, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final saves = <Map<String, dynamic>>[];

  await tester.pumpWidget(MaterialApp(
    home: WaOpsScreen(
      refreshDelay: Duration.zero,
      routesRpc: () async => routes ?? _routesPayload(),
      routeSaveRpc: (params) async {
        saves.add(params);
        return saveResult ?? {'ok': true, 'event_key': params['p_event_key']};
      },
      wabaStatusRpc: () async => waba ?? _wabaPayload(),
      wabaRefreshRpc: () async => {'ok': true, 'queued': true},
      ledgerRpc: (days, phone) async => ledger ?? _ledgerPayload(),
    ),
  ));
  await tester.pumpAndSettle();
  return saves;
}

void main() {
  // The #639 seam. Every section of this screen calls RenderLog.write, whose
  // 800 ms debounce is a REAL Timer: left on, it outlives the test (which the
  // binding fails on) and tries to reach Supabase from a VM test.
  setUpAll(() => RenderLog.flushEnabled = false);

  // ── A. nav membership ──────────────────────────────────────────────────────

  group('nav', () {
    test('every WhatsApp screen has an overflow entry with a route key', () {
      final routes =
          kAdminOverflowNav.map((e) => e.route).whereType<String>().toSet();

      // All five, by the exact keys _handleAdminNav switches on. A typo here
      // renders a row that does nothing on tap — the bug this file exists for.
      for (final key in const [
        'wa_templates',
        'wa_campaigns',
        'wa_segments',
        'wa_drips',
        'wa_ops',
      ]) {
        expect(routes, contains(key), reason: 'missing overflow route $key');
      }
    });

    test('every overflow entry carries a route, a label and an icon', () {
      // An entry with a null route reaches nav('') and silently does nothing.
      for (final e in kAdminOverflowNav) {
        expect(e.route, isNotNull, reason: '${e.label} has no route key');
        expect(e.route, isNotEmpty, reason: '${e.label} has an empty route');
        expect(e.label, isNotEmpty);
      }
    });

    test('the bottom bar still has exactly five tabs', () {
      // A sixth wraps every label at 360 px. New destinations go to the
      // overflow list, never here.
      expect(kAdminBottomNav.length, 5);
    });

    test('no existing nav entry was lost', () {
      expect(kAdminTopNav.map((e) => e.label).toList(), const [
        'Dashboard',
        'WhatsApp',
        'Customers',
        'Suppliers',
        'Fulfillment',
      ]);
      expect(kAdminBottomNav.map((e) => e.label).toList(), const [
        'Dashboard',
        'WhatsApp',
        'Customers',
        'Suppliers',
        'Fulfill',
      ]);
      // The two entries #647 added must survive, in place, at the front.
      expect(kAdminOverflowNav[0].route, 'wa_templates');
      expect(kAdminOverflowNav[1].route, 'wa_campaigns');
    });

    testWidgets('the phone profile sheet offers all five, and hands the '
        'right key to nav', (tester) async {
      tester.view.physicalSize = const Size(390, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final fired = <String>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AdminProfileMenuTiles(
              isSuperAdmin: false,
              nav: fired.add,
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      for (final e in kAdminOverflowNav) {
        expect(find.text(e.label), findsOneWidget,
            reason: '${e.label} missing from the mobile sheet');
      }

      await tester.tap(find.text('WhatsApp Ops'));
      await tester.pumpAndSettle();
      expect(fired, contains('wa_ops'));
    });
  });

  // ── B. section A — event routes ────────────────────────────────────────────

  group('event routes', () {
    testWidgets('a warn-stage row prints stage_label and pipeline_note',
        (tester) async {
      await _pumpOps(tester);

      expect(find.text('Waiting on Meta approval'), findsOneWidget);
      expect(
          find.text('The template was submitted to Meta and is queued for '
              'review. It switches on by itself once approved.'),
          findsOneWidget);
      // The row's own words, not a status this app translated.
      expect(find.text('Order placed'), findsOneWidget);
    });

    testWidgets('auto_manage hides the controls until Override is tapped',
        (tester) async {
      await _pumpOps(tester);

      expect(find.byKey(const Key('wa_ops_template_picker')), findsNothing);
      expect(find.byKey(const Key('wa_ops_enabled_switch')), findsNothing);
      expect(find.text('Override'), findsOneWidget);

      await tester.tap(find.text('Override'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('wa_ops_template_picker')), findsOneWidget);
      expect(find.byKey(const Key('wa_ops_enabled_switch')), findsOneWidget);
      // Override is spent — it does not sit alongside the controls it revealed.
      expect(find.text('Override'), findsNothing);
    });

    testWidgets('a hand-managed row shows its controls with no Override',
        (tester) async {
      await _pumpOps(tester,
          routes: _routesPayload(rows: [_route(autoManage: false)]));

      expect(find.text('Override'), findsNothing);
      expect(find.byKey(const Key('wa_ops_template_picker')), findsOneWidget);
    });

    testWidgets('the send-any-time control reads bypass_send_window, never '
        'window_label', (tester) async {
      await _pumpOps(tester,
          routes: _routesPayload(rows: [_route(autoManage: false)]));

      // #648 shipped this tristate-and-unknown because the payload carried no
      // boolean. It does now, so the control is plainly two-state and starts
      // from that value — while window_label remains something this screen
      // only ever prints. Full coverage lives in wa_ops_window_switch_test.
      final sw = tester
          .widget<Switch>(find.byKey(const Key('wa_ops_bypass_switch')));
      expect(sw.value, isTrue);
      expect(find.text('Sends any time — transactional'), findsOneWidget);
    });

    testWidgets('toggling enabled saves without p_variable_map or '
        'p_bypass_window', (tester) async {
      final saves = await _pumpOps(tester,
          routes: _routesPayload(rows: [_route(autoManage: false)]));

      await tester.tap(find.byKey(const Key('wa_ops_enabled_switch')));
      await tester.pumpAndSettle();

      expect(saves, hasLength(1));
      expect(saves.single['p_event_key'], 'order_placed');
      expect(saves.single['p_enabled'], true);
      // Untouched fields are not sent at all — wa_event_route_save coalesces,
      // so an absent key means "leave it alone".
      expect(saves.single.containsKey('p_variable_map'), isFalse);
      expect(saves.single.containsKey('p_bypass_window'), isFalse);
    });

    testWidgets('a save error prints the backend message and changes nothing',
        (tester) async {
      await _pumpOps(tester,
          routes: _routesPayload(rows: [_route(autoManage: false)]),
          saveResult: {
            'error': 'no_template',
            'message': 'Choose a template before switching this event on',
          });

      await tester.tap(find.byKey(const Key('wa_ops_enabled_switch')));
      await tester.pumpAndSettle();

      expect(find.text('Choose a template before switching this event on'),
          findsOneWidget);
      // The switch never moved: no optimistic paint to roll back.
      final sw =
          tester.widget<Switch>(find.byKey(const Key('wa_ops_enabled_switch')));
      expect(sw.value, isFalse);
    });

    testWidgets('the top-level note renders once, above the list',
        (tester) async {
      await _pumpOps(tester);
      expect(find.text('Each event sends the approved template you pick here.'),
          findsOneWidget);
    });

    testWidgets('not_authorized prints the backend code, no figures',
        (tester) async {
      await _pumpOps(tester, routes: {'error': 'not_authorized'});
      expect(find.text('not_authorized'), findsWidgets);
      expect(find.text('Order placed'), findsNothing);
    });
  });

  // ── C. section B — account health ──────────────────────────────────────────

  group('account health', () {
    testWidgets('templates_label renders with a bar at templates_pct',
        (tester) async {
      await _pumpOps(tester, waba: _wabaPayload(pct: 42));

      expect(find.text('105 of 250 templates used'), findsOneWidget);

      final bar = tester.widget<LinearProgressIndicator>(
          find.byKey(const Key('wa_ops_templates_bar')));
      expect(bar.value, closeTo(0.42, 0.0001));

      expect(find.text('Messaging tier: TIER_10K'), findsOneWidget);
      expect(find.text('Number quality: GREEN'), findsOneWidget);
      expect(find.text('Checked 04 Aug, 09:00 AM'), findsOneWidget);
    });

    testWidgets('a Meta error replaces the figures, in the bad tone',
        (tester) async {
      await _pumpOps(tester,
          waba: _wabaPayload(error: 'Token expired at Meta'));

      expect(find.text('Token expired at Meta'), findsOneWidget);
      expect(find.byKey(const Key('wa_ops_waba_error')), findsOneWidget);
      // Figures are gone, not merely pushed down.
      expect(find.byKey(const Key('wa_ops_templates_bar')), findsNothing);
      expect(find.text('105 of 250 templates used'), findsNothing);
    });

    testWidgets('Refresh queues, waits, then re-reads', (tester) async {
      var reads = 0;
      var queued = 0;
      tester.view.physicalSize = const Size(500, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        home: WaOpsScreen(
          refreshDelay: Duration.zero,
          routesRpc: () async => _routesPayload(),
          routeSaveRpc: (p) async => {'ok': true},
          wabaStatusRpc: () async {
            reads++;
            return _wabaPayload(
                templatesLabel: reads == 1 ? 'stale' : 'fresh label');
          },
          wabaRefreshRpc: () async {
            queued++;
            return {'ok': true, 'queued': true};
          },
          ledgerRpc: (d, p) async => _ledgerPayload(),
        ),
      ));
      await tester.pumpAndSettle();

      expect(reads, 1);
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();

      expect(queued, 1);
      expect(reads, 2);
      expect(find.text('fresh label'), findsOneWidget);
    });
  });

  // ── D. section C — contact ledger ──────────────────────────────────────────

  group('contact ledger', () {
    testWidgets('a blocked row renders free_from_label', (tester) async {
      await _pumpOps(tester);

      expect(find.text('Marketing allowed again 06 Aug, 06:10 PM'),
          findsOneWidget);
      expect(find.text('919876543210'), findsOneWidget);
      expect(find.text('03 Aug, 06:10 PM'), findsOneWidget);
    });

    testWidgets('an unblocked row shows no cap chip', (tester) async {
      await _pumpOps(tester,
          ledger: _ledgerPayload(rows: [
            {
              'phone': '919000000001',
              'messages': 1,
              'marketing': 0,
              'campaigns': 1,
              'last_marketing_label': 'Never',
              'last_any_label': '04 Aug, 10:02 AM',
              'blocked_now': false,
              'free_from_label': 'Can be messaged now',
              'tone': 'good',
            },
          ]));

      expect(find.text('919000000001'), findsOneWidget);
      expect(find.text('Can be messaged now'), findsNothing);
    });

    testWidgets('the summary renders, and an empty result shows summary only',
        (tester) async {
      await _pumpOps(tester, ledger: _ledgerPayload(rows: []));

      // An empty result is the summary alone. The sentence is the backend's,
      // printed as given — the app has no "no contacts yet" of its own.
      expect(find.textContaining('marketing cap is'), findsOneWidget);
      expect(find.text('919876543210'), findsNothing);
    });

    testWidgets('searching re-calls with p_phone and p_days still 30',
        (tester) async {
      final calls = <List<dynamic>>[];
      tester.view.physicalSize = const Size(500, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        home: WaOpsScreen(
          refreshDelay: Duration.zero,
          routesRpc: () async => _routesPayload(),
          routeSaveRpc: (p) async => {'ok': true},
          wabaStatusRpc: () async => _wabaPayload(),
          wabaRefreshRpc: () async => {'ok': true},
          ledgerRpc: (days, phone) async {
            calls.add([days, phone]);
            return _ledgerPayload();
          },
        ),
      ));
      await tester.pumpAndSettle();

      expect(calls, [
        [30, null]
      ]);

      await tester.enterText(
          find.byKey(const Key('wa_ops_ledger_search')), '9876543210');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(calls.last, [30, '9876543210']);
    });
  });
}
