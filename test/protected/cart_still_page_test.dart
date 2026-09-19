// PROTECTED — CMD #2099 (the cart page holds still, and the bill sits on the
// page's own gutter).
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes one of the two contracts below.
//
// 1. THE COMPENSATION IS THE BLOCK ABOVE THE RAILS, NEVER THE MAX EXTENT.
//    CMD #2090 moved the page by the change in maxScrollExtent. That number
//    moves for three reasons that are not a cart row: a bill line appearing
//    BELOW the rails, a banner appearing above the scroll (the viewport
//    shrinks), and a rail payload landing a frame after the row did. An ADD
//    on the wishlist rail does two of those in two separate layouts, which is
//    why the wishlist title travelled ~35px — one bill line — while an ADD on
//    "You may also like" looked still. The correction is now the measured
//    height of the block the rails sit under, so growth anywhere else is
//    worth exactly zero pixels of page movement.
//
// 2. THE BILL CARD SHARES THE PAGE GUTTER. Its left and right margins are the
//    16px the cart rows and the Place order button already use — measured off
//    the laid-out card, not read back off the constant that set it.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/cart_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/cart_bill_summary.dart';

/// The page's own gutter: what the cart rows and the Place order bar use.
const double _pageGutter = 16.0;

Map<String, dynamic> _bill() => {
      'has': true,
      'title': 'Order summary',
      'rows': [
        {'label': 'Total items', 'value': '4', 'tone': 'normal'},
        {'label': 'Amount to pay', 'value': '₹252.79', 'tone': 'total'},
      ],
    };

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('1 — the correction answers "how far did the rails move?"', () {
    test('a row landing above the rails is compensated to the pixel', () {
      expect(
        C2090ScrollComp.shift(
            oldAbove: 512, newAbove: 600, isScrolling: false, velocity: 0),
        88,
      );
      expect(
        C2090ScrollComp.shift(
            oldAbove: 600, newAbove: 512, isScrolling: false, velocity: 0),
        -88,
      );
    });

    test('a bill line below the rails is worth zero pixels', () {
      // The ~35px a bill row is. The block above did not move, so neither
      // does the page — this is the wishlist jump, asserted directly.
      expect(
        C2090ScrollComp.shift(
            oldAbove: 512, newAbove: 512, isScrolling: false, velocity: 0),
        0,
      );
    });

    test('a rail whose payload arrives a frame later moves nothing', () {
      // The rails reserve a constant extent, so a rail swapping its cards
      // changes no height at all — and the block above is untouched.
      expect(
        C2090ScrollComp.shift(
            oldAbove: 512, newAbove: 512.4, isScrolling: false, velocity: 0),
        0,
      );
    });

    test('the anchor starts unmeasured and never invents a first jump', () {
      final a = C2090Anchor();
      expect(a.above, isNull);
      expect(a.pending, 0);
      // The first layout has nothing to compare against, so it banks nothing.
      expect(
        C2090ScrollComp.shift(
            oldAbove: a.above, newAbove: 512, isScrolling: false, velocity: 0),
        0,
      );
    });

    test('two growths inside one frame are spent once, together', () {
      // The probe banks each measured delta; the physics spends the sum in
      // the layout that produced it.
      final a = C2090Anchor();
      a.pending += C2090ScrollComp.shift(
          oldAbove: 512, newAbove: 600, isScrolling: false, velocity: 0);
      a.pending += C2090ScrollComp.shift(
          oldAbove: 600, newAbove: 644, isScrolling: false, velocity: 0);
      expect(a.pending, 132);
    });

    test('the physics carries its anchor through composition', () {
      final a = C2090Anchor();
      final p = C2090StillPhysics(parent: const ClampingScrollPhysics(),
          anchor: a);
      final composed = p.applyTo(const BouncingScrollPhysics());
      expect(composed, isA<C2090StillPhysics>());
      expect(composed.anchor, same(a));
    });
  });

  group('2 — the bill card sits on the page gutter', () {
    testWidgets('left and right margins are the page gutter, at 360 and 412',
        (tester) async {
      for (final width in <double>[360, 412]) {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CartBillSummary.fromPayload(_bill())!,
            ),
          ),
        ));
        await tester.pump();

        // The painted card box — the Container's decoration, INSIDE the
        // margin. The Container element itself carries the margin, so it is
        // the decorated box that says where the card's edge actually is.
        final box = tester.getRect(find
            .descendant(
                of: find.byType(CartBillSummary),
                matching: find.byType(DecoratedBox))
            .first);
        expect(box.left, _pageGutter, reason: 'left gutter at ${width}px');
        expect(width - box.right, _pageGutter,
            reason: 'right gutter at ${width}px');
      }
    });
  });
}
