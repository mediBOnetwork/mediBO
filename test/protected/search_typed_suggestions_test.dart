// PROTECTED — CMD #1905. A search suggestion carries a TYPE and an ID.
//
// The bug this file retires: typing "sun pharma" and tapping the company row
// "SUN PHARMACEUTICAL IND… 2461 products" pasted that company NAME into a
// product-name search. Nothing is named that, so the shopper who had just
// been shown a company with 2,461 products got "Nothing here in this view."
// and a button offering to REQUEST the product. Salts broke the same way.
// Brands only looked fine because a brand name is a prefix of its own
// products' names, which is a coincidence and not a design.
//
// What this file holds down:
//
//   1. A TAP IS TYPED. The panel hands back the whole item, and `navKind` /
//      `navId` are read out of the payload's `nav` block — never re-derived
//      from the label, the key or the query.
//   2. A PAYLOAD WITHOUT `nav` STILL WORKS, and claims only what it knew: it
//      falls back to a text search, because that is the only thing the old
//      contract ever meant.
//   3. "See all" IS THE GROUP'S OWN NAV. It appears only when the backend
//      said `has:true`, and it carries the group's `see_all.nav`, not the
//      first item's.
//   4. THE CHIP IS THE BACKEND'S SENTENCE. `chip_label` is printed verbatim;
//      the app never assembles "Company: " + a name.
//   5. GROUPS ARE DRAWN IN PAYLOAD ORDER with the backend's own titles, and
//      the count of rows drawn is the count the payload sent — no client-side
//      cap, no client-side sort, so "max 3 with a See all" is a backend
//      decision that can be tuned without a deploy.
//   6. THE EMPTY STATE'S WAYS OUT ARE THE PAYLOAD'S `buttons`, IN ORDER, with
//      the backend's own tone. "Clear filters" leads when filters are on;
//      "Request this product" is absent unless the payload sent it, which is
//      how a navigated scope (a company, a salt, a class) stops offering it.
//   7. A PRE-#1905 PAYLOAD keeps its old two-button behaviour exactly — the
//      compat shim reproduces the old order, it does not invent the new one.
//
// No network, no Supabase: every payload is a fixture.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/models/catalogue.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/search_typeahead.dart';

