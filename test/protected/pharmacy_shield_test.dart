// CMD #413 — the expiry watch and the stock check compute NOTHING.
//
// What this holds down, permanently:
//   * every rupee, every plural, every "closes in 3 days", every tone and every
//     refusal sentence is printed verbatim from the payload — the fixtures
//     deliberately carry impossible numbers ('₹9,99,999.00' next to a qty of 2)
//     so a Dart-side recomputation would be visible instantly;
//   * the count sheet shows NO expected number while it is open, because a
//     count you can see the answer to is a copy, not a count;
//   * a line the owner left blank is OMITTED from the submit, never defaulted
//     to zero — "I did not count it" and "I counted zero" are different facts;
//   * the owner-only refusal is the BACKEND's message and carries no Retry: a
//     role refusal is an answer, and offering to ask it again would be a lie;
//   * the entry tiles are exactly the tiles the backend sent — a staff login
//     never receives the stock-check tile, so the widget never tests a role;
//   * an unknown route_key resolves to nothing instead of throwing.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/design_tokens.dart';
import 'package:pharma_b2b/screens/pharmacy/pharmacy_expiry_screen.dart';
import 'package:pharma_b2b/screens/pharmacy/pharmacy_variance_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _homePayload() => {
  'ok': true,
  'title': 'Expiry watch',
  'headline': '₹9,99,999.00 of your stock expires within 90 days',
  'cost_note': 'Valued at what you paid, not at MRP',
  'window_title': 'Return windows closing',
  'window_note': 'A supplier takes expiring stock back before it expires.',
  'window_empty': 'No supplier return window closes soon.',
  'build_button': 'Build return list',
  'buckets': [
    {
      'bucket_key': 'expired',
      'label': 'Already expired',
      'count_label': 'Nothing',
      'value_display': '₹0.00',
      'has': false,
      'tone': 'danger',
    },
    {
      'bucket_key': 'd30',
      'label': 'Within 30 days',
      'count_label': '1 item',
      'value_display': '₹1,680.00',
      'has': true,
      'tone': 'danger',
    },
    {
      'bucket_key': 'd60',
      'label': '31 to 60 days',
      'count_label': '12 items',
      'value_display': '₹1,416.00',
      'has': true,
      'tone': 'warning',
    },
  ],
  'windows': [
    {
      'product_name': 'Azimax 100 Dry Syrup',
      'supplier_label': 'Local Agency',
      'qty_label': '12 bottles',
      'value_display': '₹1,416.00',
      'closes_label': 'Return window closes in 3 days',
      'tone': 'danger',
    },
  ],
};

Map<String, dynamic> _openSheet() => {
  'ok': true,
  'session_id': 'sess-1',
  'is_open': true,
  'title': 'Count these',
  'hint': 'Count what is physically on the shelf.',
  'submit_button': 'Submit count',
  'submitting': 'Saving the count…',
  'labels': {
    'counted': 'Counted',
    'expected': 'Expected',
    'opening': 'Opening',
    'received': 'Received',
    'sold': 'Sold',
    'variance': 'Difference',
  },
  'staff': const [],
  'lines': [
    {
      'line_id': 'l1',
      'product_name': 'Dolo 650mg Tablet',
      'pack_label': 'Strip of 15',
      'unit': 'strips',
      'has_expected': false,
      'expected_label': null,
      'counted_label': null,
    },
    {
      'line_id': 'l2',
      'product_name': 'Azimax 100 Dry Syrup',
      'pack_label': 'Bottle',
      'unit': 'bottles',
      'has_expected': false,
      'expected_label': null,
      'counted_label': null,
    },
  ],
};

Map<String, dynamic> _submittedSheet() => {
  'ok': true,
  'session_id': 'sess-1',
  'is_open': false,
  'title': 'Stock check',
  'toast': 'Count saved',
  'leaked_label': 'Value of the difference',
  'leaked_display': '₹938.40',
  'all_matched': false,
  'clean_message': 'Every item counted this week matched.',
  'cause_note': 'The commonest reason for a short count is a sale that '
      'was never billed.',
  'staff_title': 'By shift',
  'staff_note': 'A shift carries the share of a difference that matches '
      'the share it sold.',
  'labels': {
    'counted': 'Counted',
    'expected': 'Expected',
    'opening': 'Opening',
    'received': 'Received',
    'sold': 'Sold',
    'variance': 'Difference',
  },
  'staff': [
    {
      'staff_label': 'Rajesh Kumar Sahu',
      'variance_label': '-4',
      'value_display': '₹47.00',
    },
  ],
  'lines': [
    {
      'line_id': 'l1',
      'product_name': 'Dolo 650mg Tablet',
      'unit': 'strips',
      'has_expected': true,
      'opening_label': '47',
      'received_label': '0',
      'sold_label': '7',
      'expected_label': '40',
      'counted_label': '26',
      'variance_label': '-14',
      'variance_value_display': '₹142.40',
      'state_label': 'Short',
      'tone': 'danger',
    },
  ],
};

