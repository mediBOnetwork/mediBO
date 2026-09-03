// PROTECTED — CHANGE #696.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes the mediBO <-> partner escalation channel.
//
// What this holds down:
//
//   1. THE ORDER IS THE BACKEND'S. The queue renders rows in payload order —
//      the fixture is deliberately NOT sorted by ref, subject or age, because
//      "breach first" is a decision partner_ticket_list() makes and re-sorting
//      it in Dart would quietly undo the one thing the office asked for.
//
//   2. NOTHING IS COMPOSED IN DART. The status word differs by WHO is reading
//      ("Waiting on you" for the side that owes the answer, "Waiting on them"
//      for the other) and both arrive finished. So do the SLA sentence, its
//      tone, the category, the priority and the counts on the filter chips.
//
//   3. THE RAISE SHEET OFFERS ONLY WHAT THE BACKEND SENT. A partner is never
//      handed a mediBO-only category, and the partner picker exists only when
//      the payload says needs_partner — a partner is never asked which partner
//      they are.
//
//   4. CLOSURE REQUIRES AN OUTCOME, AND THE LIST IS THE PAYLOAD'S. The sheet
//      offers the outcomes the backend sent, sends the picked CODE, and prints
//      the backend's refusal verbatim when it refuses.
//
//   5. ABSENCE IS EXPLICIT. link.has:false renders no link button at all
//      rather than an empty row; a link kind this build has never heard of
//      opens nothing instead of throwing.
//
//   6. A SYSTEM LINE IS NOT A MESSAGE. is_system renders the centred, tinted
//      line and is never attributed to "You", however the actor_label reads.
//
// No network, no Supabase, no goldens. Payloads are inline.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/partner/partner_issues_screen.dart';
import 'package:pharma_b2b/services/partner_ticket_api.dart';
import 'package:pharma_b2b/utils/render_log.dart';

// ── fixtures ────────────────────────────────────────────────────────────────

Map<String, dynamic> _row({
  required String id,
  required String ref,
  required String subject,
  String status = 'Waiting on you',
  String statusTone = 'warning',
  String sla = 'Reply due 04 Sep 2026, 05:00 PM',
  String slaTone = 'info',
  String category = 'Payment',
  String priority = 'Normal',
  String partner = '',
}) =>
    {
      'id': id,
      'ref': ref,
      'subject': subject,
      'category_label': category,
      'priority_label': priority,
      'priority_tone': 'info',
      'status_label': status,
      'status_tone': statusTone,
      'owner_label': 'With mediBO office',
      'partner_label': partner,
      'sla_label': sla,
      'sla_tone': slaTone,
      'breached': slaTone == 'danger',
      'age_label': '2h ago',
      'is_closed': false,
      'mine': true,
    };

// Deliberately NOT alphabetical, NOT newest-first: this is the breach-first
// order the backend chose, and the screen must print it as it arrived.
final Map<String, dynamic> _list = {
  'ok': true,
  'view': 'office',
  'title': 'Partner issues',
  'subtitle': 'Every issue open with a zone partner, the closest to breaching first.',
  'raise_cta': 'Raise issue',
  'can_raise': true,
  'filter': 'open',
  'filters': [
    {'key': 'open', 'label': 'Open', 'count': 3},
    {'key': 'breached', 'label': 'Overdue', 'count': 1},
    {'key': 'closed', 'label': 'Closed', 'count': 7},
  ],
  'rows': [
    _row(
        id: 'aaa',
        ref: 'PT-00042',
        subject: 'Settlement 12 Aug short by two lines',
        status: 'Waiting on you',
        statusTone: 'warning',
        sla: 'Overdue by 3h ago',
        slaTone: 'danger',
        partner: 'Jai Mahakal Medical And Surgical'),
    _row(
        id: 'bbb',
        ref: 'PT-00007',
        subject: 'Supplier not answering on the inquiry',
        status: 'Waiting on them',
        statusTone: 'info',
        category: 'Supplier'),
    _row(
        id: 'ccc',
        ref: 'PT-00099',
        subject: 'App shows the wrong pack count',
        category: 'App problem',
        priority: 'Low'),
  ],
  'count_label': '3 open issues',
  'empty_title': 'Nothing open',
  'empty_note': 'No partner is waiting on the office right now.',
  'retry_label': 'Try again',
};

