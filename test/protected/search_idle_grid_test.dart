// PROTECTED — CMD #2044. The focused search screen is never blank, and every
// product surface draws the SAME card in the SAME grid.
//
// What this file holds down:
//
//   1. **Focused-and-empty is a PAYLOAD, not a blank page.** `search_idle()`
//      returns an ordered list of blocks; [SearchIdleView] draws them in the
//      order they arrived, with the backend's own titles, and draws NOTHING
//      for a `kind` this build does not know (forward compatibility — a
//      fourth block ships as an INSERT, never a deploy). No blocks at all is
//      the backend's `empty_label`, never a sentence written in Dart.
//
//   2. **A chip is a query.** Tapping one reports `chip.q` verbatim — the
//      field the backend sent to SEARCH for, which is not always the label it
//      sent to PRINT. The block's own control reports `action_kind`.
//
//   3. **One grid, everywhere.** [ProductCardGrid] is the only product grid
//      left: CMD #1903's row card is deleted, so search results, the
//      catalogue inner pages, the company page, the idle rail and Home all
//      draw [CompactProductCard]. The grid injects routing and nothing else —
//      the price, the MRP, the PTR and the ADD word stay the card's payload.
//
//   4. **The column count is measured, not typed.** `columnsFor` derives the
//      count from the card's own rail width plus one gap, so a phone gets 2, a
//      tablet 3 and a desktop 4-6 without three breakpoints to keep in step,
//      and it never returns fewer than 2 (a list row) at any width.
//
// No network, no Supabase: fabricated payloads only.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/app_state.dart';
import 'package:pharma_b2b/models/cart_model.dart';
import 'package:pharma_b2b/models/search_page.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/card_layout.dart';
import 'package:pharma_b2b/widgets/compact_product_card.dart';
import 'package:pharma_b2b/widgets/product_card_grid.dart';
import 'package:pharma_b2b/widgets/search_surface.dart';

/// One `search_idle().blocks[].items[]` card — the home-card shape every
/// product surface already renders.
Map<String, dynamic> _card(String id, String name) => {
      'id': id,
      'name': name,
      'company': 'MANKIND PHARMA LTD',
      'image': '',
      'pack_label': 'Strip of 10 tablets',
      'pack_qty_label': '10.0 Tablets in 1 strip',
      'pack_type_label': 'Strip',
      'form_chip': 'Strip',
      'rx': {'is_rx': true, 'label': 'Rx'},
      'availability': {
        'is_available': true,
        'can_add': true,
        'cta_label': 'Add to cart',
        'cta_short': 'ADD',
      },
      'pricing': {
        'has_price': true,
        'mrp': 174.38,
        'sale_price': 152.40,
        'price_display': '₹152.40',
        'mrp_display': '₹174.38',
        'card_price': {
          'has_mrp': true,
          'mrp_label': 'MRP',
          'mrp_display': '₹174.38',
          'strike_mrp': true,
          'has_ptr': true,
          'ptr_label': 'PTR',
          'ptr_display': '₹152.40',
          'price_display': '₹152.40',
          'price_locked': false,
          'has_note': false,
          'note': '',
        },
      },
    };

/// The payload as `search_idle()` actually returns it: recent first, then
/// popular, then the rail — and one block this build has never heard of.
Map<String, dynamic> _idle({bool withUnknown = true, bool empty = false}) => {
      'ok': true,
      'has': !empty,
      'empty_label': 'Type a medicine, salt or company name to search.',
      'blocks': empty
          ? <Map<String, dynamic>>[]
          : [
              {
                'kind': 'recent',
                'title': 'Recent searches',
                'action_label': 'Clear',
                'action_kind': 'clear_recent',
                'chips': [
                  // label and q deliberately differ: printing the label but
                  // searching for it would be a bug this catches.
                  {'label': 'monticope', 'sub_label': '', 'q': 'monticope lc'},
                ],
              },
              if (withUnknown)
                {
                  'kind': 'a_block_from_2027',
                  'title': 'Block this build cannot draw',
                  'action_label': '',
                  'action_kind': '',
                  'chips': <Map<String, dynamic>>[],
                },
              {
                'kind': 'suggest',
                'title': 'Popular searches',
                'action_label': '',
                'action_kind': '',
                'chips': [
                  {'label': 'Mankind', 'sub_label': 'company', 'q': 'Mankind'},
                ],
              },
              {
                'kind': 'rail',
                'title': 'Top sellers near you',
                'action_label': '',
                'action_kind': '',
                'items': [_card('1', 'Monticope Tablet'), _card('2', 'Dolo 650')],
              },
            ],
    };

