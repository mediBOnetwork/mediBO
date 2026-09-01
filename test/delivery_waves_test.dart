// CHANGE #405 — the wave planner's frontend contract.
//
// The engine lives in SQL; this file holds down the one thing Dart is allowed
// to do with it, which is print it. Fixtures mirror the real
// admin_delivery_waves() shape.
//
//   1. NOTHING ON THIS SCREEN IS COMPOSED IN DART. The status label, the chips,
//      each rider's "3 stops", the reason sentence under every stop and every
//      button caption are printed exactly as they arrived. "2 stops" is on
//      screen because the BACKEND sent "2 stops" — the widget never sees the
//      number it was pluralised from.
//   2. THE MODE TOGGLE OFFERS THE PAYLOAD'S OPTIONS. Three arrive, three are
//      drawn, and the selected one is the payload's `value` — not a Dart
//      default. Tapping one sends delivery_wave_mode_set with that key.
//   3. AN UNKNOWN TONE DOES NOT THROW. A payload from a newer build renders
//      neutral rather than crashing an older app.
//   4. `can_pull` IS A FLAG, NOT AN INFERENCE. The pull-off affordance appears
//      only where the backend said so, and it sends the stop's own id.
//   5. A REFUSAL IS THE BACKEND'S SENTENCE. delivery_wave_stop_pull's
//      "That run has already started" is shown verbatim.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/admin_delivery_waves_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _wave({
  String statusTone = 'warning',
  List<Map<String, dynamic>>? stops,
  List<Map<String, dynamic>>? actions,
}) =>
    {
      'ok': true,
      'wave_id': 'w-1',
      'title': 'Afternoon wave',
      'subtitle': '01 Sep • Cut automatically at the Afternoon wave cut-off',
      'status': 'proposed',
      'status_label': 'Waiting for approval',
      'status_tone': statusTone,
      'mode': 'suggest',
      'chips': const [
        {'label': '4 stops', 'tone': 'info'},
        {'label': '2 riders', 'tone': 'neutral'},
        {'label': '1 blocked', 'tone': 'danger'},
      ],
      'riders_heading': 'Load per rider',
      'riders': const [
        {'partner_id': 'p-1', 'name': 'Ravi Kumar', 'count_label': '2 stops'},
        {'partner_id': 'p-2', 'name': 'Sunil Yadav', 'count_label': '1 stop'},
      ],
      'stops_heading': 'Stops',
      'stops': stops ??
          const [
            {
              'stop_id': 's-1',
              'label': 'Sharma Medical',
              'sub_label': 'Raipur',
              'rider_label': 'Ravi Kumar',
              'status_label': 'Planned',
              'status_tone': 'info',
              'reason': 'Lightest load in this zone — 0 stops in hand',
              'can_pull': true,
              'pull_label': 'Pull off the run',
            },
            {
              'stop_id': 's-2',
              'label': 'Verma Chemist',
              'sub_label': 'Raipur',
              'rider_label': 'Not allocated',
              'status_label': 'Blocked',
              'status_tone': 'danger',
              'reason': 'Payment pending',
              'can_pull': false,
              'pull_label': 'Pull off the run',
            },
          ],
      'decisions_heading': 'Why the engine chose this',
      'decisions': const [
        {
          'label': 'Given to Ravi Kumar — lightest load in this zone (0 stops in hand).',
          'at_label': '01 Sep 14:30',
          'actor': 'engine',
        },
      ],
      'actions': actions ??
          const [
            {'key': 'replan', 'label': 'Re-plan', 'tone': 'neutral'},
            {'key': 'approve', 'label': 'Approve and send', 'tone': 'brand'},
          ],
    };

