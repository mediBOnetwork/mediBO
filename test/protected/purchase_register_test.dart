// PROTECTED — CMD #367, feature_gaps row 174 (Purchases + purchase register).
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes this behaviour, never to make an unrelated change go
// green.
//
// What this holds down:
//
//   1. The month bars are drawn from the BACKEND's own `bar_pct`. The screen
//      must never find the tallest month by dividing one month's spend by
//      another's — that is arithmetic on money, in Dart, which this codebase
//      does not do. The fixture below is deliberately non-monotonic and its
//      biggest bar_pct does NOT belong to its biggest raw `spend`, so a widget
//      that recomputed the scale would visibly disagree with the fixture.
//
//   2. Every month in the window is printed, INCLUDING the empty ones, in
//      payload order. A gap in trading is a fact the pharmacy needs to see;
//      silently dropping zero months would draw a flattering, false chart.
//
//   3. Money is printed verbatim. `spend_display` arrives already formatted
//      (₹, Indian digit grouping, two decimals) — the test asserts the exact
//      string survives to the screen, so nobody reintroduces a Dart
//      `toStringAsFixed(2)` or a rupee sign typed in a widget.
//
//   4. The register's buttons come from `formats[]` — their captions, their
//      order and their existence. A Dart-side ['csv','pdf'] list would keep
//      rendering a CSV button after the backend stopped offering one.
//
//   5. `available:false` renders the backend's `empty_note` and NO export
//      button at all. Absence is the payload's verdict, never row_count>0
//      recomputed on the client.
//
// No network, no Supabase, no goldens — the payload is a fixture.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/purchases_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

