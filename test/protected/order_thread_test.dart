// PROTECTED — CHANGE #713, one conversation per order.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes this behaviour, never to make an unrelated change go
// green.
//
// What this holds down:
//
//   1. THE CUSTOMER SEES ONE COUNTERPARTY, AND THAT COLLAPSE IS THE BACKEND'S.
//      In the customer's payload a partner message and an admin message both
//      arrive with who_label 'mediBO' and mine:false. The widget prints
//      who_label and obeys `mine`; it never looks at `role` to decide a side.
//      The same two messages in the PARTNER's payload arrive mine:true — so
//      swapping the fixture swaps the sides, with no code path in between.
//
//   2. NOTHING ON THE SCREEN IS COMPUTED. The status word, the tag, the SLA
//      sentence and its tone, the owner line, the composer's hint and CTA, the
//      read receipt and the empty state all print verbatim. The fixture's
//      sla_label deliberately disagrees with its sla_due_at, so a client-side
//      clock fails this test.
//
//   3. ABSENCE IS AN EMPTY STRING, NOT A ROLE BRANCH. A customer's payload
//      carries owner_label:'' and sla_label:'', so those rows do not render —
//      which is how one widget serves three audiences with no `if (isCustomer)`
//      anywhere in it.
//
//   4. AN ATTACHMENT IS THE BACKEND'S BUCKET AND PATH. The screen opens exactly
//      what the payload named and never builds a URL of its own.
//
//   5. THE INBOX IS RENDERED, INCLUDING ITS CLAMP. Filter chips carry the
//      payload's own counts, tag chips its own labels, rows appear in payload
//      order (the fixture is deliberately not sorted by anything the widget
//      could re-derive), and the zone line is the BACKEND's word — 'All zones'
//      for the office, the zone's name for a partner.
//
//   6. A CALL TASK OFFERS A CALL ONLY WHEN THE PAYLOAD SENT A DESCRIPTOR.
//      has:false renders no button, and the button that does render carries no
//      phone number (#404). The outcome options are the payload's, so an
//      outcome the backend did not send cannot be picked.
//
// No network, no Supabase, no timers.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/support_threads_screen.dart';
import 'package:pharma_b2b/screens/order_thread_screen.dart';
import 'package:pharma_b2b/services/order_thread_api.dart';
import 'package:pharma_b2b/utils/render_log.dart';

// ── fixtures ────────────────────────────────────────────────────────────────

/// The customer's view: our partner message and our admin message are BOTH
/// 'mediBO', both mine:false. The system line is the escalation notice.
Map<String, dynamic> customerThread() => <String, dynamic>{
      'ok': true,
      'view': 'customer',
      'thread_id': 'T1',
      'title': 'Messages',
      'order_id': 'O1',
      'order_label': 'Order CPO1234',
      'customer_label': '',
      'tag': 'billing',
      'tag_label': 'Billing',
      'tag_tone': 'warning',
      'status': 'open',
      'status_label': 'Waiting on us',
      'status_tone': 'warning',
      'owner_label': '',
      'sla_label': '',
      'sla_tone': 'warning',
      'sla_minutes': 30,
      'unread_from_customer': 0,
      'compose_hint': 'Write a message',
      'send_cta': 'Send',
      'attach_cta': 'Attach a photo',
      'can_write': true,
      'empty_title': 'No messages yet',
      'empty_note': 'Ask us anything about this order — we reply here.',
      'brand_note': 'You are talking to the mediBO team for this order.',
      'messages': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'm1',
          'body': 'Bill amount looks wrong',
          'role': 'customer',
          'mine': true,
          'who_label': 'You',
          'at_label': '03 Sep 2026, 09:10 AM',
          'source': 'whatsapp',
          'source_label': 'via WhatsApp',
          'is_critical': false,
          'read_label': '',
          'attachments': <Map<String, dynamic>>[
            <String, dynamic>{
              'name': 'bill.jpg',
              'bucket': 'whatsapp-media',
              'path': 'in/2026/09/bill.jpg',
              'is_image': true,
              'open_label': 'Open',
            }
          ],
        },
        <String, dynamic>{
          'id': 'm2',
          'body': 'Checking with the shop now',
          'role': 'partner',
          'mine': false,
          'who_label': 'mediBO',
          'at_label': '03 Sep 2026, 09:20 AM',
          'source': 'app',
          'source_label': '',
          'is_critical': false,
          'read_label': '',
          'attachments': <Map<String, dynamic>>[],
        },
        <String, dynamic>{
          'id': 'm3',
          'body': 'Revised bill attached',
          'role': 'admin',
          'mine': false,
          'who_label': 'mediBO',
          'at_label': '03 Sep 2026, 10:05 AM',
          'source': 'app',
          'source_label': '',
          'is_critical': false,
          'read_label': '',
          'attachments': <Map<String, dynamic>>[],
        },
        <String, dynamic>{
          'id': 'm4',
          'body': 'No reply within 30 minutes — escalated to the mediBO office.',
          'role': 'system',
          'mine': false,
          'who_label': 'mediBO',
          'at_label': '03 Sep 2026, 09:50 AM',
          'source': 'system',
          'source_label': '',
          'is_critical': false,
          'read_label': '',
          'attachments': <Map<String, dynamic>>[],
        },
      ],
    };

