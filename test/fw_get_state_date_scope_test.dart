// Regression test for CHANGE #545 (superseding #471) — fw_get_state date
// scoping + rendering backend-owned display strings instead of client-side math.
//
// Proves:
//   1. The RPC params map OMITS p_date entirely — the date now lives
//      server-side in admin_date_scope (set by the one Dashboard picker) and
//      fw_get_state defaults p_date to admin_active_date(). The key must be
//      ABSENT, not present-with-null: an explicit null reads as "all dates".
//      p_include_older is likewise never sent — every Fulfill RPC ignores it
//      server-side, so sending it is misleading.
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
import 'package:pharma_b2b/widgets/box_date_row.dart';

void main() {
  group('fwGetStateParams (CHANGE #545)', () {
    test('OMITS p_date — the server default (admin_active_date) owns the date', () {
      final params = fwGetStateParams(
        supplierName: 'Acme Pharma',
        stage: 'arrivals',
      );
      expect(params['p_supplier_name'], 'Acme Pharma');
      expect(params['p_stage'], 'arrivals');
      // Absent, NOT present-with-null — an explicit null means "all dates".
      expect(params.containsKey('p_date'), false);
      expect(params.keys.toSet(), {'p_supplier_name', 'p_stage'});
    });

    test('never sends p_include_older — fw_get_state is strict single-date', () {
      final params = fwGetStateParams(
        supplierName: 'Acme Pharma',
        stage: 'collect',
      );
      expect(params.containsKey('p_date'), false);
      expect(params.containsKey('p_include_older'), false);
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

    // CHANGE #531 deleted the "+N from earlier dates" pill outright (project
    // rule: no include-older chrome anywhere — the date picker is the only way
    // to change the date). The row now IGNORES `older` in both states; these two
    // cases pin that, replacing the pre-#531 expectations that it rendered.
    testWidgets('older.show=true → still nothing (pill deleted in #531)',
        (tester) async {
      await pump(tester,
          dateLabel: 'Today · 22/07/2026',
          older: const BoxOlder(show: true, label: '+4 from earlier dates'));
      expect(find.text('+4 from earlier dates'), findsNothing);
      // The backend date label is unaffected.
      expect(find.text('Today · 22/07/2026'), findsOneWidget);
    });

    testWidgets('there is nothing tappable to toggle include-older',
        (tester) async {
      var toggled = false;
      await pump(tester,
          dateLabel: 'Today · 22/07/2026',
          older: const BoxOlder(show: true, label: '+4 from earlier dates'),
          onToggle: () => toggled = true);
      expect(find.byType(InkWell), findsNothing);
      expect(toggled, false);
    });

    testWidgets('null date_label → renders nothing', (tester) async {
      await pump(tester, dateLabel: null, older: const BoxOlder(show: false, label: ''));
      expect(find.byType(BoxDateOlderRow), findsOneWidget);
      expect(find.byType(Row), findsNothing);
    });
  });
}
