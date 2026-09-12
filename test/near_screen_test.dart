// CMD #426 — the consumer surface's contract.
//
// One rule under all of these: the page may never make availability look MORE
// certain than the backend said. That is not a style preference — the whole
// product is "we will tell you how sure we are", so a widget that hardened a
// 'Possibly' into a green tick, or invented "0 results" where the backend sent
// a sentence, would be the actual failure mode.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/public/near_screen.dart';
import 'package:pharma_b2b/screens/pharmacy/near_listing_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _boot({bool enabled = true}) => {
      'ok': true,
      'enabled': enabled,
      'min_query_chars': 3,
      'copy': {
        'title': 'Find a medicine near you',
        'subtitle': 'Availability at nearby pharmacies.',
        'search_hint': 'Type a medicine name',
        'search_button': 'Search',
        'locate_button': 'Use my location',
        'locating': 'Finding you…',
        'pincode_hint': 'Or enter your pincode',
        'pincode_button': 'Use pincode',
        'need_origin': 'Share your location or enter a pincode.',
        'short_query': 'Type at least 3 letters.',
        'empty': 'Search a medicine to see nearby pharmacies.',
        'no_results': 'No nearby pharmacy is likely to have this right now.',
        'no_results_hint': 'Try the salt name, or a wider pincode.',
        'call_button': 'Call',
        'directions_button': 'Directions',
        'disclaimer': 'mediBO does not hold this stock. Always call first.',
        'rx_note': 'Prescription medicines are dispensed at their discretion.',
        'disabled': 'Nearby search is not available right now.',
      },
    };

Map<String, dynamic> _card({
  required String name,
  required String tierLabel,
  required String tierTone,
  bool phone = true,
}) => {
      'ref': 'tok_$name',
      'name': name,
      'matched_label': 'DOLO 650MG TABLET',
      'area_label': 'Raipur',
      'distance_label': '2.0 km away',
      'tier': {'key': 'x', 'tone': tierTone, 'label': tierLabel},
      'call': {'has': phone, 'label': 'Call', 'tel': phone ? '9426000001' : null},
      'directions': {
        'has': true,
        'label': 'Directions',
        'url': 'https://www.google.com/maps/dir/?api=1&destination=21.2,81.6',
      },
    };

Map<String, dynamic> _results(List<Map<String, dynamic>> rows) => {
      'ok': true,
      'query': 'dolo',
      'count': rows.length,
      'count_label': '${rows.length} pharmacies nearby',
      'empty_label': 'No nearby pharmacy is likely to have this right now.',
      'empty_hint': 'Try the salt name, or a wider pincode.',
      'disclaimer': 'mediBO does not hold this stock. Always call first.',
      'rx_note': 'Prescription medicines are dispensed at their discretion.',
      'rows': rows,
    };

/// A stub that records what the screen ASKED for, which is half the contract:
/// an absent origin must be an ABSENT parameter, never a zero.
class _Rpc {
  final Map<String, Map<String, dynamic>> answers;
  final List<MapEntry<String, Map<String, dynamic>>> calls = [];
  _Rpc(this.answers);

  Future<Map<String, dynamic>> call(String fn, Map<String, dynamic> p) async {
    calls.add(MapEntry(fn, p));
    return answers[fn] ?? const {'ok': false, 'message': 'no stub'};
  }
}

