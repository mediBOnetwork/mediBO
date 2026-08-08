// PROTECTED — CHANGE #637.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes home-feed behaviour, never to make an unrelated change
// go green.
//
// What this holds down:
//
//   1. The home feed is ONE RPC rendered IN PAYLOAD ORDER. storefront_home_v2()
//      decides which sections exist, what they are called and what is in them.
//      The app must never sort, re-title, drop or reorder them — reordering the
//      home page is an UPDATE in Postgres, not a deploy.
//
//   2. Forward compatibility. A layout this build has never heard of, and a
//      section that arrives with no items, are both skipped SILENTLY. That is
//      what lets the backend ship a new section type to clients already in the
//      field. Neither may throw, and neither may leave a dangling header.
//
//   3. Titles, subtitles and count labels are printed verbatim. The green
//      accent is `accent_word` located inside `title` — never a guess at "the
//      first word" or "the last word".
//
//   4. A rail card is the SAME CompactProductCard the category grid uses,
//      reading the same backend-rendered `pricing.price_display` and
//      `availability.cta_label`. The home payload names its fields differently
//      (name/company/image/pack_label/form_chip vs the MEDICINE row's
//      product_name/marketer/image_url_1/pack_size/pack_type), so a mapping
//      factory exists — but the CARD is not forked, and an unavailable card
//      must show the backend's own verdict, not a locally chosen state.
//
//   5. Taps carry the backend's own key: a card opens /product/<its id>, a
//      category tile hands back `key` (the raw category name, not the pretty
//      label), and a tile with no key is not tappable at all.
//
// Fixture mirrors a real storefront_home_v2() response taken off the live
// database on 2026-08-02. No network, no Supabase, no camera, no goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/app_state.dart';
import 'package:pharma_b2b/models/cart_model.dart';
import 'package:pharma_b2b/models/home_sections.dart';
import 'package:pharma_b2b/models/storefront_p3.dart';
import 'package:pharma_b2b/widgets/compact_product_card.dart';
import 'package:pharma_b2b/widgets/home_sections_view.dart';

/// One rail card — the exact shape storefront_home_v2() sends.
Map<String, dynamic> _card({
  required int id,
  required String name,
  bool available = true,
  String ctaLabel = 'Add to cart',
  String priceDisplay = '₹236.20',
}) =>
    {
      'id': id,
      'name': name,
      'company': 'GLENMARK PHARMACEUTICALS LTD',
      'pack_label': '1 Strip',
      'form_chip': 'Strip',
      'image': '',
      'mrp_label': priceDisplay,
      'buyable': available,
      'availability': {
        'is_available': available,
        'can_add': available,
        'gated': false,
        'cta_label': ctaLabel,
        'colors': {'bg': '#1B7A43', 'fg': '#FFFFFF'},
      },
      'pricing': {
        'mrp': 236.2,
        'sale_price': 236.2,
        'discount_pct': 0,
        'mrp_display': priceDisplay,
        'price_display': priceDisplay,
        'discount_label': '',
        'has_price': true,
        'has_discount': false,
      },
    };

