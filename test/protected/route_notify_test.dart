// PROTECTED — CMD #1876.
//
// What this holds down: the route card's two new verbs are the BACKEND's, and
// the client is only allowed to print them.
//
//  • route_message_stops() reports counts in words. Dart must never build
//    "3 sent" from the number — sent_label / skipped_label / summary_label are
//    printed verbatim, including when they are worded singular.
//  • a skipped stop keeps its own reason sentence; an untoned or unknown tone
//    falls back to WARNING, never to success, so a future tone name added
//    server-side cannot make a failed send look green on an old build.
//  • rows render in the backend's order — the stop sequence a worker walks —
//    never sorted or grouped in Dart.
//  • the assignment's WhatsApp verdict survives whether or not it was sent:
//    ok:false still carries the sentence that says why.
//  • /admin/customers?tab=routes&route=<uuid> opens ONE route; a link with no
//    route id stays the old tab-only link; a blank route= is not a route.
//
// Pure Dart, no network, no Supabase.

import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/route_notify.dart';

Map<String, dynamic> _stopsPayload() => {
      'ok': true,
      'route_id': 'bbbb',
      'title': 'Visiting today — Pandri loop',
      'sent': 1,
      'skipped': 2,
      'total': 3,
      // Deliberately singular: the backend chose the wording, not Dart.
      'sent_label': '1 shop messaged',
      'skipped_label': '2 skipped',
      'summary_label': '1 sent · 2 skipped of 3 stops',
      'rows': [
        {
          'seq': 1,
          'name': 'Sharma Medical Store',
          'ok': true,
          'tone': 'success',
          'label': 'sent',
          'reason': null,
        },
        {
          'seq': 2,
          'name': 'Verma Pharmacy',
          'ok': false,
          'tone': 'warning',
          'label': 'opted out of promotions',
          'reason': 'suppressed',
        },
        {
          'seq': 3,
          'name': 'City Chemists',
          'ok': false,
          // A tone this build has never heard of.
          'tone': 'plaid',
          'label': 'no WhatsApp number',
          'reason': 'no_phone',
        },
      ],
    };

void main() {
  group('route_message_stops payload', () {
    test('counts are printed in the backend words, never rebuilt in Dart', () {
      final r = RouteMessageResult.fromPayload(_stopsPayload());
      expect(r.ok, isTrue);
      expect(r.sent, 1);
      expect(r.skipped, 2);
      expect(r.total, 3);
      // The words are the backend's — including a singular the client would
      // have got wrong by concatenating "$sent sent".
      expect(r.sentLabel, '1 shop messaged');
      expect(r.skippedLabel, '2 skipped');
      expect(r.summaryLabel, '1 sent · 2 skipped of 3 stops');
      expect(r.title, 'Visiting today — Pandri loop');
    });

    test('rows keep the backend order and each keeps its own reason', () {
      final rows = RouteMessageResult.fromPayload(_stopsPayload()).orderedRows;
      expect(rows.map((e) => e.name).toList(),
          ['Sharma Medical Store', 'Verma Pharmacy', 'City Chemists']);
      expect(rows[0].ok, isTrue);
      expect(rows[1].label, 'opted out of promotions');
      expect(rows[1].reason, 'suppressed');
      expect(rows[2].label, 'no WhatsApp number');
      expect(rows[2].reason, 'no_phone');
    });

    test('an unknown tone degrades to warning, never to success', () {
      final rows = RouteMessageResult.fromPayload(_stopsPayload()).orderedRows;
      expect(rows[0].tone, 'success');
      expect(rows[1].tone, 'warning');
      expect(rows[2].tone, 'warning'); // 'plaid'
    });

    test('a refusal carries the backend message and no invented counts', () {
      final r = RouteMessageResult.fromPayload({
        'ok': false,
        'error': 'not_in_zone',
        'message': 'outside the active zone',
      });
      expect(r.ok, isFalse);
      expect(r.errorMessage, 'outside the active zone');
      expect(r.rows, isEmpty);
      expect(r.sent, 0);
      expect(r.summaryLabel, '');
    });

    test('an empty route reports the backend empty line, not "0 sent"', () {
      final r = RouteMessageResult.fromPayload({
        'ok': true,
        'sent': 0,
        'skipped': 0,
        'total': 0,
        'sent_label': '0 sent',
        'skipped_label': '0 skipped',
        'summary_label': 'This route has no included stops yet',
        'rows': [],
      });
      expect(r.summaryLabel, 'This route has no included stops yet');
      expect(r.orderedRows, isEmpty);
    });
  });

  group('route_plan_assign verdict', () {
    test('a sent WhatsApp carries the backend sentence', () {
      final a = RouteAssignResult.fromPayload({
        'ok': true,
        'assignment_id': 'a-1',
        'route_link': 'https://medibo.in/admin/customers?tab=routes&route=bbbb',
        'wa': {
          'ok': true,
          'reason': null,
          'label': 'WhatsApp sent to Ramesh Kumar',
          'phone': '9111100001',
        },
        'message': 'Ramesh Kumar assigned 3 stops on Pandri loop — '
            'WhatsApp sent to Ramesh Kumar',
      });
      expect(a.ok, isTrue);
      expect(a.waSent, isTrue);
      expect(a.waLabel, 'WhatsApp sent to Ramesh Kumar');
      expect(a.routeLink, contains('route=bbbb'));
    });

    test('a BLOCKED WhatsApp still says why — the assignment is not silent',
        () {
      final a = RouteAssignResult.fromPayload({
        'ok': true,
        'assignment_id': 'a-2',
        'wa': {
          'ok': false,
          'reason': 'route_disabled',
          'label': 'Assigned. WhatsApp not sent — template still awaiting '
              'WhatsApp approval',
        },
        'message': 'Ramesh Kumar assigned 3 stops on Pandri loop — Assigned. '
            'WhatsApp not sent — template still awaiting WhatsApp approval',
      });
      expect(a.ok, isTrue); // the ASSIGNMENT still happened
      expect(a.waSent, isFalse);
      expect(a.waReason, 'route_disabled');
      expect(a.waLabel, isNotEmpty);
      expect(a.message, contains('not sent'));
    });

    test('a missing wa block is a not-sent, not a crash', () {
      final a = RouteAssignResult.fromPayload({'ok': true, 'message': 'done'});
      expect(a.waSent, isFalse);
      expect(a.waLabel, '');
    });
  });

  group('the route deep link', () {
    test('?tab=routes&route=<uuid> opens ONE route', () {
      final l = RouteDeepLink.parse(
          '?tab=routes&route=bbbbbbbb-0000-0000-0000-000000001872');
      expect(l.opensRoute, isTrue);
      expect(l.routeId, 'bbbbbbbb-0000-0000-0000-000000001872');
    });

    test('a tab-only link stays a tab link', () {
      final l = RouteDeepLink.parse('?tab=sLeads');
      expect(l.opensRoute, isFalse);
      expect(l.tab, 'sLeads');
      expect(l.routeId, isNull);
    });

    test('a blank or absent route= is not a route', () {
      expect(RouteDeepLink.parse('?tab=routes&route=').opensRoute, isFalse);
      expect(RouteDeepLink.parse('').opensRoute, isFalse);
      expect(RouteDeepLink.parse('?').opensRoute, isFalse);
    });

    test('a leading ? is optional — the shell passes it either way', () {
      expect(RouteDeepLink.parse('tab=routes&route=x').routeId, 'x');
      expect(RouteDeepLink.parse('?tab=routes&route=x').routeId, 'x');
    });
  });
}
