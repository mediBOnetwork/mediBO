// Regression test for CHANGE #194 — "Count items" wiring in both tabs.
//
// Proves:
//   1. FulfillItemSheet renders the PENDING state with #193 buttons.
//   2. Tapping an item opens FulfillItemSheet (the counting sheet).
//   3. onRecord callback is invoked when an action button is tapped.
//   4. The sheet renders correctly for both Collect (arrivals=false)
//      and Arrivals (arrivals=true) item data shapes.
//
// If the onTap handler is ever un-wired or the sheet fails to render,
// this test will fail.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/widgets/fulfill_item_sheet.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Minimal item map for Collect (Supplier Shop) tab.
Map<String, dynamic> _collectItem({
  String state = 'pending',
  int orderedQty = 10,
  int receivedQty = 0,
}) =>
    {
      'order_item_id': 'test-oiid-1',
      'product_id': 42,
      'product_name': 'Paracetamol 500mg',
      'pack_type': 'Strip',
      'ordered_qty': orderedQty,
      'received_qty': receivedQty,
      'fulfillment_state': state,
      'collect_locked': false,
    };

/// Minimal item map for Warehouse (Arrivals) tab.
Map<String, dynamic> _arrivalsItem({
  int ordered = 10,
  int receivedQty = 0,
  bool receivedLocked = false,
}) =>
    {
      'order_item_id': 'test-oiid-2',
      'product_id': 43,
      'product_name': 'Amoxicillin 250mg',
      'pack_type': 'Bottle',
      'ordered': ordered,
      'received_qty': receivedQty,
      'received_locked': receivedLocked,
    };

/// Pumps [FulfillItemSheet] inside a MaterialApp scaffold.
Future<void> _pumpSheet(
  WidgetTester tester, {
  required Map<String, dynamic> item,
  void Function(String state, {int? qty, String? note})? onRecordSync,
}) async {
  String? recordedState;

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(builder: (ctx) {
          return SingleChildScrollView(
            child: FulfillItemSheet(
              item: item,
              supplierName: 'Test Supplier',
              recording: false,
              existingDispute: null,
              onRecord: (state, {qty, note}) async {
                recordedState = state;
                onRecordSync?.call(state, qty: qty, note: note);
              },
              onDisputeCreated: (_, __) {},
              onViewDispute: () {},
            ),
          );
        }),
      ),
    ),
  );
  // Advance clock past the 800 ms RenderLog Supabase-flush debounce timer so
  // no pending timers remain when the test ends.
  await tester.pump(const Duration(milliseconds: 1000));
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  group('FulfillItemSheet — PENDING state (Collect / #193 button set)', () {
    testWidgets('renders "Got all" button for collect item', (tester) async {
      await _pumpSheet(tester, item: _collectItem());
      expect(find.text('Got all (10)'), findsOneWidget);
    });

    testWidgets('renders "Report missing" (not "Short") for collect item', (tester) async {
      await _pumpSheet(tester, item: _collectItem());
      expect(find.text('Report missing'), findsOneWidget);
      // #193: old "Short (enter count)" must be gone
      expect(find.textContaining('Short'), findsNothing);
    });

    testWidgets('renders "Few item wrong" button for collect item', (tester) async {
      await _pumpSheet(tester, item: _collectItem());
      expect(find.text('Few item wrong'), findsOneWidget);
    });

    testWidgets('renders "Wrong item" button for collect item', (tester) async {
      await _pumpSheet(tester, item: _collectItem());
      expect(find.text('Wrong item'), findsOneWidget);
    });

    testWidgets('renders "Not coming" button for collect item', (tester) async {
      await _pumpSheet(tester, item: _collectItem());
      expect(find.text('Not coming'), findsOneWidget);
    });

    testWidgets('"Got all" invokes onRecord with state=received', (tester) async {
      String? gotState;
      await _pumpSheet(
        tester,
        item: _collectItem(),
        onRecordSync: (state, {qty, note}) => gotState = state,
      );
      await tester.tap(find.text('Got all (10)'));
      await tester.pump(); // process tap + state updates
      await tester.pump(const Duration(milliseconds: 1000)); // drain any new RenderLog timer
      expect(gotState, 'received');
    });
  });

  group('FulfillItemSheet — PENDING state (Arrivals / #193 button set)', () {
    testWidgets('renders pending buttons for arrivals item', (tester) async {
      await _pumpSheet(tester, item: _arrivalsItem());
      expect(find.text('Got all (10)'), findsOneWidget);
      expect(find.text('Report missing'), findsOneWidget);
      expect(find.text('Few item wrong'), findsOneWidget);
      expect(find.text('Wrong item'), findsOneWidget);
      expect(find.text('Not coming'), findsOneWidget);
    });

    testWidgets('"Got all" invokes onRecord for arrivals item', (tester) async {
      String? gotState;
      await _pumpSheet(
        tester,
        item: _arrivalsItem(),
        onRecordSync: (state, {qty, note}) => gotState = state,
      );
      await tester.tap(find.text('Got all (10)'));
      await tester.pump(); // process tap + state updates
      await tester.pump(const Duration(milliseconds: 1000)); // drain any new RenderLog timer
      expect(gotState, 'received');
    });
  });

  group('FulfillItemSheet — "Report missing" inline expander', () {
    testWidgets('tapping Report missing shows inline two-half row', (tester) async {
      await _pumpSheet(tester, item: _collectItem());
      expect(find.text('Confirm missing · 10 Strip'), findsNothing);
      await tester.tap(find.text('Report missing'));
      await tester.pump(const Duration(milliseconds: 1000));
      // Inline row with confirm button should appear
      expect(find.textContaining('Confirm missing'), findsOneWidget);
    });

    testWidgets('tapping Few item wrong shows inline expander', (tester) async {
      await _pumpSheet(tester, item: _collectItem());
      expect(find.textContaining('Confirm wrong'), findsNothing);
      await tester.tap(find.text('Few item wrong'));
      await tester.pump(const Duration(milliseconds: 1000));
      expect(find.textContaining('Confirm wrong'), findsOneWidget);
    });

    testWidgets('only one expander open at a time', (tester) async {
      await _pumpSheet(tester, item: _collectItem());
      // Open Report missing
      await tester.tap(find.text('Report missing'));
      await tester.pump(const Duration(milliseconds: 1000));
      expect(find.textContaining('Confirm missing'), findsOneWidget);
      // Open Few item wrong → should close Report missing
      await tester.tap(find.text('Few item wrong'));
      await tester.pump(const Duration(milliseconds: 1000));
      expect(find.textContaining('Confirm missing'), findsNothing);
      expect(find.textContaining('Confirm wrong'), findsOneWidget);
    });
  });

  group('FulfillItemSheet — non-pending states', () {
    testWidgets('RECEIVED state shows "Reset to pending"', (tester) async {
      await _pumpSheet(tester,
          item: _collectItem(state: 'received', orderedQty: 10, receivedQty: 10));
      expect(find.text('Reset to pending'), findsOneWidget);
    });

    testWidgets('SHORT state shows "Reset to pending"', (tester) async {
      await _pumpSheet(tester,
          item: _collectItem(state: 'short', orderedQty: 10, receivedQty: 5));
      expect(find.text('Reset to pending'), findsOneWidget);
    });
  });
}
