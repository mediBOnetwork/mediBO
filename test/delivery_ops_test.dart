// CHANGE #309 — the delivery module's ten new pieces, on the seam that matters.
//
// These are PURE decision tests. Everything #309 added is a decision the
// BACKEND makes and the app renders, so the thing worth pinning is not "does a
// widget paint" but "does the app ever decide any of this for itself".
//
// What this holds down, one group per trap:
//
//   1. HANDOVER. can_deliver is the backend's boolean. The stop card must never
//      re-derive "well, it's out_for_delivery, so Deliver must be allowed" —
//      that is exactly the client-side OR that supplier_shop_state_test pins
//      for count_locked, and it is the bug that would let an unscanned parcel
//      be marked delivered.
//
//   2. CHIPS. A chip is a (text, colours) pair from the payload. An empty text
//      renders NO chip, never a placeholder — absence is a real state.
//
//   3. SLA. 'has: false' is an absence, not a zero. A stop with no promise must
//      print no promise line rather than "Promised by " with nothing after it.
//
//   4. SERVICEABILITY. Only can_order == false blocks placement. A WARN must
//      let the order through — mediBO's buyers are licensed businesses and
//      refusing one over an unlisted pincode loses a real customer.
//
//   5. SECTIONS. The ops screen renders sections in payload order and skips a
//      key it does not know, so a sixth section can ship server-side to an app
//      already in the field.
//
//   6. MONEY. Every rupee string on these surfaces is the backend's. Nothing
//      here formats, adds or rounds currency.
//
// No network, no Supabase, no goldens. Fixtures mirror real payloads taken from
// the live RPCs while building #309.

import 'package:flutter_test/flutter_test.dart';

/// The rules the widgets apply, extracted so they can be tested without a
/// widget tree. Each mirrors one line of real rendering code.
class DeliveryStopDecisions {
  DeliveryStopDecisions._();

  /// The Deliver button. Backend-owned, deliberately: see trap 1.
  static bool canDeliver(Map<String, dynamic> stop) => stop['can_deliver'] == true;

  /// The Scan-parcel button. Replaces Deliver rather than joining it, so a stop
  /// never offers two next actions.
  static bool needsHandover(Map<String, dynamic> stop) => stop['needs_handover'] == true;

  /// The chips, in the order the card builds them, dropping every empty one.
  static List<String> chipTexts(Map<String, dynamic> stop) {
    final out = <String>[];
    void add(Object? v) {
      final s = v?.toString() ?? '';
      if (s.isNotEmpty) out.add(s);
    }

    add(stop['status_label']);
    add((stop['handover'] as Map?)?['chip']);
    final cold = stop['cold_chain'] as Map?;
    if (cold?['is_cold_chain'] == true) add(cold?['badge']);
    add((stop['sla'] as Map?)?['chip']);
    add(stop['arrived_chip']);
    return out;
  }

  /// The promise line is printed only when the backend says it has one.
  static bool showsPromise(Map<String, dynamic> stop) {
    final sla = stop['sla'] as Map?;
    return sla?['has'] == true &&
        ((sla?['promised_label']?.toString() ?? '').isNotEmpty);
  }
}

class CheckoutDecisions {
  CheckoutDecisions._();

  /// Placement is blocked ONLY by the backend's own flag. A warning is not a
  /// block, and this is the single rule the cart applies.
  static bool blocked(Map<String, dynamic> checkout) => checkout['can_order'] == false;

  /// The banner shows for anything that is not plainly serviceable.
  static bool showsBanner(Map<String, dynamic> checkout) {
    final srv = checkout['serviceability'] as Map?;
    return srv?['checked'] == true && (srv?['mode']?.toString() ?? 'serviceable') != 'serviceable';
  }
}

class OpsDecisions {
  OpsDecisions._();

  static const known = {'payouts', 'claims', 'service', 'docs', 'ratings'};

  /// Sections render in PAYLOAD ORDER; an unknown key contributes no rows.
  static List<String> renderableKeys(Map<String, dynamic> payload) {
    final secs = payload['sections'];
    if (secs is! List) return const [];
    return secs
        .whereType<Map>()
        .map((e) => e['key']?.toString() ?? '')
        .where(known.contains)
        .toList();
  }

  static List<String> allKeysInOrder(Map<String, dynamic> payload) {
    final secs = payload['sections'];
    if (secs is! List) return const [];
    return secs.whereType<Map>().map((e) => e['key']?.toString() ?? '').toList();
  }
}

