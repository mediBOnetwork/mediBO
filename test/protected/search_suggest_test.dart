// PROTECTED — CHANGE #790. Catalogue search: typeahead + the synonym console.
//
// What this file holds down:
//
//   * the typeahead computes NOTHING. Groups render in payload order with the
//     backend's own titles; every label, sub-label and "N variants" counter is
//     a string from search_suggest(); a tap hands back the payload's `query`
//     (for a Hindi word that is the SALT, never the word the shopper typed);
//   * "not enough letters" is `ready:false` plus the backend's sentence, never
//     a length test written here, and an empty result prints the backend's
//     empty line;
//   * the Hinglish line is `expanded.label` under `expanded_prefix` — absent
//     when the backend sent no mapping;
//   * the brand-family card GROUPS NOTHING. `storefront_search_page()` hands
//     the grid a `blocks` list already folded by brand_family_key(); the card
//     prints the block's title, "by <company>" line and "N variants" counter
//     verbatim, draws one chip per variant in payload order, and a chip opens
//     THAT variant's own product id. A block kind this build has never heard
//     of renders nothing instead of throwing;
//   * the synonym console prints the payload: rows in payload order with the
//     backend's own "term → target" subtitle and source label, the two
//     dropdowns offer exactly the options the payload carried, and a refusal
//     (ok:false) renders the backend's message and no list.
//
// No network, no Supabase: every RPC is a mocked payload.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/search_synonyms_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/search_family_card.dart';
import 'package:pharma_b2b/widgets/search_typeahead.dart';

Map<String, dynamic> _suggest({bool hinglish = false}) => {
      'ok': true,
      'ready': true,
      'q': hinglish ? 'bukhar' : 'montic',
      'hint': '',
      'empty_label': 'No matches yet — press search to look through the full catalogue',
      'expanded_prefix': 'Searching for',
      'expanded': hinglish
          ? const {
              'has': true,
              'term': 'bukhar',
              'display': 'bukhar',
              'target': 'Paracetamol',
              'label': 'bukhar → Paracetamol',
            }
          : const {'has': false},
      'zone': const {'on': true, 'zone_id': 1, 'note': 'Suggestions from what your zone can send'},
      // Deliberately NOT alphabetical: the order is the backend's.
      'groups': const [
        {
          'kind': 'brand',
          'title': 'Brands',
          'items': [
            {
              'kind': 'brand',
              'key': 'monticope|mankind',
              'label': 'Monticope Tablet',
              'sub_label': 'by MANKIND PHARMA LTD',
              'count_label': '12 variants',
              'query': 'Monticope Tablet',
              'n': 12,
            },
            {
              'kind': 'brand',
              'key': 'montus|elkos',
              'label': 'Montus-L Syrup',
              'sub_label': 'by ELKOS HEALTHCARE PVT LTD',
              'count_label': '5 variants',
              'query': 'Montus-L Syrup',
              'n': 5,
            },
          ],
        },
        {
          'kind': 'salt',
          'title': 'Salts',
          'items': [
            {
              'kind': 'salt',
              'key': 'montelukast',
              'label': 'Montelukast',
              'sub_label': '',
              'count_label': '842 products',
              // the salt's own query, which is NOT its label by accident
              'query': 'Montelukast',
              'n': 842,
            },
          ],
        },
      ],
    };

Map<String, dynamic> _synonyms({bool ok = true}) => ok
    ? {
        'ok': true,
        'title': 'Search synonyms',
        'subtitle': 'What a shopper types, and the salt or class it should search for.',
        'empty_note': 'No synonyms yet.',
        'add_label': 'Add synonym',
        'save_label': 'Save',
        'delete_label': 'Delete',
        'term_label': 'What they type',
        'term_hint': 'bukhar',
        'target_label': 'What to search for',
        'target_hint': 'Paracetamol',
        'lang_label': 'Language',
        'kind_label': 'Match as',
        'active_label': 'Active',
        'count_label': '2 synonyms',
        'lang_options': const [
          {'key': 'hi', 'label': 'Hindi / Hinglish'},
          {'key': 'en', 'label': 'English'},
        ],
        'kind_options': const [
          {'key': 'salt', 'label': 'Salt'},
          {'key': 'category', 'label': 'Category'},
        ],
        'rows': const [
          {
            'term': 'bukhar',
            'display': 'bukhar',
            'lang': 'hi',
            'target_kind': 'salt',
            'target': 'Paracetamol',
            'active': true,
            'source': 'seed',
            'source_label': 'Seeded',
            'subtitle': 'bukhar → Paracetamol',
          },
          {
            'term': 'khansi',
            'display': 'khansi',
            'lang': 'hi',
            'target_kind': 'category',
            'target': 'Cough',
            'active': true,
            'source': 'admin',
            'source_label': 'Edited by staff',
            'subtitle': 'khansi → Cough',
          },
        ],
      }
    : {
        'ok': false,
        'error': 'not_authorized',
        'title': 'Search synonyms',
        'message': 'Only mediBO staff can edit search synonyms.',
      };

