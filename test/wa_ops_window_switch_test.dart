// WhatsApp Ops — the "send any time" switch reads bypass_send_window.
//
// #648 shipped this control tristate-and-unknown: the payload carried only
// window_label (a sentence), and parsing that sentence back into a bool would
// have been the app holding a second answer to a backend question — reword the
// sentence in Postgres and the switch silently flips. The backend now returns
// the boolean, so the control is a plain two-state switch initialised from it.
//
// What these tests pin down:
//
//   * The switch's value comes from bypass_send_window and NOTHING else. The
//     sharpest test here deliberately feeds a row whose window_label says
//     "Sends any time" while bypass_send_window is false. The switch must read
//     OFF. If anyone ever reintroduces sentence-parsing, that test is the one
//     that fails.
//   * There is no indeterminate state left anywhere — no tristate Checkbox,
//     and the Switch's value is a plain non-null bool.
//   * window_label is still rendered verbatim beneath the switch.
//   * p_bypass_window is sent when an admin toggles, and is ABSENT when they
//     touch something else. wa_event_route_save coalesces, so an absent key
//     means "leave it alone" — sending it unasked would overwrite a change
//     made concurrently anywhere else.
//
// Every RPC is stubbed inline: no network, no Supabase, no home_shell import
// (it pulls in web-only libraries and cannot load on the Dart VM).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/wa_ops_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

// ── fixtures ─────────────────────────────────────────────────────────────────

/// A hand-managed route (auto_manage false) so the controls render without
/// having to tap Override first.
Map<String, dynamic> _route({
  required bool bypass,
  String windowLabel = 'Sends any time — transactional',
  int dedupeMinutes = 45,
  bool autoManage = false,
}) =>
    {
      'event_key': 'order_placed',
      'label': 'Order placed',
      'description': 'Sent to the customer the moment an order is accepted.',
      'template_name': 'order_placed_v2',
      'language': 'en',
      'enabled': true,
      'status_label': 'On',
      'status_tone': 'good',
      'window_label': windowLabel,
      'variable_map': {'1': 'order_no'},
      'sent_30d': 412,
      'languages_live': ['en'],
      'updated_label': '05 Aug, 11:20 AM',
      'auto_manage': autoManage,
      'auto_template_name': 'order_placed_v2',
      'pipeline_note': 'Live and sending.',
      'meta_status': 'APPROVED',
      'stage': 'live',
      'stage_label': 'Live',
      'stage_tone': 'good',
      // The two fields the backend added for this change.
      'bypass_send_window': bypass,
      'dedupe_minutes': dedupeMinutes,
    };

