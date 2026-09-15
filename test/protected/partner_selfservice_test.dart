// PROTECTED — CHANGE #399, the partner self-service surface.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes partner self-service behaviour, never to make an
// unrelated change go green.
//
// What this holds down:
//
//   1. THE SUBSET RULE IS THE BACKEND'S, AND THE SCREEN CANNOT WIDEN IT. The
//      access dropdown offered for a staff member is built from the payload's
//      `options` — nothing else. A feature the partner holds 'read' on arrives
//      with two options, so 'Full access' is not on the screen to be tapped,
//      and the change the screen sends back carries the backend's own
//      feature_key and value.
//
//   2. A PARTNER CAN ONLY EVER EDIT SOMEONE ELSE. can_edit / can_remove are
//      backend booleans; the row for your own login offers neither, so the two
//      self-escalation moves (lift yourself to the ceiling, delete the last
//      login) are unreachable before the RPC even sees them.
//
//   3. NO MONEY IS COMPUTED IN DART. total / paid / due / every ₹ string is
//      printed exactly as it arrived, and the due chip's tone is the payload's
//      `due_tone` — never a comparison done in the widget.
//
//   4. A READ-ONLY GRANT IS RENDERED, NOT INFERRED. can_write:false prints the
//      backend's own readonly sentence and leaves every row untappable; a
//      frozen settlement period is the payload's `frozen` flag, not a date the
//      widget worked out.
//
//   5. ROWS RENDER IN PAYLOAD ORDER, and a route_key this build has never heard
//      of opens nothing at all — the console skips it silently, which is what
//      lets the office add a partner feature without shipping an app.
//
// Fixtures mirror the real partner_staff_console() /
// partner_supplier_payment_console() / partner_expense_console() shapes. No
// network, no Supabase, no timers.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/partner/partner_home_screen.dart';
import 'package:pharma_b2b/screens/partner/partner_expense_screen.dart';
import 'package:pharma_b2b/screens/partner/partner_staff_screen.dart';
import 'package:pharma_b2b/screens/partner/partner_supplier_payment_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

/// partner_staff_console(): the partner holds WRITE on expenses and only READ
/// on supplier payment, so the staff row for supplier payment must arrive — and
/// render — with no 'Full access' option at all.
Map<String, dynamic> _staffPayload({bool canWrite = true}) => {
      'ok': true,
      'access': canWrite ? 'write' : 'read',
      'can_write': canWrite,
      'title': 'My staff',
      'subtitle': 'Logins that work inside your zone.',
      'add_label': 'Add staff login',
      'remove_label': 'Remove',
      'empty_text': 'No staff logins yet.',
      'perm_title': 'What this login can do',
      'perm_note': 'You can only give a staff member access you hold yourself.',
      'readonly_text': canWrite ? '' : 'You can view staff but not change them.',
      'users': [
        {
          'id': 51,
          'identity': 'staff@example.com',
          'display_name': 'Pallavi',
          'is_self': false,
          'self_label': '',
          'linked': true,
          'status_label': 'Signed in',
          'status_tone': 'success',
          'can_remove': canWrite,
          'can_edit': canWrite,
          'permissions': [
            {
              'feature_key': 'partner.expenses',
              'label': 'Expenses',
              'access': 'none',
              'inherited': false,
              'options': [
                {'value': 'none', 'label': 'No access', 'selected': true},
                {'value': 'read', 'label': 'View only', 'selected': false},
                {'value': 'write', 'label': 'Full access', 'selected': false},
              ],
            },
            {
              'feature_key': 'partner.supplier_payment',
              'label': 'Supplier payment',
              'access': 'read',
              'inherited': false,
              // The partner itself only holds 'read' here — so 'write' is
              // absent. This is the subset rule, arriving as data.
              'options': [
                {'value': 'none', 'label': 'No access', 'selected': false},
                {'value': 'read', 'label': 'View only', 'selected': true},
              ],
            },
          ],
        },
        {
          'id': 52,
          'identity': 'boss@example.com',
          'display_name': 'Om',
          'is_self': true,
          'self_label': 'This is you',
          'linked': true,
          'status_label': 'Signed in',
          'status_tone': 'success',
          'can_remove': false,
          'can_edit': false,
          'permissions': const [],
        },
      ],
    };

Map<String, dynamic> _payPayload({bool canWrite = true}) => {
      'ok': true,
      'can_write': canWrite,
      'title': 'Supplier payment',
      'subtitle': 'Record what you paid a supplier.',
      'empty_text': 'No supplier orders in your zone yet.',
      'readonly_text': canWrite ? '' : 'You can view supplier payments but not record them.',
      'rows': [
        {
          'supplier_order_id': 'aaaaaaaa-0000-0000-0000-000000000001',
          'supplier_name': 'ZEBRA PHARMA',
          'order_label': 'SO-902',
          'date_label': '31 Aug, 14:05',
          'total_text': '₹12,400.00',
          'paid_label': 'Paid',
          'paid_text': '₹4,000.00',
          'due_label': 'Due',
          'due_text': '₹8,400.00',
          'due_tone': 'warning',
          'can_record': canWrite,
        },
        {
          'supplier_order_id': 'aaaaaaaa-0000-0000-0000-000000000002',
          'supplier_name': 'ALPHA DISTRIBUTORS',
          'order_label': 'SO-901',
          'date_label': '30 Aug, 09:12',
          'total_text': '₹2,000.00',
          'paid_label': 'Paid',
          'paid_text': '₹2,000.00',
          'due_label': 'Due',
          'due_text': '₹0.00',
          'due_tone': 'success',
          'can_record': canWrite,
        },
      ],
    };

