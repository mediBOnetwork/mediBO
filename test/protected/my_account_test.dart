// PROTECTED — CHANGE #840.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes the customer account page's behaviour.
//
// What this holds down, on the ONE screen the customer's whole account lives
// on:
//
//   1. THE TAB LIST IS THE BACKEND'S. my_account_page() names every tab, its
//      label, its order AND the RPC that answers for it. The screen calls the
//      rpc the payload named — not a name it built from the key — so moving a
//      tab to a different function is an UPDATE, never a deploy.
//
//   2. NOTHING IS COMPUTED IN DART. Every rupee, count, status word, month
//      name and empty state prints verbatim. The fixtures deliberately
//      disagree with what a client-side calculation would produce (the tiles
//      say Billed 100 / Paid 40 / Outstanding 999, and a top-products row
//      shows a value that is not qty x anything), so any arithmetic that crept
//      into the screen fails here.
//
//   3. A CHIP CARRIES THE BACKEND'S OWN ARGUMENT. Tapping a filter sends the
//      parameter the block NAMED with the value the chip carried, and reloads
//      that tab's RPC with it. Same for a calendar day.
//
//   4. A TOGGLE IS AN RPC CALL THE PAYLOAD DESCRIBED. The switch sends the
//      block's rpc with the item's own args plus the new value in the block's
//      own value_arg. The screen never decides what a notification preference
//      means.
//
//   5. A DOCUMENT IS ASKED FOR, THEN POLLED ON THE BACKEND'S OWN poll_ms, AND
//      OPENED AT THE BACKEND'S OWN bucket+path. The screen never builds a URL
//      and never invents a timeout.
//
//   6. FORWARD COMPATIBILITY. A block kind this build has never heard of
//      renders zero pixels instead of throwing, and a nav row pointing at a
//      route this build cannot resolve is skipped in silence — a registry row
//      that ships before its screen must not break the page.
//
//   7. ok:false RENDERS THE BACKEND'S REFUSAL, not an exception.
//
// No network, no Supabase, no goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/customer/my_account_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

// ── Fixtures ───────────────────────────────────────────────────────────────

Map<String, dynamic> _page() => {
      'ok': true,
      'title': 'Chandra Medicom',
      'subtitle': 'Chandrasekhar  ·  CHA101  ·  Raigarh',
      'chips': [
        {
          'show': true,
          'label': 'KYC missing',
          'bg': '#FEF3C7',
          'fg': '#92400E',
          'border': '#FDE68A',
        }
      ],
      'tabs': [
        // Deliberately NOT 'my_account_tab_<key>': the screen must call the
        // rpc the payload named.
        {'key': 'billing', 'label': 'Bills & Payments', 'rpc': 'tab_bills_v2'},
        {'key': 'shop', 'label': 'My Shop', 'rpc': 'tab_shop_v2'},
        {'key': 'calendar', 'label': 'Order calendar', 'rpc': 'tab_cal_v2'},
        {'key': 'statement', 'label': 'Statement', 'rpc': 'tab_stmt_v2'},
        {'key': 'preferences', 'label': 'Preferences', 'rpc': 'tab_pref_v2'},
      ],
      'default_tab': 'billing',
      'empty_label': 'Nothing here yet.',
      'more_label': 'Show more',
    };

Map<String, dynamic> _billing() => {
      'ok': true,
      'blocks': [
        {
          'kind': 'tiles',
          'tiles': [
            {'label': 'Billed', 'value': '₹100.00', 'tone': 'neutral'},
            {'label': 'Paid', 'value': '₹40.00', 'tone': 'success'},
            // 999, not 60: a screen that subtracted would fail this.
            {'label': 'Outstanding', 'value': '₹999.00', 'tone': 'danger'},
          ],
        },
        {
          'kind': 'list',
          'title': 'Bills',
          'empty': 'No bills yet.',
          'items': [
            {
              'title': 'INV-1',
              'subtitle': '2 Aug 2026',
              'meta': '₹40.00 paid',
              'trailing': '₹100.50',
              'trailing_tone': 'danger',
            }
          ],
        },
        {'kind': 'a_kind_from_2027', 'title': 'must not throw'},
      ],
    };

Map<String, dynamic> _shop() => {
      'ok': true,
      'blocks': [
        {
          'kind': 'table',
          'title': 'Your top 10 products',
          'empty': 'nothing yet',
          'columns': [
            {'label': 'Product', 'align': 'left'},
            {'label': 'Qty', 'align': 'right'},
            {'label': 'Value', 'align': 'right'},
          ],
          'rows': [
            [
              {'text': 'VesiBeta 25 Tablet ER'},
              {'text': '51'},
              // Not a product of anything on this row.
              {'text': '₹10431.38'},
            ],
          ],
        },
        {
          'kind': 'nav',
          'items': [
            {'label': 'Open all my orders', 'route': 'cust_orders'},
            // A route this build cannot resolve: skipped, never thrown.
            {'label': 'A screen from 2027', 'route': 'cust_not_built_yet'},
          ],
        },
      ],
    };

