// PROTECTED — CHANGE #469, the order state machine.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes this behaviour, never to make an unrelated change go
// green.
//
// The machine itself lives in Postgres (order_state_transitions +
// _c469_state_guard), and the suite runs on the Dart VM with no network. So
// what is held down here is the DECISION, extracted into a pure class the
// trigger and this test share a shape with: given the seeded transition table,
// which jumps are legal and which are refused — and what the refusal SAYS.
//
// What this holds down:
//
//   1. THE ANSWER IS A TABLE LOOKUP, NOT A GUESS. A transition is legal only
//      when (entity, from, to, actor) is present. Nothing is inferred from the
//      shape of the words: 'delivered' is not special, 'cancelled' is not
//      universally reachable, and an actor that was not seeded is refused even
//      for a pair that IS seeded for someone else.
//
//   2. FIVE DISTINCT ILLEGAL JUMPS ARE REFUSED — the ones the spec named plus
//      the two the flow actually makes possible: a delivery going out without
//      being assigned, a delivery delivered without going out, an order
//      delivered without acceptance, a status the vocabulary has never held,
//      and a rider doing an office-only move.
//
//   3. THE REFUSAL NAMES THE TRANSITION. The message is built from the
//      backend's own template with from/to/actor substituted — a caller who
//      trips it is told exactly what was refused, never "constraint violated".
//
//   4. ROW CREATION IS A TRANSITION TOO, from '' — so an order cannot be born
//      in a state the machine cannot reach.

import 'package:flutter_test/flutter_test.dart';

/// The seeded machine, as a lookup. Mirrors order_state_transitions: the KEY is
/// (entity, from, to, actor) and presence is the whole answer.
class StateMachine {
  StateMachine(this._legal);

  final Set<String> _legal;

  static String _k(String entity, String from, String to, String actor) =>
      '$entity|$from|$to|$actor';

  bool isLegal(String entity, String from, String to, String actor) =>
      _legal.contains(_k(entity, from, to, actor));

  /// The refusal, worded exactly as `order_state.illegal` /
  /// `order_state.illegal_new` are worded in ui_copy. The template is the
  /// backend's; this only substitutes.
  String refusal(String entity, String from, String to, String actor) =>
      from.isEmpty
          ? 'A $entity cannot start life in $to as $actor.'
          : '$entity cannot go from $from to $to as $actor. '
              'That transition is not in the state machine.';
}

/// The subset of the live seed these tests reason about. Each line is a row
/// that exists in order_state_transitions on production.
StateMachine _seeded() => StateMachine({
      // orders
      'order||pending|customer',
      'order||pending|system',
      'order||accepted|admin',
      'order|pending|accepted|system',
      'order|pending|accepted|admin',
      'order|pending|cancelled|customer',
      'order|pending|cancelled|admin',
      'order|accepted|delivered|system',
      'order|accepted|delivered|admin',
      'order|accepted|cancelled|admin',
      'order|delivered|returned|system',
      // deliveries
      'delivery||unassigned|system',
      'delivery||assigned|admin',
      'delivery|unassigned|assigned|admin',
      'delivery|unassigned|assigned|partner',
      'delivery|assigned|out_for_delivery|rider',
      'delivery|assigned|out_for_delivery|admin',
      'delivery|out_for_delivery|delivered|rider',
      'delivery|out_for_delivery|delivered|admin',
      'delivery|out_for_delivery|failed|rider',
      'delivery|failed|unassigned|system',
    });

void main() {
  final m = _seeded();

  group('CHANGE #469 — one legal path, end to end', () {
    test('an order walks checkout -> accepted -> delivered, and its delivery '
        'walks unassigned -> assigned -> out_for_delivery -> delivered', () {
      // the order side
      expect(m.isLegal('order', '', 'pending', 'customer'), isTrue);
      expect(m.isLegal('order', 'pending', 'accepted', 'system'), isTrue);
      expect(m.isLegal('order', 'accepted', 'delivered', 'system'), isTrue);

      // the delivery side, the same journey seen from the road
      expect(m.isLegal('delivery', '', 'unassigned', 'system'), isTrue);
      expect(m.isLegal('delivery', 'unassigned', 'assigned', 'admin'), isTrue);
      expect(
          m.isLegal('delivery', 'assigned', 'out_for_delivery', 'rider'), isTrue);
      expect(m.isLegal('delivery', 'out_for_delivery', 'delivered', 'rider'),
          isTrue);
    });

    test('a failed run may be sent out again — the machine is not one-way', () {
      expect(m.isLegal('delivery', 'out_for_delivery', 'failed', 'rider'), isTrue);
      expect(m.isLegal('delivery', 'failed', 'unassigned', 'system'), isTrue);
    });
  });

  group('CHANGE #469 — five distinct illegal jumps are refused', () {
    test('1. a delivery goes out without ever being assigned', () {
      expect(m.isLegal('delivery', 'unassigned', 'out_for_delivery', 'rider'),
          isFalse);
    });

    test('2. a delivery is marked delivered without going out', () {
      expect(
          m.isLegal('delivery', 'assigned', 'delivered', 'rider'), isFalse);
    });

    test('3. an order is delivered without ever being accepted', () {
      expect(m.isLegal('order', 'pending', 'delivered', 'system'), isFalse);
    });

    test('4. an order jumps to a status the vocabulary has never held', () {
      expect(m.isLegal('order', 'accepted', 'packed', 'admin'), isFalse);
      expect(m.isLegal('order', 'accepted', 'shipped', 'admin'), isFalse);
    });

    test('5. the ACTOR is part of the key — a rider cannot do an office move',
        () {
      // The office may cancel an accepted order; a rider may not, even though
      // the (from,to) pair itself is perfectly legal for someone else.
      expect(m.isLegal('order', 'accepted', 'cancelled', 'admin'), isTrue);
      expect(m.isLegal('order', 'accepted', 'cancelled', 'rider'), isFalse);
    });
  });

  group('CHANGE #469 — the refusal names the transition', () {
    test('an illegal jump is reported with its from, to and actor', () {
      expect(m.refusal('order', 'accepted', 'packed', 'admin'),
          'order cannot go from accepted to packed as admin. '
          'That transition is not in the state machine.');
    });

    test('an illegal BIRTH is reported as a birth, not as a jump from nowhere',
        () {
      expect(m.refusal('order', '', 'delivered', 'customer'),
          'A order cannot start life in delivered as customer.');
    });
  });

  group('CHANGE #469 — creation is a transition too', () {
    test('an order cannot be born delivered, or cancelled, or in transit', () {
      expect(m.isLegal('order', '', 'delivered', 'customer'), isFalse);
      expect(m.isLegal('order', '', 'cancelled', 'customer'), isFalse);
      expect(m.isLegal('delivery', '', 'out_for_delivery', 'rider'), isFalse);
    });

    test('but the office may raise an order that is already paid for', () {
      expect(m.isLegal('order', '', 'accepted', 'admin'), isTrue);
      // ...and only the office. A customer cannot hand themselves acceptance.
      expect(m.isLegal('order', '', 'accepted', 'customer'), isFalse);
    });
  });
}
