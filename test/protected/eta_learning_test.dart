// PROTECTED — CHANGE #702 (the ETA learns).
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes the learned-ETA payload contract.
//
// #691 gave the card a window. #702 gave the BACKEND a model that decides how
// wide that window is, how much history stands behind it, and whether the stop
// is going to miss its promise. The risk that creates is a client that starts
// doing arithmetic again — deriving "late" by comparing eta_at with
// promised_at, or widening the window itself when confidence is low. So:
//
//   1. THE BREACH IS A FLAG, NOT A COMPARISON. The fixture's eta_at is EARLIER
//      than its promised_at while breach.has is true, and the banner must still
//      appear; and a payload whose eta_at is far LATER than promised_at with
//      breach.has false must render no banner at all. Only the backend decides.
//
//   2. THE WINDOW IS PRINTED, NEVER MEASURED. window_label is the only source
//      of the window; eta_lo/eta_hi are carried for the render-log and must not
//      be formatted here. A narrower band is invisible to this widget — which
//      is exactly why the model can narrow it without a deploy.
//
//   3. A #691-ERA PAYLOAD STILL RENDERS. No breach key, no confidence key: the
//      card draws the window and nothing else, rather than throwing or printing
//      an empty row.
//
// No network, no Supabase, no goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/delivery_proof_card.dart';

Map<String, dynamic> _base({
  String window = '4:10–4:30 pm',
  String confidence = 'Based on 41 past deliveries here',
  Map<String, dynamic>? breach,
}) =>
    {
      'has': true,
      'state': 'eta',
      'heading': 'Expected arrival',
      'label': 'Arriving $window',
      'window_label': window,
      'countdown_label': 'in about 25 min',
      'eta_at': '2026-09-03T10:40:00+00:00',
      'eta_lo': '2026-09-03T10:40:00+00:00',
      'eta_hi': '2026-09-03T11:00:00+00:00',
      'eta_min': 25,
      'window_minutes': 20,
      'samples': 41,
      'confidence': 'high',
      'confidence_label': confidence,
      'stops_ahead': 1,
      'stops_ahead_label': '1 stop before you',
      'note': 'Updated as the rider moves',
      'breach': breach ?? const {'has': false},
    };

Map<String, dynamic> _breach() => {
      'has': true,
      'title': 'Running late',
      'body': 'We now expect 4:10–4:30 pm. Sorry — traffic is heavier than planned.',
      'promised_caption': 'Originally promised',
      'promised_label': '03 Sep 2026, 03:45 PM',
      'late_minutes': 25,
    };

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: SingleChildScrollView(child: child)),
  ));
  await tester.pump();
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('the learned window', () {
    testWidgets('prints the confidence sentence the model sent', (tester) async {
      await _pump(tester, DeliveryEtaCard(eta: _base()));
      expect(find.text('Based on 41 past deliveries here'), findsOneWidget);
      expect(find.text('Arriving 4:10–4:30 pm'), findsOneWidget);
    });

    testWidgets('a low-confidence payload prints ITS sentence, not a warning '
        'this build invented', (tester) async {
      await _pump(
          tester,
          DeliveryEtaCard(
              eta: _base(
                  confidence: 'Estimate will sharpen as we learn this route')));
      expect(find.text('Estimate will sharpen as we learn this route'),
          findsOneWidget);
      expect(find.textContaining('low confidence'), findsNothing);
    });

    testWidgets('a narrower band changes nothing here — the label is the label',
        (tester) async {
      // The same widget, a window the model tightened from 20 minutes to 8.
      await _pump(tester, DeliveryEtaCard(eta: _base(window: '4:12–4:20 pm')));
      expect(find.text('Arriving 4:12–4:20 pm'), findsOneWidget);
      // and no second, computed rendering of the same window
      expect(find.text('4:10–4:30 pm'), findsNothing);
    });

    testWidgets('a #691-era payload with no confidence and no breach still '
        'renders the window', (tester) async {
      await _pump(
          tester,
          DeliveryEtaCard(eta: const {
            'has': true,
            'state': 'eta',
            'heading': 'Expected arrival',
            'label': 'Arriving 4:10–4:30 pm',
            'window_label': '4:10–4:30 pm',
            'countdown_label': 'in about 25 min',
            'stops_ahead_label': 'You are next',
            'note': 'Updated as the rider moves',
          }));
      expect(find.text('Arriving 4:10–4:30 pm'), findsOneWidget);
      expect(find.text('You are next'), findsOneWidget);
      expect(find.text('Running late'), findsNothing);
    });
  });

  group('the promise breach is the backend\'s verdict', () {
    testWidgets('the banner appears on breach.has, and prints its own words',
        (tester) async {
      await _pump(tester, DeliveryEtaCard(eta: _base(breach: _breach())));
      expect(find.text('Running late'), findsOneWidget);
      expect(
          find.text(
              'We now expect 4:10–4:30 pm. Sorry — traffic is heavier than planned.'),
          findsOneWidget);
      expect(find.text('Originally promised 03 Sep 2026, 03:45 PM'),
          findsOneWidget);
    });

    testWidgets('breach.has false renders no banner even when the timestamps '
        'would suggest one', (tester) async {
      // eta_at is two hours PAST a promised_at that is also in the payload —
      // and the backend still says has:false. A card that compared them would
      // draw a banner here; this one must not.
      final eta = _base();
      eta['eta_at'] = '2026-09-03T18:00:00+00:00';
      eta['breach'] = const {
        'has': false,
        'promised_label': '03 Sep 2026, 03:45 PM',
      };
      await _pump(tester, DeliveryEtaCard(eta: eta));
      expect(find.text('Running late'), findsNothing);
      expect(find.textContaining('Originally promised'), findsNothing);
    });

    testWidgets('the banner shows on breach.has even when eta_at is EARLIER '
        'than the promise', (tester) async {
      final eta = _base(breach: _breach());
      eta['eta_at'] = '2026-09-03T05:00:00+00:00';
      await _pump(tester, DeliveryEtaCard(eta: eta));
      expect(find.text('Running late'), findsOneWidget);
    });

    testWidgets('a breach with no promised_label omits that line rather than '
        'printing a dangling caption', (tester) async {
      await _pump(
          tester,
          DeliveryEtaCard(
              eta: _base(breach: const {
            'has': true,
            'title': 'Running late',
            'body': 'We now expect 4:10–4:30 pm.',
            'promised_caption': 'Originally promised',
            'promised_label': '',
          })));
      expect(find.text('Running late'), findsOneWidget);
      expect(find.textContaining('Originally promised'), findsNothing);
    });
  });
}