/// The real shape of `search_suggest('sun pharma')`, taken from the branch.
/// Deliberately NOT alphabetical and deliberately not sorted by count:
/// AYURSUN PHARMA has the highest rank in the cache and still comes last,
/// because a substring can never outrank a prefix.
Map<String, dynamic> _payload() => {
      'ok': true,
      'ready': true,
      'q': 'sun pharma',
      'hint': '',
      'clear_label': 'Clear',
      'empty_label': '',
      'expanded': const {'has': false},
      'zone': const {'on': false, 'zone_id': null, 'note': ''},
      'groups': const [
        {
          'kind': 'product',
          'title': 'Products',
          'items': [
            {
              'kind': 'product',
              'key': 'sun pharma|sun pharmaceutical industries',
              'id': '900201',
              'label': 'Sun Pharma Diclofenac 50mg Tablet',
              'sub_label': 'by SUN PHARMACEUTICAL INDUSTRIES LTD',
              'count_label': '4 variants',
              'n': 4,
              'query': 'Sun Pharma Diclofenac 50mg Tablet',
              'chip_label': 'Product: Sun Pharma Diclofenac 50mg Tablet',
              'nav': {
                'kind': 'product',
                'id': '900201',
                'title': 'Sun Pharma Diclofenac 50mg Tablet'
              },
            },
          ],
          'see_all': {
            'has': false,
            'label': 'See all',
            'nav': {'kind': 'search', 'id': 'sun pharma', 'title': 'sun pharma'},
          },
        },
        {
          'kind': 'company',
          'title': 'Companies',
          'items': [
            {
              'kind': 'company',
              'key': 'sun pharmaceutical industries',
              'id': 'sun pharmaceutical industries',
              'label': 'SUN PHARMACEUTICAL INDUSTRIES LTD',
              'sub_label': '',
              'count_label': '2461 products',
              'n': 2461,
              'query': 'SUN PHARMACEUTICAL INDUSTRIES LTD',
              'chip_label': 'Company: SUN PHARMACEUTICAL INDUSTRIES LTD',
              'nav': {
                'kind': 'company',
                'id': 'sun pharmaceutical industries',
                'title': 'SUN PHARMACEUTICAL INDUSTRIES LTD'
              },
            },
            {
              'kind': 'company',
              'key': 'sun pharma laboratories',
              'id': 'sun pharma laboratories',
              'label': 'SUN PHARMA LABORATORIES LTD',
              'sub_label': '',
              'count_label': '800 products',
              'n': 800,
              'query': 'SUN PHARMA LABORATORIES LTD',
              'chip_label': 'Company: SUN PHARMA LABORATORIES LTD',
              'nav': {
                'kind': 'company',
                'id': 'sun pharma laboratories',
                'title': 'SUN PHARMA LABORATORIES LTD'
              },
            },
            {
              'kind': 'company',
              'key': 'ayursun pharma',
              'id': 'ayursun pharma',
              'label': 'AYURSUN PHARMA',
              'sub_label': '',
              'count_label': '30 products',
              'n': 30,
              'query': 'AYURSUN PHARMA',
              'chip_label': 'Company: AYURSUN PHARMA',
              'nav': {
                'kind': 'company',
                'id': 'ayursun pharma',
                'title': 'AYURSUN PHARMA'
              },
            },
          ],
          'see_all': {
            'has': true,
            'label': 'See all',
            'nav': {'kind': 'tab', 'tab': 'companies', 'query': 'sun pharma'},
          },
        },
        {
          'kind': 'salt',
          'title': 'Salts',
          'items': [
            {
              'kind': 'salt',
              'key': 'Montelukast (10mg)',
              'id': 'Montelukast (10mg)',
              'label': 'Montelukast (10mg)',
              'sub_label': '',
              'count_label': '842 products',
              'n': 842,
              'query': 'Montelukast (10mg)',
              'chip_label': 'Salt: Montelukast (10mg)',
              'nav': {
                'kind': 'salt',
                'id': 'Montelukast (10mg)',
                'title': 'Montelukast (10mg)'
              },
            },
          ],
          'see_all': {
            'has': false,
            'label': 'See all',
            'nav': {'kind': 'tab', 'tab': 'salts', 'query': 'sun pharma'},
          },
        },
        {
          'kind': 'category',
          'title': 'Categories',
          'items': [
            {
              'kind': 'category',
              'key': 'RESPIRATORY',
              'id': 'RESPIRATORY',
              'label': 'RESPIRATORY',
              'sub_label': '',
              'count_label': '120 products',
              'n': 120,
              'query': 'RESPIRATORY',
              'chip_label': 'Category: RESPIRATORY',
              'nav': {
                'kind': 'category',
                'id': 'RESPIRATORY',
                'title': 'RESPIRATORY'
              },
            },
          ],
          'see_all': {
            'has': false,
            'label': 'See all',
            'nav': {'kind': 'tab', 'tab': 'browse', 'query': ''},
          },
        },
      ],
    };

/// A mutable deep copy, so a test may strip a key the fixture declared const.
Map<String, dynamic> _mutable(Map<String, dynamic> m) =>
    jsonDecode(jsonEncode(m)) as Map<String, dynamic>;

