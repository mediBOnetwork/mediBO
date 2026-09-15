// PROTECTED — CMD #449.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes order-closure / blocker-tab behaviour.
//
// WHY THIS FILE EXISTS
//
// feature_gaps #10 and #11 recorded that no order and no supplier order had
// ever reached a terminal state — order_closure_log held ZERO rows against 31
// orders and 46 supplier orders. The cause was in the database (the PO prune
// trigger fired on the 'shipped' transition and the delete guard raised
// straight back through order_try_close / supplier_order_try_settle), and the
// migration fixes it. What this file holds down is the FRONTEND half of the
// same path, so the override can never quietly stop being wired again:
//
//   1. The override RPC NAME is the payload's. Neither
//      'admin_order_force_close' nor 'admin_supplier_order_force_settle'
//      appears in Dart — the register recorded them as having "zero callers"
//      precisely because a grep cannot see a name that arrives at runtime, and
//      that must stay true.
//   2. Which parameter it takes follows the row's own backend `kind`.
//   3. An override block the backend omitted (a row already closed) fires
//      nothing at all.
//   4. The toast is the backend's `toast`, and only falls back to the machine
//      `error` slug when there is no toast. No Dart wording, ever.
//
// And the four blocker tabs added by the same command (feature_gaps #17, #12,
// #14, #15) reuse the very same card, so:
//
//   5. A row opens a detail sheet only when the backend did NOT mark it
//      `tappable: false`. A payables row is a supplier and a waterfall row is
//      an inquiry; neither has a closure detail, and the screen must not infer
//      one from the row's shape.
//   6. Absent `tappable` still means openable — that is what the four original
//      closure tabs send, so a new tab opts OUT explicitly and old payloads
//      keep working.
//
// SCOPE NOTE: AdminOrderClosureScreen reaches Supabase in initState, so per
// CLAUDE.md this file asserts the pure decisions (ClosureRowPolicy) the
// widgets are a plain rendering of.
//
// No network, no Supabase, no goldens.

import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/admin_order_closure_screen.dart';

void main() {
  group('override — the RPC is the backend\'s, never a Dart literal', () {
    test('the rpc name is read out of the payload', () {
      expect(
        ClosureRowPolicy.overrideRpc(const {'rpc': 'admin_order_force_close'}),
        'admin_order_force_close',
      );
      expect(
        ClosureRowPolicy.overrideRpc(
            const {'rpc': 'admin_supplier_order_force_settle'}),
        'admin_supplier_order_force_settle',
      );
    });

    test('no override block, or no rpc in it, calls nothing', () {
      expect(ClosureRowPolicy.overrideRpc(null), isNull);
      expect(ClosureRowPolicy.overrideRpc(const {}), isNull);
      expect(ClosureRowPolicy.overrideRpc(const {'rpc': ''}), isNull);
    });

    test('the parameter follows the row kind', () {
      expect(
        ClosureRowPolicy.overrideParams(
            kind: 'order', id: 'o-1', reason: 'closed by hand after delivery'),
        {'p_order_id': 'o-1', 'p_reason': 'closed by hand after delivery'},
      );
      expect(
        ClosureRowPolicy.overrideParams(
            kind: 'supplier_order',
            id: 'so-1',
            reason: 'settled against the July bill'),
        {
          'p_supplier_order_id': 'so-1',
          'p_reason': 'settled against the July bill'
        },
      );
    });

    test('an unknown kind falls back to the customer-order parameter', () {
      expect(
        ClosureRowPolicy.overrideParams(kind: 'payable', id: 'x', reason: 'r'),
        containsPair('p_order_id', 'x'),
      );
    });
  });

  group('override — the refusal is the backend\'s sentence', () {
    test('toast wins when the backend sent one', () {
      expect(
        ClosureRowPolicy.toastFor(const {
          'ok': false,
          'error': 'reason_required',
          'toast': 'Write a reason of at least 10 characters.',
        }),
        'Write a reason of at least 10 characters.',
      );
    });

    test('with no toast the machine slug is shown rather than Dart wording',
        () {
      expect(
        ClosureRowPolicy.toastFor(const {'ok': false, 'error': 'not_authorized'}),
        'not_authorized',
      );
    });

    test('a silent success shows nothing', () {
      expect(ClosureRowPolicy.toastFor(const {'ok': true}), '');
    });
  });

  group('blocker tabs — tappability is a backend flag', () {
    test('a payables row (tappable:false) opens nothing', () {
      expect(
        ClosureRowPolicy.tappable(const {
          'kind': 'payable',
          'order_code': 'Sagar Medicals',
          'tappable': false,
        }),
        isFalse,
      );
    });

    test('a waterfall row (tappable:false) opens nothing', () {
      expect(
        ClosureRowPolicy.tappable(const {
          'kind': 'inquiry',
          'order_code': 'VesiBeta 25 Tablet ER',
          'tappable': false,
        }),
        isFalse,
      );
    });

    test('a pack row the backend marked tappable opens', () {
      expect(
        ClosureRowPolicy.tappable(
            const {'kind': 'order', 'id': 'o-1', 'tappable': true}),
        isTrue,
      );
    });

    test('an old payload with no tappable key stays openable', () {
      expect(
        ClosureRowPolicy.tappable(const {'kind': 'order', 'id': 'o-1'}),
        isTrue,
      );
    });
  });
}