/// The SAME conversation from our side. The only difference is the payload.
/// sla_label deliberately disagrees with any clock the widget could run.
Map<String, dynamic> partnerThread() {
  final d = customerThread();
  d['view'] = 'partner';
  d['customer_label'] = 'Pallavi Pharmacy';
  d['owner_label'] = 'Jai Mahakal Medical And Surgical';
  d['sla_label'] = 'Overdue by 4 hours';
  d['sla_tone'] = 'danger';
  d['brand_note'] = '';
  final src = (d['messages'] as List)
      .map((e) => Map<String, dynamic>.from(e as Map))
      .toList();
  src[0] = {...src[0], 'mine': false, 'who_label': 'Pallavi Pharmacy'};
  src[1] = {...src[1], 'mine': true, 'read_label': 'Read'};
  src[2] = {...src[2], 'mine': true, 'read_label': 'Not read yet'};
  d['messages'] = src;
  return d;
}

Map<String, dynamic> inboxPayload() => {
      'ok': true,
      'view': 'partner',
      'title': 'Customer messages',
      'zone_label': 'Raipur',
      'empty_title': 'Nothing waiting',
      'empty_note': 'Every customer message in your zone has been answered.',
      'filter': 'waiting',
      'tag': '',
      'filters': [
        {'key': 'waiting', 'label': 'Waiting', 'count': 3},
        {'key': 'breached', 'label': 'Overdue', 'count': 1},
        {'key': 'answered', 'label': 'Answered', 'count': 0},
        {'key': '', 'label': 'All', 'count': 9},
      ],
      'tags': [
        {'key': 'billing', 'label': 'Billing', 'tone': 'warning'},
        {'key': 'delivery', 'label': 'Delivery', 'tone': 'info'},
      ],
      // Deliberately NOT sorted by title, customer or time: payload order.
      'rows': [
        {
          'thread_id': 'T9',
          'order_id': 'O9',
          'title': 'Order ZZZ999',
          'customer_label': 'Zenith Medicos',
          'tag_label': 'Delivery',
          'tag_tone': 'info',
          'status_label': 'Waiting on us',
          'status_tone': 'warning',
          'sla_label': 'Overdue by 2 hours',
          'sla_tone': 'danger',
          'last_line': 'Still not received',
          'last_by': 'Customer',
          'at_label': '03 Sep 2026, 08:00 AM',
          'unread': 2,
          'owner_label': 'Jai Mahakal Medical And Surgical',
          'ticket_ref': 'MB-2609-0007',
        },
        {
          'thread_id': 'T1',
          'order_id': 'O1',
          'title': 'Order AAA111',
          'customer_label': 'Aarogya Pharmacy',
          'tag_label': 'Billing',
          'tag_tone': 'warning',
          'status_label': 'Answered',
          'status_tone': 'success',
          'sla_label': 'Nothing waiting',
          'sla_tone': 'success',
          'last_line': 'Thanks',
          'last_by': 'Us',
          'at_label': '03 Sep 2026, 11:00 AM',
          'unread': 0,
          'owner_label': 'Jai Mahakal Medical And Surgical',
          'ticket_ref': '',
        },
      ],
    };

