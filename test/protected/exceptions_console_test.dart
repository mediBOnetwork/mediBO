// PROTECTED — CHANGE #690: the exceptions console (register row feature_gaps #74).
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes exceptions-console behaviour.
//
// The register row's complaint was not "there is no screen". It was that seven
// different tables held stuck objects with no owner, no age and no recorded
// ending — so the one thing this screen must never do is re-decide any of that
// on the client. What this holds down:
//
//   1. PAYLOAD ORDER IS THE QUEUE. `exceptions_queue()` ranks by age × severity;
//      the fixture is deliberately NOT in age order and NOT in severity order,
//      so a client-side sort by either one fails here. A 30-hour dispute
//      outranking a 44-day count mismatch is the backend's judgement.
//   2. NOTHING IS COMPUTED. The reason label, the age, the SLA sentence, the
//      owner line, the status and the outcome all print verbatim. No
//      pluralisation, no clock arithmetic, no "N items" built in Dart.
//   3. THE NEXT ACTION IS THE BACKEND'S DISPATCH. kind:'rpc' sends the
//      exception id to exceptions_action and prints the reply's own message —
//      including when that reply is a REFUSAL, which is how a WhatsApp retry
//      with no number must read. kind:'route' calls nobody and navigates with
//      the backend's own route key.
//   4. CLOSING RECORDS AN OUTCOME. The sheet offers exactly the outcomes the
//      payload sent, in payload order; submit is dead until one is picked; and
//      the id + outcome_code that leave the screen are the ones it was given.
//   5. can_close:false HAS NO CLOSE BUTTON. Read-only access is a flag on the
//      row, never a thing the screen infers from a role.
//   6. A refusal renders the backend's own message instead of throwing, and an
//      empty queue renders the backend's empty_label.
//   7. A reason_code this build has never seen still renders, because its label
//      travelled with it — the backend can add an eighth source with no deploy.
//
// No network, no Supabase, no goldens. Fixtures mirror payloads read off the
// live database on 2026-09-02.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/exceptions_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

// ── Fixtures ────────────────────────────────────────────────────────────────

Map<String, dynamic> _row({
  required String id,
  required String reasonCode,
  required String reasonLabel,
  required String title,
  String subtitle = '',
  String ageLabel = '',
  String slaLabel = '',
  String ownerLabel = '',
  String statusLabel = 'Open',
  String outcomeLabel = '',
  String tone = 'warn',
  bool canClose = true,
  String stageChip = '',
  Map<String, dynamic>? link,
  Map<String, dynamic>? action,
}) =>
    {
      'id': id,
      'reason_code': reasonCode,
      'reason_label': reasonLabel,
      'title': title,
      'subtitle': subtitle,
      'age_label': ageLabel,
      'sla_label': slaLabel,
      'owner_label': ownerLabel,
      'status_label': statusLabel,
      'outcome_label': outcomeLabel,
      'tone': tone,
      'stage_chip': stageChip,
      'link': link ??
          const {'has': false, 'label': 'Open', 'route': ''},
      'close_label': 'Close',
      'can_close': canClose,
      'next_action': action ??
          {
            'has': true,
            'kind': 'route',
            'label': 'Open the dispute',
            'rpc': '',
            'args': <String, dynamic>{},
            'route': 'dispute',
          },
    };

