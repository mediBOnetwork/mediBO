// CMD #425 — the expiry radar renders; it never decides.
//
// What these tests hold down, in the order the money moves:
//   * the headline, every rupee and every "likely ~4 left" print VERBATIM —
//     there is no currency format, no plural rule and no ranking in Dart, so a
//     payload that says '₹1,729.80' shows exactly that;
//   * items appear in PAYLOAD ORDER (the fixture is deliberately not sorted by
//     value) — the backend already ranked them by expected loss;
//   * a correction's numbers are the payload's `options` — the same list the
//     WhatsApp quick replies carry — and tapping one sends that number and no
//     other to pharmacy_radar_answer;
//   * a lot that already has an open ask does not offer a second way to raise
//     one;
//   * the WhatsApp opt-in sends the OPPOSITE of the flag the backend sent, and
//     a shop with no number is refused with the backend's own sentence;
//   * ok:false renders the backend's refusal instead of throwing;
//   * the entry card is absent unless the backend says show:true.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/pharmacy/pharmacy_radar_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _home({
  bool optIn = false,
  bool canEnable = true,
  List<Map<String, dynamic>>? items,
  List<Map<String, dynamic>>? asks,
}) => {
  'ok': true,
  'title': 'Expiry radar',
  'subtitle': 'Ranked by what it will actually cost you.',
  'headline': '₹1,729.80 likely to expire unsold',
  'headline_note': '1 batches on the radar · at your purchase cost',
  'list_title': 'Worst first',
  'items': items ?? [_item()],
  'empty': 'No batch is at risk right now',
  'empty_hint': 'Forward your purchase bills on WhatsApp.',
  'asks_title': 'Quick check',
  'asks_note': 'One tap keeps the estimate honest.',
  'asks': asks ?? const [],
  'asks_empty': 'Nothing to confirm right now',
  'digest': {
    'title': 'This month',
    'rows': [
      {'label': 'Bills captured', 'value': '3'},
      {'label': 'Stock value', 'value': '₹12,480.00'},
    ],
  },
  'optin': {
    'title': 'Get this on WhatsApp',
    'body': 'No more than 3 messages a week.',
    'on': optIn,
    'state_label': optIn ? 'WhatsApp alerts are on' : 'WhatsApp alerts are off',
    'button': optIn ? 'Turn off' : 'Turn on WhatsApp alerts',
    'can_enable': canEnable,
    'blocked_message': canEnable
        ? null
        : 'Add a WhatsApp number to your profile first.',
  },
  'intake': {
    'title': 'Bills by WhatsApp',
    'body': 'Forward any purchase bill photo to mediBO.',
    'count_label': '2 bills arrived this way',
    'on': true,
  },
};

Map<String, dynamic> _item({
  String name = 'Montikop 10 Tablets',
  String value = '₹1,729.80',
  Map<String, dynamic>? ask,
}) => {
  'stock_id': 'lot-$name',
  'product_name': name,
  'value_display': value,
  'value_caption': 'Expected loss',
  'qty_label': 'likely ~10 left',
  'basis_label': 'Estimated from your purchases',
  'expiry_label': 'Expires 10/10/26',
  'batch_label': 'Batch JAN-425',
  'supplier_label': 'SAI GANESH PHARMA',
  'window_label': 'Return window has closed',
  'window_tone': 'danger',
  'ask': ask,
};

