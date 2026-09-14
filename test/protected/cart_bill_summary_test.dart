// PROTECTED — CMD #2014.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes the cart bill summary or its suggested rail.
//
// What this holds down:
//
//   1. The bill card is ONE payload printed verbatim. `value`, `struck_value`
//      and `free_label` are backend strings — no ₹ is formatted here, no
//      amount is summed here, and the word for "free" is never a Dart literal.
//
//   2. A WAIVED fee is not a zero row. It carries an empty `value`, its own
//      struck amount and the backend's free label, and the widget draws the
//      struck amount with a line through it followed by that label.
//
//   3. Rows render in PAYLOAD ORDER. The fixture is deliberately not in
//      alphabetical or key order, and nothing here re-sorts it.
//
//   4. A row is tappable because the payload says `tappable`, never because
//      its key looks like a fee; the popup's title, body and dismiss word all
//      come from the same row.
//
//   5. Absence is explicit. `has:false`, an empty rows list, or a payload that
//      is not a map all mean "draw nothing" — fromPayload returns null and the
//      cart omits the block rather than rendering an empty card.
//
//   6. The rail is the EXISTING storefront card: its items parse through
//      Product.fromHomeCard, which is the same factory the home feed's rails
//      use, so a rail card and a grid card cannot disagree about a product.
//
// No network, no Supabase, no goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/cart_bill_summary.dart';
import 'package:pharma_b2b/widgets/cart_wishlist_rail.dart';

Map<String, dynamic> _row({
  required String key,
  required String label,
  String icon = 'receipt_long',
  String value = '',
  String struck = '',
  String free = '',
  bool waived = false,
  String tone = 'default',
  bool bold = false,
  bool dividerBefore = false,
  bool tappable = false,
  String popupTitle = '',
  String popupBody = '',
  String popupDismiss = '',
}) =>
    <String, dynamic>{
      'key': key,
      'label': label,
      'icon': icon,
      'value': value,
      'struck_value': struck,
      'free_label': free,
      'waived': waived,
      'tone': tone,
      'bold': bold,
      'divider_before': dividerBefore,
      'tappable': tappable,
      'popup': {
        'title': popupTitle,
        'body': popupBody,
        'dismiss': popupDismiss,
      },
    };

