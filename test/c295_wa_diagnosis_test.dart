// CHANGE #295 — the WhatsApp delivery diagnosis renders the backend's verdict,
// it never computes one.
//
// The fixture is a hand-written wa_event_diagnosis() payload. Every assertion
// here is about VERBATIM rendering and about the app refusing to invent:
//   • the verdict word, the template status, the "N sent · N delivered · N
//     failed" sentence and the note are printed exactly as sent;
//   • a tone the app has never seen still renders its label (grey), because a
//     backend that adds a sixth tone must not blank an admin's screen;
//   • the filter matches the backend's own `verdict` string — there is no
//     client-side re-classification, and 'all' preserves payload order.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/wa_diagnosis_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _row({
  required String key,
  required String verdict,
  String verdictTone = 'danger',
  String template = 'order_placed',
  String templateStatus = 'Approved',
  String emitting = 'No — free-form bypass',
  String window = '29 sent · 12 delivered · 17 failed',
  String note = '—',
  String fail = 'Re-engagement message',
}) =>
    {
      'event_key': key,
      'label': key,
      'audience': 'customer',
      'enabled': true,
      'enabled_label': 'On',
      'template': template,
      'template_status': templateStatus,
      'template_tone': 'success',
      'variables_label': 'Matches template',
      'variables_tone': 'neutral',
      'emitting': false,
      'emitting_label': emitting,
      'emitting_tone': 'danger',
      'emitters': 'wa_notify_order_placed',
      'window_label': window,
      'fail_reason': fail,
      'ever_fired': true,
      'last_fired': '23 Aug 2026, 02:50 PM',
      'verdict': verdict,
      'verdict_tone': verdictTone,
      'note': note,
    };

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('waDiagFilter', () {
    final rows = [
      _row(key: 'order_placed', verdict: 'BROKEN'),
      _row(key: 'delivery_out', verdict: 'NEVER FIRED'),
      _row(key: 'login_alert', verdict: 'WORKING'),
      _row(key: 'payment_qr', verdict: 'BROKEN'),
    ];

    test('"all" keeps every row in the backend order', () {
      final out = waDiagFilter(rows, 'all');
      expect(out.map((r) => r['event_key']).toList(),
          ['order_placed', 'delivery_out', 'login_alert', 'payment_qr']);
    });

    test('a verdict key keeps only that verdict, still in payload order', () {
      expect(waDiagFilter(rows, 'BROKEN').map((r) => r['event_key']).toList(),
          ['order_placed', 'payment_qr']);
      expect(waDiagFilter(rows, 'NEVER FIRED').map((r) => r['event_key']).toList(),
          ['delivery_out']);
    });

    test('an unknown key hides everything rather than guessing', () {
      expect(waDiagFilter(rows, 'MOSTLY_FINE'), isEmpty);
    });

    test('the filter never re-classifies: a row with no verdict is not BROKEN',
        () {
      final noVerdict = [
        {'event_key': 'mystery'}
      ];
      expect(waDiagFilter(noVerdict, 'BROKEN'), isEmpty);
      expect(waDiagFilter(noVerdict, 'all'), hasLength(1));
    });
  });

  group('WaDiagEventCard', () {
    testWidgets('prints the backend verdict, counts and template status verbatim',
        (tester) async {
      await tester.pumpWidget(_host(WaDiagEventCard(
          row: _row(key: 'order_placed', verdict: 'BROKEN'))));

      expect(find.text('BROKEN'), findsOneWidget);
      expect(find.text('29 sent · 12 delivered · 17 failed'), findsOneWidget);
      expect(find.text('Approved'), findsOneWidget);
      expect(find.text('No — free-form bypass'), findsOneWidget);
      expect(find.text('Re-engagement message'), findsOneWidget);
      expect(find.text('23 Aug 2026, 02:50 PM'), findsOneWidget);
      // The count sentence is never rebuilt from the numbers in Dart.
      expect(find.textContaining('29/'), findsNothing);
    });

    testWidgets('a "—" note and a "—" failure reason are an absence, not a word',
        (tester) async {
      await tester.pumpWidget(_host(WaDiagEventCard(
          row: _row(
              key: 'delivery_out',
              verdict: 'NEVER FIRED',
              verdictTone: 'warning',
              fail: '—',
              note: '—'))));

      expect(find.text('NEVER FIRED'), findsOneWidget);
      expect(find.text('—'), findsNothing);
    });

    testWidgets('a note the backend sent IS shown', (tester) async {
      await tester.pumpWidget(_host(WaDiagEventCard(
          row: _row(
              key: 'order_dispatched',
              verdict: 'NEVER FIRED',
              verdictTone: 'warning',
              note: 'Delivery lifecycle owns this message.'))));

      expect(find.text('Delivery lifecycle owns this message.'), findsOneWidget);
    });

    testWidgets('an unrecognised tone still renders its label', (tester) async {
      await tester.pumpWidget(_host(WaDiagEventCard(
          row: _row(
              key: 'future_event',
              verdict: 'PARTIAL',
              verdictTone: 'chartreuse'))));

      expect(find.text('PARTIAL'), findsOneWidget);
    });
  });

  group('WaDiagSummaryChips', () {
    final items = [
      {'key': 'all', 'label': 'All routes', 'value': '47', 'tone': 'neutral'},
      {'key': 'BROKEN', 'label': 'Broken', 'value': '4', 'tone': 'danger'},
      {'key': 'WORKING', 'label': 'Working', 'value': '9', 'tone': 'success'},
    ];

    testWidgets('renders the backend label and count for every chip',
        (tester) async {
      await tester.pumpWidget(_host(WaDiagSummaryChips(
          items: items, selected: 'all', onPick: (_) {})));

      expect(find.text('All routes'), findsOneWidget);
      expect(find.text('47'), findsOneWidget);
      expect(find.text('Broken'), findsOneWidget);
      expect(find.text('4'), findsOneWidget);
    });

    testWidgets('a tap reports the backend key, not the label', (tester) async {
      String? picked;
      await tester.pumpWidget(_host(WaDiagSummaryChips(
          items: items, selected: 'all', onPick: (k) => picked = k)));

      await tester.tap(find.text('Broken'));
      await tester.pump();
      expect(picked, 'BROKEN');
    });
  });
}