Map<String, dynamic> _expensePayload({bool canWrite = true}) => {
      'ok': true,
      'can_write': canWrite,
      'title': 'Expenses',
      'subtitle': 'Costs you paid on an order.',
      'save_label': 'Save expense',
      'empty_text': 'No orders in your zone yet.',
      'frozen_text': "That order's settlement is already closed",
      'readonly_text': canWrite ? '' : 'You can view expenses but not add them.',
      'cost_types': [
        {'value': 'delivery', 'label': 'Delivery'},
        {'value': 'packaging', 'label': 'Packaging'},
      ],
      'rows': [
        {
          'order_id': 'bbbbbbbb-0000-0000-0000-000000000001',
          'order_label': 'ORD-77',
          'customer_label': 'Shree Medical',
          'date_label': '31 Aug, 11:00',
          'total_text': '₹5,600.00',
          'frozen': false,
          'can_add': canWrite,
          'existing_label': 'On this order',
          'existing': [
            {
              'cost_type': 'delivery',
              'label': 'Delivery',
              'value_text': '₹180.00',
              'source': 'manual',
              'note': 'auto rickshaw',
              'has_receipt': true,
            },
          ],
        },
        {
          'order_id': 'bbbbbbbb-0000-0000-0000-000000000002',
          'order_label': 'ORD-76',
          'customer_label': 'Kumar Chemists',
          'date_label': '29 Aug, 16:40',
          'total_text': '₹1,100.00',
          // Frozen: the period closed. The widget must not decide this.
          'frozen': true,
          'can_add': canWrite,
          'existing_label': 'On this order',
          'existing': const [],
        },
      ],
    };

