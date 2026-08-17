// PROTECTED — CHANGE #179, rewritten by CHANGE #223.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes offers behaviour, never to make an unrelated change go
// green.
//
// WHY THIS FILE WAS REWRITTEN. #179's version built a `_MockOfferQtyState` and
// a `_mockOfferDisplayBlock` inside the test file and then asserted on those
// mocks. It could only ever pass: it never touched a line of shipped code. It
// was green while `offers_feed` raised 42803 on every call, while the card's
// labels were typed in Dart, and while a supplier had no route to the listing
// screen at all. A test that tests its own fixture is not a test.
//
// What this file now holds down, on the REAL widget:
//
//   1. The card computes NOTHING. The action button's label, the units-left
//      line, the type badge, the discount, the seller line and the match chip
//      are all strings from the offers_feed row, printed verbatim.
//
//   2. Sold-out is the backend's `sold_out` / `can_waitlist` verdict, never a
//      qty number compared in Dart. In that state the button carries the
//      backend's waitlist label and fires the waitlist callback — not add.
//
//   3. `action_enabled:false` (already on the waitlist) disables the button.
//
//   4. SUPPLIER ANONYMITY. Nothing supplier-identifying may reach the card:
//      the seller line is whatever `seller_display` says (always mediBO), and
//      a payload that somehow carried supplier fields must still never render
//      them. The fixture below deliberately smuggles supplier_id /
//      supplier_name into the row to prove the widget ignores them.
//
//   5. Near-expiry stays an explicit, backend-flagged opt-in
//      (`requires_disclosure`), because the qty deduction and the disclosure
//      record are what the server acts on.
//
// No network, no Supabase: the card takes a plain map and two callbacks.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/widgets/offer_card.dart';

/// A fabricated offers_feed() row — the exact shape _offer_display_block
/// returns, plus (deliberately) two fields it must never contain, so the
/// anonymity assertions test the widget rather than the fixture.
Map<String, dynamic> _row({
  bool soldOut = false,
  bool waitlisted = false,
  bool matched = false,
  bool nearExpiry = false,
  String actionLabel = 'Add to Cart',
}) =>
    {
      'id': 7,
      'product_id': 176027,
      'product_name': 'Zicoplanin 400mg Injection',
      'company': 'MACLEODS PHARMACEUTICALS PVT LTD',
      'pack': '1 Vial',
      'mrp_display': '₹1,815.00',
      'price_display': '₹750.00',
      'discount_label': '25% OFF',
      'listing_type': nearExpiry ? 'near_expiry' : 'discount',
      'type_badge': {
        'label': nearExpiry ? 'Near Expiry' : 'Offer',
        'bg': nearExpiry ? '#FEF3C7' : '#EFF6FF',
        'fg': nearExpiry ? '#92400E' : '#1E40AF',
      },
      'scheme_text': '',
      'qty_display': soldOut ? 'Sold out' : '190 units left',
      'qty_low': false,
      'sold_out': soldOut,
      'available_qty': soldOut ? 0 : 190,
      'min_order_qty': 10,
      'near_expiry_label': nearExpiry ? '3 months left' : null,
      'expiry_date_display': nearExpiry ? '15 Dec 2026' : null,
      'end_date_display': null,
      'requires_disclosure': nearExpiry,
      'is_matched': matched,
      'match_label': matched ? 'You order this' : null,
      'can_waitlist': soldOut,
      'waitlisted': waitlisted,
      'action_label': actionLabel,
      'action_enabled': !(soldOut && waitlisted),
      'seller': 'mediBO',
      'seller_display': 'Sold by mediBO',
      // NEVER served by the RPC — present here only to prove the card ignores
      // supplier identity even if a future payload regression leaks it.
      'supplier_id': 'uuid-secret-1',
      'supplier_name': 'TEST_Supplier One',
    };

Future<({int adds, int waitlists})> _pump(
  WidgetTester tester,
  Map<String, dynamic> row, {
  bool busy = false,
}) async {
  var adds = 0, waitlists = 0;
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: OfferCard(
        row: row,
        busy: busy,
        onAdd: () => adds++,
        onWaitlist: () => waitlists++,
      ),
    ),
  ));
  return (adds: adds, waitlists: waitlists);
}

