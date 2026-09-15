// CHANGE #318 — the discount-slab admin screen decides NOTHING.
//
// The ladder is a data table an admin edits; the screen is a window onto it.
// What this holds down:
//
//   1. Every word on the screen is the backend's: title, subtitle, the
//      commitment note, each row's amount / percent / effective / status
//      label, the toggle caption, the add and delete captions. Nothing here
//      formats a rupee, a percent or a date, and nothing pluralises.
//
//   2. Rows render in PAYLOAD ORDER. The fixture is deliberately not sorted by
//      amount, so a client-side sort would show.
//
//   3. The toggle sends the backend's own `toggle_to`, never `!active`
//      computed in Dart — the payload is the single source of that answer.
//
//   4. A mutation re-renders from the RPC's OWN reply. The reply here carries a
//      different ladder from the one first loaded, and the screen must show the
//      reply's rows, not a locally patched copy of the old ones.
//
//   5. not_authorized is an empty state showing the backend's message, with no
//      Add button offered — never a thrown error and never a Dart-worded one.
//
//   6. The editor sheet draws exactly the fields[] the backend sent, in order,
//      and submits them as a patch keyed by the backend's own field keys — so
//      a sixth slab, or a new column on one, is a payload change.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/admin_discount_slabs_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _row({
  required int id,
  required String amount,
  required String pct,
  required bool active,
  String status = 'Active',
  String tone = 'success',
  String toggle = 'Deactivate',
  bool toggleTo = false,
  String effective = 'From 01 Jan 2000',
}) =>
    <String, dynamic>{
      'id': id,
      'min_amount': 2999,
      'discount_pct': 3,
      'effective_from': '2000-01-01',
      'active': active,
      'note': '',
      'amount_label': amount,
      'pct_label': pct,
      'effective_label': effective,
      'status_label': status,
      'status_tone': tone,
      'toggle_label': toggle,
      'toggle_to': toggleTo,
    };

Map<String, dynamic> _payload({List<Map<String, dynamic>>? rows}) =>
    <String, dynamic>{
      'ok': true,
      'title': 'Discount slabs',
      'subtitle': 'The discount every customer bill is priced at.',
      'commitment_note': 'The slab is a commitment to the customer.',
      'add_label': 'Add slab',
      'edit_label': 'Edit',
      'save_label': 'Save slab',
      'cancel_label': 'Cancel',
      'delete_label': 'Delete',
      'delete_confirm': 'Delete this slab?',
      'empty_title': 'No slabs yet',
      'empty_hint': 'Add a slab and every bill above its amount is discounted.',
      'today': '2026-08-31',
      'fields': [
        {'key': 'min_amount', 'label': 'Above amount (₹)', 'hint': 'A bill above this.', 'kind': 'number'},
        {'key': 'discount_pct', 'label': 'Discount %', 'hint': 'Before GST.', 'kind': 'number'},
        {'key': 'effective_from', 'label': 'Effective from', 'hint': 'The day it starts.', 'kind': 'date'},
      ],
      // Deliberately NOT ascending by amount.
      'rows': rows ??
          [
            _row(id: 7, amount: 'Above ₹99,999', pct: '8%', active: true),
            _row(id: 1, amount: 'Above ₹2,999', pct: '3%', active: true),
            _row(
                id: 5,
                amount: 'Above ₹19,999',
                pct: '6%',
                active: false,
                status: 'Off',
                tone: 'neutral',
                toggle: 'Activate',
                toggleTo: true),
          ],
    };

