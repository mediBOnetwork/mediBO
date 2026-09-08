// PROTECTED — CHANGE #471.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes money-reconciliation rendering.
//
// The reconciliation screen exists to say whether the money surfaces agree.
// The one thing it must never do is decide that for itself — a screen that
// recomputes a difference is a second opinion, and a second opinion is exactly
// the class of drift this feature was built to find.
//
// What this holds down:
//
//   1. NOTHING IS COMPUTED IN DART. Every rupee figure, status word, tone,
//      count and sentence is printed verbatim from recon_home() /
//      recon_run_detail(). The fixture is deliberately inconsistent — its
//      expected and actual differ by ₹1,000.00 while the payload calls the
//      difference "+ ₹0.01", and a run labelled "Clean" carries tone 'bad' —
//      so any arithmetic or any word inferred from another field fails here.
//
//   2. Groups and findings render in PAYLOAD ORDER. The fixture's order is
//      deliberately not alphabetical and not sorted by count.
//
//   3. ABSENCE IS EXPLICIT. `has_amounts:false` prints no amount row at all,
//      never a "₹0.00" placeholder; a missing key prints an empty string, not
//      a Dart fallback word.
//
//   4. A DEEP LINK IS OFFERED ONLY WHERE THIS BUILD HAS A DESTINATION.
//      route 'order' with an order_code renders the backend's own route_label
//      as a tappable affordance; a route this build has never heard of, or one
//      with no label, renders nothing — never a chip that goes nowhere.
//
//   5. THE BUTTON IS THE PAYLOAD'S. Its caption comes from the payload, and
//      "Run now" is never written in Dart.
//
//   6. An empty run prints the BACKEND's empty_label, and a run list with no
//      runs at all prints the backend's empty state.
//
// No network, no Supabase, no goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/recon_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

// ── fixtures ─────────────────────────────────────────────────────────────────

Map<String, dynamic> _run({
  int id = 7,
  String status = 'drift',
  String statusLabel = 'Clean',
  String tone = 'bad',
}) =>
    {
      'run_id': id,
      'status': status,
      // deliberately mismatched: the word and the tone are two separate
      // payload fields and the screen must not derive one from the other.
      'status_label': statusLabel,
      'status_tone': tone,
      'summary_label': '2 finding(s) across 5 checks — ₹1,38,135.16 of drift.',
      'detail_label': 'Payments vs order state — 2',
      'window_label': '04 Aug to 03 Sep',
      'checks_label': '5 checks',
      'findings_label': '2 findings',
      'ran_label': '03 Sep, 02:50 AM',
      'trigger': 'cron',
    };

Map<String, dynamic> _home({List<Map<String, dynamic>>? runs}) => {
      'ok': true,
      'title': 'Reconciliation',
      'subtitle': 'Every night the money surfaces are compared.',
      'run_button': 'Run now',
      'running_label': 'Reconciling…',
      'has_latest': true,
      'latest': _run(),
      'runs': runs ?? [_run(), _run(id: 6, statusLabel: 'Drift found')],
      'empty_title': 'No reconciliation has run yet',
      'empty_hint': 'Tap Run now to reconcile the last 30 days.',
    };

Map<String, dynamic> _detail({List<Map<String, dynamic>>? groups}) => {
      'ok': true,
      'title': 'Reconciliation',
      'run': _run(),
      'expected_caption': 'Expected',
      'actual_caption': 'Actual',
      'diff_caption': 'Difference',
      'empty_label': 'Nothing drifted in this run.',
      'groups': groups ??
          [
            // NOT alphabetical, NOT sorted by count — payload order is the order.
            {
              'ord': 10,
              'check_key': 'payments',
              'label': 'Payments vs order state',
              'description': 'No order is marked paid without money behind it.',
              'sources_label': 'Razorpay vs Order payment state',
              'count_label': '2 findings',
              'tone': 'bad',
              'findings': [
                {
                  'id': 1,
                  'severity': 'error',
                  'entity_label': 'CPO090826PAL124O1',
                  'detail_label': 'Order CPO090826PAL124O1 is treated as paid.',
                  // expected and actual are ₹1,000.00 apart; the payload calls
                  // the difference one paisa. Dart must print what it is told.
                  'expected_label': '₹5,000.00',
                  'actual_label': '₹4,000.00',
                  'diff_label': '+ ₹0.01',
                  'has_amounts': true,
                  'route': 'order',
                  'route_args': {'order_code': 'CPO090826PAL124O1'},
                  'route_label': 'Open order',
                },
                {
                  'id': 2,
                  'severity': 'error',
                  'entity_label': 'pay_TVgro5wblT563r',
                  'detail_label': 'Razorpay reported payment.captured.',
                  'expected_label': '',
                  'actual_label': '',
                  'diff_label': '',
                  'has_amounts': false,
                  // a route this build has no destination for
                  'route': 'money',
                  'route_args': {'tab': 'unmatched'},
                  'route_label': 'Open Money',
                },
              ],
            },
            {
              'ord': 20,
              'check_key': 'bill_vs_order',
              'label': 'Bills vs orders and the slab snapshot',
              'description': 'A bill must equal its order at the snapshot.',
              'sources_label': 'Order total vs Recomputed bill',
              'count_label': '0 findings',
              'tone': 'good',
              'findings': const [],
            },
          ],
    };

ReconRpc _rpcOf(Map<String, dynamic> home, Map<String, dynamic> detail,
    {List<String>? seen}) {
  return (fn, params) async {
    seen?.add(fn);
    if (fn == 'recon_home') return home;
    if (fn == 'recon_run_detail') return detail;
    return {'ok': true, 'toast': 'Reconciliation finished — see the run below.'};
  };
}

