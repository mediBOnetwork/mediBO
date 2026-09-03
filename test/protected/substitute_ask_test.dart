// PROTECTED — CHANGE #698, the substitute offer for an unfulfilled line.
//
// What this file holds down is the ONE widget the in-app order card and the
// public /substitute-ask/<token> page both render, and the promise that it
// computes nothing:
//
//   * every sentence — title, note, both button labels, the countdown, the
//     "always accept" line, each option's rank label — is printed VERBATIM
//     from the payload. The fixture's countdown deliberately disagrees with
//     its deadline_at, so a client-side clock fails this test;
//   * options render in PAYLOAD order (the fixture is deliberately not
//     alphabetical) and that order is the ranking;
//   * `selected:true` arrives pre-ticked (the customer's own "always accept Y
//     for salt S") AND stays editable — a tick is a default, never a decision;
//   * the submit posts the ids in TAP order, because that order IS the
//     customer's ranking, and it posts nothing at all until one is ticked;
//   * an untouched option is simply absent from the submit — never defaulted;
//   * a refusal renders the BACKEND's message with no Dart fallback wording;
//   * a closed / applied / timed-out ask draws the backend's copy instead of
//     the picker.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/substitute_ask_card.dart';
import 'package:pharma_b2b/screens/public/substitute_ask_screen.dart';

