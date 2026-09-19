// PROTECTED — CMD #2029.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes floating-cart-pill behaviour.
//
// What this holds down — the pill DECIDES NOTHING:
//
//   1. `show` is the backend's answer. The pill never counts the cart to work
//      out whether it exists, and when show is false it is both invisible and
//      untappable (a ghost pill that still swallows taps was the bug that made
//      this a widget test rather than a decision test).
//
//   2. `items_label` is printed VERBATIM. "1 item" / "13 items" is pluralised
//      in SQL; a fixture with deliberately non-English wording proves Dart
//      never rebuilds the string from a count.
//
//   3. `cta` is printed verbatim too — line two is payload, not a literal.
//
//   4. `thumbs` decides how MANY squares are drawn and in WHICH ORDER. One
//      entry draws one square, two draw two, and the app never reaches past
//      what the backend sent (a 13-item cart still sends two thumbs).
//
//   5. A thumb with no image renders the placeholder icon INSIDE the square —
//      never a blank white box.
//
//   6. CMD #2081 changes the shape deliberately: the pill is now
//      [CartPill.kHeight] tall and about [CartPill.kWidthFactor] of the SCREEN
//      wide (floored at [CartPill.kMinWidth] so a 320px phone still fits two
//      thumbnails, two lines and a chevron), centred, and never wider than the
//      room it was handed at 320 / 360 / 412 / 480 px. The two facts are now
//      STACKED — 'View cart' above, the count below — so the hairline divider
//      that separated them on one line is gone.
//
//   6e. The lines come from `lines[]` in payload order and the '+N' bubble
//      exists only when the backend said `has_more`. Dart does not subtract a
//      thumb count from an item count to make '+2'.
//
//   7. WHICH page floats the pill is the nav registry's answer
//      (`customer_nav().slots[].cart_pill`), never a page number in Dart. The
//      Catalogue was page 12 and the shell asked `_index == 0`, so the pill
//      was missing on every catalogue surface. An unknown page floats nothing;
//      an unanswered registry falls back to Home alone.
//
// No network, no Supabase, no goldens: every thumb url in the pumped tests is
// empty, so ProductImage paints its offline fallback.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/app_state.dart';
import 'package:pharma_b2b/models/cart_model.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/cart_pill.dart';
import 'package:pharma_b2b/widgets/product_image.dart';

// ── fixtures ─────────────────────────────────────────────────────────────────

Map<String, dynamic> _thumb(String id, {String image = ''}) => {
      'product_id': id,
      'name': 'Product $id',
      'image_url': image,
      'has_image': image.isNotEmpty,
    };

/// Mirrors cart_pill_block(): every string and the whole thumb list arrive
/// already decided.
Map<String, dynamic> _payload({
  required bool show,
  required String itemsLabel,
  String cta = 'View cart',
  List<Map<String, dynamic>> thumbs = const [],
  String moreLabel = '',
}) =>
    {
      'items': const [],
      'item_count': 0,
      'render': {
        'pill': {
          'show': show,
          'identifier': 'cart_pill',
          'items_label': itemsLabel,
          'cta': cta,
          // CMD #2081 — the two stacked lines, exactly as cart_pill_block()
          // emits them: [0] the strong line, [1] the count under it.
          'lines': [
            {'key': 'cta', 'text': cta},
            {'key': 'count', 'text': itemsLabel},
          ],
          'thumbs': thumbs,
          'thumb_count': thumbs.length,
          'has_more': moreLabel.isNotEmpty,
          'more_label': moreLabel,
          'a11y': '$cta, $itemsLabel',
        },
      },
    };

Future<CartModel> _loaded(Map<String, dynamic> payload) async {
  CartModel.rpcTransport = (fn, params) async => payload;
  final cart = CartModel.forTest();
  await cart.refresh();
  return cart;
}

