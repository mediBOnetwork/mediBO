// CHANGE — budget, control group, repeat, saved segments and drip sequences.
//
// Six things this holds down, all of them the same thing wearing six faces:
// the new fields are RENDERED, never recomputed.
//
//   1. BUDGET IS THREE INDEPENDENT FIELDS. budget_label is the sentence,
//      budget_tone is the colour, budget_pct is the bar. The app derives none
//      of them from the others — a fixture at 118% with tone 'warn' must draw
//      warn, not the red an app that thresholded budget_pct itself would pick.
//
//   2. blank_warning IS THE BACKEND'S SENTENCE. It appears because
//      blank_values > 0, and it is printed word for word. It does not block.
//
//   3. "run N" COMES FROM is_repeat_child, NOT FROM runs_done > 0. The parent
//      row carries runs_done too, so an app that inferred the chip from the
//      count would stamp it on the parent as well.
//
//   4. THE CONTROL GROUP IS NOT ARITHMETIC. summary and both order_pct values
//      are printed as given. Dividing orders by people here would publish a
//      second answer to a question wa_campaign_holdout() already answered.
//
//   5. THE SEGMENT BUILDER EMITS ONE EXACT SHAPE.
//      {"match":"all","rules":[{"field":"orders","op":"gte","value":"3"}]}
//      Field and operator are strings the payload supplied; the value is typed
//      by the admin and sent as typed.
//
//   6. START FOLLOWS can_start, NOT status. A sequence whose status_label
//      reads "Running" and whose can_start is false shows no Start button.
//
// No network, no Supabase, no goldens — every RPC is a stub returning an inline
// Map, and no test imports home_shell.dart (it pulls in web-only libraries and
// cannot load on the Dart VM).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/wa_campaigns_screen.dart';
import 'package:pharma_b2b/screens/admin/wa_drips_screen.dart';
import 'package:pharma_b2b/screens/admin/wa_segments_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

// ── fixtures ────────────────────────────────────────────────────────────────

Map<String, dynamic> _campaign({
  String? budgetLabel,
  String? budgetTone,
  num? budgetPct,
  int blankValues = 0,
  String blankWarning = '',
  bool isRepeatChild = false,
  int runsDone = 0,
  String repeatLabel = '',
  num holdoutPct = 0,
  String holdoutLabel = '',
}) =>
    {
      'id': 'c1',
      'name': 'August refill push',
      'template': 'refill_reminder',
      'category': 'MARKETING',
      'status': 'running',
      'status_label': 'Sending',
      'status_tone': 'green',
      'audience_label': 'Segment: all approved',
      'schedule_label': '05 Aug, 10:00 am',
      'summary_label': '420 sent · 310 delivered',
      'result_label': '44 clicks · 9 orders',
      'budget_inr': 1000,
      'budget_label': budgetLabel,
      'budget_pct': budgetPct,
      'budget_tone': budgetTone,
      'holdout_pct': holdoutPct,
      'holdout_label': holdoutLabel,
      'repeat_kind': 'weekly',
      'repeat_label': repeatLabel,
      'runs_done': runsDone,
      'is_repeat_child': isRepeatChild,
      'blank_values': blankValues,
      'blank_warning': blankWarning,
      'can_edit': false,
      'can_schedule': false,
      'can_approve': false,
      'can_pause': true,
      'can_resume': false,
      'can_resend_failed': false,
    };

Map<String, dynamic> _listPayload(Map<String, dynamic> campaign) => {
      'ok': true,
      'campaigns': [campaign],
      'audiences': const [],
      'triggers': const [],
      'policy': const {'send_window_label': 'Sends 7:00–22:00 IST'},
      'suppressed_count': 0,
      'suppressed_label': '',
      'empty': const {'title': 'No campaigns yet', 'note': ''},
    };

/// A drip whose STATUS reads like it is running while can_start is false —
/// the two must not be conflated.
Map<String, dynamic> _drip({
  bool canStart = true,
  bool canPause = true,
  bool canStop = true,
}) =>
    {
      'id': 'd1',
      'name': 'Welcome series',
      'status': 'running',
      'status_label': 'Running',
      'status_tone': 'good',
      'audience_label': 'New pharmacies',
      'exit_label': 'Exits on first order',
      'steps': const [
        {
          'step_no': 1,
          'template': 'welcome_hello',
          'delay_label': 'Immediately',
          'sent': 120,
        },
        {
          'step_no': 2,
          'template': 'welcome_catalogue',
          'delay_label': 'Day 3',
          'sent': 84,
        },
      ],
      'active': 41,
      'exited': 63,
      'completed': 16,
      'can_start': canStart,
      'can_pause': canPause,
      'can_stop': canStop,
    };

// ── pump helpers ────────────────────────────────────────────────────────────