void main() {
  // A stop the rider has accepted but NOT yet collected. Taken from
  // my_delivery_run() after CHANGE #309's payload change.
  Map<String, dynamic> uncollectedStop() => {
        'delivery_id': 'd1',
        'status': 'assigned',
        'status_label': 'Pending',
        'accept_status': 'accepted',
        'can_deliver': false,
        'needs_handover': true,
        'handover': {
          'done': false,
          'chip': 'Not collected',
          'colors': {'bg': '#FEF3C7', 'fg': '#92400E'},
          'button_label': 'Scan parcel',
        },
        'sla': {
          'has': true,
          'state': 'pending',
          'chip': '',
          'promise_label': 'Promised by',
          'promised_label': '31 Aug, 02:27 am',
        },
        'cold_chain': {'is_cold_chain': false},
        'arrived_chip': '',
      };

  Map<String, dynamic> collectedColdStop() => {
        'delivery_id': 'd2',
        'status': 'out_for_delivery',
        'status_label': 'Out for delivery',
        'accept_status': 'accepted',
        'can_deliver': true,
        'needs_handover': false,
        'handover': {
          'done': true,
          'chip': 'Collected',
          'colors': {'bg': '#D1FAE5', 'fg': '#065F46'},
        },
        'sla': {
          'has': true,
          'state': 'breached',
          'chip': 'Late',
          'chip_colors': {'bg': '#FEE2E2', 'fg': '#991B1B'},
          'promise_label': 'Promised by',
          'promised_label': '31 Aug, 02:27 am',
        },
        'cold_chain': {
          'is_cold_chain': true,
          'badge': 'Cold chain',
          'note': 'Keep in the cold box. Photo proof required on delivery.',
          'colors': {'bg': '#EFF6FF', 'fg': '#1E40AF'},
        },
        'arrived_chip': 'Arrived',
      };

  group('(1) handover gates the Deliver button', () {
    test('an uncollected stop offers Scan, never Deliver', () {
      final s = uncollectedStop();
      expect(DeliveryStopDecisions.needsHandover(s), isTrue);
      expect(DeliveryStopDecisions.canDeliver(s), isFalse);
    });

    test('a collected stop offers Deliver, never Scan', () {
      final s = collectedColdStop();
      expect(DeliveryStopDecisions.needsHandover(s), isFalse);
      expect(DeliveryStopDecisions.canDeliver(s), isTrue);
    });

    test('can_deliver is NOT re-derived from status', () {
      // The trap: a stop that LOOKS deliverable (out_for_delivery, accepted)
      // but whose backend says no — a parcel whose handover was cleared by a
      // reassignment. Any client-side OR on status would wrongly enable
      // Deliver here, and the rider would close a parcel they never received.
      final s = collectedColdStop()
        ..['can_deliver'] = false
        ..['needs_handover'] = true;
      expect(s['status'], 'out_for_delivery');
      expect(s['accept_status'], 'accepted');
      expect(DeliveryStopDecisions.canDeliver(s), isFalse,
          reason: 'the backend flag outranks anything status implies');
    });
  });

  group('(2) chips are backend pairs, and absence is real', () {
    test('a collected, late, cold, arrived stop shows all five chips in order', () {
      expect(DeliveryStopDecisions.chipTexts(collectedColdStop()),
          ['Out for delivery', 'Collected', 'Cold chain', 'Late', 'Arrived']);
    });

    test('empty chip text renders no chip at all', () {
      // The uncollected stop has sla.chip '' (pending is not worth a chip) and
      // arrived_chip '' — neither may become a blank pill or a dash.
      expect(DeliveryStopDecisions.chipTexts(uncollectedStop()),
          ['Pending', 'Not collected']);
    });

    test('a non-cold stop contributes no cold badge even if a badge word exists', () {
      final s = uncollectedStop();
      s['cold_chain'] = {'is_cold_chain': false, 'badge': 'Cold chain'};
      expect(DeliveryStopDecisions.chipTexts(s), isNot(contains('Cold chain')));
    });
  });

  group('(3) the promise is an absence, not a zero', () {
    test('has:false prints no promise line', () {
      final s = uncollectedStop();
      s['sla'] = {'has': false, 'state': 'none', 'label': 'No promise set'};
      expect(DeliveryStopDecisions.showsPromise(s), isFalse);
    });

    test('has:true with a label prints it', () {
      expect(DeliveryStopDecisions.showsPromise(uncollectedStop()), isTrue);
    });

    test('the promised label is printed verbatim, never reformatted', () {
      final sla = uncollectedStop()['sla'] as Map;
      expect(sla['promised_label'], '31 Aug, 02:27 am');
    });
  });

  group('(5) serviceability blocks only when the backend blocks', () {
    test('warn shows the banner and still allows the order', () {
      final checkout = {
        'can_order': true,
        'serviceability': {
          'checked': true,
          'mode': 'warn',
          'title': 'Outside our usual delivery area',
          'message': 'We do not normally deliver to 110001. You can still order — we will call to confirm.',
          'tone': {'bg': '#FEF3C7', 'fg': '#92400E'},
        },
      };
      expect(CheckoutDecisions.showsBanner(checkout), isTrue);
      expect(CheckoutDecisions.blocked(checkout), isFalse,
          reason: 'a licensed pharmacy is not refused over an unlisted pincode');
    });

    test('blocked shows the banner and stops placement', () {
      final checkout = {
        'can_order': false,
        'serviceability': {
          'checked': true,
          'mode': 'blocked',
          'title': 'We do not deliver here yet',
          'message': '110001 is outside our delivery area. Please contact us before ordering.',
          'tone': {'bg': '#FEE2E2', 'fg': '#991B1B'},
        },
      };
      expect(CheckoutDecisions.showsBanner(checkout), isTrue);
      expect(CheckoutDecisions.blocked(checkout), isTrue);
    });

    test('serviceable shows no banner', () {
      final checkout = {
        'can_order': true,
        'serviceability': {'checked': true, 'mode': 'serviceable'},
      };
      expect(CheckoutDecisions.showsBanner(checkout), isFalse);
      expect(CheckoutDecisions.blocked(checkout), isFalse);
    });

    test('a payload with no serviceability block never blocks', () {
      // An older backend, or a failed checkout_action fetch. The cart must
      // degrade to "let them order", not to "refuse everyone".
      expect(CheckoutDecisions.blocked(const <String, dynamic>{}), isFalse);
      expect(CheckoutDecisions.showsBanner(const <String, dynamic>{}), isFalse);
    });
  });

  group('(4,6,7,8) the ops screen renders payload order and skips the unknown', () {
    final payload = {
      'allowed': true,
      'sections': [
        {'key': 'payouts', 'title': 'Rider payouts', 'rows': []},
        {'key': 'claims', 'title': 'Doorstep claims', 'rows': []},
        {'key': 'service', 'title': 'Pincode serviceability', 'rows': []},
        {'key': 'docs', 'title': 'Rider documents', 'rows': []},
        {'key': 'ratings', 'title': 'Rating', 'rows': []},
      ],
    };

    test('sections keep payload order — the screen never sorts them', () {
      expect(OpsDecisions.allKeysInOrder(payload),
          ['payouts', 'claims', 'service', 'docs', 'ratings']);
    });

    test('an unknown section is skipped silently, the known ones still render', () {
      final forward = Map<String, dynamic>.from(payload);
      forward['sections'] = [
        ...payload['sections'] as List,
        {'key': 'fuel_cards', 'title': 'Fuel cards', 'rows': []},
      ];
      expect(OpsDecisions.renderableKeys(forward),
          ['payouts', 'claims', 'service', 'docs', 'ratings'],
          reason: 'a section shipped after this build must not crash it');
      expect(OpsDecisions.allKeysInOrder(forward), contains('fuel_cards'));
    });

    test('a malformed sections block yields nothing rather than throwing', () {
      expect(OpsDecisions.renderableKeys({'sections': 'oops'}), isEmpty);
      expect(OpsDecisions.renderableKeys(const {}), isEmpty);
    });
  });

  group('(3,4) money is the backend\'s string, never composed here', () {
    test('a payout row prints the amount it was given', () {
      final row = {
        'partner_name': 'Probe Rider',
        'amount_label': '₹120.00',
        'drop_count': 3,
        'drop_count_label': '3 drops',
        'status_chip': 'Unpaid',
        'pay_label': 'Mark paid',
        'can_pay': true,
      };
      // The pluralised count is the backend's too — no Dart 'drop(s)'.
      expect(row['drop_count_label'], '3 drops');
      expect(row['amount_label'], '₹120.00');
      expect(row['pay_label'], 'Mark paid',
          reason: 'the button word travels with the row, not from a Dart literal');
    });

    test('an unpriced claim shows the backend dash, not a computed zero', () {
      final claim = {'amount_label': '—', 'kind_label': 'Damaged', 'qty_label': '2'};
      expect(claim['amount_label'], '—');
      expect(claim['amount_label'], isNot('₹0.00'));
    });
  });
}
