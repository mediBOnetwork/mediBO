// PROTECTED — CHANGE #703 (geofence arrival flow).
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes the doorbell, the cold-chain strip or the rider nudge.
//
// What this holds down, on the three widgets every delivery surface shares:
//
//   1. THE RINGS ARE THE BACKEND'S. Before #703 the geofence had one radius and
//      the app learned about the rider only when arrived_at appeared. The fix
//      put two rings server-side, and the risk it creates is a client that
//      starts comparing rider_lat/lng against destination_lat/lng to decide
//      "close enough". So `state` is the ONLY thing that selects the card, and
//      an `enroute` payload — which still carries a full destination — must
//      render nothing at all.
//
//   2. THE WAITING TIME IS A SENTENCE, NOT A CLOCK. `waiting_label` and
//      `dwell_started_at` deliberately DISAGREE in the fixture, exactly as
//      #691's eta fixture does, so a widget that recomputes minutes from the
//      timestamp fails here rather than in front of a customer.
//
//   3. THE RIDER NEVER GETS THE BUYER'S OTP. CHANGE #354 CHECK-constrained
//      deliveries.otp_code to NULL because the assigned rider can read that
//      row, and customer_track_order admits the rider too. The backend answers
//      with `has_otp:false` for that caller; this widget must print no OTP and
//      no empty OTP row — while still showing the QR, which the rider must
//      scan and is theirs to see.
//
//   4. COLD CHAIN AND THE NUDGE COMPUTE NOTHING. The strip's colour comes from
//      the payload's own `tone`, never from comparing elapsed_min to
//      window_min (both of which it also receives, precisely so a regression
//      that starts using them is visible). The nudge prints the backend's
//      rider-facing sentence and renders in payload order.
//
// No network, no Supabase, no goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/delivery_arrival_card.dart';

Map<String, dynamic> _handover({bool otp = true, String token = 'QR-TOKEN-1'}) => {
      'has': true,
      'qr_label': 'Handover QR',
      'qr_token': token,
      'has_otp': otp,
      'otp_label': 'Handover OTP',
      'otp_hint': 'Read this out to the rider',
      'otp': otp ? '4321' : null,
    };

Map<String, dynamic> _arrival({
  String state = 'here',
  bool otp = true,
  String waiting = 'Waiting 4 minutes',
}) =>
    {
      'has': state != 'enroute',
      'state': state,
      'chip': state == 'here' ? 'At your door' : 'Arriving',
      'heading': state == 'here' ? 'Rider is here' : 'Rider is close',
      'body': state == 'here'
          ? 'Ramesh is at your door. Show the QR code or read out the OTP.'
          : 'Ramesh is about 3 minutes away. Keep the QR or OTP ready.',
      'partner_name': 'Ramesh',
      'waiting_label': state == 'here' ? waiting : '',
      'waiting_min': 4,
      // Deliberately disagrees with waiting_label: a widget that subtracts
      // this from "now" would print something else entirely.
      'dwell_started_at': '2020-01-01T00:00:00Z',
      'handover': _handover(otp: otp),
      'tone': state == 'here' ? 'success' : 'info',
    };

Map<String, dynamic> _cold({
  bool breach = false,
  String tone = 'info',
}) =>
    {
      'has': true,
      'is_cold_chain': true,
      'started': true,
      'heading': 'Cold chain',
      'elapsed_label': '40 minutes out of the cold box',
      'window_label': 'Allowed 120 minutes',
      'left_label': breach ? '' : '80 minutes left',
      'breach': breach,
      'breach_label': breach ? 'Cold chain window exceeded' : '',
      // Present on purpose: a widget that starts deciding urgency from these
      // two numbers instead of `tone` is the regression this catches.
      'elapsed_min': 40,
      'window_min': 120,
      'tone': tone,
    };

