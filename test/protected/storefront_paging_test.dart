// PROTECTED — CHANGE #677.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes storefront paging, never to make an unrelated change go
// green.
//
// The bug this file exists to prevent coming back:
//
//   The app held three numbers of its own — a page size of 20, a hard ceiling
//   of 200 items, and the rule "the page came back shorter than I asked for, so
//   the feed must have ended". CARDIAC holds 3,068 buyable products and the
//   storefront dead-ended at 200 of them. Every one of those three numbers was
//   the frontend answering a question the backend owns.
//
// What this holds down:
//
//   1. A feed ends when, and only when, the BACKEND says has_more:false. A
//      short page does not end it. A long list does not end it. There is no
//      number in Dart that ends it.
//
//   2. The next request starts at the backend's own next_offset — never at
//      `items.length`, which drifts the moment the feed changes underneath.
//
//   3. `infinite` is the backend's word for "keep going", and a section is
//      pageable only while it holds fewer than the backend's `total`.
//
//   4. The Load-more button's word and the end-of-feed line are backend
//      strings. No label, no button — the app has no wording of its own to
//      fall back on.
//
//   5. `grid` is a real layout: a product section that scrolls with the page.
//      Which sections are rails and which are grids is a Postgres row.
//
// CHANGE #678 added the sixth, and it is a shape rule as much as a paging one:
//
//   6. Depth goes SIDEWAYS. A rail pages as it is scrolled right, up to the
//      ceiling the backend put in `total`. A vertical grid holds exactly what
//      the payload gave it and never grows — a page that reloads under the
//      thumb is a page you can never reach the bottom of. Both shapes end in
//      the same full-width Show-all button, whose words are the backend's.
//
// No network, no Supabase, no goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/app_state.dart';
import 'package:pharma_b2b/models/cart_model.dart';
import 'package:pharma_b2b/models/home_sections.dart';
import 'package:pharma_b2b/models/product.dart';
import 'package:pharma_b2b/models/storefront_p3.dart';
import 'package:pharma_b2b/widgets/compact_product_card.dart';
import 'package:pharma_b2b/widgets/home_sections_view.dart';

/// One card in the exact shape storefront_home_v2 / storefront_home_more send.
Map<String, dynamic> _card(int id, String name) => {
  'id': id,
  'name': name,
  'company': 'GLENMARK PHARMACEUTICALS LTD',
  'pack_label': '1 Strip',
  'form_chip': 'Strip',
  'image': '',
  'mrp_label': '₹236.20',
  'buyable': true,
  'availability': {
    'is_available': true,
    'can_add': true,
    'gated': false,
    'cta_label': 'Add to cart',
    'colors': {'bg': '#1B7A43', 'fg': '#FFFFFF'},
  },
  'pricing': {
    'mrp': 236.2,
    'sale_price': 236.2,
    'discount_pct': 0,
    'mrp_display': '',
    'price_display': '₹236.20',
    'discount_label': '',
    'has_price': true,
    'has_discount': false,
  },
};

/// A `grid` section carrying the backend's paging plan — the shape the live
/// `all_products` section arrives in.
Map<String, dynamic> _gridSection({
  bool infinite = true,
  int total = 30304,
  int pageSize = 100,
  int nextOffset = 100,
  int cards = 3,
}) => {
  'id': 'all_products',
  'layout': 'grid',
  'title': 'All Products',
  'accent_word': 'All',
  'subtitle': 'THE WHOLE CATALOGUE',
  'see_all': {'type': 'category', 'key': 'All'},
  'see_all_label': 'See all products',
  'infinite': infinite,
  'next_offset': nextOffset,
  'page_size': pageSize,
  'total': total,
  'items': [for (var i = 0; i < cards; i++) _card(900000 + i, 'Grid Item $i')],
};

/// CHANGE #678 — a `rail`: the section that carries depth. 24 up front, +24 a
/// page, stopping at the backend's ceiling of 100.
Map<String, dynamic> _railSection({
  int total = 100,
  int cards = 4,
  int nextOffset = 24,
}) => {
  ..._gridSection(total: total, cards: cards, nextOffset: nextOffset),
  'id': 'cat_cardiac',
  'layout': 'rail',
  'title': 'Cardiac',
  'accent_word': 'Cardiac',
  'subtitle': 'TOP PICKS IN CARDIAC',
  'see_all': {'type': 'category', 'key': 'CARDIAC'},
  'see_all_label': 'Show all 3,068 products',
  'page_size': 24,
};

Map<String, dynamic> _payload(Map<String, dynamic> section) => {
  'ok': true,
  'sections': [section],
};

int _pumpSeq = 0;