// Deliberately out of order twice over: the OLDEST row (1056 hours) is last,
// and the HIGHEST severity row is second. Only age × severity, computed in the
// backend, produces the order the payload arrived in.
final _rows = <Map<String, dynamic>>[
  _row(
    id: 'sla_breach:orders_open/abc',
    reasonCode: 'sla_breach',
    reasonLabel: 'Past SLA',
    title: 'ORD-2291',
    subtitle: 'Orders never closed · Shree Medical',
    ageLabel: '9 days old',
    slaLabel: '144h past deadline',
    ownerLabel: 'Owner: Jai Mahakal Medical And Surgical',
    tone: 'bad',
    action: const {
      'has': true,
      'kind': 'route',
      'label': 'Open the queue',
      'rpc': '',
      'args': <String, dynamic>{},
      'route': 'orders',
    },
  ),
  _row(
    id: 'dispute_open:aaaaaaaa-0690-4690-8690-aaaaaaaaaaaa',
    reasonCode: 'dispute_open',
    reasonLabel: 'Dispute open',
    title: 'C690 QA PROBE',
    subtitle: 'UMA MEDICAL STORES',
    ageLabel: '30 hours old',
    slaLabel: '6h past deadline',
    ownerLabel: 'Owner: Jai Mahakal Medical And Surgical',
    tone: 'bad',
  ),
  _row(
    id: 'wa_send_failed:8799',
    reasonCode: 'wa_send_failed',
    reasonLabel: 'WhatsApp refused',
    title: 'rate limit reached',
    subtitle: 'order_placed',
    ageLabel: '9 hours old',
    slaLabel: '3h past deadline',
    ownerLabel: 'Owner: mediBO admin',
    tone: 'warn',
    stageChip: 'No stage',
    link: const {'has': true, 'label': 'Open', 'route': 'wa_ops'},
    action: const {
      'has': true,
      'kind': 'rpc',
      'label': 'Retry the send',
      'rpc': 'exceptions_action',
      'args': {'p_id': 'wa_send_failed:8799'},
      'route': 'wa_ops',
    },
  ),
  _row(
    id: 'count_variance:b8d20334',
    reasonCode: 'count_variance',
    reasonLabel: 'Count mismatch',
    title: 'Doberol Capsule',
    subtitle: 'UMA MEDICAL STORES',
    ageLabel: '44 days old',
    slaLabel: '1032h past deadline',
    ownerLabel: 'Owner: Jai Mahakal Medical And Surgical',
    tone: 'bad',
    canClose: false,
    stageChip: 'Stage: Count',
    link: const {'has': true, 'label': 'Open', 'route': 'warehouse'},
    action: const {
      'has': true,
      'kind': 'route',
      'label': 'Open the recount',
      'rpc': '',
      'args': <String, dynamic>{},
      'route': 'warehouse',
    },
  ),
];

Map<String, dynamic> _payload({
  List<Map<String, dynamic>>? rows,
  String emptyLabel = 'Nothing is stuck. Every queue is inside its deadline.',
}) =>
    {
      'ok': true,
      'title': 'Exceptions',
      'subtitle': 'Everything stuck, oldest and worst first.',
      'zone_label': 'Raipur Zone',
      'count': (rows ?? _rows).length,
      'count_label': '${(rows ?? _rows).length} open',
      'tone': 'warn',
      'empty_label': emptyLabel,
      'filter_label': 'Filter by reason',
      'refresh_label': 'Refresh',
      'retry_label': 'Retry',
      'can_write': true,
      'filters': const [
        {'key': 'all', 'label': 'All', 'count': 4, 'selected': true},
        {
          'key': 'dispute_open',
          'label': 'Dispute open',
          'count': 1,
          'selected': false
        },
        {
          'key': 'count_variance',
          'label': 'Count mismatch',
          'count': 1,
          'selected': false
        },
      ],
      'outcomes': const [
        {
          'code': 'supplier_replaced',
          'label': 'Supplier replaced the stock',
          'affects': 'supplier',
          'is_success': true
        },
        {
          'code': 'supplier_credited',
          'label': 'Supplier credited the amount',
          'affects': 'supplier',
          'is_success': true
        },
        {
          'code': 'no_fault',
          'label': 'No fault — nothing was wrong',
          'affects': 'none',
          'is_success': true
        },
      ],
      'close': const {
        'title': 'How did this end?',
        'hint':
            'Pick the outcome. It is recorded against the supplier or the partner.',
        'note_hint': 'Note (optional)',
        'submit': 'Record outcome',
        'cancel': 'Cancel',
        'pick': 'Pick an outcome first.',
      },
      'rows': rows ?? _rows,
    };

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

