// CMD #2057 — the long-press menu on a route stop: Skip, Remove from route,
// Restore. One widget, one door, and every decision inside it is the
// backend's.
//
// What this file holds down:
//
//   • The route order is LOCKED. There is no drag, so no menu entry and no
//     helper may ever produce a reorder call again.
//   • A menu entry names the RPC that runs it. Dart maps no key to any
//     function name, so Remove and Restore are payload, not code — and a
//     fourth stop action is an INSERT, not a deploy.
//   • Restore acts on the stop the backend named, not on the row that was
//     long-pressed: the removed stop has no card of its own any more.
//   • An entry the backend disabled produces NO call. It is drawn greyed
//     with the backend's own reason; Dart never invents "you can't do that".
//   • Every label, every reason and every toast is verbatim payload.

import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/route_stop_checkin_sheet.dart';

/// The menu route_view() sends for an ordinary, un-checked-in stop while a
/// removal from the last five minutes can still be undone.
List<Map<String, dynamic>> menuFor(String stopId,
        {bool visited = false, String? undoStopId, String? undoLabel}) =>
    [
      {
        'key': 'stop_skip',
        'label': 'Skip this stop',
        'rpc': 'route_stop_skip',
        'stop_id': stopId,
        'enabled': true,
        'skipped': true,
        'tone': 'warning',
      },
      {
        'key': 'stop_remove',
        'label': 'Remove from route',
        'rpc': 'route_stop_remove',
        'stop_id': stopId,
        'enabled': !visited,
        if (visited)
          'reason': 'A stop that is already checked in cannot be removed.',
        'tone': 'danger',
      },
      if (undoStopId != null)
        {
          'key': 'stop_restore',
          'label': undoLabel ?? 'Restore Shah Medical to stop 3',
          'rpc': 'route_stop_restore',
          'stop_id': undoStopId,
          'enabled': true,
          'tone': 'brand',
        },
    ];

void main() {
  test('Remove from route rides BESIDE Skip, in payload order', () {
    final stop = {'stop_id': 's2', 'menu': menuFor('s2')};
    final entries = RouteStopCheckInPlan.menu(stop);

    expect(entries.map((e) => e['key']).toList(),
        ['stop_skip', 'stop_remove']);
    // The labels are the backend's words, not Dart's.
    expect(entries[1]['label'], 'Remove from route');
  });

  test('the ENTRY names the RPC — Dart maps no key to a function', () {
    final stop = {'stop_id': 's2', 'menu': menuFor('s2')};
    final entries = RouteStopCheckInPlan.menu(stop);

    expect(RouteStopCheckInPlan.menuCall('s2', entries[0]), {
      'rpc': 'route_stop_skip',
      'params': {'p_stop_id': 's2', 'p_skipped': true},
    });
    expect(RouteStopCheckInPlan.menuCall('s2', entries[1]), {
      'rpc': 'route_stop_remove',
      'params': {'p_stop_id': 's2'},
    });

    // An entry that names no rpc is not an instruction: the row does nothing
    // rather than guessing which call the backend meant.
    expect(
        RouteStopCheckInPlan.menuCall(
            's2', {'key': 'stop_remove', 'label': 'Remove from route'}),
        isNull);
  });

  test('Restore runs on the REMOVED stop, not the row under the thumb', () {
    // The removed stop has no card left, so its undo entry rides in every
    // other stop's menu carrying its own id.
    final stop = {
      'stop_id': 's2',
      'menu': menuFor('s2', undoStopId: 's9'),
    };
    final restore = RouteStopCheckInPlan.menu(stop)
        .firstWhere((e) => e['key'] == 'stop_restore');

    expect(RouteStopCheckInPlan.menuCall('s2', restore), {
      'rpc': 'route_stop_restore',
      'params': {'p_stop_id': 's9'},
    });
    // And its label — which names the stop and the seat it goes back to — is
    // printed verbatim; Dart never assembles that sentence.
    expect(restore['label'], 'Restore Shah Medical to stop 3');
  });

  test('no undoable removal means no Restore entry at all', () {
    // Past the backend's five-minute window route_view() simply stops
    // sending the entry. The client shows no expired button of its own.
    final entries =
        RouteStopCheckInPlan.menu({'stop_id': 's2', 'menu': menuFor('s2')});
    expect(entries.any((e) => e['key'] == 'stop_restore'), isFalse);
  });

  test('a disabled entry makes NO call and carries its own reason', () {
    final stop = {'stop_id': 's4', 'menu': menuFor('s4', visited: true)};
    final remove = RouteStopCheckInPlan.menu(stop)
        .firstWhere((e) => e['key'] == 'stop_remove');

    expect(RouteStopCheckInPlan.menuEnabled(remove), isFalse);
    expect(RouteStopCheckInPlan.menuCall('s4', remove), isNull);
    // Greyed, never hidden — and the explanation is the backend's sentence.
    expect(remove['reason'],
        'A stop that is already checked in cannot be removed.');

    // Skip on the same stop is still live: disabling one entry never
    // disables the menu.
    final skip = RouteStopCheckInPlan.menu(stop)
        .firstWhere((e) => e['key'] == 'stop_skip');
    expect(RouteStopCheckInPlan.menuCall('s4', skip), isNotNull);
  });

  test('no menu entry can ever produce a reorder', () {
    final stop = {
      'stop_id': 's2',
      'menu': menuFor('s2', undoStopId: 's9'),
    };
    for (final e in RouteStopCheckInPlan.menu(stop)) {
      final call = RouteStopCheckInPlan.menuCall('s2', e);
      expect(call?['rpc'], isNot('route_reorder'));
      expect((call?['params'] as Map?)?.containsKey('p_stop_ids') ?? false,
          isFalse);
    }
    // And the list itself is locked whatever the payload claims.
    expect(
        RouteStopCheckInPlan.canReorder(
            {'can_reorder': true, 'order_locked': true, 'stops': const []}),
        isFalse);
  });

  test('a removed stop is simply absent — the list never hides a row', () {
    // route_view() drops the removed stop from stops[] entirely, so the
    // client has no "removed" state to render and no gap to close: the
    // seq_label it prints is the backend's new number.
    final payload = {
      'can_reorder': false,
      'order_locked': true,
      'stops': [
        {'stop_id': 's1', 'seq_label': '1', 'skipped': false},
        {'stop_id': 's4', 'seq_label': '2', 'skipped': false},
        {'stop_id': 's5', 'seq_label': '3', 'skipped': false},
      ],
    };
    final active = RouteStopCheckInPlan.active(payload);
    expect(active.map((e) => e['stop_id']).toList(), ['s1', 's4', 's5']);
    expect(active.map((e) => e['seq_label']).toList(), ['1', '2', '3']);
  });
}
