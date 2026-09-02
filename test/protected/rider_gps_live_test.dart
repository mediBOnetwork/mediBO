// PROTECTED — CHANGE #700 (register gap #124).
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes how a live rider position is read or plotted.
//
// What this holds down, on the pure decisions behind the live rider map:
//
//   1. THE APP PLOTS THE PAIR THE BACKEND CHOSE. map_lat/map_lng is the
//      road-snapped point where OSRM answered and the raw point where it did
//      not; the choice is made server-side so the customer sheet and the admin
//      sheet can never show a different dot. rider_lat/lng is the fallback for
//      an older payload, never a preference.
//
//   2. ABSENCE IS ABSENCE. No coordinates -> no point, never (0,0). A rider
//      dropped at null island is worse than a map with no rider on it.
//
//   3. THE BROADCAST ENVELOPE IS OPENED IN ONE PLACE. A database broadcast
//      arrives as {type, event, payload}; a bare map (an older shape, or a
//      direct call) is passed through untouched.
//
//   4. THE MARKER INTERPOLATES, IT DOES NOT INVENT. The tween is straight-line
//      between two backend points precisely because those points are already
//      road-snapped, and it never overshoots either end.
//
//   5. NOTHING ON THIS SCREEN IS WORDED OR THRESHOLDED IN DART. The staleness
//      block ("Live" / "Last seen 4 min ago" / "Rider offline") and the
//      "Showing raw GPS" note are carried verbatim from the payload, and the
//      channel is subscribed to ONLY when the backend said has_channel — the
//      public track page gets none, because it cannot pass the private
//      channel's RLS check.
//
// No network, no Supabase, no goldens.

import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/delivery/delivery_tracking_view.dart';
import 'package:pharma_b2b/screens/delivery/run_live_map.dart';