Map<String, dynamic> _calendar({String day = ''}) => {
      'ok': true,
      'blocks': [
        {
          'kind': 'chips',
          'arg': 'p_month',
          'chips': [
            {'key': '2026-09', 'value': '2026-09', 'label': 'Sep 2026', 'active': true},
            {'key': '2026-08', 'value': '2026-08', 'label': 'Aug 2026', 'active': false},
          ],
        },
        {
          'kind': 'calendar',
          'title': 'Days you ordered',
          'month_label': 'September 2026',
          'weekdays': ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'],
          'day_arg': 'p_day',
          'empty': 'No orders in this month.',
          'cells': [
            {'label': '', 'value': '', 'has': false, 'tone': 'muted'},
            {'label': '1', 'value': '2026-09-01', 'has': true, 'tone': 'brand'},
            {'label': '2', 'value': '2026-09-02', 'has': false, 'tone': 'muted'},
          ],
        },
        if (day.isNotEmpty)
          {
            'kind': 'list',
            'title': 'Orders on this day  ·  $day',
            'empty': 'No orders in this month.',
            'items': [
              {'title': 'CPO010926', 'subtitle': day, 'trailing': '₹1.00'}
            ],
          },
      ],
    };

Map<String, dynamic> _statement() => {
      'ok': true,
      'blocks': [
        {
          'kind': 'actions',
          'title': 'Monthly statement',
          'items': [
            {
              'label': 'Download PDF',
              'tone': 'brand',
              'kind': 'doc',
              'rpc': 'my_statement_request',
              'args': {'p_month': '2026-08'},
              'poll_rpc': 'my_statement_status',
              'poll_arg': 'p_statement_id',
            },
            {
              'label': 'Send on WhatsApp',
              'tone': 'success',
              'kind': 'rpc',
              'rpc': 'my_statement_wa',
              'args': {'p_statement_id': null},
              'enabled': false,
            },
          ],
        },
      ],
    };

Map<String, dynamic> _prefs() => {
      'ok': true,
      'blocks': [
        {
          'kind': 'toggles',
          'title': 'How we message you',
          'note': 'Turn off anything you do not want.',
          'rpc': 'my_notify_set',
          'value_arg': 'p_enabled',
          'items': [
            {
              'key': 'order_placed:whatsapp',
              'label': 'Order placed (confirmation + payment QR)',
              'caption': 'WhatsApp',
              'on': true,
              'args': {'p_action_key': 'order_placed', 'p_channel': 'whatsapp'},
            },
          ],
        },
        {
          'kind': 'select',
          'title': 'Message language',
          'rpc': 'notif_set_my_language',
          'arg': 'p_lang',
          'options': [
            {'value': 'en', 'label': 'English', 'active': true},
            {'value': 'hi', 'label': 'हिंदी', 'active': false},
          ],
        },
      ],
    };

// ── Harness ────────────────────────────────────────────────────────────────

class _Rec {
  final String rpc;
  final Map<String, dynamic> params;
  _Rec(this.rpc, this.params);
  @override
  String toString() => '$rpc$params';
}

late List<_Rec> calls;
late List<String> opened;