Map<String, dynamic> _nudge() => {
      'has': true,
      'heading': 'Check your run',
      'items': [
        {
          'kind': 'off_route',
          'label': 'Off route',
          'body': 'You are off the planned route. Rejoin it or call ops.',
          'tone': 'warning',
        },
        {
          'kind': 'stationary',
          'label': 'Stopped mid-run',
          'body': 'You have not moved for a while. Tap SOS if you need help.',
          'tone': 'warning',
        },
      ],
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

  group('the doorbell (spec 1 and 3)', () {
    testWidgets('the 500 m ring prints the approach copy and opens the handover',
        (tester) async {
      await _pump(tester, DeliveryArrivalCard(arrival: _arrival(state: 'approaching')));

      expect(find.text('Rider is close'), findsOneWidget);
      expect(find.text('Arriving'), findsOneWidget);
      // The handover is open BEFORE the rider is at the door — that is the
      // whole reason the approach ring exists.
      expect(find.text('Handover QR'), findsOneWidget);
      expect(find.text('4321'), findsOneWidget);
      // Not here yet: no waiting sentence.
      expect(find.text('Waiting 4 minutes'), findsNothing);
    });

    testWidgets('the 50 m ring prints "here" and the backend\'s waiting sentence',
        (tester) async {
      await _pump(tester, DeliveryArrivalCard(arrival: _arrival()));

      expect(find.text('Rider is here'), findsOneWidget);
      expect(find.text('At your door'), findsOneWidget);
      // The sentence, not a number this widget worked out from dwell_started_at
      // (which is set to the year 2020 on purpose).
      expect(find.text('Waiting 4 minutes'), findsOneWidget);
    });

    testWidgets('enroute renders nothing, even with a full payload attached',
        (tester) async {
      await _pump(tester, DeliveryArrivalCard(arrival: _arrival(state: 'enroute')));

      expect(find.text('Rider is here'), findsNothing);
      expect(find.text('Rider is close'), findsNothing);
      expect(find.text('Handover QR'), findsNothing);
    });

    testWidgets('a completed stop clears the doorbell', (tester) async {
      await _pump(tester,
          const DeliveryArrivalCard(arrival: {'has': false, 'state': 'done'}));

      expect(find.byType(SizedBox), findsWidgets);
      expect(find.text('Rider is here'), findsNothing);
    });

    testWidgets('has_otp:false prints no OTP and no empty OTP row, but keeps the QR',
        (tester) async {
      // CHANGE #354's line. This is the rider asking the same RPC.
      await _pump(tester, DeliveryArrivalCard(arrival: _arrival(otp: false)));

      expect(find.text('4321'), findsNothing);
      expect(find.text('Handover OTP'), findsNothing);
      expect(find.text('Read this out to the rider'), findsNothing);
      // The QR is still there: the rider has to scan it.
      expect(find.text('Handover QR'), findsOneWidget);
    });

    testWidgets('the avatar and the call button are the host\'s, and are optional',
        (tester) async {
      await _pump(
        tester,
        DeliveryArrivalCard(
          arrival: _arrival(),
          avatar: const Text('AVATAR'),
          call: const Text('CALL'),
        ),
      );
      expect(find.text('AVATAR'), findsOneWidget);
      expect(find.text('CALL'), findsOneWidget);

      await _pump(tester, DeliveryArrivalCard(arrival: _arrival()));
      expect(find.text('AVATAR'), findsNothing);
      expect(find.text('CALL'), findsNothing);
    });
  });

  group('cold chain (spec 4)', () {
    testWidgets('prints elapsed, allowed and remaining verbatim', (tester) async {
      await _pump(tester, ColdChainStrip(cold: _cold()));

      expect(find.text('Cold chain'), findsOneWidget);
      expect(find.text('40 minutes out of the cold box'), findsOneWidget);
      expect(find.text('Allowed 120 minutes · 80 minutes left'), findsOneWidget);
    });

    testWidgets('a breach leads with the backend\'s breach sentence',
        (tester) async {
      await _pump(tester,
          ColdChainStrip(cold: _cold(breach: true, tone: 'danger')));

      expect(find.text('Cold chain window exceeded'), findsOneWidget);
      // The heading is replaced, not printed alongside.
      expect(find.text('Cold chain'), findsNothing);
      // No remaining-time sentence once the window is gone.
      expect(find.text('80 minutes left'), findsNothing);
    });

    testWidgets('a stop that is not cold chain renders nothing', (tester) async {
      await _pump(tester,
          const ColdChainStrip(cold: {'has': false, 'is_cold_chain': false}));
      expect(find.text('Cold chain'), findsNothing);
    });
  });

  group('the rider nudge (spec 2)', () {
    testWidgets('prints every open anomaly in payload order', (tester) async {
      await _pump(tester, RiderNudgeStrip(nudge: _nudge()));

      expect(find.text('Check your run'), findsOneWidget);
      expect(find.text('Off route'), findsOneWidget);
      expect(
          find.text('You are off the planned route. Rejoin it or call ops.'),
          findsOneWidget);
      expect(find.text('Stopped mid-run'), findsOneWidget);

      // Payload order, not alphabetical and not by severity this widget guessed.
      final offRoute = tester.getTopLeft(find.text('Off route')).dy;
      final stationary = tester.getTopLeft(find.text('Stopped mid-run')).dy;
      expect(offRoute, lessThan(stationary));
    });

    testWidgets('a clean run renders no strip', (tester) async {
      await _pump(tester,
          const RiderNudgeStrip(nudge: {'has': false, 'items': []}));
      expect(find.text('Check your run'), findsNothing);
    });

    testWidgets('has:true with an empty list still renders nothing',
        (tester) async {
      await _pump(tester,
          const RiderNudgeStrip(nudge: {'has': true, 'heading': 'Check your run', 'items': []}));
      expect(find.text('Check your run'), findsNothing);
    });
  });
}
