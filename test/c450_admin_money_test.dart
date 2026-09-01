// CMD #450 — the four money surfaces and the two WhatsApp ops fixes.
//
// What this pins is the ONE property every feature_gaps row in this batch was
// filed against: the screen must not decide anything. Every rupee, age,
// plural, bucket name, tone and refusal below is a string in the fixture, and
// the test fails if Dart ever starts producing one of them itself.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/admin_money_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _home() => {
  'ok': true,
  'title': 'Money',
  'subtitle': 'What is owed, what arrived, and what is still waiting on somebody.',
  'tabs': [
    {'tab_key': 'receivables', 'label': 'Owed to us', 'badge': '₹2,80,286.88', 'badge_tone': 'bad'},
    {'tab_key': 'claims', 'label': 'To verify', 'badge': '6', 'badge_tone': 'warn'},
    {'tab_key': 'unmatched', 'label': 'Unattached money', 'badge': '1', 'badge_tone': 'bad'},
    {'tab_key': 'bills', 'label': 'Supplier bills', 'badge': '13', 'badge_tone': 'warn'},
  ],
};

Map<String, dynamic> _receivables() => {
  'ok': true,
  'headline': '₹2,80,286.88 open across 29 orders',
  'sub_headline': 'From 4 customers',
  'oldest_label': 'Oldest open order is 42 days old',
  'oldest_tone': 'bad',
  'buckets': [
    {'key': 'b30p', 'label': 'Over 30 days', 'tone': 'bad', 'value_label': '₹86,119.32', 'count_label': '8 orders'},
    {'key': 'b16_30', 'label': '16–30 days', 'tone': 'warn', 'value_label': '₹1,18,012.80', 'count_label': '10 orders'},
  ],
  'rows': [
    {
      'user_id': 'u1',
      'customer_name': 'Chandra Medicom',
      'open_label': '₹1,42,682.11',
      'order_count_label': '13 open orders',
      'age_label': 'Oldest 42 days',
      'age_tone': 'bad',
      'bucket_label': 'Over 30 days',
      'chase_label': 'Chase on WhatsApp',
      'open_orders_label': 'See the orders',
    },
  ],
  'empty_label': 'Every order that was placed has been paid for.',
};

Map<String, dynamic> _claims({bool hasUtr = false}) => {
  'ok': true,
  'headline': '6 payments waiting to be verified',
  'utr_gap_label': '6 of them have no UTR',
  'oldest_label': 'Oldest has waited 42 days',
  'oldest_tone': 'bad',
  'rows': [
    {
      'claim_id': 'c1',
      'customer_name': 'Chandra Medicom',
      'amount_label': '₹1,000.00',
      'received_label': 'Received 21 Jul, 03:16 AM',
      'age_label': '42 days old',
      'age_tone': 'bad',
      'has_utr': hasUtr,
      'utr_label': hasUtr ? 'UTR123456' : 'No UTR on this claim',
      'utr_tone': hasUtr ? 'good' : 'bad',
      'utr_detail': hasUtr ? '' : 'Without the bank reference this payment cannot be matched to the statement.',
      'can_ask_utr': !hasUtr,
      'ask_utr_label': 'Ask for the UTR',
      'link_label': 'CPO210726PAL124O1',
      'link_tone': 'muted',
    },
  ],
  'empty_label': 'Every payment that arrived has been verified.',
};

Map<String, dynamic> _unmatched({bool withCandidates = true}) => {
  'ok': true,
  'headline': '1 payment is not attached to any order',
  'no_candidate_label': 'No order this payment could belong to.',
  'rows': [
    {
      'claim_id': 'c9',
      'customer_name': 'Chandra Medicom',
      'amount_label': '₹20.81',
      'note': 'Unlinked — order was deleted; reassign to the correct order.',
      'age_label': '2 days old',
      'age_tone': 'good',
      'utr_label': 'pay_TVgro5wblT563r',
      'utr_tone': 'good',
      'attach_label': 'Attach to this order',
      'candidates': withCandidates
          ? [
              {
                'order_id': 'o1',
                'order_code': 'CPO290826CHAO1',
                'placed_label': '29 Aug, 04:45 pm',
                'total_label': '₹208.14',
                'match_label': 'Placed 0 days from the payment',
              },
            ]
          : <Map<String, dynamic>>[],
    },
  ],
  'empty_label': 'Every payment that arrived is sitting on an order.',
};

