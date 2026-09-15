// PROTECTED — CHANGE #850.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes the SUPPLIER account page's behaviour.
//
// The supplier's My Account is #840's renderer pointed at a second backend
// page, and this holds down the four things that makes true:
//
//   1. IT ASKS supplier_account_page(). Not my_account_page, not a name built
//      from a role check in Dart. The customer's page keeps its own RPC — the
//      parameter defaults, so #840 cannot be broken by #850.
//
//   2. THE TAB LIST, ITS ORDER AND EACH TAB'S RPC ARE THE BACKEND'S. The
//      fixture's tabs are deliberately NOT in alphabetical order and one tab's
//      rpc is deliberately not 'supplier_account_tab_<key>', so a screen that
//      sorted or guessed fails here.
//
//   3. NOTHING IS COMPUTED IN DART. Rupees, counts, percentages, chip labels
//      and empty states print verbatim — the fixture's tiles deliberately
//      disagree with what any client-side arithmetic would produce.
//
//   4. THE SUPPLIER NAV RESOLVER IS THE SUPPLIER'S. A supplier route_key
//      ('staff') resolves; a customer one ('cust_orders') does not, and an
//      unknown row is skipped in silence rather than throwing.
//
// And ok:false prints the backend's refusal instead of an exception.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/customer/my_account_screen.dart';
import 'package:pharma_b2b/screens/supplier/supplier_account_page.dart';
import 'package:pharma_b2b/utils/render_log.dart';

class _Rec {
  final String rpc;
  final Map<String, dynamic> params;
  _Rec(this.rpc, this.params);
  @override
  String toString() => '$rpc$params';
}

late List<_Rec> calls;

Map<String, dynamic> _page() => {
      'ok': true,
      'title': 'Sagar Medicals',
      'subtitle': 'SUP-014  ·  Zone 2  ·  Raipur',
      'chips': [
        {'show': true, 'label': 'Licence OK', 'bg': '#D1FAE5', 'fg': '#065F46'},
        {'show': true, 'label': 'Shop open', 'bg': '#D1FAE5', 'fg': '#065F46'},
      ],
      // Deliberately NOT alphabetical, and 'payments' names an RPC that does
      // not follow the supplier_account_tab_<key> pattern.
      'tabs': [
        {'key': 'profile', 'label': 'Profile & KYC', 'rpc': 'supplier_account_tab_profile'},
        {'key': 'availability', 'label': 'Availability', 'rpc': 'supplier_account_tab_availability'},
        {'key': 'companies', 'label': 'Companies', 'rpc': 'supplier_account_tab_companies'},
        {'key': 'payments', 'label': 'Payments & bills', 'rpc': 'sup_pay_tab_v9'},
      ],
      'default_tab': 'profile',
      'empty_label': 'Nothing to show on this tab yet.',
      'more_label': 'Load more',
    };

Map<String, dynamic> _profile() => {
      'ok': true,
      'blocks': [
        {
          'kind': 'kv',
          'title': 'Shop',
          'rows': [
            {'label': 'Shop name', 'value': 'Sagar Medicals'},
            {'label': 'Supplier code', 'value': 'SUP-014'},
            {'label': 'Zone', 'value': 'Zone 2'},
          ],
        },
        {
          'kind': 'actions',
          'title': 'Edit my details',
          'note': 'Shop name, code and zone are set by mediBO.',
          'items': [
            {
              'label': 'Phone',
              'tone': 'brand',
              'kind': 'rpc',
              'rpc': 'supplier_account_profile_set',
              'args': {'p_field': 'phone'},
              'prompt': {
                'arg': 'p_value',
                'title': 'Phone',
                'hint': '9876543210',
                'ok': 'Save',
                'cancel': 'Cancel',
              },
            },
          ],
        },
        // A kind this build has never heard of must render nothing at all.
        {'kind': 'hologram', 'title': 'From the future'},
      ],
    };