void main() {
  group('RiderPoint.from — the app plots what the backend chose', () {
    test('prefers map_lat/map_lng over the raw pair', () {
      final p = RiderPoint.from(<String, dynamic>{
        'map_lat': 21.251442,
        'map_lng': 81.629656,
        'lat': 21.2514,
        'lng': 81.6296,
        'snapped': true,
      });
      expect(p, isNotNull);
      // The SNAPPED pair, not the raw one it was snapped from.
      expect(p!.lat, 21.251442);
      expect(p.lng, 81.629656);
      expect(p.snapped, isTrue);
    });

    test('falls back to rider_lat/rider_lng when the map pair is absent', () {
      final p = RiderPoint.from(<String, dynamic>{
        'rider_lat': 21.30,
        'rider_lng': 81.70,
      });
      expect(p!.lat, 21.30);
      expect(p.lng, 81.70);
      // No flag in the payload means not snapped — never assumed either way.
      expect(p.snapped, isFalse);
    });

    test('rider_snapped is honoured as well as snapped', () {
      final p = RiderPoint.from(<String, dynamic>{
        'map_lat': 1.0,
        'map_lng': 2.0,
        'rider_snapped': true,
      });
      expect(p!.snapped, isTrue);
    });

    test('no coordinates -> null, NEVER (0,0)', () {
      expect(RiderPoint.from(const <String, dynamic>{}), isNull);
      expect(
        RiderPoint.from(<String, dynamic>{'map_lat': 21.0}),
        isNull,
        reason: 'half a coordinate is not a position',
      );
      expect(
        RiderPoint.from(<String, dynamic>{'map_lat': null, 'map_lng': null}),
        isNull,
      );
    });
  });

  group('RunLiveFrame.unwrap — the broadcast envelope', () {
    test('opens a database broadcast envelope', () {
      final out = RunLiveFrame.unwrap(<String, dynamic>{
        'type': 'broadcast',
        'event': 'rider',
        'payload': <String, dynamic>{'map_lat': 21.1, 'map_lng': 81.1},
      });
      expect(out['map_lat'], 21.1);
      expect(out.containsKey('event'), isFalse);
    });

    test('passes an unwrapped map through untouched', () {
      final bare = <String, dynamic>{'map_lat': 5.0, 'map_lng': 6.0};
      expect(RunLiveFrame.unwrap(bare)['map_lat'], 5.0);
    });
  });

  group('RiderPoint.lerp — the marker moves, it does not invent', () {
    const a = RiderPoint(20.0, 80.0, true);
    const b = RiderPoint(22.0, 82.0, false);

    test('midpoint is exactly halfway between the two backend points', () {
      final m = RiderPoint.lerp(a, b, 0.5);
      expect(m.lat, closeTo(21.0, 1e-9));
      expect(m.lng, closeTo(81.0, 1e-9));
    });

    test('never overshoots either end', () {
      expect(RiderPoint.lerp(a, b, 0.0).lat, a.lat);
      expect(RiderPoint.lerp(a, b, 1.0).lat, b.lat);
      expect(RiderPoint.lerp(a, b, 1.5).lat, b.lat);
      expect(RiderPoint.lerp(a, b, -1.0).lat, a.lat);
    });

    test('carries the DESTINATION snapped flag, so the note matches the dot', () {
      expect(RiderPoint.lerp(a, b, 0.5).snapped, isFalse);
    });

    test('a first point with nothing to come from lands on itself', () {
      expect(RiderPoint.lerp(null, b, 0.3).lat, b.lat);
    });
  });

  group('DeliveryTrackingData.fromCustomer — verbatim, and only when told', () {
    Map<String, dynamic> base() => <String, dynamic>{
          'ok': true,
          'tracking': true,
          'status_label': 'Out for delivery',
          'partner_name': 'R Kumar',
          'rider_lat': 21.2514,
          'rider_lng': 81.6296,
          'map_lat': 21.251442,
          'map_lng': 81.629656,
          'rider_snapped': true,
          'destination_lat': 21.30,
          'destination_lng': 81.70,
          'animate_ms': 900,
          'note': '',
          'has_channel': true,
          'channel': 'run:11111111-2222-4333-8444-555555550700',
          'live': <String, dynamic>{
            'has': true,
            'is_live': true,
            'state': 'live',
            'label': 'Live',
            'tone': 'success',
            'age_s': 3,
          },
        };

    test('the channel is taken ONLY when the backend said has_channel', () {
      expect(DeliveryTrackingData.fromCustomer(base()).channel,
          'run:11111111-2222-4333-8444-555555550700');

      final off = base()..['has_channel'] = false;
      expect(
        DeliveryTrackingData.fromCustomer(off).channel,
        '',
        reason: 'a channel string present without has_channel is not a licence '
            'to subscribe — the backend decides who may listen',
      );
    });

    test('the staleness block is carried verbatim, never recomputed', () {
      final stale = base()
        ..['live'] = <String, dynamic>{
          'has': true,
          'is_live': false,
          'state': 'stale',
          'label': 'Last seen 4 min ago',
          'tone': 'warning',
          'age_s': 267,
        };
      final d = DeliveryTrackingData.fromCustomer(stale);
      // The sentence AND its tone are the payload's. 267 seconds is not turned
      // into "4 min" here, and "warning" is not derived from the number.
      expect(d.live['label'], 'Last seen 4 min ago');
      expect(d.live['tone'], 'warning');
      expect(d.live['age_s'], 267);
    });

    test('the offline sentence is printed, not inferred from age', () {
      final off = base()
        ..['live'] = <String, dynamic>{
          'has': true,
          'is_live': false,
          'state': 'offline',
          'label': 'Rider offline',
          'tone': 'danger',
          'age_s': 900,
        };
      expect(DeliveryTrackingData.fromCustomer(off).live['label'],
          'Rider offline');
    });

    test('the unsnapped note is a backend string, printed as sent', () {
      final raw = base()
        ..['rider_snapped'] = false
        ..['map_lat'] = 21.2514
        ..['map_lng'] = 81.6296
        ..['note'] = 'Showing raw GPS';
      final d = DeliveryTrackingData.fromCustomer(raw);
      expect(d.note, 'Showing raw GPS');
      expect(d.riderSnapped, isFalse);
      // …and the pair plotted is still the backend's map pair.
      expect(d.mapLat, 21.2514);
    });

    test('animate_ms is the payload\'s duration', () {
      expect(DeliveryTrackingData.fromCustomer(base()).animateMs, 900);
    });

    test('map pair falls back to the rider pair on an older payload', () {
      final old = base()
        ..remove('map_lat')
        ..remove('map_lng');
      final d = DeliveryTrackingData.fromCustomer(old);
      expect(d.mapLat, 21.2514);
      expect(d.mapLng, 81.6296);
    });
  });

  group('DeliveryTrackingData.fromPublic — no identity, no private channel', () {
    test('the public track page is never handed a channel to subscribe to', () {
      final d = DeliveryTrackingData.fromPublic(<String, dynamic>{
        'ok': true,
        'found': true,
        'tracking': true,
        'status_label': 'Out for delivery',
        'has_rider_location': true,
        'rider_lat': 21.2514,
        'rider_lng': 81.6296,
        'has_destination': true,
        'destination_lat': 21.30,
        'destination_lng': 81.70,
        // even if a channel were somehow present in this payload:
        'channel': 'run:11111111-2222-4333-8444-555555550700',
      });
      expect(
        d.channel,
        '',
        reason: 'an unauthenticated viewer cannot pass the private channel RLS '
            'check, so that page keeps its refetch instead of opening a socket '
            'that would be refused',
      );
      expect(d.hasRiderLocation, isTrue);
    });
  });
}
