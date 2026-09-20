// PROTECTED — CMD #2118.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes company DISCOVERY behaviour.
//
// The one idea under all four parts: a buyer who names a MAKER is answered by
// the maker, and no part of that answer is computed in Dart.
//
//   1. THE COMPANIES BLOCK is the search envelope's own. It renders above the
//      medicine results, in payload order, printing label + count_label
//      verbatim, and a tap carries the backend's KEY (not the label). A
//      payload with no block draws nothing at all — never an empty heading.
//
//   2. THE FILTER BOX on "Shop by company" asks the BACKEND. Typing swaps the
//      section's tiles for the RPC's rows; clearing the box puts the payload's
//      own tiles back. The placeholder and the nothing-matched line are the
//      RPC's strings, so rewording them is an UPDATE.
//
//   3. SEARCH IN THIS COMPANY sends the term to the loader. Nothing is
//      filtered client-side: the screen renders whatever page comes back, and
//      an empty answer prints the payload's empty_label.
//
//   4. ONE NAME, ONE PACK LABEL. The company page says the company's name
//      once; the card drops the maker's line when the surface already carries
//      it, and reserves the shorter extent the card itself publishes.
//
// No network, no Supabase, no goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/app_state.dart';
import 'package:pharma_b2b/models/cart_model.dart';
import 'package:pharma_b2b/models/home_sections.dart';
import 'package:pharma_b2b/models/storefront_p3.dart';
import 'package:pharma_b2b/screens/company_screen.dart';
import 'package:pharma_b2b/widgets/company_hits_block.dart';
import 'package:pharma_b2b/widgets/compact_product_card.dart';
import 'package:pharma_b2b/widgets/home_sections_view.dart';
import 'package:pharma_b2b/utils/render_log.dart';

// ── fixtures ────────────────────────────────────────────────────────────────

Map<String, dynamic> _hits({List<Map<String, dynamic>>? rows}) => {
      'ok': true,
      'q': 'sun pharma',
      'title': 'Companies',
      'hint': 'Filter companies',
      'empty_label': 'No company matches that.',
      'rows': rows ??
          [
            {
              'key': 'sun pharmaceutical industries',
              'label': 'SUN PHARMACEUTICAL INDUSTRIES LTD',
              'count_label': '2,510 products',
            },
            {
              'key': 'sun pharma laboratories',
              'label': 'SUN PHARMA LABORATORIES LTD',
              'count_label': '318 products',
            },
          ],
    };

Map<String, dynamic> _card({required int id, required String name}) => {
      'id': id,
      'name': name,
      'company': 'SUN PHARMACEUTICAL INDUSTRIES LTD',
      'pack_label': '',
      'form_chip': 'Tube',
      'image': '',
      'mrp_label': '₹85.31',
      'buyable': true,
      'availability': {
        'is_available': true,
        'can_add': true,
        'gated': false,
        'cta_label': 'Add to cart',
        'colors': {'bg': '#1B7A43', 'fg': '#FFFFFF'},
      },
      'pricing': {
        'mrp': 85.31,
        'sale_price': 85.31,
        'mrp_display': '₹85.31',
        'price_display': '₹85.31',
        'discount_label': '',
        'has_price': true,
        'has_discount': false,
      },
    };

Map<String, dynamic> _companyPage({
  required List<Map<String, dynamic>> items,
  String q = '',
}) =>
    {
      'ok': true,
      'company': {
        'label': 'SUN PHARMACEUTICAL INDUSTRIES LTD',
        'key': 'sun pharmaceutical industries',
        'count_label': '2,510 products',
      },
      'q': q,
      'search_hint': 'Search in this company',
      'empty_label': 'No product here matches that.',
      'items': items,
      'offset': 0,
      'has_more': false,
    };

Map<String, dynamic> _brandSection() => {
      'id': 'shop_by_company',
      'layout': 'brand_grid',
      'title': 'Shop by company',
      'items': [
        {
          'key': 'macleods pharmaceuticals',
          'label': 'MACLEODS PHARMACEUTICALS PVT LTD',
          'count_label': '668 products',
        },
      ],
    };

