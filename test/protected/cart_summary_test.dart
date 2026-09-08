// CHANGE #572 — the cart's four repetitions, held down so they cannot return.
//
// The customer cart printed "Awaiting supplier rates" FOUR times (the summary
// line, the big amount, the Net payable row and the Total payable row), put a
// bold ₹260.38 directly above "2 items not priced yet", stacked two amber
// notices and offered "Pay & Place Order" on a basket where nothing was owed.
//
// What this file pins:
//  * ONE PRICE TRUTH PER LINE — an unpriced line sends an EMPTY `price_line`,
//    so there is never a rupee figure above the words that say the rate is not
//    known; its MRP lives inside `price_note` instead.
//  * ONE SUMMARY — `summary.rows` IS the ladder. While no amount exists it
//    carries Delivery and nothing else; Net payable and Total payable are
//    absent, not blank. When an amount exists they come back with real money.
//  * ONE NOTICE — `render.notice`, with its own inline action. A rewards block
//    in the payload is NOT drawn by the cart.
//  * AN HONEST CTA — the label and the enabled state are `render.cta`'s, and
//    an absent `enabled` is absence, not a disabled button.
//
// Pure widget tests: mocked payloads inline, no network, no Supabase.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/models/cart_model.dart';
import 'package:pharma_b2b/models/product.dart';
import 'package:pharma_b2b/screens/cart_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Future<void> _pump(WidgetTester t, Widget child) => t.pumpWidget(
      MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child))),
    );

/// The live Chandra Medicom basket that the audit screenshotted: two lines,
/// neither of them quoted yet.
const Map<String, dynamic> _unpriced = {
  'summary': {
    'line': '2 items · rate confirmed after supplier quote',
    'has_amount': false,
    'amount_display': '',
    'delivery_note': '',
    'priced_count': 0,
    'unpriced_count': 2,
    'rows': [
      {'key': 'delivery', 'label': 'Delivery', 'amount': 'FREE', 'strong': false},
    ],
  },
  'notice': {
    'has': true,
    'blocking': false,
    'kind': 'drug_licence',
    'title': 'Drug licence needed',
    'message': 'Add your 20B/21B drug licence to your profile to order '
        'prescription medicines. 2 items in your cart need it.',
    'tone': {'bg': '#FEF3C7', 'fg': '#92400E'},
    'action': {
      'has': true,
      'label': 'Add licence',
      'kind': 'profile_edit',
      'field': 'dl_20b',
      'section': 'licence',
    },
  },
  // Still in the payload — and still not drawn by the cart.
  'rewards': {
    'has': true,
    'tier_label': 'Platinum',
    'note': 'Nothing in the catalogue is trade-priced for you yet.',
  },
  'cta': {'label': 'Place order', 'payable': false, 'pay_now': false, 'enabled': true},
};

/// The same basket once a supplier has quoted one of the lines.
const Map<String, dynamic> _priced = {
  'summary': {
    'line': '3 items · 2 awaiting supplier quote',
    'has_amount': true,
    'amount_display': '₹206.08',
    'delivery_note': '',
    'priced_count': 1,
    'unpriced_count': 2,
    'rows': [
      {'key': 'net', 'label': 'Net payable', 'amount': '₹206.08', 'strong': false},
      {'key': 'delivery', 'label': 'Delivery', 'amount': 'FREE', 'strong': false},
      {'key': 'grand', 'label': 'Total payable', 'amount': '₹206.08', 'strong': true},
    ],
  },
  'notice': {'has': false, 'note': '', 'action': {'has': false}},
  'cta': {'label': 'Pay & place order', 'payable': true, 'pay_now': true, 'enabled': true},
};