Map<String, dynamic> _ask() => {
  'ask_id': 'ask-1',
  'stock_id': 'lot-Montikop 10 Tablets',
  'question': 'Montikop 10 Tablets — Batch JAN-425 expires 10/10/26. '
      'We think ~10 left. How many actually?',
  'options': [
    {'value': 0, 'label': '0'},
    {'value': 5, 'label': '5'},
    {'value': 10, 'label': '10'},
  ],
  'other_label': 'Other',
  'other_hint': 'Type the number',
  'status': 'open',
};

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  Future<void> pump(
    WidgetTester tester,
    Future<Map<String, dynamic>> Function(String, Map<String, dynamic>) rpc,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: PharmacyRadarScreen(rpc: rpc)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('every rupee and every quantity is the backend string', (
    tester,
  ) async {
    await pump(tester, (fn, p) async => _home());

    expect(find.text('₹1,729.80 likely to expire unsold'), findsOneWidget);
    expect(find.text('₹1,729.80'), findsOneWidget);
    expect(find.text('Expected loss'), findsOneWidget);
    expect(find.text('likely ~10 left · Estimated from your purchases'),
        findsOneWidget);
    expect(find.text('Return window has closed'), findsOneWidget);
    // the month card prints the backend's own figures too
    expect(find.text('₹12,480.00'), findsOneWidget);
  });

  testWidgets('items keep payload order — the backend already ranked them', (
    tester,
  ) async {
    await pump(
      tester,
      (fn, p) async => _home(
        items: [
          _item(name: 'Cheap first', value: '₹40.00'),
          _item(name: 'Dear second', value: '₹1,800.00'),
        ],
      ),
    );

    final first = tester.getTopLeft(find.text('Cheap first'));
    final second = tester.getTopLeft(find.text('Dear second'));
    expect(first.dy, lessThan(second.dy));
  });

  testWidgets('a quick-reply option sends exactly the number it printed', (
    tester,
  ) async {
    final calls = <List<Object?>>[];
    await pump(tester, (fn, p) async {
      calls.add([fn, p]);
      if (fn == 'pharmacy_radar_answer') {
        return {'ok': true, 'message': 'Saved — 5 left on Montikop.'};
      }
      return _home(asks: [_ask()]);
    });

    expect(find.textContaining('How many actually?'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, '5'));
    await tester.pumpAndSettle();

    final answer = calls.firstWhere((c) => c[0] == 'pharmacy_radar_answer');
    final params = answer[1] as Map<String, dynamic>;
    expect(params['p_ask_id'], 'ask-1');
    expect(params['p_qty'], 5);
    expect(find.text('Saved — 5 left on Montikop.'), findsOneWidget);
  });

  testWidgets('an option this build has never seen is still offered verbatim', (
    tester,
  ) async {
    final sent = <num>[];
    final ask = _ask()
      ..['options'] = [
        {'value': 3, 'label': '3'},
        {'value': 7, 'label': '7'},
      ];
    await pump(tester, (fn, p) async {
      if (fn == 'pharmacy_radar_answer') {
        sent.add(p['p_qty'] as num);
        return {'ok': true, 'message': 'ok'};
      }
      return _home(asks: [ask]);
    });

    expect(find.widgetWithText(OutlinedButton, '3'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '7'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '0'), findsNothing);
    await tester.tap(find.widgetWithText(OutlinedButton, '7'));
    await tester.pumpAndSettle();
    expect(sent, [7]);
  });

  testWidgets('a lot that already carries an ask offers no second way in', (
    tester,
  ) async {
    await pump(
      tester,
      (fn, p) async => _home(items: [_item(ask: _ask())], asks: [_ask()]),
    );
    // 'Quick check' is the section heading; it must NOT also be a row action.
    expect(find.widgetWithText(TextButton, 'Quick check'), findsNothing);
  });

  testWidgets('a lot with no ask offers one, and it raises the ask', (
    tester,
  ) async {
    final calls = <String>[];
    await pump(tester, (fn, p) async {
      calls.add(fn);
      if (fn == 'pharmacy_radar_ask_open') {
        return {'ok': true, 'ask': _ask()};
      }
      return _home();
    });

    await tester.tap(find.widgetWithText(TextButton, 'Quick check'));
    await tester.pumpAndSettle();
    expect(calls, contains('pharmacy_radar_ask_open'));
  });

  testWidgets('the opt-in sends the opposite of the flag it was given', (
    tester,
  ) async {
    Map<String, dynamic>? patch;
    await pump(tester, (fn, p) async {
      if (fn == 'pharmacy_radar_config_set') {
        patch = Map<String, dynamic>.from(p['p_patch'] as Map);
        return _home(optIn: true);
      }
      return _home();
    });

    expect(find.text('WhatsApp alerts are off'), findsOneWidget);
    final button =
        find.widgetWithText(FilledButton, 'Turn on WhatsApp alerts');
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(patch, {'opt_in': true});
    expect(find.text('WhatsApp alerts are on'), findsOneWidget);
  });

  testWidgets('no WhatsApp number: the backend refuses, in its own words', (
    tester,
  ) async {
    var configCalls = 0;
    await pump(tester, (fn, p) async {
      if (fn == 'pharmacy_radar_config_set') configCalls++;
      return _home(canEnable: false);
    });

    final blocked =
        find.widgetWithText(FilledButton, 'Turn on WhatsApp alerts');
    await tester.ensureVisible(blocked);
    await tester.pumpAndSettle();
    await tester.tap(blocked);
    await tester.pumpAndSettle();
    expect(configCalls, 0);
    expect(
      find.text('Add a WhatsApp number to your profile first.'),
      findsOneWidget,
    );
  });

  testWidgets('ok:false renders the backend refusal, never an exception', (
    tester,
  ) async {
    await pump(
      tester,
      (fn, p) async => {
        'ok': false,
        'error': 'not_a_pharmacy',
        'message': 'This screen is for a pharmacy account.',
      },
    );
    expect(find.text('This screen is for a pharmacy account.'), findsOneWidget);
    expect(find.text('Worst first'), findsNothing);
  });

  testWidgets('an empty radar states it, with the backend hint', (
    tester,
  ) async {
    await pump(tester, (fn, p) async => _home(items: const []));
    expect(find.text('No batch is at risk right now'), findsOneWidget);
    expect(
      find.text('Forward your purchase bills on WhatsApp.'),
      findsOneWidget,
    );
  });

  testWidgets('the entry card is absent unless the backend says show', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RadarEntryCard(rpc: (fn, p) async => {'ok': true, 'show': false}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(InkWell), findsNothing);
  });

  testWidgets('the entry card prints label, sub-label and badge verbatim', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RadarEntryCard(
            rpc: (fn, p) async => {
              'ok': true,
              'show': true,
              'label': 'Expiry radar',
              'sub_label': 'Ranked by the money you are about to lose',
              'badge': '₹1,729.80',
              'route_key': 'pharmacy_radar',
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Expiry radar'), findsOneWidget);
    expect(find.text('Ranked by the money you are about to lose'),
        findsOneWidget);
    expect(find.text('₹1,729.80'), findsOneWidget);
  });
}
