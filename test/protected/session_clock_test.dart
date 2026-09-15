// PROTECTED — CMD #1850.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes the SESSION CLOCK.
//
// A test session may pin an effective time so the order cut-off, order hours,
// an expiring token and every SLA countdown can be walked through in seconds
// instead of waited out. The danger in that feature is not the feature — it is
// the two ways it could quietly leak:
//
//   1. THE UNPINNED PATH MUST BE IDENTICAL. An install that is not testing, or
//      one that is testing but has not pinned anything, must see exactly the
//      banner #1848 shipped: no time control, no time in the caption, no extra
//      widget of any kind. `has:false` and an empty map (the state before the
//      first read lands) both mean draw nothing.
//
//   2. A PINNED SESSION IS ONE SESSION'S FACT. The strip renders only the
//      clock map it is HANDED. It never reads a clock from anywhere else, so
//      one install's pinned time cannot appear on another's screen — the two
//      banners below are built from the same widget in the same test with
//      different payloads, and each prints only its own.
//
// Everything else here is the printer contract: the rendered time, the
// sub-line, the presets, the step sizes, the field hint and the message after
// a tap are the BACKEND's. The fixture's `now_label` deliberately disagrees
// with any clock this machine has (it is a 2019 date), so a control that
// formatted DateTime.now() fails. Its presets are deliberately NOT in time
// order, so a client-side sort fails. And its step chip carries a `minutes`
// that does not match its own label, so a control that parsed the label
// instead of reading the number fails.
//
// No network, no Supabase, no goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/widgets/test_mode_banner.dart';

Map<String, dynamic> _banner() => {
      'on': true,
      'poll_ms': 20000,
      'session_id': 7,
      'text': 'TEST MODE — nothing here is real',
      'label': '07 Sep 13:04 run',
      'owner_label': 'Started by Om',
      'ends_label': 'Auto-ends 08 Sep 01:04',
      'badge': 'TEST',
      'tone': 'danger',
      'is_owner': true,
      'can_end': true,
      'end_action': 'End & purge',
      'end_confirm': '',
      'end_cancel': 'Keep testing',
    };

