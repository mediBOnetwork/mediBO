// PROTECTED — CMD #2079.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes what the cart's "Bill details" card is allowed to say.
//
// WHY THIS FILE EXISTS. #2079 gave one bill row the right to answer in WORDS
// instead of rupees: the sale-price total cannot be a number until every line
// in the basket has a PTR on record, and printing ₹0.00 there would be a lie
// the customer pays attention to. The temptation on the next pass is to treat
// that sentence like any other value — strike it through when the row is
// waived, or decide in Dart when to show it. Both are the bug.
//
// What this holds down:
//
//   1. is_text is the BACKEND's flag. A row carrying it prints its sentence
//      and NOTHING else — no struck amount, no FREE word — even when the same
//      payload also set waived/struck_value/free_label.
//
//   2. A row WITHOUT is_text keeps the #2047 behaviour exactly: a waived fee
//      is still its struck amount plus the backend's own word for free.
//
//   3. The sentence is never written here. Whatever string the payload sent is
//      what appears; the widget has no copy of "Confirmed on bill".
//
// No network, no Supabase, no goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/cart_bill_summary.dart';

Map<String, dynamic> _row(
  String key,
  String label,
  String value, {
  bool isText = false,
  bool waived = false,
  String struck = '',
  String free = '',
}) =>
    {
      'key': key,
      'label': label,
      'icon': 'sell_outlined',
      'value': value,
      'is_text': isText,
      'struck_value': struck,
      'free_label': free,
      'waived': waived,
      'tone': 'default',
      'bold': false,
      'divider_before': false,
      'tappable': false,
      'popup': {'title': '', 'body': '', 'dismiss': ''},
    };

Future<void> _pump(WidgetTester tester, List<Map<String, dynamic>> rows) async {
  final card = CartBillSummary.fromPayload(
      {'has': true, 'title': 'Bill details', 'rows': rows});
  expect(card, isNotNull);
  await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: card!))));
  await tester.pump();
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  testWidgets('1. a text row prints its sentence and no money decoration',
      (tester) async {
    await _pump(tester, [
      // Deliberately hostile: the payload ALSO carries waived + a struck
      // amount + a free word. is_text must win over all three.
      _row('trade_total', 'Sale price total', 'Confirmed on bill',
          isText: true, waived: true, struck: '₹123.00', free: 'FREE'),
    ]);

    expect(find.text('Sale price total'), findsOneWidget);
    expect(find.text('Confirmed on bill'), findsOneWidget);
    expect(find.text('₹123.00'), findsNothing);
    expect(find.text('FREE'), findsNothing);
  });

  testWidgets('2. a waived fee is unchanged — struck amount + the free word',
      (tester) async {
    await _pump(tester, [
      _row('handling_fee', 'Handling fee', '',
          waived: true, struck: '₹19.00', free: 'FREE'),
    ]);

    expect(find.text('Handling fee'), findsOneWidget);
    expect(find.text('₹19.00'), findsOneWidget);
    expect(find.text('FREE'), findsOneWidget);
  });

  testWidgets('3. the sentence is the payload\'s, never a Dart literal',
      (tester) async {
    await _pump(tester, [
      _row('trade_total', 'Sale price total', 'Priced after packing',
          isText: true),
    ]);

    expect(find.text('Priced after packing'), findsOneWidget);
    expect(find.text('Confirmed on bill'), findsNothing);
  });

  test('4. is_text defaults to false so an older payload is unaffected', () {
    final r = BillRow.fromMap(_row('mrp_total', 'MRP total', '₹250.00'));
    expect(r.isText, isFalse);
    expect(r.value, '₹250.00');
  });
}
