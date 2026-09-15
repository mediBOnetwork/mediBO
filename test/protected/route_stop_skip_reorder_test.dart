// CMD #1874, amended by CMD #2057 — what Skip, the route ORDER and a
// Converted check-in decide.
//
// The point of this file is that the answer to every one of those is "the
// backend did". These tests hold down the places a Dart default could creep
// back in:
//
//   • Skip and Restore are the SAME call, and the direction comes from the
//     menu entry the backend sent — never from a toggle of the local flag.
//   • CMD #2057: the route order is LOCKED. canReorder() is false for every
//     payload — including one that still carries can_reorder:true — and the
//     drag helpers are gone, so no drag can be posted from anywhere.
//   • the active set is `skipped`, in payload order, with no client sort.
//   • Converted opens Add customer because route_stop_checkin() said so
//     (next_action), not because Dart recognises the word "converted".

import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/route_stop_checkin_sheet.dart';

Map<String, dynamic> stop(String id,
        {bool canDrag = true, bool skipped = false, List? menu}) =>
    {
      'stop_id': id,
      'can_drag': canDrag,
      'skipped': skipped,
      'menu': menu ??
          [
            {
              'key': skipped ? 'stop_unskip' : 'stop_skip',
              'label': skipped ? 'Put back on the route' : 'Skip this stop',
              'skipped': !skipped,
              'tone': skipped ? 'brand' : 'warning',
            }
          ],
    };

void main() {
  test('Skip and Restore are one call — the ENTRY carries the direction', () {
    final active = stop('s1');
    final parked = stop('s2', canDrag: false, skipped: true);

    final skipEntry = RouteStopCheckInPlan.menu(active).single;
    final backEntry = RouteStopCheckInPlan.menu(parked).single;

    expect(RouteStopCheckInPlan.skipStopParams('s1', skipEntry),
        {'p_stop_id': 's1', 'p_skipped': true});
    expect(RouteStopCheckInPlan.skipStopParams('s2', backEntry),
        {'p_stop_id': 's2', 'p_skipped': false});

    // An entry with no state is not a skip — the row does nothing rather than
    // guessing which way to move the stop.
    expect(RouteStopCheckInPlan.skipStopParams('s1', {'key': 'stop_skip'}),
        isNull);

    expect(RouteStopCheckInPlan.isSkipped(parked), isTrue);
    expect(RouteStopCheckInPlan.isSkipped(active), isFalse);
  });

  test('the active set is `skipped`, in payload order, never re-sorted', () {
    final payload = {
      'can_reorder': true,
      'stops': [
        {...stop('s1'), 'status_key': 'visited'},
        stop('s2'),
        stop('s3', canDrag: false, skipped: true),
      ],
    };

    // A stop already checked in still holds its place in the day; only a
    // SKIPPED stop drops out of the active list.
    expect(
        RouteStopCheckInPlan.active(payload).map((e) => e['stop_id']).toList(),
        ['s1', 's2']);
    expect(
        RouteStopCheckInPlan.skipped(payload)
            .map((e) => e['stop_id'])
            .toList(),
        ['s3']);
  });

  test('CMD #2057 — the order is LOCKED, whatever the payload says', () {
    // The optimised order is the order: stop 1 first, stop 2 second, always.
    // Even a payload that still carries the old can_reorder:true cannot put a
    // drag handle back on the list.
    expect(
        RouteStopCheckInPlan.canReorder({
          'can_reorder': true,
          'order_locked': true,
          'stops': [stop('s1'), stop('s2'), stop('s3')],
        }),
        isFalse);
    expect(
        RouteStopCheckInPlan.canReorder(
            {'can_reorder': false, 'stops': [stop('s1')]}),
        isFalse);
    expect(RouteStopCheckInPlan.canReorder(null), isFalse);
  });

  test('Converted opens Add customer because next_action said so', () {
    final converted = {
      'ok': true,
      'status': 'converted',
      'lead_id': 9903,
      'next_action': {
        'key': 'add_customer',
        'lead_id': 9903,
        'label': 'Add customer',
      },
    };
    final next = RouteStopCheckInPlan.nextAction(converted);
    expect(RouteStopCheckInPlan.isAddCustomer(next), isTrue);
    expect(RouteStopCheckInPlan.leadIdOf(next), 9903);
    // The label is the backend's; the sheet never spells one.
    expect(next!['label'], 'Add customer');
  });

  test('a shop already linked gets no second form — even on Converted', () {
    // The status is the same word; the backend simply sent no next_action
    // because scraped_leads.matched_customer_id is already set.
    final already = {'ok': true, 'status': 'converted', 'lead_id': 9903};
    expect(RouteStopCheckInPlan.nextAction(already), isNull);
    expect(RouteStopCheckInPlan.isAddCustomer(null), isFalse);

    // Every other outcome carries none either.
    expect(
        RouteStopCheckInPlan.nextAction(
            {'ok': true, 'status': 'visited', 'next_action': null}),
        isNull);
    // A malformed action with no key is not an instruction.
    expect(
        RouteStopCheckInPlan.nextAction({'next_action': {'lead_id': 1}}),
        isNull);
  });

  test('a row with no menu offers no long-press action', () {
    expect(RouteStopCheckInPlan.menu(const {}), isEmpty);
    expect(RouteStopCheckInPlan.menu({'menu': const []}), isEmpty);
    // #1873's one-tap Skip (a 'closed' check-in) is NOT #1874's stop skip:
    // they are different keys and must stay different calls.
    expect(RouteStopCheckInPlan.isSkip({'key': 'skip', 'status': 'closed'}),
        isTrue);
    expect(RouteStopCheckInPlan.isSkip({'key': 'stop_skip'}), isFalse);
    expect(RouteStopCheckInPlan.isUnskip({'key': 'unskip'}), isTrue);
  });
}
