// CHANGE #461 — the customer MEDIUM batch B defects (feature_gaps 166-170),
// held down so they cannot come back.
//
// What each group pins, in the words of the audit that found it:
//  * #167 the cart's delivery ladder is the payload's. The amount, the GST,
//    the grand total and the free-delivery nudge are backend strings; a
//    payload with no delivery block draws no delivery rows at all.
//  * #170 the Rx class is the backend's badge, on the card and the PDP. No
//    schedule is inferred, no colour is chosen here, and a pack with no class
//    on record shows nothing rather than a locally-invented "OTC".
//  * #168 the tier benefit note is NOT a cart notice (CHANGE #572). The cart
//    draws exactly one notice, `render.notice`, and the tier promise is not
//    it — on an unpriced basket it read as a defect.
//
// Pure widget tests: mocked payloads inline, no network, no Supabase.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/models/product.dart';
import 'package:pharma_b2b/models/product_detail.dart';
import 'package:pharma_b2b/screens/cart_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Future<void> _pump(WidgetTester t, Widget child) => t.pumpWidget(
      MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child))),
    );

// CHANGE #572 — the ladder is no longer assembled here. `summary.rows` IS the
// ladder: which rows exist, in which order, with which amounts, is the
// backend's answer. Delivery survives an unpriced basket because the payload
// keeps sending it; Net payable and Total payable do not, because it does not.
Map<String, dynamic> _renderWithDelivery({
  required bool waived,
  required bool hasGst,
}) =>
    {
      'summary': {
        'line': '8 items',
        'has_amount': true,
        'amount_display': '₹1,200.00',
        'delivery_note': waived
            ? 'Free delivery on this order'
            : 'Add ₹3,800.00 more for free delivery',
        'rows': [
          {'key': 'net', 'label': 'Net payable', 'amount': '₹1,200.00', 'strong': false},
          {
            'key': 'delivery',
            'label': 'Delivery',
            'amount': waived ? 'FREE' : '₹60.00',
            'strong': false
          },
          if (hasGst)
            {
              'key': 'delivery_gst',
              'label': 'GST on delivery',
              'amount': '₹10.80',
              'strong': false
            },
          {
            'key': 'grand',
            'label': 'Total payable',
            'amount': waived ? '₹1,200.00' : '₹1,270.80',
            'strong': true
          },
        ],
      },
    };

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('#167/#572 — the cart totals ladder is printed, never computed', () {
    testWidgets('a charged delivery prints amount, GST, grand total and nudge',
        (t) async {
      await _pump(
          t, C572TotalsBlock(render: _renderWithDelivery(waived: false, hasGst: true)));

      expect(find.text('Delivery'), findsOneWidget);
      expect(find.text('₹60.00'), findsOneWidget);
      expect(find.text('GST on delivery'), findsOneWidget);
      expect(find.text('₹10.80'), findsOneWidget);
      // The grand total is the backend's string under the backend's label.
      expect(find.text('Total payable'), findsOneWidget);
      expect(find.text('₹1,270.80'), findsOneWidget);
      expect(find.text('Add ₹3,800.00 more for free delivery'), findsOneWidget);
    });

    testWidgets('a waived delivery prints the backend FREE, not a ₹0.00',
        (t) async {
      await _pump(
          t, C572TotalsBlock(render: _renderWithDelivery(waived: true, hasGst: false)));

      expect(find.text('FREE'), findsOneWidget);
      expect(find.text('Free delivery on this order'), findsOneWidget);
      // No GST row when the payload says there is no GST to show.
      expect(find.text('GST on delivery'), findsNothing);
    });

    testWidgets('no summary block in the payload draws no totals at all',
        (t) async {
      await _pump(t, const C572TotalsBlock(render: {}));
      expect(find.text('Delivery'), findsNothing);
      expect(find.byType(Text), findsNothing);
    });
  });

  group('#170/#572 — the cart shows ONE notice, in the backend\'s words', () {
    testWidgets('an Rx basket with no licence shows the backend title+message',
        (t) async {
      await _pump(t, const C572CartNotice(render: {
        'notice': {
          'has': true,
          'blocking': false,
          'kind': 'drug_licence',
          'title': 'Drug licence needed',
          'message': 'Add your 20B/21B drug licence to your profile to order '
              'prescription medicines. 2 items in your cart need it.',
          'tone': {'bg': '#FEF3C7', 'fg': '#92400E'},
          'action': {'has': false},
        },
      }));

      expect(find.text('Drug licence needed'), findsOneWidget);
      expect(
          find.textContaining('2 items in your cart need it.'), findsOneWidget);
    });

    testWidgets('a licensed Rx basket shows only the record line', (t) async {
      await _pump(t, const C572CartNotice(render: {
        'notice': {
          'has': false,
          'note': '1 prescription item in this order',
          'action': {'has': false},
        },
      }));

      // The plural is the backend's: "item", not "item(s)" decided here.
      expect(find.text('1 prescription item in this order'), findsOneWidget);
      expect(find.text('Drug licence needed'), findsNothing);
    });

    testWidgets('the tier benefit note is no longer a cart notice', (t) async {
      // #572 — "Nothing in the catalogue is trade-priced for you yet" read as
      // a defect on a basket that is simply awaiting quotes. render.notice is
      // the ONLY notice the cart draws, so a rewards block in the payload
      // reaches the screen and is not printed.
      await _pump(t, const C572CartNotice(render: {
        'rewards': {
          'has': true,
          'tier_label': 'Platinum',
          'benefit_applies': false,
          'note': 'This benefit applies once your order has trade-priced items.',
          'tone': {'bg': '#FEF3C7', 'fg': '#92400E'},
        },
      }));
      expect(find.text('Platinum'), findsNothing);
      expect(
          find.textContaining('once your order has trade-priced items'),
          findsNothing);
    });
  });

  group('#170 — the Rx class comes from the payload, never from Dart', () {
    test('a card carries the backend badge and never invents OTC', () {
      final rx = Product.fromHomeCard(const {
        'id': 1,
        'name': 'Dolo-T Tablet',
        'rx': {
          'has': true,
          'is_rx': true,
          'label': 'Rx',
          'title': 'Prescription medicine',
          'tone': {'bg': '#FEE2E2', 'fg': '#991B1B'},
        },
      });
      expect(rx.hasRxBadge, isTrue);
      expect(rx.isRx, isTrue);
      expect(rx.rxLabel, 'Rx');
      expect(rx.rxTone?['bg'], '#FEE2E2');
      // The old code hardcoded schedule:'OTC' on every card.
      expect(rx.schedule, 'Rx');

      final none = Product.fromHomeCard(const {'id': 2, 'name': 'No class'});
      expect(none.hasRxBadge, isFalse);
      expect(none.isRx, isFalse);
      expect(none.schedule, '');
    });

    test('the PDP carries the rx block and the licence line verbatim', () {
      final d = ProductDetail.fromMap(const {
        'ok': true,
        'id': '176026',
        'header': {'name': 'Megval', 'rx_required': true},
        'rx': {
          'has': true,
          'is_rx': true,
          'label': 'Rx',
          'title': 'Prescription medicine',
          'note': 'Schedule H / H1 stock.',
          'tone': {'bg': '#FEE2E2', 'fg': '#991B1B'},
        },
        'rx_licence': {'has': true, 'ok_note': 'Licence 20B-CG-RPR-1 on file'},
      });

      expect(d.hasRxBlock, isTrue);
      expect(d.rxTitle, 'Prescription medicine');
      expect(d.rxNote, 'Schedule H / H1 stock.');
      expect(d.rxLicenceNote, 'Licence 20B-CG-RPR-1 on file');
      // header.rx_required was false on EVERY product before #461.
      expect(d.rxRequired, isTrue);

      final plain = ProductDetail.fromMap(const {
        'ok': true,
        'id': '2',
        'header': {'name': 'OTC pack', 'rx_required': false},
      });
      expect(plain.hasRxBlock, isFalse);
      expect(plain.rxLabel, '');
    });
  });
}