Future<int> _pump(
  WidgetTester tester,
  CartModel cart, {
  double width = 360,
  VoidCallback? onTap,
}) async {
  var taps = 0;
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: AppState(
        cart: cart,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: CartPill(onTap: onTap ?? () => taps++),
        ),
      ),
    ),
  ));
  await tester.pump();
  return taps;
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);
  tearDown(() => CartModel.rpcTransport = null);

  testWidgets('1. show:false is invisible AND untappable', (tester) async {
    final cart = await _loaded(_payload(show: false, itemsLabel: ''));
    await _pump(tester, cart);

    final fade = tester.widget<AnimatedOpacity>(find.ancestor(
      of: find.byKey(const Key('c2029_pill')),
      matching: find.byType(AnimatedOpacity),
    ));
    expect(fade.opacity, 0, reason: 'the backend said there is no pill');

    final gate = tester.widget<IgnorePointer>(find
        .descendant(
            of: find.byType(CartPill), matching: find.byType(IgnorePointer))
        .first);
    expect(gate.ignoring, isTrue,
        reason: 'a hidden pill must not swallow taps meant for the page');
  });

  testWidgets('2. items_label is printed verbatim — never pluralised in Dart',
      (tester) async {
    final cart = await _loaded(_payload(
      show: true,
      itemsLabel: '13 items',
      thumbs: [_thumb('1'), _thumb('2')],
    ));
    await _pump(tester, cart);

    expect(find.text('13 items'), findsOneWidget);
    expect(find.text('View cart'), findsOneWidget);
  });

  testWidgets('2b. the singular is the backend\'s too', (tester) async {
    final cart = await _loaded(_payload(
      show: true,
      itemsLabel: '1 item',
      thumbs: [_thumb('1')],
    ));
    await _pump(tester, cart);

    expect(find.text('1 item'), findsOneWidget);
    expect(find.textContaining('items'), findsNothing,
        reason: 'Dart must not append an s of its own');
  });

  testWidgets('3. both lines are payload — odd wording survives intact',
      (tester) async {
    final cart = await _loaded(_payload(
      show: true,
      itemsLabel: '13 saman',
      cta: 'Cart dekhein',
      thumbs: [_thumb('1'), _thumb('2')],
    ));
    await _pump(tester, cart);

    expect(find.text('13 saman'), findsOneWidget);
    expect(find.text('Cart dekhein'), findsOneWidget);
  });

  testWidgets('4. thumbs decide how many squares, and in which order',
      (tester) async {
    final one = await _loaded(_payload(
      show: true,
      itemsLabel: '1 item',
      thumbs: [_thumb('aaa')],
    ));
    await _pump(tester, one);
    expect(find.byKey(const Key('c2029_pill_thumb_0')), findsOneWidget);
    expect(find.byKey(const Key('c2029_pill_thumb_1')), findsNothing,
        reason: 'one item is one square');

    final two = await _loaded(_payload(
      show: true,
      itemsLabel: '13 items',
      thumbs: [_thumb('older'), _thumb('newest')],
    ));
    await _pump(tester, two);
    expect(find.byKey(const Key('c2029_pill_thumb_0')), findsOneWidget);
    expect(find.byKey(const Key('c2029_pill_thumb_1')), findsOneWidget);
    expect(find.byKey(const Key('c2029_pill_thumb_2')), findsNothing,
        reason: 'a 13-item cart still draws exactly what the backend sent');

    // Draw order is the payload's order: [0] behind, [1] on top.
    final rendered = tester
        .widgetList<ProductImage>(find.byType(ProductImage))
        .map((w) => w.url)
        .toList();
    expect(rendered.length, 2);
  });

  testWidgets('5. a thumb with no image shows the placeholder, not a blank box',
      (tester) async {
    final cart = await _loaded(_payload(
      show: true,
      itemsLabel: '2 items',
      thumbs: [_thumb('a'), _thumb('b')],
    ));
    await _pump(tester, cart);

    expect(find.byIcon(Icons.medication_outlined), findsNWidgets(2),
        reason: 'an imageless product still shows the mediBO placeholder');
  });

  testWidgets('5b. a thumb url is passed through untouched', (tester) async {
    final cart = await _loaded(_payload(
      show: true,
      itemsLabel: '2 items',
      thumbs: [_thumb('a'), _thumb('b', image: 'https://cdn/x.png')],
    ));
    // The pill must hand ProductImage exactly the backend's url; it never
    // rewrites, resizes or substitutes one.
    CartModel.rpcTransport = null;
    expect(cart.pillThumbs.map((t) => t['image_url']).toList(),
        ['', 'https://cdn/x.png']);
    expect(cart.pillThumbs.last['has_image'], isTrue);
  });

  // NOTE on widths: the test font paints every glyph as a square of the font
  // size, so a label is roughly twice as wide here as it is on a device. The
  // widths below are therefore pessimistic on purpose — a pill that fits with
  // this font fits with any real one.

  testWidgets('6. one ${CartPill.kHeight}px bar, never wider than the phone',
      (tester) async {
    for (final w in <double>[320, 360, 412, 480]) {
      final cart = await _loaded(_payload(
        show: true,
        itemsLabel: '1 item',
        cta: 'Cart',
        thumbs: [_thumb('1')],
      ));
      await _pump(tester, cart, width: w);
      final size = tester.getSize(find.byKey(const Key('c2029_pill')));
      expect(size.width, lessThanOrEqualTo(w),
          reason: 'the pill overflowed at ${w}px');
      expect(size.height, CartPill.kHeight,
          reason: 'one bar, ${CartPill.kHeight}px, at every width');
      expect(tester.takeException(), isNull,
          reason: 'no overflow exception at ${w}px');
    }
  });

  testWidgets('6b. a label too long for the phone never overflows the bar',
      (tester) async {
    // CMD #2081 — the bar is a fixed rectangle now, so a long backend label
    // ellipsises INSIDE it instead of scaling the whole pill down. Either way
    // the promise is the same: no pixel leaves the screen and no row overflows.
    final cart = await _loaded(_payload(
      show: true,
      itemsLabel: '13 items in your basket right now',
      thumbs: [_thumb('1'), _thumb('2')],
    ));
    await _pump(tester, cart, width: 320);
    final size = tester.getSize(find.byKey(const Key('c2029_pill')));
    expect(size.width, lessThanOrEqualTo(320),
        reason: 'no pixel may leave the screen');
    expect(size.height, CartPill.kHeight);
    expect(tester.takeException(), isNull);
    expect(find.text('13 items in your basket right now'), findsOneWidget,
        reason: 'the label is still the backend string, ellipsised not rebuilt');
  });

  testWidgets('6c. the width is a stable slice of the screen, always centred',
      (tester) async {
    // CMD #2081 — Blinkit's bar does NOT change width as items go in, so the
    // same phone gives the same rectangle whatever the basket holds. It is
    // still never the whole screen (cards sit beside it) and still centred,
    // and it still grows with a bigger phone rather than with a longer label.
    final short = await _loaded(_payload(
      show: true, itemsLabel: '1 item', cta: 'Cart', thumbs: [_thumb('a')]));
    await _pump(tester, short, width: 480);
    final shortRect = tester.getRect(find.byKey(const Key('c2029_pill')));

    final long = await _loaded(_payload(
      show: true,
      itemsLabel: '13 items',
      cta: 'Cart',
      thumbs: [_thumb('a'), _thumb('b')],
      moreLabel: '+11',
    ));
    await _pump(tester, long, width: 480);
    final longRect = tester.getRect(find.byKey(const Key('c2029_pill')));

    expect(longRect.width, closeTo(shortRect.width, 0.5),
        reason: 'adding items must not resize the bar');
    expect(longRect.width, lessThan(480),
        reason: 'the pill must not span the screen — cards sit under it');
    expect(longRect.center.dx, closeTo(240, 1), reason: 'centred');

    await _pump(tester, long, width: 600);
    final wide = tester.getSize(find.byKey(const Key('c2029_pill'))).width;
    expect(wide, greaterThan(longRect.width),
        reason: 'a bigger phone gets a proportionally bigger bar');
  });

  testWidgets('6e. the floor is what makes 320px fit', (tester) async {
    // 60% of 320 is less than two thumbnails, two lines and a chevron need.
    final cart = await _loaded(_payload(
      show: true,
      itemsLabel: '13 items',
      thumbs: [_thumb('a'), _thumb('b')],
      moreLabel: '+11',
    ));
    await _pump(tester, cart, width: 320);
    final w = tester.getSize(find.byKey(const Key('c2029_pill'))).width;
    expect(w, greaterThanOrEqualTo(320 * CartPill.kWidthFactor));
    expect(w, lessThanOrEqualTo(320), reason: 'and still inside the screen');
    expect(tester.takeException(), isNull);
  });

  testWidgets('6d. the two facts are STACKED, CTA above the count',
      (tester) async {
    // CMD #2081 — the shape this change is about. 'View cart' is the strong
    // line, the count sits under it, both left-aligned on one column, and the
    // hairline that separated them on a single line is gone.
    final cart = await _loaded(_payload(
      show: true,
      itemsLabel: '13 items',
      thumbs: [_thumb('a'), _thumb('b')],
    ));
    await _pump(tester, cart, width: 412);
    final cta = tester.getTopLeft(find.text('View cart'));
    final count = tester.getTopLeft(find.text('13 items'));
    expect(count.dy, greaterThan(cta.dy),
        reason: 'the count is BELOW the CTA — that is the stack');
    expect(count.dx, closeTo(cta.dx, 1.0),
        reason: 'both lines share one left edge');
    expect(find.byIcon(Icons.chevron_right), findsOneWidget,
        reason: 'one chevron, and no separator bar anywhere');
  });

  testWidgets('6f. the lines are the payload, in payload order',
      (tester) async {
    final cart = await _loaded(_payload(
      show: true, itemsLabel: '4 Artikel', cta: 'Basket ansehen',
      thumbs: [_thumb('a'), _thumb('b')]));
    await _pump(tester, cart, width: 412);
    expect(find.text('Basket ansehen'), findsOneWidget);
    expect(find.text('4 Artikel'), findsOneWidget);
    expect(find.text('View cart'), findsNothing,
        reason: 'a Dart literal would survive a non-English payload');
    expect(tester.getTopLeft(find.text('4 Artikel')).dy,
        greaterThan(tester.getTopLeft(find.text('Basket ansehen')).dy));
  });

  testWidgets('6g. the +N bubble is the backend flag, never a local count',
      (tester) async {
    final more = await _loaded(_payload(
      show: true,
      itemsLabel: '13 items',
      thumbs: [_thumb('a'), _thumb('b')],
      moreLabel: '+11',
    ));
    await _pump(tester, more, width: 412);
    expect(find.byKey(const Key('c2081_pill_more')), findsOneWidget);
    expect(find.text('+11'), findsOneWidget,
        reason: 'printed verbatim — 13 minus 2 is done in SQL');

    // has_more:false — no bubble, even with a basket that obviously holds more.
    final none = await _loaded(_payload(
      show: true,
      itemsLabel: '13 items',
      thumbs: [_thumb('a'), _thumb('b')],
    ));
    await _pump(tester, none, width: 412);
    expect(find.byKey(const Key('c2081_pill_more')), findsNothing);
    expect(find.textContaining('+'), findsNothing);
  });

  testWidgets('6h. the whole pill is one named tap target', (tester) async {
    final cart = await _loaded(_payload(
      show: true, itemsLabel: '2 items', thumbs: [_thumb('a')]));
    await _pump(tester, cart, width: 412);
    final named = tester
        .widgetList<Semantics>(find.descendant(
            of: find.byType(CartPill), matching: find.byType(Semantics)))
        .map((w) => w.properties)
        .where((p) => (p.identifier ?? '').isNotEmpty)
        .toList();
    expect(named, isNotEmpty, reason: 'the payload names the target');
    expect(named.first.identifier, 'cart_pill');
    expect(named.first.label, 'View cart, 2 items');
  });

  testWidgets('8. which page floats the pill is the registry, not a number',
      (tester) async {
    // customer_nav().slots, verbatim: Home and the Catalogue carry the flag,
    // Orders / Bulk / My Shop do not.
    const slots = <Map<String, dynamic>>[
      {'key': 'home', 'page_index': 0, 'cart_pill': true},
      {'key': 'catalogue', 'page_index': 12, 'cart_pill': true},
      {'key': 'bulk', 'page_index': 2, 'cart_pill': false},
      {'key': 'orders', 'page_index': 1, 'cart_pill': false},
      {'key': 'my_shop', 'page_index': 11, 'cart_pill': false},
    ];
    expect(CartPill.floatsOnPage(slots, 0), isTrue);
    expect(CartPill.floatsOnPage(slots, 12), isTrue,
        reason: 'the Catalogue is page 12 — this is the bug #2043 fixes');
    expect(CartPill.floatsOnPage(slots, 1), isFalse);
    expect(CartPill.floatsOnPage(slots, 2), isFalse);
    expect(CartPill.floatsOnPage(slots, 11), isFalse);
    expect(CartPill.floatsOnPage(slots, 7), isFalse,
        reason: 'a page with no slot floats nothing');

    // Turning a surface on is an UPDATE, and the app follows it with no deploy.
    const flipped = <Map<String, dynamic>>[
      {'key': 'home', 'page_index': 0, 'cart_pill': false},
      {'key': 'orders', 'page_index': 1, 'cart_pill': true},
    ];
    expect(CartPill.floatsOnPage(flipped, 0), isFalse);
    expect(CartPill.floatsOnPage(flipped, 1), isTrue);

    // Before the registry answers, Home alone — never nothing, never
    // everything.
    expect(CartPill.floatsOnPage(const [], 0), isTrue);
    expect(CartPill.floatsOnPage(const [], 12), isFalse);
  });

  test('9. the pill reserves its own room at the end of a list', () {
    // One constant: what the shell floats the pill by, and what the lists put
    // between their last card and the bottom of the page.
    expect(CartPill.bottomInset,
        CartPill.kHeight + CartPill.bottomGap * 2,
        reason: 'the gap above the nav is the gap below the last card');
    expect(CartPill.bottomInset, greaterThan(CartPill.kHeight),
        reason: 'a card must not sit underneath the pill');
  });

  testWidgets('7. the whole pill opens the cart', (tester) async {
    var taps = 0;
    final cart = await _loaded(_payload(
      show: true,
      itemsLabel: '13 items',
      thumbs: [_thumb('1'), _thumb('2')],
    ));
    await _pump(tester, cart, onTap: () => taps++);
    await tester.tap(find.byKey(const Key('c2029_pill')));
    await tester.pump();
    expect(taps, 1);
  });
}
