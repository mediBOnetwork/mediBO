// PROTECTED — CHANGE #704, the agency dispatch board.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes agency-dispatch behaviour, never to make an unrelated
// change go green.
//
// What this holds down:
//
//   1. The board computes NOTHING. The SLA countdown, the promised window, the
//      distance, the bag count and the chain sentence are all backend strings
//      printed verbatim. The countdown especially: the fixture's `sec_left`
//      deliberately DISAGREES with its `sla_label`, so a Dart-side clock that
//      re-derived "3 min left" from the seconds would fail this test. The
//      deadline belongs to the server that enforces it.
//
//   2. Absence is a FLAG, never an empty string. has_distance:false and
//      has_bags:false remove those facts from the card instead of printing a
//      dash, an empty separator or a zero.
//
//   3. Buttons are the payload's. action.has:false renders no button at all —
//      a stop in a state this build has never heard of offers nothing rather
//      than guessing an action, and the label is never typed in Dart.
//
//   4. A rider the backend marked can_take:false is NOT offered in the pick
//      sheet. Whether a rider has room is one SQL comparison (spare vs load,
//      documents, shift); repeating it in Dart is how the two answers start to
//      differ.
//
//   5. Sections render in PAYLOAD ORDER (the fixture is deliberately not
//      alphabetical), and a section key this build does not know is an empty
//      list rather than a crash.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/design_tokens.dart';
import 'package:pharma_b2b/screens/delivery/agency_dispatch_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _stop({
  required String code,
  required String pharmacy,
  String status = 'agency_pending',
  bool hasDistance = true,
  bool hasBags = true,
  bool hasAction = true,
}) =>
    {
      'delivery_id': 'd-$code',
      'order_id': 'o-$code',
      'order_code': code,
      'pharmacy_name': pharmacy,
      'address': '12 Station Road',
      'status': status,
      'status_label': status == 'agency_pending' ? 'With the agency' : 'Assigned',
      'status_tone': status == 'agency_pending' ? 'warn' : 'good',
      'window_label': 'Promised 04:30 PM',
      'has_distance': hasDistance,
      'distance_label': hasDistance ? '3.4 km away' : '',
      'has_bags': hasBags,
      'bags_label': hasBags ? '2 bags' : '',
      'rider_name': status == 'agency_pending' ? '' : 'Ravi',
      'chain_label': status == 'agency_pending'
          ? 'Sunrise Logistics → picking a rider'
          : 'Sunrise Logistics → Ravi',
      // Deliberately inconsistent with sla_label: a client-side clock fails.
      'sec_left': 540,
      'sla_label': status == 'agency_pending' ? '4 min left' : '',
      'sla_tone': 'warn',
      'action': hasAction
          ? {
              'has': true,
              'key': status == 'agency_pending' ? 'assign' : 'reassign',
              'label': status == 'agency_pending' ? 'Pick a rider' : 'Change rider',
            }
          : {'has': false, 'key': '', 'label': ''},
    };

Map<String, dynamic> _board() => {
      'ok': true,
      'allowed': true,
      'is_agency': true,
      'agency_id': 'ag-1',
      'agency_name': 'Sunrise Logistics',
      'title': 'Agency dispatch',
      'note': 'Stops mediBO handed to you.',
      'waiting_heading': 'Waiting for a rider',
      'running_heading': 'With your riders',
      'empty': 'Nothing waiting.',
      'empty_running': 'No rider is carrying a stop.',
      'sheet_title': 'Give this stop to',
      'no_riders': 'No rider on your team has spare capacity right now.',
      // Payload order, deliberately NOT alphabetical by pharmacy name.
      'waiting': [
        _stop(code: 'ORD-77', pharmacy: 'Zenith Medicals'),
        _stop(code: 'ORD-12', pharmacy: 'Apollo Chemists', hasDistance: false, hasBags: false),
      ],
      'running': [
        _stop(code: 'ORD-90', pharmacy: 'Bharat Pharmacy', status: 'assigned'),
      ],
      'riders': [
        {
          'partner_id': 'r-1',
          'name': 'Ravi Kumar',
          'vehicle': 'Bike',
          'spare_label': '3 free',
          'status_label': 'Idle',
          'status_tone': 'good',
          'can_take': true,
        },
        {
          'partner_id': 'r-2',
          'name': 'Full Rider',
          'vehicle': 'Bike',
          'spare_label': '0 free',
          'status_label': 'On the road',
          'status_tone': 'info',
          // The backend already decided this one cannot take another stop.
          'can_take': false,
        },
      ],
    };

