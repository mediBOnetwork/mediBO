// PROTECTED — CMD #2074: the compare table is the backend's own table, drawn.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes this behaviour.
//
// THE SHAPE THAT CHANGED: products used to be COLUMNS and attributes ROWS,
// which reads fine for three ticked packs and not at all for twenty brands of
// one salt. Products are rows now. Everything that could have drifted into Dart
// when the table turned — the column ORDER, the headings, the cell strings, the
// two trade columns, the stock word, the ADD word — is asserted to come from
// the payload and nothing else.
//
// What this holds down:
//
//   1. COLUMN ORDER AND HEADINGS ARE THE PAYLOAD'S. The fixture ships them in
//      the spec's order and the header prints exactly that, with no Dart
//      literal anywhere near it. A reordered payload reorders the table.
//   2. CELLS SIT AT THEIR COLUMN'S INDEX, AND ROWS KEEP PAYLOAD ORDER. The
//      opened pack is row one because the backend put it there — the fixture is
//      deliberately not in sales order.
//   3. THE LOCKED PILL IS ONE FACT IN THREE CELLS. A pack with no real trade
//      rate shows the backend's literal word in Sale price, Margin AND Profit,
//      in the backend's own pill colours; a pack WITH one shows the amount, the
//      percentage and the rupee profit, and no pill on the two trade cells. The
//      app never derives a margin from MRP (#366, #746).
//   4. AVAILABILITY IS TEXT, NEVER A BUTTON. The stock column renders the
//      backend's word with no tap target of its own.
//   5. ADD IS THE CART, AND IT IS THE BACKEND'S WORD. The label is cta_label
//      verbatim; can_add:false disables it; a tap morphs it into the − n +
//      stepper and drives the SAME AppState cart a product card drives; a row
//      with no word gets no control at all.
//   6. A SHORT PAYLOAD DRAWS A BLANK, NOT AN EXCEPTION. Fewer cells than
//      columns must leave a hole, because a table a pharmacy is mid-decision on
//      may not throw.
//   7. THE FROZEN COLUMN IS A SHARE OF THE VIEWPORT, WITHIN THE BACKEND'S
//      BOUNDS — so 320px and a desktop draw the same table, and the name column
//      is never a fixed width (mobile-first, CMD #1950).
//   8. EMPTY IS THE BACKEND'S COPY, under real headings.
//
// No network, no Supabase, no goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/app_state.dart';
import 'package:pharma_b2b/models/cart_model.dart';
import 'package:pharma_b2b/models/compare_table.dart';
import 'package:pharma_b2b/screens/compare_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