Map<String, dynamic> _familyBlock() => {
      'kind': 'family',
      'family_key': 'monticope|mankind',
      'title': 'Monticope',
      'company_label': 'MANKIND PHARMA LTD',
      'sub_label': 'by MANKIND PHARMA LTD',
      'variant_count': 3,
      'count_label': '3 variants',
      // deliberately NOT alphabetical: the order is the backend's
      'variants': const [
        {'id': 501, 'product_name': 'Monticope Tablet', 'variant_label': 'Tablet'},
        {'id': 502, 'product_name': 'Monticope-A Tablet', 'variant_label': '-A Tablet'},
        {'id': 503, 'product_name': 'Monticope Syrup', 'variant_label': 'Syrup'},
      ],
    };

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);
  tearDown(() {
    SearchSynonymsScreen.rpcTransport = null;
    SearchSuggestController.rpcTransport = null;
  });

  group('the typeahead prints the payload', () {
    testWidgets('groups render in payload order with the backend titles',
        (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SearchSuggestions(payload: _suggest(), onPick: (_) {}),
        ),
      ));
      await t.pumpAndSettle();

      expect(find.text('Brands'), findsOneWidget);
      expect(find.text('Salts'), findsOneWidget);
      // Brands is drawn above Salts because the PAYLOAD put it first.
      expect(t.getTopLeft(find.text('Brands')).dy,
          lessThan(t.getTopLeft(find.text('Salts')).dy));

      // every counter is the backend's sentence, never built from `n`
      expect(find.text('12 variants'), findsOneWidget);
      expect(find.text('5 variants'), findsOneWidget);
      expect(find.text('842 products'), findsOneWidget);
      expect(find.text('by MANKIND PHARMA LTD'), findsOneWidget);
      // the raw counts are never printed on their own
      expect(find.text('12'), findsNothing);
      expect(find.text('842'), findsNothing);
    });

    testWidgets('a tap hands back the payload query, not the label',
        (t) async {
      String? picked;
      final p = _suggest(hinglish: true);
      // The salt group's query is what a Hindi word must search for.
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SearchSuggestions(payload: p, onPick: (q) => picked = q),
        ),
      ));
      await t.pumpAndSettle();

      await t.tap(find.text('Montelukast'));
      await t.pumpAndSettle();
      expect(picked, 'Montelukast');
    });

    testWidgets('the Hinglish line is the backend sentence, under its prefix',
        (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SearchSuggestions(
              payload: _suggest(hinglish: true), onPick: (_) {}),
        ),
      ));
      await t.pumpAndSettle();
      expect(find.text('Searching for bukhar → Paracetamol'), findsOneWidget);
    });

    testWidgets('no mapping draws no Hinglish line at all', (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(body: SearchSuggestions(payload: _suggest(), onPick: (_) {})),
      ));
      await t.pumpAndSettle();
      expect(find.textContaining('Searching for'), findsNothing);
    });

    testWidgets('ready:false prints the backend hint and no groups', (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SearchSuggestions(payload: const {
            'ok': true,
            'ready': false,
            'hint': 'Type at least 2 letters to see suggestions',
            'groups': [],
          }, onPick: (_) {}),
        ),
      ));
      await t.pumpAndSettle();
      expect(find.text('Type at least 2 letters to see suggestions'),
          findsOneWidget);
      expect(find.text('Brands'), findsNothing);
    });

    testWidgets('no matches prints the backend empty line', (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SearchSuggestions(payload: const {
            'ok': true,
            'ready': true,
            'groups': [],
            'empty_label': 'No matches yet — press search to look through the full catalogue',
          }, onPick: (_) {}),
        ),
      ));
      await t.pumpAndSettle();
      expect(
          find.text(
              'No matches yet — press search to look through the full catalogue'),
          findsOneWidget);
    });
  });

  group('the family card groups nothing', () {
    testWidgets('title, company line and counter are backend strings',
        (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 320,
            child: SearchFamilyCard(
                block: _familyBlock(), onOpenProduct: (_) {}),
          ),
        ),
      ));
      await t.pumpAndSettle();

      expect(find.text('Monticope'), findsOneWidget);
      expect(find.text('by MANKIND PHARMA LTD'), findsOneWidget);
      expect(find.text('3 variants'), findsOneWidget);
      // the raw count is never printed on its own
      expect(find.text('3'), findsNothing);
    });

    testWidgets('one chip per variant, in payload order, opening its own id',
        (t) async {
      String? opened;
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 320,
            child: SearchFamilyCard(
                block: _familyBlock(), onOpenProduct: (id) => opened = id),
          ),
        ),
      ));
      await t.pumpAndSettle();

      expect(find.text('Tablet'), findsOneWidget);
      expect(find.text('-A Tablet'), findsOneWidget);
      expect(find.text('Syrup'), findsOneWidget);
      // payload order, not alphabetical
      expect(t.getTopLeft(find.text('Tablet')).dx,
          lessThan(t.getTopLeft(find.text('-A Tablet')).dx));

      // the SECOND chip opens the second variant's own product, not the card's
      await t.tap(find.text('-A Tablet'));
      await t.pumpAndSettle();
      expect(opened, '502');
    });

    testWidgets('a block kind this build never heard of renders nothing',
        (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SearchResultBlock(
            block: const {'kind': 'something_new_from_the_backend'},
            onOpenProduct: (_) {},
          ),
        ),
      ));
      await t.pumpAndSettle();
      expect(tester_findsNoText(t), isTrue);
    });

    testWidgets('a product block draws the product card the grid always used',
        (t) async {
      var built = 0;
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SearchResultBlock(
            block: const {
              'kind': 'product',
              'item': {'id': 77, 'product_name': 'Solo product'},
            },
            onOpenProduct: (_) {},
            productFor: (m) {
              built++;
              return Text('${m['product_name']}');
            },
          ),
        ),
      ));
      await t.pumpAndSettle();
      expect(built, 1);
      expect(find.text('Solo product'), findsOneWidget);
    });
  });

  group('the synonym console prints the payload', () {
    testWidgets('rows render in payload order with the backend subtitles',
        (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(body: SynonymsView(payload: _synonyms())),
      ));
      await t.pumpAndSettle();

      expect(find.text('2 synonyms'), findsOneWidget);
      expect(find.text('bukhar → Paracetamol'), findsOneWidget);
      expect(find.text('khansi → Cough'), findsOneWidget);
      expect(find.text('Seeded'), findsOneWidget);
      expect(find.text('Edited by staff'), findsOneWidget);
      expect(t.getTopLeft(find.text('bukhar → Paracetamol')).dy,
          lessThan(t.getTopLeft(find.text('khansi → Cough')).dy));
    });

    testWidgets('the dropdowns offer only what the payload sent', (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(body: SynonymEditSheet(payload: _synonyms())),
      ));
      await t.pumpAndSettle();

      // Open the language dropdown by its own widget, not by its label.
      await t.tap(find.byType(DropdownButtonFormField<String>).first);
      await t.pumpAndSettle();
      expect(find.text('Hindi / Hinglish'), findsWidgets);
      expect(find.text('English'), findsWidgets);
      // 'Brand' is a real option of the OTHER dropdown in production, but this
      // payload did not send it, so it is nowhere on the screen.
      expect(find.text('Brand'), findsNothing);
      await t.tapAt(const Offset(10, 10)); // dismiss the menu
      await t.pumpAndSettle();

      // The match-kind dropdown offers exactly its own two payload options.
      await t.tap(find.byType(DropdownButtonFormField<String>).last);
      await t.pumpAndSettle();
      expect(find.text('Salt'), findsWidgets);
      expect(find.text('Category'), findsWidgets);
      expect(find.text('Brand'), findsNothing);
    });

    testWidgets('a refusal prints the backend message and no rows', (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(body: SynonymsView(payload: _synonyms(ok: false))),
      ));
      await t.pumpAndSettle();
      expect(find.text('Only mediBO staff can edit search synonyms.'),
          findsOneWidget);
      expect(find.text('bukhar → Paracetamol'), findsNothing);
    });
  });
}

/// True when the pumped tree painted no text at all — the honest way to assert
/// "this rendered nothing" without naming a string that was never there.
bool tester_findsNoText(WidgetTester t) =>
    find.byType(Text).evaluate().isEmpty;
