// PROTECTED — CHANGE #635.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes barcode counting behaviour.
//
// Drives the real BarcodeCountLogic (the state machine BarcodeCountScreen
// delegates to) against fabricated barcode_lookup / barcode_submit_scan
// payloads. No camera, no network, no Supabase.
//
// The four properties that must never regress:
//   1. what the scan renders is what the RPC returned, character for character
//   2. right zone +1, left zone -1, and qty 0 KEEPS the item on screen
//   3. commit sends the staged qty
//   4. a new scan while staged at qty 0 discards it WITHOUT a submit round trip

import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/fulfill/barcode_count_logic.dart';

/// One recorded RPC call.
class _Call {
  final String fn;
  final Map<String, dynamic> params;
  _Call(this.fn, this.params);
  @override
  String toString() => '$fn($params)';
}

/// A fabricated barcode_lookup ok:true payload — the exact shape the RPC returns.
Map<String, dynamic> _lookupOk({
  required int productId,
  required String name,
  String progressLabel = '3 of 10 counted',
  String bagLabel = 'Bag 2',
  bool bagWarning = false,
  int countedQty = 3,
}) =>
    {
      'ok': true,
      'product_id': productId,
      'product_name': name,
      'image_url': 'https://example.invalid/$productId.jpg',
      'pack_label': '10 tablets',
      'company': 'Micro Labs',
      'progress_label': progressLabel,
      'bag_label': bagLabel,
      'bag_warning': bagWarning,
      'counted_qty': countedQty,
    };

/// Builds a logic instance wired to a recording fake.
({BarcodeCountLogic logic, List<_Call> calls}) _harness({
  required Map<String, dynamic> Function(String fn, Map<String, dynamic> p) respond,
  bool isPack = false,
}) {
  final calls = <_Call>[];
  final logic = BarcodeCountLogic(
    isPack: isPack,
    supplierName: 'Acme Pharma',
    stage: 'shop',
    orderId: isPack ? 'order-1' : null,
    sessionKey: 'barcode:Acme Pharma|shop|1',
    dateYmd: () => '2026-08-02',
    rpc: (fn, params) async {
      calls.add(_Call(fn, params));
      return respond(fn, params);
    },
    // Deliberately distinguishable from anything the backend sends, so a test
    // asserting a backend string can never accidentally pass on a local one.
    errorText: (e) => 'LOCAL_ERROR_TEXT',
    messageForCode: (code) => 'LOCAL_MESSAGE_FOR_$code',
  );
  return (logic: logic, calls: calls);
}

