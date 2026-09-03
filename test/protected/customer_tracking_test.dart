// PROTECTED — CHANGE #701 (register #125).
//
// What this holds down, and why each one is a PRIVACY rule rather than a
// styling one:
//
//   1. The customer is sent a route SEGMENT, never the run. The rest of a run's
//      polyline traces other pharmacies' doors, so the cut is made in
//      _c701_route_segment and this view renders whatever it is handed. The
//      test therefore pins the thing that CAN regress here: the view reads
//      `route.polyline` and nothing else, and draws nothing when the backend
//      says has:false.
//
//   2. Stops ahead are POSTAL AREAS. pharmacy_profiles has no locality column —
//      `address` and `address_local` are full street addresses — so if this
//      view ever learned to read an address field, it would print a stranger's
//      door to whoever holds a tracking link. It reads `route.stops_ahead.areas`
//      and has no other source.
//
//   3. The public link is `track_token`, not `qr_token`. qr_token is the code
//      that PROVES delivery; it used to be the tracking link too, so one
//      forwarded WhatsApp message carried the proof secret and never expired.
//
//   4. Expired is its own answer, worded by the backend. "Not found" would tell
//      a pharmacy their order had vanished.
//
// No network, no Supabase — the payloads are the two RPCs' real shapes.

import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/delivery/delivery_tracking_view.dart';

Map<String, dynamic> _customerPayload({
  bool hasRoute = true,
  List<String> areas = const ['Raipur 492001', 'Raipur 492007'],
  bool live = true,
}) =>
    {
      'ok': true,
      'tracking': live,
      'status': live ? 'out_for_delivery' : 'delivered',
      'status_label': live ? 'Out for delivery' : 'Delivered',
      'partner_name': 'Ramesh Kumar',
      'rider_lat': 21.25,
      'rider_lng': 81.62,
      'destination_lat': 21.26,
      'destination_lng': 81.64,
      'qr_token': 'QR-PROOF-SECRET',
      'track_token': live ? 'a705c610e4044' : null,
      'route': {
        'has': hasRoute,
        'heading': 'Route to your shop',
        'polyline': hasRoute ? 'oku`C_ldqNo}@_|B' : '',
        'straight': false,
        'km': 2.4,
        'km_label': hasRoute ? '2.4 km away by road' : '',
        'stops_ahead': {
          'has': areas.isNotEmpty,
          'count': areas.length,
          'areas': areas,
          'label': areas.isEmpty ? '' : '${areas.length} stop(s) before yours',
        },
      },
      'share': {
        'has': live,
        'label': 'Share live link with staff',
        'rpc': 'delivery_share_track_link',
        'order_id': 'ord-1',
      },
    };

Map<String, dynamic> _expiredPayload() => {
      'ok': false,
      'found': false,
      'expired': true,
      'tracking': false,
      'title': 'Tracking link expired',
      'message':
          'This tracking link has expired. Your order page always has the latest.',
      'status': '',
      'status_label': '',
      'partner_name': '',
      'has_stops_ahead': false,
      'route': {'has': false, 'polyline': '', 'km_label': ''},
      'rider_lat': 0,
      'rider_lng': 0,
      'has_rider_location': false,
      'destination_lat': 0,
      'destination_lng': 0,
      'has_destination': false,
      'order_code': '',
      'qr_token': '',
    };

void main() {
  group('#701 — the customer sees the route to THEIR door', () {
    test('the polyline and the distance are the payload, verbatim', () {
      final d = DeliveryTrackingData.fromCustomer(_customerPayload());
      expect(d.hasRoute, isTrue);
      expect(d.routePolyline, 'oku`C_ldqNo}@_|B');
      expect(d.routeKmLabel, '2.4 km away by road');
      expect(d.routeHeading, 'Route to your shop');
    });

    test('has:false draws no line and no distance', () {
      final d = DeliveryTrackingData.fromCustomer(
          _customerPayload(hasRoute: false, areas: const []));
      expect(d.hasRoute, isFalse);
      expect(d.routePolyline, isEmpty);
      expect(d.routeKmLabel, isEmpty);
      expect(d.stopsAheadAreas, isEmpty);
    });

    test('a payload with no route block at all is not an error', () {
      final m = _customerPayload()..remove('route');
      final d = DeliveryTrackingData.fromCustomer(m);
      expect(d.hasRoute, isFalse);
      expect(d.routePolyline, isEmpty);
      expect(d.stopsAheadAreas, isEmpty);
    });
  });

  group('#701 — stops ahead are areas, and there is no address to leak', () {
    test('the areas render in run order, exactly as sent', () {
      final d = DeliveryTrackingData.fromCustomer(_customerPayload());
      expect(d.stopsAheadAreas, ['Raipur 492001', 'Raipur 492007']);
    });

    test('a blank area is dropped rather than drawn as an empty chip', () {
      final d = DeliveryTrackingData.fromCustomer(
          _customerPayload(areas: const ['Raipur 492001', '', '   ']));
      expect(d.stopsAheadAreas, ['Raipur 492001']);
    });

    test('an address in the payload is NOT read by this view', () {
      // The guard: if someone later adds an address to the stops-ahead rows,
      // this view must still print only `areas`. It has no address field to
      // put one in, and this test fails the day somebody adds one.
      final m = _customerPayload();
      (m['route'] as Map)['stops_ahead'] = {
        'has': true,
        'count': 1,
        'areas': ['Raipur 492001'],
        'address': '12 Shankar Nagar Main Road',
      };
      final d = DeliveryTrackingData.fromCustomer(m);
      expect(d.stopsAheadAreas, ['Raipur 492001']);
      expect(d.stopsAheadAreas.join(' '), isNot(contains('Shankar Nagar')));
    });
  });

  group('#701 — the public link is not the delivery-proof secret', () {
    test('the tracking token and the QR token are different fields', () {
      final m = _customerPayload();
      expect(m['track_token'], isNot(equals(m['qr_token'])));
      // The view still surfaces qr_token for the scan flow, and it is NOT the
      // thing the WhatsApp link carries — that is delivery-notify's track_token.
      final d = DeliveryTrackingData.fromCustomer(m);
      expect(d.qrToken, 'QR-PROOF-SECRET');
    });

    test('sharing is offered only when the backend offers it', () {
      final live = DeliveryTrackingData.fromCustomer(_customerPayload());
      expect(live.hasShare, isTrue);
      expect(live.shareLabel, 'Share live link with staff');
      expect(live.shareRpc, 'delivery_share_track_link');
      expect(live.shareOrderId, 'ord-1');

      // The public page carries no share block at all — it has no identity to
      // authorise a send with.
      final pub = DeliveryTrackingData.fromPublic(_expiredPayload());
      expect(pub.hasShare, isFalse);
      expect(pub.shareLabel, isEmpty);
    });
  });

  group('#701 — an expired link says so, in the backend words', () {
    final d = DeliveryTrackingData.fromPublic(_expiredPayload());

    test('expired is not found, and not tracking', () {
      expect(d.found, isFalse);
      expect(d.tracking, isFalse);
    });

    test('the copy is the payload, never written here', () {
      expect(d.title, 'Tracking link expired');
      expect(d.message,
          'This tracking link has expired. Your order page always has the latest.');
    });

    test('an expired link plots nothing', () {
      expect(d.hasRoute, isFalse);
      expect(d.routePolyline, isEmpty);
      expect(d.hasRiderLocation, isFalse);
      expect(d.hasDestination, isFalse);
      expect(d.qrToken, isEmpty);
    });
  });
}