Map<String, dynamic> _openAsk() => {
      'ok': true,
      'ask_id': 41,
      'token': 'tok-698',
      'status': 'asked',
      'state': 'open',
      'is_open': true,
      'order_label': 'Order MB-9001',
      'product_name': 'Olmigo 40mg Tablet',
      'title': 'Olmigo 40mg Tablet is not available',
      'note': 'Tick the ones you accept. We will try them in the order you put them.',
      // Deliberately at odds with deadline_at: the sentence is the backend's,
      // and nothing here is allowed to recompute it from a clock.
      'countdown_label': '07:24 left to answer',
      'deadline_at': '2020-01-01T00:00:00+00:00',
      'seconds_left': 444,
      'submit_label': 'Try these',
      'submit_empty_label': 'Tick at least one',
      'skip_label': 'Skip — ship without it',
      'remember_label': 'Always accept this for Olmesartan Medoxomil (40mg)',
      'remember': false,
      'empty_label': 'We could not find an equal substitute for this item.',
      'options': [
        {
          'product_id': 260981,
          'name': 'Zylmy 40 Tablet',
          'company': 'ZYDUS CADILA',
          'strength': 'Olmesartan Medoxomil (40mg)',
          'pack_label': '10 tablets in 1 strip',
          'rank': 1,
          'rank_label': 'Choice 1',
          'selected': false,
          'bought_before': true,
        },
        {
          'product_id': 480069,
          'name': 'Almetor 40 Tablet',
          'company': 'TORRENT PHARMACEUTICALS LTD',
          'strength': 'Olmesartan Medoxomil (40mg)',
          'pack_label': '10 tablets in 1 strip',
          'rank': 2,
          'rank_label': 'Choice 2',
          'selected': false,
          'bought_before': false,
        },
        {
          'product_id': 178602,
          'name': 'Bolmesar 40 Tablet',
          'company': 'MACLEODS PHARMACEUTICALS PVT LTD',
          'strength': 'Olmesartan Medoxomil (40mg)',
          'pack_label': '15 tablets in 1 strip',
          'rank': 3,
          'rank_label': 'Choice 3',
          'selected': false,
          'bought_before': false,
        },
      ],
    };

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  // A tall surface, so the whole card lays out and every option is tappable.
  // The real surfaces both scroll; the 800x600 test window does not.
  setUp(() {
    final v = TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher
        .views.first;
    v.physicalSize = const Size(900, 2400);
    v.devicePixelRatio = 1.0;
  });
  tearDown(() {
    SubstituteAskCard.rpcTransport = null;
    final v = TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher
        .views.first;
    v.resetPhysicalSize();
    v.resetDevicePixelRatio();
  });

  testWidgets('every sentence is the payload, printed verbatim', (t) async {
    await t.pumpWidget(_host(SubstituteAskCard(ask: _openAsk())));
    await t.pump();

    expect(find.text('Order MB-9001'), findsOneWidget);
    expect(find.text('Olmigo 40mg Tablet is not available'), findsOneWidget);
    expect(find.text('07:24 left to answer'), findsOneWidget);
    expect(find.text('Skip — ship without it'), findsOneWidget);
    expect(find.text('Always accept this for Olmesartan Medoxomil (40mg)'),
        findsOneWidget);
    // Nothing is ticked, so the button wears the backend's EMPTY label — the
    // widget never writes "Select an option" of its own.
    expect(find.text('Tick at least one'), findsOneWidget);
    expect(find.text('Try these'), findsNothing);
  });

  testWidgets('options render in payload order, not alphabetically', (t) async {
    await t.pumpWidget(_host(SubstituteAskCard(ask: _openAsk())));
    await t.pump();

    final names = t
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.data ?? '')
        .where((s) => s.endsWith('40 Tablet'))
        .toList();
    expect(names, ['Zylmy 40 Tablet', 'Almetor 40 Tablet', 'Bolmesar 40 Tablet']);
  });

  testWidgets('submit posts the TAP order and only what was ticked',
      (t) async {
    Map<String, dynamic>? sent;
    String? fn;
    SubstituteAskCard.rpcTransport = (f, p) async {
      fn = f;
      sent = p;
      return {'ok': true};
    };

    await t.pumpWidget(_host(SubstituteAskCard(ask: _openAsk())));
    await t.pump();

    // Third first, then first. The ranking is the order of the fingers, and
    // the untouched middle option must simply be absent.
    await t.tap(find.text('Bolmesar 40 Tablet'));
    await t.pump();
    await t.tap(find.text('Zylmy 40 Tablet'));
    await t.pump();

    expect(find.text('Try these'), findsOneWidget);
    await t.tap(find.text('Try these'));
    await t.pump();

    expect(fn, 'substitute_ask_submit');
    expect(sent!['p_token'], 'tok-698');
    expect(sent!['p_product_ids'], [178602, 260981]);
    expect(sent!['p_remember'], false);
  });

  testWidgets('a pre-ticked option is the backend\'s, and stays editable',
      (t) async {
    final ask = _openAsk();
    (ask['options'] as List)[1]['selected'] = true;
    ask['remember'] = true;

    Map<String, dynamic>? sent;
    SubstituteAskCard.rpcTransport = (f, p) async {
      sent = p;
      return {'ok': true};
    };

    await t.pumpWidget(_host(SubstituteAskCard(ask: ask)));
    await t.pump();

    // It arrived ticked without a tap.
    expect(find.text('Try these'), findsOneWidget);

    // ...and untapping it is allowed: a remembered preference is a default.
    await t.tap(find.text('Almetor 40 Tablet'));
    await t.pump();
    expect(find.text('Tick at least one'), findsOneWidget);

    await t.tap(find.text('Almetor 40 Tablet'));
    await t.pump();
    await t.tap(find.text('Try these'));
    await t.pump();
    expect(sent!['p_product_ids'], [480069]);
    expect(sent!['p_remember'], true);
  });

  testWidgets('skip sends the skip RPC and never a submit', (t) async {
    final calls = <String>[];
    SubstituteAskCard.rpcTransport = (f, p) async {
      calls.add(f);
      return {'ok': true, 'title': 'Noted — we will ship without it'};
    };

    await t.pumpWidget(_host(SubstituteAskCard(ask: _openAsk())));
    await t.pump();
    await t.tap(find.text('Skip — ship without it'));
    await t.pump();

    expect(calls, ['substitute_ask_skip']);
  });

  testWidgets('a refusal shows the BACKEND message, with no Dart wording',
      (t) async {
    SubstituteAskCard.rpcTransport = (f, p) async => {
          'ok': false,
          'error': 'expired',
          'message': 'The 10 minutes ran out',
        };

    await t.pumpWidget(_host(SubstituteAskCard(ask: _openAsk())));
    await t.pump();
    await t.tap(find.text('Zylmy 40 Tablet'));
    await t.pump();
    await t.tap(find.text('Try these'));
    await t.pump();

    expect(find.text('The 10 minutes ran out'), findsOneWidget);
    expect(find.text('expired'), findsNothing);
  });

  testWidgets('a closed ask draws the backend copy instead of the picker',
      (t) async {
    SubstituteAskCard.rpcTransport = (f, p) async => {
          'ok': true,
          'ask_id': 41,
          'token': 'tok-698',
          'status': 'timeout',
          'state': 'timeout',
          'is_open': false,
          'title': 'The 10 minutes ran out',
          'note': 'We shipped without this item so the rest was not held up.',
          'options': const [],
        };

    await t.pumpWidget(_host(const SubstituteAskScreen(token: 'tok-698')));
    await t.pump();
    await t.pump();

    expect(find.text('The 10 minutes ran out'), findsOneWidget);
    expect(find.text('We shipped without this item so the rest was not held up.'),
        findsOneWidget);
    expect(find.byType(SubstituteAskCard), findsNothing);
  });

  testWidgets('an unknown token renders the backend refusal, never a throw',
      (t) async {
    SubstituteAskCard.rpcTransport = (f, p) async => {
          'ok': false,
          'error': 'substitute_ask_not_found',
          'title': 'We could not find this offer',
          'message': 'The link may be old. Open the order in the mediBO app.',
        };

    await t.pumpWidget(_host(const SubstituteAskScreen(token: 'nope')));
    await t.pump();
    await t.pump();

    expect(find.text('We could not find this offer'), findsOneWidget);
    expect(find.text('The link may be old. Open the order in the mediBO app.'),
        findsOneWidget);
  });
}
