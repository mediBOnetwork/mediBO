// PROTECTED — CHANGE #697.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes whole-order-feedback behaviour.
//
// What this holds down:
//
//   1. The DIMENSION LIST is the payload's, in payload order, and every label
//      is printed verbatim. The fixture is deliberately NOT the alphabetical
//      order, so a client-side sort shows up immediately. Adding, removing or
//      re-wording a dimension must stay an UPDATE on order_feedback_dimension
//      / ui_copy — never a deploy.
//
//   2. A PREFILLED dimension (today: the delivery star the rider already got,
//      so delivery_ratings and this card can never disagree) arrives SELECTED
//      and stays editable. A dimension with no prefill arrives unselected —
//      absence is never turned into a default star here.
//
//   3. The low-score CHIP STRIP appears only for a dimension at or below the
//      backend's own `low_score_at`, and disappears — dropping its selections
//      — the moment that dimension is raised above it. The threshold is read
//      from the payload; there is no 2 written in Dart.
//
//   4. Submit is blocked until EVERY dimension has a star and the NPS slider
//      has been moved, and what it hands back is exactly what was tapped:
//      dim_key -> stars, the NPS integer, the trimmed reason (null when
//      empty) and only the chips still selected.
//
//   5. The public /feedback/<token> page prints the BACKEND's refusal for an
//      expired or already-used link instead of throwing, and prints the
//      backend's thank-you sentence after a submit — including the one that
//      says a ticket was opened. There is no Dart wording on either path.
//
// Fixture mirrors public.order_feedback_form() / order_feedback_prompt().
// No network, no Supabase, no goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/customer/order_feedback_sheet.dart';
import 'package:pharma_b2b/screens/public/order_feedback_form_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

// ── fixtures ─────────────────────────────────────────────────────────────────

Map<String, dynamic> _dim(String key, String label,
        {int? prefill, List<List<String>> chips = const []}) =>
    {
      'key': key,
      'label': label,
      'prefill': prefill,
      'chips': [
        for (final c in chips) {'key': c[0], 'label': c[1]},
      ],
    };

/// Deliberately NOT alphabetical: products before packaging.
Map<String, dynamic> _card() => {
      'order_id': 'ord-1',
      'order_code': 'CPO010926CHAO1',
      'title': 'How was this order?',
      'subtitle': 'Five taps.',
      'nps_question': 'How likely are you to recommend mediBO?',
      'nps_low': 'Not at all',
      'nps_high': 'Very likely',
      'nps_min': 0,
      'nps_max': 10,
      'stars_max': 5,
      'low_score_at': 2,
      'reason_hint': 'Anything we should fix?',
      'chips_hint': 'What went wrong?',
      'submit_label': 'Send feedback',
      'skip_label': 'Not now',
      'close_label': 'Done',
      'dimensions': [
        _dim('products', 'Products'),
        _dim('packaging', 'Packaging', chips: [
          ['damaged', 'Box or strip damaged'],
          ['leaking', 'Something was leaking'],
        ]),
        _dim('delivery', 'Delivery', prefill: 4),
        _dim('ordering', 'Ordering experience'),
        _dim('support', 'Customer support'),
      ],
    };

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

/// The n-th star (1..5) of the dimension whose backend key is [key]. Keyed on
/// the payload's own dim_key, so the finder cannot drift with the wording.
Finder _star(String key, int n) => find.byKey(Key('fb_star_${key}_$n'));

Future<void> _fillAll(WidgetTester tester, {int stars = 5}) async {
  for (final key in const [
    'products',
    'packaging',
    'delivery',
    'ordering',
    'support'
  ]) {
    await tester.tap(_star(key, stars));
    await tester.pump();
  }
}