final Map<String, dynamic> _newPartnerSide = {
  'ok': true,
  'side': 'partner',
  'title': 'Raise an issue',
  'category_label': 'What is it about?',
  'priority_label': 'How urgent?',
  'partner_label': 'Which partner?',
  'subject_label': 'Subject',
  'subject_hint': 'One line — what is wrong',
  'body_hint': 'What happened, and what you need',
  'link_hint': 'Order code, supplier or statement this is about (optional)',
  'submit_cta': 'Raise it',
  'needs_partner': false,
  'categories': [
    {
      'code': 'payment',
      'label': 'Payment',
      'hint': 'A settlement, payout or claim that has not moved.',
      'link_kind': 'settlement',
      'priority': 'normal',
      'sla_label': 'Answer promised within 24h',
    },
    {
      'code': 'app_bug',
      'label': 'App problem',
      'hint': 'Something in the app is broken or wrong.',
      'link_kind': 'none',
      'priority': 'low',
      'sla_label': 'Answer promised within 48h',
    },
  ],
  'priorities': [
    {'code': 'urgent', 'label': 'Urgent', 'tone': 'danger'},
    {'code': 'normal', 'label': 'Normal', 'tone': 'info'},
  ],
  'partners': [],
  'upload': {'bucket': 'partner-issue-files', 'folder': 'p1/draft', 'cta': 'Attach'},
};

Map<String, dynamic> _detail({
  bool linked = true,
  String linkKind = 'order',
  bool canClose = true,
}) =>
    {
      'ok': true,
      'side': 'medibo',
      'row': _row(
          id: 'aaa', ref: 'PT-00042', subject: 'Settlement 12 Aug short by two lines'),
      'id': 'aaa',
      'ref': 'PT-00042',
      'subject': 'Settlement 12 Aug short by two lines',
      'raised_line': 'Raised by Partner · 03 Sep 2026, 09:12 AM',
      'timeline_title': 'Timeline',
      'messages': [
        {
          'id': 'm1',
          'body': 'Two lines are missing from the 12 Aug statement.',
          'side': 'partner',
          'kind': 'message',
          'actor_label': 'Jai Mahakal Medical And Surgical',
          'when_label': '03 Sep 2026, 09:12 AM',
          'mine': false,
          'is_system': false,
          'attachments': [
            {
              'bucket': 'partner-issue-files',
              'path': 'p1/aaa/1725000000-statement.pdf',
              'name': 'statement.pdf',
              'open_label': 'Open',
            }
          ],
          'attach_cta': 'Open',
        },
        {
          'id': 'm2',
          // The actor label says "You" only because a payload can; a system
          // line must never be attributed to the reader whatever it says.
          'body': 'Half the promised time has gone — nudged on WhatsApp.',
          'side': 'system',
          'kind': 'system',
          'actor_label': 'mediBO',
          'when_label': '03 Sep 2026, 03:12 PM',
          'mine': false,
          'is_system': true,
          'attachments': const [],
          'attach_cta': 'Open',
        },
      ],
      'link': linked
          ? {
              'has': true,
              'kind': linkKind,
              'ref': 'CPO260726NIT123O1',
              'label': 'Order CPO260726NIT123O1',
              'cta': 'Open',
            }
          : {'has': false},
      'can_reply': true,
      'upload': {
        'bucket': 'partner-issue-files',
        'folder': 'p1/aaa',
        'cta': 'Attach',
      },
      'compose_hint': 'Write a reply',
      'send_cta': 'Send',
      'attach_cta': 'Attach',
      'can_close': canClose,
      'close': {
        'cta': 'Close issue',
        'title': 'How did this end?',
        'hint': 'Pick an outcome — it is what the partner scorecard counts.',
        'note_hint': 'Anything worth writing down (optional)',
        'submit': 'Close it',
        'outcomes': [
          {'code': 'fixed', 'label': 'Fixed'},
          {'code': 'no_fault', 'label': 'Nobody at fault'},
        ],
      },
      'closed_line': '',
    };

