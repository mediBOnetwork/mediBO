// PROTECTED — CHANGE #639.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes inquiry auto-tick or inquiry item ORDER.
//
// What this holds down, for the ONE widget all three inquiry surfaces share
// (WhatsApp link page, supplier Inquiry tab, admin Supplier Inquiry):
//
//   1. prestate 'Available' arrives PRE-SELECTED. The backend's zone state
//      already says this supplier stocks the item, so the chip is lit without
//      the supplier touching it.
//
//   2. …and stays EDITABLE. Pre-ticked is not locked: tapping another chip
//      still reports the new answer. An auto-tick the supplier cannot overrule
//      would put words in their mouth.
//
//   3. prestate null arrives with NOTHING selected — the manual case. The app
//      must not invent a default from any other field.
//
//   4. An explicit answer outranks prestate, and a live tap outranks both.
//
//   5. ITEM ORDER IS THE PAYLOAD'S. The decorator sorts company A-Z ->
//      category A-Z -> name in Postgres; this widget renders that order
//      verbatim. The fixture is deliberately not alphabetical, so any
//      client-side sort fails this test.
//
// No network, no Supabase, no goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ui_copy_fixture.dart';

import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/inquiry_v12.dart';

// Selected-chip swatches, as inquiry_v12 paints them.
const _kAvailableSel = Color(0xFFE1F5EE);
const _kOosSel = Color(0xFFFAECE7);

Map<String, dynamic> _item({
  required int id,
  required String name,
  String company = 'CIPLA LTD',
  String category = 'ANTI INFECTIVES',
  String? prestate,
  String answer = '',
  bool locked = false,
}) =>
    {
      'inquiry_id': id,
      'product_name': name,
      'company': company,
      'category': category,
      'therapeutic_class': category,
      'image_url': '',
      'answer': answer,
      'editable': true,
      if (prestate != null) 'prestate': prestate,
      'flags': {'is_locked': locked, 'no_supplier': false},
    };

/// Records what the widget reported back.
class _Answers {
  final List<({int id, String answer})> calls = [];
  void call(int id, String answer) => calls.add((id: id, answer: answer));
}

Future<_Answers> _pump(
  WidgetTester tester,
  List<Map<String, dynamic>> items, {
  Map<int, String> overrides = const {},
}) async {
  final answers = _Answers();
  await tester.pumpWidget(MaterialApp(
    home: MediaQuery(
      // < 960 → the narrow (stacked) card, the one suppliers actually see.
      data: const MediaQueryData(size: Size(390, 1200)),
      child: Scaffold(
        body: SingleChildScrollView(
          child: InquiryAnswerList(
            items: items,
            answerOverrides: overrides,
            onAnswer: answers.call,
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return answers;
}

void main() {
  setUp(seedUiCopy);
  setUpAll(() => RenderLog.flushEnabled = false);

  testWidgets('1+2. prestate Available arrives selected AND stays editable',
      (tester) async {
    final answers = await _pump(tester, [
      _item(id: 1, name: 'Montecip 10mg Tablet', prestate: 'Available'),
    ]);

    // 1. lit without a tap
    expect(_bg(tester, 'Available'), _kAvailableSel,
        reason: 'prestate Available must arrive pre-selected');
    expect(_bg(tester, 'Out of stock'), Colors.white);

    // 2. still overrulable
    await tester.tap(find.text('Out of stock'));
    await tester.pumpAndSettle();
    expect(answers.calls, hasLength(1));
    expect(answers.calls.single.id, 1);
    expect(answers.calls.single.answer, 'Out of Stock',
        reason: 'a pre-ticked item must remain editable');
  });

  testWidgets('3. prestate null arrives with nothing selected', (tester) async {
    await _pump(tester, [
      _item(id: 2, name: 'Azimax 100 Dry Syrup'),
    ]);

    expect(_bg(tester, 'Available'), Colors.white);
    expect(_bg(tester, 'Out of stock'), Colors.white);
    expect(_bg(tester, "Don't stock"), Colors.white,
        reason: 'no prestate means the supplier answers manually');
  });

  testWidgets('4. an explicit answer outranks prestate', (tester) async {
    await _pump(tester, [
      _item(
          id: 3,
          name: 'VesiBeta 25 Tablet ER',
          prestate: 'Available',
          answer: 'Out of Stock'),
    ]);

    expect(_bg(tester, 'Out of stock'), _kOosSel);
    expect(_bg(tester, 'Available'), Colors.white,
        reason: 'a submitted answer wins over the auto-tick');
  });

  testWidgets('4b. a live tap (override) outranks both', (tester) async {
    await _pump(
      tester,
      [_item(id: 4, name: 'Ganaton OD Capsule SR', prestate: 'Available')],
      overrides: {4: "We don't stock this product"},
    );

    expect(_bg(tester, "Don't stock"), const Color(0xFFF1EFE8));
    expect(_bg(tester, 'Available'), Colors.white);
  });

  testWidgets('5. items render in PAYLOAD ORDER — no client sort',
      (tester) async {
    // Deliberately not alphabetical, and not grouped by company: this is the
    // order the decorator sent, so it is the order that must render.
    await _pump(tester, [
      _item(id: 10, name: 'Zicoplanin 400mg Injection', company: 'ABBOTT'),
      _item(id: 11, name: 'Azimax 100 Dry Syrup', company: 'SUN PHARMA'),
      _item(id: 12, name: 'Montecip 10mg Tablet', company: 'CIPLA LTD'),
    ]);

    final y1 = tester.getTopLeft(find.text('Zicoplanin 400mg Injection')).dy;
    final y2 = tester.getTopLeft(find.text('Azimax 100 Dry Syrup')).dy;
    final y3 = tester.getTopLeft(find.text('Montecip 10mg Tablet')).dy;

    expect(y1, lessThan(y2));
    expect(y2, lessThan(y3));
  });
}

/// Background colour of the chip carrying [label].
Color? _bg(WidgetTester tester, String label) {
  final c = tester.widget<AnimatedContainer>(
    find
        .ancestor(
            of: find.text(label).first, matching: find.byType(AnimatedContainer))
        .first,
  );
  return (c.decoration as BoxDecoration).color;
}
