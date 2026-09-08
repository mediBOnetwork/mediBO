// PROTECTED — the loyalty engine's client contract (CHANGE #176).
//
// The whole rewards system is backend: Postgres decides the tier, adds up the
// points, works out the gap to the next threshold and formats every ₹. This
// file holds down the only thing the client is allowed to do — decide which
// sections exist and print what arrived, verbatim.
//
// What these tests exist to prevent, concretely:
//   • a programme Om switched OFF still rendering (money promised that the
//     engine will not pay),
//   • Dart re-deriving a label the backend already sent (the two drift, and the
//     screen starts lying about a balance),
//   • the client re-sorting targets so the order on screen stops matching the
//     order the backend ranked them in.
//
// Pure Dart, no widget tree, no network — the decisions live in RewardsView
// precisely so they can be tested this way.

import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/models/loyalty.dart';

/// A payload shaped exactly like loyalty_my_rewards() returns, with all five
/// programmes running. Values are the real strings the backend produced in
/// testing, not invented ones.
Map<String, dynamic> _fullPayload() => <String, dynamic>{
      'ok': true,
      'title': 'Rewards',
      'has_account': true,
      'any_on': true,
      'tier': {
        'on': true,
        'title': 'Your status',
        'has': true,
        'current_label': 'Gold',
        'progress_label': '₹21,220.19 more to reach Platinum',
        'progress_pct': 0.7878,
      },
      'points': {
        'on': true,
        'title': 'Points',
        'balance': 189.35,
        'balance_label': '189 points',
        'worth_label': 'Worth ₹189.35',
        'min_label': 'Redeem from 100 points',
        'redeem_label': 'Redeem',
        'can_redeem': true,
      },
      'targets': {
        'on': true,
        'title': 'Targets',
        'items': [
          {
            'id': 2,
            'name': 'Monthly 60k',
            'progress_label': 'Target reached',
            'reward_label': '₹1,500.00',
            'progress_pct': 1.0,
          },
          {
            'id': 1,
            'name': 'Monthly 25k',
            'progress_label': '₹78,779.81 of ₹25,000.00',
            'reward_label': '₹500.00',
            'progress_pct': 1.0,
          },
        ],
      },
      'streak': {
        'on': true,
        'title': 'Streak',
        'count': 1,
        'count_label': '1 in a row',
        'next_label': 'Order within 30 days to keep it',
        'next_reward_label': '₹250.00',
      },
      'referral': {
        'on': true,
        'title': 'Refer a pharmacy',
        'code_label': 'Your code',
        'code': 'MB4F2A91',
        'note': 'Both of you get rewarded on their first qualifying order.',
      },
    };

void main() {
  group('which sections render', () {
    test('all five programmes on → five sections in payload order', () {
      final v = RewardsView(_fullPayload());
      expect(v.sections.map((s) => s.key).toList(),
          <String>['tier', 'points', 'targets', 'streak', 'referral']);
    });

    test('a programme switched off in admin renders NOTHING', () {
      // This is the money test: loyalty_program_set(enabled:false) makes the
      // backend send {"on": false}, and the section must vanish — not render
      // empty, not render stale numbers.
      final p = _fullPayload();
      p['tier'] = {'on': false};
      p['referral'] = {'on': false};

      final v = RewardsView(p);
      expect(v.sections.map((s) => s.key).toList(),
          <String>['points', 'targets', 'streak']);
      expect(v.isOn('tier'), isFalse);
    });

    test('absence is off — a missing programme key is never guessed on', () {
      final p = _fullPayload();
      p.remove('streak');
      final v = RewardsView(p);
      expect(v.isOn('streak'), isFalse);
      expect(v.sections.any((s) => s.key == 'streak'), isFalse);
    });

    test('on must be exactly true — a truthy-looking value is still off', () {
      for (final junk in <Object>['true', 1, 'yes']) {
        final p = _fullPayload();
        p['points'] = {'on': junk, 'title': 'Points'};
        expect(RewardsView(p).isOn('points'), isFalse,
            reason: 'on:$junk (${junk.runtimeType}) must not enable a programme');
      }
    });

    test('nothing on at all → the backend own empty state, not a blank list',
        () {
      final v = RewardsView(<String, dynamic>{
        'ok': true,
        'title': 'Rewards',
        'has_account': true,
        'any_on': false,
        'off_title': 'Rewards are not running yet',
        'off_note': 'When mediBO starts a rewards programme it will appear here.',
      });
      expect(v.anyOn, isFalse);
      expect(v.sections, isEmpty);
      expect(v.str('off_title'), 'Rewards are not running yet');
    });
  });

  group('strings are printed, never computed', () {
    test('tier, points and streak labels come through verbatim', () {
      final v = RewardsView(_fullPayload());
      final tier = v.section('tier');
      final points = v.section('points');
      final streak = v.section('streak');

      expect(tier['current_label'], 'Gold');
      expect(tier['progress_label'], '₹21,220.19 more to reach Platinum');
      // 189.35 balance renders as the backend's "189 points" — Dart must not
      // round, truncate or pluralise it into something else.
      expect(points['balance_label'], '189 points');
      expect(points['worth_label'], 'Worth ₹189.35');
      expect(streak['count_label'], '1 in a row');
      expect(streak['next_reward_label'], '₹250.00');
    });

    test('section headings are the backend copy', () {
      final v = RewardsView(_fullPayload());
      expect(
        {for (final s in v.sections) s.key: s.title},
        <String, String>{
          'tier': 'Your status',
          'points': 'Points',
          'targets': 'Targets',
          'streak': 'Streak',
          'referral': 'Refer a pharmacy',
        },
      );
    });
  });

  group('targets', () {
    test('items render in payload order — the fixture is NOT sorted by id', () {
      final v = RewardsView(_fullPayload());
      final items = RewardsView.items(v.section('targets'));
      expect(items.map((e) => e['id']).toList(), <int>[2, 1]);
      expect(items.first['name'], 'Monthly 60k');
    });

    test('a targets section with no items yields an empty list, not a throw',
        () {
      final v = RewardsView(<String, dynamic>{
        'any_on': true,
        'targets': {'on': true, 'title': 'Targets'},
      });
      expect(RewardsView.items(v.section('targets')), isEmpty);
    });
  });

  group('redeem is the backend decision', () {
    test('can_redeem true enables it', () {
      expect(RewardsView.canRedeem(RewardsView(_fullPayload()).section('points')),
          isTrue);
    });

    test('a balance above the minimum does NOT enable it on its own', () {
      // The client must never infer "they have enough points" — only the
      // backend knows the minimum, the rate, and whether points are running.
      final points = <String, dynamic>{
        'on': true,
        'balance': 5000,
        'min_label': 'Redeem from 100 points',
        'can_redeem': false,
      };
      expect(RewardsView.canRedeem(points), isFalse);
    });
  });

  test('a PostgREST list-wrapped payload is unwrapped like every other RPC', () {
    final v = RewardsView(RewardsView.asMap([_fullPayload()]));
    expect(v.anyOn, isTrue);
    expect(v.sections.length, 5);
  });
}
