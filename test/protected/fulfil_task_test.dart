// PROTECTED — CHANGE #707, the fulfilment stage gets a named owner.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes worker-task behaviour, never to make an unrelated change
// go green.
//
// Before #707 the pipeline knew WHAT stage an order sat in and, afterwards, who
// had touched each line — but never who was SUPPOSED to do the next stage. The
// three screens added here are the whole of that feature's surface, and every
// one of them is a renderer. What this file holds down:
//
//   1. THE OWNER CHIP IS THE BACKEND'S WORD AND THE BACKEND'S TONE. An
//      unassigned stage prints `worker_label` with `worker_tone` — it is NOT a
//      null check turned into a colour here. The fixture deliberately sends
//      'warning' for the unassigned row and 'success' for the assigned one, so
//      a widget that re-derived the tone from worker_id would still pass a
//      string test and fails this one.
//
//   2. can_write:false REMOVES THE AFFORDANCE, it does not grey it out. No
//      Assign button, no Auto-assign button — a read-only partner cannot reach
//      the write RPC from the screen at all.
//
//   3. THE ASSIGN SHEET OFFERS ONLY THE WORKERS THE PAYLOAD SENT. The backend
//      sends the on-shift roster; an absent worker is absent from `workers` and
//      is therefore unpickable, without this file knowing what a shift is.
//
//   4. THE WORKER'S LIST IS IN PAYLOAD ORDER. fulfil_my_tasks() sorts by the
//      promise it computed against each stage's SLA; the fixture is
//      deliberately NOT in order-code order, so a client-side sort fails.
//
//   5. START vs FINISH IS THE PAYLOAD'S `started` FLAG, and both captions are
//      backend strings. A row that has been started shows finish_label and
//      calls fulfil_task_finish; one that has not shows start_label and calls
//      fulfil_task_start. The widget never reads state_label to guess.
//
//   6. NOTHING ON THE WORKERS CONSOLE IS ARITHMETIC. items/hour, the variance
//      percentage and the '—' that means "nothing measured yet" print exactly
//      as they arrived — including a '%' the widget never appends — and an
//      older payload with no `productivity` block draws the card it always drew
//      instead of a row of zeroes.
//
// Fixtures mirror fulfil_task_board() / fulfil_my_tasks() /
// partner_workers_console(). No network, no Supabase, no timers.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/partner/partner_home_screen.dart';
import 'package:pharma_b2b/screens/partner/partner_tasks_screen.dart';
import 'package:pharma_b2b/screens/partner/partner_ui.dart';
import 'package:pharma_b2b/screens/shell/shell_extra_routes.dart';
import 'package:pharma_b2b/screens/partner/partner_workers_screen.dart';
import 'package:pharma_b2b/screens/worker/worker_tasks_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

import 'registered_routes.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

/// fulfil_task_board(): one stage nobody owns, one already given to a named
/// worker. Every label is finished text — the widget adds no punctuation.
Map<String, dynamic> _board({bool canWrite = true}) => {
      'ok': true,
      'title': 'Task board',
      'subtitle': 'Who is doing each stage, right now',
      'empty_label': 'No stages are waiting for a worker right now.',
      'assign_label': 'Assign',
      'reassign_label': 'Reassign',
      'unassigned_label': 'Unassigned',
      'can_write': canWrite,
      'auto_assign': false,
      'auto_label': 'Auto-assign',
      'auto_state_label': 'Auto-assign is off for this zone',
      'workers_title': 'Workers today',
      'zone_id': 3,
      'workers': const [
        {'worker_id': 11, 'name': 'Asha', 'role': 'counting', 'open_n': 0},
        {'worker_id': 12, 'name': 'Ravi', 'role': 'packing', 'open_n': 2},
      ],
      'rows': const [
        {
          'order_id': 'aaaa-1111',
          'order_code': 'MB-2001',
          'customer': 'Sai Medicals',
          'stage_key': 'count',
          'stage_label': 'Counting',
          'age_label': '18m',
          'promised_label': 'Promised 4:20 PM',
          'task': {
            'has': true,
            'task_id': 501,
            'assigned': false,
            'worker_id': null,
            'worker_label': 'Unassigned',
            'worker_name': '',
            'worker_tone': 'warning',
            'source': 'manual',
            'started': false,
            'state_label': 'Waiting 18m',
            'qty_label': 'Nothing counted yet',
            'is_override': false,
            'override_chip': null,
            'start_label': 'Start',
            'finish_label': 'Finish',
          },
        },
        {
          'order_id': 'bbbb-2222',
          'order_code': 'MB-2002',
          'customer': 'Nova Chemist',
          'stage_key': 'pack',
          'stage_label': 'Packing',
          'age_label': '4m',
          'promised_label': 'Promised 4:35 PM',
          'task': {
            'has': true,
            'task_id': 502,
            'assigned': true,
            'worker_id': 12,
            'worker_label': 'Ravi',
            'worker_name': 'Ravi',
            'worker_tone': 'success',
            'source': 'auto',
            'started': true,
            'state_label': 'Started 4m',
            'qty_label': '9 items',
            'is_override': false,
            'override_chip': null,
            'start_label': 'Start',
            'finish_label': 'Finish',
          },
        },
      ],
    };