void main() {
  group('a scan renders exactly what barcode_lookup returned', () {
    test('name, progress_label and bag_label are verbatim', () async {
      final h = _harness(
        respond: (fn, p) => _lookupOk(
          productId: 42,
          name: 'Dolo 650',
          progressLabel: '3 of 10 counted',
          bagLabel: 'Bag 2',
        ),
      );

      await h.logic.handleCode('8901234567890');

      final s = h.logic.staged!;
      expect(s.productId, 42);
      expect(s.name, 'Dolo 650');
      // Not "3/10", not "3 of 10", not a Dart-composed fraction.
      expect(s.progressLabel, '3 of 10 counted');
      expect(h.logic.progressLabel, '3 of 10 counted');
      expect(s.bagLabel, 'Bag 2');
      expect(s.packLabel, '10 tablets');
      expect(s.company, 'Micro Labs');
      // The bottom bar's count is the backend's counted_qty, not a local tally.
      expect(h.logic.countedQty, 3);
      // The scan that created the stage starts at qty 1 (B2).
      expect(s.qty, 1);
    });

    test('the lookup is scoped by supplier, stage and date', () async {
      final h = _harness(respond: (fn, p) => _lookupOk(productId: 1, name: 'X'));
      await h.logic.handleCode('CODE-1');

      expect(h.calls.single.fn, 'barcode_lookup');
      expect(h.calls.single.params, {
        'p_supplier': 'Acme Pharma',
        'p_barcode': 'CODE-1',
        'p_stage': 'shop',
        'p_date': '2026-08-02',
      });
    });

    test('ok:false renders the backend title + message and stages nothing', () async {
      final h = _harness(
        respond: (fn, p) => {
          'ok': false,
          'error': 'not_on_order',
          'title': 'Not on this order',
          'message': 'Scan a product from Acme Pharma’s order.',
        },
      );

      await h.logic.handleCode('CODE-BAD');

      expect(h.logic.staged, isNull);
      expect(h.logic.errTitle, 'Not on this order');
      expect(h.logic.errMessage, 'Scan a product from Acme Pharma’s order.');
      // Never the local fallback when the backend supplied copy.
      expect(h.logic.errMessage, isNot(contains('LOCAL_')));
    });

    test('the same barcode again increments — with NO second RPC', () async {
      final h = _harness(respond: (fn, p) => _lookupOk(productId: 7, name: 'Pan 40'));

      await h.logic.handleCode('SAME');
      await h.logic.handleCode('SAME');
      await h.logic.handleCode('SAME');

      expect(h.logic.staged!.qty, 3);
      expect(h.calls.length, 1, reason: 'B2: repeat scans never hit the network');
    });
  });

  group('tap zones', () {
    Future<BarcodeCountLogic> staged() async {
      final h = _harness(respond: (fn, p) => _lookupOk(productId: 9, name: 'Zerodol'));
      await h.logic.handleCode('C');
      return h.logic;
    }

    test('right zone increments the staged qty', () async {
      final l = await staged();
      l.bump(1);
      l.bump(1);
      expect(l.staged!.qty, 3); // started at 1
    });

    test('left zone decrements', () async {
      final l = await staged();
      l.bump(1);
      l.bump(1);
      l.bump(-1);
      expect(l.staged!.qty, 2);
    });

    test('qty 0 KEEPS the item on screen — a mis-tap is undone by tapping right', () async {
      final l = await staged();
      l.bump(-1);
      expect(l.staged!.qty, 0);
      expect(l.staged, isNotNull,
          reason: 'B4: at 0 the product stays so the mis-tap is recoverable');
      l.bump(1);
      expect(l.staged!.qty, 1);
    });

    test('never below zero', () async {
      final l = await staged();
      l.bump(-1);
      l.bump(-1);
      l.bump(-1);
      expect(l.staged!.qty, 0);
    });
  });

  group('commit', () {
    test('sends the staged qty and renders the response verbatim', () async {
      final h = _harness(
        respond: (fn, p) => fn == 'barcode_lookup'
            ? _lookupOk(productId: 42, name: 'Dolo 650')
            : {
                'ok': true,
                'counted_qty': 8,
                'progress_label': '8 of 10 counted',
                'is_over': false,
                'over_qty': 0,
              },
      );

      await h.logic.handleCode('CODE');
      h.logic.bump(1);
      h.logic.bump(1);
      h.logic.bump(1);
      h.logic.bump(1); // staged qty is now 5
      await h.logic.commit();

      final submit = h.calls.last;
      expect(submit.fn, 'barcode_submit_scan');
      expect(submit.params['p_qty'], 5, reason: 'the STAGED qty, not 1, not counted_qty');
      expect(submit.params['p_product_id'], 42);
      expect(submit.params['p_session_key'], 'barcode:Acme Pharma|shop|1');

      // C5: the bottom bar is the commit response, verbatim.
      expect(h.logic.countedQty, 8);
      expect(h.logic.progressLabel, '8 of 10 counted');
      expect(h.logic.staged, isNull);
      expect(h.logic.anyCommitted, isTrue);
    });

    test('an over-count renders the backend is_over/over_qty', () async {
      final h = _harness(
        respond: (fn, p) => fn == 'barcode_lookup'
            ? _lookupOk(productId: 1, name: 'X')
            : {
                'ok': true,
                'counted_qty': 12,
                'progress_label': '12 of 10 counted',
                'is_over': true,
                'over_qty': 2,
              },
      );

      await h.logic.handleCode('CODE');
      await h.logic.commit();

      expect(h.logic.isOver, isTrue);
      expect(h.logic.overQty, 2, reason: 'from the RPC — never 12 minus 10 in Dart');
    });

    test('a refused commit shows the backend message', () async {
      final h = _harness(
        respond: (fn, p) => fn == 'barcode_lookup'
            ? _lookupOk(productId: 1, name: 'X')
            : {'ok': false, 'error': 'locked', 'message': 'Counting is closed for today.'},
      );

      await h.logic.handleCode('CODE');
      await h.logic.commit();

      expect(h.logic.errMessage, 'Counting is closed for today.');
      expect(h.logic.staged, isNull);
      expect(h.logic.anyCommitted, isFalse);
    });
  });

  group('qty 0 discards without a submit', () {
    test('a NEW scan at qty 0 never calls barcode_submit_scan', () async {
      final h = _harness(
        respond: (fn, p) => fn == 'barcode_lookup'
            ? _lookupOk(productId: 1, name: 'First')
            : {'ok': true, 'counted_qty': 1, 'progress_label': 'x', 'is_over': false, 'over_qty': 0},
      );

      await h.logic.handleCode('FIRST');
      h.logic.bump(-1); // tapped down to 0 — the operator changed their mind
      expect(h.logic.staged!.qty, 0);

      await h.logic.handleCode('SECOND'); // C2 auto-commit path

      expect(
        h.calls.where((c) => c.fn == 'barcode_submit_scan'),
        isEmpty,
        reason: 'C4: zero is not a count — nothing may be written',
      );
      // ...and the new code was still looked up.
      expect(h.calls.map((c) => c.fn).toList(), ['barcode_lookup', 'barcode_lookup']);
      expect(h.calls.last.params['p_barcode'], 'SECOND');
    });

    test('closing the screen at qty 0 writes nothing', () async {
      final h = _harness(
        respond: (fn, p) => fn == 'barcode_lookup'
            ? _lookupOk(productId: 1, name: 'First')
            : {'ok': true},
      );

      await h.logic.handleCode('FIRST');
      h.logic.bump(-1);
      await h.logic.flushOnClose();

      expect(h.calls.where((c) => c.fn == 'barcode_submit_scan'), isEmpty);
      expect(h.logic.staged, isNull);
      expect(h.logic.anyCommitted, isFalse);
    });

    test('a DIFFERENT barcode at qty > 0 DOES auto-commit first', () async {
      final h = _harness(
        respond: (fn, p) => fn == 'barcode_lookup'
            ? _lookupOk(productId: p['p_barcode'] == 'FIRST' ? 1 : 2, name: 'n')
            : {'ok': true, 'counted_qty': 2, 'progress_label': 'x', 'is_over': false, 'over_qty': 0},
      );

      await h.logic.handleCode('FIRST');
      h.logic.bump(1); // qty 2
      await h.logic.handleCode('SECOND');

      expect(h.calls.map((c) => c.fn).toList(),
          ['barcode_lookup', 'barcode_submit_scan', 'barcode_lookup']);
      expect(h.calls[1].params['p_qty'], 2);
      expect(h.calls[1].params['p_product_id'], 1);
    });
  });

  group('Pack mode never crosses into the supplier ledger', () {
    test('pack uses the pack_* RPC family and sends no supplier/stage/date', () async {
      final h = _harness(
        isPack: true,
        respond: (fn, p) => fn == 'pack_barcode_lookup'
            ? _lookupOk(productId: 5, name: 'Pack item')
            : {'ok': true, 'counted_qty': 1, 'progress_label': 'p', 'is_over': false, 'over_qty': 0},
      );

      await h.logic.handleCode('CODE');
      await h.logic.commit();

      expect(h.calls.map((c) => c.fn).toList(),
          ['pack_barcode_lookup', 'pack_barcode_submit_scan']);
      expect(h.calls.first.params.keys.toSet(), {'p_order_id', 'p_barcode'});
      expect(h.calls.last.params.containsKey('p_supplier'), isFalse);
      expect(h.calls.last.params.containsKey('p_stage'), isFalse);
      // A2: there is no bag in Pack — the field is empty, never a stale label.
      expect(h.logic.staged, isNull); // committed
    });

    test('pack ignores any bag fields that leak into the payload', () async {
      final h = _harness(
        isPack: true,
        respond: (fn, p) => _lookupOk(
            productId: 5, name: 'Pack item', bagLabel: 'Bag 9', bagWarning: true),
      );

      await h.logic.handleCode('CODE');

      expect(h.logic.staged!.bagLabel, '');
      expect(h.logic.staged!.bagWarning, isFalse);
    });
  });
}
