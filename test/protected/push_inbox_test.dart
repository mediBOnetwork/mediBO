// PROTECTED — CHANGE #298 (PART 2 of the notification rebuild).
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes push / inbox / deep-link behaviour.
//
// What this holds down:
//
//   1. THE INBOX PRINTS, IT DOES NOT WRITE. Title, body, channel label and the
//      timestamp label all come from the payload. A row the backend sent
//      without a body renders NO body line — never a placeholder sentence —
//      and the same for the channel chip. This is the whole reason the inbox
//      exists: it is a faithful record of what was sent, on every channel.
//
//   2. DEEP LINKS NEVER FALL BACK TO HOME (spec item 5). A notification opens
//      the exact screen or it opens nothing. deep_link '' and deep_link '/'
//      are both "nowhere" — if either ever started routing, every push would
//      quietly dump the user on the storefront, which is precisely the bug
//      this part of the rebuild was written to prevent. An absolute backend
//      link (the supplier form on medibo.in) is reduced to its PATH so the
//      in-app router can match it, and is not otherwise rewritten.
//
//   3. PAGING IS THE BACKEND'S has_more, and appending a page never
//      duplicates a row. The inbox pages by offset over a table that is
//      actively being written to, so a row can shift across a page boundary
//      between two reads; dedupe by id is what stops the same notification
//      being painted twice.
//
//   4. "Mark all read" appears only when the backend sent the caption AND
//      there is something to mark — the caption is not invented, and an empty
//      inbox does not offer to mark nothing.
//
//   5. THE ORDER DEEP LINK IS PARSED IN ONE PLACE. A push, an inbox tap and a
//      pasted URL all read `/my-order/<order_code>` through
//      InboxItem.orderCodeFrom, so they cannot drift apart, and the code is
//      taken verbatim — the app never checks what a valid order code looks
//      like. This is spec item 5: the notification opens the EXACT order.
//
//   6. THE ADMIN PUSH SCREEN IS REACHABLE. #645/#646 shipped screens that
//      existed and compiled but had no nav entry, so on a phone there was no
//      way in at all — three deploys deep before anyone noticed. A screen the
//      overflow nav does not name does not exist, so the entry is pinned here
//      rather than trusted.
//
// Pure Dart: no network, no Supabase, no widgets, no goldens. The screen's
// decisions live in InboxPage/InboxItem exactly so this suite stays on the VM.

import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/models/notification_inbox.dart';
import 'package:pharma_b2b/screens/admin/admin_nav_entries.dart';

/// Mirrors a real notif_inbox_list() payload.
Map<String, dynamic> _payload({
  List<Map<String, dynamic>>? items,
  bool hasMore = false,
  int total = 0,
  String markAll = 'Mark all read',
}) =>
    {
      'ok': true,
      'title': 'Notifications',
      'empty_title': 'No notifications yet',
      'empty_hint':
          'Order updates, payment reminders and delivery alerts will appear here.',
      'mark_all': markAll,
      'load_more': 'Load more',
      'items': items ?? const [],
      'total': total,
      'has_more': hasMore,
    };

Map<String, dynamic> _row(
  int id, {
  String title = 'Order placed',
  String body = 'Order CPO1 is in.',
  String deepLink = '/my-order/CPO1',
  String channel = 'Push',
  String when = '23 Aug 2026, 4:01 PM',
  bool unread = true,
}) =>
    {
      'id': id,
      'event_key': 'order_placed',
      'title': title,
      'body': body,
      'deep_link': deepLink,
      'channel': channel.toLowerCase(),
      'channel_label': channel,
      'when_label': when,
      'unread': unread,
      'status': 'sent',
    };

