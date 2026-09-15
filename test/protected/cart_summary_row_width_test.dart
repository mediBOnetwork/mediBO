// PROTECTED — CMD #2024 (the width contract of the ONE cart summary row).
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes how the summary row above Place order is laid out.
//
// CMD #2013 shipped the row with a Spacer between its two halves. At 360px it
// read "Advance to ... ₹252.79" with roughly 65px of width sitting unused
// beside the ellipsis. A Spacer is a Flexible with flex:1 and no child, so it
// is laid out in the SAME flex pass as the real Flexible children and claims
// its share of the free width first; the only thing left to squeeze was the
// label. That is standing lesson 327, and this file is what stops it coming
// back — on this row and as a pattern.
//
// What this holds down, at the two phone widths the proof is taken at:
//
//   1. THE AMOUNTS NEVER SHRINK. "4" and "₹252.79" are never ellipsised, at
//      any width. A customer may lose a word of a label; never a digit of the
//      sum they are about to pay.
//
//   2. NO WIDTH IS WASTED BESIDE AN ELLIPSIS. The advance amount's right edge
//      sits on the row's right edge and the items label's left edge sits on
//      the row's left edge. Every free pixel is therefore inside the two
//      labels, which is exactly what the Spacer used to take away.
//
//   3. THE HALVES STAY JUSTIFIED WHEN THE TEXT IS SHORT. Two loose Flexibles
//      alone pack to the left, so short labels would clump in the left half
//      with dead space on the right. The free width is spent by the Row's
//      mainAxisAlignment AFTER the halves are sized — never by a flex child.
//
//   4. THE LONGER SENTENCE GETS THE WIDER HALF. Under pressure the advance
//      half (flex 4) is wider than the items half (flex 3): "Advance to pay"
//      gives up its characters after "Total items" does.
//
//   5. NO Spacer LIVES IN THIS ROW. The cause itself, asserted directly.
//
// The test font makes every glyph a square em box, so the long strings below
// are the CONSTRAINED case at both widths and the short ones are the roomy
// case. Both are checked; #2013's 412px proof looked perfect while 360px was
// broken, which is why neither width is allowed to stand in for the other.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/cart_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

const _pagePad = 16.0;

Map<String, dynamic> _render({
  required String itemsLabel,
  required String itemsValue,
  required String advanceLabel,
  required String advance,
}) =>
    {
      'summary': {
        'bottom': {
          'has': true,
          'items_label': itemsLabel,
          'items_value': itemsValue,
          'advance_label': advanceLabel,
          'has_advance': true,
          'advance_display': advance,
        }
      }
    };

/// The row as the cart actually builds it: inside the footer's 16px padding,
/// on a phone-width viewport.
Future<void> _pumpAt(
    WidgetTester tester, double width, Map<String, dynamic> render) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = Size(width, 800);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(_pagePad, 12, _pagePad, 16),
          child: C2013SummaryRow(render: render),
        ),
      ),
    ),
  ));
  await tester.pump();
}

bool _ellipsised(WidgetTester tester, String text) =>
    tester.renderObject<RenderParagraph>(find.text(text)).didExceedMaxLines;

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  const widths = <double>[360, 412];

  for (final width in widths) {
    final right = width - _pagePad;

    group('CMD #2024 — the summary row at ${width.toInt()}px', () {
      testWidgets('neither amount is ever ellipsised', (tester) async {
        await _pumpAt(
            tester,
            width,
            _render(
              itemsLabel: 'Total items',
              itemsValue: '4',
              advanceLabel: 'Advance to pay',
              advance: '₹252.79',
            ));
        expect(_ellipsised(tester, '4'), isFalse);
        expect(_ellipsised(tester, '₹252.79'), isFalse);
      });

      testWidgets('no free width sits beside an ellipsis', (tester) async {
        await _pumpAt(
            tester,
            width,
            _render(
              itemsLabel: 'Total items',
              itemsValue: '4',
              advanceLabel: 'Advance to pay',
              advance: '₹252.79',
            ));
        expect(tester.getRect(find.text('Total items')).left,
            moreOrLessEquals(_pagePad, epsilon: 0.5));
        expect(tester.getRect(find.text('₹252.79')).right,
            moreOrLessEquals(right, epsilon: 0.5));
      });

      testWidgets('short labels stay justified, not packed left',
          (tester) async {
        await _pumpAt(
            tester,
            width,
            _render(
              itemsLabel: 'Tot',
              itemsValue: '4',
              advanceLabel: 'Adv',
              advance: '₹9',
            ));
        expect(tester.getRect(find.text('Tot')).left,
            moreOrLessEquals(_pagePad, epsilon: 0.5));
        expect(tester.getRect(find.text('₹9')).right,
            moreOrLessEquals(right, epsilon: 0.5));
      });

      testWidgets('the advance half is the wider one', (tester) async {
        await _pumpAt(
            tester,
            width,
            _render(
              itemsLabel: 'Total items',
              itemsValue: '4',
              advanceLabel: 'Advance to pay',
              advance: '₹252.79',
            ));
        final itemsHalf = tester.getRect(find.text('4')).right -
            tester.getRect(find.text('Total items')).left;
        final advanceHalf = tester.getRect(find.text('₹252.79')).right -
            tester.getRect(find.text('Advance to pay')).left;
        expect(advanceHalf, greaterThan(itemsHalf));
      });
    });
  }

  testWidgets('CMD #2024 — no Spacer lives in the summary row',
      (tester) async {
    await _pumpAt(
        tester,
        360,
        _render(
          itemsLabel: 'Total items',
          itemsValue: '4',
          advanceLabel: 'Advance to pay',
          advance: '₹252.79',
        ));
    expect(find.byType(Spacer), findsNothing);
  });
}
