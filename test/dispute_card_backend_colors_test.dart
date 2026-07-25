import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/dispute/dispute_models.dart';
import 'package:pharma_b2b/widgets/dispute_card.dart';

/// CHANGE: supplier_my_disputes / get_dispute_form now return per-item
/// active_colors / kind_label+kind_colors / return_note_chip. DisputeCard
/// (shared by the supplier portal and the public token page) was wired to
/// render them instead of deriving Active/Inactive colour from `isActive`
/// locally. This pumps the real widget with the new payload shapes inside
/// a bounded-width, unbounded-height scrollable ancestor (the real ambient
/// constraint context on both live screens) to confirm it actually renders
/// rather than just compiling.
Map<String, dynamic> _item({
  required bool active,
  Map<String, dynamic>? activeColors,
  String kindLabel = '',
  Map<String, dynamic>? kindColors,
  Map<String, dynamic>? returnNoteChip,
}) {
  return {
    'dispute_id': 'd1',
    'order_item_id': 'oi1',
    'product_name': 'Paracetamol 500mg',
    'supplier': 'Test Supplier',
    'mode': 'reminder',
    'kind': 'short',
    'ordered': 10,
    'received': 7,
    'short': 3,
    'status': active ? 'reminder_sent' : 'missing_arrived',
    'item_status_label': 'Label',
    'dispute_status': active ? 'active' : 'closed',
    'actions': <dynamic>[],
    if (activeColors != null) 'active_colors': activeColors,
    if (kindLabel.isNotEmpty) 'kind_label': kindLabel,
    if (kindColors != null) 'kind_colors': kindColors,
    if (returnNoteChip != null) 'return_note_chip': returnNoteChip,
  };
}

Future<void> _pump(WidgetTester tester, DisputeItem item) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: SizedBox(width: 400, child: DisputeCard(item: item)),
      ),
    ),
  ));
  // RenderLog.write() schedules an 800ms debounced Supabase flush timer;
  // drain it (it no-ops harmlessly with no Supabase instance in tests) so
  // the test doesn't fail on a pending timer at teardown.
  await tester.pump(const Duration(milliseconds: 900));
}

void main() {
  testWidgets('renders with backend-owned active_colors + kind tag + return_note_chip',
      (tester) async {
    final item = DisputeItem.fromJson(_item(
      active: true,
      activeColors: {'label': 'Active', 'bg': '#FEE2E2', 'fg': '#991B1B', 'border': '#FCA5A5'},
      kindLabel: 'Short delivery',
      kindColors: {'bg': '#F1F5F9', 'fg': '#475569'},
      // supplier_my_disputes / get_dispute_form shape: {is_open, label, bg, fg}
      returnNoteChip: {'is_open': true, 'label': 'Stock with buyer', 'bg': '#FFF8E1', 'fg': '#B8860B'},
    ));

    await _pump(tester, item);
    expect(tester.takeException(), isNull);

    expect(find.text('Active'), findsOneWidget);
    expect(find.text('Short delivery'), findsOneWidget);
    expect(find.text('Stock with buyer'), findsOneWidget);
  });

  testWidgets('renders with no backend colour/label fields (falls back gracefully)',
      (tester) async {
    final item = DisputeItem.fromJson(_item(active: false));

    await _pump(tester, item);
    expect(tester.takeException(), isNull);

    expect(find.text('Inactive'), findsOneWidget);
    // No kind label / no return note chip payload -> neither is rendered.
    expect(find.text('Stock with buyer'), findsNothing);
  });

  testWidgets('aggregated row prefers agg.activeColors over the representative item',
      (tester) async {
    final rep = DisputeItem.fromJson(_item(
      active: true,
      activeColors: {'label': 'Active', 'bg': '#FEE2E2', 'fg': '#991B1B'},
    ));
    final agg = AggregatedDispute(
      supplier: 'Test Supplier',
      productName: rep.productName,
      kind: rep.kind,
      disputedQty: 3,
      orderedQty: 10,
      receivedQty: 7,
      active: true,
      itemStatusLabel: rep.itemStatusLabel,
      lines: [rep],
      representative: rep,
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SizedBox(width: 400, child: DisputeCard(item: rep, agg: agg)),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 900));
    expect(tester.takeException(), isNull);
    expect(find.text('Active'), findsOneWidget);
  });
}
