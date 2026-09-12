// PROTECTED — CMD #454 (feature_gaps #101).
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes how a partial delivery reports what came back.
//
// The defect this pins shut: delivery_partial recorded a partial handover as
// TWO SCALARS on the parcel — delivered_qty / returned_qty — so a 12-line order
// returning 3 strips was stored as "9/3" with a free-text note, and nothing
// could route those goods back to stock or to the bill. The fix is per-line,
// and these are the client-side halves of that contract:
//
//   1. AN UNTOUCHED LINE IS OMITTED, never sent as qty 0. Zero would read as a
//      positive statement ("the customer kept all of it") that the rider never
//      made — the same rule the stock-update form already lives by.
//   2. The quantity is CLAMPED to what is on the line, and stepping back down
//      to zero un-answers it rather than pinning a 0.
//   3. LINES RENDER IN PAYLOAD ORDER. The fixture is deliberately not
//      alphabetical, so any client-side sort fails here.
//   4. Every label is the BACKEND's — the title, the hint and the submit
//      caption come from ui_copy, never from a Dart literal.
//   5. Submit is unavailable until at least one line has been answered.
//
// No network, no Supabase, no goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ui_copy_fixture.dart';

import 'package:pharma_b2b/screens/delivery/delivery_partial_sheet.dart';
import 'package:pharma_b2b/services/ui_copy.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _line(String id, String name, int qty, {String? qtyLabel}) => {
      'order_item_id': id,
      'product_name': name,
      'quantity': qty,
      if (qtyLabel != null) 'qty_label': qtyLabel,
    };

// Deliberately NOT alphabetical: Z before A before M.
final _lines = <Map<String, dynamic>>[
  _line('oi-z', 'Zincovit Tablet', 10, qtyLabel: '10 strips billed'),
  _line('oi-a', 'Azithral 500', 4, qtyLabel: '4 strips billed'),
  _line('oi-m', 'Montek LC', 2, qtyLabel: '2 strips billed'),
];

Future<void> _pump(WidgetTester tester) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: DeliveryPartialSheet(
        deliveryId: 'del-1',
        lines: _lines,
        photoPath: 'delivery-proofs/x.jpg',
      ),
    ),
  ));
  await tester.pump();
}

void main() {
  setUpAll(() {
    RenderLog.flushEnabled = false;
    seedUiCopy();
  });

  group('the partial-return selection', () {
    test('an untouched line is OMITTED from the payload, never sent as 0', () {
      final sel = DeliveryPartialSelection();
      sel.bump('oi-z', 10, 3);

      expect(sel.payload(), [
        {'order_item_id': 'oi-z', 'qty': 3},
      ]);
      // oi-a and oi-m were never touched, so they are absent — not qty 0.
      expect(sel.payload().map((e) => e['order_item_id']), isNot(contains('oi-a')));
      expect(sel.payload().map((e) => e['order_item_id']), isNot(contains('oi-m')));
    });

    test('the quantity is clamped to the line, in both directions', () {
      final sel = DeliveryPartialSelection();
      sel.bump('oi-a', 4, 9); // asking for more than was billed
      expect(sel.qtyFor('oi-a'), 4);

      sel.bump('oi-a', 4, -99); // and below zero
      expect(sel.qtyFor('oi-a'), 0);
    });

    test('stepping back to zero un-answers the line rather than pinning a 0', () {
      final sel = DeliveryPartialSelection();
      sel.bump('oi-m', 2, 1);
      expect(sel.payload(), hasLength(1));

      sel.bump('oi-m', 2, -1);
      expect(sel.isEmpty, isTrue);
      expect(sel.payload(), isEmpty);
    });

    test('several answered lines all ride along', () {
      final sel = DeliveryPartialSelection();
      sel.bump('oi-z', 10, 3);
      sel.bump('oi-m', 2, 2);

      expect(sel.payload(), hasLength(2));
      expect(sel.qtyFor('oi-z'), 3);
      expect(sel.qtyFor('oi-m'), 2);
    });
  });

  group('the partial-return sheet', () {
    testWidgets('renders the lines in PAYLOAD order, not sorted', (tester) async {
      await _pump(tester);

      final names = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .where((s) => s.contains('Zincovit') || s.contains('Azithral') || s.contains('Montek'))
          .toList();

      expect(names, ['Zincovit Tablet', 'Azithral 500', 'Montek LC']);
    });

    testWidgets('prints the backend copy, not Dart literals', (tester) async {
      await _pump(tester);

      expect(find.text(UiCopy.t('delivery.partial_title')), findsOneWidget);
      expect(find.text(UiCopy.t('delivery.partial_hint')), findsOneWidget);
      expect(find.text(UiCopy.t('delivery.partial_submit')), findsOneWidget);
      // and the per-line quantity sentence is the payload's own string
      expect(find.text('10 strips billed'), findsOneWidget);
    });

    testWidgets('submit is dead until a line has been answered', (tester) async {
      await _pump(tester);

      FilledButton button() => tester.widget<FilledButton>(find.byType(FilledButton));
      expect(button().onPressed, isNull);

      await tester.tap(find.byIcon(Icons.add).first);
      await tester.pump();
      expect(button().onPressed, isNotNull);
    });

    testWidgets('a line with no qty_label renders no caption of its own',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: DeliveryPartialSheet(
            deliveryId: 'del-1',
            lines: [_line('oi-x', 'Unlabelled Item', 5)],
            photoPath: 'delivery-proofs/x.jpg',
          ),
        ),
      ));
      await tester.pump();

      expect(find.text('Unlabelled Item'), findsOneWidget);
      expect(find.textContaining('billed'), findsNothing);
    });
  });
}