Future<void> _pump(WidgetTester t, ReconRpc rpc) async {
  // A tall surface so the whole payload is BUILT: a ListView only builds what
  // fits, and "renders in payload order" is a claim about the whole list.
  await t.binding.setSurfaceSize(const Size(900, 3000));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(MaterialApp(home: ReconScreen(rpc: rpc)));
  await t.pumpAndSettle();
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  testWidgets('1a. every rupee figure is the payload string, never computed',
      (t) async {
    await _pump(t, _rpcOf(_home(), _detail()));

    expect(find.text('₹5,000.00'), findsOneWidget);
    expect(find.text('₹4,000.00'), findsOneWidget);
    // The honest arithmetic answer is ₹1,000.00. The payload says one paisa,
    // and the payload is what the screen prints.
    expect(find.text('+ ₹0.01'), findsOneWidget);
    expect(find.textContaining('₹1,000.00'), findsNothing);
    expect(find.text('2 finding(s) across 5 checks — ₹1,38,135.16 of drift.'),
        findsWidgets);
  });

  testWidgets('1b. the status word and its tone are two separate payload fields',
      (t) async {
    await _pump(t, _rpcOf(_home(), _detail()));
    // status is 'drift' and the tone is 'bad', yet the label says "Clean":
    // the screen prints the label it was given rather than one derived from
    // the status key.
    expect(find.text('Clean'), findsWidgets);
    expect(find.text('Drift found'), findsOneWidget); // the older run's label
  });

  testWidgets('1c. counts and captions come from the payload', (t) async {
    await _pump(t, _rpcOf(_home(), _detail()));
    expect(find.text('2 findings'), findsWidgets);
    expect(find.text('0 findings'), findsOneWidget);
    expect(find.text('Expected'), findsOneWidget);
    expect(find.text('Actual'), findsOneWidget);
    expect(find.text('Difference'), findsOneWidget);
    expect(find.text('Razorpay vs Order payment state'), findsOneWidget);
  });

  testWidgets('2. groups and findings render in payload order', (t) async {
    await _pump(t, _rpcOf(_home(), _detail()));

    final payments = t.getTopLeft(find.text('Payments vs order state')).dy;
    final bills =
        t.getTopLeft(find.text('Bills vs orders and the slab snapshot')).dy;
    // 'Bills…' sorts before 'Payments…' alphabetically and has fewer findings;
    // it is second because the payload put it second.
    expect(payments, lessThan(bills));

    final first = t.getTopLeft(find.text('CPO090826PAL124O1')).dy;
    final second = t.getTopLeft(find.text('pay_TVgro5wblT563r')).dy;
    expect(first, lessThan(second));
  });

  testWidgets('3. has_amounts:false prints no amount row, not a ₹0.00',
      (t) async {
    await _pump(t, _rpcOf(_home(), _detail()));
    // Exactly one finding carries amounts, so each caption appears once.
    expect(find.text('Expected'), findsOneWidget);
    expect(find.text('₹0.00'), findsNothing);
  });

  testWidgets('4a. a known route offers the backend\'s own label', (t) async {
    await _pump(t, _rpcOf(_home(), _detail()));
    expect(find.widgetWithText(TextButton, 'Open order'), findsOneWidget);
  });

  testWidgets('4b. a route this build has no destination for offers nothing',
      (t) async {
    await _pump(t, _rpcOf(_home(), _detail()));
    // The label is in the payload; the affordance is not drawn, because a chip
    // that goes nowhere is worse than no chip.
    expect(find.widgetWithText(TextButton, 'Open Money'), findsNothing);
    expect(find.text('Open Money'), findsNothing);
  });

  testWidgets('4c. a known route with no order_code offers nothing', (t) async {
    final d = _detail(groups: [
      {
        'ord': 10,
        'check_key': 'payments',
        'label': 'Payments vs order state',
        'description': '',
        'sources_label': '',
        'count_label': '1 findings',
        'tone': 'bad',
        'findings': [
          {
            'id': 1,
            'entity_label': 'CPO1',
            'detail_label': 'no code on this one',
            'has_amounts': false,
            'route': 'order',
            'route_args': const <String, dynamic>{},
            'route_label': 'Open order',
          },
        ],
      },
    ]);
    await _pump(t, _rpcOf(_home(), d));
    expect(find.widgetWithText(TextButton, 'Open order'), findsNothing);
  });

  testWidgets('5. the run button caption is the payload\'s', (t) async {
    await _pump(t, _rpcOf(_home(), _detail()));
    expect(find.widgetWithText(ElevatedButton, 'Run now'), findsOneWidget);
  });

  testWidgets('6a. a run with no findings prints the backend empty label',
      (t) async {
    await _pump(t, _rpcOf(_home(), _detail(groups: const [])));
    expect(find.text('Nothing drifted in this run.'), findsOneWidget);
  });

  testWidgets('6b. no runs at all prints the backend empty state', (t) async {
    final home = _home(runs: const [])
      ..['has_latest'] = false
      ..['latest'] = null;
    final detail = {
      'ok': false,
      'title': 'No reconciliation has run yet',
      'message': 'Tap Run now to reconcile the last 30 days.',
    };
    await _pump(t, _rpcOf(home, detail));
    expect(find.text('No reconciliation has run yet'), findsOneWidget);
    expect(find.text('Tap Run now to reconcile the last 30 days.'),
        findsOneWidget);
  });

  testWidgets('7. the screen asks for the two read RPCs and nothing else',
      (t) async {
    final seen = <String>[];
    await _pump(t, _rpcOf(_home(), _detail(), seen: seen));
    expect(seen, ['recon_home', 'recon_run_detail']);
  });
}