/// fulfil_my_tasks(): DELIBERATELY NOT in order-code order. MB-3009 is promised
/// first, so it is sent first; a screen that sorted by code would put MB-3001
/// on top and disagree with the ops board's clock.
Map<String, dynamic> _mine() => {
      'ok': true,
      'title': 'My tasks',
      'subtitle': 'Today, in the order they are promised',
      'empty_label': 'Nothing is assigned to you today.',
      'worker_id': 12,
      'rows': const [
        {
          'order_id': 'cccc-3333',
          'order_code': 'MB-3009',
          'stage_key': 'count',
          'stage_label': 'Counting',
          'promised_label': 'Promised 2:05 PM',
          'task': {
            'has': true,
            'task_id': 601,
            'assigned': true,
            'worker_label': 'Ravi',
            'worker_tone': 'success',
            'started': false,
            'state_label': 'Waiting 6m',
            'qty_label': 'Nothing counted yet',
            'override_chip': null,
            'start_label': 'Start',
            'finish_label': 'Finish',
          },
        },
        {
          'order_id': 'dddd-4444',
          'order_code': 'MB-3001',
          'stage_key': 'pack',
          'stage_label': 'Packing',
          'promised_label': 'No promised time',
          'task': {
            'has': true,
            'task_id': 602,
            'assigned': true,
            'worker_label': 'Ravi',
            'worker_tone': 'success',
            'started': true,
            'state_label': 'Started 11m',
            'qty_label': '14 items',
            'override_chip': 'Override',
            'start_label': 'Start',
            'finish_label': 'Finish',
          },
        },
      ],
    };

/// partner_workers_console() with the #707 block. Asha has closed work and so
/// has a measured rate; Nadia has none, so the backend sent its own dash.
Map<String, dynamic> _workers({bool withProductivity = true}) => {
      'ok': true,
      'screen_title': 'Workers',
      'intro': 'Your counting and packing staff.',
      'can_write': true,
      'add_label': 'Add worker',
      'remove_label': 'Remove',
      'identity_hint': 'Login id',
      'name_hint': 'Name',
      'role_label': 'Role',
      'empty_text': 'No workers yet.',
      'shift_title': "Today's attendance",
      'shift_hint': 'Mark who is in.',
      'today_label': '03 Sep 2026',
      'prod_title': 'Workers today',
      'prod_tasks_label': 'Tasks',
      'prod_items_label': 'Items/hour',
      'prod_variance_label': 'Count variance',
      'prod_packerr_label': 'Pack errors',
      'role_options': const [
        {'value': 'counting', 'label': 'Counting'},
        {'value': 'packing', 'label': 'Packing'},
      ],
      'shift_options': const [
        {'value': 'present', 'label': 'Present', 'tone': 'success'},
        {'value': 'absent', 'label': 'Absent', 'tone': 'danger'},
      ],
      'rows': [
        {
          'id': 11,
          'name': 'Asha',
          'identity': 'asha01',
          'role': 'counting',
          'role_label': 'Counting',
          'shift': 'present',
          'shift_label': 'Present',
          'shift_tone': 'success',
          if (withProductivity)
            'productivity': const {
              'worker_id': 11,
              'name': 'Asha',
              'tasks_done': 7,
              'tasks_open': 2,
              'open_label': '2 open',
              'items': 214,
              'items_per_hour': '38.6',
              'variance_rate': '4.2%',
              'pack_errors': 1,
              'pack_errors_label': '1',
            },
        },
        {
          'id': 12,
          'name': 'Nadia',
          'identity': 'nadia02',
          'role': 'packing',
          'role_label': 'Packing',
          'shift': 'absent',
          'shift_label': 'Absent',
          'shift_tone': 'danger',
          if (withProductivity)
            'productivity': const {
              'worker_id': 12,
              'name': 'Nadia',
              'tasks_done': 0,
              'tasks_open': 0,
              'open_label': '0 open',
              'items': 0,
              'items_per_hour': '—',
              'variance_rate': '—',
              'pack_errors': 0,
              'pack_errors_label': '—',
            },
        },
      ],
    };