Map<String, dynamic> _bills() => {
  'ok': true,
  'headline': '13 bills waiting to be imported',
  'stalled_headline': '13 bills have been waiting over 30 days',
  'stalled_tone': 'bad',
  'buckets': [
    {'key': 'b30p', 'label': 'Over 30 days', 'tone': 'bad', 'count_label': '13 bills'},
    {'key': 'b0_7', 'label': '0–7 days', 'tone': 'good', 'count_label': '0 bills'},
  ],
  'rows': [
    {
      'bill_id': 'b1',
      'supplier_name': 'Unknown supplier',
      'file_name': 'images.png',
      'received_label': 'Arrived 03 Jun 2026',
      'age_label': '90 days old',
      'age_tone': 'bad',
      'scan_label': 'Scanned and ready to import',
      'scan_tone': 'good',
      'stalled_label': 'Stalled 90 days',
    },
  ],
  'empty_label': 'Every bill that arrived has been imported.',
};

MoneyRpc _rpcFrom(Map<String, Map<String, dynamic>> byFn, {List<String>? seen}) {
  return (fn, args) async {
    seen?.add(fn);
    return byFn[fn] ?? <String, dynamic>{'ok': true, 'rows': <Map<String, dynamic>>[]};
  };
}

Future<void> _pump(WidgetTester tester, MoneyRpc rpc) async {
  await tester.pumpWidget(MaterialApp(home: AdminMoneyScreen(rpc: rpc)));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  testWidgets('the tab list is the backend\'s, and the first tab opens', (t) async {
    final seen = <String>[];
    await _pump(t, _rpcFrom({
      'admin_money_home': _home(),
      'admin_receivables': _receivables(),
    }, seen: seen));

    for (final label in ['Owed to us', 'To verify', 'Unattached money', 'Supplier bills']) {
      expect(find.text(label), findsOneWidget, reason: 'tab $label came from the payload');
    }
    // The badges are backend strings, never counted here.
    expect(find.text('₹2,80,286.88'), findsWidgets);
    expect(find.text('13'), findsOneWidget);
    // The first tab in the payload is the one that loaded.
    expect(seen, contains('admin_receivables'));
  });

  testWidgets('an unknown tab_key renders nothing instead of throwing', (t) async {
    final home = _home();
    home['tabs'] = [
      {'tab_key': 'a_tab_this_build_has_never_heard_of', 'label': 'Tomorrow', 'badge': '', 'badge_tone': 'good'},
    ];
    final seen = <String>[];
    await _pump(t, _rpcFrom({'admin_money_home': home}, seen: seen));

    expect(find.text('Tomorrow'), findsOneWidget);
    expect(t.takeException(), isNull);
    // No RPC was invented for a tab the build does not know.
    expect(seen.where((f) => f != 'admin_money_home'), isEmpty);
  });

  testWidgets('receivables prints every rupee, age and plural verbatim', (t) async {
    await _pump(t, _rpcFrom({
      'admin_money_home': _home(),
      'admin_receivables': _receivables(),
    }));

    expect(find.text('₹2,80,286.88 open across 29 orders'), findsOneWidget);
    expect(find.text('From 4 customers'), findsOneWidget);
    expect(find.text('Chandra Medicom'), findsOneWidget);
    expect(find.text('₹1,42,682.11'), findsOneWidget);
    expect(find.text('13 open orders'), findsOneWidget);
    expect(find.text('Oldest 42 days'), findsOneWidget);
    // The buckets, with the backend's own value strings.
    expect(find.text('Over 30 days'), findsWidgets);
    expect(find.text('₹86,119.32'), findsOneWidget);
  });

  testWidgets('a missing UTR is a state with an ask; a present UTR offers neither', (t) async {
    await _pump(t, _rpcFrom({
      'admin_money_home': _home(),
      'admin_claim_queue': _claims(),
    }));
    // The tab list came from the backend; move to the claims tab.
    await t.tap(find.text('To verify'));
    await t.pumpAndSettle();

    expect(find.text('No UTR on this claim'), findsOneWidget);
    expect(find.text('42 days old'), findsOneWidget);
    expect(find.text('Ask for the UTR'), findsOneWidget);
    expect(find.text('6 of them have no UTR'), findsOneWidget);
  });

  testWidgets('can_ask_utr false hides the ask entirely', (t) async {
    await _pump(t, _rpcFrom({
      'admin_money_home': _home(),
      'admin_claim_queue': _claims(hasUtr: true),
    }));
    await t.tap(find.text('To verify'));
    await t.pumpAndSettle();

    expect(find.text('UTR123456'), findsOneWidget);
    expect(find.text('Ask for the UTR'), findsNothing);
  });

  testWidgets('attach sends the candidate the backend offered, and prints its message', (t) async {
    final calls = <List<Object?>>[];
    await _pump(t, (fn, args) async {
      calls.add([fn, args]);
      if (fn == 'admin_money_home') return _home();
      if (fn == 'admin_unmatched_payments') return _unmatched();
      if (fn == 'admin_claim_attach') {
        return {'ok': true, 'message': '₹20.81 attached to CPO290826CHAO1. It is now in the verification queue.'};
      }
      return {'ok': true, 'rows': <Map<String, dynamic>>[]};
    });
    await t.tap(find.text('Unattached money'));
    await t.pumpAndSettle();

    expect(find.text('CPO290826CHAO1'), findsOneWidget);
    await t.tap(find.text('Attach to this order'));
    await t.pumpAndSettle();

    final attach = calls.firstWhere((c) => c[0] == 'admin_claim_attach');
    expect((attach[1] as Map)['p_claim_id'], 'c9');
    expect((attach[1] as Map)['p_order_id'], 'o1');
    // The toast is the backend's sentence, not one written here.
    expect(
      find.text('₹20.81 attached to CPO290826CHAO1. It is now in the verification queue.'),
      findsOneWidget,
    );
  });

  testWidgets('no candidates renders the backend\'s explanation, not an empty gap', (t) async {
    await _pump(t, _rpcFrom({
      'admin_money_home': _home(),
      'admin_unmatched_payments': _unmatched(withCandidates: false),
    }));
    await t.tap(find.text('Unattached money'));
    await t.pumpAndSettle();

    expect(find.text('No order this payment could belong to.'), findsOneWidget);
    expect(find.text('Attach to this order'), findsNothing);
  });

  testWidgets('a stalled bill shows the backend\'s stall sentence and its scan state', (t) async {
    await _pump(t, _rpcFrom({
      'admin_money_home': _home(),
      'admin_bill_queue': _bills(),
    }));
    await t.tap(find.text('Supplier bills'));
    await t.pumpAndSettle();

    expect(find.text('13 bills have been waiting over 30 days'), findsOneWidget);
    expect(find.text('Stalled 90 days'), findsOneWidget);
    expect(find.text('90 days old'), findsOneWidget);
    expect(find.text('Scanned and ready to import'), findsOneWidget);
    // A bucket the backend sent as zero is still drawn — an empty bucket is a
    // visible zero, never a row that quietly disappeared.
    expect(find.text('0 bills'), findsOneWidget);
  });

  testWidgets('an empty list renders the backend\'s empty copy', (t) async {
    final empty = _claims();
    empty['rows'] = <Map<String, dynamic>>[];
    empty['headline'] = 'Nothing waiting to be verified';
    empty['utr_gap_label'] = '';
    empty['oldest_label'] = '';
    await _pump(t, _rpcFrom({
      'admin_money_home': _home(),
      'admin_claim_queue': empty,
    }));
    await t.tap(find.text('To verify'));
    await t.pumpAndSettle();

    expect(find.text('Every payment that arrived has been verified.'), findsOneWidget);
  });
}
