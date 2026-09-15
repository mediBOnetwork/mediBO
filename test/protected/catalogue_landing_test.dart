// PROTECTED — CMD #2020: the Catalogue landing's four blocks.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes landing behaviour, never to make an unrelated change go
// green.
//
// What this file holds down, and why each one is a bug worth a permanent test:
//
//   1. THE TILE IS PAINTED BY THE PAYLOAD. The gradient is two hex strings the
//      backend sent (app_settings.catalogue_landing), not a palette written in
//      Dart. A tile whose payload carries no gradient falls back to the brand
//      token — it never invents a colour and it never draws nothing.
//   2. THE PREVIEW IS RANKED AND WORDED IN SQL. The tile prints the items in
//      payload ORDER, prints their labels verbatim, and draws NOTHING for a
//      `kind` this build does not know — the same forward-compatible silence
//      the home feed gives an unknown layout.
//   3. FOUR TILES ARE ONE GRID. Every tile is the same height, whatever its
//      preview holds, and no label or count is ellipsised.
//   4. THE RAIL IS THE STOREFRONT CARD. Top selling draws CompactProductCard,
//      unchanged — one product card in this app, not three — and its NOTE is
//      the backend saying which ranking this is. An empty block draws nothing.
//   5. THE BANNER'S VISIBILITY IS `has`. A zone running no scheme sends
//      has:false and there is no banner at all; the app never infers it from a
//      count of zero, and never pluralises the count itself.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/app_state.dart';
import 'package:pharma_b2b/models/cart_model.dart';
import 'package:pharma_b2b/models/catalogue.dart';
import 'package:pharma_b2b/widgets/catalogue_landing.dart';
import 'package:pharma_b2b/widgets/compact_product_card.dart';

// ── fixtures ────────────────────────────────────────────────────────────────

Map<String, dynamic> _door(
  String key,
  String label, {
  Map<String, dynamic>? gradient,
  Map<String, dynamic>? preview,
}) => {
      'key': key,
      'kind': key,
      'tab': key,
      'label': label,
      'icon_key': 'store',
      'icon_letter': label.substring(0, 1),
      'count_label': '18,563 companies',
      if (gradient != null) 'gradient': gradient,
      if (preview != null) 'preview': preview,
    };

Map<String, dynamic> _grad(String from, String to) =>
    {'from': from, 'to': to, 'on': '#FFFFFF'};

Map<String, dynamic> _preview(String kind, List<String> labels) => {
      'kind': kind,
      'has': labels.isNotEmpty,
      'items': [
        for (final l in labels)
          {
            'key': l,
            'label': l,
            'letter': l.substring(0, 1).toUpperCase(),
            'tone': '#E8F3EC',
            'count_label': '12 products',
          },
      ],
    };

Map<String, dynamic> _card(String id, String name) => {
      'id': id,
      'name': name,
      'company': 'SUN PHARMA',
      'pack_label': '1 Strip',
      'availability': {
        'is_available': true,
        'can_add': true,
        'cta_label': 'Add to cart',
        'cta_short': 'ADD',
        'gated': true,
        'availability_label': 'In stock',
        'availability_tone': 'success',
      },
      'pricing': {
        'has_price': true,
        'price_display': '₹120.00',
        'card_price': {
          'has_mrp': true,
          'mrp_label': 'MRP',
          'mrp_display': '₹150.00',
          'strike_mrp': true,
          'has_ptr': true,
          'ptr_label': 'PTR',
          'ptr_display': '₹120.00',
          'price_display': '₹120.00',
          'price_locked': false,
          'sale_label': 'Sale price:',
          'has_note': false,
          'note': '',
        },
      },
    };

