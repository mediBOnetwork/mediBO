// PROTECTED — CHANGE #691 (register rows 122 + 126).
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes the arrival window or the proof-of-delivery block.
//
// The two things this holds down, on the widgets every delivery surface shares
// (customer track sheet, public /track page, Orders card, order detail, ops
// board timeline, invoice card):
//
//   1. THE ARRIVAL WINDOW IS A BACKEND STRING. Row 122's bug was an ETA that
//      was stamped once and never rebased; the fix put the rebase in the
//      backend, and the risk it creates is a client that "helpfully" recomputes
//      the countdown from eta_at. So the fixture deliberately carries an eta_at
//      that DISAGREES with the label and the countdown: the card must print the
//      label and the countdown, never a figure derived from the timestamp.
//
//   2. ABSENCE IS `has:false`, NOT AN EMPTY STRING. A delivery that has not
//      started and an order that was never delivered render NOTHING — no empty
//      "Proof of delivery" heading, no "ETA unavailable" sentence this build
//      invented, no dash where a receiver's name would go. Every caption on the
//      proof block is the payload's, including the method label: `method_key`
//      is carried for the render-log only and must never be title-cased into a
//      label on this side of the wire.
//
// No network, no Supabase, no goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/delivery_proof_card.dart';
import 'package:pharma_b2b/widgets/order_card_lean.dart';

Map<String, dynamic> _eta({bool has = true}) => {
      'has': has,
      'state': has ? 'eta' : 'none',
      'heading': 'Expected arrival',
      // Deliberately NOT derivable from eta_at below.
      'label': 'Arriving 4:10–4:30 pm',
      'window_label': '4:10–4:30 pm',
      'countdown_label': 'in about 25 min',
      // Two years in the past: any client-side countdown would print a negative
      // or an "arriving now", and this fixture would catch it.
      'eta_at': '2024-01-01T00:00:00+00:00',
      'eta_min': 25,
      'stops_ahead': 2,
      'stops_ahead_label': '2 stops before you',
      'note': 'Updated as the rider moves',
    };

Map<String, dynamic> _proof({
  bool has = true,
  bool hasReceiver = true,
  bool hasTime = true,
  bool hasPhoto = false,
  bool hasMap = true,
}) =>
    {
      'has': has,
      'heading': 'Proof of delivery',
      'method_key': 'otp',
      'method_label': 'OTP verified at the door',
      'method_caption': 'Confirmed by',
      'has_receiver': hasReceiver,
      'receiver_caption': 'Received by',
      'receiver_name': hasReceiver ? 'Sunita Verma' : '',
      'has_time': hasTime,
      'time_caption': 'Handed over at',
      'time_label': hasTime ? '03 Sep 2026, 04:18 PM' : '',
      'photo': hasPhoto
          ? {
              'has': true,
              'bucket': 'delivery-proofs',
              'path': 'a/b.jpg',
              'label': 'Delivery photo',
            }
          : {'has': false},
      'signature': {'has': false},
      'map': hasMap
          ? {
              'has': true,
              'lat': 21.25,
              'lng': 81.63,
              'label': 'Delivered at this location',
              'url': 'https://maps.example/?q=21.25,81.63',
            }
          : {'has': false},
    };

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: SingleChildScrollView(child: child)),
  ));
  await tester.pump();
}