Map<String, dynamic> _availability(String zone) => {
      'ok': true,
      'zone_id': zone,
      'blocks': [
        {
          'kind': 'chips',
          'key': 'zone',
          'arg': 'p_zone_id',
          'title': 'Zone',
          'chips': [
            {'key': '1', 'value': 1, 'label': '① Raipur', 'count': 12, 'active': zone != '3'},
            {'key': '3', 'value': 3, 'label': '③ Bhilai', 'count': 4, 'active': zone == '3'},
          ],
        },
        {
          'kind': 'list',
          'title': 'Update a whole company',
          'empty': 'No company to update in bulk yet.',
          'items': [
            {
              'title': 'Alkem Laboratories',
              // 9 products, but the label says 41 — a screen that counted
              // anything itself fails here.
              'subtitle': '41 products',
              'actions': [
                {
                  'label': 'All out of stock',
                  'tone': 'danger',
                  'kind': 'rpc',
                  'rpc': 'supplier_account_bulk_availability',
                  'args': {'p_company': 'Alkem Laboratories', 'p_state': 'Out of Stock'},
                },
              ],
            },
          ],
        },
      ],
    };

Map<String, dynamic> _companies() => {
      'ok': true,
      'blocks': [
        {
          'kind': 'tiles',
          'tiles': [
            {'label': 'Companies', 'value': '18', 'tone': 'neutral'},
            {'label': 'Matched', 'value': '11', 'tone': 'success'},
            // 18 - 11 is 7; the backend says 6 and the screen must print 6.
            {'label': 'Unmatched', 'value': '6', 'tone': 'warning'},
          ],
        },
        {
          'kind': 'nav',
          'title': 'Elsewhere',
          'items': [
            {'route': 'staff', 'label': 'Manage staff', 'caption': 'Add a login'},
            {'route': 'cust_orders', 'label': 'Customer orders'},
            {'route': 'not_a_screen_yet', 'label': 'Ships next week'},
          ],
        },
      ],
    };

Map<String, dynamic> _payments() => {
      'ok': true,
      'blocks': [
        {
          'kind': 'tiles',
          'tiles': [
            {'label': 'Billed', 'value': '₹ 1,20,450.00', 'tone': 'neutral'},
            {'label': 'Pending', 'value': '₹ 9,999.00', 'tone': 'warning'},
          ],
        },
      ],
    };

