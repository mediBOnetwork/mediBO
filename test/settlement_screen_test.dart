// CHANGE #323 — the settlement screens print the backend's arithmetic and do
// none of their own.
//
// What these tests hold down is the one way a money-split screen goes wrong: a
// number, a word or an option that Dart produced. Every rupee, status word,
// cadence label and dropdown choice below arrives in the payload, and the
// assertions look for the EXACT backend string — including figures no
// client-side sum could reproduce.
//
// The three rules that make this feature correct, asserted here as rendering:
//   1. the split is applied to the PERIOD total, so the ₹150.00 due on a day
//      that held +₹500 and -₹200 is NOT the ₹250.00 a per-order split gives;
//   2. a period under water pays ₹0.00, carries the shortfall, and says so;
//   3. the partner sees the same statement as the admin, minus the actions —
//      Record and Settle exist only when the BACKEND says is_admin/can_settle.
//
// No network, no Supabase, no camera.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/settlement_screen.dart';
import 'package:pharma_b2b/screens/partner/partner_statement_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _dash({bool hasData = true}) => {
      'ok': true,
      'title': 'Partner settlement',
      'subtitle': 'A zone is fulfilled by mediBO or by a partner.',
      'footnote': 'Distributable profit is gross margin minus every cost line.',
      'empty_text': 'Nothing to settle in this window yet.',
      'error_text': 'Could not load the settlement figures.',
      'retry_text': 'Retry',
      'range_label': 'Last 30 days',
      'refresh_label': 'Refresh',
      'recalculate_label': 'Recalculate',
      'has_data': hasData,
      'tabs': [
        {'key': 'overview', 'label': 'Overview'},
        {'key': 'zones', 'label': 'Zones'},
        {'key': 'costs', 'label': 'Cost types'},
        {'key': 'periods', 'label': 'Periods'},
      ],
      // ₹150.00 is the PERIOD split of (+500 - 200) x 50%. A client that split
      // each order and dropped the loss would print ₹250.00 here.
      'tiles': [
        {'key': 'tile.distributable', 'label': 'Distributable profit', 'value': '₹300.00', 'tone': 'brand'},
        {'key': 'tile.partner', 'label': 'Partner share', 'value': '₹150.00', 'tone': null},
        {'key': 'tile.medibo', 'label': 'mediBO share', 'value': '₹150.00', 'tone': null},
      ],
      'route': {
        'ok': true,
        'heading': 'How the partner is paid',
        'save_label': 'Save',
        'route_mode': 'manual',
        'route_options': [
          {'key': 'manual', 'label': 'Manual — mediBO transfers separately'},
          {'key': 'automatic', 'label': 'Automatic — Razorpay Route splits at settlement'},
        ],
        'default_cadence': 'same_day',
        'cadence_options': [
          {'key': 'same_day', 'label': 'Same day'},
          {'key': 't_plus_2', 'label': 'Two days after (T+2)'},
          {'key': 'weekly', 'label': 'Weekly'},
          {'key': 'monthly', 'label': 'Monthly'},
        ],
        'auto_close': true,
        'fields': {
          'route_mode': 'How the partner is paid',
          'cadence': 'Settle every',
          'auto_close': 'Close and write statements automatically',
        },
      },
      'zones': {
        'ok': true,
        'heading': 'Zones and their deal',
        'empty_text': 'Nothing to settle in this window yet.',
        'save_label': 'Save',
        'mode_options': [
          {'key': 'self', 'label': 'mediBO fulfils'},
          {'key': 'partner', 'label': 'Partner fulfils'},
        ],
        'cadence_options': [
          {'key': 'same_day', 'label': 'Same day'},
          {'key': 't_plus_2', 'label': 'Two days after (T+2)'},
        ],
        'partners': [
          {'id': 1, 'label': 'Jai Mahakal Medical And Surgical'},
        ],
        'fields': {
          'mode': 'Fulfilment mode',
          'partner': 'Partner',
          'split': 'Partner share %',
          'cadence': 'Settle every',
        },
        'rows': [
          {
            'zone_id': 1,
            'label': 'Raipur Zone',
            'mode': 'partner',
            'partner_id': 1,
            'split_pct': 50,
            'cadence': 'same_day',
            'sub': 'Jai Mahakal Medical And Surgical · 50% · Same day',
            'value': '50%',
          },
          {
            'zone_id': 2,
            'label': 'Bilaspur Zone',
            'mode': 'self',
            'split_pct': 0,
            'cadence': 'same_day',
            'sub': '100% to mediBO.',
            'value': '0%',
          },
        ],
      },
      'cost_types': {
        'ok': true,
        'heading': 'Cost types',
        'note': 'Changing how a cost is charged applies to orders billed from now on.',
        'add_label': 'Add a cost type',
        'save_label': 'Save',
        'empty_text': 'Nothing to settle in this window yet.',
        'basis_options': [
          {'key': 'flat', 'label': 'Flat per order'},
          {'key': 'per_km', 'label': 'Base + per km'},
          {'key': 'per_box', 'label': 'Base + per box'},
          {'key': 'pct_of_order', 'label': 'Base + % of order value'},
        ],
        'fields': {
          'slug': 'Key',
          'label': 'Name',
          'basis': 'How it is charged',
          'base': 'Base amount (₹)',
          'rate': 'Rate',
          'active': 'Active',
        },
        'rows': [
          {
            'slug': 'delivery',
            'label': 'Delivery',
            'basis': 'flat',
            'basis_label': 'Flat per order',
            'default_value': 0,
            'rate_value': 0,
            'active': true,
            'sub': 'Flat per order · ₹0.00',
            'value': '',
          },
        ],
      },
      'periods': {
        'ok': true,
        'heading': 'Settlement periods',
        'note': 'Statements are written automatically when the period closes.',
        'empty_text': 'No periods yet.',
        'rows': [
          {
            'period_id': 7,
            'label': '20 Aug 2026 to 20 Aug 2026',
            'sub': 'Jai Mahakal Medical And Surgical · Due · Same day',
            'value': '₹150.00',
            'value_tone': 'warning',
          },
        ],
      },
      'month_rollup': {
        'heading': 'Monthly rollup',
        'empty_text': 'No periods yet.',
        'rows': [
          {'label': '2026-08', 'sub': 'Jai Mahakal · Orders settled 4', 'value': '₹350.00'},
        ],
      },
    };

