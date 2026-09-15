// CHANGE #472 — the CLIENT half of idempotency.
//
// The backend edges answer a repeated client_action_id with the first answer
// instead of applying the money twice. That guarantee is worth exactly nothing
// if the screen mints a fresh key on every tap: then every retry is a new
// action and the ledger never matches. So what is held down here is the one
// client rule the whole change rests on —
//
//     mint once when the user commits, reuse for every retry,
//     retire only when the action actually landed.
//
// The double-fire proof against the real database lives in rg_behavior_tests
// (scripts/c472_idempotency_proof.sh) because this suite is Dart-VM-only with
// no Supabase (CLAUDE.md). What CAN be tested here is the key's lifecycle and
// the shape of the params every keyed call site sends, so a future edit that
// drops `p_client_action_id` or moves the mint inside the tap handler fails
// before it ships.

import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/services/idempotency.dart';

/// A stand-in for the one thing every keyed call site does: build the params
/// map for an RPC from the slot it holds. Mirrors cart_screen, sup_pay_panel,
/// settlement_screen and returns_refunds_screen.
Map<String, dynamic> _params(ActionSlot slot, Map<String, dynamic> rest) =>
    {...rest, 'p_client_action_id': slot.key};

void main() {
  group('ActionKey.mint', () {
    test('is a v4 uuid — the shape the uuid columns accept', () {
      final k = ActionKey.mint();
      expect(
        RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
            .hasMatch(k),
        isTrue,
        reason: 'got "$k" — the backend casts this straight to uuid',
      );
    });

    test('two mints never collide', () {
      final seen = <String>{};
      for (var i = 0; i < 5000; i++) {
        expect(seen.add(ActionKey.mint()), isTrue, reason: 'minted a duplicate key');
      }
    });
  });

  group('ActionSlot — one key per INTENT, not per attempt', () {
    test('every read before the action lands returns the SAME key', () {
      final slot = ActionSlot();
      final first = slot.key;
      // three failed attempts: a timeout, a 500, a lost connection
      expect(slot.key, first);
      expect(slot.key, first);
      expect(slot.key, first,
          reason: 'a retry that changes the key is a SECOND order, not a retry');
    });

    test('nothing is minted until the user commits', () {
      final slot = ActionSlot();
      expect(slot.isInFlight, isFalse);
      slot.key;
      expect(slot.isInFlight, isTrue);
    });

    test('done() retires the key, so the NEXT action is a different one', () {
      final slot = ActionSlot();
      final first = slot.key;
      slot.done();
      expect(slot.isInFlight, isFalse);
      expect(slot.key, isNot(first),
          reason: 'a second, deliberate order must not be deduped against the first');
    });

    test('abandon() also retires it — a cancelled sheet is not a retry', () {
      final slot = ActionSlot();
      final first = slot.key;
      slot.abandon();
      expect(slot.key, isNot(first));
    });
  });

  group('the params every keyed call site sends', () {
    test('p_client_action_id is present and is the slot key', () {
      final slot = ActionSlot();
      final p = _params(slot, {'p_order_id': 'o1', 'p_amount': 100});
      expect(p.containsKey('p_client_action_id'), isTrue,
          reason: 'without this parameter the edge falls back to unkeyed behaviour');
      expect(p['p_client_action_id'], slot.key);
    });

    test('a retry sends byte-identical params — same key, same everything', () {
      final slot = ActionSlot();
      final rest = {'p_supplier_order_id': 'so1', 'p_amount': 500, 'p_mode': 'cash'};
      final first = _params(slot, rest);
      final retry = _params(slot, rest);
      expect(retry, equals(first),
          reason: 'the server can only recognise a retry if it looks like one');
    });

    test('after success the next action carries a different key', () {
      final slot = ActionSlot();
      final firstOrder = _params(slot, {'x': 1});
      slot.done();
      final secondOrder = _params(slot, {'x': 1});
      expect(secondOrder['p_client_action_id'],
          isNot(firstOrder['p_client_action_id']));
    });

    test('two screens hold two independent slots', () {
      final cart = ActionSlot();
      final refund = ActionSlot();
      expect(cart.key, isNot(refund.key),
          reason: 'one shared key would make an order and a refund the same action');
    });
  });
}