Map<String, dynamic> _payload({
  String mode = 'suggest',
  List<Map<String, dynamic>>? waves,
}) =>
    {
      'ok': true,
      'allowed': true,
      'title': 'Delivery waves',
      'subtitle': 'Raipur • 01 Sep 2026',
      'zone_id': 1,
      'zone_label': 'Raipur',
      'mode_card': {
        'heading': 'Assignment mode',
        'value': mode,
        'value_label': 'Suggest — you approve the plan',
        'help': 'Set per zone. Suggest is the default so the plan is seen '
            'before it is trusted.',
        'options': const [
          {'key': 'auto', 'label': 'Auto', 'hint': 'Cut, plan and send to riders without a tap.'},
          {'key': 'suggest', 'label': 'Suggest', 'hint': 'Prepare the wave and wait for your approval.'},
          {'key': 'manual', 'label': 'Manual', 'hint': 'No waves — assign from the delivery queue as today.'},
        ],
      },
      'riders_line': '2 riders on shift in this zone',
      'windows_heading': 'Cut-off windows',
      'windows': const [
        {'key': 'morning', 'label': 'Morning wave', 'cutoff_label': 'Cut-off 10:30 IST', 'action_label': 'Cut now'},
        {'key': 'evening', 'label': 'Evening wave', 'cutoff_label': 'Cut-off 18:00 IST', 'action_label': 'Cut now'},
      ],
      'waves_heading': 'Waves today',
      'waves': waves ?? [_wave()],
      'empty_hint': 'No wave cut yet today.',
    };

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  Future<List<List<Object?>>> pump(
    WidgetTester tester, {
    required Map<String, dynamic> payload,
    Map<String, dynamic>? actionResult,
  }) async {
    final calls = <List<Object?>>[];
    // A tall surface: this screen is a scrolling list and every assertion below
    // is about what it PRINTS, not about what fits an 800x600 default viewport.
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: AdminDeliveryWavesScreen(
        rpc: (fn, p) async {
          calls.add([fn, p]);
          if (fn == 'admin_delivery_waves') return payload;
          return actionResult ?? const {'ok': true};
        },
      ),
    ));
    await tester.pumpAndSettle();
    return calls;
  }

  testWidgets('every label, chip, count and reason is printed verbatim',
      (tester) async {
    await pump(tester, payload: _payload());

    // Headings and the zone line.
    expect(find.text('Delivery waves'), findsWidgets);
    expect(find.text('Raipur • 01 Sep 2026'), findsOneWidget);
    expect(find.text('2 riders on shift in this zone'), findsOneWidget);

    // The wave's own words.
    expect(find.text('Afternoon wave'), findsOneWidget);
    expect(find.text('Waiting for approval'), findsOneWidget);
    expect(find.text('4 stops'), findsOneWidget);
    expect(find.text('1 blocked'), findsOneWidget);

    // Rider load is the backend's plural — "2 stops" and "1 stop" both arrive
    // finished, and nothing here counts anything.
    expect(find.text('Ravi Kumar'), findsWidgets);
    expect(find.text('2 stops'), findsWidgets);
    expect(find.text('1 stop'), findsOneWidget);

    // Every automatic decision is readable on the surface (spec 4).
    expect(find.text('Why the engine chose this'), findsOneWidget);
    expect(
        find.text(
            'Given to Ravi Kumar — lightest load in this zone (0 stops in hand).'),
        findsOneWidget);

    // A block is shown WITH the backend's own refusal, never swallowed.
    expect(find.text('Blocked'), findsOneWidget);
    expect(find.text('Payment pending'), findsOneWidget);
  });

  testWidgets('the mode toggle offers the payload options and sends the key',
      (tester) async {
    final calls = await pump(tester, payload: _payload(mode: 'suggest'));

    expect(find.text('Auto'), findsOneWidget);
    expect(find.text('Suggest'), findsOneWidget);
    expect(find.text('Manual'), findsOneWidget);
    expect(find.text('Cut, plan and send to riders without a tap.'), findsOneWidget);

    // The selected option is the payload's `value` — 'suggest' — so exactly one
    // radio is filled and it is not a Dart default.
    expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_unchecked), findsNWidgets(2));

    calls.clear();
    await tester.tap(find.text('Auto'));
    await tester.pumpAndSettle();

    final set = calls.firstWhere((c) => c[0] == 'delivery_wave_mode_set');
    expect((set[1] as Map)['p_mode'], 'auto');
    expect((set[1] as Map)['p_zone_id'], 1);
  });

  testWidgets('a cut-off window fires delivery_wave_cut_now with its own key',
      (tester) async {
    final calls = await pump(tester, payload: _payload());
    expect(find.text('Cut-off 10:30 IST'), findsOneWidget);

    calls.clear();
    await tester.tap(find.text('Cut now').first);
    await tester.pumpAndSettle();

    final cut = calls.firstWhere((c) => c[0] == 'delivery_wave_cut_now');
    expect((cut[1] as Map)['p_window_key'], 'morning');
  });

  testWidgets('a wave action sends the backend button key, not a Dart guess',
      (tester) async {
    final calls = await pump(tester, payload: _payload());

    calls.clear();
    await tester.tap(find.text('Approve and send'));
    await tester.pumpAndSettle();

    final act = calls.firstWhere((c) => c[0] == 'delivery_wave_action');
    expect((act[1] as Map)['p_action'], 'approve');
    expect((act[1] as Map)['p_wave_id'], 'w-1');
  });

  testWidgets('can_pull is a flag — the affordance exists only where sent',
      (tester) async {
    final calls = await pump(tester, payload: _payload());

    // Two stops, exactly one of which the backend allows pulling.
    expect(find.text('Pull off the run'), findsOneWidget);

    calls.clear();
    await tester.tap(find.text('Pull off the run'));
    await tester.pumpAndSettle();

    final pull = calls.firstWhere((c) => c[0] == 'delivery_wave_stop_pull');
    expect((pull[1] as Map)['p_stop_id'], 's-1');
  });

  testWidgets("a refusal shows the backend's sentence", (tester) async {
    await pump(tester,
        payload: _payload(),
        actionResult: const {
          'ok': false,
          'error': 'run_started',
          'message': 'That run has already started — reassign the stop instead.',
        });

    await tester.tap(find.text('Pull off the run'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
        find.text('That run has already started — reassign the stop instead.'),
        findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('an unknown tone renders neutral instead of throwing',
      (tester) async {
    await pump(tester,
        payload: _payload(waves: [_wave(statusTone: 'cosmic_ray')]));
    expect(find.text('Waiting for approval'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an empty day renders the backend hint, not a blank page',
      (tester) async {
    await pump(tester, payload: _payload(waves: const []));
    expect(find.text('No wave cut yet today.'), findsOneWidget);
  });
}
