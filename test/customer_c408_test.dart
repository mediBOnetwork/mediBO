// CHANGE #408 — the two new customer surfaces decide nothing.
//
// Both screens are pure renderers of one payload, so both are tested by handing
// them a payload and asserting that what appears is what the BACKEND sent — and
// that what the backend did not send does not appear.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/customer/customer_staff_screen.dart';
import 'package:pharma_b2b/screens/customer/order_edit_sheet.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

Map<String, dynamic> _staffPayload({
  bool canManage = true,
  List<Map<String, dynamic>>? options,
  List<Map<String, dynamic>>? rows,
}) =>
    {
      'ok': true,
      'title': 'Staff logins',
      'subtitle': 'People at your pharmacy who can sign in.',
      'can_manage': canManage,
      'add_label': 'Add staff',
      'add_hint': 'Phone number or email',
      'name_hint': 'Name (optional)',
      'save_label': 'Add',
      'remove_label': 'Remove',
      'access_label': 'Access',
      'empty': 'No staff logins yet.',
      'activity_heading': 'Recent activity',
      'activity_empty': 'Nothing yet.',
      'access_options': options ??
          [
            {'access_key': 'order_only', 'label': 'Orders only', 'description': 'Place and edit orders.'},
            {'access_key': 'order_payments', 'label': 'Orders and payments', 'description': 'Plus bills.'},
            {'access_key': 'full', 'label': 'Full access', 'description': 'Including staff.'},
          ],
      'rows': rows ??
          [
            {
              'id': null,
              'identity': 'owner@pharmacy.in',
              'name': 'Jai Mahakal Medical',
              'access_key': null,
              'access_label': 'Owner · full access',
              'is_owner': true,
              'is_self': true,
              'can_remove': false,
              'can_edit_access': false,
              'added_label': '',
            },
          ],
      'activity': const [],
    };

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('customer staff screen', () {
    testWidgets('every label is the payload\'s, and the owner cannot be removed',
        (tester) async {
      await tester.pumpWidget(_host(CustomerStaffView(
        payload: _staffPayload(),
        onRemove: (_) {},
        onAccessChanged: (_, __) {},
        onAdd: () {},
        identityCtrl: TextEditingController(),
        nameCtrl: TextEditingController(),
        addAccessKey: 'order_only',
        onAddAccessChanged: (_) {},
      )));

      expect(find.text('Staff logins'), findsOneWidget);
      expect(find.text('People at your pharmacy who can sign in.'), findsOneWidget);
      expect(find.text('Add staff'), findsOneWidget);
      expect(find.text('Jai Mahakal Medical'), findsOneWidget);
      expect(find.text('Owner · full access'), findsOneWidget);
      // The owner row offers no Remove: can_remove was false.
      expect(find.text('Remove'), findsNothing);
    });

    testWidgets(
        'the access dropdown offers ONLY what the backend sent — a level it '
        'withheld can never be picked', (tester) async {
      await tester.pumpWidget(_host(CustomerStaffView(
        // An order_only staff member: the backend caps access_options at their
        // own rank, so 'Full access' is not in the payload at all.
        payload: _staffPayload(
          canManage: false,
          options: [
            {'access_key': 'order_only', 'label': 'Orders only', 'description': ''},
          ],
          rows: [
            {
              'id': 7,
              'identity': '9812340408',
              'name': 'Counter Ramesh',
              'access_key': 'order_only',
              'access_label': 'Orders only',
              'is_owner': false,
              'is_self': true,
              'can_remove': false,
              'can_edit_access': false,
              'added_label': 'Added 01/09/2026',
            },
          ],
        ),
        onRemove: (_) {},
        onAccessChanged: (_, __) {},
        onAdd: () {},
        identityCtrl: TextEditingController(),
        nameCtrl: TextEditingController(),
        addAccessKey: 'order_only',
        onAddAccessChanged: (_) {},
      )));

      expect(find.text('Counter Ramesh'), findsOneWidget);
      expect(find.text('Added 01/09/2026'), findsOneWidget);
      // can_manage false => no add card at all, so no way to grant anything.
      expect(find.text('Add staff'), findsNothing);
      // Their own row is not editable and not removable.
      expect(find.text('Remove'), findsNothing);
      // And the level they do not hold was never rendered.
      expect(find.text('Full access'), findsNothing);
    });

    testWidgets('ok:false renders the backend refusal, not a Dart sentence',
        (tester) async {
      await tester.pumpWidget(_host(CustomerStaffView(
        payload: const {
          'ok': false,
          'error': 'not_authorized',
          'message': 'Only the pharmacy owner can manage staff logins.',
        },
        onRemove: (_) {},
        onAccessChanged: (_, __) {},
        onAdd: () {},
        identityCtrl: TextEditingController(),
        nameCtrl: TextEditingController(),
        addAccessKey: '',
        onAddAccessChanged: (_) {},
      )));

      expect(find.text('Only the pharmacy owner can manage staff logins.'),
          findsOneWidget);
      expect(find.text('Staff logins'), findsNothing);
    });

    testWidgets('activity names a person and an action, both verbatim',
        (tester) async {
      final p = _staffPayload();
      p['activity'] = [
        {
          'when': '01/09/2026 08:44',
          'who': 'Counter Ramesh',
          'what': 'edited an order',
          'order_code': 'ORD-4408',
        },
      ];
      await tester.pumpWidget(_host(CustomerStaffView(
        payload: p,
        onRemove: (_) {},
        onAccessChanged: (_, __) {},
        onAdd: () {},
        identityCtrl: TextEditingController(),
        nameCtrl: TextEditingController(),
        addAccessKey: 'order_only',
        onAddAccessChanged: (_) {},
      )));

      expect(find.text('Counter Ramesh · edited an order'), findsOneWidget);
      expect(find.text('ORD-4408'), findsOneWidget);
      expect(find.text('01/09/2026 08:44'), findsOneWidget);
      expect(find.text('Nothing yet.'), findsNothing);
    });
  });

  group('order edit affordance', () {
    testWidgets('can_edit:false draws NOTHING — not a greyed-out button',
        (tester) async {
      await tester.pumpWidget(_host(OrderEditButton(
        state: const {
          'can_edit': false,
          'error': 'inquiry_started',
          'reason': 'Suppliers have been asked',
          'message': 'We have already started asking suppliers.',
          // a button_label is present and must STILL not be drawn: can_edit is
          // the flag, never the presence of copy.
          'button_label': 'Edit order',
        },
        onTap: () {},
      )));

      expect(find.byType(OutlinedButton), findsNothing);
      expect(find.text('Edit order'), findsNothing);
    });

    testWidgets('can_edit:true draws the backend\'s own label', (tester) async {
      await tester.pumpWidget(_host(OrderEditButton(
        state: const {'can_edit': true, 'button_label': 'Change this order'},
        onTap: () {},
      )));

      expect(find.text('Change this order'), findsOneWidget);
    });

    testWidgets('a missing label draws nothing rather than a Dart fallback',
        (tester) async {
      await tester.pumpWidget(_host(OrderEditButton(
        state: const {'can_edit': true},
        onTap: () {},
      )));

      expect(find.byType(OutlinedButton), findsNothing);
    });
  });

  group('order edit sheet', () {
    Map<String, dynamic> statePayload() => {
          'ok': true,
          'can_edit': true,
          'title': 'Edit this order',
          'subtitle': 'You can still change this basket.',
          'button_label': 'Edit order',
          'save_label': 'Save changes',
          'add_label': 'Add item',
          'search_hint': 'Search medicines to add',
          'qty_label': 'Qty',
          'remove_label': 'Remove',
          'window_label': 'Editable until we ask a supplier',
          'empty_message': 'An order needs at least one item.',
          'lines': const [],
        };

    testWidgets('lines render in payload order — no client sort',
        (tester) async {
      final lines = [
        OrderEditLine(productId: 3, name: 'Zincovit', quantity: 2),
        OrderEditLine(productId: 1, name: 'Amoxyclav', quantity: 1),
      ];
      await tester.pumpWidget(_host(OrderEditView(
        payload: statePayload(),
        lines: lines,
        onQty: (_, __) {},
        onRemove: (_) {},
        onSave: () {},
        onAddTap: () {},
      )));

      final texts = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .whereType<String>()
          .toList();
      expect(texts.indexOf('Zincovit') < texts.indexOf('Amoxyclav'), isTrue,
          reason: 'the sheet must not reorder what the backend sent');
      expect(find.text('Editable until we ask a supplier'), findsOneWidget);
      expect(find.text('Save changes'), findsOneWidget);
    });

    testWidgets('quantity never drops below 1 — emptying a line is Remove',
        (tester) async {
      final line = OrderEditLine(productId: 1, name: 'Amoxyclav', quantity: 1);
      var changed = -1;
      await tester.pumpWidget(_host(OrderEditView(
        payload: statePayload(),
        lines: [line],
        onQty: (_, q) => changed = q,
        onRemove: (_) {},
        onSave: () {},
        onAddTap: () {},
      )));

      await tester.tap(find.byIcon(Icons.remove));
      await tester.pump();
      expect(changed, -1, reason: 'the minus is inert at 1, never sending 0');

      await tester.tap(find.byIcon(Icons.add));
      await tester.pump();
      expect(changed, 2);
    });

    testWidgets('an empty basket cannot be saved, and says why', (tester) async {
      await tester.pumpWidget(_host(OrderEditView(
        payload: statePayload(),
        lines: const [],
        onQty: (_, __) {},
        onRemove: (_) {},
        onSave: () {},
        onAddTap: () {},
      )));

      expect(find.text('An order needs at least one item.'), findsOneWidget);
      final save = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(save.onPressed, isNull);
    });
  });
}