/// How many stars are lit on one dimension row.
int _lit(WidgetTester tester, String key, {int max = 5}) {
  var n = 0;
  for (var i = 1; i <= max; i++) {
    final icon = tester.widget<Icon>(
        find.descendant(of: _star(key, i), matching: find.byType(Icon)));
    if (icon.icon == Icons.star_rounded) n++;
  }
  return n;
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  // Five dimension rows, a chip strip, an NPS slider and two buttons do not
  // fit the 800x600 default surface, and a tap that lands outside the viewport
  // silently misses. Give every test a phone-width, tall surface instead.
  setUp(() {
    final v = TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher
        .views.first;
    v.physicalSize = const Size(800, 2400);
    v.devicePixelRatio = 1.0;
  });

  tearDown(() {
    final v = TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher
        .views.first;
    v.resetPhysicalSize();
    v.resetDevicePixelRatio();
    OrderFeedbackSheet.rpcTransport = null;
    OrderFeedbackFormScreen.rpcTransport = null;
  });

  testWidgets('1 · dimensions render in payload order, labels verbatim',
      (tester) async {
    await tester.pumpWidget(_host(OrderFeedbackCard(
      payload: _card(),
      onSubmit: (_) async {},
    )));

    // Every label the payload sent, printed as it arrived.
    for (final l in const [
      'Products',
      'Packaging',
      'Delivery',
      'Ordering experience',
      'Customer support'
    ]) {
      expect(find.text(l), findsOneWidget);
    }

    // …and in the payload's own order, which is NOT alphabetical.
    final ys = <double>[
      for (final l in const [
        'Products',
        'Packaging',
        'Delivery',
        'Ordering experience',
        'Customer support'
      ])
        tester.getTopLeft(find.text(l)).dy
    ];
    for (var i = 1; i < ys.length; i++) {
      expect(ys[i], greaterThan(ys[i - 1]),
          reason: 'the card re-sorted the dimensions');
    }

    // The headings are the payload's too.
    expect(find.text('How was this order?'), findsOneWidget);
    expect(find.text('How likely are you to recommend mediBO?'), findsOneWidget);
    expect(find.text('Send feedback'), findsOneWidget);
  });

  testWidgets('2 · a prefilled dimension arrives selected and stays editable',
      (tester) async {
    OrderFeedbackAnswer? sent;
    await tester.pumpWidget(_host(OrderFeedbackCard(
      payload: _card(),
      onSubmit: (a) async => sent = a,
    )));

    // Delivery came back prefilled at 4 — four filled stars on that row.
    expect(_lit(tester, 'delivery'), 4);

    // Products had no prefill: nothing is lit. Absence is not a default star.
    expect(_lit(tester, 'products'), 0);

    // The prefill is still editable — a live tap outranks it.
    await tester.tap(_star('delivery', 2));
    await tester.pump();
    expect(_lit(tester, 'delivery'), 2);

    // Finish and submit: the tapped 2 is what leaves, not the prefilled 4.
    await tester.tap(_star('products', 5));
    await tester.tap(_star('packaging', 5));
    await tester.tap(_star('ordering', 5));
    await tester.tap(_star('support', 5));
    await tester.pump();
    await tester.drag(find.byType(Slider), const Offset(500, 0));
    await tester.pump();
    await tester.tap(find.text('Send feedback'));
    await tester.pump();

    expect(sent, isNotNull);
    expect(sent!.scores['delivery'], 2);
  });

  testWidgets('3 · chips appear only at or below the payload low_score_at',
      (tester) async {
    OrderFeedbackAnswer? sent;
    await tester.pumpWidget(_host(OrderFeedbackCard(
      payload: _card(),
      onSubmit: (a) async => sent = a,
    )));

    // Nothing scored yet: no chip strip anywhere.
    expect(find.text('Box or strip damaged'), findsNothing);

    // 3 is above low_score_at (2) — still nothing.
    await tester.tap(_star('packaging', 3));
    await tester.pump();
    expect(find.text('Box or strip damaged'), findsNothing);

    // 2 is the threshold the BACKEND named — the strip appears.
    await tester.tap(_star('packaging', 2));
    await tester.pump();
    expect(find.text('What went wrong?'), findsOneWidget);
    expect(find.text('Box or strip damaged'), findsOneWidget);
    expect(find.text('Something was leaking'), findsOneWidget);

    await tester.tap(find.text('Box or strip damaged'));
    await tester.pump();

    // Raising the score past the threshold hides the strip AND drops the
    // selection — a chip cannot survive the score that justified it.
    await tester.tap(_star('packaging', 5));
    await tester.pump();
    expect(find.text('Box or strip damaged'), findsNothing);

    await tester.tap(_star('products', 5));
    await tester.tap(_star('delivery', 5));
    await tester.tap(_star('ordering', 5));
    await tester.tap(_star('support', 5));
    await tester.pump();
    await tester.drag(find.byType(Slider), const Offset(500, 0));
    await tester.pump();
    await tester.tap(find.text('Send feedback'));
    await tester.pump();

    expect(sent!.chips, isEmpty);
  });

  testWidgets('4 · submit is blocked until every star and the NPS are set',
      (tester) async {
    OrderFeedbackAnswer? sent;
    await tester.pumpWidget(_host(OrderFeedbackCard(
      payload: _card(),
      onSubmit: (a) async => sent = a,
    )));

    FilledButton button() =>
        tester.widget<FilledButton>(find.byType(FilledButton));

    // Delivery is prefilled but four rows are still blank.
    expect(button().onPressed, isNull);

    await _fillAll(tester, stars: 4);
    // Every star set, but the NPS slider has not been touched.
    expect(button().onPressed, isNull);

    await tester.drag(find.byType(Slider), const Offset(1000, 0));
    await tester.pump();
    expect(button().onPressed, isNotNull);

    await tester.tap(find.text('Send feedback'));
    await tester.pump();

    expect(sent, isNotNull);
    expect(sent!.scores, {
      'products': 4,
      'packaging': 4,
      'delivery': 4,
      'ordering': 4,
      'support': 4,
    });
    expect(sent!.nps, 10);
    // An untyped reason is omitted, never sent as an empty string.
    expect(sent!.reason, isNull);
  });

  testWidgets('5a · the public page prints the backend refusal, never throws',
      (tester) async {
    OrderFeedbackFormScreen.rpcTransport = (fn, params) async => {
          'ok': false,
          'error': 'expired',
          'title': 'Rate your mediBO order',
          'message': 'This feedback link has expired.',
        };

    await tester.pumpWidget(
        const MaterialApp(home: OrderFeedbackFormScreen(token: 'tok')));
    await tester.pumpAndSettle();

    expect(find.text('This feedback link has expired.'), findsOneWidget);
    // The card is not built at all for a refused link.
    expect(find.byType(OrderFeedbackCard), findsNothing);
  });

  testWidgets('5b · the public page submits by token and prints the thank-you',
      (tester) async {
    final calls = <String>[];
    Map<String, dynamic>? submitted;
    OrderFeedbackFormScreen.rpcTransport = (fn, params) async {
      calls.add(fn);
      if (fn == 'order_feedback_form') {
        return <String, dynamic>{'ok': true, 'intro': 'Tap a star on each row.'}
          ..addAll(_card());
      }
      submitted = params;
      return {
        'ok': true,
        'ticket_opened': true,
        'message':
            'Thank you. We have opened a ticket and your zone partner will call you back.',
      };
    };

    await tester.pumpWidget(
        const MaterialApp(home: OrderFeedbackFormScreen(token: 'tok-abc')));
    await tester.pumpAndSettle();

    // There is no "Not now" on the link page — nothing to come back to.
    expect(find.text('Not now'), findsNothing);

    await _fillAll(tester, stars: 1);
    // Right then left: the slider starts AT the minimum, so a left-only drag
    // never changes the value and the card stays (correctly) unsubmittable —
    // an untouched NPS is not a zero.
    await tester.drag(find.byType(Slider), const Offset(1000, 0));
    await tester.pump();
    await tester.drag(find.byType(Slider), const Offset(-1000, 0));
    await tester.pump();
    await tester.tap(find.text('Send feedback'));
    await tester.pumpAndSettle();

    expect(calls, ['order_feedback_form', 'order_feedback_submit_token']);
    expect(submitted!['p_token'], 'tok-abc');
    expect(submitted!['p_nps'], 0);
    expect((submitted!['p_scores'] as Map)['packaging'], 1);
    // The confirmation is the backend's sentence, printed verbatim.
    expect(
        find.text(
            'Thank you. We have opened a ticket and your zone partner will call you back.'),
        findsOneWidget);
  });
}
