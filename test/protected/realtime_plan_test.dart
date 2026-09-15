// CHANGE #643 — the realtime plan is the BACKEND's, and the app obeys it.
//
// The app once opened 29 postgres_changes bindings because each screen decided
// for itself what deserved one, and every table it named had to be added to the
// publication to keep that screen working. That produced 7.44M realtime
// messages in a cycle (149% of the 5M allowance) with zero customers online.
//
// realtime_plan() now says, per table, live or poll and how often; LiveFeed
// only routes. This holds down the routing rule, because it is the one place
// where "just make this one live" would quietly undo the whole change:
//   * live means the PLAN said live — never the caller's preference;
//   * a table the plan says must be filtered, watched WITHOUT a filter, polls;
//   * a table the plan has never heard of polls (forward compatible);
//   * an unreadable plan polls EVERYTHING, never the reverse;
//   * the poll interval is the backend's smallest, never a Dart constant.

import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/services/live_feed.dart';

LiveFeedPlan planOf(Map<String, Map<String, Object?>> tables,
        {int defaultPoll = 30}) =>
    LiveFeedPlan(
      tables.map((k, v) => MapEntry(
          k, LiveFeedTablePlan.fromJson(Map<String, dynamic>.from(v), defaultPoll))),
      defaultPoll,
    );

void main() {
  group('LiveFeedRouting.split — the backend decides the transport', () {
    test('live means the plan said live; poll means the plan said poll', () {
      final plan = planOf({
        'cart_items': {'mode': 'live', 'filter_required': false, 'poll_seconds': 30},
        'orders': {'mode': 'poll', 'filter_required': false, 'poll_seconds': 30},
      });

      final r = LiveFeedRouting.split(plan, ['cart_items', 'orders'], const {});

      expect(r.live, ['cart_items']);
      expect(r.polled, ['orders']);
    });

    test('a filter_required table watched without a filter is POLLED', () {
      // This is the rule that keeps a "just add pharmacy_profiles to this
      // screen" from re-opening an unfiltered fan-out on a table every admin
      // session subscribes to.
      final plan = planOf({
        'pharmacy_profiles': {
          'mode': 'live',
          'filter_required': true,
          'poll_seconds': 30,
        },
      });

      final unfiltered =
          LiveFeedRouting.split(plan, ['pharmacy_profiles'], const {});
      expect(unfiltered.live, isEmpty);
      expect(unfiltered.polled, ['pharmacy_profiles']);

      final filtered =
          LiveFeedRouting.split(plan, ['pharmacy_profiles'], {'pharmacy_profiles'});
      expect(filtered.live, ['pharmacy_profiles']);
      expect(filtered.polled, isEmpty);
    });

    test('a table the plan has never heard of polls at the default', () {
      final plan = planOf({
        'cart_items': {'mode': 'live', 'filter_required': false, 'poll_seconds': 30},
      }, defaultPoll: 45);

      final r = LiveFeedRouting.split(plan, ['a_table_added_tomorrow'], const {});

      expect(r.live, isEmpty);
      expect(r.polled, ['a_table_added_tomorrow']);
      expect(r.pollSeconds, 45);
    });

    test('the interval is the smallest the BACKEND named for the polled set', () {
      final plan = planOf({
        'delivery_partner_locations': {
          'mode': 'poll',
          'filter_required': false,
          'poll_seconds': 15,
        },
        'orders': {'mode': 'poll', 'filter_required': false, 'poll_seconds': 30},
      }, defaultPoll: 30);

      final r = LiveFeedRouting.split(
          plan, ['orders', 'delivery_partner_locations'], const {});

      expect(r.polled, ['orders', 'delivery_partner_locations']);
      expect(r.pollSeconds, 15);
    });

    test('an unreadable plan polls everything — never the other way round', () {
      // LiveFeedPlan.fallback is what _loadPlan returns when realtime_plan()
      // cannot be read. A missing answer must never be read as permission.
      final r = LiveFeedRouting.split(
        LiveFeedPlan.fallback,
        ['cart_items', 'order_items', 'whatsapp_messages'],
        {'cart_items'},
      );

      expect(r.live, isEmpty);
      expect(r.polled, ['cart_items', 'order_items', 'whatsapp_messages']);
      expect(r.pollSeconds, 30);
    });

    test('the caller asking for a table does not make it live', () {
      // FulfillRealtime still NAMES ten tables — that list is what the Fulfill
      // area cares about. Only the plan decides which of them are bound.
      final plan = planOf({
        'order_items': {'mode': 'live', 'filter_required': false, 'poll_seconds': 30},
        'bag_item_counts': {'mode': 'live', 'filter_required': false, 'poll_seconds': 30},
        'orders': {'mode': 'poll', 'filter_required': false, 'poll_seconds': 30},
        'supplier_orders': {'mode': 'poll', 'filter_required': false, 'poll_seconds': 30},
        'voice_clip_mentions': {'mode': 'poll', 'filter_required': false, 'poll_seconds': 30},
      });

      final r = LiveFeedRouting.split(
        plan,
        const [
          'order_items',
          'supplier_orders',
          'orders',
          'bag_item_counts',
          'voice_clip_mentions',
        ],
        const {},
      );

      expect(r.live, ['order_items', 'bag_item_counts']);
      expect(r.polled, ['supplier_orders', 'orders', 'voice_clip_mentions']);
    });
  });

  group('LiveFeedTablePlan.fromJson — absence is poll, not live', () {
    test('a payload with no mode is a poll', () {
      final p = LiveFeedTablePlan.fromJson(const {}, 30);
      expect(p.isLive, isFalse);
      expect(p.pollSeconds, 30);
      expect(p.filterRequired, isFalse);
    });

    test('filter_required is true only when the backend says true', () {
      expect(
        LiveFeedTablePlan.fromJson(
            const {'mode': 'live', 'filter_required': 'yes'}, 30).filterRequired,
        isFalse,
      );
      expect(
        LiveFeedTablePlan.fromJson(
            const {'mode': 'live', 'filter_required': true}, 30).filterRequired,
        isTrue,
      );
    });
  });
}