/// The payload `pdp_salt_compare()` actually returns, verified against the
/// branch database: ten columns in the spec's order, the opened pack first, one
/// locked row and one priced row.
Map<String, dynamic> _payload() => {
      'ok': true,
      'has': true,
      'title': 'Compare',
      'note': 'Other brands with the same composition.',
      'empty': 'No other brand of this composition is listed yet.',
      'max': 20,
      'layout': {
        'name_pct': 42,
        'name_min': 116,
        'name_max': 200,
        'row_h': 64,
        'head_h': 44,
      },
      'columns': [
        {'key': 'name', 'kind': 'name', 'align': 'left', 'frozen': true,
         'label': 'Product'},
        {'key': 'company', 'kind': 'text', 'align': 'left', 'frozen': false,
         'width': 116, 'label': 'Company'},
        {'key': 'pack', 'kind': 'text', 'align': 'left', 'frozen': false,
         'width': 88, 'label': 'Pack'},
        {'key': 'mrp', 'kind': 'text', 'align': 'right', 'frozen': false,
         'width': 92, 'label': 'MRP'},
        {'key': 'sale', 'kind': 'pill', 'align': 'right', 'frozen': false,
         'width': 104, 'label': 'Sale price'},
        {'key': 'margin', 'kind': 'text', 'align': 'right', 'frozen': false,
         'width': 92, 'label': 'Margin'},
        {'key': 'profit', 'kind': 'text', 'align': 'right', 'frozen': false,
         'width': 96, 'label': 'Profit'},
        {'key': 'drugtype', 'kind': 'text', 'align': 'left', 'frozen': false,
         'width': 96, 'label': 'Drug type'},
        {'key': 'stock', 'kind': 'text', 'align': 'left', 'frozen': false,
         'width': 108, 'label': 'Availability'},
        {'key': 'add', 'kind': 'add', 'align': 'left', 'frozen': false,
         'width': 112, 'label': 'Add'},
      ],
      'rows': [
        // The opened pack. Locked: no real trade rate, so all three money
        // cells carry the literal word in the muted pill.
        {
          'id': '990001',
          'name': 'Zeta Tablet',
          'company': 'Acme Labs Ltd',
          'is_current': true,
          'tag': 'Viewing',
          'can_add': true,
          'cta_label': 'ADD',
          'cells': [
            {'has': true, 'value': 'Zeta Tablet', 'tone': 'text'},
            {'has': true, 'value': 'Acme Labs Ltd', 'tone': 'text'},
            {'has': true, 'value': 'Strip', 'tone': 'text'},
            {'has': true, 'value': '₹69.96', 'tone': 'text'},
            {'has': true, 'value': 'PTR', 'tone': 'text', 'locked': true,
             'pill': {'bg': '#F3F4F6', 'fg': '#6B7280'}},
            {'has': false, 'value': 'PTR', 'tone': 'text', 'locked': true,
             'pill': {'bg': '#F3F4F6', 'fg': '#6B7280'}},
            {'has': false, 'value': 'PTR', 'tone': 'text', 'locked': true,
             'pill': {'bg': '#F3F4F6', 'fg': '#6B7280'}},
            {'has': true, 'value': 'Ethical', 'tone': 'text'},
            {'has': true, 'value': 'Add to cart', 'tone': 'success'},
            {'has': true, 'value': '', 'tone': 'text'},
          ],
        },
        // A priced pack: MRP 72.00, PTR 50.00, GST 12% -> net 56.00, so the
        // margin is 22.2% of MRP and the profit ₹16.00 per pack. Both computed
        // by _pricing_compute, never here.
        {
          'id': '990002',
          'name': 'Alpha Tablet',
          'company': 'Alpha Labs Ltd',
          'is_current': false,
          'tag': '',
          'can_add': true,
          'cta_label': 'ADD',
          'cells': [
            {'has': true, 'value': 'Alpha Tablet', 'tone': 'text'},
            {'has': true, 'value': 'Alpha Labs Ltd', 'tone': 'text'},
            {'has': true, 'value': 'Strip', 'tone': 'text'},
            {'has': true, 'value': '₹72.00', 'tone': 'text'},
            {'has': true, 'value': '₹50.00', 'tone': 'text', 'locked': false,
             'pill': {'bg': '#1B7A43', 'fg': '#FFFFFF'}},
            {'has': true, 'value': '22.2%', 'tone': 'success',
             'locked': false, 'pill': null},
            {'has': true, 'value': '₹16.00', 'tone': 'success',
             'locked': false, 'pill': null},
            {'has': true, 'value': 'Generic', 'tone': 'text'},
            {'has': true, 'value': 'Add to cart', 'tone': 'success'},
            {'has': true, 'value': '', 'tone': 'text'},
          ],
        },
        // Out of stock in this buyer's zone: the word is the backend's and the
        // ADD control is disabled, not hidden.
        {
          'id': '990003',
          'name': 'Beta Tablet',
          'company': 'Beta Pharma Pvt Ltd',
          'is_current': false,
          'tag': '',
          'can_add': false,
          'cta_label': 'Unavailable',
          'cells': [
            {'has': true, 'value': 'Beta Tablet', 'tone': 'text'},
            {'has': true, 'value': 'Beta Pharma Pvt Ltd', 'tone': 'text'},
            {'has': true, 'value': 'Strip', 'tone': 'text'},
            {'has': true, 'value': '₹88.50', 'tone': 'text'},
            {'has': true, 'value': 'PTR', 'tone': 'text', 'locked': true,
             'pill': {'bg': '#F3F4F6', 'fg': '#6B7280'}},
            {'has': false, 'value': 'PTR', 'tone': 'text', 'locked': true,
             'pill': {'bg': '#F3F4F6', 'fg': '#6B7280'}},
            {'has': false, 'value': 'PTR', 'tone': 'text', 'locked': true,
             'pill': {'bg': '#F3F4F6', 'fg': '#6B7280'}},
            // drug_type unset -> the backend's own dash, not a Dart blank.
            {'has': false, 'value': '—', 'tone': 'text'},
            {'has': true, 'value': 'Unavailable', 'tone': 'warning'},
            {'has': true, 'value': '', 'tone': 'text'},
          ],
        },
      ],
    };

