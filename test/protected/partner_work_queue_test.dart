// CHANGE #398 — the partner work queue board.
//
// partner_home() answers "what may I open?". Before this change that was the
// WHOLE partner home: a list of permitted features, with no answer to the only
// question a fulfilment partner actually opens the app with — "what is waiting
// for me right now?". She opened Collect, then Count, then Pack, guessing.
//
// partner_work_queue() answers it in one payload, and this file pins the four
// ways that payload could quietly stop being the authority:
//   1. The stage list is rendered in PAYLOAD ORDER, and the plural form, the
//      money, the age and the next action are the backend's strings — a Dart
//      "$n orders" here would be the bug this whole app is built to avoid.
//   2. A stage the partner has no permission for is ABSENT from the payload,
//      so it must be absent from the screen: the widget never invents the full
//      ladder and greys out what is missing.
//   3. has_any:false renders the backend's empty state, not a bare empty list.
//   4. A board that did not answer (null) draws NOTHING and leaves the feature
//      list underneath intact — a queue outage must not cost the partner the
//      rest of her home.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/order_alerts_screen.dart' show OrderAlertCard;
import 'package:pharma_b2b/screens/partner/partner_home_screen.dart';
import 'package:pharma_b2b/services/ui_copy.dart';
import 'package:pharma_b2b/utils/render_log.dart';

/// The SHAPE of a live partner_work_queue() answer for zone 1.
///
/// Deliberately hostile in three ways: the stages are NOT alphabetical (a
/// client-side sort would show), 'pack' is missing entirely (this partner has
/// no partner.pack grant), and the orders inside a stage are listed oldest
/// first with ages that a Dart sort on the STRING would reorder.
const Map<String, dynamic> queueJson = {
  'ok': true,
  'is_partner': true,
  'partner_id': 1,
  'zone_id': 1,
  'zone_label': 'Raipur Zone',
  'show_zone_picker': false,
  'title': "Today's work",
  'subtitle': 'Oldest first. Tap a stage to open it.',
  'today_label': 'Today: 4 received · 1 delivered',
  'total': 30,
  'total_label': '30 waiting',
  'has_any': true,
  'empty_title': 'Nothing waiting',
  'empty_message': 'Every order in your zone has moved on.',
  'stages': [
    {
      'stage_key': 'received',
      'label': 'Received',
      'tone': 'warning',
      'feature_key': 'partner.inquiry',
      'next_action': 'Accept and start inquiry',
      'count': 1,
      'count_label': '1 order',
      'has_any': true,
      'can_open': true,
      'open_label': 'Open',
      'more_count': 0,
      'more_label': '',
      'orders': [
        {
          'order_id': 'o-1',
          'order_code': 'CPO070826CHAO1',
          'customer': 'Chandra Medical',
          'amount_display': '₹2,410',
          'age_label': '24 days',
          'next_action': 'Accept and start inquiry',
        },
      ],
    },
    {
      'stage_key': 'supplier_order',
      'label': 'Supplier order',
      'tone': 'info',
      'feature_key': 'partner.supplier_orders',
      'next_action': 'Raise the supplier order',
      'count': 17,
      'count_label': '17 orders',
      'has_any': true,
      'can_open': true,
      'open_label': 'Open',
      'more_count': 15,
      'more_label': '+15 more',
      'orders': [
        {
          'order_id': 'o-2',
          'order_code': 'CPO210726PAL124O1',
          'customer': 'Pallavi Medicos',
          'amount_display': '₹9,180',
          'age_label': '42 days',
          'next_action': 'Raise the supplier order',
        },
        {
          'order_id': 'o-3',
          'order_code': 'CPO300726CHAO1',
          'customer': 'Chandra Medical',
          'amount_display': '₹640',
          'age_label': '32 days',
          'next_action': 'Raise the supplier order',
        },
      ],
    },
    {
      'stage_key': 'collect',
      'label': 'Collect',
      'tone': 'info',
      'feature_key': 'partner.collect',
      'next_action': 'Collect from the shop',
      'count': 0,
      'count_label': '0 orders',
      'has_any': false,
      'can_open': true,
      'open_label': 'Open',
      'more_count': 0,
      'more_label': '',
      'orders': [],
    },
  ],
};

/// The partner_home() half of the same screen, so the "board is absent, the
/// features still render" case has something underneath to survive.
const Map<String, dynamic> homeJson = {
  'ok': true,
  'is_partner': true,
  'partner_id': 1,
  'partner_name': 'Jai Mahakal Medical And Surgical',
  'title': 'Partner',
  'zone_chip': 'Zone · Raipur Zone',
  'show_zone_picker': false,
  'feature_count': 1,
  'has_features': true,
  'groups': [
    {
      'label': 'Sourcing',
      'sort': '000001',
      'count': 1,
      'features': [
        {
          'feature_key': 'partner.inquiry',
          'label': 'Inquiry',
          'icon_key': 'forum',
          'route_key': 'inquiry',
          'access': 'write',
          'can_write': true,
          'access_label': 'Full access',
        },
      ],
    },
  ],
  'empty_title': 'No features enabled yet',
  'empty_message': '',
};