Future<void> _pumpIdle(
  WidgetTester tester,
  Map<String, dynamic> map, {
  ValueChanged<String>? onPickQuery,
  ValueChanged<String>? onAction,
  ValueChanged<String>? onOpenProduct,
  double width = 390,
}) async {
  await tester.pumpWidget(
    AppState(
      cart: CartModel.forTest(),
      child: MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: width,
            child: SingleChildScrollView(
              child: SearchIdleView(
                payload: SearchIdlePayload.fromMap(map),
                onPickQuery: onPickQuery ?? (_) {},
                onOpenProduct: onOpenProduct ?? (_) {},
                onAction: onAction,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('the focused search screen is the backend\'s payload', () {
    testWidgets('blocks render in payload order with the backend\'s titles',
        (tester) async {
      await _pumpIdle(tester, _idle());

      for (final title in const [
        'Recent searches',
        'Popular searches',
        'Top sellers near you',
      ]) {
        expect(find.text(title), findsOneWidget,
            reason: '$title is the backend\'s word, printed verbatim');
      }

      // ORDER is the payload's, not alphabetical and not grouped by kind.
      double y(String t) => tester.getTopLeft(find.text(t)).dy;
      expect(y('Recent searches'), lessThan(y('Popular searches')));
      expect(y('Popular searches'), lessThan(y('Top sellers near you')));
    });

    testWidgets('a kind this build cannot draw is skipped, not guessed at',
        (tester) async {
      await _pumpIdle(tester, _idle());
      expect(find.text('Block this build cannot draw'), findsNothing,
          reason: 'an unknown block costs nothing — a 4th block is an INSERT');
    });

    testWidgets('no blocks prints the backend empty line, never a blank page',
        (tester) async {
      await _pumpIdle(tester, _idle(empty: true));
      expect(find.byKey(const Key('c2044_idle_empty')), findsOneWidget);
      expect(find.text('Type a medicine, salt or company name to search.'),
          findsOneWidget);
      expect(find.byType(CompactProductCard), findsNothing);
    });

    testWidgets('a chip reports q verbatim, not the label it printed',
        (tester) async {
      final picked = <String>[];
      await _pumpIdle(tester, _idle(), onPickQuery: picked.add);

      await tester.tap(find.text('monticope'));
      await tester.pump();
      expect(picked, ['monticope lc'],
          reason: 'q is what is searched; label is only what is printed');
    });

    testWidgets('the block control reports its own action_kind', (tester) async {
      final fired = <String>[];
      await _pumpIdle(tester, _idle(), onAction: fired.add);

      await tester.tap(find.text('Clear'));
      await tester.pump();
      expect(fired, ['clear_recent']);

      // Only the block that SENT a control has one.
      expect(find.widgetWithText(TextButton, 'Clear'), findsOneWidget);
    });

    testWidgets('the rail is the shared grid, never a list row', (tester) async {
      await _pumpIdle(tester, _idle());
      expect(find.byType(ProductCardGrid), findsOneWidget);
      expect(find.byType(CompactProductCard), findsNWidgets(2));
      expect(find.text('Monticope Tablet'), findsOneWidget);
      expect(find.text('₹152.40'), findsWidgets,
          reason: 'the price is the payload\'s string, computed nowhere here');
    });
  });

  group('one grid, and its column count is measured from the card', () {
    // Spec item 3 asked for '2 phone, 3 tablet, 4-5 desktop — the grid Home
    // already uses at that width'. Home's own rule was
    // ((w - 32 + 12) / 168).clamp(2, 6), which is 4 at 768 and 6 at 1280, so
    // the item's two halves disagreed. The reference wins (decision logged on
    // #2044): the card's image plate is a FIXED 152pt height, so a tile wide
    // enough to force 3-up on a tablet letterboxes the artwork. Phone — the
    // 99% — is 2 either way.
    test('2 up on a phone, more as the viewport grows, never more than 6', () {
      // The grid's own maxWidth, i.e. AFTER the 16pt page padding.
      expect(ProductCardGrid.columnsFor(360 - 32), 2, reason: '360pt phone');
      expect(ProductCardGrid.columnsFor(412 - 32), 2, reason: '412pt phone');
      expect(ProductCardGrid.columnsFor(480 - 32), 2, reason: 'large phone');
      expect(ProductCardGrid.columnsFor(768 - 32), greaterThanOrEqualTo(3),
          reason: 'a tablet fits more than a phone');
      expect(ProductCardGrid.columnsFor(1280 - 48), greaterThanOrEqualTo(4),
          reason: 'desktop');
      expect(ProductCardGrid.columnsFor(4000), 6,
          reason: 'clamped — a card never becomes a hairline');
    });

    test('the count is the one Home was already using at that width', () {
      // Home's pre-#2044 rule, kept here as the thing the shared grid must
      // not drift from. If someone retunes the grid, this is the test that
      // says Home and the catalogue just stopped matching.
      int home(double w) => ((w - 32 + 12) / 168.0).floor().clamp(2, 6);
      for (final w in const [328.0, 380.0, 448.0, 736.0, 1232.0]) {
        expect(ProductCardGrid.columnsFor(w), home(w),
            reason: 'width $w: the grid and Home must agree');
      }
    });

    test('never a single column — a list row is not a state this grid has', () {
      for (final w in const [200.0, 280.0, 320.0, 360.0, 390.0, 412.0, 480.0]) {
        expect(ProductCardGrid.columnsFor(w), greaterThanOrEqualTo(2),
            reason: '$w must still be two cards across, never one row');
      }
    });

    test('CMD #2167 — the skeleton reserves the CARD it will become', () {
      // The real grid reserves nothing any more (its rows measure their
      // cards). What is left with an extent is the skeleton, and its extent
      // is the card's own square plate plus the card's own body — never a
      // number typed in a screen.
      final l = CardLayout.fallback;
      final d = ProductCardGrid.delegateFor(360 - 32, l)
          as SliverGridDelegateWithFixedCrossAxisCount;
      expect(d.mainAxisExtent,
          l.cardWidth(360 - 32) + CompactProductCard.bodyV6);
      expect(d.crossAxisCount, ProductCardGrid.columnsFor(360 - 32, l));
      expect(d.crossAxisSpacing, l.gridGap);
    });

    testWidgets('the grid injects routing and nothing else', (tester) async {
      final opened = <String>[];
      await _pumpIdle(tester, _idle(), onOpenProduct: opened.add);

      await tester.tap(find.text('Dolo 650'));
      await tester.pump();
      expect(opened, ['2'], reason: 'the card carries the id; the grid routes');
    });
  });
}