Map<String, dynamic> _bill(List<Map<String, dynamic>> rows) => <String, dynamic>{
      'has': rows.isNotEmpty,
      'title': 'Bill summary',
      'rows': rows,
    };

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: SingleChildScrollView(child: child)),
  ));
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('bill summary — the payload is the card', () {
    testWidgets('labels and amounts print verbatim, in payload order',
        (tester) async {
      final block = CartBillSummary.fromPayload(_bill([
        _row(key: 'mrp_total', label: 'MRP total', value: '₹1,800.00'),
        _row(key: 'trade_total', label: 'Sale price (PTR)', value: '₹806.40'),
        _row(
            key: 'advance',
            label: 'Advance amount',
            value: '₹180.00',
            tone: 'brand',
            bold: true),
        _row(
            key: 'grand_total',
            label: 'Grand total',
            value: '₹855.40',
            tone: 'total',
            bold: true,
            dividerBefore: true),
      ]))!;

      expect(block.rows.map((r) => r.key).toList(),
          <String>['mrp_total', 'trade_total', 'advance', 'grand_total']);

      await _pump(tester, block);

      for (final s in <String>[
        'Bill summary',
        'MRP total',
        '₹1,800.00',
        'Sale price (PTR)',
        '₹806.40',
        'Advance amount',
        '₹180.00',
        'Grand total',
        '₹855.40',
      ]) {
        expect(find.text(s), findsOneWidget, reason: '"$s" must print verbatim');
      }
    });

    testWidgets('a waived fee is its struck amount plus the backend free word',
        (tester) async {
      final block = CartBillSummary.fromPayload(_bill([
        _row(
            key: 'delivery_fee',
            label: 'Delivery fee',
            value: '',
            struck: '₹49.00',
            free: 'FREE',
            waived: true),
      ]))!;

      await _pump(tester, block);

      expect(find.text('₹49.00'), findsOneWidget);
      expect(find.text('FREE'), findsOneWidget);

      final struck = tester.widget<Text>(find.text('₹49.00'));
      expect(struck.style?.decoration, TextDecoration.lineThrough,
          reason: 'a waived amount is struck through, not hidden');
    });

    testWidgets('a tappable row opens the popup the backend wrote',
        (tester) async {
      final block = CartBillSummary.fromPayload(_bill([
        _row(
            key: 'handling_fee',
            label: 'Handling fee',
            value: '₹25.00',
            tappable: true,
            popupTitle: 'Handling fee',
            popupBody: 'Covers picking and packing.',
            popupDismiss: 'Got it'),
        _row(key: 'grand_total', label: 'Grand total', value: '₹100.00'),
      ]))!;

      await _pump(tester, block);
      expect(find.text('Covers picking and packing.'), findsNothing);

      await tester.tap(find.text('Handling fee'));
      await tester.pumpAndSettle();

      expect(find.text('Covers picking and packing.'), findsOneWidget);
      expect(find.text('Got it'), findsOneWidget);

      await tester.tap(find.text('Got it'));
      await tester.pumpAndSettle();
      expect(find.text('Covers picking and packing.'), findsNothing);
    });

    testWidgets('a row the backend did not mark tappable has no popup',
        (tester) async {
      final block = CartBillSummary.fromPayload(_bill([
        _row(
            key: 'handling_fee',
            label: 'Handling fee',
            value: '₹25.00',
            popupTitle: 'Never shown',
            popupBody: 'Never shown either'),
      ]))!;

      await _pump(tester, block);
      await tester.tap(find.text('Handling fee'));
      await tester.pumpAndSettle();

      expect(find.text('Never shown either'), findsNothing,
          reason: 'tappable is the payload\'s decision, not the key\'s shape');
    });

    test('absence is explicit — nothing is drawn without a payload that says so',
        () {
      expect(CartBillSummary.fromPayload(null), isNull);
      expect(CartBillSummary.fromPayload('nope'), isNull);
      expect(CartBillSummary.fromPayload(_bill(const [])), isNull);
      expect(
          CartBillSummary.fromPayload(<String, dynamic>{
            'has': false,
            'title': 'Bill summary',
            'rows': [_row(key: 'x', label: 'x', value: '₹1.00')],
          }),
          isNull,
          reason: 'has:false wins over a non-empty rows list');
    });

    test('an unknown icon name renders no glyph rather than a guessed one', () {
      expect(CartBillSummary.glyphFor('local_shipping_outlined'), isNotNull);
      expect(CartBillSummary.glyphFor('a_glyph_from_a_newer_build'), isNull);
    });
  });

  group('suggested rail — the storefront card, unchanged', () {
    Map<String, dynamic> card(int id, String name) => <String, dynamic>{
          'id': id,
          'name': name,
          'company': 'Acme Labs',
          'pack_label': 'strip',
          'form_chip': '10',
          'image': '',
          'pricing': {
            'price_display': '₹40.00',
            'price_caption': 'PTR',
            'mrp_display': '₹50.00',
            'has_struck_mrp': true,
          },
          'availability': {
            'cta_label': 'Add to cart',
            'cta_short': 'ADD',
            'can_add': true,
            'is_available': true,
            'availability_label': 'Available',
          },
        };

    test('items keep payload order and parse through the shared factory', () {
      final rail = CartWishlistRail.fromPayload(<String, dynamic>{
        'has': true,
        'title': 'You may also need',
        'items': [card(9, 'Zeta'), card(2, 'Alpha'), card(5, 'Mid')],
      }, (_) {})!;

      expect(rail.title, 'You may also need');
      expect(rail.items.map((p) => p.name).toList(),
          <String>['Zeta', 'Alpha', 'Mid'],
          reason: 'the backend decided the order; Dart must not re-sort it');
      expect(rail.items.first.id, '9');
    });

    test('an empty or absent rail draws nothing', () {
      expect(CartWishlistRail.fromPayload(null, (_) {}), isNull);
      expect(
          CartWishlistRail.fromPayload(
              <String, dynamic>{'has': true, 'title': 't', 'items': const []},
              (_) {}),
          isNull);
      expect(
          CartWishlistRail.fromPayload(
              <String, dynamic>{'has': false, 'title': 't', 'items': [card(1, 'A')]},
              (_) {}),
          isNull);
    });

    test('the rail owns no route — a tap is handed back to the caller', () {
      // SCOPE NOTE: CompactProductCard needs a live AppState to mount, so per
      // CLAUDE.md this asserts the rail's DECISION (which product a tap
      // reports) rather than pumping the storefront card, which the storefront
      // tests already cover.
      final taps = <String>[];
      final rail = CartWishlistRail.fromPayload(<String, dynamic>{
        'has': true,
        'title': 'You may also need',
        'items': [card(7, 'Tapped'), card(8, 'Other')],
      }, (p) => taps.add(p.id))!;

      rail.onOpen(rail.items.first);
      expect(taps, <String>['7']);
    });
  });
}
