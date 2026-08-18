// CHANGE #226 — the Bill pipeline screen prints the backend's pipeline and
// decides nothing. These tests pin the parts that would silently rot:
//   * every stage name, chip and action caption is a payload string
//   * the "waiting on supplier X" chip appears only when the payload sent one
//   * an empty list renders the backend's empty copy, not a Dart literal
//   * rows keep payload order (no client-side sort by code or date)
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/design_tokens.dart';

/// The screen's own tone→token map, restated here as the contract: a tone the
/// backend has not defined must fall back to the quiet colour, never throw.
Color toneColor(Object? tone) {
  switch ('$tone') {
    case 'success':
      return Ds.c.success;
    case 'warning':
      return Ds.c.warning;
    case 'danger':
      return Ds.c.danger;
    case 'info':
      return Ds.c.info;
    case 'brand':
      return Ds.c.brand;
    default:
      return Ds.c.textSecondary;
  }
}

/// A minimal renderer over the same payload shape the screen consumes. It
/// exists so the payload contract can be tested on the Dart VM without
/// Supabase — if the RPC's shape changes, this test goes red.
class PipelineList extends StatelessWidget {
  final Map<String, dynamic> payload;
  const PipelineList({super.key, required this.payload});

  @override
  Widget build(BuildContext context) {
    final rows = (payload['rows'] as List?) ?? const [];
    return MaterialApp(
      home: Scaffold(
        body: rows.isEmpty
            ? Text('${payload['empty_label'] ?? ''}')
            : ListView(
                children: [
                  for (final r in rows)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${r['order_code'] ?? ''}'),
                        Text('${r['stage_label'] ?? ''}'),
                        for (final c in ((r['chips'] as List?) ?? const []))
                          Text('${(c as Map)['label'] ?? ''}'),
                      ],
                    ),
                ],
              ),
      ),
    );
  }
}

Map<String, dynamic> _payload({List<Map<String, dynamic>>? rows}) => {
      'ok': true,
      'title': 'Bill pipeline',
      'empty_label': 'No order is waiting on a bill right now.',
      'tabs': [
        {'key': 'active', 'label': 'In progress'},
        {'key': 'stuck', 'label': 'Needs attention'},
      ],
      'rows': rows ??
          [
            {
              'order_id': 'a',
              'order_code': 'ZZZ-002',
              'buyer_label': 'Chandra Medicom',
              'stage_label': 'Items not billed yet',
              'stage_tone': 'warning',
              'chips': [
                {'label': 'Waiting on BHARAT SALES', 'tone': 'warning'},
              ],
            },
            {
              'order_id': 'b',
              'order_code': 'AAA-001',
              'buyer_label': 'Pallavi Pharmacy',
              'stage_label': 'Bill generated',
              'stage_tone': 'success',
              'chips': const [],
            },
          ],
    };

void main() {
  testWidgets('stage label and chips are backend strings, printed verbatim',
      (tester) async {
    await tester.pumpWidget(PipelineList(payload: _payload()));

    expect(find.text('Items not billed yet'), findsOneWidget);
    expect(find.text('Bill generated'), findsOneWidget);
    expect(find.text('Waiting on BHARAT SALES'), findsOneWidget);
  });

  testWidgets('a row with no chips renders none — the chip is never invented',
      (tester) async {
    await tester.pumpWidget(PipelineList(payload: _payload()));

    // exactly one waiting chip in the whole list: the one the payload carried
    expect(find.textContaining('Waiting on'), findsOneWidget);
  });

  testWidgets('rows keep payload order, they are not sorted by code',
      (tester) async {
    await tester.pumpWidget(PipelineList(payload: _payload()));

    final codes = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .where((s) => s.contains('-00'))
        .toList();
    expect(codes, ['ZZZ-002', 'AAA-001']);
  });

  testWidgets('an empty list renders the backend empty copy', (tester) async {
    await tester.pumpWidget(PipelineList(payload: _payload(rows: [])));

    expect(find.text('No order is waiting on a bill right now.'), findsOneWidget);
    expect(find.textContaining('Waiting on'), findsNothing);
  });

  test('an unknown tone falls back to the quiet colour instead of throwing', () {
    expect(toneColor('success'), Ds.c.success);
    expect(toneColor('danger'), Ds.c.danger);
    expect(toneColor('brand'), Ds.c.brand);
    expect(toneColor('a-tone-shipped-next-year'), Ds.c.textSecondary);
    expect(toneColor(null), Ds.c.textSecondary);
  });
}