Map<String, dynamic> _statement({
  bool isAdmin = true,
  bool canSettle = true,
  bool negative = false,
}) =>
    {
      'ok': true,
      'period_id': 7,
      'title': 'Partner settlement',
      'heading': '21 Aug 2026 to 21 Aug 2026',
      'sub': 'Same day · Due on 21 Aug 2026',
      'partner': 'Jai Mahakal Medical And Surgical',
      'status': 'due',
      'status_label': 'Due',
      'status_tone': 'warning',
      'is_admin': isAdmin,
      'can_settle': canSettle,
      'settle_label': 'Settle this period',
      'record_label': 'Record a transfer',
      'amount_label': 'Amount (₹)',
      'reference_label': 'Reference / transfer id',
      'route_mode': 'manual',
      'route_label': 'Manual — mediBO transfers separately',
      'route_note': 'Record each transfer here after you send it.',
      'negative': negative,
      'negative_text':
          'This period nets below zero, so nothing is transferred. The shortfall is carried into the next statement instead of being billed back.',
      'tiles': [
        {'key': 'tile.distributable', 'label': 'Distributable profit', 'value': negative ? '-₹200.00' : '₹600.00', 'tone': 'brand'},
        {'key': 'tile.brought_forward', 'label': 'Brought forward', 'value': '-₹100.00', 'tone': 'warning'},
        {'key': 'tile.due', 'label': 'Due to partner', 'value': negative ? '₹0.00' : '₹200.00', 'tone': null},
        {'key': 'tile.transferred', 'label': 'Transferred', 'value': '₹0.00', 'tone': 'success'},
        {'key': 'tile.pending', 'label': 'Pending', 'value': negative ? '₹0.00' : '₹200.00', 'tone': 'warning'},
        {'key': 'tile.carry_forward', 'label': 'Carried to next period', 'value': negative ? '-₹200.00' : '₹0.00', 'tone': 'warning'},
      ],
      'costs': {
        'heading': 'Cost lines on this order',
        'rows': [
          {'label': 'Delivery', 'sub': 'Flat per order', 'value': '₹40.00'},
        ],
      },
      'orders': {
        'heading': 'Orders in this period',
        'empty_text': 'Nothing to settle in this window yet.',
        'rows': [
          {'order_id': 'o1', 'label': 'ORD-1', 'sub': '20 Aug 2026 · Gross margin ₹700.00 · Costs ₹200.00', 'value': '₹500.00'},
          {'order_id': 'o2', 'label': 'ORD-2', 'sub': '20 Aug 2026 · Gross margin -₹100.00 · Costs ₹100.00', 'value': '-₹200.00', 'value_tone': 'danger'},
        ],
      },
      'payments': {
        'heading': 'Transfers',
        'empty_text': 'No periods yet.',
        'rows': const [],
      },
      'footnote': 'Distributable profit is gross margin minus every cost line.',
    };

