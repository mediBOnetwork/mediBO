// PROTECTED — CHANGE #536.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes My Shop behaviour, never to make an unrelated change go
// green.
//
// What this holds down:
//
//   1. My Shop is ONE RPC rendered IN PAYLOAD ORDER. customer_shop_home()
//      decides which sections exist, what they are called, what order they come
//      in and what is inside each one. The fixture below is deliberately NOT
//      alphabetical and its tiles are deliberately not sorted by label, so a
//      client-side sort fails here rather than in front of a pharmacy.
//
//   2. Nothing is written in Dart. The screen title, the subtitle, every
//      section label, every tile label and every caption print verbatim. There
//      is no feature list in the screen and no `switch` on a feature key, which
//      is what makes a twentieth tile an INSERT instead of a deploy.
//
//   3. A tap carries the BACKEND's own route. The tile hands back `nav_key`
//      exactly as it arrived — the screen never derives a route from a
//      feature_key or a label. This is the bug the change was filed for: the
//      suite was registered on the wrong surface and every tile dead-ended.
//
//   4. `ok:false` renders the backend's sentence and nothing else. An admin, a
//      supplier or a rider opening this tab sees customer_shop_home()'s own
//      refusal — the screen has no wording of its own to soften it with.
//
//   5. Sections after the first arrive COLLAPSED. A pharmacy that only places
//      orders is not handed nineteen tiles at once; the first section's tiles
//      are on screen and the rest are behind their own headers.
//
// No network, no Supabase, no goldens. The RPC is a function that returns a map.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/pharmacy/my_shop_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

/// A customer_shop_home() answer. Sections are Money → Billing → Stock on
/// purpose: neither the section order nor the tile order is alphabetical, and
/// neither may be "helpfully" corrected by the screen.
Map<String, dynamic> _payload() => {
      'ok': true,
      'role': 'customer',
      'title': 'My Shop',
      'subtitle': 'Everything you run your counter with.',
      'empty_message': 'Your shop tools will appear here.',
      'retry_label': 'Try again',
      'sections': [
        {
          'key': 'cshop_money',
          'label': 'Money',
          'icon_key': 'rupee',
          'items': [
            {
              'feature_key': 'admin.khata',
              'label': 'Khata book',
              'caption': 'Who owes the counter, and since when',
              'icon_key': 'book',
              'icon_letter': 'K',
              'nav_key': 'khata',
            },
            {
              'feature_key': 'shop.pharmacy_gst',
              'label': 'GST pack',
              'caption': 'Your month, ready for the return',
              'icon_key': 'account_balance',
              'icon_letter': 'G',
              'nav_key': 'pharmacy_gst',
            },
          ],
        },
        {
          'key': 'cshop_billing',
          'label': 'Billing',
          'icon_key': 'receipt',
          'items': [
            {
              'feature_key': 'shop.pos',
              'label': 'Counter POS',
              'caption': 'Ring up a walk-in sale',
              'icon_key': 'shop',
              'icon_letter': 'C',
              'nav_key': 'pos',
            },
          ],
        },
        {
          'key': 'cshop_stock',
          'label': 'Stock',
          'icon_key': 'inventory',
          'items': [
            {
              'feature_key': 'admin.pharmacy_expiry',
              'label': 'Expiry watch',
              'caption': 'Batches going short-dated',
              // A glyph this build has never heard of must still draw a tile —
              // the row's own initial stands in for it.
              'icon_key': 'a_key_this_build_has_never_heard_of',
              'icon_letter': 'E',
              'nav_key': 'pharmacy_expiry',
            },
          ],
        },
      ],
    };