/// A distinct key per pump: without it Flutter reuses the existing State,
/// initState never re-runs, and a second fixture is silently ignored.
Future<void> _pumpCampaigns(
  WidgetTester tester,
  Map<String, dynamic> campaign, {
  String key = 'a',
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: WaCampaignsScreen(
        key: ValueKey(key),
        screenRpc: () async => _listPayload(campaign),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Pushes `child` onto a real route so the screen's own Navigator.pop() at the
/// end of a save has something to pop.
Future<void> _pushed(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => ElevatedButton(
            onPressed: () => Navigator.push(
                ctx, MaterialPageRoute<bool>(builder: (_) => child)),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() {
    // RenderLog's 800 ms debounce is a real Timer that would outlive the test
    // and try to reach Supabase.
    RenderLog.flushEnabled = false;
  });

  // The default 800×600 test viewport is short enough to scroll the lower half
  // of a campaign card out of the tree, which would let an assertion pass for
  // the wrong reason — hence the explicit view size in each list test.

  group('budget', () {
    testWidgets('budget_label renders with its own tone and a bar at budget_pct',
        (tester) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await _pumpCampaigns(
        tester,
        _campaign(
          budgetLabel: '₹618 of ₹1,000 spent',
          budgetTone: 'warn',
          budgetPct: 62,
        ),
      );

      // The sentence, verbatim — not "62%" assembled here.
      expect(find.text('₹618 of ₹1,000 spent'), findsOneWidget);

      final bar = tester.widget<LinearProgressIndicator>(
          find.byType(LinearProgressIndicator));
      expect(bar.value, closeTo(0.62, 0.0001));

      // tone 'warn' is the amber palette, chosen by the tone token and not by
      // this app thresholding budget_pct.
      final chip = tester.widget<Container>(
        find
            .ancestor(
              of: find.text('₹618 of ₹1,000 spent'),
              matching: find.byType(Container),
            )
            .first,
      );
      final deco = chip.decoration as BoxDecoration;
      expect(deco.color, const Color(0xFFFEF3C7));
    });

    testWidgets('no budget_label means no budget block at all', (tester) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await _pumpCampaigns(tester, _campaign(), key: 'nobudget');
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });
  });

  group('blank values', () {
    testWidgets('blank_values 2 renders blank_warning verbatim', (tester) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await _pumpCampaigns(
        tester,
        _campaign(
          blankValues: 2,
          blankWarning: '2 recipients have an empty value in this template',
        ),
      );

      expect(
        find.text('2 recipients have an empty value in this template'),
        findsOneWidget,
      );
      // It warns, it does not block: the card's own actions are still there.
      expect(find.text('Pause'), findsOneWidget);
    });

    testWidgets('blank_values 0 hides the warning even when text is present',
        (tester) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await _pumpCampaigns(
        tester,
        _campaign(blankValues: 0, blankWarning: 'should not appear'),
        key: 'noblank',
      );
      expect(find.text('should not appear'), findsNothing);
    });
  });

  group('repeat', () {
    testWidgets('is_repeat_child true renders the run chip from runs_done',
        (tester) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await _pumpCampaigns(
        tester,
        _campaign(
          isRepeatChild: true,
          runsDone: 4,
          repeatLabel: 'Repeats every week on Monday',
        ),
      );

      expect(find.text('run 4'), findsOneWidget);
      expect(find.text('Repeats every week on Monday'), findsOneWidget);
    });

    testWidgets('a parent row carrying runs_done shows no run chip',
        (tester) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      // The distinction that matters: same runs_done, is_repeat_child false.
      await _pumpCampaigns(
        tester,
        _campaign(isRepeatChild: false, runsDone: 4),
        key: 'parent',
      );
      expect(find.text('run 4'), findsNothing);
    });
  });

  group('control group', () {
    testWidgets('holdout payload renders summary and both order_pct values',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: WaHoldoutSection(
                campaignId: 'c1',
                holdoutRpc: (id) async => {
                  'measure_days': 14,
                  'measured_from': 'Measured from 21 Jul',
                  'sent_group': {
                    'people': 480,
                    'orders': 61,
                    'revenue': '₹1,42,300',
                    'order_pct': '12.7%',
                  },
                  'holdout_group': {
                    'people': 120,
                    'orders': 6,
                    'revenue': '₹9,800',
                    'order_pct': '5.0%',
                  },
                  'lift_pct': '+7.7%',
                  'summary': 'Sent group ordered 2.5× more than the held-back group',
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Sent group ordered 2.5× more than the held-back group'),
        findsOneWidget,
      );
      // BOTH groups' order_pct, printed as given.
      expect(find.text('12.7%'), findsOneWidget);
      expect(find.text('5.0%'), findsOneWidget);
      // The headline number and the revenue strings are the backend's too.
      expect(find.text('+7.7%'), findsOneWidget);
      expect(find.text('₹1,42,300'), findsOneWidget);
      expect(find.text('₹9,800'), findsOneWidget);
    });

    testWidgets('an error payload renders its message and no groups',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WaHoldoutSection(
              campaignId: 'c1',
              holdoutRpc: (id) async => {
                'error': 'no_holdout',
                'message': 'This campaign held nobody back',
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('This campaign held nobody back'), findsOneWidget);
      expect(find.text('Sent'), findsNothing);
    });
  });

  group('segment builder', () {
    testWidgets('emits {"match":"all","rules":[{field,op,value}]}',
        (tester) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      Map<String, dynamic>? sent;

      await _pushed(
        tester,
        WaSegmentEditor(
          matchModes: const [
            {'value': 'all', 'label': 'Match all rules'},
            {'value': 'any', 'label': 'Match any rule'},
          ],
          operators: const [
            {'value': 'gte', 'label': 'is at least'},
            {'value': 'lte', 'label': 'is at most'},
          ],
          fields: const {
            'customer': [
              {'value': 'orders', 'label': 'Orders', 'type': 'number'},
              {'value': 'city', 'label': 'City', 'type': 'text'},
            ],
            'supplier': [
              {'value': 'answers', 'label': 'Answers', 'type': 'number'},
            ],
          },
          saveRpc: (params) async {
            sent = params;
            return {'ok': true, 'id': 's9', 'matches': 12, 'summary': '12 contacts'};
          },
        ),
      );

      await tester.tap(find.text('Add rule'));
      await tester.pumpAndSettle();

      // Field: pick "Orders" -> value 'orders'.
      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Orders').last);
      await tester.pumpAndSettle();

      // Operator: pick "is at least" -> value 'gte'.
      await tester.tap(find.byType(DropdownButtonFormField<String>).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('is at least').last);
      await tester.pumpAndSettle();

      // The value is typed and travels as typed.
      await tester.enterText(find.byType(TextField).last, '3');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(sent, isNotNull);
      expect(sent!['p_filters'], {
        'match': 'all',
        'rules': [
          {'field': 'orders', 'op': 'gte', 'value': '3'},
        ],
      });
      expect(sent!['p_audience_of'], 'customer');

      // Let the toast's 4 s timer run out rather than leave it pending.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('the match mode defaults to the payload\'s first, not to "all"',
        (tester) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      Map<String, dynamic>? sent;

      await _pushed(
        tester,
        WaSegmentEditor(
          // Deliberately 'any' first: an app defaulting to a hardcoded 'all'
          // would fail here.
          matchModes: const [
            {'value': 'any', 'label': 'Match any rule'},
            {'value': 'all', 'label': 'Match all rules'},
          ],
          operators: const [
            {'value': 'gte', 'label': 'is at least'},
          ],
          fields: const {
            'supplier': [
              {'value': 'answers', 'label': 'Answers', 'type': 'number'},
            ],
          },
          saveRpc: (params) async {
            sent = params;
            return {'ok': true, 'summary': 'ok'};
          },
        ),
      );

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect((sent!['p_filters'] as Map)['match'], 'any');
      // And the audience side is the first key the payload listed.
      expect(sent!['p_audience_of'], 'supplier');

      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });
  });

  group('sequences', () {
    testWidgets('can_start false hides Start while status_label says Running',
        (tester) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: WaDripsScreen(
            key: const ValueKey('nostart'),
            screenRpc: () async => {
              'rows': [_drip(canStart: false)],
              'empty_copy': '',
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Running'), findsOneWidget);
      expect(find.text('Start'), findsNothing);
      // The other two flags were true, so their buttons are present — proving
      // the row rendered its action bar at all.
      expect(find.text('Pause'), findsOneWidget);
      expect(find.text('Stop'), findsOneWidget);
    });

    testWidgets('steps render delay_label and sent, and the three counts show',
        (tester) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: WaDripsScreen(
            key: const ValueKey('steps'),
            screenRpc: () async => {
              'rows': [_drip()],
              'empty_copy': '',
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Immediately'), findsOneWidget);
      expect(find.text('Day 3'), findsOneWidget);
      expect(find.text('welcome_catalogue'), findsOneWidget);
      expect(find.text('120'), findsOneWidget);
      expect(find.text('41'), findsOneWidget);
      expect(find.text('63'), findsOneWidget);
      expect(find.text('16'), findsOneWidget);
      expect(find.text('Start'), findsOneWidget);
    });

    testWidgets('empty_copy is the backend\'s, printed when there are no rows',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: WaDripsScreen(
            key: const ValueKey('empty'),
            screenRpc: () async => {
              'rows': const [],
              'empty_copy': 'No sequences yet — build one from a saved segment',
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('No sequences yet — build one from a saved segment'),
        findsOneWidget,
      );
    });
  });
}
