// PROTECTED — the route stop check-in contract (CMD #1873).
//
// What this holds down, on the ONE class every check-in surface calls:
//   • the four outcomes render in the BACKEND's order, verbatim — no client
//     sort, no Dart-side label;
//   • a stop already checked in re-opens on its stored outcome AND its stored
//     note, both editable;
//   • no outcome picked = NO RPC (the sheet shows the backend's pick_label)
//     — it never defaults to "visited";
//   • the note is trimmed and OMITTED when empty rather than sent as '';
//   • the photo goes to the bucket the SHEET named, and the params carry a
//     PATH — the public URL is assembled server-side;
//   • one-tap Skip posts the status the ACTION carried, so what skipping a
//     stop writes is a payload change and never a deploy — an action with no
//     status writes nothing at all.
//
// Pure Dart VM: no network, no Supabase, no camera. Payloads are the real
// shapes of route_stop_sheet() / route_stops_today().

import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/route_stop_checkin_sheet.dart';

/// A real route_stop_sheet() payload, deliberately NOT in alphabetical order.
Map<String, dynamic> _sheet({String? selected, String note = ''}) => {
      'ok': true,
      'can_check_in': true,
      'stop_id': 'dc84caf0-3fa5-4233-bb2e-fb88be012bba',
      'title': 'Check in',
      'subtitle': 'Stop 1 · Sharma Medical Store',
      'options': [
        {'key': 'visited', 'label': 'Visited', 'tone': 'success', 'hint': 'Met the shop.'},
        {'key': 'closed', 'label': 'Closed', 'tone': 'warning', 'hint': 'Shutter down.'},
        {
          'key': 'not_interested',
          'label': 'Not interested',
          'tone': 'danger',
          'hint': 'Parked for 30 days.'
        },
        {'key': 'converted', 'label': 'Converted', 'tone': 'brand', 'hint': 'Now a customer.'},
      ],
      'selected': selected,
      'note': {'label': 'Note', 'hint': 'What happened?', 'value': note},
      'photo': {'label': 'Photo proof', 'bucket': 'lead-photos', 'take_label': 'Take photo'},
      'submit_label': 'Save check-in',
      'pick_label': 'Pick an outcome first.',
    };

void main() {
  const stopId = 'dc84caf0-3fa5-4233-bb2e-fb88be012bba';

  test('the four outcomes render in payload order, labels verbatim', () {
    final opts = RouteStopCheckInPlan.options(_sheet());
    expect(opts.map((o) => o['key']).toList(),
        ['visited', 'closed', 'not_interested', 'converted']);
    expect(opts.map((o) => o['label']).toList(),
        ['Visited', 'Closed', 'Not interested', 'Converted']);
    expect(opts.map((o) => o['tone']).toList(),
        ['success', 'warning', 'danger', 'brand']);
    // The hint is the backend's sentence, including the revisit window it
    // computed — Dart must never restate "30 days" of its own.
    expect(opts[2]['hint'], 'Parked for 30 days.');
  });

  test('an unchecked stop opens unselected; a checked one opens on its own '
      'outcome and note', () {
    expect(RouteStopCheckInPlan.initialStatus(_sheet()), isNull);
    expect(RouteStopCheckInPlan.initialNote(_sheet()), '');

    final again = _sheet(selected: 'converted', note: 'Signed up on the spot');
    expect(RouteStopCheckInPlan.initialStatus(again), 'converted');
    expect(RouteStopCheckInPlan.initialNote(again), 'Signed up on the spot');
  });

  test('no outcome picked = no RPC — it never defaults to visited', () {
    expect(
        RouteStopCheckInPlan.submitParams(stopId: stopId, status: null), isNull);
    expect(RouteStopCheckInPlan.submitParams(stopId: stopId, status: ''), isNull);
  });

  test('submit carries the status and trims the note; an empty note is '
      'omitted, never sent as an empty string', () {
    final bare =
        RouteStopCheckInPlan.submitParams(stopId: stopId, status: 'visited')!;
    expect(bare, {'p_stop_id': stopId, 'p_status': 'visited'});
    expect(bare.containsKey('p_note'), isFalse);
    expect(bare.containsKey('p_photo'), isFalse);

    final blank = RouteStopCheckInPlan.submitParams(
        stopId: stopId, status: 'closed', note: '   ')!;
    expect(blank.containsKey('p_note'), isFalse);

    final full = RouteStopCheckInPlan.submitParams(
        stopId: stopId,
        status: 'not_interested',
        note: '  Buys from Agarwal  ',
        photoPath: '$stopId/1757_42.jpg')!;
    expect(full['p_note'], 'Buys from Agarwal');
    // A PATH, not a URL: route_stop_checkin prefixes the storage base itself.
    expect(full['p_photo'], '$stopId/1757_42.jpg');
    expect(full['p_photo'].toString().startsWith('http'), isFalse);
  });

  test('the photo bucket is the one the sheet named', () {
    expect(RouteStopCheckInPlan.bucket(_sheet()), 'lead-photos');
    // Absent photo block: no bucket invented in Dart.
    expect(RouteStopCheckInPlan.bucket(const {}), '');
  });

  test('Skip posts the status the ACTION carried, and an action without one '
      'writes nothing', () {
    const skip = {'key': 'skip', 'label': 'Skip', 'status': 'closed', 'tone': 'warning'};
    const checkin = {'key': 'checkin', 'label': 'Check in', 'tone': 'brand'};

    expect(RouteStopCheckInPlan.isSkip(skip), isTrue);
    expect(RouteStopCheckInPlan.isSkip(checkin), isFalse);

    expect(RouteStopCheckInPlan.skipParams(stopId, skip),
        {'p_stop_id': stopId, 'p_status': 'closed'});
    // The day the backend renames the skip outcome, Flutter follows with no
    // deploy; the day it sends no status, Flutter writes nothing.
    expect(
        RouteStopCheckInPlan.skipParams(
            stopId, const {'key': 'skip', 'status': 'permanently_closed'}),
        {'p_stop_id': stopId, 'p_status': 'permanently_closed'});
    expect(RouteStopCheckInPlan.skipParams(stopId, checkin), isNull);
  });

  test('a stop row with no actions offers nothing — the list is the '
      "backend's, not a Dart default", () {
    expect(RouteStopCheckInPlan.options(const {}), isEmpty);
    expect(RouteStopCheckInPlan.options(const {'options': null}), isEmpty);
  });
}
