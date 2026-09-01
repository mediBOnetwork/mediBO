// CHANGE #414 — the reorder screen and the margin strip decide nothing.
//
// The whole value of both features is that a number on screen is TRUE: an
// owner acts on "finishes Thursday" and on "₹2.10 more margin". So what these
// tests hold down is that neither widget ever produces such a number itself —
// it prints what the backend sent, and prints nothing when the backend sent
// nothing.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/pharmacy/pharmacy_reorder_screen.dart';
import 'package:pharma_b2b/screens/pharmacy/pos_margin_strip.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

Map<String, dynamic> _reorderPayload({List<Map<String, dynamic>>? rows}) => {
      'ok': true,
      'title': 'What to reorder',
      'subtitle': 'Worked out from what actually sold at your counter.',
      'empty': 'Nothing is running low.',
      'add_all_label': 'Add all to cart',
      'window_label': 'Measure sales over',
      'cover_label': 'Order enough for',
      'window_display': '30 days',
      'cover_display': '14 days',
      'groups': const [
        {'key': 'urgent', 'label': 'Running out now', 'tone': 'danger'},
        {'key': 'soon', 'label': 'Running out this week', 'tone': 'warning'},
        {'key': 'later', 'label': 'Watch these', 'tone': 'info'},
      ],
      'rows': rows ??
          [
            {
              'medicine_id': 11,
              'product_name': 'Dolo 650',
              'group_key': 'urgent',
              'stockout_label': 'Finishes Thursday',
              'stock_label': 'In stock',
              'stock_display': '9',
              'velocity_label': 'Selling',
              'velocity_display': '3/day',
              'suggest_label': 'Suggested',
              'suggest_qty': 33,
              'add_label': 'Add to cart',
            },
          ],
    };

