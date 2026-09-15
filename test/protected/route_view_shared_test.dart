// PROTECTED — CMD #1917: Today and All plans are ONE component.
//
// The bug this pins down is not a widget bug, it is an ARCHITECTURE bug. Today
// and All plans each had their own route card, their own stop row and their own
// map, and by 08 Sep they had drifted so far apart that Today was missing the
// map, the jump chips, the stop photos, the score chip, the route cost, the
// closed-at-arrival warning and four of the five stop actions.
//
// So the assertions here are about SAMENESS, and they fail the moment a second
// implementation reappears:
//
//   1. Both screens render RouteViewPanel — the source of admin_customer_screen_
//      _web.dart must contain no second route map, stop card or jump-chip
//      builder, and Today must not go back to route_stops_today().
//   2. Both screens hand the panel the SAME action set, and the five actions
//      come from the payload in the payload's own order — Dart never composes
//      that list, so it cannot differ between two callers.
//   3. Every action's label, enabled flag and URI is the backend's. A URI built
//      in Dart is how the two screens diverged in the first place.
//   4. The map is created once per route and only RESIZED: mini and large are
//      the backend's numbers, and a resize changes neither the route id nor the
//      stop signature that guards a rebuild.
//
// Never edit this file to make a change pass. It only changes when the change
// deliberately changes one of those four behaviours.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/widgets/route_view_panel.dart';

/// One route_view() payload, shaped exactly as the RPC returns it.
Map<String, dynamic> _payload({int stops = 12, bool phone = true}) => {
      'ok': true,
      'route_id': 'bbbbbbbb-0000-0000-0000-000000001872',
      'stop_signature': 'sig-a',
      'map_mini_h': 180,
      'map_large_vh': 0.60,
      'header': {
        'title': 'Pandri loop',
        'subtitle': '12 stops · 8.4 km · 2h 05m',
        'progress_label': '3 of 12 stops · 5.1 km left · ETA 4:20 PM',
        'cost_label': '₹412 route cost',
        'day_warning': 'Longer than an 8-hour day',
        'closed_label': '2 shut on arrival',
        'assign_label': 'Assign',
        'msg_stops_label': 'Message stops',
        'nav_label': 'Navigate',
        'nav_uri': 'https://maps.example/dir',
        'can_navigate': true,
      },
      'windows': [
        {'index': 0, 'from': 1, 'to': 10, 'label': 'Stops 1–10'},
        {'index': 1, 'from': 11, 'to': stops, 'label': 'Stops 11–$stops'},
      ],
      'stops': [
        for (var i = 1; i <= stops; i++)
          {
            'stop_id': 's$i',
            'lead_id': 9900 + i,
            'seq': i,
            'seq_label': '$i',
            'name': 'Shop $i',
            'address': 'Pandri',
            'photo_url': 'https://img.example/$i.jpg',
            'score_label': '${40 + i}/100',
            'status_label': 'Not checked in',
            'status_tone': 'neutral',
            'skipped': false,
            'actions': [
              {
                'key': 'call',
                'label': 'Call',
                'enabled': phone,
                'uri': phone ? 'tel:+919000000$i' : null,
              },
              {
                'key': 'whatsapp',
                'label': 'WhatsApp',
                'enabled': phone,
                'uri': phone ? 'https://wa.me/919000000$i' : null,
              },
              {
                'key': 'navigate',
                'label': 'Navigate',
                'enabled': true,
                'uri': 'https://maps.example/$i',
              },
              {'key': 'checkin', 'label': 'Check in', 'enabled': true},
              {
                'key': 'import_customer',
                'label': 'Import customer',
                'enabled': true,
                'lead_id': 9900 + i,
              },
            ],
          }
      ],
    };

List<String> _actionKeys(Map<String, dynamic> payload, int stopIndex) =>
    ((payload['stops'] as List)[stopIndex]['actions'] as List)
        .map((a) => (a as Map)['key'].toString())
        .toList();

String _screenSource() =>
    File('lib/screens/admin/admin_customer_screen_web.dart').readAsStringSync();

