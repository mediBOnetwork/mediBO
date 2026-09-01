// CHANGE #419 — the owner's night screens compute nothing.
//
// What these tests hold down is the boundary, not the arithmetic: every rupee,
// percentage, caption and refusal on all three surfaces is a string the backend
// sent, the range toggle hands back the backend's own key, and "Add all" posts
// exactly the SKUs that were on screen. The anonymisation floor is a BACKEND
// decision that arrives as copy — so a cohort that is too small must render the
// backend's sentence and nothing of Dart's own.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/pharmacy/pharmacy_owner_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

const _dashboard = <String, dynamic>{
  'ok': true,
  'title': 'Your shop tonight',
  'subtitle': 'Sales, profit and what is sitting still.',
  'range': 'today',
  'has_sales': true,
  'empty': 'No bills in this window yet.',
  'empty_hint': 'Bill a patient on the counter and this fills up.',
  'ranges': [
    {'key': 'today', 'label': 'Today', 'selected': true},
    {'key': 'week', 'label': '7 days', 'selected': false},
    {'key': 'month', 'label': '30 days', 'selected': false},
  ],
  'tiles': [
    {
      'key': 'sales',
      'label': 'Sales',
      'value': '₹11,950.00',
      'sub': '5 bills',
      'tone': 'success',
    },
    {
      'key': 'profit',
      'label': 'Gross profit',
      'value': '₹9,325.00',
      'sub': 'Cost known on 4 of 7 lines',
      'tone': 'success',
    },
  ],
  'sections': [
    {
      'key': 'products',
      'heading': 'Top products',
      'rows': [
        {
          'rank': 1,
          'name': 'Zincovit Tablet',
          'value_label': '₹11,250.00',
          'qty_label': '10 units',
        },
      ],
    },
  ],
};

const _benchReady = <String, dynamic>{
  'ok': true,
  'state': 'ready',
  'title': 'How you compare',
  'subtitle': 'Against shops your size, nearby. Nobody is named.',
  'cohort_label': '7 similar pharmacies · ₹1–3 lakh a month · Raipur Zone',
  'privacy': 'Only group averages are ever shown, never a shop.',
  'sharing': true,
  'toggle_label': 'Stop sharing my totals',
  'message': '',
  'hint': '',
  'cards': [
    {
      'category': 'supplements',
      'tone': 'warning',
      'ahead': false,
      'headline':
          'Similar pharmacies earn ₹18,400 a month more on supplements than you.',
      'hint': 'Stocking a little deeper here is the easiest money on this list.',
      'mine_label': '₹4,100',
      'cohort_label': '₹22,500',
    },
  ],
};

const _benchTooSmall = <String, dynamic>{
  'ok': true,
  'state': 'too_small',
  'title': 'How you compare',
  'subtitle': 'Against shops your size, nearby. Nobody is named.',
  'message': 'Not enough pharmacies near you yet.',
  'hint':
      'Comparisons need at least 5 similar shops so no single shop can be recognised.',
  'sharing': true,
  'toggle_label': 'Stop sharing my totals',
  'privacy': 'Only group averages are ever shown, never a shop.',
  'cards': <Map<String, dynamic>>[],
};