/// The panel is a scroller with its own maxHeight. A row below the fold is
/// not hittable, and that is a property of the test surface, not of the
/// widget — so the surface is made tall enough to hold the whole payload and
/// every row is tapped where it really is.
Future<SearchSuggestion?> _tap(WidgetTester t, String text,
    {Map<String, dynamic>? payload}) async {
  SearchSuggestion? picked;
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: SearchSuggestions(
            payload: payload ?? _payload(),
            maxHeight: 4000,
            onPick: (s) => picked = s),
      ),
    ),
  ));
  await t.pumpAndSettle();
  await t.scrollUntilVisible(find.text(text), 200,
      scrollable: find.byType(Scrollable).first);
  await t.pumpAndSettle();
  await t.tap(find.text(text));
  await t.pumpAndSettle();
  return picked;
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('a tap is typed, and opens what the backend named', () {
    testWidgets('a company hands back kind company and the company key',
        (t) async {
      final s = await _tap(t, 'SUN PHARMACEUTICAL INDUSTRIES LTD');
      expect(s, isNotNull);
      expect(s!.navKind, 'company');
      expect(s.navId, 'sun pharmaceutical industries');
      // The old contract — the visible NAME — is still on the value, and is
      // still not what routing reads. That distinction is the whole fix.
      expect(s.query, 'SUN PHARMACEUTICAL INDUSTRIES LTD');
      expect(s.navId, isNot(s.query));
    });

    testWidgets('a product hands back a product id, not its name', (t) async {
      final s = await _tap(t, 'Sun Pharma Diclofenac 50mg Tablet');
      expect(s!.navKind, 'product');
      expect(s.navId, '900201');
    });

    testWidgets('a salt hands back the salt key', (t) async {
      final s = await _tap(t, 'Montelukast (10mg)');
      expect(s!.navKind, 'salt');
      expect(s.navId, 'Montelukast (10mg)');
    });

    testWidgets('a category hands back the class key', (t) async {
      final s = await _tap(t, 'RESPIRATORY');
      expect(s!.navKind, 'category');
      expect(s.navId, 'RESPIRATORY');
    });

    testWidgets('a payload with no nav block falls back to a text search',
        (t) async {
      final p = _mutable(_payload());
      // Strip every nav — this is what a cached pre-#1905 payload looks like.
      for (final g in p['groups'] as List) {
        for (final it in (g as Map)['items'] as List) {
          (it as Map).remove('nav');
        }
      }
      final s = await _tap(t, 'SUN PHARMACEUTICAL INDUSTRIES LTD', payload: p);
      expect(s!.navKind, 'search');
      expect(s.navId, 'SUN PHARMACEUTICAL INDUSTRIES LTD');
    });
  });

  group('See all is the group own nav', () {
    testWidgets('it is drawn only for the group whose payload said has:true',
        (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SearchSuggestions(
                payload: _payload(), maxHeight: 4000, onPick: (_) {}),
          ),
        ),
      ));
      await t.pumpAndSettle();
      // Four groups, one `has:true` — so exactly one row, never four.
      expect(find.text('See all'), findsOneWidget);
    });

    testWidgets('tapping it carries the group nav, not the first item',
        (t) async {
      final s = await _tap(t, 'See all');
      expect(s!.navKind, 'tab');
      expect(s.navTab, 'companies');
      expect(s.navQuery, 'sun pharma');
      // A scope is not one named thing, so it claims no chip.
      expect(s.chipLabel, '');
    });
  });

  group('the chip is the backend sentence', () {
    testWidgets('chip_label is carried verbatim off the tapped item',
        (t) async {
      final s = await _tap(t, 'SUN PHARMACEUTICAL INDUSTRIES LTD');
      expect(s!.chipLabel, 'Company: SUN PHARMACEUTICAL INDUSTRIES LTD');
    });

    testWidgets('the box prints the chip and its clear label, nothing else',
        (t) async {
      var cleared = 0;
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SearchBoxChip(
            chip: const SearchChip(
                label: 'Company: Sun Pharmaceutical', clearLabel: 'Clear'),
            onClear: () => cleared++,
          ),
        ),
      ));
      await t.pumpAndSettle();
      expect(find.text('Company: Sun Pharmaceutical'), findsOneWidget);
      // No prefix is assembled here: "Company:" exists only inside that one
      // backend string.
      expect(find.text('Company'), findsNothing);
      await t.tap(find.text('Company: Sun Pharmaceutical'));
      await t.pumpAndSettle();
      expect(cleared, 1);
    });

    testWidgets('an empty chip has nothing to show', (t) async {
      expect(SearchChip.none.has, isFalse);
    });
  });

  group('groups render in payload order, at the payload count', () {
    testWidgets('Products above Companies above Salts', (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SearchSuggestions(
                payload: _payload(), maxHeight: 4000, onPick: (_) {}),
          ),
        ),
      ));
      await t.pumpAndSettle();
      final products = t.getTopLeft(find.text('Products')).dy;
      final companies = t.getTopLeft(find.text('Companies')).dy;
      final salts = t.getTopLeft(find.text('Salts')).dy;
      expect(products, lessThan(companies));
      expect(companies, lessThan(salts));
    });

    testWidgets('the cap is the backend, so every sent row is drawn',
        (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SearchSuggestions(
                payload: _payload(), maxHeight: 4000, onPick: (_) {}),
          ),
        ),
      ));
      await t.pumpAndSettle();
      // Three companies were sent; three are drawn. Nothing here trims to a
      // number of its own, which is how the cap stays a setting.
      expect(find.text('SUN PHARMACEUTICAL INDUSTRIES LTD'), findsOneWidget);
      expect(find.text('SUN PHARMA LABORATORIES LTD'), findsOneWidget);
      expect(find.text('AYURSUN PHARMA'), findsOneWidget);
    });

    testWidgets('a substring never outranks a prefix', (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SearchSuggestions(
                payload: _payload(), maxHeight: 4000, onPick: (_) {}),
          ),
        ),
      ));
      await t.pumpAndSettle();
      // AYURSUN PHARMA carries the highest rank in the cache and 30 products;
      // both Sun Pharma rows are prefixes of the query and sit above it. The
      // panel does not sort — it prints the order it was handed, which is
      // where that rule is enforced.
      expect(t.getTopLeft(find.text('SUN PHARMACEUTICAL INDUSTRIES LTD')).dy,
          lessThan(t.getTopLeft(find.text('AYURSUN PHARMA')).dy));
      expect(t.getTopLeft(find.text('SUN PHARMA LABORATORIES LTD')).dy,
          lessThan(t.getTopLeft(find.text('AYURSUN PHARMA')).dy));
    });
  });

  group('the empty state offers exactly what the payload offered', () {
    test('a typed query with zero matches offers Request', () {
      final e = CatEmptyState.fromMap(const {
        'label': 'No product matches “zzzznonsense”.',
        'hint': 'Check the spelling, or try a shorter word.',
        'action': {'has': true, 'kind': 'request', 'label': 'Request this product'},
        'clear': {'has': false, 'kind': 'clear_filters', 'label': 'Clear all'},
        'buttons': [
          {'kind': 'request', 'tone': 'primary', 'label': 'Request this product'}
        ],
      });
      expect(e.label, 'No product matches “zzzznonsense”.');
      expect(e.buttons.map((b) => b.kind).toList(), ['request']);
      expect(e.buttons.single.tone, 'primary');
    });

    test('a navigated scope offers nothing to request', () {
      // This is the bug's other half: a company page that is empty must not
      // offer to request the catalogue the shopper asked to see.
      final e = CatEmptyState.fromMap(const {
        'label': 'Nothing in sun pharmaceutical industries right now.',
        'hint': '',
        'action': {'has': false, 'kind': 'request', 'label': 'Request this product'},
        'clear': {'has': false, 'kind': 'clear_filters', 'label': 'Clear all'},
        'buttons': [],
      });
      expect(e.buttons, isEmpty);
      expect(e.label, contains('sun pharmaceutical industries'));
    });

    test('with filters on, Clear leads and Request follows', () {
      final e = CatEmptyState.fromMap(const {
        'label': 'Nothing in zzzznonsense matches these filters.',
        'hint': '',
        'action': {'has': true, 'kind': 'request', 'label': 'Request this product'},
        'clear': {'has': true, 'kind': 'clear_filters', 'label': 'Clear all'},
        'buttons': [
          {'kind': 'clear_filters', 'tone': 'primary', 'label': 'Clear all'},
          {'kind': 'request', 'tone': 'secondary', 'label': 'Request this product'},
        ],
      });
      expect(e.buttons.map((b) => b.kind).toList(),
          ['clear_filters', 'request']);
      expect(e.buttons.first.tone, 'primary');
      expect(e.buttons.last.tone, 'secondary');
    });

    test('a payload with no buttons keeps the OLD order exactly', () {
      // Compat, not a second opinion: before #1905 the action was drawn first
      // and the clear under it, so that is what a payload without `buttons`
      // still gets.
      final e = CatEmptyState.fromMap(const {
        'label': 'Nothing matches these filters. Clear one and try again.',
        'hint': '',
        'action': {'has': true, 'kind': 'request', 'label': 'Request this product'},
        'clear': {'has': true, 'kind': 'clear_filters', 'label': 'Clear all'},
      });
      expect(e.buttons.map((b) => b.kind).toList(),
          ['request', 'clear_filters']);
    });
  });
}
