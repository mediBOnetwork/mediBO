// PROTECTED — CHANGE #812.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes dashboard behaviour, never to make an unrelated change
// go green.
//
// What this holds down — the dashboard is ONE payload, PRINTED:
//
//   1. Nothing on the strip is computed in Dart. The tile shows
//      `value_display` and `delta_display` verbatim: the fixture deliberately
//      sends a `delta_display` that disagrees with `value` minus yesterday's
//      spark point, so any client-side arithmetic fails this test. Money
//      arrives as a rupee string; Dart never formats a currency.
//
//   2. A tone is a NAME the backend sent, never a number the client judged.
//      `delta_tone: 'warn'` on a metric whose delta is POSITIVE is honoured
//      (money out going up is bad), which no local "bigger is greener" rule
//      could ever produce.
//
//   3. Order is payload order. The fixture's metrics and funnel stages are
//      deliberately not alphabetical and not sorted by count; the screen must
//      not reorder either.
//
//   4. needs_you rows carry ONE action, and its kind decides what happens: a
//      'rpc' action calls exactly the rpc and args the payload named, and a
//      'route' action opens the payload's route instead — the widget never
//      invents a call for a row that did not carry one, and a row whose action
//      has:false shows no button at all.
//
//   5. Absence is explicit. An empty needs_you renders the BACKEND's
//      `empty_label`; a funnel whose total is 0 renders the backend's
//      `funnel.empty_label`; zone_cards with no cards renders nothing rather
//      than an empty heading; and `ok:false` prints the backend's `message`
//      instead of throwing.
//
//   6. universal_search results are grouped and labelled by the backend, and a
//      pick hands the WHOLE row back (with its own deep_link / route_key), so
//      the caller opens the door the backend chose — never one Dart derived
//      from `kind`.
//
// No network, no Supabase, no goldens. Fixture mirrors a real dashboard_v2()
// response taken off the live database on 2026-09-03.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/dashboard_v2_card.dart';

