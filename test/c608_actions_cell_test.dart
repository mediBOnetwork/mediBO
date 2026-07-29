// CHANGE #608 — the "actions" cell type.
//
// order_tab_columns.customer_orders carries
//   {"key":"actions","label":"CONFIRMATION","align":"center","flex":3,
//    "type":"actions"}
// and backend_table.dart handled only absent / "chip" / "button", so that
// column rendered blank. This proves the new branch:
//
//   1. actions.show true  -> both buttons, with the payload's labels and hexes
//   2. actions.show false -> NOTHING. No text, no button, no dash.
//   3. tapping Accept emits the payload's own `status`, not a Dart literal.
//
// Payload is inline — no network, no Supabase.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/widgets/backend_table.dart';

const _columns = <Map<String, dynamic>>[
  {'key': 'code_label', 'label': 'ORDER', 'align': 'left', 'flex': 3},
  {
    'key': 'actions',
    'label': 'CONFIRMATION',
    'align': 'center',
    'flex': 3,
    'type': 'actions',
  },
];

/// Row A — the admin may still accept or reject this order.
const _rowA = <String, dynamic>{
  'order_id': 'o-A',
  'code_label': 'MB-1001',
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
};

/// Row B — already decided, so there is nothing the admin may do.
const _rowB = <String, dynamic>{
  'order_id': 'o-B',
  'code_label': 'MB-1002',
  'can_confirm': false,
  'actions': {
    'show': false,
    'accept': {'label': 'Accept', 'status': 'accepted', 'show': false},
    'reject': {'label': 'Reject', 'status': 'rejected', 'show': false},
  },
};

/// (order_id, status, note) captured from the handler.
final List<List<String>> written = [];

Widget _harness({required List<Map<String, dynamic>> rows}) {
  final cols = backendColumns(_columns);
  return MaterialApp(
    home: Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          BackendTableHeader(columns: cols),
          for (final r in rows)
            BackendTableRowCells(
              columns: cols,
              row: r,
              actionHandler: (row, status, note) async {
                written.add([row['order_id'] as String, status, note]);
              },
            ),
        ],
      ),
    ),
  );
}

void main() {
  setUp(written.clear);

  testWidgets('actions.show true renders both buttons with backend colours',
      (tester) async {
    await tester.pumpWidget(_harness(rows: [_rowA]));

    expect(find.text('Accept'), findsOneWidget);
    expect(find.text('Reject'), findsOneWidget);

    final acceptBox = tester.widget<Container>(
      find
          .ancestor(of: find.text('Accept'), matching: find.byType(Container))
          .first,
    );
    final acceptDeco = acceptBox.decoration as BoxDecoration;
    expect(acceptDeco.color, const Color(0xFFE1F5EE));
    expect((acceptDeco.border as Border).top.color, const Color(0xFF1B7A43));
    expect(tester.widget<Text>(find.text('Accept')).style?.color,
        const Color(0xFF0F6E56));

    final rejectBox = tester.widget<Container>(
      find
          .ancestor(of: find.text('Reject'), matching: find.byType(Container))
          .first,
    );
    final rejectDeco = rejectBox.decoration as BoxDecoration;
    expect(rejectDeco.color, const Color(0xFFFDE7E7));
    expect(tester.widget<Text>(find.text('Reject')).style?.color,
        const Color(0xFFA11212));
  });

  testWidgets('actions.show false renders NOTHING in the cell', (tester) async {
    await tester.pumpWidget(_harness(rows: [_rowB]));

    // The row is on screen — its plain column printed.
    expect(find.text('MB-1002'), findsOneWidget);

    // The actions cell contributed no button and no text of any kind.
    expect(find.byType(BackendActionButton), findsNothing);
    expect(find.text('Accept'), findsNothing);
    expect(find.text('Reject'), findsNothing);
    expect(find.text('—'), findsNothing);

    // Only the header label and the one plain cell carry text in this tree.
    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data)
        .whereType<String>()
        .toList();
    expect(texts, containsAll(<String>['ORDER', 'CONFIRMATION', 'MB-1002']));
    expect(texts.length, 3);
  });

  testWidgets('both rows together: buttons on A only', (tester) async {
    await tester.pumpWidget(_harness(rows: [_rowA, _rowB]));

    expect(find.byType(BackendActionButton), findsNWidgets(2));
    expect(find.text('Accept'), findsOneWidget);
    expect(find.text('Reject'), findsOneWidget);
  });

  testWidgets('tapping Accept emits the payload status and note',
      (tester) async {
    await tester.pumpWidget(_harness(rows: [_rowA, _rowB]));

    await tester.tap(find.text('Accept'));
    await tester.pump();

    expect(written, [
      ['o-A', 'accepted', 'Order accepted'],
    ]);
  });

  testWidgets('tapping Reject emits the payload status and note',
      (tester) async {
    await tester.pumpWidget(_harness(rows: [_rowA]));

    await tester.tap(find.text('Reject'));
    await tester.pump();

    expect(written, [
      ['o-A', 'rejected', 'Order rejected'],
    ]);
  });

  testWidgets('the CONFIRMATION column header still comes from columns[]',
      (tester) async {
    await tester.pumpWidget(_harness(rows: [_rowA]));
    final header = find.descendant(
      of: find.byType(BackendTableHeader),
      matching: find.byType(Text),
    );
    expect(
      tester.widgetList<Text>(header).map((t) => t.data).toList(),
      ['ORDER', 'CONFIRMATION'],
    );
  });
}
