// PROTECTED — CHANGE #573.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes Test-mode behaviour, never to make an unrelated change
// go green.
//
// What this holds down — the Test mode screen is the one surface that can
// delete data and flip a platform switch, and it must therefore be the LEAST
// opinionated screen in the app:
//
//   1. Every visible word is the payload's. Title, subtitle, the kill-switch
//      sentence, the Razorpay verdict, fixture labels, count labels, run status
//      labels, empty states and the action captions all print verbatim. If this
//      file could ever show a word the backend did not send, a wording change
//      would need a deploy — and worse, the screen could disagree with what the
//      database actually did.
//
//   2. The red TEST badge exists ONLY when the payload sent one. `null` badge
//      draws nothing. That is what stops a real row ever wearing the mark, and
//      a synthetic one ever going unmarked — the decision is `is_synthetic` in
//      Postgres, resolved by `synthetic_badge()`, never a guess here.
//
//   3. A destructive action's CONFIRMATION is the backend's sentence, and an
//      action with no `confirm` fires straight away. The screen does not decide
//      which buttons are dangerous; the payload's `tone` and `confirm` do.
//
//   4. Rows render in PAYLOAD ORDER — fixtures, counts, runs and actions. No
//      client-side sort, so the backend can reorder any of them without a
//      deploy.
//
//   5. There is ONE door. Om's scope change (#573, live reply) grew the action
//      set from three keys to six — start a session, end it, purge it — and a
//      Dart switch that named each key would have needed a deploy for the
//      seventh. Every button posts its key back through `test_mode_action`
//      verbatim, INCLUDING a key this build has never heard of: the backend
//      answers `unknown_action` and the screen prints that. This is the rule
//      that changed in this file, and it changed deliberately.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/test_mode_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

/// A payload shaped exactly like `test_mode_screen()`. Deliberately in a
/// non-alphabetical order so "payload order" is a real assertion.
Map<String, dynamic> _payload() => <String, dynamic>{
      'ok': true,
      'title': 'PAYLOAD TITLE',
      'subtitle': 'PAYLOAD SUBTITLE',
      'badge': {'label': 'TEST', 'tone': 'danger', 'hint': 'synthetic'},
      'switch': {
        'title': 'PAYLOAD SWITCH TITLE',
        'enabled': true,
        'enabled_label': 'PAYLOAD ENABLED LABEL',
        'enabled_tone': 'success',
        'enabled_hint': 'PAYLOAD ENABLED HINT',
        'allow_outbound': false,
        'outbound_label': 'PAYLOAD OUTBOUND LABEL',
        'phone_label': 'PAYLOAD PHONE LABEL',
        'phone_hint': 'PAYLOAD PHONE HINT',
        'test_phone': null,
        'phone_display': 'PAYLOAD PHONE NONE',
        'phone_tone': 'neutral',
      },
      'razorpay': {
        'is_test': false,
        'label': 'PAYLOAD RAZORPAY LIVE',
        'tone': 'danger',
      },
      'fixtures': {
        'title': 'PAYLOAD FIXTURES TITLE',
        'rows': [
          {'key': 'zebra', 'label': 'ZEBRA FIXTURE', 'id_label': 'z-1',
            'badge': {'label': 'TEST', 'tone': 'danger'}},
          {'key': 'alpha', 'label': 'ALPHA FIXTURE', 'id_label': 'a-1',
            'badge': {'label': 'TEST', 'tone': 'danger'}},
        ],
      },
      'counts': {
        'title': 'PAYLOAD COUNTS TITLE',
        'rows': [
          {'key': 'orders', 'label': 'orders', 'count': 1, 'count_label': '1'},
        ],
        'empty_label': 'PAYLOAD COUNTS EMPTY',
      },
      'runs': {
        'title': 'PAYLOAD RUNS TITLE',
        'rows': [],
        'empty_label': 'PAYLOAD RUNS EMPTY',
      },
      'proof': {
        'title': 'PAYLOAD PROOF TITLE',
        'outbound_label': 'PAYLOAD OUTBOUND HEADING',
        'outbound': {'wa_queued': 0},
        'books_label': 'PAYLOAD BOOKS HEADING',
        'books': {'gst_ledger': 0},
        'clean': true,
        'verdict': 'PAYLOAD VERDICT',
        'tone': 'success',
      },
      'actions': [
        {'key': 'run_full', 'label': 'PAYLOAD RUN', 'tone': 'brand',
          'confirm': null},
        {'key': 'purge', 'label': 'PAYLOAD PURGE', 'tone': 'danger',
          'confirm': 'PAYLOAD PURGE CONFIRM'},
        {'key': 'nonsense_future_action', 'label': 'PAYLOAD FUTURE',
          'tone': 'danger', 'confirm': null},
      ],
    };

/// A service that answers with the fixture and records what was asked of it.
class _FakeService implements TestModeService {
  _FakeService(this._screen);

  Map<String, dynamic> _screen;
  final List<String> calls = <String>[];
  Map<String, dynamic>? lastPatch;
  Map<String, dynamic>? lastArg;

  @override
  Future<Map<String, dynamic>> screen() async {
    calls.add('screen');
    return _screen;
  }

  @override
  Future<Map<String, dynamic>> set(Map<String, dynamic> patch) async {
    calls.add('set');
    lastPatch = patch;
    return _screen;
  }