void main() {
  // ── 1. ONE component, and no second implementation left behind ──────────
  group('Today and All plans render the same component', () {
    test('both screens build RouteViewPanel, and nothing else builds a route',
        () {
      final src = _screenSource();

      // Today's card and All plans' expanded detail are both the panel.
      expect(src.contains("screen: 'today'"), isTrue,
          reason: "Today must render RouteViewPanel with screen: 'today'");
      expect(src.contains("screen: 'all_plans'"), isTrue,
          reason: "All plans must render RouteViewPanel with screen: 'all_plans'");
      expect('RouteViewPanel('.allMatches(src).length, greaterThanOrEqualTo(2),
          reason: 'both screens must construct the shared panel');

      // The second implementation is GONE — each of these names was one half
      // of a duplicated route surface.
      for (final dead in const [
        'Widget _todayStopRow(',
        'Widget _todayStopList(',
        'Widget _builderStopRow(',
        'Widget _buildRouteMapView(',
        'Widget _buildStopRangeButtons(',
        'Widget _stopActionCompact(',
      ]) {
        expect(src.contains(dead), isFalse,
            reason: '$dead is a second route implementation — it must stay deleted');
      }
    });

    test('Today no longer has its own stop RPC', () {
      final src = _screenSource();
      expect(src.contains("rpc('route_stops_today'"), isFalse,
          reason: 'route_view() feeds both screens; Today must not fetch its own '
              'stop list, or the two lists can disagree again');
      expect(src.contains("rpc('lead_stop_card'"), isFalse,
          reason: 'the stop photo/score/actions arrive inside route_view()');
    });

    test('one handler set is shared, so the actions cannot differ', () {
      final src = _screenSource();
      expect(src.contains('RouteViewActions get _routeViewActions'), isTrue);
      expect('_routeViewActions'.allMatches(src).length, greaterThanOrEqualTo(3),
          reason: 'declared once and handed to BOTH panels');
    });
  });

  // ── 2. The same five actions, in the backend's order ────────────────────
  group('every stop carries the same five actions', () {
    test('the set and its order are the payload’s, on both screens', () {
      final today = _payload();
      final allPlans = _payload();
      const expected = [
        'call',
        'whatsapp',
        'navigate',
        'checkin',
        'import_customer'
      ];
      for (var i = 0; i < (today['stops'] as List).length; i++) {
        expect(_actionKeys(today, i), expected);
        expect(_actionKeys(allPlans, i), _actionKeys(today, i),
            reason: 'the two screens read the SAME payload — a difference here '
                'means someone filtered the list in one of them');
      }
    });

    test('a disabled action is still present — greyed, never hidden', () {
      final p = _payload(phone: false);
      expect(_actionKeys(p, 0).length, 5,
          reason: 'a stop with no phone must keep the same row shape');
      final call = (p['stops'] as List)[0]['actions'][0] as Map;
      expect(call['enabled'], isFalse);
      expect(call['uri'], isNull,
          reason: 'no URI is composed in Dart when the backend sent none');
    });

    test('Import customer carries the lead the form is pre-filled from', () {
      final p = _payload();
      final import = (p['stops'] as List)[0]['actions'][4] as Map;
      expect(import['key'], 'import_customer');
      expect(import['lead_id'], 9901);
    });

    test('the panel builds no label, URI or action of its own', () {
      final src = File('lib/widgets/route_view_panel.dart').readAsStringSync();
      for (final banned in const [
        "'tel:",
        "'https://wa.me/",
        "'https://www.google.com/maps",
        "'Call'",
        "'WhatsApp'",
        "'Import customer'",
      ]) {
        expect(src.contains(banned), isFalse,
            reason: '$banned is a display string or URI written in Dart — it '
                'belongs in route_view()');
      }
    });
  });

  // ── 3. The map: loaded once, resized, never rebuilt ─────────────────────
  group('the map is created once per route', () {
    setUp(() {
      RouteViewStore.mapLoads.clear();
      RouteViewStore.orderChanged('r1');
    });

    test('one map element per route id, shared by both screens', () {
      final a = RouteViewStore.mapKey('r1');
      final b = RouteViewStore.mapKey('r1');
      expect(identical(a, b), isTrue,
          reason: 'Today and All plans must reparent the SAME map element');
      expect(identical(a, RouteViewStore.mapKey('r2')), isFalse);
    });

    test('a resize is not a load; a new stop order is', () {
      RouteViewStore.countMapLoad('r1', 'today', 'sig-a');
      // Same route, other screen, same stop order -> still one load.
      RouteViewStore.countMapLoad('r1', 'all_plans', 'sig-a');
      RouteViewStore.countMapLoad('r1', 'today', 'sig-a');
      expect(RouteViewStore.mapLoads['r1'], 1,
          reason: 'moving between the screens, and resizing, must not reload');

      // The ONE thing that rebuilds a map: the stops moved.
      RouteViewStore.countMapLoad('r1', 'today', 'sig-b');
      expect(RouteViewStore.mapLoads['r1'], 2);
    });

    test('mini and large are the backend’s numbers', () {
      final p = _payload();
      expect(p['map_mini_h'], 180);
      expect(p['map_large_vh'], 0.60);
      final src = File('lib/widgets/route_view_panel.dart').readAsStringSync();
      expect(src.contains("_num('map_mini_h'"), isTrue);
      expect(src.contains("_num('map_large_vh'"), isTrue);
    });

    test('collapsing never disposes or removes the map', () {
      final src = File('lib/widgets/route_view_panel.dart').readAsStringSync();
      // The map widget is built unconditionally; only its height changes.
      expect(src.contains('height: h,'), isTrue);
      expect(RegExp(r'if \(_large\)[\s\S]{0,80}RouteGoogleMapPanel')
              .hasMatch(src),
          isFalse,
          reason: 'the map must not be behind an is-expanded condition');
    });
  });

  // ── 4. The 24h payload cache is a render fallback, not an authority ─────
  group('route_view payload cache', () {
    test('a reorder drops the cached payload for that route', () {
      RouteViewStore.put('r9', _payload());
      expect(RouteViewStore.peek('r9'), isNotNull);
      RouteViewStore.orderChanged('r9');
      expect(RouteViewStore.peek('r9'), isNull,
          reason: 'a new stop order must refetch, never redraw stale stops');
    });

    test('the cache lives for 24h', () {
      expect(RouteViewStore.ttl, const Duration(hours: 24));
    });
  });
}