/// A tall surface. These screens are lists, and the default 800x600 test
/// viewport lazily builds only the first card or two — which would make an
/// assertion about the THIRD pharmacy's sentence pass or fail on geometry
/// rather than on what the widget printed.
Future<void> _pump(WidgetTester t, Widget child) async {
  t.view.physicalSize = const Size(1200, 3000);
  t.view.devicePixelRatio = 1.0;
  addTearDown(() {
    t.view.resetPhysicalSize();
    t.view.resetDevicePixelRatio();
  });
  await t.pumpWidget(MaterialApp(home: child));
  await t.pumpAndSettle();
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('near — the consumer page', () {
    testWidgets('the page is the backend\'s words, top to bottom',
        (t) async {
      final rpc = _Rpc({'near_boot': _boot()});
      await _pump(t, NearScreen(rpc: rpc.call));

      expect(find.text('Find a medicine near you'), findsOneWidget);
      expect(find.text('Availability at nearby pharmacies.'), findsOneWidget);
      expect(find.text('Search'), findsOneWidget);
      expect(find.text('Use my location'), findsOneWidget);
      // The pre-search state is the backend's own invitation, not "no results".
      expect(find.text('Search a medicine to see nearby pharmacies.'),
          findsOneWidget);
      expect(find.textContaining('No nearby pharmacy'), findsNothing);
    });

    testWidgets('the tier SENTENCE is printed verbatim and is never upgraded',
        (t) async {
      final rpc = _Rpc({
        'near_boot': _boot(),
        'near_search': _results([
          _card(
            name: 'Sharma Medical',
            tierLabel: 'Likely available — call to confirm',
            tierTone: 'success',
          ),
          _card(
            name: 'Verma Chemist',
            tierLabel: 'Possibly available — call to confirm',
            tierTone: 'warning',
          ),
          _card(
            name: 'Gupta Pharmacy',
            tierLabel: 'Ask the pharmacy',
            tierTone: 'info',
          ),
        ]),
      });
      await _pump(t, NearScreen(rpc: rpc.call));
      await t.enterText(find.byType(TextField).first, 'dolo');
      await t.tap(find.text('Search'));
      await t.pumpAndSettle();

      expect(find.text('Likely available — call to confirm'), findsOneWidget);
      expect(find.text('Possibly available — call to confirm'), findsOneWidget);
      expect(find.text('Ask the pharmacy'), findsOneWidget);
      // Three different sentences, three different pharmacies: nothing was
      // collapsed into one word like "Available".
      expect(find.text('Available'), findsNothing);
      expect(find.text('In stock'), findsNothing);
    });

    testWidgets('rows render in payload order — no client sort', (t) async {
      final rpc = _Rpc({
        'near_boot': _boot(),
        'near_search': _results([
          _card(name: 'Zed Medical', tierLabel: 'Likely', tierTone: 'success'),
          _card(name: 'Alpha Chemist', tierLabel: 'Possibly', tierTone: 'warning'),
        ]),
      });
      await _pump(t, NearScreen(rpc: rpc.call));
      await t.enterText(find.byType(TextField).first, 'dolo');
      await t.tap(find.text('Search'));
      await t.pumpAndSettle();

      final zed = t.getTopLeft(find.text('Zed Medical')).dy;
      final alpha = t.getTopLeft(find.text('Alpha Chemist')).dy;
      expect(zed, lessThan(alpha),
          reason: 'the backend ranked by confidence x distance, not the alphabet');
    });

    testWidgets('the disclaimer ships with every result set', (t) async {
      final rpc = _Rpc({
        'near_boot': _boot(),
        'near_search': _results([
          _card(name: 'Sharma Medical', tierLabel: 'Likely', tierTone: 'success'),
        ]),
      });
      await _pump(t, NearScreen(rpc: rpc.call));
      await t.enterText(find.byType(TextField).first, 'dolo');
      await t.tap(find.text('Search'));
      await t.pumpAndSettle();

      expect(find.text('mediBO does not hold this stock. Always call first.'),
          findsOneWidget);
      expect(
          find.text(
              'Prescription medicines are dispensed at their discretion.'),
          findsOneWidget);
    });

    testWidgets('a refusal is the backend message — there is no Dart fallback',
        (t) async {
      final rpc = _Rpc({
        'near_boot': _boot(),
        'near_search': {
          'ok': false,
          'error': 'rate_limited',
          'tone': 'warning',
          'retry_after_s': 900,
          'message': 'Too many searches from this device.',
        },
      });
      await _pump(t, NearScreen(rpc: rpc.call));
      await t.enterText(find.byType(TextField).first, 'dolo');
      await t.tap(find.text('Search'));
      await t.pumpAndSettle();

      expect(find.text('Too many searches from this device.'), findsOneWidget);
      // The machine slug never reaches a human.
      expect(find.textContaining('rate_limited'), findsNothing);
    });

    testWidgets('an empty result is the backend sentence, never "0 results"',
        (t) async {
      final rpc = _Rpc({
        'near_boot': _boot(),
        'near_search': _results(const []),
      });
      await _pump(t, NearScreen(rpc: rpc.call));
      await t.enterText(find.byType(TextField).first, 'dolo');
      await t.tap(find.text('Search'));
      await t.pumpAndSettle();

      expect(find.text('No nearby pharmacy is likely to have this right now.'),
          findsOneWidget);
      expect(find.text('Try the salt name, or a wider pincode.'), findsOneWidget);
      expect(find.text('0'), findsNothing);
    });

    testWidgets('no origin is an ABSENT parameter, never a zero coordinate',
        (t) async {
      final rpc = _Rpc({
        'near_boot': _boot(),
        'near_search': _results(const []),
      });
      await _pump(t, NearScreen(rpc: rpc.call));
      await t.enterText(find.byType(TextField).first, 'dolo');
      await t.tap(find.text('Search'));
      await t.pumpAndSettle();

      final sent = rpc.calls.lastWhere((c) => c.key == 'near_search').value;
      expect(sent.containsKey('p_lat'), isFalse);
      expect(sent.containsKey('p_lng'), isFalse);
      expect(sent.containsKey('p_pincode'), isFalse);
      expect(sent['p_q'], 'dolo');
    });

    testWidgets('a typed pincode is sent; an untouched one is omitted',
        (t) async {
      final rpc = _Rpc({
        'near_boot': _boot(),
        'near_search': _results(const []),
      });
      await _pump(t, NearScreen(rpc: rpc.call));
      await t.enterText(find.byType(TextField).first, 'dolo');
      await t.enterText(find.byType(TextField).last, '492001');
      await t.tap(find.text('Search'));
      await t.pumpAndSettle();

      final sent = rpc.calls.lastWhere((c) => c.key == 'near_search').value;
      expect(sent['p_pincode'], '492001');
    });

    testWidgets('a pharmacy that withheld its number gets no call button',
        (t) async {
      final rpc = _Rpc({
        'near_boot': _boot(),
        'near_search': _results([
          _card(
            name: 'Quiet Chemist',
            tierLabel: 'Likely',
            tierTone: 'success',
            phone: false,
          ),
        ]),
      });
      await _pump(t, NearScreen(rpc: rpc.call));
      await t.enterText(find.byType(TextField).first, 'dolo');
      await t.tap(find.text('Search'));
      await t.pumpAndSettle();

      expect(find.text('Quiet Chemist'), findsOneWidget);
      expect(find.text('Directions'), findsOneWidget);
      expect(find.text('Call'), findsNothing);
    });

    testWidgets('the kill switch renders the backend copy and nothing else',
        (t) async {
      final rpc = _Rpc({'near_boot': _boot(enabled: false)});
      await _pump(t, NearScreen(rpc: rpc.call));

      expect(find.text('Nearby search is not available right now.'),
          findsOneWidget);
      expect(find.byType(TextField), findsNothing);
    });
  });

  group('near — the QR landing page', () {
    testWidgets('one pharmacy, its badge, and no trade data', (t) async {
      final rpc = _Rpc({
        'near_pharmacy': {
          'ok': true,
          'name': 'Sharma Medical',
          'badge': 'Listed on mediBO Near',
          'area_label': 'Raipur',
          'search_hint': 'Type a medicine name',
          'disclaimer': 'mediBO does not hold this stock.',
          'call': {'has': true, 'label': 'Call', 'tel': '9426000001'},
          'directions': {'has': true, 'label': 'Directions', 'url': 'https://x'},
        },
      });
      await _pump(t, NearPharmacyScreen(token: 'tok', rpc: rpc.call));

      expect(find.text('Sharma Medical'), findsOneWidget);
      expect(find.text('Listed on mediBO Near'), findsOneWidget);
      expect(find.text('Call'), findsOneWidget);
      expect(find.text('mediBO does not hold this stock.'), findsOneWidget);
    });

    testWidgets('an unknown token is the backend empty state, not a throw',
        (t) async {
      final rpc = _Rpc({
        'near_pharmacy': {
          'ok': false,
          'error': 'not_found',
          'tone': 'info',
          'message': 'This pharmacy is not listed.',
        },
      });
      await _pump(t, NearPharmacyScreen(token: 'nope', rpc: rpc.call));

      expect(find.text('This pharmacy is not listed.'), findsOneWidget);
    });
  });

  group('near — the pharmacy\'s own control', () {
    Map<String, dynamic> own({bool listed = false, bool hidden = false}) => {
          'ok': true,
          'title': 'Nearby listing',
          'opt_in_label': 'List this pharmacy on mediBO Near',
          'opt_in_note':
              'Consumers see your name, distance and phone — never your '
              'quantities, purchase prices, suppliers or bills.',
          'phone_label': 'Show my phone number',
          'is_listed': listed,
          'show_phone': true,
          'state_label': listed ? 'You are listed.' : 'You are not listed.',
          'state_tone': listed ? 'success' : 'info',
          'public_url': listed ? 'https://medibo.in/near/p/tok' : null,
          'items_title': 'Likely available right now',
          'items_empty': 'Nothing is listed yet.',
          'items': [
            {
              'medicine_id': 42,
              'name': 'DOLO 650MG TABLET',
              'tier': {'tone': 'success', 'label': 'Likely available'},
              'hidden': hidden,
              'hidden_label': hidden ? 'Hidden until 02 Sep, 10:00 AM' : null,
              'mark_label': 'Mark unavailable',
              'undo_label': 'Show again',
            },
          ],
          'poster': {
            'title': 'Counter poster',
            'note': 'A printable poster with your name and a QR code.',
            'status': 'none',
            'button': 'Get poster',
            'can_request': true,
            'ready': false,
            'poll_ms': 3000,
          },
        };

    testWidgets('opt-in is off until the owner turns it on', (t) async {
      final rpc = _Rpc({'near_listing_get': own()});
      await _pump(t, NearListingScreen(rpc: rpc.call));

      expect(find.text('You are not listed.'), findsOneWidget);
      final sw = t.widget<Switch>(find.byType(Switch).first);
      expect(sw.value, isFalse);
      // The consequence sentence is on screen next to the toggle, not buried.
      expect(find.textContaining('never your'), findsOneWidget);
    });

    testWidgets('the phone toggle only exists once you are listed', (t) async {
      final off = _Rpc({'near_listing_get': own()});
      await _pump(t, NearListingScreen(rpc: off.call));
      expect(find.byType(Switch), findsOneWidget);

      // A distinct key, or Flutter reuses the element and its State never
      // re-reads the new payload — the second pump would silently assert
      // against the first one's answer.
      final on = _Rpc({'near_listing_get': own(listed: true)});
      await _pump(t,
          NearListingScreen(key: const ValueKey('listed'), rpc: on.call));
      expect(find.byType(Switch), findsNWidgets(2));
      expect(find.text('Show my phone number'), findsOneWidget);
      expect(find.text('https://medibo.in/near/p/tok'), findsOneWidget);
    });

    testWidgets('the owner reads the SAME sentence a consumer would',
        (t) async {
      final rpc = _Rpc({'near_listing_get': own(listed: true)});
      await _pump(t, NearListingScreen(rpc: rpc.call));

      expect(find.text('Likely available'), findsOneWidget);
      expect(find.text('Mark unavailable'), findsOneWidget);
    });

    testWidgets('one tap hides it; the hidden row offers the undo', (t) async {
      final rpc = _Rpc({
        'near_listing_get': own(listed: true),
        'near_mark_unavailable': own(listed: true, hidden: true),
      });
      await _pump(t, NearListingScreen(rpc: rpc.call));
      await t.tap(find.text('Mark unavailable'));
      await t.pumpAndSettle();

      final sent =
          rpc.calls.lastWhere((c) => c.key == 'near_mark_unavailable').value;
      expect(sent['p_medicine_id'], 42);
      expect(find.text('Hidden until 02 Sep, 10:00 AM'), findsOneWidget);
      expect(find.text('Show again'), findsOneWidget);
      expect(find.text('Mark unavailable'), findsNothing);
    });

    testWidgets('the poster button prints the backend label for its state',
        (t) async {
      final rpc = _Rpc({'near_listing_get': own(listed: true)});
      await _pump(t, NearListingScreen(rpc: rpc.call));
      expect(find.text('Get poster'), findsOneWidget);
      expect(find.text('A printable poster with your name and a QR code.'),
          findsOneWidget);
    });

    testWidgets('a refusal renders the backend copy instead of throwing',
        (t) async {
      final rpc = _Rpc({
        'near_listing_get': {
          'ok': false,
          'error': 'denied',
          'tone': 'danger',
          'message': 'Only the pharmacy owner can change the nearby listing.',
        },
      });
      await _pump(t, NearListingScreen(rpc: rpc.call));

      expect(
          find.text('Only the pharmacy owner can change the nearby listing.'),
          findsOneWidget);
    });
  });
}