  @override
  Future<Map<String, dynamic>> act(String key,
      {Map<String, dynamic> arg = const {}}) async {
    calls.add('act:$key');
    lastArg = arg;
    return <String, dynamic>{
      'ok': true,
      'message': key == 'purge' ? 'PAYLOAD PURGE MESSAGE' : 'PAYLOAD RUN MESSAGE',
    };
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// A viewport tall enough that the whole screen is built at once. The screen
/// is a lazy ListView; on the 800x600 default everything below the switch card
/// would simply not exist, and "the backend's word is on screen" would pass by
/// accident on a screen that renders nothing.
Future<_FakeService> _pump(WidgetTester tester,
    {Map<String, dynamic>? payload}) async {
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final svc = _FakeService(payload ?? _payload());
  await tester.pumpWidget(MaterialApp(home: TestModeScreen(service: svc)));
  await tester.pumpAndSettle();
  return svc;
}

void main() {
  // RenderLog.write's 800 ms debounce is a real Timer that would outlive the
  // test and try to reach Supabase (see CLAUDE.md, PROTECTED TEST SUITE).
  setUpAll(() => RenderLog.flushEnabled = false);

  testWidgets('every visible word is the payload, verbatim', (tester) async {
    await _pump(tester);

    for (final s in const [
      'PAYLOAD TITLE',
      'PAYLOAD SUBTITLE',
      'PAYLOAD SWITCH TITLE',
      'PAYLOAD ENABLED LABEL',
      'PAYLOAD ENABLED HINT',
      'PAYLOAD OUTBOUND LABEL',
      'PAYLOAD PHONE LABEL',
      'PAYLOAD PHONE HINT',
      'PAYLOAD RAZORPAY LIVE',
      'PAYLOAD FIXTURES TITLE',
      'PAYLOAD COUNTS TITLE',
      'PAYLOAD RUNS TITLE',
      'PAYLOAD PROOF TITLE',
      'PAYLOAD VERDICT',
      'PAYLOAD RUN',
      'PAYLOAD PURGE',
    ]) {
      expect(find.text(s), findsWidgets, reason: '$s did not render verbatim');
    }
  });

  testWidgets('an empty section prints the backend empty state', (tester) async {
    await _pump(tester);
    expect(find.text('PAYLOAD RUNS EMPTY'), findsOneWidget);
    // counts is NOT empty, so its empty label must not appear
    expect(find.text('PAYLOAD COUNTS EMPTY'), findsNothing);
  });

  testWidgets('rows render in payload order, never sorted here',
      (tester) async {
    await _pump(tester);
    final zebra = tester.getTopLeft(find.text('ZEBRA FIXTURE')).dy;
    final alpha = tester.getTopLeft(find.text('ALPHA FIXTURE')).dy;
    expect(zebra, lessThan(alpha),
        reason: 'the fixture list was re-sorted in Dart');
  });

  testWidgets('the TEST badge is drawn wherever the payload sent one',
      (tester) async {
    await _pump(tester);
    // one in the app bar + one per fixture row
    expect(find.text('TEST'), findsNWidgets(3));
  });

  testWidgets('no badge is invented for a row the backend did not mark',
      (tester) async {
    final stripped = _payload();
    stripped['badge'] = null;
    (stripped['fixtures'] as Map)['rows'] = [
      {'key': 'alpha', 'label': 'ALPHA FIXTURE', 'id_label': 'a-1'},
    ];
    await _pump(tester, payload: stripped);
    expect(find.text('TEST'), findsNothing,
        reason: 'a badge was drawn for a row the backend did not mark');
  });

  testWidgets('an action with no confirm fires straight away', (tester) async {
    final svc = await _pump(tester);
    await tester.tap(find.text('PAYLOAD RUN'));
    await tester.pumpAndSettle();
    expect(svc.calls, contains('act:run_full'));
    expect(find.text('PAYLOAD RUN MESSAGE'), findsOneWidget,
        reason: 'the RPC message was not shown verbatim');
  });

  testWidgets('a destructive action asks with the BACKEND sentence first',
      (tester) async {
    final svc = await _pump(tester);
    await tester.tap(find.text('PAYLOAD PURGE'));
    await tester.pumpAndSettle();

    expect(find.text('PAYLOAD PURGE CONFIRM'), findsOneWidget);
    expect(svc.calls, isNot(contains('act:purge')),
        reason: 'the purge ran before the confirmation was answered');

    // the sheet's own button carries the action's label
    await tester.tap(find.text('PAYLOAD PURGE').last);
    await tester.pumpAndSettle();
    expect(svc.calls, contains('act:purge'));
  });

  testWidgets('an action key this build has never heard of is posted verbatim',
      (tester) async {
    final svc = await _pump(tester);
    await tester.tap(find.text('PAYLOAD FUTURE'));
    await tester.pumpAndSettle();
    expect(svc.calls, contains('act:nonsense_future_action'),
        reason: 'the screen renamed, dropped or decided about an action key');
  });

  testWidgets('an action carries the payload arg it was given, unchanged',
      (tester) async {
    final withArg = _payload();
    withArg['actions'] = <dynamic>[
      ...(withArg['actions'] as List),
      <String, dynamic>{
        'key': 'session_purge',
        'label': 'PAYLOAD SESSION PURGE',
        'tone': 'danger',
        'confirm': null,
        'arg': <String, dynamic>{'session_id': '42'},
      },
    ];
    final svc = await _pump(tester, payload: withArg);
    await tester.tap(find.text('PAYLOAD SESSION PURGE'));
    await tester.pumpAndSettle();
    expect(svc.calls, contains('act:session_purge'));
    expect(svc.lastArg, equals(<String, dynamic>{'session_id': '42'}));
  });

  testWidgets('flipping the kill switch sends exactly that patch',
      (tester) async {
    final svc = await _pump(tester);
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    expect(svc.lastPatch, equals(<String, dynamic>{'enabled': false}));
  });
}