void main() {
  group('1. the inbox prints the backend verbatim', () {
    test('every visible string is carried through, none authored in Dart', () {
      final p = InboxPage.fromJson(_payload(items: [_row(7)], total: 1));

      expect(p.title, 'Notifications');
      expect(p.emptyTitle, 'No notifications yet');
      expect(p.loadMoreLabel, 'Load more');

      final r = p.items.single;
      expect(r.id, 7);
      expect(r.title, 'Order placed');
      expect(r.body, 'Order CPO1 is in.');
      expect(r.channelLabel, 'Push');
      // The timestamp is a backend-formatted IST string. Dart does no date
      // math and must not reformat it.
      expect(r.whenLabel, '23 Aug 2026, 4:01 PM');
      expect(r.unread, isTrue);
    });

    test('an absent body is absent, not a default sentence', () {
      final r = InboxPage.fromJson(_payload(items: [_row(1, body: '')]))
          .items
          .single;
      expect(r.body, '');
      expect(r.hasBody, isFalse,
          reason: 'an empty body must render no line at all');
    });

    test('an absent channel label draws no chip', () {
      final r = InboxPage.fromJson(_payload(items: [_row(1, channel: '')]))
          .items
          .single;
      expect(r.hasChannel, isFalse);
    });

    test('a row missing every optional key does not throw', () {
      final r = InboxItem.fromJson(const {'id': 3});
      expect(r.id, 3);
      expect(r.title, '');
      expect(r.hasBody, isFalse);
      expect(r.canOpen, isFalse);
      expect(r.unread, isFalse);
    });
  });

  group('2. deep links open the exact screen or nothing', () {
    test('an app route is passed through untouched', () {
      final r = InboxItem.fromJson(_row(1, deepLink: '/my-order/CPO230826CHAO1'));
      expect(r.canOpen, isTrue);
      expect(r.route, '/my-order/CPO230826CHAO1');
    });

    test('empty deep_link opens nothing', () {
      final r = InboxItem.fromJson(_row(1, deepLink: ''));
      expect(r.canOpen, isFalse);
      expect(r.route, isNull);
    });

    test('deep_link "/" is nowhere, NOT the app home', () {
      final r = InboxItem.fromJson(_row(1, deepLink: '/'));
      expect(r.canOpen, isFalse,
          reason: 'a notification must never dump the user on the storefront');
      expect(r.route, isNull);
    });

    test('an absolute backend link is reduced to its path, not rewritten', () {
      final r = InboxItem.fromJson(
          _row(1, deepLink: 'https://medibo.in/SPO300726TOP012I1/jerps'));
      expect(r.route, '/SPO300726TOP012I1/jerps',
          reason: 'the router matches paths; case and secret stay verbatim');
    });

    test('whitespace around a link is trimmed but the link is not touched', () {
      final r = InboxItem.fromJson(_row(1, deepLink: '  /my-order/CPO9  '));
      expect(r.route, '/my-order/CPO9');
    });
  });

  group('3. paging is the backend\'s, and never duplicates', () {
    test('has_more comes from the payload, not from the page size', () {
      expect(InboxPage.fromJson(_payload(items: [_row(1)], hasMore: true)).hasMore,
          isTrue);
      expect(
          InboxPage.fromJson(_payload(items: [_row(1)], hasMore: false)).hasMore,
          isFalse,
          reason: 'a full page with has_more:false is the END of the list');
    });

    test('appending a page that re-sends a row does not paint it twice', () {
      final first = InboxPage.fromJson(
          _payload(items: [_row(10), _row(9), _row(8)], hasMore: true)).items;
      // A new notification arrived between the two reads, so the second page
      // overlaps the first — the real hazard of offset paging.
      final second =
          InboxPage.fromJson(_payload(items: [_row(8), _row(7)])).items;

      final merged = InboxPage.append(first, second);
      expect(merged.map((e) => e.id).toList(), [10, 9, 8, 7]);
    });

    test('append preserves payload order and adds nothing of its own', () {
      final merged = InboxPage.append(
        InboxPage.fromJson(_payload(items: [_row(5), _row(3)])).items,
        InboxPage.fromJson(_payload(items: [_row(4), _row(1)])).items,
      );
      expect(merged.map((e) => e.id).toList(), [5, 3, 4, 1],
          reason: 'no client-side sort — the backend already ordered these');
    });
  });

  group('4. mark-all appears only when it means something', () {
    test('hidden on an empty inbox', () {
      expect(InboxPage.fromJson(_payload()).showMarkAll, isFalse);
    });

    test('hidden when the backend sent no caption', () {
      expect(
          InboxPage.fromJson(_payload(items: [_row(1)], markAll: '')).showMarkAll,
          isFalse,
          reason: 'the caption is a backend string, never a Dart literal');
    });

    test('shown when there are rows and a caption', () {
      final p = InboxPage.fromJson(_payload(items: [_row(1)]));
      expect(p.showMarkAll, isTrue);
      expect(p.markAllLabel, 'Mark all read');
    });
  });

  group('5. the order deep link is read in exactly one place', () {
    test('the order code is taken verbatim, never validated or cased', () {
      expect(InboxItem.orderCodeFrom('/my-order/CPO300726TOP012I1'),
          'CPO300726TOP012I1');
      expect(InboxItem.orderCodeFrom('/my-order/lower-case-99'),
          'lower-case-99',
          reason: 'order_code is the backend\'s string; the app has no pattern');
    });

    test('a query or fragment is dropped, the code is not', () {
      expect(InboxItem.orderCodeFrom('/my-order/CPO1?from=push'), 'CPO1');
      expect(InboxItem.orderCodeFrom('/my-order/CPO1#top'), 'CPO1');
    });

    test('any other route is not an order link', () {
      for (final r in ['/', '', '/orders', '/my-order/', '/my-orders/CPO1']) {
        expect(InboxItem.orderCodeFrom(r), isNull, reason: 'route: "$r"');
      }
      expect(InboxItem.orderCodeFrom(null), isNull);
    });

    test('an inbox row routes through the SAME parser as a push', () {
      final row = InboxItem.fromJson(_row(1, deepLink: '/my-order/CPO9'));
      expect(InboxItem.orderCodeFrom(row.route), 'CPO9');
    });
  });

  group('6. the new admin surface is reachable, not merely built', () {
    test('the overflow nav names the push screen exactly once', () {
      final hits =
          kAdminOverflowNav.where((e) => e.route == 'admin_push').toList();
      expect(hits, hasLength(1),
          reason: 'a screen the nav does not name cannot be opened at all');
    });

    test('it sits beside the Notification Centre, its sibling surface', () {
      final routes = kAdminOverflowNav.map((e) => e.route).toList();
      expect(routes.indexOf('admin_push'),
          routes.indexOf('notify_center') + 1);
    });

    test('every overflow entry still carries a route', () {
      for (final e in kAdminOverflowNav) {
        expect(e.route, isNotNull, reason: 'entry "${e.label}" does nothing');
        expect(e.route, isNotEmpty, reason: 'entry "${e.label}" does nothing');
      }
    });
  });
}
