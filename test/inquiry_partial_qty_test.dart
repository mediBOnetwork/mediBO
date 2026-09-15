// CHANGE #535 (#527 gap 60) — the part-quantity field on the public inquiry
// form.
//
// What this holds down:
//
//   1. A payload WITHOUT `partial_qty` renders NO quantity field. #527's
//      decorator can be turned off, and an app talking to an older backend
//      must keep exactly the behaviour it had before this change.
//
//   2. A payload WITH `partial_qty` renders the BACKEND's label, asked_label
//      and hint. Nothing here is worded in Dart, so the fixture's copy is
//      deliberately not the wording `_inquiry_partial_qty_items()` ships —
//      a field that printed its own caption fails.
//
//   3. An untouched field is OMITTED from the submitted answer. Blank means
//      "the whole quantity" to `submit_inquiry_form`; a Dart-side 0 would turn
//      every full answer into a partial refusal, and the whole remainder
//      cascade would fire on an order nobody shortened.
//
// No network, no Supabase, no goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/public/inquiry_form_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/inquiry_v12.dart';

Map<String, dynamic> _item({bool withPartialQty = true}) => {
      'inquiry_id': 71,
      'product_name': 'AZITHRAL 500',
      'company': 'ALKEM',
      'quantity': '100',
      'locked': false,
      if (withPartialQty)
        'partial_qty': {
          'enabled': true,
          // Deliberately NOT the backend's shipped wording: these three strings
          // must arrive on screen exactly as the payload wrote them.
          'label': 'FIXTURE how many can you send',
          'hint': 'FIXTURE blank means all of it',
          'asked_label': 'FIXTURE asked: 100',
          'max': 100,
        },
    };

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
      MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child))),
    );

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('InquiryPartialQtyField.maybe', () {
    test('absent partial_qty renders nothing', () {
      final item = _item(withPartialQty: false);
      expect(InquiryPartialQtyField.enabledFor(item), isFalse);
      expect(
        InquiryPartialQtyField.maybe(item, TextEditingController()),
        isNull,
      );
    });

    test('enabled:false renders nothing either', () {
      final item = _item();
      (item['partial_qty'] as Map)['enabled'] = false;
      expect(InquiryPartialQtyField.enabledFor(item), isFalse);
      expect(
        InquiryPartialQtyField.maybe(item, TextEditingController()),
        isNull,
      );
    });

    test('present partial_qty builds the row', () {
      expect(
        InquiryPartialQtyField.maybe(_item(), TextEditingController()),
        isA<InquiryPartialQtyField>(),
      );
    });
  });

  testWidgets('a payload WITHOUT partial_qty draws no quantity field',
      (tester) async {
    final built = InquiryPartialQtyField.maybe(
        _item(withPartialQty: false), TextEditingController());
    await _pump(tester, built ?? const SizedBox.shrink());

    expect(find.byKey(const Key('c535_qty_field')), findsNothing);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('a payload WITH partial_qty prints the BACKEND strings',
      (tester) async {
    final ctl = TextEditingController();
    await _pump(tester, InquiryPartialQtyField.maybe(_item(), ctl)!);

    expect(find.text('FIXTURE how many can you send'), findsOneWidget);
    expect(find.text('FIXTURE asked: 100'), findsOneWidget);

    final field = tester.widget<TextField>(
        find.byKey(const Key('c535_qty_field')));
    expect((field.decoration!.hintText), 'FIXTURE blank means all of it');
  });

  testWidgets('the field is proportional, never a fixed width',
      (tester) async {
    await _pump(
        tester, InquiryPartialQtyField.maybe(_item(), TextEditingController())!);

    // Two Expanded children: the caption block and the field. A hard-coded
    // width would not survive 360 / 414 / 1280.
    expect(
      find.descendant(
          of: find.byType(InquiryPartialQtyField), matching: find.byType(Expanded)),
      findsNWidgets(2),
    );
    expect(
      find.descendant(
          of: find.byType(InquiryPartialQtyField),
          matching: find.byWidgetPredicate(
              (w) => w is SizedBox && w.width != null && w.child is TextField)),
      findsNothing,
    );
  });

  testWidgets('typing lands in the caller\'s controller', (tester) async {
    final ctl = TextEditingController();
    var changes = 0;
    await _pump(
      tester,
      InquiryPartialQtyField.maybe(_item(), ctl, onChanged: () => changes++)!,
    );

    await tester.enterText(find.byKey(const Key('c535_qty_field')), '40');
    expect(ctl.text, '40');
    expect(changes, 1);
  });

  group('buildInquiryAnswer', () {
    test('an untouched quantity is OMITTED, never sent as 0', () {
      final a = buildInquiryAnswer(
          inquiryId: 71, answer: 'Available', rate: '12.50', offeredQty: null);
      expect(a.containsKey('offered_qty'), isFalse);
      expect(a['rate'], '12.50');
      expect(a['answer'], 'Available');
      expect(a['inquiry_id'], 71);
    });

    test('a blank or whitespace quantity is OMITTED too', () {
      expect(
        buildInquiryAnswer(inquiryId: 71, answer: 'Available', offeredQty: '')
            .containsKey('offered_qty'),
        isFalse,
      );
      expect(
        buildInquiryAnswer(inquiryId: 71, answer: 'Available', offeredQty: '  ')
            .containsKey('offered_qty'),
        isFalse,
      );
    });

    test('a typed quantity is carried through, trimmed, as text', () {
      final a = buildInquiryAnswer(
          inquiryId: 71, answer: 'Available', offeredQty: ' 40 ');
      expect(a['offered_qty'], '40');
      // TEXT, not a number: submit_inquiry_form validates the string itself.
      expect(a['offered_qty'], isA<String>());
    });

    test('an untouched rate is omitted on the same rule', () {
      final a = buildInquiryAnswer(
          inquiryId: 71, answer: 'Available', rate: '', offeredQty: '40');
      expect(a.containsKey('rate'), isFalse);
      expect(a['offered_qty'], '40');
    });
  });

  testWidgets('it reaches the screen through the itemTrailingWidget seam',
      (tester) async {
    // The public form hands _rateField to InquiryAnswerList.itemTrailingWidget.
    // This drives the REAL seam: the trailing builder is asked for each item,
    // and only the item the payload decorated gets a field.
    final ctl = TextEditingController();
    final decorated = _item();
    final plain = _item(withPartialQty: false)..['inquiry_id'] = 72;
    await _pump(
      tester,
      InquiryAnswerList(
        items: [decorated, plain],
        answerOverrides: const {71: 'Available', 72: 'Available'},
        onAnswer: (_, _) {},
        surface: 'link',
        itemTrailingWidget: (item) => InquiryPartialQtyField.maybe(item, ctl),
      ),
    );
    await tester.pump();

    // One field for the decorated item, none for the undecorated one.
    expect(find.byKey(const Key('c535_qty_field')), findsOneWidget);
    expect(find.text('FIXTURE how many can you send'), findsOneWidget);
  });
}
