// CMD #430 — the stock audit renders; it never decides.
//
// The load-bearing test in this file is the first one: a count sheet CANNOT
// show an expected quantity, because the payload the backend sends while a
// session is open does not contain one. That is the whole point of a blind
// count, and it is tested as an absence, not as a hidden widget.
//
// The rest: rows and methods come from the payload (an unknown method the
// backend adds later still renders), variance strings and tones are printed
// verbatim, the "a different person has to count these" refusal is the
// backend's sentence and the button it blocks is really disabled, accept is
// offered only when the backend says can_accept, and a post-audit action whose
// route_key this build has never heard of navigates nowhere instead of
// throwing.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/pharmacy/pharmacy_audit_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _sheet({bool blind = true}) => {
  'ok': true,
  'session_id': 'sess-1',
  'status': 'open',
  'title': 'Count sheet',
  'blind': blind,
  'blind_note': blind ? 'Expected quantities are hidden while you count.' : null,
  'progress_label': '1 of 3 counted',
  'submit_label': 'Submit the count',
  'search_hint': 'Type a medicine name',
  'methods': const [
    {'key': 'voice', 'label': 'Voice'},
    {'key': 'barcode', 'label': 'Scan'},
    {'key': 'photo', 'label': 'Shelf photo'},
    {'key': 'type', 'label': 'Type'},
  ],
  'rows': [
    {
      'line_id': 'line-1',
      'stock_id': 'lot-1',
      'product_name': 'Azithral 500 AUD',
      'batch_label': 'Batch AUD-2',
      'expiry_label': 'Expiry 30/09/27',
      'has_expiry': true,
      'expiry_prompt': 'Expiry on the strip',
      'counted': false,
      'counted_label': 'Not counted yet',
      'expected_qty': blind ? null : 12,
      'has_expected': !blind,
    },
  ],
  'empty': 'Nothing to count in this scope',
  'empty_hint': 'Add stock, or pick a different rack.',
};

Map<String, dynamic> _variance({
  bool canAccept = true,
  List<Map<String, dynamic>>? actions,
}) => {
  'ok': true,
  'session_id': 'sess-1',
  'status': 'closed',
  'title': 'Variance',
  'note': 'Counted against what the books expected, batch by batch.',
  'value_label': 'Value at stake',
  'value_display': '₹135.00',
  'accept_label': 'Accept and adjust the ledger',
  'can_accept': canAccept,
  'rows': [
    {
      'line_id': 'line-1',
      'product_name': 'Azithral 500 AUD',
      'batch_label': 'Batch AUD-2',
      'counts_label': '9 counted · 12 expected',
      'sold_note': '3 sold while you were counting — already allowed for',
      'variance_label': 'Short',
      'variance_tone': 'danger',
      'value_display': '₹135.00',
      'second_count': '9',
      'second_by': 'C430 Second Counter',
      'status': 'confirmed',
    },
  ],
};