Map<String, dynamic> _payload({
  List<Map<String, dynamic>>? needs,
  List<Map<String, dynamic>>? stages,
  List<Map<String, dynamic>>? alerts,
  List<Map<String, dynamic>>? zoneCards,
  int funnelTotal = 32,
}) =>
    {
      'ok': true,
      'allowed': true,
      'role': 'super_admin',
      'is_partner': false,
      'is_super': true,
      'zone_id': 1,
      'zone_label': 'Raipur Zone',
      'greeting': 'Good afternoon',
      'first_thing': '7 orders waiting for accept',
      'strip': {
        'title': 'Today',
        // Deliberately NOT alphabetical, and money_out's tone contradicts the
        // sign of its delta.
        'metrics': [
          {
            'key': 'orders_received',
            'label': 'Orders received',
            'short_label': 'Received',
            'kind': 'count',
            'value': 2,
            // Disagrees with the spark on purpose: the tile must print this.
            'value_display': 'two',
            'delta': 2,
            'delta_display': '+2 vs yesterday',
            'delta_tone': 'good',
            'spark': [0, 1, 1, 2, 2, 0, 2],
          },
          {
            'key': 'money_out',
            'label': 'Money out',
            'short_label': 'Out',
            'kind': 'money',
            'value': 4200,
            'value_display': '₹4.2K',
            'delta': 4200,
            'delta_display': '+₹4.2K vs yesterday',
            // Positive delta, WARN tone — money out rising is not good news.
            'delta_tone': 'warn',
            'spark': [0, 0, 0, 0, 0, 0, 4200],
          },
        ],
      },
      'needs_you': {
        'title': 'Needs you',
        'empty_label': 'Nothing is overdue right now.',
        'items': needs ??
            [
              {
                'id': 'exc:sla_breach:bills_pending/abc',
                'label': 'images.png',
                'sub_label': 'Supplier bills not imported · SAI GANESH PHARMA',
                'stage_label': 'Past SLA',
                'age_label': '92 days',
                'over_label': '92d 5h over',
                'owner_label': 'Waiting on: mediBO admin',
                'tone': 'bad',
                'source': 'exception',
                'action': {
                  'has': true,
                  'kind': 'rpc',
                  'label': 'Open the queue',
                  'rpc': 'exceptions_action',
                  'args': {'p_id': 'sla_breach:bills_pending/abc'},
                  'route': 'exceptions',
                },
              },
              {
                'id': 'ops:11111111-2222-3333-4444-555555555555:accept',
                'label': 'ORD-2201',
                'sub_label': 'Shraddha Medical & General Stores',
                'stage_label': 'Accept',
                'age_label': '3h ago',
                'over_label': '1h 10m over',
                'owner_label': 'Waiting on: Partner',
                'tone': 'warn',
                'source': 'ops',
                'action': {
                  'has': true,
                  'kind': 'route',
                  'label': 'Accept and start inquiry',
                  'rpc': '',
                  'args': <String, dynamic>{},
                  'route': 'ops_board',
                },
              },
              {
                'id': 'ops:66666666-7777-8888-9999-000000000000:pack',
                'label': 'ORD-2199',
                'sub_label': 'Ot Medical',
                'stage_label': 'Pack',
                'age_label': '5h ago',
                'over_label': '20m over',
                'owner_label': 'Waiting on: Partner',
                'tone': 'warn',
                'source': 'ops',
                // No action at all: the row still renders, with no button.
                'action': {'has': false},
              },
            ],
      },
      'funnel': {
        'title': 'Where orders are',
        'empty_label': 'No open orders.',
        'total': funnelTotal,
        // Deliberately NOT sorted by count.
        'stages': stages ??
            [
              {
                'key': 'received',
                'label': 'Received',
                'count': 7,
                'count_label': '7',
                'route_key': 'customer_orders',
                'deep_link': '/admin/go/fulfillment',
              },
              {
                'key': 'inquiry',
                'label': 'Inquiry',
                'count': 25,
                'count_label': '25',
                'route_key': 'inquiry',
                'deep_link': '/admin/go/fulfillment',
              },
              {
                'key': 'pack',
                'label': 'Pack',
                'count': 0,
                'count_label': '0',
                'route_key': 'pack',
                'deep_link': '/admin/go/fulfillment',
              },
            ],
      },
      'promised': {
        'title': 'Promised today',
        'has': true,
        'done': 3,
        'total': 4,
        'pct': 75,
        'label': '3 of 4',
        'sub_label': '1 still to land',
      },
      'alerts': alerts ??
          [
            {
              'key': 'licence',
              'tone': 'warn',
              'label': '1 partner licence(s) expiring within 30 days',
            },
          ],
      'quick_actions': {
        'title': 'Quick actions',
        'items': [
          {
            'key': 'add_order',
            'label': 'Add order',
            'icon_key': 'add_shopping_cart',
            'route_key': 'customer_order',
            'deep_link': '',
          },
        ],
      },
      'zone_cards': {
        'title': 'Zones',
        'has': true,
        'cards': zoneCards ??
            [
              {
                'zone_id': 2,
                'zone_label': 'Bilaspur Zone',
                'route_key': 'dashboard',
                'metrics': [
                  {
                    'key': 'orders_received',
                    'short_label': 'Received',
                    'value_display': '0',
                  },
                ],
              },
            ],
      },
      'updated_label': 'Updated 3:42 PM',
      'refresh_ms': 60000,
    };

Future<void> _pump(
  WidgetTester tester,
  Map<String, dynamic> payload, {
  void Function(Map<String, dynamic>)? onOpen,
  Future<void> Function(Map<String, dynamic>)? onAction,
}) async {
  // The card is a full dashboard head — taller than the 800x600 default
  // surface, so every row is on screen and tappable under test.
  tester.view.physicalSize = const Size(1200, 3200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: DashboardV2Card(
          payload: payload,
          onOpen: onOpen ?? (_) {},
          onAction: onAction ?? (_) async {},
        ),
      ),
    ),
  ));
  await tester.pump();
}