Future<void> _pump(
  WidgetTester tester, {
  required Map<String, dynamic> payload,
  List<String>? taps,
  bool active = true,
  List<String>? calls,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: MyShopScreen(
        navigate: (key) => taps?.add(key),
        active: active,
        rpc: (fn, params) async {
          calls?.add(fn);
          return payload;
        },
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  testWidgets('sections render in payload order — never sorted', (t) async {
    await _pump(t, payload: _payload());

    final money = t.getTopLeft(find.text('Money')).dy;
    final billing = t.getTopLeft(find.text('Billing')).dy;
    final stock = t.getTopLeft(find.text('Stock')).dy;

    expect(money, lessThan(billing));
    expect(billing, lessThan(stock));
  });

  testWidgets('title, subtitle, labels and captions print verbatim', (t) async {
    await _pump(t, payload: _payload());

    expect(find.text('My Shop'), findsOneWidget);
    expect(find.text('Everything you run your counter with.'), findsOneWidget);
    // First section is open, so its tiles and their captions are on screen.
    expect(find.text('Khata book'), findsOneWidget);
    expect(find.text('Who owes the counter, and since when'), findsOneWidget);
    expect(find.text('GST pack'), findsOneWidget);
  });

  testWidgets('only the first section is expanded', (t) async {
    await _pump(t, payload: _payload());

    // Money is open …
    expect(find.text('Khata book'), findsOneWidget);
    // … Billing and Stock are headers only.
    expect(find.text('Counter POS'), findsNothing);
    expect(find.text('Expiry watch'), findsNothing);
    // The headers themselves are always drawn.
    expect(find.text('Billing'), findsOneWidget);
    expect(find.text('Stock'), findsOneWidget);
  });

  testWidgets('a folded section opens on its header', (t) async {
    await _pump(t, payload: _payload());

    await t.tap(find.text('Billing'));
    await t.pumpAndSettle();

    expect(find.text('Counter POS'), findsOneWidget);
  });

  testWidgets('a tap carries the backend nav_key, not a derived route',
      (t) async {
    final taps = <String>[];
    await _pump(t, payload: _payload(), taps: taps);

    await t.tap(find.text('Khata book'));
    await t.pumpAndSettle();

    // 'khata' is the payload's nav_key. The feature_key is 'admin.khata' and
    // the label is 'Khata book'; neither may be what travels.
    expect(taps, ['khata']);
  });

  testWidgets('an unknown icon key still draws the tile, on its own initial',
      (t) async {
    await _pump(t, payload: _payload());

    await t.tap(find.text('Stock'));
    await t.pumpAndSettle();

    expect(find.text('Expiry watch'), findsOneWidget);
    expect(find.text('E'), findsOneWidget);
  });

  testWidgets('ok:false renders the backend message and no tiles', (t) async {
    await _pump(t, payload: {
      'ok': false,
      'error': 'not_pharmacy',
      'message': 'My Shop is for a pharmacy account.',
    });

    expect(find.text('My Shop is for a pharmacy account.'), findsOneWidget);
    expect(find.text('Counter POS'), findsNothing);
    // No wording of the screen's own is added to a refusal.
    expect(find.text('My Shop'), findsNothing);
  });

  // CHANGE #536 QA round 1. The shell's IndexedStack builds every page at boot,
  // so an eager initState load fired this RPC once per visitor — including
  // signed-out ones, who can only ever be refused. The tab asks when it is
  // opened, and asks once.
  testWidgets('an inactive tab asks the backend nothing', (t) async {
    final calls = <String>[];
    await _pump(t, payload: _payload(), active: false, calls: calls);

    expect(calls, isEmpty);
    expect(find.text('Khata book'), findsNothing);
  });

  testWidgets('the first activation loads exactly once', (t) async {
    final calls = <String>[];
    await _pump(t, payload: _payload(), calls: calls);

    expect(calls, ['customer_shop_home']);

    // A rebuild while still active must not ask again.
    await t.pump();
    await t.pumpAndSettle();
    expect(calls, ['customer_shop_home']);
  });

  testWidgets('no sections is the backend empty state, never a crash',
      (t) async {
    await _pump(t, payload: {
      'ok': true,
      'title': 'My Shop',
      'empty_message': 'Your shop tools will appear here.',
      'sections': const [],
    });

    expect(find.text('Your shop tools will appear here.'), findsOneWidget);
  });
}