Map<String, dynamic> _clock({bool pinned = false, bool presets = true}) => {
      'has': true,
      'session_id': 7,
      'pinned': pinned,
      'title': 'Session clock',
      'badge': 'CLOCK',
      'tone': pinned ? 'warning' : 'neutral',
      'now_label': pinned ? '14 Feb, 11:29 PM' : '14 Feb, 1:04 PM',
      'now_sub': pinned ? 'Pinned · real time is 1:04 PM' : 'Real time',
      'open_action': 'Clock',
      'close_action': 'Done',
      'step_label': 'Step',
      'steps': [
        // The label and the number deliberately disagree: the control must
        // send `minutes`, never something parsed out of the words.
        {'key': '15', 'label': '+15 m', 'minutes': 15},
        {'key': '-60', 'label': '−1 h', 'minutes': -60},
      ],
      'jump_label': 'Jump to',
      'jump_hint': 'DD-MM HH:MM, 24-hour, IST',
      'jump_action': 'Pin',
      'presets_label': 'Jump to a moment that matters',
      'presets': presets
          ? [
              // Deliberately NOT in time order.
              {'key': 'cutoff_plus', 'label': 'Just past cut-off',
               'at': '2019-02-14 17:06'},
              {'key': 'cutoff_minus', 'label': '1 min before cut-off',
               'at': '2019-02-14 16:59'},
            ]
          : <Map<String, dynamic>>[],
      'can_release': pinned,
      'release_action': 'Real time',
    };

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('the unpinned path is the path that shipped', () {
    testWidgets('an empty clock map draws no control and no time', (t) async {
      await t.pumpWidget(_host(TestModeBanner(payload: _banner())));
      expect(find.byKey(const ValueKey('test_clock_open')), findsNothing);
      expect(find.textContaining('11:29 PM'), findsNothing);
      // #1848's own words are untouched.
      expect(find.text('TEST MODE — nothing here is real'), findsOneWidget);
      expect(find.text('End & purge'), findsOneWidget);
    });

    testWidgets('has:false draws no control either', (t) async {
      await t.pumpWidget(_host(TestModeBanner(
        payload: _banner(),
        clock: const {'has': false},
      )));
      expect(find.byKey(const ValueKey('test_clock_open')), findsNothing);
    });

    testWidgets('a live but UNPINNED clock offers the control and prints no time',
        (t) async {
      await t.pumpWidget(_host(TestModeBanner(
        payload: _banner(),
        clock: _clock(),
      )));
      expect(find.byKey(const ValueKey('test_clock_open')), findsOneWidget);
      // pinned:false — the caption is exactly what it was before this change.
      expect(
        find.text('07 Sep 13:04 run  ·  Started by Om  ·  Auto-ends 08 Sep 01:04'),
        findsOneWidget,
      );
    });
  });

  testWidgets('a pinned clock names its time on the strip, verbatim', (t) async {
    await t.pumpWidget(_host(TestModeBanner(
      payload: _banner(),
      clock: _clock(pinned: true),
    )));
    expect(
      find.text('14 Feb, 11:29 PM  ·  07 Sep 13:04 run  ·  Started by Om  ·  '
          'Auto-ends 08 Sep 01:04'),
      findsOneWidget,
    );
  });

  testWidgets('one install\'s pinned clock never reaches another\'s banner',
      (t) async {
    // The SAME widget, twice, in one tree: each prints only the clock it was
    // handed. There is no global the second could read the first out of.
    await t.pumpWidget(_host(Column(children: [
      TestModeBanner(payload: _banner(), clock: _clock(pinned: true)),
      TestModeBanner(payload: _banner(), clock: const {'has': false}),
    ])));
    expect(find.textContaining('11:29 PM'), findsOneWidget);
    expect(find.byKey(const ValueKey('test_clock_open')), findsOneWidget);
  });

  group('the sheet is a printer', () {
    testWidgets('it prints the backend\'s time and sub-line', (t) async {
      await t.pumpWidget(_host(TestClockSheet(clock: _clock(pinned: true))));
      expect(find.text('14 Feb, 11:29 PM'), findsOneWidget);
      expect(find.text('Pinned · real time is 1:04 PM'), findsOneWidget);
      expect(find.text('Session clock'), findsOneWidget);
    });

    testWidgets('presets render in PAYLOAD order and send their own instant',
        (t) async {
      String? sent;
      await t.pumpWidget(_host(TestClockSheet(
        clock: _clock(),
        onPin: (at) async {
          sent = at;
          return {'ok': true, ...(_clock(pinned: true)), 'message': 'pinned'};
        },
      )));
      final chips = t.widgetList<Text>(find.byType(Text)).map((w) => w.data).toList();
      expect(chips.indexOf('Just past cut-off'),
          lessThan(chips.indexOf('1 min before cut-off')));

      await t.tap(find.text('1 min before cut-off'));
      await t.pumpAndSettle();
      expect(sent, '2019-02-14 16:59');
      // The sheet adopted the state that came back, message and all.
      expect(find.text('14 Feb, 11:29 PM'), findsOneWidget);
      expect(find.text('pinned'), findsOneWidget);
    });

    testWidgets('a step sends its own minutes, not its label', (t) async {
      int? sent;
      await t.pumpWidget(_host(TestClockSheet(
        clock: _clock(),
        onStep: (m) async {
          sent = m;
          return {'ok': true, ...(_clock(pinned: true))};
        },
      )));
      await t.tap(find.text('−1 h'));
      await t.pumpAndSettle();
      expect(sent, -60);
    });

    testWidgets('no presets in the payload means no preset row', (t) async {
      await t.pumpWidget(_host(TestClockSheet(clock: _clock(presets: false))));
      expect(find.text('Jump to a moment that matters'), findsNothing);
      expect(find.text('1 min before cut-off'), findsNothing);
      // The step row and the field are unaffected.
      expect(find.text('Step'), findsOneWidget);
      expect(find.byKey(const ValueKey('test_clock_at')), findsOneWidget);
    });

    testWidgets('Real time appears only while can_release says so', (t) async {
      await t.pumpWidget(_host(TestClockSheet(clock: _clock())));
      expect(find.byKey(const ValueKey('test_clock_release')), findsNothing);

      await t.pumpWidget(_host(TestClockSheet(clock: _clock(pinned: true))));
      expect(find.byKey(const ValueKey('test_clock_release')), findsOneWidget);
    });

    testWidgets('a refusal prints the backend\'s words and moves no clock',
        (t) async {
      await t.pumpWidget(_host(TestClockSheet(
        clock: _clock(pinned: true),
        onPin: (_) async => {
          'ok': false,
          'error': 'no_session',
          'message': 'Start test mode before setting a clock.',
        },
      )));
      await t.enterText(find.byKey(const ValueKey('test_clock_at')), 'nonsense');
      await t.tap(find.byKey(const ValueKey('test_clock_pin')));
      await t.pumpAndSettle();
      expect(find.text('Start test mode before setting a clock.'), findsOneWidget);
      // The displayed time is still the one the backend last stood behind.
      expect(find.text('14 Feb, 11:29 PM'), findsOneWidget);
    });

    testWidgets('the typed text is sent through untouched', (t) async {
      String? sent;
      await t.pumpWidget(_host(TestClockSheet(
        clock: _clock(),
        onPin: (at) async {
          sent = at;
          return {'ok': true, ...(_clock(pinned: true))};
        },
      )));
      await t.enterText(
          find.byKey(const ValueKey('test_clock_at')), '2019-02-14 23:29');
      await t.tap(find.byKey(const ValueKey('test_clock_pin')));
      await t.pumpAndSettle();
      // No parsing, no timezone maths, no reformatting in Dart.
      expect(sent, '2019-02-14 23:29');
    });
  });
}