Future<void> _pump(
  WidgetTester tester,
  Map<String, dynamic> payload, {
  double width = 1000,
}) async {
  // Width matters: the grid's column count is derived from it, and a widget
  // test's default viewport is 800 — assert the phone case explicitly.
  tester.view.physicalSize = Size(width, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  HomeSectionsView.resetMemo();
  addTearDown(HomeSectionsView.resetMemo);

  await tester.pumpWidget(
    AppState(
      cart: CartModel.forTest(),
      child: MaterialApp(
        onGenerateRoute: (s) => MaterialPageRoute(
          settings: s,
          builder: (_) => const SizedBox.shrink(),
        ),
        home: Scaffold(
          body: HomeSectionsView(
            key: ValueKey('paging-${_pumpSeq++}'),
            loader: () async => HomeSections.fromMap(payload),
            onCategoryTap: (_) {},
            notificationsLoader: () async => BackInStock.empty,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

HomeSection _parse(Map<String, dynamic> raw) {
  final s = HomeSection.fromMap(raw);
  expect(s, isNotNull, reason: 'the fixture must parse');
  return s!;
}

void main() {
  setUp(() {
    CartModel.rpcTransport = (fn, params) async => {
      'ok': true,
      'message': '',
      'cart': <String, dynamic>{},
    };
  });
  tearDown(() => CartModel.rpcTransport = null);

  group('the paging plan is the backend\'s, not the app\'s', () {
    test('canPageMore is infinite AND below the backend total', () {
      final s = _parse(_gridSection());
      expect(s.infinite, isTrue);
      expect(s.total, 30304);
      expect(s.pageSize, 100);
      expect(
        s.canPageMore,
        isTrue,
        reason: '3 of 30,304 held — the backend says keep going',
      );
    });

    test('a section the backend did not mark infinite never pages', () {
      final s = _parse(_gridSection(infinite: false));
      expect(
        s.canPageMore,
        isFalse,
        reason: 'no client rule may override infinite:false',
      );
    });

    test('holding everything the backend has ends it — no 200 ceiling', () {
      // 250 cards, and the backend says that IS everything. The old code would
      // have stopped at 200 regardless; the new code stops because total says
      // so, and would happily have gone past 200 if total were larger.
      final s = _parse(_gridSection(total: 250, cards: 250, nextOffset: 250));
      expect(s.cards.length, 250);
      expect(s.canPageMore, isFalse);

      final deep = _parse(
        _gridSection(total: 30304, cards: 250, nextOffset: 250),
      );
      expect(deep.cards.length, 250);
      expect(
        deep.canPageMore,
        isTrue,
        reason: '250 held is well past the old 200 cap and must NOT end',
      );
    });

    test('a short page does not end the feed — only has_more does', () {
      // 3 cards against a page_size of 100. Under the old rule this was
      // "shorter than a page, therefore the end". It is not.
      final s = _parse(_gridSection(cards: 3, pageSize: 100));
      expect(s.cards.length, lessThan(s.pageSize));
      expect(s.canPageMore, isTrue);
    });

    test('a section with no See-all destination cannot page', () {
      final raw = _gridSection();
      raw['see_all'] = null;
      final s = _parse(raw);
      expect(s.feedKey, '');
      expect(
        s.canPageMore,
        isFalse,
        reason: 'nowhere to page FROM is not a reason to invent one',
      );
    });
  });

  group('appending uses the backend cursor', () {
    test('next_offset comes from the response, not from items.length', () {
      final s = _parse(_gridSection(cards: 3, nextOffset: 100));
      final more = [
        Product.fromHomeCard(_card(910001, 'Appended A')),
        Product.fromHomeCard(_card(910002, 'Appended B')),
      ];
      // The backend jumped the cursor to 250 — it de-duplicated, or the feed
      // moved. The app must take 250, not 3 + 2.
      final grown = s.appending(more, 250);

      expect(grown.cards.length, 5);
      expect(grown.nextOffset, 250);
      expect(
        grown.cards.first.name,
        'Grid Item 0',
        reason: 'appending keeps order — it never re-sorts',
      );
      expect(grown.cards.last.name, 'Appended B');
      // Everything else survives the copy.
      expect(grown.id, s.id);
      expect(grown.total, s.total);
      expect(grown.pageSize, s.pageSize);
      expect(grown.infinite, isTrue);
    });
  });

  group('grid is a real layout', () {
    testWidgets('a grid section renders its cards', (tester) async {
      await _pump(tester, _payload(_gridSection(cards: 4)));

      expect(find.byType(CompactProductCard), findsNWidgets(4));
      expect(find.text('THE WHOLE CATALOGUE'), findsOneWidget);
    });

    testWidgets('a grid stacks vertically — it is not a rail', (tester) async {
      // A 390pt phone: two columns, so the third card starts the second row.
      await _pump(tester, _payload(_gridSection(cards: 4)), width: 390);

      final cards = find.byType(CompactProductCard);
      final row1 = tester.getTopLeft(cards.at(0));
      final row1b = tester.getTopLeft(cards.at(1));
      final row2 = tester.getTopLeft(cards.at(2));

      expect(row1b.dy, row1.dy, reason: 'cards 1 and 2 share a row');
      expect(
        row2.dy,
        greaterThan(row1.dy),
        reason: 'card 3 wrapped — a grid, not a sideways rail',
      );
      expect(row1b.dx, greaterThan(row1.dx));
    });

    testWidgets('the whole-catalogue grid (key All) shows no See-all bar',
        (tester) async {
      // Best Sellers / All-products (see_all key 'All') carry no "Show all
      // products" bar — the hero's Browse-catalogue CTA is that entry instead.
      // A category- or company-wise bar still renders verbatim (the rail test
      // below covers that).
      await _pump(tester, _payload(_gridSection()));
      expect(find.text('See all products'), findsNothing);
    });

    testWidgets('no See-all label means no See-all control', (tester) async {
      final raw = _gridSection();
      raw['see_all_label'] = '';
      await _pump(tester, _payload(raw));
      expect(find.text('See all products'), findsNothing);
    });
  });

  // CHANGE #678 — the shape rule. Sideways is where depth lives.
  group('depth is sideways, not downwards', () {
    test('a rail below the ceiling pages; at the ceiling it stops', () {
      final mid = _parse(_railSection(total: 100, cards: 24, nextOffset: 24));
      expect(
        mid.canPageMore,
        isTrue,
        reason: '24 of the backend\'s 100 — scroll right for more',
      );

      final full = _parse(
        _railSection(total: 100, cards: 100, nextOffset: 100),
      );
      expect(
        full.canPageMore,
        isFalse,
        reason: 'the ceiling is the backend\'s 100, not a number in Dart',
      );
    });

    test('a finite grid never pages, whatever it holds', () {
      // The live grid arrives infinite:false with total == what it was given.
      final s = _parse(
        _gridSection(infinite: false, total: 9, cards: 9, nextOffset: 9),
      );
      expect(
        s.canPageMore,
        isFalse,
        reason: 'a vertical block that keeps growing has no bottom',
      );
    });

    testWidgets('a rail lays its cards out in ONE row', (tester) async {
      await _pump(tester, _payload(_railSection(cards: 4)), width: 390);

      final cards = find.byType(CompactProductCard);
      final a = tester.getTopLeft(cards.at(0));
      final b = tester.getTopLeft(cards.at(1));
      expect(b.dy, a.dy, reason: 'a rail never wraps — that is a grid');
      expect(b.dx, greaterThan(a.dx));
    });

    testWidgets('a rail carries the same Show-all bar a grid does', (
      tester,
    ) async {
      await _pump(tester, _payload(_railSection()));
      // The count is the backend's word, printed verbatim — the app owns no
      // wording it could compose this from.
      expect(find.text('Show all 3,068 products'), findsOneWidget);
    });
  });

  // CHANGE #678a — a rail moves because a finger moved it. Nothing else.
  group('a rail never scrolls itself', () {
    testWidgets('it sits at 0 and stays there', (tester) async {
      await _pump(tester, _payload(_railSection(cards: 6)), width: 390);
      final pos = tester
          .state<ScrollableState>(find.byType(Scrollable).last)
          .position;
      expect(pos.pixels, 0);

      // Let every post-frame callback, layout pass and animation run out.
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(
        pos.pixels,
        0,
        reason: 'no effect, no animation, no restored offset — it is a list',
      );
    });

    testWidgets('two rails keep their own positions', (tester) async {
      final a = _railSection(cards: 8);
      final b = {..._railSection(cards: 8), 'id': 'cat_derma'};
      await _pump(tester, {
        'ok': true,
        'sections': [a, b],
      }, width: 390);

      final rails = find.byType(Scrollable);
      final posA = tester.state<ScrollableState>(rails.at(1)).position;
      final posB = tester.state<ScrollableState>(rails.at(2)).position;

      await tester.drag(rails.at(1), const Offset(-200, 0));
      await tester.pumpAndSettle();

      expect(posA.pixels, greaterThan(0));
      expect(
        posB.pixels,
        0,
        reason: 'one rail\'s offset must never land on another rail',
      );
    });
  });
}