void main() {
  setUpAll(() {
    // RenderLog.write's 800 ms debounce is a real Timer that would outlive the
    // test and try to reach Supabase.
    RenderLog.flushEnabled = false;
  });

  group('CHANGE #707 — the partner task board', () {
    testWidgets('the owner chip is the payload word AND the payload tone',
        (t) async {
      await t.pumpWidget(_host(PartnerTasksView(payload: _board())));

      expect(find.text('Unassigned'), findsOneWidget);
      expect(find.text('Ravi'), findsOneWidget);

      // The tone is read off the widget, not guessed from worker_id: the
      // fixture's unassigned row carries 'warning' and the assigned one
      // 'success', and both must arrive on the chip verbatim.
      final chips = t
          .widgetList<PartnerChip>(find.byType(PartnerChip))
          .toList(growable: false);
      expect(chips.map((c) => c.text).toList(), ['Unassigned', 'Ravi']);
      expect(chips.map((c) => c.tone).toList(), ['warning', 'success']);
    });

    testWidgets('rows render in payload order with their finished strings',
        (t) async {
      await t.pumpWidget(_host(PartnerTasksView(
        payload: _board(),
        onAutoAssign: () {},
      )));

      final codes = t
          .widgetList<Text>(find.byType(Text))
          .map((w) => w.data ?? '')
          .where((s) => s.startsWith('MB-'))
          .toList();
      expect(codes, ['MB-2001', 'MB-2002']);

      // The stage/age line is composed from two payload fields and nothing
      // else; the promise is a whole backend sentence.
      expect(find.text('Counting · 18m'), findsOneWidget);
      expect(find.text('Promised 4:20 PM'), findsOneWidget);
      expect(find.text('Waiting 18m'), findsOneWidget);
      // The auto-assign STATE is a backend sentence too — this file never
      // writes "on"/"off" from the auto_assign boolean.
      expect(find.text('Auto-assign is off for this zone'), findsOneWidget);
    });

    testWidgets('assign says Assign when unowned and Reassign when owned',
        (t) async {
      await t.pumpWidget(_host(PartnerTasksView(
        payload: _board(),
        onAssign: (_) {},
        onAutoAssign: () {},
      )));

      expect(find.widgetWithText(OutlinedButton, 'Assign'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Reassign'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Auto-assign'), findsOneWidget);
    });

    testWidgets('can_write:false REMOVES the affordance, it does not grey it',
        (t) async {
      // The screen passes null callbacks when the backend said can_write:false.
      await t.pumpWidget(_host(PartnerTasksView(payload: _board(canWrite: false))));

      expect(find.text('Assign'), findsNothing);
      expect(find.text('Reassign'), findsNothing);
      expect(find.text('Auto-assign'), findsNothing);
      expect(find.byType(OutlinedButton), findsNothing);
      // The board itself is still fully readable.
      expect(find.text('MB-2001'), findsOneWidget);
      expect(find.text('Unassigned'), findsOneWidget);
    });

    testWidgets('tapping assign hands back the row the backend addressed',
        (t) async {
      Map<String, dynamic>? got;
      await t.pumpWidget(_host(PartnerTasksView(
        payload: _board(),
        onAssign: (r) => got = r,
      )));

      await t.tap(find.widgetWithText(OutlinedButton, 'Assign'));
      await t.pump();

      // The order id and stage key travel back untouched — the RPC is addressed
      // by the backend's own keys, never by an index into the list.
      expect(got?['order_id'], 'aaaa-1111');
      expect(got?['stage_key'], 'count');
    });

    testWidgets('an empty board prints the backend empty line', (t) async {
      final p = _board()..['rows'] = const [];
      await t.pumpWidget(_host(PartnerTasksView(payload: p)));

      expect(find.text('No stages are waiting for a worker right now.'),
          findsOneWidget);
    });
  });

  group('CHANGE #707 — the worker\'s own list', () {
    testWidgets('rows keep the backend promise order, not code order',
        (t) async {
      await t.pumpWidget(_host(WorkerTasksView(
        payload: _mine(),
        onStart: (_) {},
        onFinish: (_) {},
      )));

      final codes = t
          .widgetList<Text>(find.byType(Text))
          .map((w) => w.data ?? '')
          .where((s) => s.startsWith('MB-'))
          .toList();
      // MB-3009 is promised at 2:05 PM and MB-3001 has no promise at all, so
      // the backend sent 3009 first. A client-side sort would invert this.
      expect(codes, ['MB-3009', 'MB-3001']);
      expect(find.text('No promised time'), findsOneWidget);
    });

    testWidgets('start vs finish is the started flag, with backend captions',
        (t) async {
      final started = <Object>[];
      final finished = <Object>[];
      await t.pumpWidget(_host(WorkerTasksView(
        payload: _mine(),
        onStart: started.add,
        onFinish: finished.add,
      )));

      // Row one has started:false -> Start. Row two has started:true -> Finish.
      expect(find.widgetWithText(FilledButton, 'Start'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Finish'), findsOneWidget);

      await t.tap(find.widgetWithText(FilledButton, 'Start'));
      await t.pump();
      await t.tap(find.widgetWithText(FilledButton, 'Finish'));
      await t.pump();

      // Each button carries its OWN task id — the ids are the backend's.
      expect(started, [601]);
      expect(finished, [602]);
    });

    testWidgets('the override chip appears only where the payload sent one',
        (t) async {
      await t.pumpWidget(_host(WorkerTasksView(
        payload: _mine(),
        onStart: (_) {},
        onFinish: (_) {},
      )));

      // Row one's override_chip is null; row two's is 'Override'.
      expect(find.text('Override'), findsOneWidget);
      expect(find.text('Nothing counted yet'), findsOneWidget);
      expect(find.text('14 items'), findsOneWidget);
    });

    testWidgets('an empty day prints the backend empty line', (t) async {
      final p = _mine()..['rows'] = const [];
      await t.pumpWidget(_host(WorkerTasksView(
        payload: p,
        onStart: (_) {},
        onFinish: (_) {},
      )));

      expect(find.text('Nothing is assigned to you today.'), findsOneWidget);
    });
  });

  group('CHANGE #707 — the Workers console columns', () {
    testWidgets('every cell is a backend string, headings included', (t) async {
      await t.pumpWidget(_host(PartnerWorkersView(
        payload: _workers(),
        onRemove: (_) {},
        onShift: (_, __) {},
      )));

      for (final h in const [
        'Tasks',
        'Items/hour',
        'Count variance',
        'Pack errors'
      ]) {
        expect(find.text(h), findsNWidgets(2)); // one per worker card
      }

      // Asha's measured numbers print verbatim — the '%' is the backend's.
      expect(find.text('7'), findsOneWidget);
      expect(find.text('38.6'), findsOneWidget);
      expect(find.text('4.2%'), findsOneWidget);
      expect(find.text('2 open'), findsOneWidget);
    });

    testWidgets('no measurement is the backend dash, never a Dart zero',
        (t) async {
      await t.pumpWidget(_host(PartnerWorkersView(
        payload: _workers(),
        onRemove: (_) {},
        onShift: (_, __) {},
      )));

      // Nadia closed nothing: items/hour, variance and pack errors are all the
      // backend's '—'. A widget that printed 0.0 or '0%' would be inventing a
      // measurement that was never taken.
      expect(find.text('—'), findsNWidgets(3));
      expect(find.text('0 open'), findsOneWidget);
    });

    testWidgets('a payload with no productivity block draws the old card',
        (t) async {
      await t.pumpWidget(_host(PartnerWorkersView(
        payload: _workers(withProductivity: false),
        onRemove: (_) {},
        onShift: (_, __) {},
      )));

      // Forward/backward compatibility: the columns are absent, and nothing
      // throws or renders a placeholder number.
      expect(find.text('Tasks'), findsNothing);
      expect(find.text('Items/hour'), findsNothing);
      expect(find.text('Asha'), findsOneWidget);
      expect(find.text('Present'), findsOneWidget);
    });
  });

  group('CHANGE #707 — reachability', () {
    // This group is the one that would have caught the shipping bug. Both
    // screens were first wired ONLY into partnerDestination(), and nothing in
    // the app calls that resolver any more — #653 retired the partner surface
    // and took its three entry points with it. The screens compiled, the RPCs
    // answered, and every tap fell through home_shell's switch into the
    // backend's "route unavailable". A feature Om cannot reach does not exist,
    // so the door the SHELL actually looks in is what is pinned here.
    test('the shell opens both route keys', () {
      expect(shellExtraRouteScreen('fulfil_tasks'), isA<PartnerTasksScreen>());
      expect(shellExtraRouteScreen('my_tasks'), isA<WorkerTasksScreen>());
      // Null means "not mine, keep looking" — never "broken" — so an unknown
      // key still reaches the shell's own backend-worded default branch.
      expect(shellExtraRouteScreen('a_key_from_the_future'), isNull);
    });

    test('and the mirror the nav gate reads names them', () {
      // registered_routes.dart is generated from surface_route. A door written
      // in Dart that the mirror never hears about is a door no gate checks —
      // which is how the mirror drifted 31 routes behind by #821.
      expect(kRegisteredAdminRoutes, contains('fulfil_tasks'));
      expect(kRegisteredAdminRoutes, contains('my_tasks'));
    });

    test('the partner console resolver still answers, for whoever revives it',
        () {
      expect(partnerDestination('fulfil_tasks'), isA<PartnerTasksScreen>());
      expect(partnerDestination('my_tasks'), isA<WorkerTasksScreen>());
      expect(partnerDestination('a_key_from_the_future'), isNull);
    });
  });
}
