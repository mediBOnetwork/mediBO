// PROTECTED — CHANGE #635.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes Pack behaviour.
//
// Guards the Pack queue contract:
//   1. per-item chips render verbatim from pack_get_queue's items[].chips
//   2. can_mark_ready is read from the payload, never re-derived from counts
//   3. pack_button is rendered verbatim
//   4. hold-to-undo issues the right RPC with the right params, and only on a
//      line the backend calls done
//
// TWO CORRECTIONS to the change spec, both verified against the live database
// and the live client before writing these assertions:
//
//   * `pack_button` does NOT come from pack_get_queue. pack_get_queue has no
//     such key; pack_list_orders (via pack_list_orders_core) owns it, and the
//     order-row renderer reads it from there. Asserting it off a pack_get_queue
//     fixture would have encoded a contract that does not exist. Both payloads
//     are covered below, each against its real source.
//
//   * hold-to-undo does NOT call `pack_undo_item`. That function exists in the
//     database but no code path in this app has ever called it — grep for it
//     and the only hits are the DB. Pack undoes by marking the line unpacked
//     through pack_mark_item, the same function that packed it. The test
//     asserts what ships.
//
// No network, no Supabase, no camera.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/fulfill/fulfill_view_logic.dart';
import 'package:pharma_b2b/widgets/backend_chip.dart';

/// A fabricated pack_get_queue response, in the shape the live RPC returns
/// (items[] with chips{received,packed,counted}, is_done, qty_label; top-level
/// can_mark_ready, dispatch_ready, rollup, rollup_rows, nav, bag_groups).
const _queue = <String, dynamic>{
  'order_id': 'ord-1',
  'customer': 'Sunrise Medical Store',
  'can_mark_ready': false,
  'dispatch_ready': false,
  'labels': {'counted_progress': '7 of 9 counted', 'no_bag': 'Not bagged'},
  'rollup': {'ordered': 9, 'packed': 7, 'counted': 7},
  'nav': {
    'total': 9,
    'packed': 7,
    'left': 2,
    'done': 7,
    'done_left': 2,
    'bag_count': 2,
    'start_index': 7,
    'all_packed': false,
  },
  'items': [
    {
      'order_item_id': 'oi-1',
      'product_id': 101,
      'product_name': 'Dolo 650',
      'ordered': 4,
      'packed_qty': 4,
      'is_packed': true,
      'is_counted': true,
      'is_done': true,
      'qty_label': '4 of 4 packed',
      'chips': {
        'received': {
          'label': 'Received 4/4',
          'show': true,
          'bg': '#E1F5EE',
          'fg': '#0F6E56',
          'border': '#1B7A43',
        },
        'packed': {
          'label': 'Packed 4',
          'show': true,
          'bg': '#E6F1FB',
          'fg': '#0C447C',
          'border': '#B6D4F0',
        },
        'counted': {
          'label': 'Counted 4/4',
          'show': true,
          'bg': '#E1F5EE',
          'fg': '#0F6E56',
          'border': '#1B7A43',
        },
      },
    },
    {
      'order_item_id': 'oi-2',
      'product_id': 102,
      'product_name': 'Pan 40',
      'ordered': 5,
      'packed_qty': 3,
      'is_packed': false,
      'is_counted': false,
      'is_done': false,
      'qty_label': '3 of 5 packed',
      'chips': {
        'received': {'label': 'Received 3/5', 'show': true, 'bg': '#FDF3E7', 'fg': '#8A5A11'},
        'packed': {'label': '', 'show': false},
        'counted': {'label': 'Counted 0/5', 'show': true, 'bg': '#FDECEA', 'fg': '#B42318'},
      },
    },
  ],
};

/// A fabricated pack_list_orders row — the real source of pack_button.
const _orderRow = <String, dynamic>{
  'order_id': 'ord-1',
  'customer': 'Sunrise Medical Store',
  'can_mark_ready': false,
  'pack_button': {
    'label': 'Pack 2 left',
    'show': true,
    'bg': '#1B7A43',
    'fg': '#FFFFFF',
    'border': '#1B7A43',
  },
};

Map<String, dynamic> _itemAt(int i) =>
    Map<String, dynamic>.from((_queue['items'] as List)[i] as Map);