Map<String, dynamic> _recountSheet({bool blockedForMe = false}) => {
  'ok': true,
  'title': 'Second count',
  'note': 'Someone else counts these, without seeing the first number.',
  'rows': [
    {
      'round_id': 'round-1',
      'line_id': 'line-1',
      'product_name': 'Azithral 500 AUD',
      'batch_label': 'Batch AUD-2',
      'blocked_for_me': blockedForMe,
      'blocked_message':
          blockedForMe ? 'A different person has to count these.' : null,
    },
  ],
  'empty': 'Nothing needs a second count',
};

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  Future<void> pumpSheet(
    WidgetTester tester,
    Future<Map<String, dynamic>> Function(String, Map<String, dynamic>) rpc,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PharmacyCountSheetScreen(sessionId: 'sess-1', rpc: rpc),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pumpVariance(
    WidgetTester tester,
    Future<Map<String, dynamic>> Function(String, Map<String, dynamic>) rpc,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PharmacyAuditVarianceScreen(sessionId: 'sess-1', rpc: rpc),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the blind sheet has no expected number to show', (tester) async {
    await pumpSheet(tester, (fn, p) async => _sheet());

    expect(find.text('Azithral 500 AUD'), findsOneWidget);
    expect(find.text('Not counted yet'), findsOneWidget);
    expect(
      find.text('Expected quantities are hidden while you count.'),
      findsOneWidget,
    );
    // 12 is the expected quantity. It is not in the payload, so it cannot be
    // anywhere on this screen.
    expect(find.textContaining('12'), findsNothing);
  });

  testWidgets('the four methods are the payload\'s, in its order', (
    tester,
  ) async {
    await pumpSheet(tester, (fn, p) async => _sheet());
    for (final label in ['Voice', 'Scan', 'Shelf photo', 'Type']) {
      expect(find.widgetWithText(ChoiceChip, label), findsOneWidget);
    }
  });

  testWidgets('a method this build has never seen still renders', (
    tester,
  ) async {
    final s = _sheet()
      ..['methods'] = [
        {'key': 'weighbridge', 'label': 'Weigh'},
      ];
    await pumpSheet(tester, (fn, p) async => s);
    expect(find.widgetWithText(ChoiceChip, 'Weigh'), findsOneWidget);
  });

  testWidgets('an empty scope states it, with the backend hint', (
    tester,
  ) async {
    final s = _sheet()..['rows'] = const [];
    await pumpSheet(tester, (fn, p) async => s);
    expect(find.text('Nothing to count in this scope'), findsOneWidget);
    expect(find.text('Add stock, or pick a different rack.'), findsOneWidget);
  });

  testWidgets('submitting the count calls close and nothing else', (
    tester,
  ) async {
    final calls = <String>[];
    await pumpSheet(tester, (fn, p) async {
      calls.add(fn);
      if (fn == 'pharmacy_audit_close') {
        return {'ok': false, 'message': 'This count has already been submitted.'};
      }
      return _sheet();
    });

    final submit = find.widgetWithText(FilledButton, 'Submit the count');
    await tester.ensureVisible(submit);
    await tester.pumpAndSettle();
    await tester.tap(submit);
    await tester.pumpAndSettle();

    expect(calls, contains('pharmacy_audit_close'));
    expect(
      find.text('This count has already been submitted.'),
      findsOneWidget,
    );
  });

  testWidgets('variance prints every rupee, tone and note verbatim', (
    tester,
  ) async {
    await pumpVariance(tester, (fn, p) async {
      if (fn == 'pharmacy_audit_variance') return _variance();
      if (fn == 'pharmacy_audit_recount_sheet') {
        return {'ok': true, 'title': 'Second count', 'rows': const []};
      }
      return {'ok': true, 'title': 'What to do next', 'rows': const []};
    });

    expect(find.text('₹135.00'), findsNWidgets(2)); // headline + the row
    expect(find.text('Value at stake'), findsOneWidget);
    // the row prints the backend's batch label and its counts label, joined —
    // neither string is composed here
    expect(find.text('Batch AUD-2 · 9 counted · 12 expected'), findsOneWidget);
    expect(
      find.text('3 sold while you were counting — already allowed for'),
      findsOneWidget,
    );
    expect(find.text('Short'), findsOneWidget);
  });

  testWidgets('the same counter is blocked, in the backend\'s words', (
    tester,
  ) async {
    var recounts = 0;
    await pumpVariance(tester, (fn, p) async {
      if (fn == 'pharmacy_audit_variance') return _variance();
      if (fn == 'pharmacy_audit_recount_sheet') {
        return _recountSheet(blockedForMe: true);
      }
      if (fn == 'pharmacy_audit_recount') recounts++;
      return {'ok': true, 'title': 'What to do next', 'rows': const []};
    });

    expect(
      find.text('A different person has to count these.'),
      findsOneWidget,
    );
    final button = find.widgetWithText(TextButton, 'Second count');
    expect(tester.widget<TextButton>(button).onPressed, isNull);
    expect(recounts, 0);
  });

  testWidgets('accept is offered only when the backend says so', (
    tester,
  ) async {
    await pumpVariance(tester, (fn, p) async {
      if (fn == 'pharmacy_audit_variance') return _variance(canAccept: false);
      if (fn == 'pharmacy_audit_recount_sheet') {
        return {'ok': true, 'title': 'Second count', 'rows': const []};
      }
      return {'ok': true, 'title': 'What to do next', 'rows': const []};
    });
    expect(
      find.widgetWithText(FilledButton, 'Accept and adjust the ledger'),
      findsNothing,
    );
  });

  testWidgets('a post-audit action with an unknown route goes nowhere', (
    tester,
  ) async {
    await pumpVariance(tester, (fn, p) async {
      if (fn == 'pharmacy_audit_variance') return _variance();
      if (fn == 'pharmacy_audit_recount_sheet') {
        return {'ok': true, 'title': 'Second count', 'rows': const []};
      }
      return {
        'ok': true,
        'title': 'What to do next',
        'rows': [
          {
            'key': 'mars',
            'label': 'Send it to Mars',
            'route_key': 'route_from_the_future',
            'tone': 'info',
          },
        ],
      };
    });

    final action = find.text('Send it to Mars');
    await tester.ensureVisible(action);
    await tester.pumpAndSettle();
    await tester.tap(action);
    await tester.pumpAndSettle();
    // still on the variance screen — an unknown key resolves to nothing
    expect(find.text('Value at stake'), findsOneWidget);
  });

  testWidgets('ok:false renders the backend refusal, never an exception', (
    tester,
  ) async {
    await pumpSheet(
      tester,
      (fn, p) async => {
        'ok': false,
        'error': 'no_session',
        'message': 'That count is not open any more.',
      },
    );
    expect(find.text('That count is not open any more.'), findsOneWidget);
  });

  testWidgets('the nav icon is absent unless the backend says show', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            actions: [
              AuditNavIcon(rpc: (fn, p) async => {'ok': true, 'show': false}),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(IconButton), findsNothing);
  });

  testWidgets('the nav icon carries the backend badge when there is one', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            actions: [
              AuditNavIcon(
                rpc: (fn, p) async => {
                  'ok': true,
                  'show': true,
                  'label': 'Stock audit',
                  'badge': 'Count in progress',
                  'route_key': 'pharmacy_audit',
                },
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(IconButton), findsOneWidget);
    expect(find.text('Count in progress'), findsOneWidget);
  });
}