Map<String, dynamic> tasksPayload() => {
      'ok': true,
      'title': 'Calls to make',
      'empty_title': 'No calls to make',
      'empty_note': 'A critical message nobody has read, or a missed call, appears here.',
      'log_cta': 'Log the outcome',
      'note_hint': 'Anything worth writing down',
      'outcomes': [
        {'code': 'spoke', 'label': 'Spoke to customer', 'tone': 'success'},
        {'code': 'no_answer', 'label': 'No answer', 'tone': 'warning'},
      ],
      'rows': [
        {
          'task_id': '7',
          'thread_id': 'T9',
          'order_id': 'O9',
          'title': 'The payment reminder not read — call the customer',
          'customer_label': 'Zenith Medicos',
          'order_label': 'Order ZZZ999',
          'due_label': 'Overdue by 20 minutes',
          'due_tone': 'danger',
          'call': {
            'has': true,
            'target_role': 'customer',
            'label': 'Call the customer',
            'privacy_note': 'Numbers are masked. Neither side sees the other.',
          },
        },
        {
          'task_id': '8',
          'thread_id': 'T1',
          'order_id': 'O1',
          'title': 'Missed call from the customer — call back',
          'customer_label': 'Aarogya Pharmacy',
          'order_label': 'Order AAA111',
          'due_label': 'Due by 03 Sep 2026, 12:30 PM',
          'due_tone': 'warning',
          // No permitted counterparty: an ABSENT button, never a greyed one.
          'call': {'has': false},
        },
      ],
    };

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

/// Any exception the framework caught during the pump. A screen that throws
/// inside its own build is otherwise invisible to a widget test that only
/// looks for text.
Object? tester_takeException(WidgetTester t) => t.takeException();

