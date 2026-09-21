// PROTECTED — CMD #2120.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes the shape of a cart row on a phone.
//
// The phone cart row is the Bulk Upload review row (#2115 / CHANGE #1454,
// #2119): a photo and FOUR lines. What this holds down is that all four of
// them are the payload's, and that the control on line 4 is a chip, not a
// stepper:
//
//   1. Line 2 is `row.composition` — MEDICINE.salt_composition verbatim.
//      Absence is absence: no composition on the payload draws no line, and
//      the row never falls back to the pack caption or the company.
//
//   2. Line 3 is `row.sale_badge`: the label, the value and the TWO COLOURS
//      are the backend's. The value is card_price's `price_display`, which is
//      already the right answer for this viewer — so an unapproved viewer
//      gets the locked WORD and no number anywhere on the row, and the badge
//      never re-derives, strikes or discounts anything.
//
//   3. Line 4 is `row.qty_chip.label` — bulk_qty_line()'s sentence ("5
//      strip"), printed verbatim. The unit word in particular is NOT derived
//      from the pack string in Dart; a payload that says "5 box" renders "5
//      box" beside a pack that says strips.
//
//   4. The chip is a CONTROL: it carries the backend's hint, it is at least
//      44px tall, and it opens the quantity picker with the row's own
//      `pack_type` and `qty`. `has:false` draws nothing.
//
//   5. `qty_locked` kills the chip. That is cart_render()'s flag carried
//      through — never a local stock check.
//
//   6. Between the pick and the server's reply the chip prints the label the
//      PICKER handed back, and it drops that label the moment the payload's
//      own label changes — whatever the server answered, including a clamp.
//      No sentence is ever composed in Dart.
//
// No network, no Supabase, no goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/models/cart_model.dart';
import 'package:pharma_b2b/screens/cart_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

// ── fixtures ─────────────────────────────────────────────────────────────────

Map<String, dynamic> _row({
  String composition = 'Dapagliflozin 10mg + Metformin 1000mg',
  bool badge = true,
  String value = 'PTR',
  bool locked = true,
  String saleLabel = 'Sale price:',
  bool chip = true,
  String chipLabel = '5 strip',
  String packType = 'Strip',
  int qty = 5,
}) =>
    {
      'name': 'Dapa-Met 10/1000',
      'pack_label': '1 Strip of 10 Tablets',
      'has_pack': true,
      if (composition.isNotEmpty) 'composition': composition,
      'has_composition': composition.isNotEmpty,
      if (badge)
        'sale_badge': {
          'has': true,
          'label': saleLabel,
          'value': value,
          'locked': locked,
          'bg': '#1B7A43',
          'fg': '#FFFFFF',
        },
      if (chip)
        'qty_chip': {
          'has': true,
          'label': chipLabel,
          'qty': qty,
          'pack_type': packType,
          'hint': 'Change quantity',
        },
      'rx_chip': {
        'has': true,
        'label': 'Rx',
        'tone': {'bg': '#1E40AF', 'fg': '#FFFFFF'},
      },
    };