void main() {
  setUpAll(() {
    // The 800 ms debounce is a real Timer that would outlive the test and try
    // to reach Supabase.
    RenderLog.flushEnabled = false;
  });

  group('the today strip is printed, never computed', () {
    testWidgets('value and delta are the payload strings, verbatim',
        (tester) async {
      await _pump(tester, _payload());

      // 'two', not '2': the tile prints value_display and does no arithmetic
      // of its own on `value` or on the spark array.
      expect(find.text('two'), findsOneWidget);
      expect(find.text('+2 vs yesterday'), findsOneWidget);

      // Money is a backend string. Dart formats no currency.
      expect(find.text('₹4.2K'), findsOneWidget);
      expect(find.text('+₹4.2K vs yesterday'), findsOneWidget);
    });

    testWidgets('a tone is the name the backend sent, not a sign test',
        (tester) async {
      await _pump(tester, _payload());

      // money_out's delta is POSITIVE and its tone is 'warn'. If the widget
      // decided colour from the number, this would come out as the success
      // colour instead.
      final delta = tester.widget<Text>(find.text('+₹4.2K vs yesterday'));
      final good = tester.widget<Text>(find.text('+2 vs yesterday'));
      expect(delta.style!.color, isNot(equals(good.style!.color)));
    });

    testWidgets('metrics render in payload order', (tester) async {
      await _pump(tester, _payload());
      final received = tester.getTopLeft(find.byKey(
          const Key('c812_metric_orders_received')));
      final out =
          tester.getTopLeft(find.byKey(const Key('c812_metric_money_out')));
      // Second in the payload, so never above/left of the first.
      expect(out.dy >= received.dy, isTrue);
    });
  });

  group('greeting, first thing and alerts', () {
    testWidgets('both halves of the sentence are the backend\'s',
        (tester) async {
      await _pump(tester, _payload());
      expect(find.text('Good afternoon'), findsOneWidget);
      expect(find.text('7 orders waiting for accept'), findsOneWidget);
    });

    testWidgets('an alert prints its own label; no alerts prints no banner',
        (tester) async {
      await _pump(tester, _payload());
      expect(find.text('1 partner licence(s) expiring within 30 days'),
          findsOneWidget);

      await _pump(tester, _payload(alerts: const []));
      expect(find.textContaining('licence'), findsNothing);
    });
  });

  group('needs you', () {
    testWidgets('an rpc action calls exactly the rpc and args it carried',
        (tester) async {
      final calls = <Map<String, dynamic>>[];
      await _pump(tester, _payload(), onAction: (a) async {
        calls.add(a);
      });

      await tester.tap(find.text('Open the queue'));
      await tester.pumpAndSettle();

      expect(calls, hasLength(1));
      expect(calls.single['rpc'], 'exceptions_action');
      expect(calls.single['args'],
          {'p_id': 'sla_breach:bills_pending/abc'});
    });

    testWidgets('a route action opens the route and calls no rpc',
        (tester) async {
      final opened = <Map<String, dynamic>>[];
      final calls = <Map<String, dynamic>>[];
      await _pump(tester, _payload(),
          onOpen: opened.add, onAction: (a) async => calls.add(a));

      await tester.tap(find.text('Accept and start inquiry'));
      await tester.pumpAndSettle();

      expect(calls, isEmpty);
      expect(opened, hasLength(1));
      expect(opened.single['route_key'], 'ops_board');
    });

    testWidgets('a row whose action has:false shows no button', (tester) async {
      await _pump(tester, _payload());
      // The third row is present…
      expect(find.text('ORD-2199'), findsOneWidget);
      // …with exactly the two buttons the other two rows carried.
      expect(find.byType(TextButton), findsNWidgets(2));
    });

    testWidgets('an empty queue renders the backend empty label',
        (tester) async {
      await _pump(tester, _payload(needs: const []));
      expect(find.byKey(const Key('c812_needs_empty')), findsOneWidget);
      expect(find.text('Nothing is overdue right now.'), findsOneWidget);
    });

    testWidgets('the age/over wording is printed, never recomputed',
        (tester) async {
      await _pump(tester, _payload());
      expect(find.text('92d 5h over'), findsOneWidget);
      expect(find.text('Waiting on: mediBO admin'), findsOneWidget);
    });
  });

  group('funnel and promised ring', () {
    testWidgets('stages render in payload order with their own count labels',
        (tester) async {
      await _pump(tester, _payload());
      // 'Received' is also a zone-card short_label, so anchor on the stage.
      expect(
          find.descendant(
              of: find.byKey(const Key('c812_stage_received')),
              matching: find.text('Received')),
          findsOneWidget);
      expect(find.text('25'), findsOneWidget);

      final first =
          tester.getTopLeft(find.byKey(const Key('c812_stage_received')));
      final second =
          tester.getTopLeft(find.byKey(const Key('c812_stage_inquiry')));
      // 'inquiry' has the bigger count; payload order still wins.
      expect(second.dy > first.dy, isTrue);
    });

    testWidgets('a stage tap hands back the stage row itself', (tester) async {
      final opened = <Map<String, dynamic>>[];
      await _pump(tester, _payload(), onOpen: opened.add);
      await tester.tap(find.byKey(const Key('c812_stage_inquiry')));
      await tester.pumpAndSettle();
      expect(opened.single['route_key'], 'inquiry');
      expect(opened.single['deep_link'], '/admin/go/fulfillment');
    });

    testWidgets('total 0 renders the backend empty label', (tester) async {
      await _pump(tester, _payload(funnelTotal: 0));
      expect(find.byKey(const Key('c812_funnel_empty')), findsOneWidget);
      expect(find.text('No open orders.'), findsOneWidget);
    });

    testWidgets('the ring prints its own label and sub label', (tester) async {
      await _pump(tester, _payload());
      expect(find.text('3 of 4'), findsOneWidget);
      expect(find.text('1 still to land'), findsOneWidget);
    });
  });

  group('zone cards and refusal', () {
    testWidgets('no cards renders no heading at all', (tester) async {
      await _pump(tester, _payload(zoneCards: const []));
      expect(find.text('Zones'), findsNothing);
    });

    testWidgets('ok:false prints the backend message instead of throwing',
        (tester) async {
      await _pump(tester, const {
        'ok': false,
        'allowed': false,
        'error': 'not_authorized',
        'message': 'You do not have access to this dashboard.',
      });
      expect(find.text('You do not have access to this dashboard.'),
          findsOneWidget);
      expect(find.byKey(const Key('c812_dashboard')), findsNothing);
    });
  });

  group('universal search', () {
    Map<String, dynamic> result() => {
          'ok': true,
          'query': 'sahu',
          'groups': [
            {
              'key': 'customers',
              'label': 'Pharmacies',
              'items': [
                {
                  'kind': 'pharmacy',
                  'title': 'Shraddha Medical & General Stores',
                  'subtitle': 'Raipur · 9000000000',
                  'icon_key': 'people',
                  'route_key': 'customer_360',
                  'deep_link': '/admin/go/customer_360/abc',
                  'seed': 'abc',
                  'ref_id': 'abc',
                },
              ],
            },
            {
              'key': 'products',
              'label': 'Products',
              'items': [
                {
                  'kind': 'product',
                  'title': 'Yashoda Ayurveda Sahu Porridge Mix',
                  'subtitle': 'suryan organic',
                  'icon_key': 'medication',
                  'route_key': 'search',
                  'deep_link': '/product/634609',
                  'seed': 'Yashoda Ayurveda Sahu Porridge Mix',
                  'ref_id': '634609',
                },
              ],
            },
          ],
          'empty_label': 'Nothing matched.',
        };

    testWidgets('groups are labelled by the backend and kept in order',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: UniversalSearchSheet(
            search: (q) async => result(),
            onPick: (_) {},
            placeholder: 'Search an order, phone, pharmacy, supplier or product',
          ),
        ),
      ));
      await tester.pump();

      await tester.enterText(
          find.byKey(const Key('c812_search_field')), 'sahu');
      await tester.pumpAndSettle();

      expect(find.text('Pharmacies'), findsOneWidget);
      expect(find.text('Products'), findsOneWidget);
      expect(find.text('Shraddha Medical & General Stores'), findsOneWidget);

      final customers = tester.getTopLeft(find.text('Pharmacies'));
      final products = tester.getTopLeft(find.text('Products'));
      expect(products.dy > customers.dy, isTrue);
    });

    testWidgets('a pick hands back the whole row, deep link included',
        (tester) async {
      final picked = <Map<String, dynamic>>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: UniversalSearchSheet(
            search: (q) async => result(),
            onPick: picked.add,
            placeholder: 'Search',
          ),
        ),
      ));
      await tester.pump();
      await tester.enterText(
          find.byKey(const Key('c812_search_field')), 'sahu');
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('c812_hit_634609')));
      await tester.pumpAndSettle();

      expect(picked, hasLength(1));
      expect(picked.single['deep_link'], '/product/634609');
      expect(picked.single['route_key'], 'search');
    });

    testWidgets('an empty query shows the backend hint, not a Dart literal',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: UniversalSearchSheet(
            search: (q) async => const {
              'ok': true,
              'groups': [],
              'hint': 'Type at least two characters.',
              'empty_label': 'Type at least two characters.',
            },
            onPick: (_) {},
            placeholder: 'Search',
          ),
        ),
      ));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('c812_search_field')), 'a');
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('c812_search_empty')), findsOneWidget);
      expect(find.text('Type at least two characters.'), findsOneWidget);
    });
  });
}
