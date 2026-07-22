// Regression test for CHANGE #471 — fw_get_state date scoping + rendering
// backend-owned display strings instead of client-side math.
//
// Proves:
//   1. The RPC params map always carries p_date (= the selected date's
//      'yyyy-MM-dd' string) and p_include_older — the #471 bug was the
//      client silently relying on the server default for both.
//   2. The header progress reads progress.counted/total/label verbatim
//      from a stubbed fw_get_state response (no client-side counting).
//   3. The include-older control is absent when older.show is false and
//      renders older.label verbatim when older.show is true.
//   4. A per-item date chip renders only when show_date_chip is true, with
//      the exact backend date_chip text.
//
// No browser, no golden, no headless — pure Dart + a couple of tiny widget
// pumps of the extracted, stand-alone widgets (no Supabase/voice mocking
// needed since the RPC-shape decisions were pulled into pure functions).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/fulfill/fulfill_view_logic.dart';
import 'package:pharma_b2b/widgets/date_scope_chip.dart';

void main() {
  group('fwGetStateParams (CHANGE #471)', () {
    test('always sends p_date and p_include_older — never relies on server default', () {
      final params = fwGetStateParams(
        supplierName: 'Acme Pharma',
        stage: 'arrivals',
        date: DateTime(2026, 7, 22),
        includeOlder: false,
      );
      expect(params['p_supplier_name'], 'Acme Pharma');
      expect(params['p_stage'], 'arrivals');
      expect(params['p_date'], '2026-07-22');
      expect(params['p_include_older'], false);
    });

    test('p_include_older reflects the toggle', () {
      final params = fwGetStateParams(
        supplierName: 'Acme Pharma',
        stage: 'collect',
        date: DateTime(2026, 7, 20),
        includeOlder: true,
      );
      expect(params['p_date'], '2026-07-20');
      expect(params['p_include_older'], true);
    });
  });

  group('boxProgressFrom (CHANGE #471)', () {
    test('reads counted/total/label verbatim from a stubbed fw_get_state response', () {
      final response = {'counted': 3, 'total': 15, 'label': '3/15'};
      final progress = boxProgressFrom(response, fallbackTotal: 999);
      expect(progress.counted, 3);
      expect(progress.total, 15);
      expect(progress.label, '3/15');
      // Not '0/15' — proves the header no longer recomputes this client-side.
      expect(progress.label, isNot('0/15'));
    });

    test('falls back to raw item count only when no response has landed yet', () {
      final progress = boxProgressFrom(null, fallbackTotal: 7);
      expect(progress.counted, 0);
      expect(progress.total, 7);
      expect(progress.label, '0/7');
    });
  });

  group('boxOlderFrom (CHANGE #471)', () {
    test('show=false → not shown', () {
      final older = boxOlderFrom({'count': 0, 'show': false, 'label': null});
      expect(older.show, false);
    });

    test('show=true → label carried verbatim, never reconstructed', () {
      final older = boxOlderFrom({'count': 4, 'show': true, 'label': '+4 from earlier dates'});
      expect(older.show, true);
      expect(older.label, '+4 from earlier dates');
    });
  });

  group('itemDateChip (CHANGE #471)', () {
    test('show_date_chip=false → no chip', () {
      expect(itemDateChip({'show_date_chip': false, 'date_chip': null}), isNull);
    });

    test('show_date_chip=true → exact backend date_chip text', () {
      expect(itemDateChip({'show_date_chip': true, 'date_chip': '20/07'}), '20/07');
    });
  });

  group('BoxDateOlderRow widget (CHANGE #471)', () {
    Future<void> pump(WidgetTester tester, {
      required String? dateLabel,
      required BoxOlder older,
      bool includeOlder = false,
      VoidCallback? onToggle,
    }) =>
        tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: BoxDateOlderRow(
              dateLabel: dateLabel,
              older: older,
              includeOlder: includeOlder,
              onToggleOlder: onToggle ?? () {},
            ),
          ),
        ));

    testWidgets('header renders date_label verbatim', (tester) async {
      await pump(tester,
          dateLabel: 'Today · 22/07/2026', older: const BoxOlder(show: false, label: ''));
      expect(find.text('Today · 22/07/2026'), findsOneWidget);
    });

    testWidgets('older.show=false → control absent', (tester) async {
      await pump(tester,
          dateLabel: 'Today · 22/07/2026',
          older: const BoxOlder(show: false, label: '+4 from earlier dates'));
      expect(find.text('+4 from earlier dates'), findsNothing);
    });

    testWidgets('older.show=true → label rendered verbatim', (tester) async {
      await pump(tester,
          dateLabel: 'Today · 22/07/2026',
          older: const BoxOlder(show: true, label: '+4 from earlier dates'));
      expect(find.text('+4 from earlier dates'), findsOneWidget);
    });

    testWidgets('tapping the older pill invokes the toggle callback', (tester) async {
      var toggled = false;
      await pump(tester,
          dateLabel: 'Today · 22/07/2026',
          older: const BoxOlder(show: true, label: '+4 from earlier dates'),
          onToggle: () => toggled = true);
      await tester.tap(find.text('+4 from earlier dates'));
      expect(toggled, true);
    });

    testWidgets('null date_label → renders nothing', (tester) async {
      await pump(tester, dateLabel: null, older: const BoxOlder(show: false, label: ''));
      expect(find.byType(BoxDateOlderRow), findsOneWidget);
      expect(find.byType(Row), findsNothing);
    });
  });
}