Map<String, dynamic> _marginPayload({List<Map<String, dynamic>>? rows}) => {
      'ok': true,
      'has': true,
      'title': 'Same salt, better margin',
      'subtitle': 'Also on your shelf right now.',
      'for_medicine_id': 11,
      'for_name': 'Dolo 650',
      'self_has_margin': true,
      'self_margin_display': '₹3.00',
      'rows': rows ??
          [
            {
              'medicine_id': 22,
              'product_name': 'Cipmol 650',
              'company': 'Cipla',
              'stock_display': '20 in stock',
              'has_margin': true,
              'margin_label': 'Your margin',
              'margin_display': '₹5.10',
              'delta_display': '₹2.10 more margin',
              'delta': 2.10,
              'swap_label': 'Use this',
            },
          ],
    };

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('reorder screen', () {
    testWidgets('the stockout sentence is the backend\'s, never a date Dart formatted',
        (tester) async {
      await tester.pumpWidget(_host(PharmacyReorderView(
        payload: _reorderPayload(),
        onAdd: (_) {},
        onAddAll: () {},
        onDraftAction: (_) {},
      )));

      expect(find.text('Finishes Thursday'), findsOneWidget);
      expect(find.text('Dolo 650'), findsOneWidget);
      // the group HEADING is the payload's, matched by the row's own group_key
      expect(find.text('Running out now'), findsOneWidget);
      // and a section with no rows is not drawn at all
      expect(find.text('Watch these'), findsNothing);
      expect(find.text('Suggested 33'), findsOneWidget);
      expect(find.text('Selling 3/day'), findsOneWidget);
    });

    testWidgets('rows are grouped by the payload\'s key, in the payload\'s order',
        (tester) async {
      await tester.pumpWidget(_host(PharmacyReorderView(
        payload: _reorderPayload(rows: [
          {
            'medicine_id': 1,
            'product_name': 'Later Item',
            'group_key': 'later',
            'stockout_label': 'Finishes 20 Sep',
            'stock_label': 'In stock',
            'stock_display': '40',
            'velocity_label': 'Selling',
            'velocity_display': '1/day',
            'suggest_label': 'Suggested',
            'suggest_qty': 2,
            'add_label': 'Add to cart',
          },
          {
            'medicine_id': 2,
            'product_name': 'Urgent Item',
            'group_key': 'urgent',
            'stockout_label': 'Finishes tomorrow',
            'stock_label': 'In stock',
            'stock_display': '2',
            'velocity_label': 'Selling',
            'velocity_display': '2/day',
            'suggest_label': 'Suggested',
            'suggest_qty': 26,
            'add_label': 'Add to cart',
          },
        ]),
        onAdd: (_) {},
        onAddAll: () {},
        onDraftAction: (_) {},
      )));

      final texts = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .whereType<String>()
          .toList();
      // 'urgent' comes first in `groups`, so it is drawn first — even though
      // the row arrived second. The ORDER is the payload's, not the list's.
      expect(texts.indexOf('Urgent Item') < texts.indexOf('Later Item'), isTrue);
      expect(texts.indexOf('Running out now') < texts.indexOf('Watch these'),
          isTrue);
    });

    testWidgets('a row whose group the build has never heard of is still shown',
        (tester) async {
      await tester.pumpWidget(_host(PharmacyReorderView(
        payload: _reorderPayload(rows: [
          {
            'medicine_id': 3,
            'product_name': 'Future Bucket Item',
            'group_key': 'brand_new_bucket',
            'stockout_label': 'Finishes Friday',
            'stock_label': 'In stock',
            'stock_display': '5',
            'velocity_label': 'Selling',
            'velocity_display': '1/day',
            'suggest_label': 'Suggested',
            'suggest_qty': 9,
            'add_label': 'Add to cart',
          },
        ]),
        onAdd: (_) {},
        onAddAll: () {},
        onDraftAction: (_) {},
      )));

      // A SKU about to run out must never vanish because a bucket was renamed.
      expect(find.text('Future Bucket Item'), findsOneWidget);
      expect(find.text('Finishes Friday'), findsOneWidget);
    });

    testWidgets('the empty state is the backend\'s sentence', (tester) async {
      final p = _reorderPayload(rows: const []);
      await tester.pumpWidget(_host(PharmacyReorderView(
        payload: p,
        onAdd: (_) {},
        onAddAll: () {},
        onDraftAction: (_) {},
      )));

      expect(find.text('Nothing is running low.'), findsOneWidget);
      expect(find.text('Add all to cart'), findsNothing);
    });

    testWidgets('the draft card says approving only fills the cart',
        (tester) async {
      await tester.pumpWidget(_host(PharmacyReorderView(
        payload: _reorderPayload(),
        draft: const {
          'has': true,
          'id': 'd1',
          'title': "This week's suggested order",
          'note':
              'Built for you on 01 Sep. Approving only fills your cart — you still place the order yourself.',
          'approve_label': 'Approve and fill cart',
          'skip_label': 'Skip this week',
          'line_count': 4,
        },
        onAdd: (_) {},
        onAddAll: () {},
        onDraftAction: (_) {},
      )));

      expect(find.text('Approve and fill cart'), findsOneWidget);
      expect(
          find.textContaining('you still place the order yourself'),
          findsOneWidget);
    });

    testWidgets('ok:false renders the backend refusal', (tester) async {
      await tester.pumpWidget(_host(PharmacyReorderView(
        payload: const {
          'ok': false,
          'error': 'not_authorized',
          'message': "This is your pharmacy's counter — sign in as the pharmacy.",
        },
        onAdd: (_) {},
        onAddAll: () {},
        onDraftAction: (_) {},
      )));

      expect(find.textContaining('sign in as the pharmacy'), findsOneWidget);
      expect(find.text('What to reorder'), findsNothing);
    });
  });

  group('counter margin finder', () {
    testWidgets('prints the backend\'s margin and its comparison verbatim',
        (tester) async {
      await tester.pumpWidget(_host(PosMarginStrip(
        payload: _marginPayload(),
        onSwap: (_) {},
      )));

      expect(find.text('Same salt, better margin'), findsOneWidget);
      expect(find.text('Cipmol 650'), findsOneWidget);
      expect(find.text('₹5.10'), findsOneWidget);
      expect(find.text('₹2.10 more margin'), findsOneWidget);
      expect(find.text('20 in stock'), findsOneWidget);
      expect(find.text('Use this'), findsOneWidget);
    });

    testWidgets('has:false draws NOTHING — not an empty card', (tester) async {
      await tester.pumpWidget(_host(PosMarginStrip(
        payload: const {
          'ok': true,
          'has': false,
          'title': 'Same salt, better margin',
          'message': 'No same-salt alternative on your shelf.',
          'rows': [],
        },
        onSwap: (_) {},
      )));

      expect(find.text('Same salt, better margin'), findsNothing);
      expect(find.byType(OutlinedButton), findsNothing);
    });

    testWidgets('a row with no real cost shows no margin figure at all',
        (tester) async {
      await tester.pumpWidget(_host(PosMarginStrip(
        payload: _marginPayload(rows: [
          {
            'medicine_id': 33,
            'product_name': 'Uncosted Brand',
            'company': 'Someone',
            'stock_display': '12 in stock',
            // the backend says there is no real cost behind this row
            'has_margin': false,
            'margin_label': 'Your margin',
            'no_cost_note': 'Cost not recorded for this batch.',
            'swap_label': 'Use this',
          },
        ]),
        onSwap: (_) {},
      )));

      expect(find.text('Uncosted Brand'), findsOneWidget);
      // An estimated margin is worse than none, so there is no fallback figure
      // and no zero.
      expect(find.text('Your margin'), findsNothing);
      expect(find.text('₹0.00'), findsNothing);
    });

    testWidgets('the swap hands back the row the backend sent', (tester) async {
      Map<String, dynamic>? swapped;
      await tester.pumpWidget(_host(PosMarginStrip(
        payload: _marginPayload(),
        onSwap: (r) => swapped = r,
      )));

      await tester.tap(find.text('Use this'));
      await tester.pump();
      expect(swapped?['medicine_id'], 22);
      expect(swapped?['product_name'], 'Cipmol 650');
    });

    testWidgets('rows render in payload order — the backend already ranked them',
        (tester) async {
      await tester.pumpWidget(_host(PosMarginStrip(
        payload: _marginPayload(rows: [
          {
            'medicine_id': 44,
            'product_name': 'Best Margin',
            'stock_display': '5 in stock',
            'has_margin': true,
            'margin_label': 'Your margin',
            'margin_display': '₹9.00',
            'delta_display': '₹6.00 more margin',
            'swap_label': 'Use this',
          },
          {
            'medicine_id': 22,
            'product_name': 'Next Margin',
            'stock_display': '20 in stock',
            'has_margin': true,
            'margin_label': 'Your margin',
            'margin_display': '₹5.10',
            'delta_display': '₹2.10 more margin',
            'swap_label': 'Use this',
          },
        ]),
        onSwap: (_) {},
      )));

      final texts = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .whereType<String>()
          .toList();
      expect(texts.indexOf('Best Margin') < texts.indexOf('Next Margin'), isTrue,
          reason: 'the strip must not re-rank what the backend ranked');
    });
  });
}
