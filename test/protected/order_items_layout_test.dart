// PROTECTED — CHANGE #641.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes the customer Orders → Items card, never to make an
// unrelated change go green.
//
// What this holds down:
//
//   1. The card prints backend strings and computes nothing. name, company,
//      qty_label ("2 Tubes"), rate_label ("₹69.38"), line_label ("₹138.76")
//      and status_label all render character for character. No currency is
//      formatted here, no unit word is pluralised here, and no status is
//      re-worded here — the regression that prompted this change shipped a
//      card that had lost image, company and pack entirely.
//
//   2. status_label is printed VERBATIM. The word "Awaiting" must never appear
//      in place of the backend's "Confirmation Pending", and the chip's colour
//      travels with the line rather than being mapped from a role or a bool.
//      A red-toned line must render the red the payload sent.
//
//   3. A null image and a null pack behave differently: the image SLOT is
//      always occupied (a placeholder, never a collapsed box, so the list
//      cannot reflow when bytes land), while the pack LINE is omitted
//      entirely. Absence of a pack is not an empty line.
//
//   4. The card fills its parent's width even inside a
//      CrossAxisAlignment.start Column. This is the actual regression: the
//      card carried no width, so it shrank to its widest child — full-bleed on
//      a phone, a collapsed stub on desktop. The width assertion below is the
//      thing that must never go green again by accident.
//
//   5. One card per payload item. cust_order_panel's old unqualified
//      `LEFT JOIN inquiry` emitted an order_item once per inquiry row (8 items
//      → 24 rows on order CPO310726PAL124O1); the payload is deduped at source
//      now, and the card must not re-introduce or hide duplicates.
//
// Fixtures mirror a real my_orders_screen().lines row. No network, no Supabase.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/widgets/customer_order_item_card.dart';
import 'package:pharma_b2b/widgets/product_image.dart';

/// The exact shape `my_orders_screen().lines` / `.unfulfilled_lines` return.
Map<String, dynamic> _line({
  required String name,
  required String company,
  String? imageUrl,
  String? packLabel,
  required String qtyLabel,
  required String rateLabel,
  required String lineLabel,
  required String statusLabel,
  required String statusTone,
  required String bg,
  required String fg,
}) =>
    {
      'name': name,
      'company': company,
      'image_url': imageUrl,
      'pack_label': packLabel,
      'qty_label': qtyLabel,
      'rate_label': rateLabel,
      'line_label': lineLabel,
      'status_label': statusLabel,
      'status_tone': statusTone,
      'status_ok': statusTone == 'green',
      'status_colors': {'bg': bg, 'fg': fg},
    };

/// Item 1 — everything present. Values copied from live order
/// CPO310726PAL124O1 so the fixture cannot drift from the real payload.
final _withImageAndPack = _line(
  name: 'Pinkgums Dental Gel',
  company: 'MED MANOR ORGANICS PVT LTD',
  imageUrl: 'https://cdn.medibo.in/pinkgums.jpg',
  packLabel: '10 gm in 1 tube',
  qtyLabel: '2 Tubes',
  rateLabel: '₹69.38',
  lineLabel: '₹138.76',
  statusLabel: 'Available',
  statusTone: 'green',
  bg: '#E1F5EE',
  fg: '#0F6E56',
);

/// Item 2 — image AND pack both null. The awkward row.
final _bothNull = _line(
  name: 'Emessa E-Oil',
  company: 'A MENARINI INDIA PVT LTD',
  imageUrl: null,
  packLabel: null,
  qtyLabel: '4 Bottles',
  rateLabel: '₹395.00',
  lineLabel: '₹1,580.00',
  statusLabel: 'Confirmation Pending',
  statusTone: 'yellow',
  bg: '#FEF3C7',
  fg: '#92400E',
);

/// Item 3 — the red tone.
final _redTone = _line(
  name: 'Rozustat 20 Tablet',
  company: 'MACLEODS PHARMACEUTICALS PVT LTD',
  imageUrl: 'https://cdn.medibo.in/rozustat.jpg',
  packLabel: '15 tablets in 1 strip',
  qtyLabel: '2 Strips',
  rateLabel: '₹456.32',
  lineLabel: '₹912.64',
  statusLabel: 'No Supplier Available',
  statusTone: 'red',
  bg: '#FBE9E7',
  fg: '#B42318',
);

/// Deliberately much wider than the card's own content. The default test view
/// is only 800px — narrow enough that the content nearly fills it, which would
/// make the width assertion below pass even for a shrink-wrapping card. At
/// 1400 a card that sizes to its text measures ~600 and the assertion bites.
/// This is the desktop case the regression was reported on.
const double _surfaceWidth = 1400;