const _radar = <String, dynamic>{
  'ok': true,
  'state': 'ready',
  'title': 'Demand radar',
  'subtitle': 'What your zone is buying this week.',
  'headline': 'Fever and pain up +40% in Raipur Zone this week — stock these 2.',
  'class_heading': 'By therapeutic class',
  'sku_heading': 'SKUs to stock',
  'add_all_label': 'Add all 2 to my cart',
  'classes': [
    {
      'key': 'fever_pain',
      'label': 'fever and pain',
      'units_label': '420 units',
      'delta_label': '+40% vs last week',
      'tone': 'success',
    },
  ],
  'rows': [
    {
      'medicine_id': 8811,
      'name': 'Dolo 650 Tablet',
      'category': 'fever_pain',
      'units_label': '260 units',
      'delta_label': '+52% vs last week',
      'tone': 'success',
      'stock_label': 'You have it',
      'add_label': 'Add',
      'qty': 1,
    },
    {
      'medicine_id': 9042,
      'name': 'Cheston Cold Tablet',
      'category': 'respiratory',
      'units_label': '160 units',
      'delta_label': '+21% vs last week',
      'tone': 'success',
      'stock_label': 'Not on your shelf',
      'add_label': 'Add',
      'qty': 1,
    },
  ],
};

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('owner dashboard', () {
    testWidgets('every tile prints the backend strings verbatim',
        (tester) async {
      await tester.pumpWidget(_host(
        OwnerDashboardView(payload: _dashboard, onRange: (_) {}),
      ));

      expect(find.text('₹11,950.00'), findsOneWidget);
      expect(find.text('5 bills'), findsOneWidget);
      // The profit caption names its own coverage — Dart never recomputes it.
      expect(find.text('Cost known on 4 of 7 lines'), findsOneWidget);
      expect(find.text('Top products'), findsOneWidget);
      expect(find.text('₹11,250.00'), findsOneWidget);
    });

    testWidgets('the range toggle sends the backend key, not a Dart label',
        (tester) async {
      final sent = <String>[];
      await tester.pumpWidget(_host(
        OwnerDashboardView(payload: _dashboard, onRange: sent.add),
      ));

      await tester.tap(find.text('30 days'));
      await tester.pump();
      expect(sent, ['month']);
    });

    testWidgets('no bills renders the backend empty state, not a zero grid',
        (tester) async {
      final empty = Map<String, dynamic>.from(_dashboard)
        ..['has_sales'] = false;
      await tester
          .pumpWidget(_host(OwnerDashboardView(payload: empty, onRange: (_) {})));

      expect(find.text('No bills in this window yet.'), findsOneWidget);
      expect(find.text('₹11,950.00'), findsNothing);
    });
  });

  group('benchmark', () {
    testWidgets('a card is the backend sentence, framed as opportunity',
        (tester) async {
      await tester.pumpWidget(_host(
        OwnerBenchmarkView(payload: _benchReady, onSharing: (_) {}),
      ));

      expect(
        find.text(
            'Similar pharmacies earn ₹18,400 a month more on supplements than you.'),
        findsOneWidget,
      );
      expect(
        find.text('7 similar pharmacies · ₹1–3 lakh a month · Raipur Zone'),
        findsOneWidget,
      );
    });

    testWidgets('a cohort under the floor shows the backend refusal and no card',
        (tester) async {
      await tester.pumpWidget(_host(
        OwnerBenchmarkView(payload: _benchTooSmall, onSharing: (_) {}),
      ));

      expect(find.text('Not enough pharmacies near you yet.'), findsOneWidget);
      expect(
        find.text(
            'Comparisons need at least 5 similar shops so no single shop can be recognised.'),
        findsOneWidget,
      );
      // No comparison is drawn, and no number is invented to fill the gap.
      expect(find.textContaining('more on'), findsNothing);
    });

    testWidgets('the sharing toggle flips the backend flag it was given',
        (tester) async {
      final sent = <bool>[];
      await tester.pumpWidget(_host(
        OwnerBenchmarkView(payload: _benchReady, onSharing: sent.add),
      ));

      await tester.tap(find.text('Stop sharing my totals'));
      await tester.pump();
      expect(sent, [false]);
    });

    testWidgets('an opted-out shop sees its own state and the way back',
        (tester) async {
      const out = <String, dynamic>{
        'ok': true,
        'state': 'opted_out',
        'title': 'How you compare',
        'subtitle': 'Against shops your size, nearby. Nobody is named.',
        'message': 'Your shop is out of the network comparison.',
        'hint': 'Nothing from your counter goes into any shared figure.',
        'sharing': false,
        'toggle_label': 'Share my totals anonymously',
        'privacy': 'Only group averages are ever shown, never a shop.',
        'cards': <Map<String, dynamic>>[],
      };
      final sent = <bool>[];
      await tester
          .pumpWidget(_host(OwnerBenchmarkView(payload: out, onSharing: sent.add)));

      expect(find.text('Your shop is out of the network comparison.'),
          findsOneWidget);
      await tester.tap(find.text('Share my totals anonymously'));
      await tester.pump();
      expect(sent, [true]);
    });
  });

  group('demand radar', () {
    testWidgets('headline, classes and SKUs render in payload order',
        (tester) async {
      await tester.pumpWidget(
          _host(OwnerRadarView(payload: _radar, onAdd: (_) {})));

      expect(
        find.text(
            'Fever and pain up +40% in Raipur Zone this week — stock these 2.'),
        findsOneWidget,
      );
      expect(find.text('+52% vs last week'), findsOneWidget);
      expect(find.text('Not on your shelf'), findsOneWidget);

      final names = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .where((d) => d == 'Dolo 650 Tablet' || d == 'Cheston Cold Tablet')
          .toList();
      expect(names, ['Dolo 650 Tablet', 'Cheston Cold Tablet']);
    });

    testWidgets('add all posts exactly the ids that were on screen',
        (tester) async {
      List<Map<String, dynamic>>? sent;
      await tester.pumpWidget(
          _host(OwnerRadarView(payload: _radar, onAdd: (i) => sent = i)));

      await tester.tap(find.text('Add all 2 to my cart'));
      await tester.pump();
      expect(sent, [
        {'medicine_id': 8811, 'qty': 1},
        {'medicine_id': 9042, 'qty': 1},
      ]);
    });

    testWidgets('a single Add posts only that row', (tester) async {
      List<Map<String, dynamic>>? sent;
      await tester.pumpWidget(
          _host(OwnerRadarView(payload: _radar, onAdd: (i) => sent = i)));

      await tester.tap(find.text('Add').first);
      await tester.pump();
      expect(sent, [
        {'medicine_id': 8811, 'qty': 1},
      ]);
    });

    testWidgets('a zone under the floor shows the refusal and offers no list',
        (tester) async {
      const small = <String, dynamic>{
        'ok': true,
        'state': 'too_small',
        'title': 'Demand radar',
        'subtitle': 'What your zone is buying this week.',
        'message': 'Your zone is still too quiet to read.',
        'hint':
            'The radar needs at least 5 pharmacies selling before a trend means anything.',
        'classes': <Map<String, dynamic>>[],
        'rows': <Map<String, dynamic>>[],
      };
      await tester
          .pumpWidget(_host(OwnerRadarView(payload: small, onAdd: (_) {})));

      expect(find.text('Your zone is still too quiet to read.'), findsOneWidget);
      expect(find.textContaining('Add all'), findsNothing);
    });
  });

  testWidgets('a refusal payload prints the backend message, never a Dart one',
      (tester) async {
    const denied = <String, dynamic>{
      'ok': false,
      'error': 'not_a_pharmacy',
      'message': 'This screen belongs to a pharmacy account.',
    };
    await tester.pumpWidget(
        _host(OwnerDashboardView(payload: denied, onRange: (_) {})));
    expect(find.text('This screen belongs to a pharmacy account.'),
        findsOneWidget);
  });

  testWidgets('the entry tile disappears when its backend label is empty',
      (tester) async {
    await tester
        .pumpWidget(_host(const OwnerDashboardEntryTile(label: '')));
    expect(find.byType(InkWell), findsNothing);

    await tester.pumpWidget(
        _host(const OwnerDashboardEntryTile(label: 'Owner dashboard')));
    expect(find.text('Owner dashboard'), findsOneWidget);
  });
}