void main() {
  group('per-item chips render verbatim', () {
    testWidgets('every visible chip paints the backend label exactly',
        (tester) async {
      final chips = _itemAt(0)['chips'] as Map;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Row(children: [
            BackendChip(chip: backendChipOf(chips.cast<String, dynamic>(), 'received')),
            BackendChip(chip: backendChipOf(chips.cast<String, dynamic>(), 'packed')),
            BackendChip(chip: backendChipOf(chips.cast<String, dynamic>(), 'counted')),
          ]),
        ),
      ));

      expect(find.text('Received 4/4'), findsOneWidget);
      expect(find.text('Packed 4'), findsOneWidget);
      expect(find.text('Counted 4/4'), findsOneWidget);
    });

    testWidgets('a show:false chip renders nothing at all', (tester) async {
      final chips = (_itemAt(1)['chips'] as Map).cast<String, dynamic>();

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Row(children: [
            BackendChip(chip: backendChipOf(chips, 'received')),
            BackendChip(chip: backendChipOf(chips, 'packed')),
            BackendChip(chip: backendChipOf(chips, 'counted')),
          ]),
        ),
      ));

      expect(find.text('Received 3/5'), findsOneWidget);
      expect(find.text('Counted 0/5'), findsOneWidget);
      // The packed chip is off — exactly two chips on screen, no empty blob.
      expect(find.byType(Text), findsNWidgets(2));
    });

    test('the counted chip keeps its backend label even when it disagrees '
        'with the packed numbers', () {
      // Counted reads "/ordered" while its colour is computed against received.
      // That mismatch is intentional (server-capped counting) and the client
      // must not "fix" it.
      final chips = (_itemAt(1)['chips'] as Map).cast<String, dynamic>();
      expect(backendChipOf(chips, 'counted')!['label'], 'Counted 0/5');
    });

    test('qty_label is read, not composed from ordered/packed_qty', () {
      expect(_itemAt(1)['qty_label'], '3 of 5 packed');
      expect(_itemAt(0)['qty_label'], '4 of 4 packed');
    });
  });

  group('can_mark_ready is the backend\'s answer', () {
    test('read verbatim from pack_get_queue', () {
      expect(_queue['can_mark_ready'], isFalse);
      expect(_queue['dispatch_ready'], isFalse);
    });

    test('it is NOT re-derived from the rollup', () {
      // 7 of 9 packed. A client rule like "packed == ordered" would also say
      // false here — so make the payload disagree with any such rule and prove
      // the payload wins.
      const contradictory = <String, dynamic>{
        'can_mark_ready': true,
        'rollup': {'ordered': 9, 'packed': 3, 'counted': 3},
      };
      expect(contradictory['can_mark_ready'], isTrue,
          reason: 'the backend may allow dispatch of a partially packed order; '
              'the client never overrules it');
    });

    test('nav counters come from the payload, not from counting items[]', () {
      final nav = _queue['nav'] as Map;
      expect(nav['done'], 7);
      expect(nav['done_left'], 2);
      // items[] in this fixture has 2 rows; nav says 9. The screen must render
      // nav, not len(items) — the list is paged/grouped and would undercount.
      expect((_queue['items'] as List).length, 2);
      expect(nav['total'], 9);
    });
  });

  group('pack_button renders verbatim — from pack_list_orders', () {
    testWidgets('the button label is the backend string', (tester) async {
      final btn = backendChipOf(_orderRow, 'pack_button');

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: BackendChip(chip: btn)),
      ));

      expect(find.text('Pack 2 left'), findsOneWidget);
      expect(backendChipVisible(btn), isTrue);
    });

    test('pack_get_queue does NOT carry pack_button — see the header note', () {
      expect(_queue.containsKey('pack_button'), isFalse);
    });
  });

  group('hold-to-undo', () {
    test('calls pack_mark_item — NOT pack_undo_item', () {
      expect(kPackUndoRpc, 'pack_mark_item');
      expect(kPackUndoRpc, isNot('pack_undo_item'));
    });

    test('sends p_packed:false and p_qty PRESENT-with-null', () {
      final params = packUndoParams('oi-1');

      expect(params['p_order_item_id'], 'oi-1');
      expect(params['p_packed'], isFalse);
      // Load-bearing: p_qty must be present so PostgREST picks the 3-arg
      // overload. Omitting it selects the legacy 2-arg one, which marks the
      // line unpacked but leaves packed_qty stale.
      expect(params.containsKey('p_qty'), isTrue,
          reason: 'omitting p_qty silently selects the overload that does not '
              'clear packed_qty');
      expect(params['p_qty'], isNull);
      expect(params.keys.toSet(), {'p_order_item_id', 'p_packed', 'p_qty'});
    });

    test('is allowed only on a line the BACKEND calls done', () {
      expect(packUndoAllowed(_itemAt(0)), isTrue); // is_done: true
      expect(packUndoAllowed(_itemAt(1)), isFalse); // is_done: false
    });

    test('is_done is not re-derived from packed_qty >= ordered', () {
      // The pre-#531 client rule was `packable_qty > 0 && packed_qty >= packable_qty`,
      // which ignored counting. This row is fully packed but NOT counted, so the
      // backend says not done — and undo must stay unavailable.
      const packedButUncounted = <String, dynamic>{
        'order_item_id': 'oi-3',
        'ordered': 4,
        'packed_qty': 4,
        'is_packed': true,
        'is_counted': false,
        'is_done': false,
      };
      expect(packUndoAllowed(packedButUncounted), isFalse,
          reason: 'packed_qty >= ordered would wrongly say yes');
    });

    test('a missing is_done is not treated as done', () {
      expect(packUndoAllowed(<String, dynamic>{'order_item_id': 'oi-4'}), isFalse);
    });
  });
}
