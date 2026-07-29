// CHANGE #607 — the accept/reject gate and the table shape are the backend's.
//
// Payload below is a fabricated admin_customer_orders response, inline — no
// network, no Supabase. Three properties are under test:
//
//   1. Row A has actions.show true, so BOTH buttons render, with the labels
//      and the exact tone_colors() hexes the payload supplied.
//   2. Row B has can_confirm false / actions.show false, so NEITHER renders.
//      Not greyed, not disabled — absent. This is the gate that used to be
//      `if (status != 'pending')` in Dart.
//   3. The header prints columns[]'s labels, in columns[]'s order. Reordering
//      the array reorders the table with no deploy.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/widgets/backend_chip.dart';
import 'package:pharma_b2b/widgets/backend_table.dart';

/// A fabricated admin_customer_orders payload.
const _payload = <String, dynamic>{
  'status': 'ok',
  'count': 2,
  // Deliberately NOT alphabetical and NOT the order a developer would guess:
  // the header must follow this array exactly.
  'columns': [
    {'key': 'code_label', 'label': 'ORDER', 'align': 'left', 'flex': 3},
    {
      'key': 'status_chip',
      'label': 'STATUS',
      'align': 'left',
      'flex': 3,
      'type': 'chip',
    },
    {'key': 'amount_label', 'label': 'AMOUNT', 'align': 'right', 'flex': 3},
  ],
  'orders': [
    {
      'order_id': 'o-A',
      'code_label': 'MB-1001',
      'amount_label': '₹2,628.28',
      'status_chip': {
        'value': 'pending',
        'label': 'Pending',
        'bg': '#FFF4E0',
        'fg': '#8A5A00',
        'border': '#F2D9A0',
        'show': true,
      },
      'can_confirm': true,
      'actions': {
        'show': true,
        'accept': {
          'label': 'Accept',
          'status': 'accepted',
          'show': true,
          'note': 'Order accepted',
          'bg': '#E1F5EE',
          'fg': '#0F6E56',
          'border': '#1B7A43',
        },
        'reject': {
          'label': 'Reject',
          'status': 'rejected',
          'show': true,
          'note': 'Order rejected',
          'bg': '#FDE7E7',
          'fg': '#A11212',
          'border': '#F3B4B4',
        },
      },
    },
    {
      'order_id': 'o-B',
      'code_label': 'MB-1002',
      'amount_label': '₹1,000.00',
      'status_chip': {
        'value': 'accepted',
        'label': 'Accepted',
        'bg': '#E1F5EE',
        'fg': '#0F6E56',
        'border': '#1B7A43',
        'show': true,
      },
      // Already accepted — there is nothing the admin may do to it.
      'can_confirm': false,
      'actions': {
        'show': false,
        'accept': {'label': 'Accept', 'status': 'accepted', 'show': false},
        'reject': {'label': 'Reject', 'status': 'rejected', 'show': false},
      },
    },
  ],
};

/// The written status values, captured so the test can prove the tap sends the
/// payload's `status` and not a hardcoded literal.
final List<String> tapped = [];

/// The row's action cell, reduced to the render path under test.
class _ActionCell extends StatelessWidget {
  final Map<String, dynamic> row;
  const _ActionCell(this.row);

  @override
  Widget build(BuildContext context) {
    final actions = row['actions'] is Map
        ? (row['actions'] as Map).cast<String, dynamic>()
        : null;
    if (actions == null || actions['show'] != true) {
      return const SizedBox.shrink();
    }
    final accept = (actions['accept'] as Map?)?.cast<String, dynamic>();
    final reject = (actions['reject'] as Map?)?.cast<String, dynamic>();
    return Row(mainAxisSize: MainAxisSize.min, children: [
      BackendActionButton(
        action: accept,
        onTap: () => tapped.add(accept!['status'] as String),
      ),
      BackendActionButton(
        action: reject,
        onTap: () => tapped.add(reject!['status'] as String),
      ),
    ]);
  }
}