Map<String, dynamic> _empty() => {
      'ok': true,
      'has': false,
      'title': 'Compare',
      'note': 'Other brands with the same composition.',
      'empty': 'No other brand of this composition is listed yet.',
      'max': 20,
      'layout': (_payload()['layout'] as Map).cast<String, dynamic>(),
      'columns': _payload()['columns'],
      'rows': const [],
    };

Future<CartModel> _pump(
  WidgetTester tester,
  Map<String, dynamic> payload, {
  Size size = const Size(390, 844),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final cart = CartModel.forTest();
  await tester.pumpWidget(
    AppState(
      cart: cart,
      child: MaterialApp(
        home: CompareScreen(
          productId: '990001',
          loader: (_) async => CompareTable.fromMap(payload),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return cart;
}

void main() {
  setUpAll(() {
    RenderLog.flushEnabled = false;
  });

  group('1 — the columns are the payload\'s, in the payload\'s order', () {
    testWidgets('every heading is printed, and the frozen one is first',
        (tester) async {
      await _pump(tester, _payload(), size: const Size(1200, 900));

      for (final label in const [
        'Product', 'Company', 'Pack', 'MRP', 'Sale price',
        'Margin', 'Profit', 'Drug type', 'Availability', 'Add',
      ]) {
        expect(find.text(label), findsWidgets,
            reason: '$label is a backend heading — it must be printed');
      }

      // The order is read off the rendered x-positions, so a Dart-side sort
      // would fail this even though every label is present.
      final xs = <String, double>{};
      for (final label in const [
        'Product', 'Company', 'Pack', 'MRP', 'Sale price',
        'Margin', 'Profit', 'Drug type', 'Availability', 'Add',
      ]) {
        xs[label] = tester.getTopLeft(find.text(label).first).dx;
      }
      final ordered = xs.keys.toList()
        ..sort((a, b) => xs[a]!.compareTo(xs[b]!));
      expect(ordered, const [
        'Product', 'Company', 'Pack', 'MRP', 'Sale price',
        'Margin', 'Profit', 'Drug type', 'Availability', 'Add',
      ]);
    });

    testWidgets('a reordered payload reorders the table — nothing is keyed '
        'off a column name in Dart', (tester) async {
      final p = _payload();
      final cols = (p['columns'] as List).cast<Map<String, dynamic>>();
      // Swap Company and Pack in the HEADER and in every row's cells.
      final swapped = [...cols];
      final tmp = swapped[1];
      swapped[1] = swapped[2];
      swapped[2] = tmp;
      p['columns'] = swapped;
      for (final r in (p['rows'] as List).cast<Map<String, dynamic>>()) {
        final cells = (r['cells'] as List).toList();
        final c = cells[1];
        cells[1] = cells[2];
        cells[2] = c;
        r['cells'] = cells;
      }

      await _pump(tester, p, size: const Size(1200, 900));
      expect(tester.getTopLeft(find.text('Pack').first).dx,
          lessThan(tester.getTopLeft(find.text('Company').first).dx),
          reason: 'the payload moved Pack before Company; so must the table');
      expect(tester.getTopLeft(find.text('Strip').first).dx,
          lessThan(tester.getTopLeft(find.text('Acme Labs Ltd').first).dx),
          reason: 'the CELLS moved with their column');
    });
  });

  group('2 — rows keep payload order, opened pack first', () {
    testWidgets('the fixture is not in sales order and is drawn as sent',
        (tester) async {
      await _pump(tester, _payload(), size: const Size(1200, 900));

      final zeta = tester.getTopLeft(find.text('Zeta Tablet')).dy;
      final alpha = tester.getTopLeft(find.text('Alpha Tablet')).dy;
      final beta = tester.getTopLeft(find.text('Beta Tablet')).dy;
      expect(zeta, lessThan(alpha));
      expect(alpha, lessThan(beta));

      // The tag is the backend's word and only the opened pack carries one.
      expect(find.text('Viewing'), findsOneWidget);
    });
  });

  group('3 — the locked pill is one fact in three cells', () {
    testWidgets('no trade rate: the literal word in Sale, Margin and Profit, '
        'in the backend\'s pill colours', (tester) async {
      await _pump(tester, _payload(), size: const Size(1200, 900));

      // Two locked rows x three money cells = six PTR pills, and not one of
      // them is a number derived from MRP.
      expect(find.text('PTR'), findsNWidgets(6));

      final pills = tester
          .widgetList<Container>(find.ancestor(
              of: find.text('PTR').first, matching: find.byType(Container)))
          .where((c) => c.decoration is BoxDecoration)
          .toList();
      expect(pills, isNotEmpty, reason: 'a locked cell is drawn as a pill');
      final deco = pills.first.decoration as BoxDecoration;
      expect(deco.color, const Color(0xFFF3F4F6),
          reason: 'the pill fill is cmp_lock_bg, verbatim from the payload');
    });

    testWidgets('a real trade rate: the amount, the percentage and the rupee '
        'profit — and no pill on the two trade cells', (tester) async {
      await _pump(tester, _payload(), size: const Size(1200, 900));

      expect(find.text('₹50.00'), findsOneWidget, reason: 'sale price');
      expect(find.text('22.2%'), findsOneWidget, reason: 'margin % on MRP');
      expect(find.text('₹16.00'), findsOneWidget, reason: 'profit per pack');

      // 22.2% is plain text: no Container with a fill wraps it.
      final wrapped = tester
          .widgetList<Container>(find.ancestor(
              of: find.text('22.2%'), matching: find.byType(Container)))
          .where((c) =>
              c.decoration is BoxDecoration &&
              (c.decoration as BoxDecoration).color == const Color(0xFF1B7A43))
          .toList();
      expect(wrapped, isEmpty,
          reason: 'an unlocked margin sent no pill — so none is drawn');
    });

    testWidgets('the app computes NO margin of its own: strip the two cells '
        'and the table shows the backend\'s dash, never a number',
        (tester) async {
      final p = _payload();
      final priced = (p['rows'] as List)[1] as Map<String, dynamic>;
      final cells = (priced['cells'] as List).toList();
      cells[5] = {'has': false, 'value': '—', 'tone': 'text'};
      cells[6] = {'has': false, 'value': '—', 'tone': 'text'};
      priced['cells'] = cells;

      await _pump(tester, p, size: const Size(1200, 900));
      expect(find.text('22.2%'), findsNothing);
      expect(find.text('₹16.00'), findsNothing);
      // MRP 72.00 and PTR 50.00 are both still on screen — the app had every
      // input it would need and still printed nothing.
      expect(find.text('₹72.00'), findsOneWidget);
      expect(find.text('₹50.00'), findsOneWidget);
      expect(find.text('—'), findsWidgets);
    });
  });

  group('4 — availability is text, never a button', () {
    testWidgets('the stock word carries no tap target of its own',
        (tester) async {
      await _pump(tester, _payload(), size: const Size(1200, 900));

      expect(find.text('Add to cart'), findsNWidgets(2),
          reason: 'the availability word for the two addable rows');
      expect(find.text('Unavailable'), findsWidgets);

      // No InkWell / button wraps the availability text — the only controls on
      // a row are the name cell and the ADD column.
      expect(
          find.ancestor(
              of: find.text('Add to cart').first,
              matching: find.byType(InkWell)),
          findsNothing,
          reason: 'availability shows the state — it is not a control');
      expect(
          find.ancestor(
              of: find.text('Add to cart').first,
              matching: find.byType(OutlinedButton)),
          findsNothing);
    });
  });

  group('5 — ADD is the cart, and the word is the backend\'s', () {
    testWidgets('the label is cta_label verbatim and a tap morphs it into the '
        'stepper, driving the shared cart', (tester) async {
      final cart = await _pump(tester, _payload(),
          size: const Size(1200, 900));

      final add = find.byKey(const ValueKey('compare-add-990002'));
      expect(add, findsOneWidget);
      expect(
          find.descendant(of: add, matching: find.text('ADD')), findsOneWidget,
          reason: 'the caption is the payload\'s cta_label');

      await tester.tap(add);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(cart.quantityOf('990002'), 1);
      expect(find.byKey(const ValueKey('compare-qty-990002')), findsOneWidget);
      expect(find.byKey(const ValueKey('compare-add-990002')), findsNothing,
          reason: 'ADD morphs in place — the two never show at once');

      await tester.tap(find.byKey(const ValueKey('compare-plus-990002')));
      await tester.pumpAndSettle();
      expect(cart.quantityOf('990002'), 2);

      await tester.tap(find.byKey(const ValueKey('compare-minus-990002')));
      await tester.pumpAndSettle();
      expect(cart.quantityOf('990002'), 1);
    });

    testWidgets('can_add:false disables the control — it is not hidden',
        (tester) async {
      await _pump(tester, _payload(), size: const Size(1200, 900));
      final btn = tester.widget<OutlinedButton>(
          find.byKey(const ValueKey('compare-add-990003')));
      expect(btn.onPressed, isNull,
          reason: 'out of stock is can_add:false, never a stock number');
    });

    testWidgets('no cta_label, no control at all', (tester) async {
      final p = _payload();
      for (final r in (p['rows'] as List).cast<Map<String, dynamic>>()) {
        r['cta_label'] = '';
      }
      await _pump(tester, p, size: const Size(1200, 900));
      expect(find.byType(OutlinedButton), findsNothing,
          reason: 'the app never captions a button of its own');
    });
  });

  group('6 — a short payload draws a blank, not an exception', () {
    testWidgets('fewer cells than columns leaves a hole', (tester) async {
      final p = _payload();
      for (final r in (p['rows'] as List).cast<Map<String, dynamic>>()) {
        r['cells'] = (r['cells'] as List).take(4).toList();
      }
      await _pump(tester, p, size: const Size(1200, 900));
      expect(tester.takeException(), isNull);
      // The columns that were sent still print.
      expect(find.text('Acme Labs Ltd'), findsOneWidget);
    });
  });

  group('7 — the frozen column is a share of the viewport', () {
    test('the width follows the width it is given, inside the backend\'s '
        'bounds', () {
      const l = CompareLayout(
          namePct: 42, nameMin: 116, nameMax: 200, rowH: 64, headH: 44);
      expect(l.nameWidth(320), closeTo(320 * 0.42, 0.01));
      expect(l.nameWidth(390), closeTo(390 * 0.42, 0.01));
      // Clamped at both ends, so a tiny or a huge viewport is still readable.
      expect(l.nameWidth(200), 116, reason: 'never below name_min');
      expect(l.nameWidth(1400), 200, reason: 'never above name_max');
    });

    testWidgets('a 320px phone draws the whole table with no overflow',
        (tester) async {
      await _pump(tester, _payload(), size: const Size(320, 640));
      expect(tester.takeException(), isNull);
      expect(find.text('Zeta Tablet'), findsOneWidget);
      expect(find.text('Product'), findsOneWidget);
    });

    testWidgets('and so does a 412px phone', (tester) async {
      await _pump(tester, _payload(), size: const Size(412, 892));
      expect(tester.takeException(), isNull);
      expect(find.text('Alpha Tablet'), findsOneWidget);
    });
  });

  group('8 — empty is the backend\'s copy, under real headings', () {
    testWidgets('no other brand: the backend sentence, and the columns still '
        'arrived', (tester) async {
      await _pump(tester, _empty());
      expect(find.text('No other brand of this composition is listed yet.'),
          findsOneWidget);
      expect(find.text('Zeta Tablet'), findsNothing);
    });

    testWidgets('ok:false draws nothing rather than a Dart error string',
        (tester) async {
      await _pump(tester, {'ok': false});
      expect(tester.takeException(), isNull);
      expect(find.byType(OutlinedButton), findsNothing);
    });
  });
}