Widget _host({
  required SlabsListRpc list,
  SlabsSaveRpc? save,
  SlabsActiveRpc? active,
  SlabsDeleteRpc? del,
}) =>
    MaterialApp(
      home: AdminDiscountSlabsScreen(
        listRpc: list,
        saveRpc: save ?? (_) async => _payload(),
        setActiveRpc: active ?? (_, __) async => _payload(),
        deleteRpc: del ?? (_) async => _payload(),
      ),
    );

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  testWidgets('every word comes from the payload', (tester) async {
    await tester.pumpWidget(_host(list: () async => _payload()));
    await tester.pumpAndSettle();

    expect(find.text('Discount slabs'), findsOneWidget);
    expect(find.text('The discount every customer bill is priced at.'),
        findsOneWidget);
    expect(find.text('The slab is a commitment to the customer.'),
        findsOneWidget);
    expect(find.text('Above ₹99,999'), findsOneWidget);
    expect(find.text('8%'), findsOneWidget);
    expect(find.text('From 01 Jan 2000'), findsNWidgets(3));
    expect(find.text('Off'), findsOneWidget);
    expect(find.text('Activate'), findsOneWidget);
    expect(find.text('Deactivate'), findsNWidgets(2));
    expect(find.text('Add slab'), findsOneWidget);
  });

  testWidgets('rows render in payload order, never re-sorted', (tester) async {
    await tester.pumpWidget(_host(list: () async => _payload()));
    await tester.pumpAndSettle();

    final cards = tester.widgetList<SlabCard>(find.byType(SlabCard)).toList();
    expect(cards.map((c) => c.row['id']).toList(), <int>[7, 1, 5]);
  });

  testWidgets('the toggle sends the backend toggle_to, not !active',
      (tester) async {
    final sent = <List<Object?>>[];
    await tester.pumpWidget(_host(
      list: () async => _payload(),
      active: (id, on) async {
        sent.add([id, on]);
        return _payload();
      },
    ));
    await tester.pumpAndSettle();

    // The INACTIVE row (id 5) carries toggle_to: true.
    await tester.tap(find.text('Activate'));
    await tester.pumpAndSettle();
    expect(sent, [
      [5, true]
    ]);
  });

  testWidgets('a mutation re-renders from the RPC reply, not a local patch',
      (tester) async {
    final after = _payload(rows: [
      _row(id: 9, amount: 'Above ₹4,999', pct: '4%', active: true),
    ]);
    after['toast'] = 'Slab saved.';

    await tester.pumpWidget(_host(
      list: () async => _payload(),
      active: (_, __) async => after,
    ));
    await tester.pumpAndSettle();
    expect(find.text('Above ₹99,999'), findsOneWidget);

    await tester.tap(find.text('Activate'));
    await tester.pumpAndSettle();

    expect(find.text('Above ₹4,999'), findsOneWidget);
    expect(find.text('Above ₹99,999'), findsNothing);
    // The toast is the reply's own word, not a Dart "Saved!".
    expect(find.text('Slab saved.'), findsOneWidget);
    // Let the toast retire its own timer before the tree is torn down.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('not_authorized is the backend message, and offers no Add',
      (tester) async {
    await tester.pumpWidget(_host(
      list: () async => <String, dynamic>{
        'ok': false,
        'error': 'not_authorized',
        'message': 'Only an admin can change the discount ladder.',
      },
    ));
    await tester.pumpAndSettle();

    expect(find.text('Only an admin can change the discount ladder.'),
        findsOneWidget);
    expect(find.byType(FloatingActionButton), findsNothing);
  });

  testWidgets('the editor draws the payload fields and submits their keys',
      (tester) async {
    Map<String, dynamic>? patch;
    await tester.pumpWidget(_host(
      list: () async => _payload(),
      save: (p) async {
        patch = p;
        return _payload();
      },
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add slab'));
    await tester.pumpAndSettle();

    expect(find.text('Above amount (₹)'), findsOneWidget);
    expect(find.text('Discount %'), findsOneWidget);
    expect(find.text('Effective from'), findsOneWidget);

    await tester.enterText(
        find.widgetWithText(TextField, 'Above amount (₹)'), '149999');
    await tester.enterText(
        find.widgetWithText(TextField, 'Discount %'), '9');
    await tester.tap(find.text('Save slab'));
    await tester.pumpAndSettle();

    expect(patch, isNotNull);
    expect(patch!['min_amount'], '149999');
    expect(patch!['discount_pct'], '9');
    // The new-slab sheet seeds the backend's own "today", never DateTime.now().
    expect(patch!['effective_from'], '2026-08-31');
    expect(patch!.containsKey('id'), isFalse);
  });
}