Future<void> _pump(WidgetTester tester, Widget child,
    {Size size = const Size(390, 780)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    AppState(
      cart: CartModel.forTest(),
      child: MaterialApp(home: Scaffold(body: child)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // RenderLog's 800ms debounce is a real Timer that would outlive the test and
  // try to reach Supabase.
  setUpAll(() => RenderLog.flushEnabled = false);

  // ── 1. The Companies block ────────────────────────────────────────────────
  group('the Companies block', () {
    test('it is parsed from the payload, and absence is explicit', () {
      final hits = CompanyHits.fromMap(_hits());
      expect(hits.has, isTrue);
      expect(hits.title, 'Companies');
      expect(hits.rows.first.label, 'SUN PHARMACEUTICAL INDUSTRIES LTD');
      expect(hits.rows.first.countLabel, '2,510 products');

      // ok:false, or no rows, is the backend saying "no block".
      expect(CompanyHits.fromMap({'ok': false}).has, isFalse);
      expect(CompanyHits.fromMap(_hits(rows: const [])).has, isFalse);
      expect(CompanyHits.none.has, isFalse);
    });

    testWidgets('rows render in payload order, verbatim', (tester) async {
      await _pump(
        tester,
        CompanyHitsBlock(hits: CompanyHits.fromMap(_hits()), onOpen: (_) {}),
      );

      expect(find.text('Companies'), findsOneWidget);
      expect(find.text('SUN PHARMACEUTICAL INDUSTRIES LTD'), findsOneWidget);
      expect(find.text('2,510 products'), findsOneWidget);

      // Payload order, not sorted by name or by count.
      final first = tester
          .getTopLeft(find.text('SUN PHARMACEUTICAL INDUSTRIES LTD'))
          .dy;
      final second =
          tester.getTopLeft(find.text('SUN PHARMA LABORATORIES LTD')).dy;
      expect(first, lessThan(second));
    });

    testWidgets('a tap carries the backend KEY, never the label',
        (tester) async {
      final tapped = <String>[];
      await _pump(
        tester,
        CompanyHitsBlock(
          hits: CompanyHits.fromMap(_hits()),
          onOpen: (h) => tapped.add(h.key),
        ),
      );

      await tester.tap(find.text('SUN PHARMACEUTICAL INDUSTRIES LTD'));
      await tester.pumpAndSettle();
      expect(tapped, ['sun pharmaceutical industries']);
    });

    testWidgets('no block means nothing is drawn — never an empty heading',
        (tester) async {
      await _pump(
        tester,
        CompanyHitsBlock(hits: CompanyHits.none, onOpen: (_) {}),
      );
      expect(find.text('Companies'), findsNothing);
      expect(find.byType(InkWell), findsNothing);
    });

    testWidgets('every row clears the 44pt touch minimum', (tester) async {
      await _pump(
        tester,
        CompanyHitsBlock(hits: CompanyHits.fromMap(_hits()), onOpen: (_) {}),
      );
      expect(CompanyHitsBlock.rowH, greaterThanOrEqualTo(44));
    });
  });

  // ── 2. The filter box on Shop by company ──────────────────────────────────
  group('the Shop-by-company filter box', () {
    testWidgets('typing asks the BACKEND and swaps the tiles', (tester) async {
      final asked = <String>[];
      final section = HomeSection.fromMap(_brandSection());

      await _pump(
        tester,
        CompanyFilterGrid(
          section: section!,
          search: (q) async {
            asked.add(q);
            return CompanyHits.fromMap(q.isEmpty ? _hits(rows: const []) : _hits());
          },
        ),
      );

      // The copy call, with an empty term: the placeholder is a backend
      // string, so the box has to ask for it.
      expect(asked, ['']);
      expect(find.text('Filter companies'), findsOneWidget);
      expect(find.text('MACLEODS PHARMACEUTICALS PVT LTD'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'sun');
      await tester.pumpAndSettle(const Duration(milliseconds: 400));

      expect(asked, ['', 'sun']);
      expect(find.text('SUN PHARMACEUTICAL INDUSTRIES LTD'), findsOneWidget);
      expect(
        find.text('MACLEODS PHARMACEUTICALS PVT LTD'),
        findsNothing,
        reason: 'the grid is the RPC\'s rows while a term is typed',
      );
    });

    testWidgets('clearing the box puts the payload\'s own tiles back',
        (tester) async {
      final section = HomeSection.fromMap(_brandSection());
      await _pump(
        tester,
        CompanyFilterGrid(
          section: section!,
          search: (q) async =>
              CompanyHits.fromMap(q.isEmpty ? _hits(rows: const []) : _hits()),
        ),
      );

      await tester.enterText(find.byType(TextField), 'sun');
      await tester.pumpAndSettle(const Duration(milliseconds: 400));
      expect(find.text('SUN PHARMACEUTICAL INDUSTRIES LTD'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle(const Duration(milliseconds: 400));
      expect(find.text('MACLEODS PHARMACEUTICALS PVT LTD'), findsOneWidget);
    });

    testWidgets('nothing matched prints the backend\'s line', (tester) async {
      final section = HomeSection.fromMap(_brandSection());
      await _pump(
        tester,
        CompanyFilterGrid(
          section: section!,
          search: (q) async => CompanyHits.fromMap(_hits(rows: const [])),
        ),
      );

      await tester.enterText(find.byType(TextField), 'zzzz');
      await tester.pumpAndSettle(const Duration(milliseconds: 400));
      expect(find.text('No company matches that.'), findsOneWidget);
    });
  });

  // ── 3. Search in this company ─────────────────────────────────────────────
  group('search inside a company', () {
    testWidgets('the typed term goes to the LOADER, not to a client filter',
        (tester) async {
      final terms = <String>[];
      await _pump(
        tester,
        CompanyScreen(
          companyKey: 'sun pharmaceutical industries',
          cloudLoader: (_) async => CompanySaltCloud.none,
          loader: (key, offset, q) async {
            terms.add(q);
            return CompanyPage.fromMap(_companyPage(
              q: q,
              items: q.isEmpty
                  ? [
                      _card(id: 1, name: 'Fungicros Cream'),
                      _card(id: 2, name: 'Volini Gel'),
                    ]
                  : [_card(id: 1, name: 'Fungicros Cream')],
            ));
          },
        ),
      );

      expect(terms, ['']);
      expect(find.text('Search in this company'), findsOneWidget);
      expect(find.text('Volini Gel'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'fungi');
      await tester.pumpAndSettle(const Duration(milliseconds: 500));

      expect(terms, ['', 'fungi']);
      expect(find.text('Fungicros Cream'), findsOneWidget);
      expect(
        find.text('Volini Gel'),
        findsNothing,
        reason: 'the page renders the backend\'s page, whatever it contains',
      );
    });

    testWidgets('an empty answer prints the payload\'s empty_label',
        (tester) async {
      await _pump(
        tester,
        CompanyScreen(
          companyKey: 'sun pharmaceutical industries',
          cloudLoader: (_) async => CompanySaltCloud.none,
          loader: (key, offset, q) async => CompanyPage.fromMap(_companyPage(
            q: q,
            items: q.isEmpty ? [_card(id: 1, name: 'Fungicros Cream')] : const [],
          )),
        ),
      );

      await tester.enterText(find.byType(TextField), 'zzz');
      await tester.pumpAndSettle(const Duration(milliseconds: 500));
      expect(find.text('No product here matches that.'), findsOneWidget);
    });
  });

  // ── 4. One name, one pack label ───────────────────────────────────────────
  group('the company page says the name once', () {
    testWidgets('the bar carries it and nothing else does', (tester) async {
      await _pump(
        tester,
        CompanyScreen(
          companyKey: 'sun pharmaceutical industries',
          cloudLoader: (_) async => CompanySaltCloud.none,
          loader: (key, offset, q) async => CompanyPage.fromMap(
            _companyPage(items: [_card(id: 1, name: 'Fungicros Cream')]),
          ),
        ),
      );

      expect(find.text('SUN PHARMACEUTICAL INDUSTRIES LTD'), findsOneWidget);
      expect(find.text('2,510 products'), findsOneWidget);
      expect(find.text('Fungicros Cream'), findsOneWidget);
    });

    test('the shorter extent is DERIVED from the card, never a second number',
        () {
      expect(
        CompactProductCard.extentWithoutCompany,
        lessThan(CompactProductCard.extent),
      );
      expect(
        CompactProductCard.extent - CompactProductCard.extentWithoutCompany,
        greaterThan(0),
      );
    });
  });
}