/// One cart line, adopted the way the app adopts one: through the payload.
Future<CartLine> _line(Map<String, dynamic>? row, {bool qtyLocked = false}) async {
  CartModel.rpcTransport = (fn, params) async => {
        'items': [
          {
            'id': 1,
            'product_id': '101',
            'product_name': 'Dapa-Met 10/1000',
            'quantity': 5,
            'mrp': 231.80,
            'image_url': '',
            'manufacturer': 'USV Ltd',
            'pack_size': '1 Strip of 10 Tablets',
            'category': 'ANTIDIABETIC',
            if (qtyLocked) 'qty_locked': true,
            if (row != null) 'row': row,
          }
        ],
        'item_count': 1,
        'render': const {},
      };
  final cart = CartModel.forTest();
  await cart.refresh();
  return cart.lines.single;
}

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
      MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child))),
    );

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);
  tearDown(() => CartModel.rpcTransport = null);

  group('CMD #2120 — line 2 is the composition, verbatim', () {
    test('the salts arrive exactly as the payload printed them', () async {
      final line = await _line(_row());
      expect(line.rows('composition'), 'Dapagliflozin 10mg + Metformin 1000mg');
      expect(line.row['has_composition'], isTrue);
    });

    test('no composition is no line — never the pack or the company',
        () async {
      final line = await _line(_row(composition: ''));
      expect(line.rows('composition'), '');
      expect(line.row['has_composition'], isFalse);
      // Both of those are still ON the row; the screen simply does not promote
      // either of them into line 2.
      expect(line.rows('pack_label'), '1 Strip of 10 Tablets');
    });
  });

  group('CMD #2120 — line 3 is ONE badge, and it is the backend\'s', () {
    testWidgets('the label, the value and both colours are printed as sent',
        (t) async {
      final line = await _line(_row(value: '₹189.00', locked: false));
      await _pump(t, C2120SaleBadge(badge: line.rowMap('sale_badge')));
      expect(find.text('Sale price:'), findsOneWidget);
      expect(find.text('₹189.00'), findsOneWidget);

      final box = t.widget<Container>(find
          .descendant(of: find.byType(C2120SaleBadge), matching: find.byType(Container))
          .first);
      expect((box.decoration as BoxDecoration).color,
          const Color(0xFF1B7A43));
    });

    testWidgets('an unapproved viewer gets the WORD and no number anywhere',
        (t) async {
      final line = await _line(_row());
      await _pump(t, C2120SaleBadge(badge: line.rowMap('sale_badge')));
      expect(find.text('PTR'), findsOneWidget);
      expect(find.textContaining('₹'), findsNothing);
      expect(line.rowMap('sale_badge')['locked'], isTrue);
    });

    testWidgets('no badge on the payload draws no money at all', (t) async {
      final line = await _line(_row(badge: false));
      expect(line.rowMap('sale_badge'), isEmpty);
      await _pump(t, C2120SaleBadge(badge: line.rowMap('sale_badge')));
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('an empty value is absence too, not an empty green pill',
        (t) async {
      await _pump(
          t,
          const C2120SaleBadge(
              badge: {'has': true, 'label': 'Sale price:', 'value': ''}));
      expect(find.byType(Text), findsNothing);
    });
  });

  group('CMD #2120 — line 4 is a chip, and the chip is a control', () {
    testWidgets('the sentence is the payload\'s, unit word and all', (t) async {
      final line = await _line(_row(chipLabel: '5 box'));
      await _pump(
          t, C2120QtyChip(chip: line.rowMap('qty_chip'), onPicked: (_) {}));
      // The pack caption on the same row says "Strip". The chip says what the
      // BACKEND said, which is the whole point.
      expect(find.text('5 box'), findsOneWidget);
      expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);
    });

    testWidgets('it carries the backend hint and a full 44px touch height',
        (t) async {
      final line = await _line(_row());
      await _pump(
          t, C2120QtyChip(chip: line.rowMap('qty_chip'), onPicked: (_) {}));
      final sem = t.widget<Semantics>(find
          .descendant(
              of: find.byType(C2120QtyChip), matching: find.byType(Semantics))
          .first);
      expect(sem.properties.label, 'Change quantity');
      expect(sem.properties.identifier, 'cart_qty_chip');
      expect(t.getSize(find.byType(InkWell).first).height,
          greaterThanOrEqualTo(44.0));
    });

    testWidgets('the picker is opened with the ROW\'s pack type and quantity',
        (t) async {
      final chip = (await _line(_row(packType: 'Bottle', qty: 12))).rowMap('qty_chip');
      expect(chip['pack_type'], 'Bottle');
      expect(chip['qty'], 12);
    });

    testWidgets('has:false draws nothing', (t) async {
      final line = await _line(_row(chip: false));
      expect(line.rowMap('qty_chip'), isEmpty);
      await _pump(
          t, C2120QtyChip(chip: line.rowMap('qty_chip'), onPicked: (_) {}));
      expect(find.byType(InkWell), findsNothing);
    });

    testWidgets('qty_locked kills the tap — the backend\'s flag, carried',
        (t) async {
      final line = await _line(_row(), qtyLocked: true);
      expect(line.qtyLocked, isTrue);
      await _pump(
          t,
          C2120QtyChip(
              chip: line.rowMap('qty_chip'),
              locked: line.qtyLocked,
              onPicked: (_) {}));
      expect(t.widget<InkWell>(find.byType(InkWell).first).onTap, isNull);
    });
  });

  group('CMD #2120 — the pending label is the picker\'s, and it is temporary',
      () {
    test('it survives while the payload label has not moved', () {
      expect(
          c2120PendingAfterPayload(
              pending: '7 strip', oldLabel: '5 strip', newLabel: '5 strip'),
          '7 strip');
    });

    test('the server answering drops it — even when the server clamped', () {
      expect(
          c2120PendingAfterPayload(
              pending: '999 strip', oldLabel: '5 strip', newLabel: '50 strip'),
          isNull);
    });

    test('with nothing pending the payload is what prints', () {
      expect(c2120ChipText(pending: null, payload: '5 strip'), '5 strip');
      expect(c2120ChipText(pending: '', payload: '5 strip'), '5 strip');
      expect(c2120ChipText(pending: '7 strip', payload: '5 strip'), '7 strip');
    });
  });
}