void main() {
  setUpAll(() {
    // The 800 ms debounce is a real Timer that would outlive the test and try
    // to reach Supabase.
    RenderLog.flushEnabled = false;
  });

  group('staff — the permission subset is the backend\'s, rendered verbatim', () {
    testWidgets('a feature the partner holds read on offers no write option',
        (tester) async {
      await tester.pumpWidget(_host(PartnerStaffView(
        payload: _staffPayload(),
        onRemove: (_) {},
        onAccessSet: (_, __, ___) {},
      )));

      // Expenses (partner holds write) offers all three.
      expect(find.text('Full access'), findsNothing,
          reason: 'closed dropdowns show only the selected value');

      // Open the supplier-payment dropdown for the staff member.
      final dropdowns = find.byType(DropdownButton<String>);
      expect(dropdowns, findsNWidgets(2));
      await tester.tap(dropdowns.at(1));
      await tester.pumpAndSettle();

      expect(find.text('View only'), findsWidgets);
      expect(find.text('No access'), findsWidgets);
      // The one thing that must never be offerable: more than the partner holds.
      expect(find.text('Full access'), findsNothing);
    });

    testWidgets('changing access sends the backend\'s own key and value',
        (tester) async {
      final sent = <List<Object>>[];
      await tester.pumpWidget(_host(PartnerStaffView(
        payload: _staffPayload(),
        onRemove: (_) {},
        onAccessSet: (uid, key, access) => sent.add([uid, key, access]),
      )));

      await tester.tap(find.byType(DropdownButton<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Full access').last);
      await tester.pumpAndSettle();

      expect(sent, hasLength(1));
      expect(sent.first[0], 51);
      expect(sent.first[1], 'partner.expenses');
      expect(sent.first[2], 'write');
    });

    testWidgets('your own login offers neither Remove nor an editable dropdown',
        (tester) async {
      await tester.pumpWidget(_host(PartnerStaffView(
        payload: _staffPayload(),
        onRemove: (_) {},
        onAccessSet: (_, __, ___) {},
      )));

      expect(find.text('This is you'), findsOneWidget);
      // Exactly one Remove button — the other user's. Never your own.
      expect(find.widgetWithText(OutlinedButton, 'Remove'), findsOneWidget);
    });

    testWidgets('can_write:false prints the backend sentence and disables edits',
        (tester) async {
      await tester.pumpWidget(_host(PartnerStaffView(
        payload: _staffPayload(canWrite: false),
        onRemove: (_) {},
        onAccessSet: (_, __, ___) {},
      )));

      expect(find.text('You can view staff but not change them.'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Remove'), findsNothing);
      final dd = tester.widget<DropdownButton<String>>(
          find.byType(DropdownButton<String>).first);
      expect(dd.onChanged, isNull, reason: 'read access must not be editable');
    });

    testWidgets('no staff yet renders the backend empty state', (tester) async {
      final p = _staffPayload()..['users'] = const [];
      await tester.pumpWidget(_host(PartnerStaffView(
        payload: p,
        onRemove: (_) {},
        onAccessSet: (_, __, ___) {},
      )));
      expect(find.text('No staff logins yet.'), findsOneWidget);
    });
  });

  group('supplier payment — every rupee is a backend string', () {
    testWidgets('totals, paid and due print verbatim, in payload order',
        (tester) async {
      await tester.pumpWidget(_host(PartnerSupplierPaymentView(
        payload: _payPayload(),
        onTapRow: (_) {},
      )));

      expect(find.text('₹12,400.00'), findsOneWidget);
      expect(find.text('Paid ₹4,000.00'), findsOneWidget);
      expect(find.text('Due ₹8,400.00'), findsOneWidget);
      expect(find.text('Due ₹0.00'), findsOneWidget);

      final names = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .whereType<String>()
          .toList();
      expect(names.indexOf('ZEBRA PHARMA'),
          lessThan(names.indexOf('ALPHA DISTRIBUTORS')),
          reason: 'rows render in payload order, never re-sorted');
    });

    testWidgets('a row is tappable only when the backend says can_record',
        (tester) async {
      final tapped = <String>[];
      await tester.pumpWidget(_host(PartnerSupplierPaymentView(
        payload: _payPayload(),
        onTapRow: (r) => tapped.add(r['supplier_order_id'] as String),
      )));
      await tester.tap(find.text('ZEBRA PHARMA'));
      await tester.pumpAndSettle();
      expect(tapped, ['aaaaaaaa-0000-0000-0000-000000000001']);

      await tester.pumpWidget(_host(PartnerSupplierPaymentView(
        payload: _payPayload(canWrite: false),
        onTapRow: (r) => tapped.add(r['supplier_order_id'] as String),
      )));
      await tester.tap(find.text('ZEBRA PHARMA'));
      await tester.pumpAndSettle();
      expect(tapped, hasLength(1), reason: 'read-only rows are not tappable');
      expect(
          find.text('You can view supplier payments but not record them.'),
          findsOneWidget);
    });
  });

  group('expenses — frozen and read-only are flags, not deductions', () {
    testWidgets('an existing manual line prints its own formatted value',
        (tester) async {
      await tester.pumpWidget(_host(PartnerExpenseView(
        payload: _expensePayload(),
        onTapRow: (_) {},
      )));
      expect(find.text('On this order'), findsOneWidget);
      expect(find.text('₹180.00'), findsOneWidget);
    });

    testWidgets('a frozen order shows the backend copy and cannot be tapped',
        (tester) async {
      final tapped = <String>[];
      await tester.pumpWidget(_host(PartnerExpenseView(
        payload: _expensePayload(),
        onTapRow: (r) => tapped.add(r['order_label'] as String),
      )));

      expect(find.text("That order's settlement is already closed"),
          findsOneWidget);

      await tester.tap(find.text('ORD-76'));
      await tester.pumpAndSettle();
      expect(tapped, isEmpty, reason: 'a closed period accepts no new expense');

      await tester.tap(find.text('ORD-77'));
      await tester.pumpAndSettle();
      expect(tapped, ['ORD-77']);
    });

    testWidgets('read-only prints the backend sentence and blocks every row',
        (tester) async {
      final tapped = <String>[];
      await tester.pumpWidget(_host(PartnerExpenseView(
        payload: _expensePayload(canWrite: false),
        onTapRow: (r) => tapped.add(r['order_label'] as String),
      )));
      expect(find.text('You can view expenses but not add them.'), findsOneWidget);
      await tester.tap(find.text('ORD-77'));
      await tester.pumpAndSettle();
      expect(tapped, isEmpty);
    });
  });

  group('routing — the backend names the destination, and an unknown one opens nothing', () {
    test('the three self-service route keys resolve to their own screens', () {
      expect(partnerDestination('partner_staff'), isA<PartnerStaffScreen>());
      expect(partnerDestination('partner_expenses'), isA<PartnerExpenseScreen>());
      // #326 pointed supplier_payment at AdminSupplierScreen, whose pay panel
      // calls sup_record_payment — super_admin only, so a partner could open
      // the screen and never record anything. It is the partner's own surface
      // now.
      expect(partnerDestination('supplier_payment'),
          isA<PartnerSupplierPaymentScreen>());
    });

    test('a route key this build has never heard of resolves to nothing', () {
      // Forward compatibility: the office may register a partner feature before
      // the app can open it. partner_home must skip it in silence rather than
      // draw a tile that does nothing on tap.
      expect(partnerDestination('partner_something_new'), isNull);
      expect(partnerDestination(''), isNull);
    });

    test('a self-service screen brings no Scaffold of its own', () {
      // Every destination is pushed inside PartnerFeaturePage, which owns the
      // Scaffold and prints the BACKEND's label as the page title. A screen
      // that carried its own would show two app bars, one of them titled by
      // Dart.
      for (final w in [
        partnerDestination('partner_staff'),
        partnerDestination('partner_expenses'),
        partnerDestination('supplier_payment'),
      ]) {
        expect(w, isNot(isA<Scaffold>()));
      }
    });
  });
}