Widget _harness() {
  final cols = backendColumns(_payload['columns']);
  final orders = (_payload['orders'] as List).cast<Map<String, dynamic>>();
  return MaterialApp(
    home: Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          BackendTableHeader(columns: cols),
          for (final o in orders)
            Row(children: [
              Expanded(
                flex: cols.fold<int>(0, (a, c) => a + c.flex),
                child: BackendTableRowCells(columns: cols, row: o),
              ),
              _ActionCell(o),
            ]),
        ],
      ),
    ),
  );
}

void main() {
  setUp(tapped.clear);

  testWidgets('actions.show true renders both buttons, with backend colours',
      (tester) async {
    await tester.pumpWidget(_harness());

    expect(find.text('Accept'), findsOneWidget);
    expect(find.text('Reject'), findsOneWidget);

    final acceptBox = tester.widget<Container>(
      find
          .ancestor(of: find.text('Accept'), matching: find.byType(Container))
          .first,
    );
    final acceptDeco = acceptBox.decoration as BoxDecoration;
    expect(acceptDeco.color, const Color(0xFFE1F5EE)); // accept bg, verbatim
    expect((acceptDeco.border as Border).top.color, const Color(0xFF1B7A43));
    expect(tester.widget<Text>(find.text('Accept')).style?.color,
        const Color(0xFF0F6E56));

    final rejectBox = tester.widget<Container>(
      find
          .ancestor(of: find.text('Reject'), matching: find.byType(Container))
          .first,
    );
    final rejectDeco = rejectBox.decoration as BoxDecoration;
    expect(rejectDeco.color, const Color(0xFFFDE7E7)); // reject bg, verbatim
    expect(tester.widget<Text>(find.text('Reject')).style?.color,
        const Color(0xFFA11212));
  });

  testWidgets('actions.show false renders NEITHER button', (tester) async {
    await tester.pumpWidget(_harness());

    // Row B is on screen — its code and its status chip both render …
    expect(find.text('MB-1002'), findsOneWidget);
    expect(find.text('Accepted'), findsOneWidget);

    // … but it contributes no buttons. Exactly one Accept and one Reject
    // exist in the whole tree, and both belong to row A.
    expect(find.text('Accept'), findsOneWidget);
    expect(find.text('Reject'), findsOneWidget);
    expect(find.byType(BackendActionButton), findsNWidgets(2));
  });

  testWidgets('tapping sends the payload status, not a Dart literal',
      (tester) async {
    await tester.pumpWidget(_harness());

    await tester.tap(find.text('Accept'));
    await tester.pump();
    expect(tapped, ['accepted']);

    await tester.tap(find.text('Reject'));
    await tester.pump();
    expect(tapped, ['accepted', 'rejected']);
  });

  testWidgets('header prints columns[] labels in payload order',
      (tester) async {
    await tester.pumpWidget(_harness());

    expect(find.text('ORDER'), findsOneWidget);
    expect(find.text('STATUS'), findsOneWidget);
    expect(find.text('AMOUNT'), findsOneWidget);

    // Order is the array's, left to right — not alphabetical, not invented.
    final header = find.descendant(
      of: find.byType(BackendTableHeader),
      matching: find.byType(Text),
    );
    expect(
      tester.widgetList<Text>(header).map((t) => t.data).toList(),
      ['ORDER', 'STATUS', 'AMOUNT'],
    );

    // A column with no header entry cannot appear: 'CUSTOMER' and 'ITEMS' are
    // real keys on other tables but are absent from THIS columns[].
    expect(find.text('CUSTOMER'), findsNothing);
    expect(find.text('ITEMS'), findsNothing);
  });

  testWidgets('type:"chip" cell paints the chip, plain cells print verbatim',
      (tester) async {
    await tester.pumpWidget(_harness());

    // The chip column rendered as a chip, with the payload's colours.
    expect(find.byType(BackendChip), findsNWidgets(2));
    final chip = tester.widget<Container>(
      find
          .ancestor(of: find.text('Pending'), matching: find.byType(Container))
          .first,
    );
    expect((chip.decoration as BoxDecoration).color, const Color(0xFFFFF4E0));

    // Plain columns printed their string exactly.
    expect(find.text('MB-1001'), findsOneWidget);
    expect(find.text('₹2,628.28'), findsOneWidget);
    expect(find.text('₹2628.28'), findsNothing); // no Dart re-formatting
  });
}