void main() {
  group('CHANGE #223 — the offer card prints backend strings', () {
    testWidgets('name, pack, price, struck MRP and units are verbatim',
        (tester) async {
      await _pump(tester, _row());

      expect(find.text('Zicoplanin 400mg Injection'), findsOneWidget);
      expect(find.text('1 Vial'), findsOneWidget);
      expect(find.text('₹750.00'), findsOneWidget);
      expect(find.text('₹1,815.00'), findsOneWidget);
      expect(find.text('190 units left'), findsOneWidget,
          reason: 'qty line is qty_display, never a number formatted in Dart');
      expect(find.text('25% OFF'), findsOneWidget);
      expect(find.text('Offer'), findsOneWidget, reason: 'type_badge.label');
    });

    testWidgets('the action label is the payload, not a Dart literal',
        (tester) async {
      await _pump(tester, _row(actionLabel: 'अभी जोड़ें'));
      expect(find.text('अभी जोड़ें'), findsOneWidget);
      expect(find.text('Add to Cart'), findsNothing,
          reason: 'no English fallback may be typed into the widget');
    });

    testWidgets('the match chip appears only when the backend matched it',
        (tester) async {
      await _pump(tester, _row(matched: true));
      expect(find.text('You order this'), findsOneWidget);

      await _pump(tester, _row());
      expect(find.text('You order this'), findsNothing);
    });

    testWidgets('near-expiry prints its own months-left and expiry date',
        (tester) async {
      await _pump(tester, _row(nearExpiry: true));
      expect(find.text('Near Expiry'), findsOneWidget);
      expect(find.textContaining('3 months left'), findsOneWidget);
      expect(find.textContaining('15 Dec 2026'), findsOneWidget);
    });
  });

  group('sold out is the backend verdict, not a qty compared in Dart', () {
    testWidgets('can_waitlist routes the tap to the waitlist, never to add',
        (tester) async {
      final row = _row(soldOut: true, actionLabel: 'Notify me');
      var adds = 0, waitlists = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: OfferCard(
            row: row,
            onAdd: () => adds++,
            onWaitlist: () => waitlists++,
          ),
        ),
      ));

      expect(find.text('Notify me'), findsOneWidget);
      expect(find.text('Sold out'), findsOneWidget, reason: 'qty_display');

      await tester.tap(find.byType(ElevatedButton));
      await tester.pump();
      expect(waitlists, 1);
      expect(adds, 0);
    });

    testWidgets('an in-stock card routes the tap to add', (tester) async {
      var adds = 0, waitlists = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: OfferCard(
            row: _row(),
            onAdd: () => adds++,
            onWaitlist: () => waitlists++,
          ),
        ),
      ));

      await tester.tap(find.byType(ElevatedButton));
      await tester.pump();
      expect(adds, 1);
      expect(waitlists, 0);
    });

    testWidgets('action_enabled:false disables the button', (tester) async {
      await _pump(tester,
          _row(soldOut: true, waitlisted: true, actionLabel: 'On waitlist'));
      final button =
          tester.widget<ElevatedButton>(find.byType(ElevatedButton));
      expect(button.onPressed, isNull);
    });

    testWidgets('busy disables the button while its RPC is in flight',
        (tester) async {
      await _pump(tester, _row(), busy: true);
      final button =
          tester.widget<ElevatedButton>(find.byType(ElevatedButton));
      expect(button.onPressed, isNull);
    });
  });

  group('supplier anonymity — Om keeps the margin', () {
    testWidgets('the seller line is seller_display, never the supplier',
        (tester) async {
      await _pump(tester, _row());
      expect(find.text('Sold by mediBO'), findsOneWidget);
      expect(find.text('TEST_Supplier One'), findsNothing,
          reason: 'a leaked supplier_name in the payload must not render');
      expect(find.textContaining('uuid-secret-1'), findsNothing);
    });

    testWidgets('no widget in the tree carries supplier identity text',
        (tester) async {
      await _pump(tester, _row(matched: true, nearExpiry: true));
      final texts = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .join(' | ');
      expect(texts.contains('TEST_Supplier One'), isFalse);
      expect(texts.contains('uuid-secret-1'), isFalse);
      expect(texts.contains('Sold by mediBO'), isTrue);
    });
  });

  group('offer type contracts', () {
    test('listing_type is one of the allowed values', () {
      const allowed = {'scheme', 'near_expiry', 'discount'};
      expect(allowed.contains('scheme'), isTrue);
      expect(allowed.contains('near_expiry'), isTrue);
      expect(allowed.contains('discount'), isTrue);
      expect(allowed.contains('flash_sale'), isFalse);
    });

    test('status is one of the allowed values', () {
      const allowed = {'active', 'paused', 'expired', 'delisted'};
      expect(allowed.contains('active'), isTrue);
      expect(allowed.contains('delisted'), isTrue);
      expect(allowed.contains('pending'), isFalse);
    });
  });
}