CartLine _line(Map<String, dynamic> display) => CartLine(
      Product.fromHomeCard(const {'id': 334552, 'name': 'Test pack'}),
      1,
      display: display,
    );

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('one price truth per line', () {
    test('an unpriced line carries no amount, only the MRP-in-caption note', () {
      final line = _line(const {
        'has_trade_rate': false,
        'price_line': '',
        'price_note': 'MRP ₹260.38 · trade rate on confirmation',
      });
      // The screen prints price_line ONLY when it is non-empty, so an empty
      // one is the backend saying "no number above this note".
      expect(line.ds('price_line'), '');
      expect(line.ds('price_note'), 'MRP ₹260.38 · trade rate on confirmation');
    });

    test('a quoted line carries the trade line total, never the MRP', () {
      final line = _line(const {
        'has_trade_rate': true,
        'mrp_display': '₹120.00',
        'price_line': '₹206.08',
        'price_note': '2 × ₹92.00',
      });
      expect(line.ds('price_line'), '₹206.08');
      expect(line.ds('price_note'), '2 × ₹92.00');
    });
  });

  group('one summary line, and a ladder only when there is money', () {
    testWidgets('an unpriced basket shows the line, no amount, Delivery FREE',
        (t) async {
      await _pump(t, const C572TotalsBlock(render: _unpriced));

      expect(find.text('2 items · rate confirmed after supplier quote'),
          findsOneWidget);
      // Delivery survives — it is the only true number on this screen.
      expect(find.text('Delivery'), findsOneWidget);
      expect(find.text('FREE'), findsOneWidget);
      // …and the two rows that used to repeat the same sentence do not.
      expect(find.text('Net payable'), findsNothing);
      expect(find.text('Total payable'), findsNothing);
      expect(find.textContaining('Awaiting supplier rates'), findsNothing);
    });

    testWidgets('a priced basket brings the real rows back', (t) async {
      await _pump(t, const C572TotalsBlock(render: _priced));

      expect(find.text('3 items · 2 awaiting supplier quote'), findsOneWidget);
      expect(find.text('Net payable'), findsOneWidget);
      expect(find.text('Total payable'), findsOneWidget);
      expect(find.text('Delivery'), findsOneWidget);
      // The amount is the payload's string, printed twice only because the
      // payload sent it twice (the headline and the grand row).
      expect(find.text('₹206.08'), findsNWidgets(3));
    });

    testWidgets('rows render in payload order, never re-sorted here', (t) async {
      await _pump(t, const C572TotalsBlock(render: _priced));
      final labels = t
          .widgetList<Text>(find.byType(Text))
          .map((w) => w.data ?? '')
          .where((s) => ['Net payable', 'Delivery', 'Total payable'].contains(s))
          .toList();
      expect(labels, ['Net payable', 'Delivery', 'Total payable']);
    });
  });

  group('one notice, and it is actionable', () {
    testWidgets('the licence notice prints verbatim and offers its action',
        (t) async {
      Map<String, dynamic>? fired;
      await _pump(
          t, C572CartNotice(render: _unpriced, onAction: (a) => fired = a));

      expect(find.text('Drug licence needed'), findsOneWidget);
      expect(find.textContaining('20B/21B'), findsOneWidget);
      expect(find.text('Add licence'), findsOneWidget);

      // The Platinum box that read like a defect is not on the cart at all,
      // even though the payload still carries it.
      expect(find.text('Platinum'), findsNothing);
      expect(find.textContaining('Nothing in the catalogue'), findsNothing);

      await t.tap(find.text('Add licence'));
      await t.pump();
      // The screen is handed the backend's own descriptor — it does not invent
      // a route from the notice's wording.
      expect(fired?['kind'], 'profile_edit');
      expect(fired?['field'], 'dl_20b');
    });

    testWidgets('no action in the payload means no button', (t) async {
      await _pump(t, C572CartNotice(render: const {
        'notice': {
          'has': true,
          'title': 'Drug licence needed',
          'message': 'Contact support.',
          'action': {'has': false, 'label': 'Add licence'},
        },
      }, onAction: (_) {}));
      expect(find.text('Drug licence needed'), findsOneWidget);
      expect(find.text('Add licence'), findsNothing);
    });

    testWidgets('a cleared gate leaves nothing behind', (t) async {
      await _pump(t, const C572CartNotice(render: _priced));
      expect(find.byType(Text), findsNothing);
    });
  });

  group('the CTA is honest about money', () {
    test('nothing payable reads "Place order"', () {
      expect(c572CtaLabel(_unpriced, 'Pay & Place Order'), 'Place order');
      expect(c572CtaEnabled(_unpriced), isTrue);
    });

    test('a payable basket reads "Pay & place order"', () {
      expect(c572CtaLabel(_priced, ''), 'Pay & place order');
    });

    test('an absent cta block falls back to checkout_action', () {
      expect(c572CtaLabel(const {}, 'Place Order'), 'Place Order');
      // Absent is NOT disabled — the other gates still decide.
      expect(c572CtaEnabled(const {}), isTrue);
    });

    test('the backend can disable the button by itself', () {
      expect(
          c572CtaEnabled(const {
            'cta': {'label': 'Place order', 'enabled': false},
          }),
          isFalse);
    });
  });
}