Future<void> _pump(WidgetTester tester,
    {Map<String, dynamic>? page,
    Map<String, dynamic> Function(String rpc, Map<String, dynamic> p)? tab,
    String initialTab = ''}) async {
  calls = [];
  MyAccountScreen.rpcOverride = (rpc, params) async {
    calls.add(_Rec(rpc, params));
    if (rpc == 'supplier_account_page') return page ?? _page();
    if (tab != null) return tab(rpc, params);
    switch (rpc) {
      case 'supplier_account_tab_profile':
        return _profile();
      case 'supplier_account_tab_availability':
        return _availability((params['p_zone_id'] ?? '').toString());
      case 'supplier_account_tab_companies':
        return _companies();
      case 'sup_pay_tab_v9':
        return _payments();
      default:
        return {'ok': true, 'message': 'Saved.'};
    }
  };

  await tester.pumpWidget(
      MaterialApp(home: SupplierAccountPage(initialTab: initialTab)));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);
  tearDown(() => MyAccountScreen.rpcOverride = null);

  testWidgets('1 — the page asks supplier_account_page, never the customer one',
      (tester) async {
    await _pump(tester);

    expect(calls.first.rpc, 'supplier_account_page');
    expect(calls.map((c) => c.rpc), isNot(contains('my_account_page')));
  });

  testWidgets('2 — the customer page still asks its own RPC (default unchanged)',
      (tester) async {
    final asked = <String>[];
    MyAccountScreen.rpcOverride = (rpc, params) async {
      asked.add(rpc);
      return {'ok': true, 'tabs': const [], 'empty_label': 'Nothing here.'};
    };
    await tester.pumpWidget(const MaterialApp(home: MyAccountScreen()));
    await tester.pumpAndSettle();

    expect(asked.first, 'my_account_page');
  });

  testWidgets('3 — tab labels and their order are the payload\'s', (tester) async {
    await _pump(tester);

    for (final label in const [
      'Profile & KYC',
      'Availability',
      'Companies',
      'Payments & bills',
    ]) {
      expect(find.text(label), findsOneWidget, reason: '$label tab missing');
    }

    // Payload order, not alphabetical: Availability sits left of Companies.
    final avail = tester.getTopLeft(find.text('Availability')).dx;
    final comps = tester.getTopLeft(find.text('Companies')).dx;
    expect(avail, lessThan(comps));
  });

  testWidgets('4 — each tab calls the RPC the registry named', (tester) async {
    await _pump(tester);
    expect(calls.map((c) => c.rpc), contains('supplier_account_tab_profile'));

    // 'payments' names sup_pay_tab_v9 — a screen that built the name from the
    // tab key would call supplier_account_tab_payments and fail here.
    await tester.tap(find.text('Payments & bills'));
    await tester.pumpAndSettle();
    expect(calls.map((c) => c.rpc), contains('sup_pay_tab_v9'));
    expect(calls.map((c) => c.rpc),
        isNot(contains('supplier_account_tab_payments')));
    expect(find.text('₹ 1,20,450.00'), findsOneWidget);
    expect(find.text('₹ 9,999.00'), findsOneWidget);
  });

  testWidgets('5 — nothing on the page is computed in Dart', (tester) async {
    await _pump(tester);
    await tester.tap(find.text('Companies'));
    await tester.pumpAndSettle();

    // 18 - 11 = 7, but the backend said 6.
    expect(find.text('18'), findsOneWidget);
    expect(find.text('11'), findsOneWidget);
    expect(find.text('6'), findsOneWidget);
    expect(find.text('7'), findsNothing);

    await tester.tap(find.text('Availability'));
    await tester.pumpAndSettle();
    expect(find.text('41 products'), findsOneWidget);
  });

  testWidgets('6 — a chip sends the backend\'s own arg and value',
      (tester) async {
    await _pump(tester);
    await tester.tap(find.text('Availability'));
    await tester.pumpAndSettle();

    calls.clear();
    await tester.tap(find.textContaining('③ Bhilai'));
    await tester.pumpAndSettle();

    final hit = calls.firstWhere(
        (c) => c.rpc == 'supplier_account_tab_availability',
        orElse: () => _Rec('none', const {}));
    expect(hit.params['p_zone_id'], 3);
  });

  testWidgets('7 — a row action calls the payload\'s rpc with its own args',
      (tester) async {
    await _pump(tester);
    await tester.tap(find.text('Availability'));
    await tester.pumpAndSettle();

    calls.clear();
    await tester.ensureVisible(find.text('All out of stock'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All out of stock'));
    await tester.pumpAndSettle();

    final hit = calls.firstWhere(
        (c) => c.rpc == 'supplier_account_bulk_availability',
        orElse: () => _Rec('none', const {}));
    expect(hit.params['p_company'], 'Alkem Laboratories');
    expect(hit.params['p_state'], 'Out of Stock');

    // The toast the backend's message raised is a real 4 s timer; drain it so
    // the tree can be disposed.
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('8 — the nav resolver is the supplier\'s, and unknown routes are '
      'skipped in silence', (tester) async {
    await _pump(tester);
    await tester.tap(find.text('Companies'));
    await tester.pumpAndSettle();

    expect(supplierAccountMenuScreen('staff'), isNotNull);
    expect(supplierAccountMenuScreen('payout'), isNotNull);
    expect(supplierAccountMenuScreen('cust_orders'), isNull);
    expect(supplierAccountMenuScreen('not_a_screen_yet'), isNull);

    expect(find.text('Manage staff'), findsOneWidget);
    expect(find.text('Customer orders'), findsNothing);
    expect(find.text('Ships next week'), findsNothing);
  });

  testWidgets('9 — an unknown block kind renders zero pixels, never a throw',
      (tester) async {
    await _pump(tester);
    expect(find.text('From the future'), findsNothing);
    expect(find.text('Sagar Medicals'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('10 — ok:false prints the backend\'s refusal', (tester) async {
    await _pump(tester,
        page: {
          'ok': false,
          'error': 'not_a_supplier',
          'message': 'This login is not linked to a supplier account.',
        });

    expect(find.text('This login is not linked to a supplier account.'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