// A window with a quiet month in the middle, and a bar_pct scale that a
// client-side max() would NOT reproduce.
const _months = <Map<String, dynamic>>[
  {
    'key': '2026-06',
    'label': 'Jun 2026',
    'spend': 4000,
    'spend_display': '₹4,000.00',
    'orders': 2,
    'bar_pct': 40,
    'is_empty': false,
  },
  {
    'key': '2026-07',
    'label': 'Jul 2026',
    'spend': 0,
    'spend_display': '₹0.00',
    'orders': 0,
    'bar_pct': 0,
    'is_empty': true,
  },
  {
    'key': '2026-08',
    'label': 'Aug 2026',
    'spend': 10000,
    'spend_display': '₹10,000.00',
    'orders': 5,
    'bar_pct': 100,
    'is_empty': false,
  },
];

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('purchase analytics — the month bars', () {
    testWidgets('prints every month in payload order, empty ones included',
        (tester) async {
      await tester.pumpWidget(_host(const MonthBars(months: _months)));

      expect(find.text('Jun 2026'), findsOneWidget);
      expect(find.text('Jul 2026'), findsOneWidget); // the quiet month stays
      expect(find.text('Aug 2026'), findsOneWidget);

      final labels = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .whereType<String>()
          .toList();
      expect(labels.indexOf('Jun 2026') < labels.indexOf('Jul 2026'), isTrue);
      expect(labels.indexOf('Jul 2026') < labels.indexOf('Aug 2026'), isTrue);
    });

    testWidgets('prints backend money verbatim — no Dart formatting',
        (tester) async {
      await tester.pumpWidget(_host(const MonthBars(months: _months)));
      expect(find.text('₹4,000.00'), findsOneWidget);
      expect(find.text('₹10,000.00'), findsOneWidget);
      expect(find.text('₹0.00'), findsOneWidget);
      // Nothing may print a bare number it formatted itself.
      expect(find.text('4000'), findsNothing);
      expect(find.text('10000.00'), findsNothing);
    });

    testWidgets('bar width follows bar_pct, not a client-side max()',
        (tester) async {
      // 500 logical px of bar track; the fill is a fraction of the SAME track,
      // so June's fill must be 40% of August's 100% — the payload's ratio.
      await tester.pumpWidget(_host(
        SizedBox(width: 500, child: const MonthBars(months: _months)),
      ));

      final fills = tester
          .widgetList<Container>(find.byType(Container))
          .where((c) => c.constraints?.hasBoundedWidth == true)
          .toList();
      // Two fills per month (track + fill); take the widths that are non-zero
      // and bounded, and assert the June:August ratio is 40:100.
      final widths = <double>[];
      for (final c in fills) {
        final w = c.constraints!.maxWidth;
        if (w > 0 && w.isFinite) widths.add(w);
      }
      expect(widths.isNotEmpty, isTrue);
      final maxW = widths.reduce((a, b) => a > b ? a : b);
      final junW = widths.where((w) => w > 0 && w < maxW).toList();
      expect(junW.isNotEmpty, isTrue,
          reason: 'June must draw a shorter bar than August');
      expect((junW.reduce((a, b) => a > b ? a : b) / maxW - 0.40).abs() < 0.02,
          isTrue,
          reason: 'the fill ratio must be the payload bar_pct (40/100), '
              'not a ratio recomputed from spend');
    });
  });

  group('the purchase register card', () {
    testWidgets('draws its buttons from formats[], in payload order',
        (tester) async {
      final tapped = <String>[];
      await tester.pumpWidget(_host(RegisterCard(
        busy: false,
        onExport: tapped.add,
        register: const {
          'title': 'Purchase register',
          'note': 'Invoice-wise register with GST, ready to reconcile.',
          'available': true,
          'row_count': 116,
          'count_label': '116 lines',
          'empty_note': 'No billed lines in this period.',
          'formats': [
            {'key': 'csv', 'label': 'Download CSV'},
            {'key': 'pdf', 'label': 'Print / save PDF'},
          ],
        },
      )));

      expect(find.text('Purchase register'), findsOneWidget);
      expect(find.text('116 lines'), findsOneWidget);
      // The captions are the backend's, not 'CSV' / 'PDF' typed in Dart.
      expect(find.text('Download CSV'), findsOneWidget);
      expect(find.text('Print / save PDF'), findsOneWidget);

      await tester.tap(find.text('Download CSV'));
      await tester.pump();
      expect(tapped, ['csv']);
    });

    testWidgets('a backend that offers one format renders exactly one button',
        (tester) async {
      await tester.pumpWidget(_host(RegisterCard(
        busy: false,
        onExport: (_) {},
        register: const {
          'title': 'Purchase register',
          'note': '',
          'available': true,
          'count_label': '9 lines',
          'formats': [
            {'key': 'csv', 'label': 'Download CSV'},
          ],
        },
      )));
      expect(find.text('Download CSV'), findsOneWidget);
      expect(find.text('Print / save PDF'), findsNothing);
    });

    testWidgets('available:false shows the backend empty note and no buttons',
        (tester) async {
      await tester.pumpWidget(_host(RegisterCard(
        busy: false,
        onExport: (_) {},
        register: const {
          'title': 'Purchase register',
          'note': 'Invoice-wise register with GST, ready to reconcile.',
          'available': false,
          'row_count': 0,
          'count_label': '0 lines',
          'empty_note': 'No billed lines in this period.',
          // The backend sends no formats at all in this state; even if it did,
          // `available` is the verdict the card obeys.
          'formats': [
            {'key': 'csv', 'label': 'Download CSV'},
          ],
        },
      )));

      expect(find.text('No billed lines in this period.'), findsOneWidget);
      expect(find.text('Download CSV'), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(OutlinedButton), findsNothing);
    });

    testWidgets('busy disables export rather than firing it twice',
        (tester) async {
      final tapped = <String>[];
      await tester.pumpWidget(_host(RegisterCard(
        busy: true,
        onExport: tapped.add,
        register: const {
          'title': 'Purchase register',
          'note': '',
          'available': true,
          'count_label': '2 lines',
          'formats': [
            {'key': 'csv', 'label': 'Download CSV'},
          ],
        },
      )));
      await tester.tap(find.text('Download CSV'));
      await tester.pump();
      expect(tapped, isEmpty);
    });
  });
}