Future<void> _pump(WidgetTester tester,
    {Map<String, dynamic>? page,
    Map<String, dynamic> Function(String rpc, Map<String, dynamic> p)? tab,
    String initialTab = ''}) async {
  calls = [];
  opened = [];
  MyAccountScreen.rpcOverride = (rpc, params) async {
    calls.add(_Rec(rpc, params));
    if (rpc == 'my_account_page') return page ?? _page();
    if (tab != null) return tab(rpc, params);
    switch (rpc) {
      case 'tab_bills_v2':
        return _billing();
      case 'tab_shop_v2':
        return _shop();
      case 'tab_cal_v2':
        return _calendar(day: (params['p_day'] ?? '').toString());
      case 'tab_stmt_v2':
        return _statement();
      case 'tab_pref_v2':
        return _prefs();
      default:
        return {'ok': true, 'message': 'Saved.'};
    }
  };
  MyAccountScreen.openDoc = (bucket, path) async => opened.add('$bucket/$path');

  await tester.pumpWidget(
      MaterialApp(home: MyAccountScreen(initialTab: initialTab)));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);
  tearDown(() {
    MyAccountScreen.rpcOverride = null;
    MyAccountScreen.openDoc = null;
  });

  testWidgets('1 — the tab list, its order and each tab RPC are the payload\'s',
      (tester) async {
    await _pump(tester);

    for (final label in const [
      'Bills & Payments',
      'My Shop',
      'Order calendar',
      'Statement',
      'Preferences',
    ]) {
      expect(find.text(label), findsOneWidget, reason: '$label tab missing');
    }
    // default_tab decided which one loaded, and the RPC called is the one the
    // payload NAMED — not my_account_tab_billing.
    expect(calls.map((c) => c.rpc).toList(),
        equals(['my_account_page', 'tab_bills_v2']));
    expect(find.text('₹100.00'), findsOneWidget);

    // Switching tabs calls that tab's own rpc, once.
    await tester.tap(find.text('My Shop'));
    await tester.pumpAndSettle();
    expect(calls.last.rpc, 'tab_shop_v2');
  });

  testWidgets('2 — every figure prints verbatim; nothing is recomputed',
      (tester) async {
    await _pump(tester);

    // Outstanding is the backend's 999, not billed-minus-paid.
    expect(find.text('₹999.00'), findsOneWidget);
    expect(find.text('₹60.00'), findsNothing);
    expect(find.text('₹40.00 paid'), findsOneWidget);
    expect(find.text('₹100.50'), findsOneWidget);

    await tester.tap(find.text('My Shop'));
    await tester.pumpAndSettle();
    expect(find.text('51'), findsOneWidget);
    expect(find.text('₹10431.38'), findsOneWidget);
  });

  testWidgets('3 — a chip and a calendar day send the argument the block named',
      (tester) async {
    await _pump(tester, initialTab: 'calendar');
    expect(calls.last.rpc, 'tab_cal_v2');

    await tester.tap(find.text('Aug 2026'));
    await tester.pumpAndSettle();
    expect(calls.last.rpc, 'tab_cal_v2');
    expect(calls.last.params['p_month'], '2026-08');

    // A day cell carries p_day with the cell's own value, and the reload shows
    // the day list the backend then sent.
    await tester.tap(find.text('1'));
    await tester.pumpAndSettle();
    expect(calls.last.params['p_day'], '2026-09-01');
    expect(find.textContaining('Orders on this day'), findsOneWidget);
    expect(find.text('CPO010926'), findsOneWidget);
  });

  testWidgets('4 — a toggle and a language chip are the RPC the payload named',
      (tester) async {
    await _pump(tester, initialTab: 'preferences');

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    final t = calls.firstWhere((c) => c.rpc == 'my_notify_set');
    expect(t.params['p_action_key'], 'order_placed');
    expect(t.params['p_channel'], 'whatsapp');
    // The block's own value_arg carries the NEW value.
    expect(t.params['p_enabled'], false);

    await tester.tap(find.text('हिंदी'));
    await tester.pumpAndSettle();
    final l = calls.firstWhere((c) => c.rpc == 'notif_set_my_language');
    expect(l.params['p_lang'], 'hi');

    // The toast the backend's message raised is a real 4 s timer; drain it so
    // the tree can be disposed.
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('5 — a document is polled on the backend\'s poll_ms and opened '
      'at the backend\'s own bucket and path', (tester) async {
    var polls = 0;
    await _pump(tester, initialTab: 'statement', tab: (rpc, p) {
      switch (rpc) {
        case 'tab_stmt_v2':
          return _statement();
        case 'my_statement_request':
          return {
            'ok': true,
            'status': 'building',
            'statement_id': 'st-1',
            'poll_ms': 1,
            'message': 'Drawing your statement…',
          };
        case 'my_statement_status':
          polls++;
          if (polls < 2) {
            return {'ok': true, 'status': 'building', 'poll_ms': 1};
          }
          return {
            'ok': true,
            'status': 'ready',
            'statement_id': 'st-1',
            'bucket': 'customer-bills',
            'path': 'statement/c/st-1.pdf',
            'message': 'Your statement is ready.',
          };
        default:
          return {'ok': true};
      }
    });

    // The disabled button is absent — `enabled:false` is the backend's word.
    expect(find.text('Send on WhatsApp'), findsNothing);

    await tester.tap(find.text('Download PDF'));
    await tester.pumpAndSettle();

    final req = calls.firstWhere((c) => c.rpc == 'my_statement_request');
    expect(req.params['p_month'], '2026-08');
    expect(calls.where((c) => c.rpc == 'my_statement_status').length,
        greaterThanOrEqualTo(2));
    expect(calls.firstWhere((c) => c.rpc == 'my_statement_status')
        .params['p_statement_id'], 'st-1');
    expect(opened, ['customer-bills/statement/c/st-1.pdf']);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('6 — an unknown block kind and an unresolvable route are skipped',
      (tester) async {
    await _pump(tester);
    // The unknown kind sat in the billing payload and the tab still rendered.
    expect(find.text('must not throw'), findsNothing);
    expect(find.text('Bills'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('My Shop'));
    await tester.pumpAndSettle();
    expect(find.text('Open all my orders'), findsOneWidget);
    expect(find.text('A screen from 2027'), findsNothing);
  });

  testWidgets('7 — ok:false prints the backend\'s refusal instead of throwing',
      (tester) async {
    await _pump(tester, page: {
      'ok': false,
      'message': 'Sign in with your pharmacy account to see this page.',
    });
    expect(find.text('Sign in with your pharmacy account to see this page.'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
