// CMD #412 — the shelf-stock screen renders the backend's answer and computes
// nothing of its own.
//
// What is pinned here is the same contract the rest of the app is held to, on
// the surface where it is easiest to break: a stock screen is exactly the place
// a developer is tempted to sum a column, pluralise a word or decide that four
// is "low". Every one of those is the BACKEND's answer, and these tests fail if
// Dart starts having opinions:
//   * rupees, quantities and plurals print verbatim — the value tile shows what
//     the payload said, never a sum of the rows below it
//   * "LOW"/"OUT"/"NEGATIVE" are payload badges, not thresholds re-derived here
//   * a negative lot is drawn LOUDLY and never suppressed
//   * a refusal renders the backend's own message with no Retry — it is an
//     answer, not an outage
//   * an untouched search box is an ABSENT parameter, never an empty string
//   * the adjustment sheet submits the reason CODE the backend offered
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/pharmacy/pharmacy_stock_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _home({
  bool negative = false,
  List<Map<String, dynamic>>? rows,
}) => {
  'ok': true,
  'title': 'Shelf stock',
  'subtitle': 'Builds itself from your mediBO deliveries',
  'search_hint': 'Search a medicine or a batch',
  'tiles': [
    {'key': 'value', 'label': 'Stock value', 'value': '₹11,497.29', 'tone': 'ok'},
    {'key': 'items', 'label': 'Medicines', 'value': '14', 'tone': 'ok'},
    {'key': 'low', 'label': 'Low or out', 'value': '2', 'tone': 'warning'},
    {
      'key': 'negative',
      'label': 'Negative',
      'value': negative ? '1' : '0',
      'tone': negative ? 'danger' : 'ok',
    },
  ],
  'filters': [
    {'key': 'all', 'label': 'All', 'count': 14, 'selected': true},
    {'key': 'negative', 'label': 'Negative', 'count': negative ? 1 : 0, 'selected': false},
  ],
  'reasons': [
    {'code': 'damage', 'label': 'Damaged / broken', 'direction': 'down'},
    {'code': 'count_correction', 'label': 'Count correction', 'direction': 'both'},
  ],
  'rows': rows ??
      [
        {
          'item_key': 'm:1',
          'product_name': 'Dolo 650 Tablet',
          'pack_label': '1x15',
          'qty_label': '25 on hand',
          'value_label': '₹30.00',
          'badge': null,
          'batches': [
            {
              'stock_id': 'lot-1',
              'batch_label': 'Batch DL-77',
              'expiry_label': 'Exp 11/27',
              'qty_label': '25',
              'qty': 25,
              'cost_label': '₹1.20 / unit',
              'value_label': '₹30.00',
              'state': 'ok',
              'tone': 'ok',
              'state_label': null,
              'source_label': 'From a mediBO delivery',
            },
          ],
        },
      ],
  'has_more': false,
  'negative_note': negative
      ? '1 batch went negative — the counter sold stock this list did not know you had.'
      : null,
  'empty': null,
  'copy': {
    'add_button': 'Add purchase',
    'import_button': 'Opening stock',
    'adjust_title': 'Adjust this batch',
    'adjust_qty': 'Counted quantity',
    'adjust_reason': 'Reason',
    'adjust_note': 'Note (optional)',
    'save': 'Save',
    'saving': 'Saving…',
    'retry': 'Retry',
    'error_generic': 'Could not load shelf stock.',
  },
};

