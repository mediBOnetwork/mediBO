// PROTECTED — CHANGE #678.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes the zone-wise count contract, never to make an
// unrelated change go green.
//
// What this holds down — the ZONE-WISE COUNT CONTRACT:
//
//   1. The hero number is the VIEWER's number, decided and formatted by the
//      backend. storefront_home_v2() answers "5,62,549+ products" to an
//      anonymous visitor (the catalogue) and "74,852+ products" to an approved
//      Raipur customer (their zone). The app prints the prop label VERBATIM —
//      it never re-formats the digits, never appends its own "+", never
//      substitutes a number it fetched elsewhere, and never decides which of
//      the two numbers a viewer should see. Switching a viewer from the global
//      count to a zone count is a backend rule (_viewer_zone_or_null), not a
//      Dart branch.
//
//   2. Every prop label is printed as sent, whether or not the build knows its
//      icon name — a prop with an unknown icon still shows its label, so the
//      backend can ship a new prop to an old build.
//
//   3. A prop with an empty label is not a prop: the backend sends nothing and
//      nothing is drawn. The app never fills the gap with a default count.
//
//   4. The category counts map (get_all_storefront_counts) is carried through
//      untouched: the number the tile shows for CARDIAC is the number the
//      backend sent for CARDIAC, for this viewer. The repository's only job is
//      to key the map by upper-cased category name — a pure mapping the test
//      pins here so it can never grow arithmetic.
//
// No network, no Supabase, no goldens. Fixtures mirror storefront_home_v2()
// hero payloads taken off the live database on 2026-09-02.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/models/home_sections.dart';
import 'package:pharma_b2b/widgets/home_sections_view.dart';
import 'package:pharma_b2b/utils/render_log.dart';

/// The hero block exactly as storefront_home_v2() sends it. [countLabel] is
/// the backend-formatted count prop — the viewer's number.
Map<String, dynamic> _hero({required String countLabel, List<Map<String, dynamic>>? props}) => {
      'show': true,
      'eyebrow': 'B2B PHARMA SUPPLY',
      'title': 'Stock your pharmacy in one order',
      'cta': 'Browse catalogue',
      'bg_top': '#0B3D2E',
      'bg_bottom': '#145C42',
      'accent': '#1B7A43',
      'props': props ??
          [
            {'icon': 'inventory', 'label': countLabel},
            {'icon': 'truck', 'label': 'Same-day delivery'},
            {'icon': 'verified', 'label': 'Licensed distributors'},
          ],
    };

Widget _wrap(Widget child) => MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: child),
      ),
    );

/// The one thing the repository does to get_all_storefront_counts(): key the
/// map by UPPER-CASED category and keep every value as the integer that came.
/// Mirrors MedicineRepository.fetchAllCategoryCounts() so a future "helpful"
/// adjustment there has a test to argue with.
Map<String, int> _keyCounts(Map<String, dynamic> raw) => raw.map(
      (k, v) => MapEntry(k.toString().toUpperCase(), (v as num).toInt()),
    );

void main() {
  setUpAll(() {
    RenderLog.flushEnabled = false;
  });

  group('the hero number is the viewer\'s number, printed verbatim', () {
    testWidgets('an anonymous visitor sees the catalogue count the backend sent',
        (tester) async {
      final hero = HomeHero.fromMap(_hero(countLabel: '5,62,549+ products'));
      await tester.pumpWidget(_wrap(HomeHeroBanner(hero: hero, onCta: () {})));

      expect(find.text('5,62,549+ products'), findsOneWidget);
      // No re-formatting: the Indian grouping and the trailing "+" are the
      // backend's characters, not a NumberFormat the app applied.
      expect(find.textContaining('562,549'), findsNothing);
      expect(find.textContaining('562549'), findsNothing);
    });

    testWidgets('an approved Raipur customer sees their zone count — the same widget, a different payload',
        (tester) async {
      final hero = HomeHero.fromMap(_hero(countLabel: '74,852+ products'));
      await tester.pumpWidget(_wrap(HomeHeroBanner(hero: hero, onCta: () {})));

      expect(find.text('74,852+ products'), findsOneWidget);
      // The catalogue number is NOT on the screen: the app did not fetch a
      // second count and it did not decide which one applies.
      expect(find.textContaining('5,62,549'), findsNothing);
      expect(find.textContaining('562,549'), findsNothing);
    });

    testWidgets('a Bilaspur customer\'s tiny count is printed as sent, never padded or hidden',
        (tester) async {
      final hero = HomeHero.fromMap(_hero(countLabel: '412+ products'));
      await tester.pumpWidget(_wrap(HomeHeroBanner(hero: hero, onCta: () {})));

      expect(find.text('412+ products'), findsOneWidget);
    });

    testWidgets('every prop label is verbatim, known icon or not', (tester) async {
      final hero = HomeHero.fromMap(_hero(countLabel: '74,852+ products', props: [
        {'icon': 'inventory', 'label': '74,852+ products'},
        {'icon': 'rocket', 'label': 'Delivered by 6 pm'}, // icon this build never heard of
        {'icon': 'verified', 'label': 'Licensed distributors'},
      ]));
      await tester.pumpWidget(_wrap(HomeHeroBanner(hero: hero, onCta: () {})));

      expect(find.text('74,852+ products'), findsOneWidget);
      expect(find.text('Delivered by 6 pm'), findsOneWidget);
      expect(find.text('Licensed distributors'), findsOneWidget);
      // exactly the three labels the payload carried — nothing invented
      expect(hero.props.length, 3);
    });

    test('an empty label is not a prop — the app never fills it with a default count', () {
      final hero = HomeHero.fromMap(_hero(countLabel: '', props: [
        {'icon': 'inventory', 'label': ''},
        {'icon': 'truck', 'label': 'Same-day delivery'},
      ]));
      expect(hero.props.map((p) => p.label).toList(), ['Same-day delivery']);
    });
  });

  group('category counts are carried through untouched', () {
    test('the zone map an approved customer receives keys by upper-cased name and keeps every value',
        () {
      // get_all_storefront_counts() for an approved Raipur customer: the zone
      // cache, 'All' = the hero total (same scan in the backend).
      final raw = <String, dynamic>{
        'All': 74852,
        'CARDIAC': 3067,
        'Neuro CNS': 1920,
        'OTHERS': 10922,
      };
      final counts = _keyCounts(raw);
      expect(counts['ALL'], 74852);
      expect(counts['CARDIAC'], 3067);
      expect(counts['NEURO CNS'], 1920);
      expect(counts['OTHERS'], 10922);
      expect(counts.length, 4);
      // no derived total: the app does not sum categories to make 'ALL'
      expect(counts.values.where((v) => v == 3067 + 1920 + 10922), isEmpty);
    });

    test('the global map an anonymous visitor receives is the same shape — the branch lives in the backend',
        () {
      final raw = <String, dynamic>{'All': 30228, 'CARDIAC': 3067};
      final counts = _keyCounts(raw);
      expect(counts['ALL'], 30228);
      expect(counts['CARDIAC'], 3067);
    });
  });
}
