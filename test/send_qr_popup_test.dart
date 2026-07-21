// Regression test for CHANGE #488 — the customer pay popup's "Send QR to"
// mini popup must be anchored to the WhatsApp button via
// CompositedTransformTarget/Follower + LayerLink, directly above the
// button — not a centered dialog. (Earlier attempts anchored it with a
// manually-computed Offset from the button's RenderBox, which broke down
// to look screen-centred wherever that math's Overlay-coordinate-origin
// assumption didn't hold — LayerLink tracks the target's real transform
// layer directly, so it can't drift like that.)
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/widgets/cust_pay_panel.dart';

void main() {
  testWidgets(
      'Send QR to popup is anchored to the WhatsApp button via LayerLink, not a centered dialog',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CustPaySheet(
          qrData: 'upi://pay?pa=test@upi&pn=Test&am=264.5&cu=INR',
          vpa: 'test@upi',
          bankingName: 'Test Banking',
          payLabel: 'Pay Advance',
          orderId: 'order-1',
          amount: 264.50,
          kind: 'advance',
          fetchWaNumbers: (orderId) async => {'numbers': []},
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // The LayerLink the WhatsApp button is registered under.
    final targetFinder = find.ancestor(
      of: find.text('WhatsApp'),
      matching: find.byType(CompositedTransformTarget),
    );
    expect(targetFinder, findsOneWidget,
        reason: 'the WhatsApp button must be wrapped in a CompositedTransformTarget');
    final targetLink = (tester.widget(targetFinder) as CompositedTransformTarget).link;

    await tester.tap(find.text('WhatsApp'));
    await tester.pumpAndSettle();

    // Not a centered dialog: no Dialog/Center ancestor for the popup.
    final popupFinder = find.byKey(const Key('payQrWaPopupAnchor'));
    expect(popupFinder, findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    expect(
      find.ancestor(of: popupFinder, matching: find.byType(Center)),
      findsNothing,
    );

    // It IS a CompositedTransformFollower tied to that exact button's link —
    // an anchor that tracks the button wherever it is, not a fixed position.
    final followerFinder = find.byType(CompositedTransformFollower);
    expect(followerFinder, findsOneWidget);
    final follower = tester.widget(followerFinder) as CompositedTransformFollower;
    expect(follower.link, same(targetLink));

    // "Directly above the button": the follower's own bottom sits at the
    // target's top (its followerAnchor/targetAnchor pairing), not below or
    // beside it.
    expect(follower.followerAnchor, Alignment.bottomLeft);
    expect(follower.targetAnchor, Alignment.topLeft);
    expect(follower.offset.dy, lessThan(0)); // gap sits above, not below

    await tester.pump(const Duration(milliseconds: 900));
  });
}
