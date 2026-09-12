// CHANGE #424 — the inference screen never turns an estimate into a certainty.
//
// The engine's arithmetic is proven in SQL (c424_montikop_proof). What these
// tests hold down is the boundary: every quantity, range, rate and confidence
// word is a backend string printed verbatim; the POS swap is invisible because
// the screen reads labels rather than deciding anything; the correction options
// are the backend's own and the tap sends the quantity untouched.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/pharmacy/pharmacy_inference_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

Map<String, dynamic> _row({
  String name = 'Montikop 10 Tablet',
  String left = 'Around 3 left',
  String range = 'likely 1–6',
  String method = 'Estimated',
  bool canCorrect = true,
  String rate = 'Selling about 0.37 a day',
}) => {
      'lot_id': 'lot-jan',
      'medicine_id': 8811,
      'name': name,
      'batch_label': 'JAN',
      'expiry_label': 'Expires Feb 2026',
      'left_label': left,
      'range_label': range,
      'sold_label': 'About 7 of 10 sold since 12 Jan',
      'rate_label': rate,
      'method_label': method,
      'confidence_label': 'Rough estimate',
      'confidence': 0.42,
      'tone': 'info',
      'can_correct': canCorrect,
      'ask_title': 'How many are actually left?',
      'ask_hint': 'One tap teaches the estimate — it gets better every time.',
      'ask_other': 'Another number',
      'ask_save': 'Save',
      'ask_options': [
        {'qty': 0, 'label': '0'},
        {'qty': 2, 'label': '2'},
        {'qty': 5, 'label': '5'},
      ],
    };

Map<String, dynamic> _payload(List<Map<String, dynamic>> rows) => {
      'ok': true,
      'title': 'What is probably left',
      'subtitle': 'Worked out from your purchase history. No counting needed.',
      'heading': 'Lot by lot',
      'note': 'Updated every night.',
      'empty': 'Not enough purchase history yet.',
      'empty_hint': 'Add a few purchase bills and this fills in by itself.',
      'count': rows.length,
      'rows': rows,
    };

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  testWidgets('the estimate prints the backend sentence, hedge and all',
      (tester) async {
    await tester.pumpWidget(_host(
      InferenceView(payload: _payload([_row()]), onCorrect: (_) {}),
    ));

    expect(find.text('Around 3 left'), findsOneWidget);
    expect(find.text('likely 1–6'), findsOneWidget);
    expect(find.text('About 7 of 10 sold since 12 Jan'), findsOneWidget);
    expect(find.text('Selling about 0.37 a day'), findsOneWidget);
    expect(find.text('Rough estimate'), findsOneWidget);
    // Nothing anywhere is a bare number pretending to be a count.
    expect(find.text('3'), findsNothing);
  });

  testWidgets('a missing range is an absence, not a made-up band',
      (tester) async {
    await tester.pumpWidget(_host(
      InferenceView(
        payload: _payload([_row(range: '')]),
        onCorrect: (_) {},
      ),
    ));
    expect(find.textContaining('likely'), findsNothing);
    expect(find.text('Around 3 left'), findsOneWidget);
  });

  testWidgets('the POS swap is invisible: only the labels change',
      (tester) async {
    // Same widget, same shape — the backend has silently replaced inference
    // with the counter's own sales for this SKU.
    await tester.pumpWidget(_host(
      InferenceView(
        payload: _payload([
          _row(
            left: '8 left',
            range: '',
            method: 'From your counter',
            canCorrect: false,
            rate: 'Selling about 1.1 a day',
          )
        ]),
        onCorrect: (_) {},
      ),
    ));

    expect(find.text('8 left'), findsOneWidget);
    expect(find.text('From your counter'), findsOneWidget);
    // A counter-priced lot offers no correction — that is the backend's flag,
    // not a role test in Dart.
    expect(find.text('How many are actually left?'), findsNothing);
  });

  testWidgets('an estimated lot offers the correction button', (tester) async {
    Map<String, dynamic>? asked;
    await tester.pumpWidget(_host(
      InferenceView(payload: _payload([_row()]), onCorrect: (r) => asked = r),
    ));

    await tester.tap(find.text('How many are actually left?'));
    await tester.pump();
    expect(asked?['lot_id'], 'lot-jan');
  });

  testWidgets('the correction sheet offers the backend options and sends them raw',
      (tester) async {
    final picked = <num>[];
    await tester.pumpWidget(_host(
      CorrectionSheet(row: _row(), onPick: picked.add),
    ));

    expect(find.text('0'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('5'), findsOneWidget);
    expect(find.text('Another number'), findsOneWidget);

    await tester.tap(find.text('2'));
    await tester.pump();
    expect(picked, [2]);
  });

  testWidgets('"another number" sends exactly what was typed', (tester) async {
    final picked = <num>[];
    await tester.pumpWidget(_host(
      CorrectionSheet(row: _row(), onPick: picked.add),
    ));

    await tester.tap(find.text('Another number'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '7');
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(picked, [7]);
  });

  testWidgets('an empty shelf shows the backend guidance, not an empty list',
      (tester) async {
    await tester.pumpWidget(_host(
      InferenceView(payload: _payload(const []), onCorrect: (_) {}),
    ));
    expect(find.text('Not enough purchase history yet.'), findsOneWidget);
    expect(
      find.text('Add a few purchase bills and this fills in by itself.'),
      findsOneWidget,
    );
  });

  testWidgets('rows render in payload order', (tester) async {
    await tester.pumpWidget(_host(
      InferenceView(
        payload: _payload([
          _row(name: 'Montikop 10 Tablet'),
          _row(name: 'Dolo 650 Tablet'),
        ]),
        onCorrect: (_) {},
      ),
    ));

    final names = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data)
        .where((d) => d == 'Montikop 10 Tablet' || d == 'Dolo 650 Tablet')
        .toList();
    expect(names, ['Montikop 10 Tablet', 'Dolo 650 Tablet']);
  });

  testWidgets('a refusal prints the backend message, never a Dart one',
      (tester) async {
    await tester.pumpWidget(_host(
      InferenceView(
        payload: const {
          'ok': false,
          'error': 'not_a_pharmacy',
          'message': 'This screen belongs to a pharmacy account.',
        },
        onCorrect: (_) {},
      ),
    ));
    expect(find.text('This screen belongs to a pharmacy account.'),
        findsOneWidget);
  });

  testWidgets('the entry tile disappears when its backend label is empty',
      (tester) async {
    await tester.pumpWidget(_host(const InferenceEntryTile(label: '')));
    expect(find.byType(InkWell), findsNothing);

    await tester
        .pumpWidget(_host(const InferenceEntryTile(label: 'Likely stock on hand')));
    expect(find.text('Likely stock on hand'), findsOneWidget);
  });
}
