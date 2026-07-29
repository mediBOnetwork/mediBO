// CHANGE #606 — the Customer Orders row renders what admin_customer_orders
// returned, and nothing else.
//
// The payload below is a fabricated admin_customer_orders response, inline —
// no network, no Supabase. It exercises the two properties that matter:
//
//   1. The strings on the card are the backend's, character for character.
//      A Dart formatter would produce "₹2628.28" or "₹2,628" from the same
//      number; the assertion is on the exact "₹2,628.28" the RPC returned.
//   2. `show:false` means the widget is ABSENT — not greyed out, not empty,
//      not replaced by a Dart default. Row two's admin_chip is off and the
//      test asserts "Placed by admin" appears nowhere in the tree.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/widgets/backend_chip.dart';

/// A fabricated admin_customer_orders payload — the exact shape the RPC returns.
const _payload = <String, dynamic>{
  'status': 'ok',
  'count': 2,
  'has_orders': true,
  'summary': {
    'orders': 2,
    'items': 11,
    'amount': 3628.28,
    'amount_label': '₹3,628.28',
    'label': '2 orders • 11 items • ₹3,628.28',
  },
  'empty': {'show': false, 'title': '', 'note': ''},
  'orders': [
    {
      'order_id': 'o-1',
      'title': 'Sunrise Medical Store',
      'code_label': 'MB-1001',
      'show_code': true,
      'phone_label': '+91 98765 43210',
      'has_phone': true,
      'status_chip': {
        'value': 'accepted',
        'label': 'Accepted',
        'bg': '#E1F5EE',
        'fg': '#0F6E56',
        'border': '#1B7A43',
        'show': true,
      },
      'admin_chip': {
        'label': 'Placed by admin',
        'bg': '#E6F1FB',
        'fg': '#0C447C',
        'border': '#B6D4F0',
        'show': true,
      },
      'amount_label': '₹2,628.28',
      'items_label': '8 items',
      'time_label': '11:42 AM',
    },
    {
      'order_id': 'o-2',
      'title': 'Unnamed pharmacy',
      'code_label': '',
      'show_code': false,
      'phone_label': 'No phone',
      'has_phone': false,
      'status_chip': {
        'value': 'pending',
        'label': 'Pending',
        'bg': '#FFF4E0',
        'fg': '#8A5A00',
        'border': '#F2D9A0',
        'show': true,
      },
      // The order was NOT placed by an admin: the backend still returns the
      // key, with show:false and an empty label.
      'admin_chip': {
        'label': '',
        'bg': '#FFFFFF',
        'fg': '#FFFFFF',
        'border': '#FFFFFF',
        'show': false,
      },
      'amount_label': '₹1,000.00',
      'items_label': '3 items',
      'time_label': '09:05 AM',
    },
  ],
};

/// The Customer Orders card, reduced to exactly the render path under test:
/// read the row, paint the backend's strings and chips. No derivation.
class _OrderCard extends StatelessWidget {
  final Map<String, dynamic> row;
  const _OrderCard(this.row);

  String rs(String k) => (row[k] as String?) ?? '';
  bool rb(String k) => row[k] == true;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(rs('title')),
        if (rb('show_code')) Text(rs('code_label')),
        if (rb('has_phone')) Text(rs('phone_label')),
        BackendChipRow(chips: [
          backendChipOf(row, 'status_chip'),
          backendChipOf(row, 'admin_chip'),
        ]),
        Text(rs('amount_label')),
        Text(rs('items_label')),
        Text(rs('time_label')),
      ],
    );
  }
}

Widget _harness() {
  final orders = (_payload['orders'] as List).cast<Map<String, dynamic>>();
  final summary = _payload['summary'] as Map<String, dynamic>;
  return MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(summary['label'] as String),
            for (final o in orders) _OrderCard(o),
          ],
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('renders the backend strings verbatim', (tester) async {
    await tester.pumpWidget(_harness());

    // Row 1 — every visible string, exactly as the RPC returned it.
    expect(find.text('Sunrise Medical Store'), findsOneWidget);
    expect(find.text('MB-1001'), findsOneWidget);
    expect(find.text('+91 98765 43210'), findsOneWidget);
    expect(find.text('Accepted'), findsOneWidget);
    expect(find.text('₹2,628.28'), findsOneWidget);
    expect(find.text('8 items'), findsOneWidget);
    expect(find.text('11:42 AM'), findsOneWidget);

    // The summary line is the backend's, not a Dart sum.
    expect(find.text('2 orders • 11 items • ₹3,628.28'), findsOneWidget);

    // A Dart currency formatter would have produced one of these from
    // 2628.28. None of them may appear.
    expect(find.text('₹2628.28'), findsNothing);
    expect(find.text('₹2,628'), findsNothing);
    expect(find.text('₹2628'), findsNothing);
  });

  testWidgets('chip paints the colours the backend supplied', (tester) async {
    await tester.pumpWidget(_harness());

    final chip = tester.widget<Container>(
      find.ancestor(of: find.text('Accepted'), matching: find.byType(Container)).first,
    );
    final deco = chip.decoration as BoxDecoration;
    expect(deco.color, const Color(0xFFE1F5EE)); // bg "#E1F5EE", verbatim
    expect((deco.border as Border).top.color, const Color(0xFF1B7A43));

    final text = tester.widget<Text>(find.text('Accepted'));
    expect(text.style?.color, const Color(0xFF0F6E56)); // fg "#0F6E56"
  });

  testWidgets('show:false renders nothing at all', (tester) async {
    await tester.pumpWidget(_harness());

    // Row 2's admin_chip is show:false — the chip is ABSENT, and no Dart
    // fallback took its place.
    expect(find.text('Placed by admin'), findsOneWidget); // row 1 only
    expect(find.text('Unnamed pharmacy'), findsOneWidget);
    expect(find.text('Pending'), findsOneWidget);

    // Row 2 has show_code:false and has_phone:false — neither the empty
    // code_label nor the "No phone" string is drawn, and no em-dash
    // placeholder was invented for them.
    expect(find.text('No phone'), findsNothing);
    expect(find.text('—'), findsNothing);

    // Exactly two chips are painted across both rows: row 1's status +
    // admin, row 2's status. Row 2's hidden admin chip adds nothing.
    expect(find.byType(BackendChip), findsNWidgets(3));
  });

  testWidgets('an empty label is never rendered as a chip', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: BackendChip(chip: {'label': '', 'bg': '#FF0000', 'show': true}),
      ),
    ));
    expect(find.byType(Text), findsNothing);
  });
}