void main() {
  setUpAll(() {
    // The 800 ms debounce is a real Timer that would outlive the test.
    RenderLog.flushEnabled = false;
  });

  group('AgencyBoard — the two pure decisions', () {
    test('rows() keeps payload order and never sorts', () {
      final w = AgencyBoard.rows(_board(), 'waiting');
      expect(w.map((e) => e['order_code']).toList(), ['ORD-77', 'ORD-12'],
          reason: 'the board must render the order the backend sent, not an '
              'order Dart chose');
    });

    test('an unknown or non-list section is empty, not a crash', () {
      expect(AgencyBoard.rows(_board(), 'a_section_this_build_never_heard_of'),
          isEmpty);
      expect(AgencyBoard.rows({'waiting': 'not a list'}, 'waiting'), isEmpty);
      expect(AgencyBoard.rows(const {}, 'riders'), isEmpty);
    });

    test('an unknown tone reads as neutral, never as an error colour', () {
      expect(AgencyBoard.toneColor('bad'), Ds.c.danger);
      expect(AgencyBoard.toneColor('good'), Ds.c.success);
      expect(AgencyBoard.toneColor('a_tone_from_the_future'), Ds.c.textSecondary);
      expect(AgencyBoard.toneSoft('a_tone_from_the_future'), Ds.c.bg);
    });
  });

  group('the card prints the backend and computes nothing', () {
    testWidgets('every fact on a waiting stop is the payload string', (t) async {
      await _pump(t, _board());

      expect(find.text('Waiting for a rider'), findsOneWidget);
      expect(find.text('With your riders'), findsOneWidget);
      expect(find.text('Zenith Medicals'), findsOneWidget);

      // The countdown is the SENTENCE, not sec_left re-divided in Dart.
      expect(find.text('4 min left'), findsWidgets);
      expect(find.textContaining('9 min'), findsNothing,
          reason: 'sec_left is 540 — a card that shows "9 min left" is running '
              'its own clock instead of printing the backend deadline');

      // Window / distance / bags are one backend-worded meta line.
      expect(find.textContaining('Promised 04:30 PM'), findsWidgets);
      expect(find.textContaining('3.4 km away'), findsWidgets);
      expect(find.textContaining('2 bags'), findsWidgets);

      // The chain, verbatim, both before and after a rider is picked.
      expect(find.text('Sunrise Logistics → picking a rider'), findsWidgets);
      expect(find.text('Sunrise Logistics → Ravi'), findsOneWidget);
    });

    testWidgets('absence removes the fact instead of printing a dash',
        (t) async {
      await _pump(t, _board());
      // ORD-12 sent has_distance:false + has_bags:false.
      final meta = t
          .widgetList<Text>(find.byType(Text))
          .map((w) => w.data ?? '')
          .where((s) => s.contains('Promised 04:30 PM'))
          .toList();
      expect(meta.any((s) => s == 'Promised 04:30 PM'), isTrue,
          reason: 'a stop with no distance and no bags shows the window alone '
              '— never "Promised 04:30 PM ·  · " or a 0 km');
      expect(find.textContaining('0 km'), findsNothing);
      expect(find.textContaining('0 bags'), findsNothing);
    });

    testWidgets('the button is the payload button, and absent when has:false',
        (t) async {
      await _pump(t, _board());
      expect(find.widgetWithText(ElevatedButton, 'Pick a rider'), findsNWidgets(2));
      expect(find.widgetWithText(ElevatedButton, 'Change rider'), findsOneWidget);

      final b = _board();
      b['waiting'] = [_stop(code: 'X', pharmacy: 'No Action Pharmacy', hasAction: false)];
      b['running'] = <Map<String, dynamic>>[];
      await _pump(t, b);
      expect(find.byType(ElevatedButton), findsNothing,
          reason: 'a state this build has never heard of offers no action '
              'rather than guessing one');
    });

    testWidgets('an empty section prints the backend empty state', (t) async {
      final b = _board();
      b['waiting'] = <Map<String, dynamic>>[];
      b['running'] = <Map<String, dynamic>>[];
      await _pump(t, b);
      expect(find.text('Nothing waiting.'), findsOneWidget);
      expect(find.text('No rider is carrying a stop.'), findsOneWidget);
    });

    testWidgets('a refusal renders the backend message and no board', (t) async {
      await _pump(t, {
        'ok': false,
        'allowed': false,
        'is_agency': false,
        'title': 'Agency dispatch',
        'message': 'This login is not an agency account.',
        'waiting': <Map<String, dynamic>>[],
        'running': <Map<String, dynamic>>[],
        'riders': <Map<String, dynamic>>[],
      });
      expect(find.text('This login is not an agency account.'), findsOneWidget);
      expect(find.byType(ElevatedButton), findsNothing);
    });
  });

  group('the pick sheet offers exactly who the backend allowed', () {
    testWidgets('a rider with can_take:false is not on the list', (t) async {
      await _pump(t, _board());
      await t.tap(find.widgetWithText(ElevatedButton, 'Pick a rider').first);
      await t.pumpAndSettle();

      expect(find.text('Give this stop to'), findsOneWidget);
      expect(find.text('Ravi Kumar'), findsOneWidget);
      expect(find.text('3 free'), findsOneWidget);
      expect(find.text('Full Rider'), findsNothing,
          reason: 'can_take is the backend\'s single answer to "has this rider '
              'room" — a card that shows them anyway lets the agency send work '
              'to a rider SQL already refused');
    });

    testWidgets('no eligible rider prints the backend sentence', (t) async {
      final b = _board();
      for (final r in (b['riders'] as List)) {
        (r as Map)['can_take'] = false;
      }
      await _pump(t, b);
      await t.tap(find.widgetWithText(ElevatedButton, 'Pick a rider').first);
      await t.pumpAndSettle();
      expect(find.text('No rider on your team has spare capacity right now.'),
          findsOneWidget);
    });
  });
}

/// Renders the board's body with a fixture payload — no Supabase, no network.
/// The surface is made tall enough for BOTH sections, because a card that is
/// merely scrolled out of view would silently pass every assertion below.
Future<void> _pump(WidgetTester t, Map<String, dynamic> board) async {
  t.view.physicalSize = const Size(1200, 3000);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      body: AgencyDispatchBoardBody(board: board, onAssign: (stop, partnerId) async {}),
    ),
  ));
  await t.pumpAndSettle();
}