Map<String, dynamic> _routesPayload(Map<String, dynamic> row) => {
      'rows': [row],
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

Map<String, dynamic> _wabaPayload() => {
      'waba_name': 'mediBO',
      'review_status': 'APPROVED',
      'templates_label': '105 of 250 templates used',
      'templates_used': 105,
      'templates_limit': 250,
      'templates_pct': 42,
      'templates_tone': 'good',
      'tier_label': 'Messaging tier: TIER_10K',
      'quality_label': 'Number quality: GREEN',
      'quality_tone': 'good',
      'checked_label': 'Checked 05 Aug, 09:00 AM',
      'error': null,
      'note': 'Meta caps a WhatsApp Business Account at 250 templates.',
    };

Map<String, dynamic> _ledgerPayload() => {
      'window_days': 30,
      'cap_days': 3,
      'contacts': 0,
      'summary': 'No contacts messaged in the last 30 days',
      'rows': <Map<String, dynamic>>[],
    };

/// Pumps the screen with every RPC stubbed, and returns the list that each
/// wa_event_route_save call's params are appended to.
Future<List<Map<String, dynamic>>> _pumpOps(
  WidgetTester tester, {
  required Map<String, dynamic> row,
}) async {
  // Widget tests default to an 800 px-tall viewport and this screen is much
  // taller. Without this the controls render off-screen and a tap silently
  // misses — the finder still resolves, so the test passes while asserting
  // nothing. See [[widget-test-viewport-800]].
  tester.view.physicalSize = const Size(500, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final saves = <Map<String, dynamic>>[];

  await tester.pumpWidget(MaterialApp(
    home: WaOpsScreen(
      refreshDelay: Duration.zero,
      routesRpc: () async => _routesPayload(row),
      routeSaveRpc: (params) async {
        saves.add(params);
        return {'ok': true, 'event_key': params['p_event_key']};
      },
      wabaStatusRpc: () async => _wabaPayload(),
      wabaRefreshRpc: () async => {'ok': true, 'queued': true},
      ledgerRpc: (days, phone) async => _ledgerPayload(),
    ),
  ));
  await tester.pumpAndSettle();
  return saves;
}

Switch _bypassSwitch(WidgetTester tester) =>
    tester.widget<Switch>(find.byKey(const Key('wa_ops_bypass_switch')));

void main() {
  // The #639 seam: RenderLog's 800 ms debounce is a real Timer that would
  // outlive the test and try to reach Supabase from a VM test.
  setUpAll(() => RenderLog.flushEnabled = false);

  group('send-window switch initial state', () {
    testWidgets('bypass_send_window true renders the switch ON',
        (tester) async {
      await _pumpOps(tester, row: _route(bypass: true));

      expect(_bypassSwitch(tester).value, isTrue);
    });

    testWidgets('bypass_send_window false renders the switch OFF',
        (tester) async {
      await _pumpOps(tester, row: _route(bypass: false));

      expect(_bypassSwitch(tester).value, isFalse);
    });

    testWidgets('the value is read from the boolean, NOT from window_label',
        (tester) async {
      // Deliberately contradictory: the sentence says "any time", the boolean
      // says the route is held to the window. The boolean wins. This is the
      // regression guard — sentence-parsing would flip this to ON.
      await _pumpOps(tester,
          row: _route(
              bypass: false, windowLabel: 'Sends any time — transactional'));

      expect(_bypassSwitch(tester).value, isFalse);
      expect(find.text('Sends any time — transactional'), findsOneWidget);
    });

    testWidgets('no indeterminate state survives anywhere', (tester) async {
      for (final b in [true, false]) {
        await _pumpOps(tester, row: _route(bypass: b));

        // Switch.value is non-nullable, so simply resolving it proves there is
        // no unknown state. The tristate Checkbox is gone outright.
        expect(_bypassSwitch(tester).value, isA<bool>());
        expect(find.byKey(const Key('wa_ops_bypass_checkbox')), findsNothing);
        expect(find.byType(Checkbox), findsNothing);
      }
    });

    testWidgets('window_label still renders verbatim beneath the switch',
        (tester) async {
      await _pumpOps(tester,
          row: _route(
              bypass: false,
              windowLabel: 'Held to the 9am-8pm window — marketing'));

      expect(find.text('Held to the 9am-8pm window — marketing'),
          findsOneWidget);
    });

    testWidgets('dedupe_minutes renders as a read-only line', (tester) async {
      await _pumpOps(tester, row: _route(bypass: true, dedupeMinutes: 45));

      expect(find.byKey(const Key('wa_ops_dedupe_minutes')), findsOneWidget);
      expect(find.textContaining('45'), findsWidgets);
    });
  });

  group('send-window switch saving', () {
    testWidgets('toggling sends p_bypass_window with the new value',
        (tester) async {
      final saves = await _pumpOps(tester, row: _route(bypass: false));

      final sw = find.byKey(const Key('wa_ops_bypass_switch'));
      // Scroll it into view first: an un-scrolled tap lands nowhere and the
      // test would pass having asserted nothing.
      await tester.ensureVisible(sw);
      await tester.pumpAndSettle();
      await tester.tap(sw);
      await tester.pumpAndSettle();

      expect(saves, hasLength(1));
      expect(saves.single['p_event_key'], 'order_placed');
      expect(saves.single['p_bypass_window'], isTrue);
    });

    testWidgets('toggling the other way sends false', (tester) async {
      final saves = await _pumpOps(tester, row: _route(bypass: true));

      final sw = find.byKey(const Key('wa_ops_bypass_switch'));
      await tester.ensureVisible(sw);
      await tester.pumpAndSettle();
      await tester.tap(sw);
      await tester.pumpAndSettle();

      expect(saves, hasLength(1));
      expect(saves.single['p_bypass_window'], isFalse);
    });

    testWidgets('an untouched switch never sends p_bypass_window',
        (tester) async {
      final saves = await _pumpOps(tester, row: _route(bypass: true));

      // Touch a DIFFERENT control. The send-window switch was never moved, so
      // its key must be absent — wa_event_route_save coalesces, and sending it
      // unasked would overwrite a concurrent change made elsewhere.
      final enabled = find.byKey(const Key('wa_ops_enabled_switch'));
      await tester.ensureVisible(enabled);
      await tester.pumpAndSettle();
      await tester.tap(enabled);
      await tester.pumpAndSettle();

      expect(saves, hasLength(1));
      expect(saves.single.containsKey('p_bypass_window'), isFalse);
      expect(saves.single.containsKey('p_variable_map'), isFalse);
    });
  });
}