Future<void> _pump(WidgetTester tester, Widget child, {double width = 360}) async {
  await tester.pumpWidget(
    AppState(
      cart: CartModel.forTest(),
      child: MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(size: Size(width, 780)),
            child: SizedBox(width: width, child: child),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  setUp(() {
    CartModel.rpcTransport = (fn, params) async =>
        {'ok': true, 'message': '', 'cart': <String, dynamic>{}};
  });
  tearDown(() => CartModel.rpcTransport = null);

  group('the tile is painted by the payload', () {
    testWidgets('the gradient is the two hex strings that arrived', (tester) async {
      final doors = [
        CatDoor.fromMap(_door('companies', 'Company',
            gradient: _grad('#0E6B3A', '#1B7A43'))),
      ];
      await _pump(tester,
          CatalogueTiles(title: 'Browse by', doors: doors, onTap: (_) {}));

      final ink = tester.widget<Ink>(find.byType(Ink).first);
      final deco = ink.decoration as BoxDecoration;
      final grad = deco.gradient as LinearGradient;
      expect(grad.colors.first, const Color(0xFF0E6B3A));
      expect(grad.colors.last, const Color(0xFF1B7A43));
    });

    testWidgets('a payload with no gradient still draws a tile', (tester) async {
      final doors = [CatDoor.fromMap(_door('salts', 'Salt'))];
      await _pump(tester,
          CatalogueTiles(title: 'Browse by', doors: doors, onTap: (_) {}));
      expect(find.text('Salt'), findsOneWidget);
      expect(find.text('18,563 companies'), findsOneWidget);
    });

    testWidgets('tapping a tile hands back the door the backend sent',
        (tester) async {
      CatDoor? tapped;
      final doors = [CatDoor.fromMap(_door('companies', 'Company'))];
      await _pump(tester,
          CatalogueTiles(title: '', doors: doors, onTap: (d) => tapped = d));
      await tester.tap(find.text('Company'));
      await tester.pump();
      expect(tapped?.key, 'companies');
      expect(tapped?.tab, 'companies');
    });
  });

  group('the preview is ranked and worded in SQL', () {
    testWidgets('chips print in payload order, verbatim', (tester) async {
      final doors = [
        CatDoor.fromMap(_door('browse', 'Category',
            preview: _preview('chips', ['PAIN', 'GASTRO', 'CARDIAC']))),
      ];
      // Wide enough that all three chips are built: the property under test
      // is the ORDER they arrive in, not how many fit on a 360px tile.
      await _pump(tester,
          CatalogueTiles(title: '', doors: doors, onTap: (_) {}), width: 800);
      final x = (String s) => tester.getTopLeft(find.text(s)).dx;
      expect(x('PAIN') < x('GASTRO'), isTrue,
          reason: 'payload order, never a client-side sort');
      expect(x('GASTRO') < x('CARDIAC'), isTrue);
    });

    testWidgets('logos draw the backend letter, not the label', (tester) async {
      final doors = [
        CatDoor.fromMap(_door('companies', 'Company',
            preview: _preview('logos', ['Alkem', 'Cipla', 'Mankind', 'Sun']))),
      ];
      await _pump(tester,
          CatalogueTiles(title: '', doors: doors, onTap: (_) {}));
      for (final l in ['A', 'C', 'M', 'S']) {
        expect(find.text(l), findsOneWidget);
      }
      expect(find.text('Alkem'), findsNothing,
          reason: 'a logo disc prints the letter the backend derived');
    });

    testWidgets('names print two popular labels', (tester) async {
      final doors = [
        CatDoor.fromMap(_door('salts', 'Salt',
            preview: _preview('names', ['Paracetamol', 'Ibuprofen']))),
      ];
      await _pump(tester,
          CatalogueTiles(title: '', doors: doors, onTap: (_) {}));
      expect(find.text('Paracetamol'), findsOneWidget);
      expect(find.text('Ibuprofen'), findsOneWidget);
    });

    testWidgets('an unknown preview kind draws nothing and does not throw',
        (tester) async {
      final doors = [
        CatDoor.fromMap(_door('salts', 'Salt',
            preview: _preview('carousel_v9', ['Paracetamol']))),
      ];
      await _pump(tester,
          CatalogueTiles(title: '', doors: doors, onTap: (_) {}));
      expect(find.text('Salt'), findsOneWidget);
      expect(find.text('Paracetamol'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('four tiles are one grid', () {
    for (final w in [360.0, 412.0]) {
      testWidgets('every tile is the same height at ${w.toInt()}px', (tester) async {
        final doors = [
          CatDoor.fromMap(_door('companies', 'Company',
              gradient: _grad('#0E6B3A', '#1B7A43'),
              preview: _preview('logos', ['Alkem', 'Cipla', 'Mankind', 'Sun']))),
          CatDoor.fromMap(_door('salts', 'Salt',
              preview: _preview('names', ['Paracetamol', 'Ibuprofen']))),
          CatDoor.fromMap(_door('conditions', 'Use',
              preview: _preview('names', ['Fever']))),
          CatDoor.fromMap(_door('browse', 'Category',
              preview: _preview('chips', ['PAIN', 'GASTRO', 'CARDIAC']))),
        ];
        await _pump(tester,
            CatalogueTiles(title: 'Browse by', doors: doors, onTap: (_) {}),
            width: w);

        final heights = tester
            .renderObjectList<RenderBox>(find.byType(Ink))
            .map((b) => b.size.height)
            .toList();
        expect(heights.length, 4);
        for (final h in heights) {
          expect(h, heights.first, reason: 'a 2×2 grid is four equal tiles');
        }
        expect(tester.takeException(), isNull, reason: 'no overflow at ${w}px');
      });
    }

    testWidgets('no label or count is ellipsised', (tester) async {
      final doors = [
        CatDoor.fromMap(_door('companies', 'Company',
            preview: _preview('logos', ['Alkem']))),
      ];
      await _pump(tester,
          CatalogueTiles(title: '', doors: doors, onTap: (_) {}));
      final label = tester.widget<Text>(find.text('Company'));
      final count = tester.widget<Text>(find.text('18,563 companies'));
      expect(label.overflow, isNot(TextOverflow.ellipsis));
      expect(count.overflow, isNot(TextOverflow.ellipsis));
    });
  });

  group('the top-selling rail is the storefront card', () {
    testWidgets('it draws CompactProductCard and the backend note',
        (tester) async {
      final block = CatTopSelling.fromMap({
        'has': true,
        'title': 'Top selling',
        'note': 'What pharmacies near you order most',
        'items': [_card('1', 'Dolo 650 Tablet'), _card('2', 'Pan 40 Tablet')],
      });
      await _pump(tester,
          CatalogueTopSellingRail(block: block, onTap: (_) {}));
      expect(find.text('Top selling'), findsOneWidget);
      expect(find.text('What pharmacies near you order most'), findsOneWidget);
      expect(find.byType(CompactProductCard), findsWidgets);
    });

    testWidgets('has:false draws no rail at all', (tester) async {
      final block = CatTopSelling.fromMap({
        'has': false,
        'title': 'Top selling',
        'note': '',
        'items': <Map<String, dynamic>>[],
      });
      await _pump(tester,
          CatalogueTopSellingRail(block: block, onTap: (_) {}));
      expect(find.text('Top selling'), findsNothing);
      expect(find.byType(CompactProductCard), findsNothing);
    });
  });

  group("the banner's visibility is `has`", () {
    testWidgets('a promo with has:true prints title, subtitle and count',
        (tester) async {
      final promo = CatPromo.fromMap({
        'has': true,
        'key': 'schemes',
        'list_kind': 'tab',
        'list_key': 'schemes',
        'title': 'Schemes & offers',
        'subtitle': 'Extra units on selected packs',
        'count_label': '412 products',
        'action_label': 'View all',
        'gradient': _grad('#7A1F3D', '#B02E57'),
      });
      var taps = 0;
      await _pump(tester,
          CataloguePromoBanner(promo: promo, onTap: () => taps++));
      expect(find.text('Schemes & offers'), findsOneWidget);
      expect(find.text('Extra units on selected packs'), findsOneWidget);
      expect(find.text('412 products'), findsOneWidget);
      await tester.tap(find.text('Schemes & offers'));
      await tester.pump();
      expect(taps, 1);
    });

    testWidgets('has:false draws no banner, whatever else arrived',
        (tester) async {
      final promo = CatPromo.fromMap({
        'has': false,
        'title': 'Schemes & offers',
        'subtitle': 'Extra units on selected packs',
        'count_label': '0 products',
        'gradient': _grad('#7A1F3D', '#B02E57'),
      });
      await _pump(tester,
          CataloguePromoBanner(promo: promo, onTap: () {}));
      expect(find.text('Schemes & offers'), findsNothing);
      expect(find.text('0 products'), findsNothing);
    });
  });

  group('the landing payload carries its own decisions', () {
    test('an empty trail is what hides the breadcrumb on the landing', () {
      final home = CatHome.fromMap({
        'ok': true,
        'trail': {'label': 'You are here', 'separator': '›', 'items': []},
        'doors': <Map<String, dynamic>>[],
      });
      expect(home.trail.isEmpty, isTrue);
      expect(home.trail.separator, '›',
          reason: 'the trail block still arrived — only its steps are empty');
    });

    test('chips are the backend list, not the tab strip', () {
      final home = CatHome.fromMap({
        'ok': true,
        'chips': [
          {'key': 'cold_chain', 'label': 'Cold chain', 'kind': 'list',
           'list_kind': 'tab', 'list_key': 'cold_chain',
           'count_label': '18 products'},
        ],
      });
      expect(home.chips.length, 1);
      expect(home.chips.single.key, 'cold_chain');
      expect(home.chips.single.countLabel, '18 products');
    });
  });
}