final _negRow = {
  'item_key': 'm:2',
  'product_name': 'Paracad Injection',
  'pack_label': '1x1',
  'qty_label': '-12 on hand',
  'value_label': '₹0.00',
  'badge': {'label': 'NEGATIVE', 'tone': 'danger'},
  'batches': [
    {
      'stock_id': 'lot-neg',
      'batch_label': 'Batch not on the bill',
      'expiry_label': 'Expiry not recorded',
      'qty_label': '-12',
      'qty': -12,
      'cost_label': 'Cost not known',
      'value_label': '₹0.00',
      'state': 'negative',
      'tone': 'danger',
      'state_label': 'Sold more than the shelf knew about',
      'source_label': 'Adjusted',
    },
  ],
};

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  Future<List<List<Object?>>> pump(
    WidgetTester tester,
    Map<String, dynamic> Function(String fn, Map<String, dynamic> p) answer,
  ) async {
    final calls = <List<Object?>>[];
    await tester.pumpWidget(
      MaterialApp(
        home: PharmacyStockScreen(
          rpc: (fn, p) async {
            calls.add([fn, p]);
            return answer(fn, p);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    return calls;
  }

  testWidgets('every number on the screen is the backend\'s string', (t) async {
    await pump(t, (fn, p) => _home());

    // The value tile is the payload's own total. If Dart ever starts summing
    // the rows this would read ₹30.00 and the test would go red.
    expect(find.text('₹11,497.29'), findsOneWidget);
    expect(find.text('Stock value'), findsOneWidget);
    expect(find.text('25 on hand'), findsOneWidget);
    expect(find.textContaining('₹1.20 / unit'), findsOneWidget);
    expect(find.text('Batch DL-77'), findsOneWidget);
    expect(find.textContaining('Exp 11/27'), findsOneWidget);
  });

  testWidgets('a negative lot is badged and shouted about, never hidden', (t) async {
    await pump(t, (fn, p) => _home(negative: true, rows: [_negRow]));

    expect(find.text('NEGATIVE'), findsOneWidget);
    expect(find.text('-12'), findsOneWidget);
    expect(find.text('Sold more than the shelf knew about'), findsOneWidget);
    expect(
      find.textContaining('1 batch went negative'),
      findsOneWidget,
      reason: 'the backend sent a note about negative stock; it must be shown',
    );
  });

  testWidgets('the badge is the payload\'s, not a threshold re-derived here', (t) async {
    // 4 units with NO badge in the payload: a screen that decided "low" for
    // itself would draw one anyway.
    final quiet = Map<String, dynamic>.from(_home());
    quiet['rows'] = [
      {
        'item_key': 'm:9',
        'product_name': 'Azithral 500',
        'pack_label': '1x5',
        'qty_label': '4 on hand',
        'value_label': '₹232.00',
        'badge': null,
        'batches': const [],
      },
    ];
    await pump(t, (fn, p) => quiet);

    expect(find.text('4 on hand'), findsOneWidget);
    expect(find.text('LOW'), findsNothing);
    expect(find.text('OUT'), findsNothing);
  });

  testWidgets('a refusal shows the backend message and offers no Retry', (t) async {
    await pump(t, (fn, p) => {
      'ok': false,
      'error': 'not_a_pharmacy',
      'message': 'Shelf stock is for a pharmacy account.',
    });

    expect(find.text('Shelf stock is for a pharmacy account.'), findsOneWidget);
    expect(
      find.text('Retry'),
      findsNothing,
      reason: 'a role refusal is an answer, not an outage — retrying changes nothing',
    );
  });

  testWidgets('an untouched search box is an absent parameter', (t) async {
    final calls = await pump(t, (fn, p) => _home());

    final home = calls.firstWhere((c) => c[0] == 'pharmacy_stock_home');
    final params = home[1] as Map<String, dynamic>;
    expect(
      params.containsKey('p_q'),
      isFalse,
      reason: 'an empty search must be omitted, never sent as an empty string',
    );
    expect(params['p_filter'], 'all');
  });

  testWidgets('a filter chip sends the backend\'s own key', (t) async {
    final calls = await pump(t, (fn, p) => _home(negative: true, rows: [_negRow]));
    calls.clear();

    await t.tap(find.textContaining('Negative').last);
    await t.pumpAndSettle();

    final home = calls.firstWhere((c) => c[0] == 'pharmacy_stock_home');
    expect((home[1] as Map<String, dynamic>)['p_filter'], 'negative');
  });

  testWidgets('an adjustment submits the reason CODE the backend offered', (t) async {
    final calls = <List<Object?>>[];
    await t.pumpWidget(
      MaterialApp(
        home: PharmacyStockScreen(
          rpc: (fn, p) async {
            calls.add([fn, p]);
            if (fn == 'pharmacy_stock_moves') {
              return {
                'ok': true,
                'title': 'Batch history',
                'rows': [
                  {
                    'id': 1,
                    'kind_label': 'mediBO delivery',
                    'qty_label': '+25',
                    'tone': 'ok',
                    'after_label': '25 left',
                    'actor': 'Test Owner',
                    'when': '01 Sep 2026, 09:10 AM',
                  },
                ],
                'empty': null,
              };
            }
            if (fn == 'pharmacy_stock_adjust') {
              return {'ok': true, 'message': 'Stock corrected'};
            }
            return _home();
          },
        ),
      ),
    );
    await t.pumpAndSettle();

    await t.tap(find.text('Batch DL-77'));
    await t.pumpAndSettle();

    // The history is the audit trail, rendered verbatim including the actor.
    expect(find.text('mediBO delivery'), findsOneWidget);
    expect(find.textContaining('Test Owner'), findsOneWidget);
    expect(find.text('25 left'), findsOneWidget);

    await t.enterText(
      find
          .descendant(
            of: find.byType(BottomSheet),
            matching: find.byType(TextField),
          )
          .first,
      '20',
    );
    await t.tap(find.text('Reason'));
    await t.pumpAndSettle();
    await t.tap(find.text('Damaged / broken').last);
    await t.pumpAndSettle();
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();

    final adj = calls.firstWhere((c) => c[0] == 'pharmacy_stock_adjust');
    final params = adj[1] as Map<String, dynamic>;
    expect(params['p_reason'], 'damage');
    expect(params['p_new_qty'], 20);
    expect(params['p_stock_id'], 'lot-1');
  });
}