/// The full payload: a rail (one card unavailable), an icon_grid, a brand_grid,
/// an unknown layout and an empty section — in a deliberate order.
Map<String, dynamic> _payload() => {
      'ok': true,
      'sections': [
        {
          'id': 'best_sellers',
          'layout': 'rail',
          'title': 'Best Sellers',
          'accent_word': 'Best',
          'subtitle': 'MOST ORDERED ON MEDIBO',
          'see_all': {'type': 'category', 'key': 'All'},
          // CHANGE #673 — the pill's WORD is the backend's too. It used to be
          // the Dart literal 'See all'.
          'see_all_label': 'See all',
          'items': [
            _card(id: 252328, name: 'SyNtraN 200 Capsule'),
            _card(
              id: 999001,
              name: 'Gone Forever Tablet',
              available: false,
              ctaLabel: 'Unavailable',
            ),
          ],
        },
        {
          'id': 'shop_by_category',
          'layout': 'icon_grid',
          'title': 'Shop by category',
          'accent_word': 'category',
          'subtitle': 'EVERY THERAPEUTIC CLASS',
          'see_all': null,
          'items': [
            {
              'label': 'Anti Infectives',
              'count_label': '77,547 products',
              'key': 'ANTI INFECTIVES',
            },
            {'label': 'Cardiac', 'count_label': '28,626 products', 'key': ''},
          ],
        },
        {
          'id': 'future_section',
          'layout': 'future_thing',
          'title': 'From the future',
          'accent_word': 'future',
          'subtitle': 'NOT IN THIS BUILD',
          'items': [
            {'label': 'whatever', 'count_label': '', 'key': 'x'}
          ],
        },
        {
          'id': 'empty_rail',
          'layout': 'rail',
          'title': 'Nothing here',
          'accent_word': 'Nothing',
          'subtitle': 'EMPTY',
          'items': <dynamic>[],
        },
        {
          'id': 'shop_by_company',
          'layout': 'brand_grid',
          'title': 'Shop by company',
          'accent_word': 'company',
          'subtitle': 'TOP MANUFACTURERS',
          'see_all': null,
          'items': [
            {
              'label': 'SUN PHARMACEUTICAL INDUSTRIES LTD',
              'count_label': '2,510 products',
              'key': 'sun pharmaceutical industries',
            },
          ],
        },
      ],
    };

int _pumpSeq = 0;

/// Records what the feed handed back, so navigation can be asserted without
/// wiring a real HomeShell.
class _Taps {
  final categories = <String>[];
  final companies = <String>[];
  final routes = <String>[];
}