void main() {
  setUpAll(() {
    // RenderLog's 800 ms debounce is a real Timer that would outlive the test.
    RenderLog.flushEnabled = false;
  });

  group('arrival window (register row 122)', () {
    testWidgets('prints the backend sentence, not a countdown it computed',
        (tester) async {
      await _pump(tester, DeliveryEtaCard(eta: _eta()));

      expect(find.text('Expected arrival'), findsOneWidget);
      expect(find.text('Arriving 4:10–4:30 pm'), findsOneWidget);
      expect(find.text('in about 25 min'), findsOneWidget);
      expect(find.text('2 stops before you'), findsOneWidget);
      expect(find.text('Updated as the rider moves'), findsOneWidget);
    });

    testWidgets('has:false with no label renders nothing at all',
        (tester) async {
      await _pump(
          tester,
          DeliveryEtaCard(eta: const {
            'has': false,
            'state': 'none',
            'heading': 'Expected arrival',
            'label': '',
          }));

      expect(find.text('Expected arrival'), findsNothing);
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('has:false WITH a state sentence prints that sentence',
        (tester) async {
      // "Delivered", or "Arrival time updates once the rider starts" — the
      // backend's own wording for a window it cannot give yet.
      await _pump(
          tester,
          DeliveryEtaCard(eta: const {
            'has': false,
            'state': 'unknown',
            'heading': 'Expected arrival',
            'label': 'Arrival time updates once the rider starts',
            'countdown_label': '',
            'stops_ahead_label': 'You are next',
          }));

      expect(find.text('Arrival time updates once the rider starts'),
          findsOneWidget);
      expect(find.text('You are next'), findsOneWidget);
    });

    testWidgets('the compact line appears only when has:true', (tester) async {
      await _pump(tester, DeliveryEtaLine(eta: _eta(has: false)));
      expect(find.byType(Text), findsNothing);

      await _pump(tester, DeliveryEtaLine(eta: _eta()));
      expect(find.text('Arriving 4:10–4:30 pm'), findsOneWidget);
    });
  });

  group('proof of delivery (register row 126)', () {
    testWidgets('prints receiver, time and method verbatim', (tester) async {
      await _pump(tester, DeliveryProofCard(proof: _proof()));

      expect(find.text('Proof of delivery'), findsOneWidget);
      expect(find.text('Received by'), findsOneWidget);
      expect(find.text('Sunita Verma'), findsOneWidget);
      expect(find.text('Handed over at'), findsOneWidget);
      expect(find.text('03 Sep 2026, 04:18 PM'), findsOneWidget);
      expect(find.text('Confirmed by'), findsOneWidget);
      // The LABEL, never the key title-cased.
      expect(find.text('OTP verified at the door'), findsOneWidget);
      expect(find.text('Otp'), findsNothing);
      expect(find.text('Delivered at this location'), findsOneWidget);
    });

    testWidgets('an undelivered order renders nothing', (tester) async {
      await _pump(
          tester,
          DeliveryProofCard(
              proof: const {'has': false, 'heading': 'Proof of delivery'}));

      expect(find.text('Proof of delivery'), findsNothing);
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('an absent receiver omits the row rather than printing a dash',
        (tester) async {
      await _pump(tester, DeliveryProofCard(proof: _proof(hasReceiver: false)));

      expect(find.text('Received by'), findsNothing);
      expect(find.text('-'), findsNothing);
      // ...and the rows the payload DID send are still there.
      expect(find.text('OTP verified at the door'), findsOneWidget);
    });

    testWidgets('no map pin without map.has', (tester) async {
      await _pump(tester, DeliveryProofCard(proof: _proof(hasMap: false)));
      expect(find.text('Delivered at this location'), findsNothing);
    });

    testWidgets('showHeading:false drops only the heading', (tester) async {
      await _pump(
          tester, DeliveryProofCard(proof: _proof(), showHeading: false));
      expect(find.text('Proof of delivery'), findsNothing);
      expect(find.text('Sunita Verma'), findsOneWidget);
    });
  });

  group('the Orders card carries the window', () {
    Map<String, dynamic> row(Map<String, dynamic>? eta) => {
          'id': 'o1',
          'order_code': 'CPO020826CHAO1',
          'date_label': '02 Aug 2026, 02:30 PM',
          'item_count_label': '8 items',
          'amount_label': '₹12,447.71',
          'amount_is_money': true,
          'stage_key': 'out_for_delivery',
          'stage_label': 'Out for delivery',
          'progress': {'show': false, 'index': 3, 'steps': []},
          'primary_action': {'key': 'track', 'label': 'Track', 'tone': 'brand'},
          'situation': 'active',
          'placed_by_admin': false,
          'placed_by_admin_label': '',
          if (eta != null) 'eta': eta,
        };

    testWidgets('shows the window under the stage when the payload sent one',
        (tester) async {
      await _pump(
        tester,
        OrderCardLean(
          card: CustomerOrderCard.fromPayload(row(_eta())),
          onOpen: () {},
          onAction: (_) {},
        ),
      );

      expect(find.text('Out for delivery'), findsOneWidget);
      expect(find.text('Arriving 4:10–4:30 pm'), findsOneWidget);
    });

    testWidgets('an order with no eta block draws no window', (tester) async {
      await _pump(
        tester,
        OrderCardLean(
          card: CustomerOrderCard.fromPayload(row(null)),
          onOpen: () {},
          onAction: (_) {},
        ),
      );

      expect(find.text('Out for delivery'), findsOneWidget);
      expect(find.textContaining('Arriving'), findsNothing);
    });
  });
}
