// PROTECTED — CHANGE #635.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes Supplier Shop / Warehouse state rendering.
//
// Guards the fw_get_state contract on the counting screens:
//   1. qty_label / status_label / status_tone are RENDERED, never composed
//   2. count_locked is the backend's stage-resolved answer and it blocks entry
//   3. nothing falls back to a Dart-built string when the backend sent one
//
// The payloads below are fabricated fw_get_state responses in the exact shape
// the RPC returns (verified against the live function: items[] carries
// qty_label, status_label, status_tone, status_colors, count_locked, plus the
// legacy collect_locked / received_locked pair). No network, no Supabase.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/fulfill/fulfill_view_logic.dart';
import 'package:pharma_b2b/widgets/backend_chip.dart';

/// A fabricated fw_get_state item — shop view.
Map<String, dynamic> _item({
  String qtyLabel = '12 strips (2 boxes)',
  String statusLabel = 'Counted — short by 3',
  String statusTone = 'short_ok',
  bool? countLocked,
  bool collectLocked = false,
  bool receivedLocked = false,
}) =>
    {
      'order_item_id': 'oi-1',
      'product_id': 101,
      'product_name': 'Dolo 650',
      'ordered_qty': 12,
      'received_qty': 9,
      'pack_type': 'strip',
      'qty_label': qtyLabel,
      'status_label': statusLabel,
      'status_tone': statusTone,
      'status_colors': {'bg': '#FDF3E7', 'fg': '#8A5A11'},
      if (countLocked != null) 'count_locked': countLocked,
      'collect_locked': collectLocked,
      'received_locked': receivedLocked,
    };

void main() {
  group('display strings are the backend\'s, verbatim', () {
    test('qty_label / status_label / status_tone are read, not built', () {
      final d = shopItemDisplayOf(_item());

      // A Dart formatter given (12, 'strip') produces "12 strips". The backend
      // sent something no client-side rule would ever produce — proving the
      // value travelled through untouched.
      expect(d.qtyLabel, '12 strips (2 boxes)');
      expect(d.qtyLabel, isNot(qtyWithPack(12, 'strip')));

      expect(d.statusLabel, 'Counted — short by 3');
      expect(d.statusTone, 'short_ok');
      expect(d.statusColors, {'bg': '#FDF3E7', 'fg': '#8A5A11'});
    });

    test('an EMPTY backend label stays empty — no invented fallback', () {
      final d = shopItemDisplayOf(_item(qtyLabel: '', statusLabel: ''));

      expect(d.qtyLabel, '',
          reason: 'falling back to a 9/12 fraction or qtyWithPack would be deciding');
      expect(d.statusLabel, '');
      // ...and it must NOT have quietly become the ordered/received numbers.
      expect(d.qtyLabel, isNot(contains('12')));
      expect(d.qtyLabel, isNot(contains('9')));
    });

    test('a missing status_colors block yields null, not a default palette', () {
      final m = _item()..remove('status_colors');
      expect(shopItemDisplayOf(m).statusColors, isNull);
    });

    test('the tone is passed through even when this client has never seen it', () {
      // A new backend tone must reach the renderer unchanged rather than being
      // mapped onto the nearest tone this build happens to know.
      final d = shopItemDisplayOf(_item(statusTone: 'awaiting_recount_v2'));
      expect(d.statusTone, 'awaiting_recount_v2');
    });
  });

  group('count_locked blocks entry', () {
    test('count_locked:true locks the row', () {
      expect(countLockedOf(_item(countLocked: true)), isTrue);
      expect(shopItemDisplayOf(_item(countLocked: true)).countLocked, isTrue);
    });

    test('count_locked:false unlocks it — even when a legacy flag is set', () {
      // THE REGRESSION. fw_get_state resolves count_locked per stage:
      //   shop view      -> collect_locked
      //   warehouse view -> received_locked
      // This row is the shop view of a supplier whose WAREHOUSE lines are
      // locked. The old client OR-ed the two raw flags and locked shop entry
      // too, because it could not tell which flag governed the screen in front
      // of the operator. The backend can, and did: count_locked is false.
      final row = _item(countLocked: false, receivedLocked: true);

      expect(countLockedOf(row), isFalse,
          reason: 'the backend already resolved the stage — do not re-derive');
      expect(shopItemDisplayOf(row).countLocked, isFalse);
    });

    test('the inverse case: warehouse open, shop locked', () {
      final row = _item(countLocked: false, collectLocked: true);
      expect(countLockedOf(row), isFalse);
    });

    test('legacy payloads without count_locked still fall back to the OR', () {
      // get_receiving_box predates the field and returns collect_locked alone.
      expect(countLockedOf(_item(collectLocked: true)), isTrue);
      expect(countLockedOf(_item(receivedLocked: true)), isTrue);
      expect(countLockedOf(_item()), isFalse);
    });

    test('count_locked always wins when present', () {
      expect(
        countLockedOf(_item(
            countLocked: true, collectLocked: false, receivedLocked: false)),
        isTrue,
      );
      expect(
        countLockedOf(_item(
            countLocked: false, collectLocked: true, receivedLocked: true)),
        isFalse,
      );
    });
  });

  group('the status chip paints what the backend sent', () {
    testWidgets('label and colours render verbatim', (tester) async {
      const chip = <String, dynamic>{
        'label': 'Counted — short by 3',
        'bg': '#FDF3E7',
        'fg': '#8A5A11',
        'border': '#E0B978',
        'show': true,
      };

      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: BackendChip(chip: chip)),
      ));

      expect(find.text('Counted — short by 3'), findsOneWidget);
      expect(backendChipVisible(chip), isTrue);
    });

    testWidgets('show:false renders NOTHING — not a greyed or empty chip',
        (tester) async {
      const chip = <String, dynamic>{
        'label': 'Counted',
        'bg': '#FDF3E7',
        'fg': '#8A5A11',
        'show': false,
      };

      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: BackendChip(chip: chip)),
      ));

      expect(find.text('Counted'), findsNothing);
      expect(backendChipVisible(chip), isFalse);
    });

    testWidgets('an empty label renders nothing rather than a Dart default',
        (tester) async {
      const chip = <String, dynamic>{'label': '', 'show': true};

      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: BackendChip(chip: chip)),
      ));

      expect(backendChipVisible(chip), isFalse);
      expect(find.byType(Text), findsNothing);
    });
  });

  group('the fw_get_state call itself stays server-scoped', () {
    test('p_date is ABSENT so the Dashboard picker owns the date', () {
      final params = fwGetStateParams(supplierName: 'Acme Pharma', stage: 'collect');
      expect(params.containsKey('p_date'), isFalse);
      expect(params.keys.toSet(), {'p_supplier_name', 'p_stage'});
    });
  });
}