/// Renders the payload exactly as the Items tab does — inside a
/// CrossAxisAlignment.start Column, which is the container that made the old
/// card shrink-wrap.
Future<void> _pumpItems(
    WidgetTester tester, List<Map<String, dynamic>> payload) async {
  tester.view.physicalSize = const Size(_surfaceWidth, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: _surfaceWidth,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: payload
                  .map((j) => CustomerOrderItemCard(
                      item: CustomerOrderItem.fromPayload(j)))
                  .toList(),
            ),
          ),
        ),
      ),
    ),
  ));
  // Not pumpAndSettle: the image placeholder's fade is a running animation and
  // the network image never resolves in a test.
  await tester.pump();
}

void main() {
  testWidgets('every backend string renders verbatim', (tester) async {
    await _pumpItems(tester, [_withImageAndPack]);

    expect(find.text('Pinkgums Dental Gel'), findsOneWidget);
    expect(find.text('MED MANOR ORGANICS PVT LTD'), findsOneWidget);
    expect(find.text('10 gm in 1 tube'), findsOneWidget);
    // The unit word and its plural came from the payload, not from Dart.
    expect(find.text('2 Tubes'), findsOneWidget);
    // Currency formatted server-side — no NumberFormat here.
    expect(find.text('₹69.38'), findsOneWidget);
    expect(find.text('₹138.76'), findsOneWidget);
    expect(find.text('Available'), findsOneWidget);
  });

  testWidgets('status chip prints status_label verbatim — never "Awaiting"',
      (tester) async {
    await _pumpItems(tester, [_withImageAndPack, _bothNull, _redTone]);

    // The exact substitution this change forbids.
    expect(find.textContaining('Awaiting'), findsNothing);

    // Each chip's text IS the backend's status_label.
    for (final expected in const [
      'Available',
      'Confirmation Pending',
      'No Supplier Available',
    ]) {
      final chip = find.widgetWithText(LineStatusChip, expected);
      expect(chip, findsOneWidget, reason: 'chip must print "$expected"');
    }
  });

  testWidgets('status_tone red renders the red the payload sent',
      (tester) async {
    await _pumpItems(tester, [_redTone]);

    final chipText = tester.widget<Text>(find.descendant(
      of: find.byType(LineStatusChip),
      matching: find.text('No Supplier Available'),
    ));
    expect(chipText.style?.color, hexColor('#B42318', fallback: Colors.black),
        reason: 'red tone must use the payload fg, not a colour chosen here');

    final chipBox = tester.widget<Container>(find.descendant(
      of: find.byType(LineStatusChip),
      matching: find.byType(Container),
    ));
    expect((chipBox.decoration as BoxDecoration).color,
        hexColor('#FBE9E7', fallback: Colors.black),
        reason: 'red tone must use the payload bg');
  });

  testWidgets('a null image keeps its slot; a null pack omits its line',
      (tester) async {
    await _pumpItems(tester, [_bothNull]);

    // The slot exists and is still the full 72x72 — it did NOT collapse.
    final img = tester.widget<ProductImage>(find.byType(ProductImage));
    expect(img.url, '',
        reason: 'a null image_url must read as the explicit "no image"');
    final slot = tester.getSize(find.byType(ProductImage));
    expect(slot.width, 72);
    expect(slot.height, 72);

    // The row still renders its real content.
    expect(find.text('Emessa E-Oil'), findsOneWidget);
    expect(find.text('4 Bottles'), findsOneWidget);

    // A null pack contributes NO line at all. The card holds exactly two grey
    // 14sp lines' worth of slots normally (company + pack); here only company.
    final greyLines = tester
        .widgetList<Text>(find.byType(Text))
        .where((t) => t.style?.fontSize == 14)
        .map((t) => t.data)
        .toList();
    expect(greyLines, ['A MENARINI INDIA PVT LTD'],
        reason: 'null pack_label must add no line, not an empty one');
  });

  testWidgets('the card fills its parent width (the desktop regression)',
      (tester) async {
    await _pumpItems(tester, [_withImageAndPack, _bothNull, _redTone]);

    for (var i = 0; i < 3; i++) {
      final w = tester.getSize(find.byType(CustomerOrderItemCard).at(i)).width;
      expect(w, _surfaceWidth,
          reason: 'card $i must stretch to the full width, not shrink-wrap');
    }
  });

  testWidgets('exactly one card per payload item', (tester) async {
    await _pumpItems(tester, [_withImageAndPack, _bothNull, _redTone]);

    expect(find.byType(CustomerOrderItemCard), findsNWidgets(3));
    // And each product appears exactly once — the duplicate the old
    // cust_order_panel join produced must not reappear.
    expect(find.text('Pinkgums Dental Gel'), findsOneWidget);
    expect(find.text('Emessa E-Oil'), findsOneWidget);
    expect(find.text('Rozustat 20 Tablet'), findsOneWidget);
  });
}