Map<String, dynamic> _partner({bool empty = false}) => {
      'ok': true,
      'title': 'Partner settlement',
      'subtitle': 'A zone is fulfilled by mediBO or by a partner.',
      'footnote': 'Distributable profit is gross margin minus every cost line.',
      'empty_text': 'Nothing to settle in this window yet.',
      'partner': 'Jai Mahakal Medical And Surgical',
      'periods': {
        'heading': 'Settlement periods',
        'empty_text': 'No periods yet.',
        'rows': empty
            ? const []
            : [
                {
                  'period_id': 7,
                  'label': '21 Aug 2026 to 21 Aug 2026',
                  'sub': 'Due · Same day',
                  'value': '₹200.00',
                  'value_tone': 'warning',
                },
              ],
      },
      'statement': empty ? null : _statement(isAdmin: false, canSettle: false),
    };

Future<void> _pump(WidgetTester t, Widget w) async {
  await t.pumpWidget(MaterialApp(home: Scaffold(body: w)));
  await t.pump();
  await t.pump(const Duration(milliseconds: 50));
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);
  tearDown(() => SettlementScreen.rpcOverride = null);

  group('admin settlement screen', () {
    testWidgets('the period split is printed, never re-derived per order',
        (t) async {
      SettlementScreen.rpcOverride = (fn, p) async => _dash();
      await t.pumpWidget(const MaterialApp(home: SettlementScreen()));
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));

      // ₹150.00 is the split of the PERIOD total (+500 - 200) x 50%.
      expect(find.text('₹150.00'), findsWidgets);
      // ₹250.00 is what a per-order split that ignored the loss would show.
      expect(find.text('₹250.00'), findsNothing);
      expect(find.text('Partner settlement'), findsOneWidget);
      expect(find.text('Distributable profit'), findsOneWidget);
    });

    testWidgets('the zone deal is the backend sentence, verbatim', (t) async {
      SettlementScreen.rpcOverride = (fn, p) async => _dash();
      await t.pumpWidget(const MaterialApp(home: SettlementScreen()));
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));

      await t.tap(find.text('Zones'));
      await t.pump();

      expect(find.text('Zones and their deal'), findsOneWidget);
      expect(find.text('Raipur Zone'), findsOneWidget);
      expect(
          find.text('Jai Mahakal Medical And Surgical · 50% · Same day'),
          findsOneWidget);
      // A self zone's note is the backend's, not a Dart "100%".
      expect(find.text('100% to mediBO.'), findsOneWidget);
    });

    testWidgets('a cost type shows its basis words and offers Add', (t) async {
      SettlementScreen.rpcOverride = (fn, p) async => _dash();
      await t.pumpWidget(const MaterialApp(home: SettlementScreen()));
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));

      await t.tap(find.text('Cost types'));
      await t.pump();

      expect(find.text('Delivery'), findsOneWidget);
      // Delivery seeds as FLAT — never per_km/per_box by assumption.
      expect(find.text('Flat per order · ₹0.00'), findsOneWidget);
      expect(find.byKey(const ValueKey('stl_add_cost_type')), findsOneWidget);
      expect(find.text('Add a cost type'), findsOneWidget);
    });

    testWidgets('the basis dropdown offers only the payload options',
        (t) async {
      SettlementScreen.rpcOverride = (fn, p) async => _dash();
      await t.pumpWidget(const MaterialApp(home: SettlementScreen()));
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));

      await t.tap(find.text('Cost types'));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('stl_add_cost_type')));
      await t.pumpAndSettle();

      expect(find.text('Flat per order'), findsWidgets);
      expect(find.byKey(const ValueKey('stl_ct_slug')), findsOneWidget);
      // A fifth way to charge cannot appear without the backend sending it.
      expect(find.text('Per invoice'), findsNothing);
    });

    testWidgets('the empty window shows the backend empty state', (t) async {
      SettlementScreen.rpcOverride = (fn, p) async => _dash(hasData: false);
      await t.pumpWidget(const MaterialApp(home: SettlementScreen()));
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));

      expect(find.text('Nothing to settle in this window yet.'), findsOneWidget);
    });

    testWidgets('a refusal renders the backend message, not a Dart one',
        (t) async {
      SettlementScreen.rpcOverride =
          (fn, p) async => {'ok': false, 'message': 'Admins only.'};
      await t.pumpWidget(const MaterialApp(home: SettlementScreen()));
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));

      expect(find.text('Admins only.'), findsOneWidget);
    });
  });

  group('the statement body', () {
    testWidgets('the admin gets Record and Settle', (t) async {
      await _pump(
        t,
        settlementStatementBody(_statement(),
            onRecord: () {}, onSettle: () {}),
      );
      expect(find.text('Brought forward'), findsOneWidget);
      expect(find.text('-₹100.00'), findsOneWidget);

      // The actions sit below the fold of a phone-sized statement; scroll to
      // them rather than pretending the list is short.
      await t.scrollUntilVisible(
          find.byKey(const ValueKey('stl_record_payment')), 300,
          scrollable: find.byType(Scrollable).first);
      expect(find.byKey(const ValueKey('stl_record_payment')), findsOneWidget);
      await t.scrollUntilVisible(
          find.byKey(const ValueKey('stl_settle')), 300,
          scrollable: find.byType(Scrollable).first);
      expect(find.byKey(const ValueKey('stl_settle')), findsOneWidget);
    });

    testWidgets('a negative period pays nothing and says why', (t) async {
      await _pump(t, settlementStatementBody(_statement(negative: true)));
      expect(
          find.textContaining('nothing is transferred'), findsOneWidget);
      // Due and Pending are the backend's ₹0.00, and the shortfall is carried.
      expect(find.text('₹0.00'), findsWidgets);
      expect(find.text('-₹200.00'), findsWidgets);
    });

    testWidgets('a loss-making order shows in the detail without being settled',
        (t) async {
      await _pump(t, settlementStatementBody(_statement()));
      expect(find.text('ORD-2'), findsOneWidget);
      expect(find.text('-₹200.00'), findsOneWidget);
    });
  });

  group('partner statement screen', () {
    testWidgets('renders the same statement, without the admin actions',
        (t) async {
      await _pump(
          t, PartnerStatementScreen(rpc: (fn, p) async => _partner()));

      expect(find.text('21 Aug 2026 to 21 Aug 2026'), findsWidgets);
      await t.scrollUntilVisible(find.text('Due to partner'), 300,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('Due to partner'), findsOneWidget);
      expect(find.text('Transferred'), findsOneWidget);
      expect(find.text('Pending'), findsOneWidget);
      // The partner never gets the buttons — the backend said so. Scrolling to
      // the bottom proves they are ABSENT, not merely below the fold.
      await t.drag(find.byType(Scrollable).first, const Offset(0, -4000));
      await t.pump();
      expect(find.byKey(const ValueKey('stl_record_payment')), findsNothing);
      expect(find.byKey(const ValueKey('stl_settle')), findsNothing);
    });

    testWidgets('a partner with no statements sees the backend empty state',
        (t) async {
      await _pump(t,
          PartnerStatementScreen(rpc: (fn, p) async => _partner(empty: true)));
      expect(find.text('No periods yet.'), findsOneWidget);
    });

    testWidgets('a refused partner sees the backend refusal', (t) async {
      await _pump(
        t,
        PartnerStatementScreen(
          rpc: (fn, p) async => {
            'ok': false,
            'message': 'This statement is not shared with your account.',
          },
        ),
      );
      expect(find.text('This statement is not shared with your account.'),
          findsOneWidget);
    });
  });
}