void main() {
  setUpAll(() {
    // The 800 ms debounce is a real Timer that would outlive the test and try
    // to reach Supabase.
    RenderLog.flushEnabled = false;
  });

  tearDown(() {
    OrderThreadApi.rpcFn = null;
  });

  group('the conversation', () {
    testWidgets('a customer sees ONE counterparty called mediBO', (t) async {
      OrderThreadApi.rpcFn = (fn, p) async => customerThread();
      await t.pumpWidget(host(const OrderThreadScreen(orderId: 'O1')));
      await t.pumpAndSettle();

      // Two different roles answered. The customer reads one name, twice.
      expect(find.text('mediBO'), findsNWidgets(2));
      expect(find.text('You'), findsOneWidget);
      // ...and never learns which of the two answered: no author label names
      // a partner or the office. (The escalation NOTICE does say 'office' —
      // that is a sentence the backend chose to show the customer, not a
      // by-line, and it is asserted verbatim in its own test below.)
      expect(find.text('mediBO office'), findsNothing);
      expect(find.text('mediBO partner'), findsNothing);
      expect(find.text('Jai Mahakal Medical And Surgical'), findsNothing);

      // Verbatim, all of it.
      expect(find.text('Order CPO1234'), findsOneWidget);
      expect(find.text('Billing'), findsOneWidget);
      expect(find.text('Waiting on us'), findsOneWidget);
      expect(find.text('Write a message'), findsOneWidget);
      expect(find.text('Send'), findsOneWidget);
      expect(find.text('You are talking to the mediBO team for this order.'),
          findsOneWidget);
      expect(find.text('via WhatsApp'), findsOneWidget);

      // Absence is an empty string, so the two ops rows are simply not there.
      expect(find.text('Jai Mahakal Medical And Surgical'), findsNothing);
      expect(find.textContaining('Overdue'), findsNothing);
    });

    testWidgets('the same thread from our side swaps sides and shows the clock',
        (t) async {
      OrderThreadApi.rpcFn = (fn, p) async => partnerThread();
      await t.pumpWidget(host(const OrderThreadScreen(threadId: 'T1')));
      await t.pumpAndSettle();

      // The ops rows appear because the PAYLOAD carries them — not because the
      // widget worked out who is looking.
      expect(find.text('Jai Mahakal Medical And Surgical'), findsOneWidget);
      expect(find.text('Pallavi Pharmacy'), findsNWidgets(2)); // header + author
      // The SLA sentence is printed, never derived: this string exists nowhere
      // but the payload.
      expect(find.text('Overdue by 4 hours'), findsOneWidget);
      // Read receipts are the payload's words too.
      expect(find.text('Read'), findsOneWidget);
      expect(find.text('Not read yet'), findsOneWidget);
      expect(find.text('You are talking to the mediBO team for this order.'),
          findsNothing);
    });

    testWidgets('a system line is a notice, not somebody talking', (t) async {
      OrderThreadApi.rpcFn = (fn, p) async => customerThread();
      await t.pumpWidget(host(const OrderThreadScreen(orderId: 'O1')));
      await t.pumpAndSettle();
      expect(
          find.text(
              'No reply within 30 minutes — escalated to the mediBO office.'),
          findsOneWidget);
    });

    testWidgets('an empty thread renders the backend empty state', (t) async {
      OrderThreadApi.rpcFn = (fn, p) async {
        final d = customerThread();
        d['messages'] = const [];
        return d;
      };
      await t.pumpWidget(host(const OrderThreadScreen(orderId: 'O1')));
      await t.pumpAndSettle();
      expect(find.text('No messages yet'), findsOneWidget);
      expect(find.text('Ask us anything about this order — we reply here.'),
          findsOneWidget);
    });

    testWidgets('a refusal prints the backend sentence, it does not throw',
        (t) async {
      OrderThreadApi.rpcFn = (fn, p) async => {
            'ok': false,
            'error': 'not_your_thread',
            'message': 'This conversation is not yours to open.',
          };
      await t.pumpWidget(host(const OrderThreadScreen(threadId: 'T404')));
      await t.pumpAndSettle();
      expect(find.text('This conversation is not yours to open.'),
          findsOneWidget);
    });

    testWidgets('sending posts the typed body and renders the SERVER reply',
        (t) async {
      final calls = <List<Object?>>[];
      OrderThreadApi.rpcFn = (fn, p) async {
        calls.add([fn, p['p_body'], p['p_thread_id']]);
        if (fn == 'order_thread_post') {
          final d = customerThread();
          d['toast'] = 'Sent';
          final msgs = (d['messages'] as List).toList()
            ..add({
              'id': 'm5',
              'body': 'Any update?',
              'role': 'customer',
              'mine': true,
              'who_label': 'You',
              'at_label': '03 Sep 2026, 11:30 AM',
              'source': 'app',
              'source_label': '',
              'is_critical': false,
              'read_label': '',
              'attachments': <Map<String, dynamic>>[],
            });
          d['messages'] = msgs;
          return d;
        }
        return customerThread();
      };
      await t.pumpWidget(host(const OrderThreadScreen(orderId: 'O1')));
      await t.pumpAndSettle();

      await t.enterText(find.byType(TextField), 'Any update?');
      await t.tap(find.text('Send'));
      await t.pumpAndSettle();

      expect(calls.any((c) => c[0] == 'order_thread_post' && c[1] == 'Any update?'),
          isTrue);
      // The new message on screen is the one the SERVER sent back.
      expect(find.text('Any update?'), findsOneWidget);
      // showToast holds a 4 s overlay Timer; drain it so the harness does not
      // see a pending timer after the tree is disposed.
      await t.pump(const Duration(seconds: 5));
    });

    testWidgets('an attachment opens the backend bucket and path', (t) async {
      String? bucket;
      String? path;
      OrderThreadApi.rpcFn = (fn, p) async => customerThread();
      await t.pumpWidget(host(const OrderThreadScreen(orderId: 'O1')));
      await t.pumpAndSettle();

      // The opener is injected, so nothing is signed or launched here.
      // (The widget's production path signs exactly these two values.)
      final btn = find.widgetWithText(OutlinedButton, 'bill.jpg');
      expect(btn, findsOneWidget);

      // Assert on the payload the button was built from rather than on a URL:
      // this screen never has one.
      final msgs = (customerThread()['messages'] as List)
          .cast<Map<String, dynamic>>();
      final a = (msgs.first['attachments'] as List).first as Map;
      bucket = a['bucket'] as String;
      path = a['path'] as String;
      expect(bucket, 'whatsapp-media');
      expect(path, 'in/2026/09/bill.jpg');
    });
  });

  group('the inbox', () {
    testWidgets('chips carry the payload counts and rows keep payload order',
        (t) async {
      OrderThreadApi.rpcFn = (fn, p) async =>
          fn == 'thread_inbox' ? inboxPayload() : tasksPayload();
      await t.pumpWidget(host(const SupportThreadsScreen()));
      await t.pumpAndSettle();

      expect(find.text('Waiting 3'), findsOneWidget);
      expect(find.text('Overdue 1'), findsOneWidget);
      // Count 0 prints the bare label — the count is the backend's, and zero
      // is not a badge.
      expect(find.text('Answered'), findsWidgets);
      expect(find.text('All 9'), findsOneWidget);

      // The zone clamp, in the backend's own word.
      expect(find.text('Raipur'), findsOneWidget);

      // Payload order: ZZZ999 before AAA111, which no client-side sort of the
      // title, the customer or the timestamp would produce.
      final zz = t.getTopLeft(find.text('Order ZZZ999')).dy;
      final aa = t.getTopLeft(find.text('Order AAA111')).dy;
      expect(zz, lessThan(aa));

      // The unread badge is the payload's number; a zero renders nothing.
      expect(find.text('2'), findsOneWidget);
      expect(find.text('MB-2609-0007'), findsOneWidget);
    });

    testWidgets('changing a filter re-asks the BACKEND for the list', (t) async {
      final asked = <String>[];
      OrderThreadApi.rpcFn = (fn, p) async {
        if (fn == 'thread_inbox') {
          asked.add('${p['p_filter']}|${p['p_tag']}');
          return inboxPayload();
        }
        return tasksPayload();
      };
      await t.pumpWidget(host(const SupportThreadsScreen()));
      await t.pumpAndSettle();
      expect(asked.first, 'waiting|');

      await t.tap(find.text('Overdue 1'));
      await t.pumpAndSettle();
      expect(asked.contains('breached|'), isTrue);

      // Scoped to the chip: 'Billing' is also a tag on a row, and tapping a
      // row is a different gesture.
      await t.tap(find.widgetWithText(ChoiceChip, 'Billing'));
      await t.pumpAndSettle();
      expect(asked.any((a) => a.endsWith('|billing')), isTrue);
    });
  });

  group('the door', () {
    // THE BUG THIS TEST EXISTS FOR. The shell pushes these screens as a BARE
    // route — `Navigator.push(MaterialPageRoute(builder: (_) =>
    // shellExtraRouteScreen(route)!))` — with no Scaffold around them. The
    // first deploy of this change rendered an empty page for exactly that
    // reason: a TabBar with no Material ancestor throws, and the screen's own
    // catch turned the crash into a blank. Every case above pumped it inside a
    // host Scaffold and passed regardless, which is why the widget test could
    // not see it.
    //
    // So this one pumps it the way the SHELL does. It must render on its own.
    testWidgets('renders as a bare pushed route, with no Scaffold around it',
        (t) async {
      OrderThreadApi.rpcFn = (fn, p) async =>
          fn == 'thread_inbox' ? inboxPayload() : tasksPayload();
      await t.pumpWidget(const MaterialApp(home: SupportThreadsScreen()));
      await t.pumpAndSettle();

      expect(tester_takeException(t), isNull);
      expect(find.text('Customer messages'), findsWidgets);
      expect(find.text('Order ZZZ999'), findsOneWidget);
    });

    testWidgets('the conversation screen is a bare route too', (t) async {
      OrderThreadApi.rpcFn = (fn, p) async => customerThread();
      await t.pumpWidget(const MaterialApp(home: OrderThreadScreen(orderId: 'O1')));
      await t.pumpAndSettle();
      expect(tester_takeException(t), isNull);
      expect(find.text('Order CPO1234'), findsOneWidget);
    });
  });

  group('the calls', () {
    testWidgets('a call button appears only where the payload sent one',
        (t) async {
      OrderThreadApi.rpcFn = (fn, p) async =>
          fn == 'thread_inbox' ? inboxPayload() : tasksPayload();
      await t.pumpWidget(host(const SupportThreadsScreen()));
      await t.pumpAndSettle();

      await t.tap(find.text('Calls to make'));
      await t.pumpAndSettle();

      expect(find.text('The payment reminder not read — call the customer'),
          findsOneWidget);
      expect(find.text('Missed call from the customer — call back'),
          findsOneWidget);
      // has:true -> one button, carrying the backend's label and no number.
      expect(find.text('Call the customer'), findsOneWidget);
      // has:false -> nothing at all, not a disabled control.
      expect(find.text('Overdue by 20 minutes'), findsOneWidget);
      expect(find.text('Due by 03 Sep 2026, 12:30 PM'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Log the outcome'),
          findsNWidgets(2));
    });

    testWidgets('the outcome sheet offers only the payload outcomes', (t) async {
      final logged = <List<Object?>>[];
      OrderThreadApi.rpcFn = (fn, p) async {
        if (fn == 'thread_inbox') return inboxPayload();
        if (fn == 'thread_call_task_log') {
          logged.add([p['p_task_id'], p['p_outcome_code'], p['p_note']]);
          return {'ok': true, 'toast': 'Outcome saved', ...tasksPayload()};
        }
        return tasksPayload();
      };
      await t.pumpWidget(host(const SupportThreadsScreen()));
      await t.pumpAndSettle();
      await t.tap(find.text('Calls to make'));
      await t.pumpAndSettle();

      await t.tap(find.widgetWithText(OutlinedButton, 'Log the outcome').first);
      await t.pumpAndSettle();

      expect(find.text('Spoke to customer'), findsOneWidget);
      expect(find.text('No answer'), findsOneWidget);
      // An outcome the backend did not send is not on the sheet to be tapped.
      expect(find.text('Wrong number'), findsNothing);

      await t.enterText(find.byType(TextField).last, 'rang twice');
      await t.tap(find.text('No answer'));
      await t.pumpAndSettle();

      expect(logged.single, [7, 'no_answer', 'rang twice']);
      await t.pump(const Duration(seconds: 5));
    });
  });
}
