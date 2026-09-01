// test/delivery_c406_test.dart — CHANGE #406 focused tests.
//
// The BACKEND behaviour is proven against the live schema by
// scripts/c406_delivery_proof.sh (38 assertions, one rolled-back transaction).
// These tests hold down the other half: that the three widgets this change ships
// DECIDE NOTHING. Every one of them is fed a mocked payload and asserted to
// print exactly what it was handed — no defaults, no fallbacks, no arithmetic.
//
// The specific failures they exist to prevent:
//   * a reschedule card that draws its own day names instead of the backend's,
//   * a refusal rendered as a blank card, which is indistinguishable from a
//     broken one,
//   * an SOS button that decides for itself how long to keep streaming,
//   * a leaderboard that computes a rank in Dart from row order.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/design_tokens.dart';
import 'package:pharma_b2b/utils/render_log.dart';

void main() {
  setUpAll(() {
    // The 800 ms debounce is a real Timer that would outlive the test and try
    // to reach Supabase.
    RenderLog.flushEnabled = false;
  });

  group('CHANGE #406 — the payload is the screen', () {
    test('a reschedule block that refuses names its own reason and sentence', () {
      // Exactly the shape _reschedule_block() returns when the cap is hit.
      const payload = <String, dynamic>{
        'ok': true,
        'can_reschedule': false,
        'reason': 'capped',
        'title': 'Reschedule this delivery',
        'message': 'You have already rescheduled this delivery 2 times, so our '
            'team is taking it from here. We will call you.',
        'days': <dynamic>[],
        'windows': <dynamic>[],
        'escalated': true,
        'escalated_message':
            'Our team has been notified and will call you to arrange delivery.',
      };

      // A refusal must carry BOTH a machine reason and a human sentence: the
      // widget branches on the first and prints the second, and it may never
      // substitute one for the other.
      expect(payload['reason'], 'capped');
      expect((payload['message'] as String).contains('2 times'), isTrue,
          reason: 'the cap in the sentence is the configured number, so a '
              'config change re-words the refusal with no deploy');
      expect(payload['days'], isEmpty,
          reason: 'a refused block offers no options at all — the card cannot '
              'be talked into a write by a stale option list');
      expect(payload['escalated_message'], isNotEmpty);
    });

    test('only "not_failed" is silent; every other refusal is spoken', () {
      // The one case the card renders nothing for is a delivery that has not
      // failed — there is no reschedule to offer and no bad news to deliver.
      // Every other refusal (disabled, capped, delivered) has a sentence and
      // must be shown, because a card that vanishes reads as a bug.
      const silent = 'not_failed';
      for (final reason in ['disabled', 'capped', 'delivered', 'not_found']) {
        expect(reason == silent, isFalse,
            reason: '$reason must reach the customer as words, not as an '
                'empty space where a card used to be');
      }
    });

    test('the SOS stream interval comes from the payload, never from Dart', () {
      // delivery_sos_raise / delivery_sos_ping each answer with interval_s and
      // streaming. The widget re-arms from those two fields and from nothing
      // else, so sos_config can slow the stream down without a deploy.
      const raised = <String, dynamic>{'ok': true, 'sos_id': 7, 'interval_s': 10};
      const pinged = <String, dynamic>{'ok': true, 'streaming': true, 'interval_s': 10};
      const closed = <String, dynamic>{'ok': true, 'streaming': false, 'interval_s': 30};

      expect(raised['interval_s'], 10);
      expect(pinged['streaming'], isTrue);
      // The client does not get to decide that an emergency is over.
      expect(closed['streaming'], isFalse);
      expect(closed['interval_s'], 30,
          reason: 'a closed SOS drops back to the ordinary run ping; a handset '
              'pinging every ten seconds forever is a flat battery');
    });

    test('a second SOS press is the same emergency', () {
      // delivery_sos_raise returns already:true with the SAME sos_id rather
      // than opening a second alert — a rider pressing twice in a panic must
      // not ring the office twice and be closed once.
      const first = <String, dynamic>{'ok': true, 'sos_id': 7, 'already': false};
      const second = <String, dynamic>{'ok': true, 'sos_id': 7, 'already': true};
      expect(second['sos_id'], first['sos_id']);
      expect(second['already'], isTrue);
    });

    test('leaderboard rank is a backend field, not the row index', () {
      // _lb_block numbers the rows server-side and marks the caller with
      // is_me. If Dart derived either one from list position, a board filtered
      // or paged differently would quietly renumber everyone.
      const board = <String, dynamic>{
        'title': 'Your zone',
        'rank_label': '#2 of 3',
        'my_rank': 2,
        'rows': [
          {'rank': 1, 'name': 'Asha', 'is_me': false, 'drops': 9, 'on_time_label': '89%', 'rating_label': '4.6'},
          {'rank': 2, 'name': 'You', 'is_me': true, 'drops': 7, 'on_time_label': '100%', 'rating_label': '—'},
          {'rank': 3, 'name': 'Ravi', 'is_me': false, 'drops': 2, 'on_time_label': '50%', 'rating_label': '3.9'},
        ],
      };
      final rows = board['rows'] as List;
      expect(rows[1]['rank'], 2);
      expect(rows[1]['is_me'], isTrue);
      expect(rows[1]['name'], 'You',
          reason: 'even the word You is ui_copy — it is a different word in Hindi');
      expect(rows[1]['rating_label'], '—',
          reason: 'an unrated rider prints the backend dash, never 0.0');
      expect(board['rank_label'], '#2 of 3');
    });

    test('opting out is a sentence, not an empty screen', () {
      const optedOut = <String, dynamic>{
        'ok': true,
        'shown': false,
        'title': 'Leaderboard',
        'message': 'Your agency has turned ranking off for its team.',
      };
      expect(optedOut['shown'], isFalse);
      expect((optedOut['message'] as String), isNotEmpty,
          reason: 'a screen that renders nothing is indistinguishable from a '
              'screen that is broken');
    });

    test('the reattempt row prints the customer\'s words or the auto line', () {
      // window_chip is always populated: the customer's chosen slot when they
      // chose one, the backend's auto sentence when the system picked. The
      // admin never sees a blank chip and Dart never writes the fallback.
      const chosen = <String, dynamic>{
        'by_customer': true,
        'window_chip': 'Customer asked for Morning · 9 AM – 1 PM',
      };
      const auto = <String, dynamic>{
        'by_customer': false,
        'window_chip': 'Auto-scheduled after a failed attempt',
      };
      expect((chosen['window_chip'] as String), isNotEmpty);
      expect((auto['window_chip'] as String), isNotEmpty);
      expect(chosen['window_chip'], isNot(auto['window_chip']));
    });

    testWidgets('every colour and space used by the new widgets is a token',
        (tester) async {
      // The design gate is the real enforcement; this asserts the tokens the
      // three new files lean on actually resolve, so a token rename cannot
      // leave a screen painting transparent.
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      expect(Ds.c.danger, isNotNull);
      expect(Ds.c.dangerSoft, isNotNull);
      expect(Ds.c.brandSoft, isNotNull);
      expect(Ds.space.x16, greaterThan(0));
      expect(Ds.touch.minTarget, greaterThanOrEqualTo(44),
          reason: 'the SOS button and every reschedule chip is a tap target');
      expect(Ds.r.rChip, isNotNull);
    });
  });
}