/// The queue is a lazy ListView: on the default 800x600 test surface the
/// fourth card is never built, and "the order the payload arrived in" cannot be
/// asserted about rows that were never laid out. Every test pumps tall.
Future<void> _pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_host(child));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() {
    // The 800 ms RenderLog debounce is a real Timer that would outlive the test.
    RenderLog.flushEnabled = false;
  });

  testWidgets('1 — rows render in PAYLOAD order, not by age and not by severity',
      (tester) async {
    await _pump(tester, ExceptionsScreen(
      queueRpc: ({String? reason, String status = 'open'}) async => _payload(),
    ));

    final cards = tester
        .widgetList<Container>(find.byWidgetPredicate((w) =>
            w is Container && w.key is ValueKey<String> &&
            (w.key as ValueKey<String>).value.startsWith('exc_row_')))
        .map((w) => (w.key as ValueKey<String>).value)
        .toList();

    expect(cards, [
      'exc_row_sla_breach:orders_open/abc',
      'exc_row_dispute_open:aaaaaaaa-0690-4690-8690-aaaaaaaaaaaa',
      'exc_row_wa_send_failed:8799',
      'exc_row_count_variance:b8d20334',
    ]);
  });

  testWidgets('2 — reason, age, SLA, owner and status all print verbatim',
      (tester) async {
    await _pump(tester, ExceptionsScreen(
      queueRpc: ({String? reason, String status = 'open'}) async => _payload(),
    ));

    expect(find.text('Dispute open'), findsOneWidget);
    expect(find.text('30 hours old'), findsOneWidget);
    expect(find.text('6h past deadline'), findsOneWidget);
    expect(find.text('Owner: mediBO admin'), findsOneWidget);
    expect(find.text('4 open'), findsOneWidget);
    // The headline count is the backend's sentence, never "4 exceptions".
    expect(find.text('4 exceptions'), findsNothing);
  });

  testWidgets("3a — kind:'rpc' sends the id and prints the reply's own message",
      (tester) async {
    String? sentId;
    await _pump(tester, ExceptionsScreen(
      queueRpc: ({String? reason, String status = 'open'}) async => _payload(),
      actionRpc: (id) async {
        sentId = id;
        return {'ok': true, 'message': 'Sent again to 9812345678.'};
      },
    ));

    await tester.tap(find.byKey(const Key('exc_action_wa_send_failed:8799')));
    await tester.pumpAndSettle();

    expect(sentId, 'wa_send_failed:8799');
    expect(find.text('Sent again to 9812345678.'), findsOneWidget);
  });

  testWidgets('3b — a REFUSAL from the action reads as the refusal it is',
      (tester) async {
    await _pump(tester, ExceptionsScreen(
      queueRpc: ({String? reason, String status = 'open'}) async => _payload(),
      actionRpc: (id) async => {
        'ok': false,
        'error': 'action_refused',
        'message': 'This send had no number, so there is nothing to send again.',
      },
    ));

    await tester.tap(find.byKey(const Key('exc_action_wa_send_failed:8799')));
    await tester.pumpAndSettle();

    expect(
        find.text(
            'This send had no number, so there is nothing to send again.'),
        findsOneWidget);
  });

  testWidgets("3c — kind:'route' calls no RPC and navigates the backend's key",
      (tester) async {
    var actionCalls = 0;
    final routes = <String>[];
    await _pump(tester, ExceptionsScreen(
      queueRpc: ({String? reason, String status = 'open'}) async => _payload(),
      actionRpc: (id) async {
        actionCalls++;
        return {'ok': true};
      },
      onNavigate: routes.add,
    ));

    await tester.tap(find.byKey(const Key('exc_action_count_variance:b8d20334')));
    await tester.pumpAndSettle();

    expect(actionCalls, 0);
    expect(routes, ['warehouse']);
  });

  testWidgets('4 — closing offers the payload outcomes and carries id + code',
      (tester) async {
    String? closedId, closedCode, closedNote;
    await _pump(tester, ExceptionsScreen(
      queueRpc: ({String? reason, String status = 'open'}) async => _payload(),
      closeRpc: (id, code, note) async {
        closedId = id;
        closedCode = code;
        closedNote = note;
        return {
          'ok': true,
          'message': 'Outcome recorded.',
          'outcome_code': code,
        };
      },
    ));

    await tester.tap(find.byKey(
        const Key('exc_close_dispute_open:aaaaaaaa-0690-4690-8690-aaaaaaaaaaaa')));
    await tester.pumpAndSettle();

    // Exactly the outcomes the payload sent, in payload order.
    expect(find.text('Supplier replaced the stock'), findsOneWidget);
    expect(find.text('Supplier credited the amount'), findsOneWidget);
    expect(find.text('No fault — nothing was wrong'), findsOneWidget);

    // Submit is dead until an outcome is picked.
    final submit = tester
        .widget<FilledButton>(find.byKey(const Key('exc_close_submit')));
    expect(submit.onPressed, isNull);

    await tester
        .tap(find.byKey(const Key('exc_outcome_opt_supplier_credited')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('exc_close_submit')));
    await tester.pumpAndSettle();

    expect(closedId, 'dispute_open:aaaaaaaa-0690-4690-8690-aaaaaaaaaaaa');
    expect(closedCode, 'supplier_credited');
    expect(closedNote, isNull);
    expect(find.text('Outcome recorded.'), findsOneWidget);
  });

  testWidgets('5 — can_close:false has no Close button at all', (tester) async {
    await _pump(tester, ExceptionsScreen(
      queueRpc: ({String? reason, String status = 'open'}) async => _payload(),
    ));

    expect(find.byKey(const Key('exc_close_count_variance:b8d20334')),
        findsNothing);
    expect(
        find.byKey(const Key(
            'exc_close_dispute_open:aaaaaaaa-0690-4690-8690-aaaaaaaaaaaa')),
        findsOneWidget);
  });

  testWidgets('6a — a refusal renders the backend message, never a throw',
      (tester) async {
    await _pump(tester, ExceptionsScreen(
      queueRpc: ({String? reason, String status = 'open'}) async => {
        'ok': false,
        'error': 'not_authorized',
        'message': 'You do not have access to the exceptions queue.',
        'retry_label': 'Retry',
      },
    ));

    expect(find.byKey(const Key('exc_error')), findsOneWidget);
    expect(find.text('You do not have access to the exceptions queue.'),
        findsOneWidget);
  });

  testWidgets("6b — an empty queue is the backend's empty_label", (tester) async {
    await _pump(tester, ExceptionsScreen(
      queueRpc: ({String? reason, String status = 'open'}) async =>
          _payload(rows: const []),
    ));

    expect(find.byKey(const Key('exc_empty')), findsOneWidget);
    expect(find.text('Nothing is stuck. Every queue is inside its deadline.'),
        findsOneWidget);
  });

  testWidgets('7 — an unknown reason_code still renders, label and all',
      (tester) async {
    await _pump(tester, ExceptionsScreen(
      queueRpc: ({String? reason, String status = 'open'}) async => _payload(
        rows: [
          _row(
            id: 'return_pickup_missed:99',
            reasonCode: 'return_pickup_missed',
            reasonLabel: 'Return pickup missed',
            title: 'RTN-4410',
            ageLabel: '2 days old',
            action: const {
              'has': false,
              'kind': 'none',
              'label': '',
              'rpc': '',
              'args': <String, dynamic>{},
              'route': ''
            },
          ),
        ],
      ),
    ));

    expect(find.byKey(const Key('exc_row_return_pickup_missed:99')),
        findsOneWidget);
    expect(find.text('Return pickup missed'), findsOneWidget);
    expect(find.text('RTN-4410'), findsOneWidget);
  });

  testWidgets('8 — picking a reason chip refetches with that reason',
      (tester) async {
    final asked = <String?>[];
    await _pump(tester, ExceptionsScreen(
      queueRpc: ({String? reason, String status = 'open'}) async {
        asked.add(reason);
        return _payload();
      },
    ));

    await tester.tap(find.byKey(const Key('exc_filter_dispute_open')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('exc_filter_all')));
    await tester.pumpAndSettle();

    expect(asked, [null, 'dispute_open', null]);
  });

  // ── CHANGE #470 ───────────────────────────────────────────────────────────
  //
  // The register row asked for one queue over EVERY flow, and two of its
  // fields are new: the STAGE the thing is stuck at, and a one-tap link to the
  // exact screen that fixes it. Both are backend strings. What is held down:
  //
  //   9.  The stage chip prints VERBATIM. 'Stage: Count' is the backend's
  //       sentence built from sla_stage.label — the screen never title-cases a
  //       stage_key and never derives a stage from the reason.
  //   10. A reason with no stage still says so in the backend's words, and a
  //       row that sent no chip at all draws nothing rather than a placeholder.
  //   11. The link is offered ONLY where the action cannot already reach the
  //       screen. kind:'route' IS the link (the backend resolves both from one
  //       field), so a second button there would be the same tap twice.
  //   12. Tapping the link navigates the backend's route and calls no RPC.

  testWidgets('9 — the stage chip prints verbatim, never derived',
      (tester) async {
    await _pump(tester, ExceptionsScreen(
      queueRpc: ({String? reason, String status = 'open'}) async => _payload(),
    ));

    expect(find.text('Stage: Count'), findsOneWidget);
    expect(find.text('No stage'), findsOneWidget);
    // The reason label is 'Count mismatch'; nothing on the screen turned the
    // stage_key 'count' into a chip by itself.
    expect(find.text('Count'), findsNothing);
  });

  testWidgets('10 — a row that sent no stage chip draws no chip at all',
      (tester) async {
    await _pump(tester, ExceptionsScreen(
      queueRpc: ({String? reason, String status = 'open'}) async => _payload(),
    ));

    expect(
        find.byKey(const Key(
            'exc_stage_dispute_open:aaaaaaaa-0690-4690-8690-aaaaaaaaaaaa')),
        findsNothing);
    expect(find.byKey(const Key('exc_stage_count_variance:b8d20334')),
        findsOneWidget);
  });

  testWidgets('11 — the link appears only where the action is not already a route',
      (tester) async {
    await _pump(tester, ExceptionsScreen(
      queueRpc: ({String? reason, String status = 'open'}) async => _payload(),
    ));

    // kind:'rpc' — retrying the send never reached wa_ops before.
    expect(find.byKey(const Key('exc_link_wa_send_failed:8799')), findsOneWidget);
    // kind:'route' — the action button already goes to the warehouse.
    expect(find.byKey(const Key('exc_link_count_variance:b8d20334')), findsNothing);
  });

  testWidgets('12 — tapping the link navigates the backend route, calls no RPC',
      (tester) async {
    final routes = <String>[];
    var rpcCalls = 0;
    await _pump(tester, ExceptionsScreen(
      queueRpc: ({String? reason, String status = 'open'}) async => _payload(),
      actionRpc: (id) async {
        rpcCalls += 1;
        return {'ok': true, 'message': ''};
      },
      onNavigate: routes.add,
    ));

    await tester.tap(find.byKey(const Key('exc_link_wa_send_failed:8799')));
    await tester.pumpAndSettle();

    expect(routes, ['wa_ops']);
    expect(rpcCalls, 0);
  });
}