Future<void> _pump(WidgetTester t, Widget child) async {
  await t.pumpWidget(MaterialApp(home: child));
  await t.pumpAndSettle();
}

/// The tiles are a menu fragment, not a screen — they are drawn inside somebody
/// else's sheet, so the test gives them the Material ancestor that sheet is.
Future<void> _pumpTiles(WidgetTester t, Widget child) async {
  await t.pumpWidget(
    MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child))),
  );
  await t.pumpAndSettle();
}

void main() {
  setUpAll(() {
    RenderLog.flushEnabled = false;
    Ds.apply(const {});
  });

  group('expiry watch renders the payload and nothing else', () {
    testWidgets('the headline rupee string is printed verbatim', (t) async {
      await _pump(
        t,
        PharmacyExpiryScreen(
          rpc: (fn, p) async => _homePayload(),
        ),
      );
      // The fixture's number is impossible for its own bucket values on
      // purpose: if this string were recomputed in Dart it could not survive.
      expect(
        find.text('₹9,99,999.00 of your stock expires within 90 days'),
        findsOneWidget,
      );
      expect(find.text('Valued at what you paid, not at MRP'), findsOneWidget);
    });

    testWidgets('plurals come from the payload, never from a count', (t) async {
      await _pump(
        t,
        PharmacyExpiryScreen(rpc: (fn, p) async => _homePayload()),
      );
      expect(find.text('1 item'), findsOneWidget);
      expect(find.text('12 items'), findsOneWidget);
      // The empty bucket keeps the backend's word for zero.
      expect(find.text('Nothing'), findsOneWidget);
    });

    testWidgets('a closing window prints the backend sentence', (t) async {
      await _pump(
        t,
        PharmacyExpiryScreen(rpc: (fn, p) async => _homePayload()),
      );
      expect(find.text('Return window closes in 3 days'), findsOneWidget);
    });

    testWidgets('an ok:false boot renders the message with no Retry', (
      t,
    ) async {
      await _pump(
        t,
        PharmacyExpiryScreen(
          rpc: (fn, p) async => {
            'ok': false,
            'error': 'not_a_pharmacy',
            'message': 'Expiry watch is available on a pharmacy account.',
          },
        ),
      );
      expect(
        find.text('Expiry watch is available on a pharmacy account.'),
        findsOneWidget,
      );
      expect(find.byType(OutlinedButton), findsNothing);
    });
  });

  group('the count sheet', () {
    testWidgets('shows no expected number while it is open', (t) async {
      await _pump(
        t,
        PharmacyCountSheetScreen(
          session: _openSheet(),
          rpc: (fn, p) async => _openSheet(),
        ),
      );
      expect(find.text('Dolo 650mg Tablet'), findsOneWidget);
      expect(find.text('Expected'), findsNothing);
      expect(find.byType(TextField), findsNWidgets(2));
    });

    testWidgets('submits only the lines that were answered', (t) async {
      List<Map<String, dynamic>> sent = const [];
      await _pump(
        t,
        PharmacyCountSheetScreen(
          session: _openSheet(),
          rpc: (fn, p) async {
            if (fn == 'pharmacy_count_submit') {
              sent = (p['p_lines'] as List)
                  .map((e) => Map<String, dynamic>.from(e as Map))
                  .toList();
              return _submittedSheet();
            }
            return {'ok': true};
          },
        ),
      );
      // Answer the FIRST line only. The second is left untouched.
      await t.enterText(find.byType(TextField).first, '26');
      await t.tap(find.text('Submit count'));
      await t.pumpAndSettle();

      expect(sent.length, 1);
      expect(sent.first['line_id'], 'l1');
      expect(sent.first['counted_qty'], 26);
      // The untouched line is ABSENT — never defaulted to a counted zero.
      expect(sent.any((e) => e['line_id'] == 'l2'), isFalse);
    });

    testWidgets('after submitting, every number is the backend string', (
      t,
    ) async {
      await _pump(
        t,
        PharmacyCountSheetScreen(
          session: _submittedSheet(),
          rpc: (fn, p) async => _submittedSheet(),
        ),
      );
      expect(find.text('47'), findsOneWidget); // opening
      expect(find.text('40'), findsOneWidget); // expected
      expect(find.text('26'), findsOneWidget); // counted
      expect(find.text('₹142.40'), findsOneWidget);
      // -14 is NOT 26 - 40 computed here; it is the payload's own label, and
      // the chip glues it to the backend's own state word.
      expect(find.text('Short -14'), findsOneWidget);
      expect(find.text('₹938.40'), findsOneWidget);
    });
  });

  group('the stock check is owner-only by payload, not by a role test', () {
    testWidgets('a refusal prints the backend copy and offers no Retry', (
      t,
    ) async {
      await _pump(
        t,
        PharmacyVarianceScreen(
          rpc: (fn, p) async => {
            'ok': false,
            'error': 'not_owner',
            'message': 'This is an owner-only report.',
          },
        ),
      );
      expect(find.text('This is an owner-only report.'), findsOneWidget);
      expect(find.byType(OutlinedButton), findsNothing);
    });

    testWidgets('the report prints the backend sentence and value', (t) async {
      await _pump(
        t,
        PharmacyVarianceScreen(
          rpc: (fn, p) async => {
            'ok': true,
            'title': 'Stock check',
            'period_label': 'This week',
            'leaked_label': 'Value of the difference',
            'leaked_display': '₹938.40',
            'staff_title': 'By shift',
            'staff_note': 'A share of the movement, not a finding.',
            'staff_empty': 'No shift has a recorded difference yet.',
            'cause_note': 'The commonest reason is a sale never billed.',
            'start_button': 'Start a spot count',
            'starting': 'Picking items…',
            'empty': 'No differences recorded yet.',
            'empty_hint': 'Run a spot count.',
            'items': [
              {
                'headline': '14 strips Dolo 650mg Tablet unaccounted',
                'value_display': '₹142.40',
                'tone': 'danger',
              },
            ],
            'staff': const [],
          },
        ),
      );
      expect(
        find.text('14 strips Dolo 650mg Tablet unaccounted'),
        findsOneWidget,
      );
      expect(find.text('₹938.40'), findsOneWidget);
      // The empty-shift state is the backend's line, not a Dart fallback.
      expect(find.text('No shift has a recorded difference yet.'),
          findsOneWidget);
    });
  });

  group('the entry tiles are exactly what the backend sent', () {
    testWidgets('show:false renders nothing at all', (t) async {
      PharmacyShieldEntry.value.value = const {'ok': true, 'show': false};
      await _pumpTiles(t, const PharmacyShieldTiles());
      expect(find.byType(InkWell), findsNothing);
    });

    testWidgets('a staff login gets the expiry tile and no stock check', (
      t,
    ) async {
      // This is the whole owner fence on the client side: the widget does not
      // know what a staff login is, it just renders the tiles it was handed.
      PharmacyShieldEntry.value.value = {
        'ok': true,
        'show': true,
        'is_owner': false,
        'tiles': [
          {
            'route_key': 'pharmacy_expiry',
            'label': 'Expiry watch',
            'sub_label': 'Money still on the shelf',
          },
        ],
      };
      await _pumpTiles(t, const PharmacyShieldTiles());
      expect(find.text('Expiry watch'), findsOneWidget);
      expect(find.text('Stock check'), findsNothing);
    });

    testWidgets('the owner gets both, in payload order', (t) async {
      PharmacyShieldEntry.value.value = {
        'ok': true,
        'show': true,
        'is_owner': true,
        'tiles': [
          {'route_key': 'pharmacy_expiry', 'label': 'Expiry watch'},
          {'route_key': 'pharmacy_variance', 'label': 'Stock check'},
        ],
      };
      await _pumpTiles(t, const PharmacyShieldTiles());
      expect(find.text('Expiry watch'), findsOneWidget);
      expect(find.text('Stock check'), findsOneWidget);
    });

    testWidgets('a route_key this build has never heard of resolves to nothing',
        (t) async {
      expect(PharmacyShieldTiles.screenFor('pharmacy_expiry'), isNotNull);
      expect(PharmacyShieldTiles.screenFor('pharmacy_variance'), isNotNull);
      expect(PharmacyShieldTiles.screenFor('pharmacy_time_machine'), isNull);
    });
  });
}
