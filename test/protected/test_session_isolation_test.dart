import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/services/test_session.dart';
import 'package:pharma_b2b/widgets/order_card_lean.dart';
import 'package:pharma_b2b/widgets/test_mode_banner.dart';

/// CMD #1848 — test mode is a PER-USER session the REAL checkout honours, and
/// a real order's path is byte-identical.
///
/// The backend decides everything: whose session a write belongs to
/// (test_session_for), whether an order is stamped, whether a row is visible
/// (the c1848 RLS policy + test_row_visible), and whether THIS person may end
/// the session. What this file holds down is that the app never re-derives
/// any of it:
///
///   1. NO SESSION MEANS THE ORDINARY PAYLOAD, VERBATIM. An order card built
///      from a row with no `test_badge` draws no badge; the banner host with
///      `on:false` draws nothing. There is no Dart notion of "test" that could
///      fire on its own.
///   2. ANOTHER USER'S LIVE SESSION DOES NOT AFFECT THIS USER. The banner is
///      the backend's per-user answer: `on:false` (what a stranger receives
///      while someone else is testing) is absent, even when the payload also
///      carries every word a live banner would. And `can_end:false` draws no
///      End & purge button even when `end_action` has a word.
///   3. A STAMPED ORDER NEVER APPEARS IN AN ORDINARY LISTING because the
///      backend never sends it — the card list renders exactly the rows it
///      was given, in payload order, and a badge appears only where the
///      payload put one. Nothing in Dart filters or flags by is_synthetic.
///   4. END & PURGE is one tap whose words (button, confirm, cancel, result
///      message) are all payload, and whose tap calls the injected runner
///      exactly once and talks to no network.
void main() {
  Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

  setUp(() => TestSessionState.instance.debugSet(const {}));

  Map<String, dynamic> row(String code, {String testBadge = ''}) => {
        'id': 'id-$code',
        'order_code': code,
        'date_label': '07 Sep',
        'item_count_label': '2 items',
        'amount_label': '₹120.00',
        'amount_is_money': true,
        'stage_key': 'placed',
        'stage_label': 'Placed',
        'progress': {'show': false, 'steps': []},
        'primary_action': {'key': 'track', 'label': 'Track', 'tone': 'brand'},
        'situation': 'open',
        'placed_by_admin': false,
        'placed_by_admin_label': '',
        if (testBadge.isNotEmpty) 'test_badge': testBadge,
      };

  group('1. no session — the ordinary payload, verbatim', () {
    test('a row without test_badge parses to an empty badge, never a guess', () {
      final c = CustomerOrderCard.fromPayload(row('CPO1'));
      expect(c.testBadge, '');
      expect(c.orderCode, 'CPO1');
    });

    testWidgets('an ordinary card draws no TEST chip', (tester) async {
      await tester.pumpWidget(host(OrderCardLean(
        card: CustomerOrderCard.fromPayload(row('CPO1')),
        onOpen: () {},
        onAction: (_) {},
      )));
      expect(find.text('CPO1'), findsOneWidget);
      expect(find.textContaining('TEST'), findsNothing);
      expect(find.textContaining('Test'), findsNothing);
    });

    testWidgets('on:false — the page is untouched', (tester) async {
      TestSessionState.instance.debugSet(const {'on': false, 'poll_ms': 20000});
      await tester.pumpWidget(host(
        const TestModeBannerHost(child: Text('page')),
      ));
      await tester.pump();
      expect(find.byType(TestModeBanner), findsNothing);
      expect(find.text('page'), findsOneWidget);
    });
  });

  group("2. another user's live session does not affect this user", () {
    testWidgets(
        'on:false is honoured even when every live-banner word is present',
        (tester) async {
      // A stranger's app receives the backend's per-user answer. The words
      // that WOULD have been shown to the owner are deliberately in the
      // payload, so a banner that keyed on `text`/`label` instead of `on`
      // fails here.
      TestSessionState.instance.debugSet(const {
        'on': false,
        'poll_ms': 20000,
        'text': 'TEST MODE — nothing here is real',
        'label': '07 Sep 08:10 run',
        'owner_label': 'Started by om@example.com',
        'badge': 'TEST',
        'can_end': true,
        'end_action': 'End & purge',
      });
      await tester.pumpWidget(host(
        const TestModeBannerHost(child: Text('page')),
      ));
      await tester.pump();
      expect(find.byType(TestModeBanner), findsNothing);
      expect(find.textContaining('TEST'), findsNothing);
      expect(TestSessionState.instance.isOn, isFalse);
    });

    testWidgets('can_end:false draws no End button even with a word for it',
        (tester) async {
      await tester.pumpWidget(host(const TestModeBanner(payload: {
        'on': true,
        'text': 'TEST MODE — nothing here is real',
        'badge': 'TEST',
        'owner_label': 'Started by om@example.com',
        'ends_label': 'Auto-ends 07 Sep 20:10',
        'can_end': false,
        'end_action': 'End & purge',
      })));
      expect(find.byKey(const ValueKey('test_session_end_purge')), findsNothing);
      expect(find.text('End & purge'), findsNothing);
      // The strip still names WHOSE session it is and when it auto-ends.
      expect(
        find.text('Started by om@example.com  ·  Auto-ends 07 Sep 20:10'),
        findsOneWidget,
      );
    });
  });

  group('3. a stamped order never appears in an ordinary listing', () {
    testWidgets('the list renders exactly the rows it was given, in order',
        (tester) async {
      // The backend sent two ordinary rows. If a stamped row existed it was
      // never sent — there is nothing here to filter, and nothing filters.
      final rows = [row('CPO2'), row('CPO1')];
      await tester.pumpWidget(host(ListView(
        children: [
          for (final r in rows)
            OrderCardLean(
              card: CustomerOrderCard.fromPayload(r),
              onOpen: () {},
              onAction: (_) {},
            ),
        ],
      )));
      expect(find.byType(OrderCardLean), findsNWidgets(2));
      // Payload order, not alphabetical.
      final y2 = tester.getTopLeft(find.text('CPO2')).dy;
      final y1 = tester.getTopLeft(find.text('CPO1')).dy;
      expect(y2, lessThan(y1));
      expect(find.textContaining('TEST'), findsNothing);
    });

    testWidgets("the owner's own list shows the badge ONLY where the payload put it",
        (tester) async {
      final rows = [row('CPO3', testBadge: 'TEST'), row('CPO1')];
      await tester.pumpWidget(host(ListView(
        children: [
          for (final r in rows)
            OrderCardLean(
              card: CustomerOrderCard.fromPayload(r),
              onOpen: () {},
              onAction: (_) {},
            ),
        ],
      )));
      expect(find.text('TEST'), findsOneWidget);
      // The chip sits on the stamped card's row, not the real one's.
      final badgeY = tester.getTopLeft(find.text('TEST')).dy;
      final stampedY = tester.getTopLeft(find.text('CPO3')).dy;
      final realY = tester.getTopLeft(find.text('CPO1')).dy;
      expect((badgeY - stampedY).abs(), lessThan((badgeY - realY).abs()));
    });
  });

  group('4. End & purge — one tap, every word the backend\'s', () {
    const live = {
      'on': true,
      'poll_ms': 20000,
      'session_id': 20,
      'text': 'TEST MODE — nothing here is real',
      'label': 'c1848 run',
      'owner_label': 'Started by tst.admin1848@medibo.invalid',
      'ends_label': 'Auto-ends 07 Sep 14:21',
      'badge': 'TEST',
      'tone': 'danger',
      'is_owner': false,
      'can_end': true,
      'end_action': 'End & purge',
      'end_confirm':
          'End this test session and delete every row, file and message it created? Real business data is untouched.',
      'end_cancel': 'Keep testing',
    };

    testWidgets('the button, the confirm sheet and the result are payload',
        (tester) async {
      var calls = 0;
      await tester.pumpWidget(host(TestModeBanner(
        payload: live,
        onEndPurge: () async {
          calls++;
          return {
            'ok': true,
            'done': true,
            'message': 'Test session ended and its rows purged.',
          };
        },
      )));
      expect(find.text('End & purge'), findsOneWidget);
      expect(find.text('Started by tst.admin1848@medibo.invalid'), findsNothing);
      expect(
        find.text(
            'c1848 run  ·  Started by tst.admin1848@medibo.invalid  ·  Auto-ends 07 Sep 14:21'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('test_session_end_purge')));
      await tester.pumpAndSettle();
      // The confirm sheet: the backend's sentence, its button word, its cancel word.
      expect(find.textContaining('Real business data is untouched.'),
          findsOneWidget);
      expect(find.text('Keep testing'), findsOneWidget);
      expect(calls, 0);

      // Cancel first — nothing runs.
      await tester.tap(find.text('Keep testing'));
      await tester.pumpAndSettle();
      expect(calls, 0);

      // Then confirm — the runner is called exactly once and its message shows.
      await tester.tap(find.byKey(const ValueKey('test_session_end_purge')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('End & purge').last);
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(find.text('Test session ended and its rows purged.'), findsOneWidget);
    });

    testWidgets('a missing confirm sentence means no sheet — tap runs directly',
        (tester) async {
      var calls = 0;
      final payload = Map<String, dynamic>.from(live)
        ..remove('end_confirm')
        ..remove('end_cancel');
      await tester.pumpWidget(host(TestModeBanner(
        payload: payload,
        onEndPurge: () async {
          calls++;
          return {'ok': true, 'done': true, 'message': 'Done.'};
        },
      )));
      await tester.tap(find.byKey(const ValueKey('test_session_end_purge')));
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(find.text('Done.'), findsOneWidget);
    });

    testWidgets('a refusal shows the backend\'s own message, no Dart wording',
        (tester) async {
      await tester.pumpWidget(host(TestModeBanner(
        payload: Map<String, dynamic>.from(live)..remove('end_confirm'),
        onEndPurge: () async => {
          'ok': false,
          'error': 'not_owner',
          'message': 'Only the person who started this session can end it.',
        },
      )));
      await tester.tap(find.byKey(const ValueKey('test_session_end_purge')));
      await tester.pumpAndSettle();
      expect(find.text('Only the person who started this session can end it.'),
          findsOneWidget);
    });
  });
}