Future<_Taps> _pump(WidgetTester tester, Map<String, dynamic> payload) async {
  // Tall surface: the feed is a lazy ListView, so a short viewport simply
  // would not build the lower sections and assertions would turn into scroll
  // position tests.
  tester.view.physicalSize = const Size(1000, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  // The memo is app-lifetime state; a stale one would leak between tests.
  HomeSectionsView.resetMemo();
  addTearDown(HomeSectionsView.resetMemo);

  final taps = _Taps();

  await tester.pumpWidget(
    AppState(
      cart: CartModel.forTest(),
      child: MaterialApp(
        onGenerateRoute: (s) {
          taps.routes.add(s.name ?? '');
          return MaterialPageRoute(
            settings: s,
            builder: (_) => const SizedBox.shrink(),
          );
        },
        home: Scaffold(
          body: HomeSectionsView(
            key: ValueKey('feed-${_pumpSeq++}'),
            loader: () async => HomeSections.fromMap(payload),
            onCategoryTap: taps.categories.add,
            // #638 — this file covers the sections themselves; the strip has
            // its own tests in company_notify_test.dart.
            notificationsLoader: () async => BackInStock.empty,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return taps;
}

void main() {
  setUp(() {
    CartModel.rpcTransport = (fn, params) async =>
        {'ok': true, 'message': '', 'cart': <String, dynamic>{}};
  });
  tearDown(() => CartModel.rpcTransport = null);

  group('the feed renders the payload, in the payload order', () {
    testWidgets('every valid section appears', (tester) async {
      await _pump(tester, _payload());

      expect(find.text('MOST ORDERED ON MEDIBO'), findsOneWidget);
      expect(find.text('EVERY THERAPEUTIC CLASS'), findsOneWidget);
      expect(find.text('TOP MANUFACTURERS'), findsOneWidget);
    });

    testWidgets('sections keep the backend order, top to bottom',
        (tester) async {
      await _pump(tester, _payload());

      double dy(String s) => tester.getTopLeft(find.text(s)).dy;

      expect(dy('MOST ORDERED ON MEDIBO'), lessThan(dy('EVERY THERAPEUTIC CLASS')),
          reason: 'best_sellers came first in the payload');
      expect(dy('EVERY THERAPEUTIC CLASS'), lessThan(dy('TOP MANUFACTURERS')),
          reason: 'shop_by_category came before shop_by_company');
    });

    testWidgets('subtitles and count labels are verbatim', (tester) async {
      await _pump(tester, _payload());

      expect(find.text('77,547 products'), findsOneWidget);
      expect(find.text('2,510 products'), findsOneWidget);
      expect(find.text('SUN PHARMACEUTICAL INDUSTRIES LTD'), findsOneWidget,
          reason: 'the company label is printed as sent, not prettified');
    });
  });

  group('forward compatibility', () {
    testWidgets('an unknown layout renders nothing and does not throw',
        (tester) async {
      await _pump(tester, _payload());

      expect(find.text('From the future'), findsNothing);
      expect(find.text('NOT IN THIS BUILD'), findsNothing,
          reason: 'no dangling header for a layout this build cannot paint');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a section with no items renders nothing', (tester) async {
      await _pump(tester, _payload());

      expect(find.text('Nothing here'), findsNothing);
      expect(find.text('EMPTY'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('ok:false shows the retry block, never a blank page or a throw',
        (tester) async {
      await _pump(tester, {'ok': false});

      expect(find.text('Retry'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('the accent word is located, not guessed', () {
    test('title splits around accent_word wherever it sits', () {
      HomeSection s(String title, String accent) => HomeSection(
            id: 'x',
            layout: HomeSectionLayout.rail,
            title: title,
            accentWord: accent,
            subtitle: '',
            seeAll: null,
            cards: const [],
            tiles: const [],
          );

      expect(s('Best Sellers', 'Best').titleParts, ('', 'Best', ' Sellers'));
      expect(s('Shop by category', 'category').titleParts,
          ('Shop by ', 'category', ''));
      expect(s('Anti Infectives', 'Anti').titleParts,
          ('', 'Anti', ' Infectives'));
    });

    test('an accent word that is absent or blank leaves the title plain', () {
      HomeSection s(String title, String accent) => HomeSection(
            id: 'x',
            layout: HomeSectionLayout.rail,
            title: title,
            accentWord: accent,
            subtitle: '',
            seeAll: null,
            cards: const [],
            tiles: const [],
          );

      expect(s('Best Sellers', '').titleParts, ('Best Sellers', '', ''));
      expect(s('Best Sellers', 'Nope').titleParts, ('Best Sellers', '', ''),
          reason: 'never emphasise a word the backend did not name');
    });

    testWidgets('both halves of the split title are on screen', (tester) async {
      await _pump(tester, _payload());
      // Text.rich renders one Text widget whose plain text is the whole title.
      expect(
        find.byWidgetPredicate((w) =>
            w is RichText && w.text.toPlainText() == 'Best Sellers'),
        findsOneWidget,
      );
    });
  });

  group('a rail card is the shared CompactProductCard', () {
    testWidgets('it prints pricing.price_display and availability.cta_label '
        'verbatim', (tester) async {
      await _pump(tester, _payload());

      expect(find.text('SyNtraN 200 Capsule'), findsOneWidget);
      expect(find.text('1 Strip'), findsWidgets);
      expect(find.text('₹236.20'), findsWidgets,
          reason: 'price_display verbatim — never mrp × (1 - pct)');
      expect(find.text('Add to cart'), findsOneWidget,
          reason: 'cta_label verbatim, only on the available card');
    });

    testWidgets('an unavailable card shows the backend cta state and offers no '
        'ADD', (tester) async {
      await _pump(tester, _payload());

      expect(find.text('Gone Forever Tablet'), findsOneWidget);
      expect(find.text('Unavailable'), findsOneWidget,
          reason: 'the sold-out chip is the backend label');
      // Exactly one cart control in the rail — for the one available card. The
      // sold-out card offers no path into the cart at all.
      //
      // #673 re-pointed this from OutlinedButton (the ADD pill stopped being
      // one) to CompactCartControl, which is the only widget in a card that can
      // write to the cart. Asserting on the button TYPE would now pass without
      // proving anything.
      expect(find.byType(CompactCartControl), findsOneWidget,
          reason: 'the sold-out card has no ADD control');
    });

    test('the mapping factory feeds the card the right fields', () {
      // Guards the rename trap: the home payload uses name/company/image/
      // pack_label/form_chip, NOT the MEDICINE row's key names.
      final p = HomeSections.fromMap(_payload()).sections.first.cards.first;

      expect(p.id, '252328');
      expect(p.name, 'SyNtraN 200 Capsule');
      expect(p.manufacturer, 'GLENMARK PHARMACEUTICALS LTD');
      expect(p.packSize, '1 Strip');
      expect(p.formChip, 'Strip');
      expect(p.pricing?.priceDisplay, '₹236.20');
      expect(p.availability?.ctaLabel, 'Add to cart');
    });
  });

  group('taps carry the backend key', () {
    testWidgets('a rail card opens /product/<its id>', (tester) async {
      final taps = await _pump(tester, _payload());

      await tester.tap(find.text('SyNtraN 200 Capsule'));
      await tester.pumpAndSettle();

      expect(taps.routes, contains('/product/252328'));
    });

    testWidgets('a category tile hands back key, not the pretty label',
        (tester) async {
      final taps = await _pump(tester, _payload());

      await tester.tap(find.text('Anti Infectives'));
      await tester.pumpAndSettle();

      expect(taps.categories, ['ANTI INFECTIVES'],
          reason: 'the raw category name is what the chips use');
    });

    // CHANGE #638 deliberately changed this protected behaviour: a company
    // tile used to hand its LABEL back for a search prefill, because no
    // company listing existed. One does now, so the tile opens /company/<key>
    // and the search fallback is gone.
    testWidgets('a company tile opens /company/<key>, url-encoded',
        (tester) async {
      final taps = await _pump(tester, _payload());

      await tester.tap(find.text('SUN PHARMACEUTICAL INDUSTRIES LTD'));
      await tester.pumpAndSettle();

      expect(taps.routes, contains('/company/sun%20pharmaceutical%20industries'),
          reason: 'the backend key, encoded — never the display label');
      expect(taps.companies, isEmpty,
          reason: 'the #637 search-prefill fallback is gone');
    });

    testWidgets('See-all uses the section is own destination', (tester) async {
      final taps = await _pump(tester, _payload());

      await tester.tap(find.text('See all'));
      await tester.pumpAndSettle();

      expect(taps.categories, ['All'], reason: 'see_all.key, verbatim');
    });

    testWidgets('a tile with no key is not tappable', (tester) async {
      final taps = await _pump(tester, _payload());

      await tester.tap(find.text('Cardiac'));
      await tester.pumpAndSettle();

      expect(taps.categories, isEmpty,
          reason: 'no key means no destination — the tile must do nothing');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a section with no see_all shows no See-all pill',
        (tester) async {
      await _pump(tester, _payload());
      // Exactly one See-all in the whole feed: only best_sellers carries one.
      expect(find.text('See all'), findsOneWidget);
    });

    testWidgets('the See-all pill prints see_all_label, not a Dart word',
        (tester) async {
      final p = _payload();
      (p['sections'] as List).first['see_all_label'] = 'Browse all 77,547';
      await _pump(tester, p);

      expect(find.text('Browse all 77,547'), findsOneWidget);
      expect(find.text('See all'), findsNothing,
          reason: 'rewording the pill is an UPDATE, never a deploy');
    });
  });

  group('the parser', () {
    test('drops unknown layouts and empty sections, keeps the rest in order',
        () {
      final s = HomeSections.fromMap(_payload());

      expect(s.ok, isTrue);
      expect(s.sections.map((e) => e.id).toList(),
          ['best_sellers', 'shop_by_category', 'shop_by_company'],
          reason: 'future_section and empty_rail are dropped at parse time');
    });

    test('ok:false yields no sections rather than throwing', () {
      final s = HomeSections.fromMap({'ok': false});
      expect(s.ok, isFalse);
      expect(s.sections, isEmpty);
    });

    test('a see_all missing its key is treated as no see_all', () {
      expect(SeeAll.fromMap({'type': 'category'}), isNull);
      expect(SeeAll.fromMap({'type': 'category', 'key': ''}), isNull);
      expect(SeeAll.fromMap(null), isNull);
      expect(SeeAll.fromMap({'type': 'category', 'key': 'All'})?.key, 'All');
    });
  });
}