/// PartnerHomeView brings its own Scaffold, so it is hosted bare.
Widget _host(Widget child) => MaterialApp(home: child);

/// The board on its own lives inside the partner home's SingleChildScrollView
/// in production, so its host gives it the same vertical freedom — a fixed
/// 800 px test viewport is not the phone this ships to.
Widget _boardHost(Widget child) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  setUpAll(() {
    RenderLog.flushEnabled = false;
    UiCopy.debugSet(const {
      'partner.error_title': 'Could not load your partner home',
      'partner.error_message': 'Check your connection and try again.',
      'partner.retry_label': 'Retry',
      'partner.sign_out_label': 'Sign out',
    });
  });

  group('the board prints the backend and computes nothing', () {
    testWidgets('stages render in payload order, counts verbatim',
        (tester) async {
      await tester.pumpWidget(_boardHost(
          PartnerWorkQueue(payload: queueJson, onOpen: (_) {})));
      await tester.pump();

      expect(find.text("Today's work"), findsOneWidget);
      expect(find.text('Today: 4 received · 1 delivered'), findsOneWidget);
      expect(find.text('30 waiting'), findsOneWidget);

      // The backend's plural forms, printed. Never composed here.
      expect(find.text('1 order'), findsOneWidget);
      expect(find.text('17 orders'), findsOneWidget);
      expect(find.text('0 orders'), findsOneWidget);

      final labels = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .toList();
      expect(labels.indexOf('Received'),
          lessThan(labels.indexOf('Supplier order')),
          reason: 'payload order, not alphabetical');
      expect(labels.indexOf('Supplier order'), lessThan(labels.indexOf('Collect')));
    });

    testWidgets('a stage the partner cannot see is simply not there',
        (tester) async {
      await tester.pumpWidget(_boardHost(
          PartnerWorkQueue(payload: queueJson, onOpen: (_) {})));
      await tester.pump();
      // partner.pack was never granted, so partner_work_queue() omitted it.
      // The widget must not draw the ladder it "knows" should exist.
      expect(find.text('Pack'), findsNothing);
    });

    testWidgets('orders keep payload order and print money, age and action',
        (tester) async {
      await tester.pumpWidget(_boardHost(
          PartnerWorkQueue(payload: queueJson, onOpen: (_) {})));
      await tester.pump();

      expect(find.text('₹9,180'), findsOneWidget);
      expect(find.text('42 days'), findsOneWidget);
      expect(find.text('Raise the supplier order'), findsNWidgets(2));
      expect(find.text('+15 more'), findsOneWidget);

      final labels = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .toList();
      expect(labels.indexOf('CPO210726PAL124O1'),
          lessThan(labels.indexOf('CPO300726CHAO1')),
          reason: 'oldest first is the BACKEND order — no client sort');
    });

    testWidgets('Open carries the stage feature key, and only where there is work',
        (tester) async {
      final tapped = <String>[];
      await tester.pumpWidget(_boardHost(
          PartnerWorkQueue(payload: queueJson, onOpen: tapped.add)));
      await tester.pump();

      // Two stages have work; the empty Collect stage offers no button.
      expect(find.widgetWithText(OutlinedButton, 'Open'), findsNWidgets(2));
      await tester.tap(find.widgetWithText(OutlinedButton, 'Open').first);
      expect(tapped, ['partner.inquiry']);
    });

    testWidgets('an empty board shows the backend empty state', (tester) async {
      final empty = Map<String, dynamic>.from(queueJson)
        ..['has_any'] = false
        ..['total'] = 0
        ..['total_label'] = '0 waiting';
      await tester.pumpWidget(
          _boardHost(PartnerWorkQueue(payload: empty, onOpen: (_) {})));
      await tester.pump();

      expect(find.text('Nothing waiting'), findsOneWidget);
      expect(find.text('Every order in your zone has moved on.'), findsOneWidget);
      expect(find.byType(OutlinedButton), findsNothing);
    });
  });

  group('the board is additive — it can never cost the home its features', () {
    testWidgets('queue null draws no board and leaves the tiles alone',
        (tester) async {
      await tester.pumpWidget(_host(PartnerHomeView(
        payload: homeJson,
        queue: null,
        onOpen: (_) {},
      )));
      await tester.pump();

      expect(find.byType(PartnerWorkQueue), findsNothing);
      expect(find.text("Today's work"), findsNothing);
      expect(find.text('Inquiry'), findsOneWidget);
    });

    testWidgets('an ok:false board is treated as absent, not as an empty queue',
        (tester) async {
      await tester.pumpWidget(_host(PartnerHomeView(
        payload: homeJson,
        queue: const {'ok': false, 'is_partner': false, 'message': 'nope'},
        onOpen: (_) {},
      )));
      await tester.pump();

      expect(find.byType(PartnerWorkQueue), findsNothing);
      expect(find.text('Inquiry'), findsOneWidget);
    });

    testWidgets('a live board renders above the feature tiles', (tester) async {
      await tester.pumpWidget(_host(PartnerHomeView(
        payload: homeJson,
        queue: queueJson,
        onOpen: (_) {},
      )));
      await tester.pump();

      expect(find.byType(PartnerWorkQueue), findsOneWidget);
      final labels = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .toList();
      expect(labels.indexOf("Today's work"), lessThan(labels.indexOf('Sourcing')));
    });
  });

  // ── CHANGE #398 — the ring, on the partner's phone ────────────────────────
  //
  // #306 rang admin devices for an order the PARTNER has to fulfil. The push
  // half of the fix lives in order_alert_push(); this is the in-app half, and
  // these are the properties that must not rot: the card is the backend's item
  // (never re-decided here), Accept exists only when the backend says it may,
  // and no ringing item means no banner at all.
  group('the ring reaches the partner and prints the backend', () {
    const ringingItem = {
      'alert_id': 12,
      'order_id': 'o-ring',
      'order_code': 'CPO310826CHAO1',
      'customer': 'Chandra Medical',
      'amount_display': '₹2,410',
      'age_label': '2 min',
      'state': 'ringing',
      'state_label': 'Ringing',
      'stage': 'new',
      'stage_label': 'New',
      'risk': 'unpaid',
      'risk_label': 'Unpaid',
      'paid': false,
      'ring': true,
      'critical': false,
      'banner': 'Unpaid order waiting for a decision',
      'credit_blocked': false,
      'credit_note': '',
      'can_accept': true,
      'can_reject': true,
      'accept_label': 'Accept',
      'reject_label': 'Reject',
      'dismiss_label': 'Dismiss',
      'view_label': 'View',
      'accept_note': 'Accepting starts the inquiry.',
      'reject_note': 'Rejecting cancels the order.',
      'push_count': 1,
    };

    testWidgets('a ringing alert draws the backend card with both buttons',
        (tester) async {
      final acts = <String>[];
      await tester.pumpWidget(_boardHost(PartnerRing(
        items: const [ringingItem],
        onAct: (id, action) => acts.add('$id:$action'),
      )));
      await tester.pump();

      expect(find.text('Unpaid order waiting for a decision'), findsOneWidget);
      expect(find.text('CPO310826CHAO1'), findsOneWidget);
      expect(find.text('Accept'), findsOneWidget);
      expect(find.text('Reject'), findsOneWidget);

      await tester.tap(find.text('Accept'));
      expect(acts, ['o-ring:accept']);
    });

    testWidgets('can_accept:false offers no Accept — the backend decides, not the widget',
        (tester) async {
      final blocked = Map<String, dynamic>.from(ringingItem)
        ..['can_accept'] = false
        ..['credit_blocked'] = true
        ..['credit_note'] = 'Credit limit reached. Collect payment first.';
      await tester.pumpWidget(_boardHost(PartnerRing(
        items: [blocked],
        onAct: (_, __) {},
      )));
      await tester.pump();

      expect(find.text('Credit limit reached. Collect payment first.'),
          findsOneWidget);
      // The card still SHOWS Accept — with its own words — but the backend's
      // can_accept:false is what disables it. The widget never re-decides.
      final accept = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Accept'));
      expect(accept.onPressed, isNull);
    });

    testWidgets('no ringing alert means no banner at all', (tester) async {
      await tester.pumpWidget(_boardHost(
          const PartnerRing(items: [])));
      await tester.pump();
      expect(find.byType(OrderAlertCard), findsNothing);
    });

    testWidgets('the badge is the backend sentence, and absent when nothing rings',
        (tester) async {
      await tester.pumpWidget(_host(PartnerHomeView(
        payload: homeJson,
        queue: queueJson,
        ring: const [ringingItem],
        ringBadge: '1 order waiting for a decision',
        onOpen: (_) {},
        onRingAct: (_, __) {},
      )));
      await tester.pump();
      expect(find.text('1 order waiting for a decision'), findsOneWidget);

      await tester.pumpWidget(_host(PartnerHomeView(
        payload: homeJson,
        queue: queueJson,
        onOpen: (_) {},
      )));
      await tester.pump();
      // Nothing ringing -> the backend sends no badge sentence -> no chip. The
      // widget never composes one from a list length.
      expect(find.text('1 order waiting for a decision'), findsNothing);
      expect(find.text('Zone · Raipur Zone'), findsOneWidget);
    });

    testWidgets('the ring sits ABOVE the work queue on the home', (tester) async {
      await tester.pumpWidget(_host(PartnerHomeView(
        payload: homeJson,
        queue: queueJson,
        ring: const [ringingItem],
        onOpen: (_) {},
        onRingAct: (_, __) {},
      )));
      await tester.pump();

      expect(find.byType(PartnerRing), findsOneWidget);
      final labels = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .toList();
      expect(labels.indexOf('Unpaid order waiting for a decision'),
          lessThan(labels.indexOf("Today's work")),
          reason: 'a ringing order outranks the board it will join');
    });
  });
}
