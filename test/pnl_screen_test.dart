// CHANGE #319 — the P&L screen prints the backend's arithmetic and does none
// of its own.
//
// What these tests hold down is the one way a margin screen goes wrong: a
// number that Dart computed. Every rupee, percentage, heading, tab and empty
// state below arrives already formatted, and the test asserts the EXACT
// backend string appears — including a deliberately "wrong" total that no
// client-side sum could ever produce. If someone re-derives a figure in Dart,
// that string stops matching and this file goes red.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/pnl_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _dash() => {
      'ok': true,
      'title': 'Profit & loss',
      'subtitle': 'Margin is taxable minus taxable.',
      'footnote': 'Cost is the supplier rate after their discount.',
      'empty_text': 'No billed lines in this window yet.',
      'error_text': 'Could not load the profit & loss figures.',
      'retry_text': 'Retry',
      'days': 30,
      'range_label': 'Last 30 days',
      'has_data': true,
      'tabs': [
        {'key': 'overview', 'label': 'Overview'},
        {'key': 'customer', 'label': 'Customers'},
        {'key': 'supplier', 'label': 'Suppliers'},
        {'key': 'simulator', 'label': 'Slab simulator'},
      ],
      // 131.82 is the amortised-scheme margin from the SQL self-test: a client
      // that recomputed 950 - 900 would print ₹50.00 here instead.
      'tiles': [
        {'key': 'revenue', 'label': 'Revenue (taxable)', 'value': '₹950.00', 'tone': 'neutral'},
        {'key': 'cost', 'label': 'Goods cost', 'value': '₹818.18', 'tone': 'neutral'},
        {'key': 'gross', 'label': 'Gross margin', 'value': '₹131.82', 'tone': 'success'},
        {'key': 'contribution', 'label': 'Contribution', 'value': '₹131.59', 'tone': 'brand'},
      ],
      'costs': {
        'heading': 'Below the goods',
        'rows': [
          {'label': 'WhatsApp messages', 'value': '- ₹0.23'},
          {'label': 'Delivery recovered', 'value': '+ ₹0.00'},
        ],
      },
      'sections': [
        {
          'key': 'customer',
          'heading': 'Margin per customer',
          'empty_text': 'No billed lines in this window yet.',
          'rows': [
            {'key': 'c1', 'label': 'Shree Medical', 'sub': '3 orders  ·  ₹9,500.00',
             'value': '₹1,318.20', 'value_tone': 'success'},
          ],
        },
        {
          'key': 'supplier',
          'heading': 'Margin per supplier',
          'empty_text': 'No billed lines in this window yet.',
          'rows': [],
        },
      ],
      'alerts': {
        'heading': 'Sold below cost',
        'note': 'Reported only.',
        'empty_text': 'Nothing has sold below cost in this window.',
        'count': 1,
        'rows': [
          {'key': '1', 'label': 'Megval 50mg Injection',
           'sub': 'CPO310826  ·  ₹400.00 → ₹1,000.00',
           'value': '-₹600.00', 'value_tone': 'danger'},
        ],
      },
    };

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);
  tearDown(() => PnlScreen.rpcOverride = null);

  Future<void> pump(WidgetTester t) async {
    await t.pumpWidget(const MaterialApp(home: PnlScreen()));
    await t.pumpAndSettle();
  }

  testWidgets('every figure on the overview is the backend string, verbatim',
      (t) async {
    PnlScreen.rpcOverride = (fn, params) async {
      expect(fn, 'pnl_dashboard');
      expect(params?['p_days'], 30);
      return _dash();
    };
    await pump(t);

    // the amortised margin, not the naive one
    expect(find.text('₹131.82'), findsOneWidget);
    expect(find.text('₹50.00'), findsNothing);
    // contribution is its own backend number, not gross minus something here
    expect(find.text('₹131.59'), findsOneWidget);
    // labels, headings and the range word are all the payload's
    expect(find.text('Gross margin'), findsOneWidget);
    expect(find.text('Below the goods'), findsOneWidget);
    expect(find.text('Last 30 days'), findsOneWidget);
    expect(find.text('- ₹0.23'), findsOneWidget);
  });

  testWidgets('a section with no rows shows the backend empty state, not a zero',
      (t) async {
    PnlScreen.rpcOverride = (fn, params) async => _dash();
    await pump(t);

    // it is below the fold on a test-sized viewport, so scroll to it rather
    // than assert on what happens to be painted first
    await t.scrollUntilVisible(find.text('Margin per supplier'), 300,
        scrollable: find.byType(Scrollable).first);
    await t.pumpAndSettle();

    expect(find.text('Margin per supplier'), findsOneWidget);
    expect(find.text('No billed lines in this window yet.'), findsWidgets);
  });

  testWidgets('the below-cost alert is rendered, and its note says it blocks nothing',
      (t) async {
    PnlScreen.rpcOverride = (fn, params) async => _dash();
    await pump(t);

    expect(find.text('Megval 50mg Injection'), findsOneWidget);
    expect(find.text('-₹600.00'), findsOneWidget);
    expect(find.text('Reported only.'), findsOneWidget);
  });

  testWidgets('tabs come from the payload and switching one asks for that dim',
      (t) async {
    String? askedDim;
    PnlScreen.rpcOverride = (fn, params) async {
      if (fn == 'pnl_dashboard') return _dash();
      if (fn == 'pnl_breakdown') {
        askedDim = params?['p_dim'] as String?;
        return {
          'ok': true,
          'dim': 'supplier',
          'heading': 'Margin per supplier',
          'empty_text': 'No billed lines in this window yet.',
          'rows': [
            {'key': 's1', 'label': 'Chhattisgarh Distributors',
             'sub': '12 lines  ·  ₹22,400.00', 'value': '₹2,144.00',
             'value_tone': 'success'},
          ],
        };
      }
      return {'ok': true};
    };
    await pump(t);

    await t.tap(find.text('Suppliers'));
    await t.pumpAndSettle();

    expect(askedDim, 'supplier');
    expect(find.text('Chhattisgarh Distributors'), findsOneWidget);
    expect(find.text('₹2,144.00'), findsOneWidget);
  });

  testWidgets('the simulator sends the proposed slab and prints the backend impact',
      (t) async {
    List<dynamic>? sent;
    PnlScreen.rpcOverride = (fn, params) async {
      if (fn == 'pnl_dashboard') return _dash();
      if (fn == 'pnl_slab_simulate') {
        sent = params?['p_slabs'] as List<dynamic>?;
        if (sent == null) {
          // the setup call: the current slab, so the proposal starts from live
          return {
            'ok': true,
            'ran': false,
            'title': 'Slab simulator',
            'subtitle': 'Replay a proposed slab.',
            'proposed_label': 'Proposed slab',
            'min_ptr_label': 'Order value above',
            'pct_label': 'Discount %',
            'run_label': 'Run simulation',
            'note': 'A simulation changes nothing.',
            'empty_text': 'No billed orders in this window to replay.',
            'current': [
              {'slab_id': 1, 'min_amount': 0, 'discount_pct': 5},
            ],
          };
        }
        return {
          'ok': true,
          'ran': true,
          'title': 'Slab simulator',
          'subtitle': 'Replay a proposed slab.',
          'proposed_label': 'Proposed slab',
          'min_ptr_label': 'Order value above',
          'pct_label': 'Discount %',
          'run_label': 'Run simulation',
          'note': 'A simulation changes nothing.',
          'empty_text': 'No billed orders in this window to replay.',
          'result_heading': 'Impact on the same orders',
          'current': [
            {'slab_id': 1, 'min_amount': 0, 'discount_pct': 5},
          ],
          'tiles': [
            {'key': 'delta_margin', 'label': 'Gross margin change',
             'value': '-₹300.00', 'tone': 'danger'},
            {'key': 'pushed', 'label': 'Lines pushed below cost',
             'value': '1', 'tone': 'danger'},
          ],
          'rows': [
            {'key': 'c1', 'label': 'Shree Medical',
             'sub': '₹131.82 → -₹168.18', 'value': '-₹300.00',
             'value_tone': 'danger'},
          ],
        };
      }
      return {'ok': true};
    };
    await pump(t);

    await t.tap(find.text('Slab simulator'));
    await t.pumpAndSettle();

    // the proposal is seeded from the live slab, not from an empty form
    expect(find.text('Order value above 0'), findsOneWidget);

    await t.enterText(find.byKey(const ValueKey('pnl_sim_pct_0')), '20');
    await t.tap(find.text('Run simulation'));
    await t.pumpAndSettle();

    expect(sent, isNotNull);
    expect(sent!.first['discount_pct'], 20);
    expect(sent!.first['min_amount'], 0);
    // the impact is the backend's number: 2000 x 15% = 300, computed in SQL
    expect(find.text('-₹300.00'), findsWidgets);
    expect(find.text('Lines pushed below cost'), findsOneWidget);
  });

  testWidgets('a refusal renders the backend message instead of throwing',
      (t) async {
    PnlScreen.rpcOverride = (fn, params) async =>
        {'ok': false, 'error': 'not_authorized', 'message': 'Admins only.'};
    await pump(t);

    expect(find.text('Admins only.'), findsOneWidget);
  });
}