Widget _host(Widget child) => MaterialApp(home: child);

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  setUp(() {
    PartnerTicketApi.rpcFn = null;
  });

  tearDown(() {
    PartnerTicketApi.rpcFn = null;
  });

  testWidgets('1 · the queue renders the backend rows in PAYLOAD order',
      (tester) async {
    PartnerTicketApi.rpcFn = (fn, params) async {
      expect(fn, 'partner_ticket_list');
      return _list;
    };
    await tester.pumpWidget(_host(const PartnerIssuesScreen()));
    await tester.pumpAndSettle();

    final subjects = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .where((s) => s.startsWith('Settlement 12 Aug') ||
            s.startsWith('Supplier not answering') ||
            s.startsWith('App shows the wrong'))
        .toList();
    expect(subjects, [
      'Settlement 12 Aug short by two lines',
      'Supplier not answering on the inquiry',
      'App shows the wrong pack count',
    ]);
  });

  testWidgets('2 · every word is the payload\'s — including both status voices',
      (tester) async {
    PartnerTicketApi.rpcFn = (fn, params) async => _list;
    await tester.pumpWidget(_host(const PartnerIssuesScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Partner issues'), findsOneWidget);
    expect(find.text('Waiting on you'), findsOneWidget);
    expect(find.text('Waiting on them'), findsOneWidget);
    expect(find.text('Overdue by 3h ago'), findsOneWidget);
    expect(find.text('Raise issue'), findsOneWidget);
    // the filter chip prints the backend's own count, never a rows.length
    expect(find.text('Closed · 7'), findsOneWidget);
  });

  testWidgets('3 · an empty queue prints the backend\'s empty state, and a '
      'refusal prints its message', (tester) async {
    PartnerTicketApi.rpcFn = (fn, params) async => {
          ..._list,
          'rows': const [],
        };
    await tester.pumpWidget(_host(const PartnerIssuesScreen()));
    await tester.pumpAndSettle();
    expect(find.text('No partner is waiting on the office right now.'),
        findsOneWidget);

    PartnerTicketApi.rpcFn = (fn, params) async =>
        {'ok': false, 'message': 'Only a mediBO partner or the office can use this.'};
    await tester.pumpWidget(_host(const PartnerIssuesScreen()));
    await tester.pumpAndSettle();
    expect(find.text('Only a mediBO partner or the office can use this.'),
        findsOneWidget);
  });

  testWidgets('4 · the raise sheet offers only the categories the backend sent, '
      'and never asks a partner which partner they are', (tester) async {
    PartnerTicketApi.rpcFn = (fn, params) async => _newPartnerSide;
    await tester.pumpWidget(_host(const PartnerIssueRaiseSheet()));
    await tester.pumpAndSettle();

    expect(find.text('Payment'), findsOneWidget);
    expect(find.text('App problem'), findsOneWidget);
    // a mediBO-only category is not in the payload, so it cannot be on screen
    expect(find.text('Count dispute'), findsNothing);
    // needs_partner:false -> no picker at all
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
    // the category's own hint and promise, verbatim
    expect(find.text('A settlement, payout or claim that has not moved.'),
        findsOneWidget);
    expect(find.text('Answer promised within 24h'), findsOneWidget);
  });

  testWidgets('5 · raising sends the backend codes and prints its refusal',
      (tester) async {
    Map<String, dynamic>? sent;
    PartnerTicketApi.rpcFn = (fn, params) async {
      if (fn == 'partner_ticket_new') return _newPartnerSide;
      sent = params;
      return {'ok': false, 'message': 'Give it a one-line subject.'};
    };
    await tester.pumpWidget(_host(const PartnerIssueRaiseSheet()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('App problem'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Raise it'));
    await tester.pumpAndSettle();

    expect(sent?['p_category'], 'app_bug');
    // the priority followed the category's own default, not a Dart guess
    expect(sent?['p_priority'], 'low');
    expect(find.text('Give it a one-line subject.'), findsOneWidget);
  });

  testWidgets('6 · a system line is centred and never attributed to the reader',
      (tester) async {
    PartnerTicketApi.rpcFn = (fn, params) async => _detail();
    await tester.pumpWidget(_host(const PartnerIssueScreen(ticketId: 'aaa')));
    await tester.pumpAndSettle();

    expect(find.text('Half the promised time has gone — nudged on WhatsApp.'),
        findsOneWidget);
    // the system line carries no "actor · when" header line
    expect(find.text('mediBO · 03 Sep 2026, 03:12 PM'), findsNothing);
    // the real message does
    expect(
        find.text(
            'Jai Mahakal Medical And Surgical · 03 Sep 2026, 09:12 AM'),
        findsOneWidget);
    // the attachment prints its own name and never builds a URL
    expect(find.text('statement.pdf'), findsOneWidget);
  });

  testWidgets('7 · the linked object is a payload flag, not an inference',
      (tester) async {
    PartnerTicketApi.rpcFn = (fn, params) async => _detail(linked: false);
    await tester.pumpWidget(_host(const PartnerIssueScreen(ticketId: 'aaa')));
    await tester.pumpAndSettle();
    expect(find.text('Order CPO260726NIT123O1 · Open'), findsNothing);

    PartnerTicketApi.rpcFn = (fn, params) async => _detail();
    await tester.pumpWidget(_host(const PartnerIssueScreen(ticketId: 'aaa')));
    await tester.pumpAndSettle();
    expect(find.text('Order CPO260726NIT123O1 · Open'), findsOneWidget);
  });

  testWidgets('8 · a link kind this build never heard of opens nothing',
      (tester) async {
    var pushed = 0;
    await tester.pumpWidget(MaterialApp(
      navigatorObservers: [_CountingObserver(() => pushed++)],
      home: Builder(
        builder: (ctx) => TextButton(
          onPressed: () => openIssueLink(
              ctx, const {'has': true, 'kind': 'a_kind_from_the_future', 'ref': 'x'}),
          child: const Text('go'),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(pushed, 0);
  });

  testWidgets('9 · closing sends the picked OUTCOME CODE and prints refusals',
      (tester) async {
    Map<String, dynamic>? sent;
    PartnerTicketApi.rpcFn = (fn, params) async {
      sent = params;
      return {'ok': false, 'message': 'Pick an outcome before closing.'};
    };
    await tester.pumpWidget(_host(PartnerIssueCloseSheet(
        d: ticketMap(_detail(), 'close'), ticketId: 'aaa')));
    await tester.pumpAndSettle();

    expect(find.text('Pick an outcome — it is what the partner scorecard counts.'),
        findsOneWidget);
    await tester.tap(find.text('Nobody at fault'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close it'));
    await tester.pumpAndSettle();

    expect(sent?['p_outcome_code'], 'no_fault');
    expect(find.text('Pick an outcome before closing.'), findsOneWidget);
  });

  testWidgets('10 · a closed issue offers no composer and no close action',
      (tester) async {
    PartnerTicketApi.rpcFn = (fn, params) async => {
          ..._detail(canClose: false),
          'can_reply': false,
          'closed_line': 'Closed 03 Sep 2026, 06:00 PM · Fixed',
        };
    await tester.pumpWidget(_host(const PartnerIssueScreen(ticketId: 'aaa')));
    await tester.pumpAndSettle();

    expect(find.text('Send'), findsNothing);
    expect(find.text('Close issue'), findsNothing);
    expect(find.text('Closed 03 Sep 2026, 06:00 PM · Fixed'), findsOneWidget);
  });
}

class _CountingObserver extends NavigatorObserver {
  _CountingObserver(this.onPush);

  final VoidCallback onPush;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute != null) onPush();
    super.didPush(route, previousRoute);
  }
}
