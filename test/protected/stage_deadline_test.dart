// PROTECTED — CMD #1845, the Stage deadlines sheet.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes stage-deadline behaviour, never to make an unrelated
// change go green.
//
// The change this holds down is a rule, not a screen: a stage's promise is a
// TIME OF DAY that every order in that stage shares, and every word of it —
// including the 12-hour string — is written by the backend. So:
//
//   1. THE SHEET IS A PRINTER. Title, mode names, day names, the per-stage
//      preview ("Due 12:00 PM"), the save caption and the read-only sentence
//      are payload strings. The fixture's preview_label deliberately disagrees
//      with its own due_time_display, so a sheet that re-derived the preview
//      from the time fails.
//
//   2. THE MODE OPTIONS ARE THE PAYLOAD'S. `modes` drives the chips, so a mode
//      added in SQL appears with no deploy — and a mode this build has never
//      heard of is still offered rather than silently dropped.
//
//   3. MODE DECIDES THE CONTROL, and the payload decides the mode. A clock
//      stage offers the time button and NO minutes field; a duration stage
//      offers the minutes field and no time button.
//
//   4. A PICKED TIME IS WORDED BY THE BACKEND. The sheet never formats an hour
//      and minute itself: it hands them to formatTime (ops_time_label) and
//      prints the reply. The stub deliberately returns a string no Dart
//      formatter would produce.
//
//   5. THE SUBMITTED PAYLOAD CARRIES MODE + HOUR/MINUTE, and the working week
//      goes with it as day NUMBERS — never a formatted string, never a Dart
//      default for a stage the admin did not touch.
//
//   6. can_edit IS THE BACKEND'S DECISION. false disables save and every
//      control, and prints the backend's own read-only sentence on the button.
//
// No network, no Supabase, no goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/ops_board_view.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _config({bool canEdit = true}) => {
      'ok': true,
      'can_edit': canEdit,
      'zone_id': null,
      'zone_label': 'All zones',
      'active_date': '2026-09-06',
      'date_label': '6 Sep 2026',
      'title': 'Stage deadlines',
      'subtitle': 'When work in each stage is due.',
      'modes': [
        {'key': 'clock', 'label': 'Clock time', 'hint': 'Same time every day'},
        {'key': 'duration', 'label': 'Duration', 'hint': 'Minutes from entry'},
      ],
      'mode_label': 'Mode',
      'time_label': 'Due time',
      'minutes_label': 'Minutes',
      'time_picker_title': 'Pick the due time',
      'week': {
        'title': 'Working days',
        'subtitle': 'A passed deadline rolls to the next working day.',
        'days': [
          {'n': 1, 'label': 'Mon', 'on': true},
          {'n': 2, 'label': 'Tue', 'on': true},
          {'n': 7, 'label': 'Sun', 'on': false},
        ],
      },
      'save_label': 'Save deadlines',
      'saved_message': 'Stage deadlines saved.',
      'readonly_message': 'Only a super admin can change a stage deadline.',
      'rows': [
        {
          'stage_key': 'accept',
          'label': 'Accept',
          'owner_label': 'Partner',
          'mode': 'clock',
          'sla_minutes': 30,
          'amber_pct': 70,
          'due_hour': 12,
          'due_minute': 0,
          'due_time_display': '12:00 PM',
          // Deliberately NOT "Due 12:00 PM": the preview is the backend's
          // sentence, not something the sheet can rebuild from due_time.
          'preview_label': 'Due 12:00 PM sharp',
          'source_label': 'Platform default',
        },
        {
          'stage_key': 'collect',
          'label': 'Collect',
          'owner_label': 'Partner',
          'mode': 'duration',
          'sla_minutes': 180,
          'amber_pct': 70,
          'due_hour': null,
          'due_minute': null,
          'due_time_display': '',
          'preview_label': 'Deadline 3h',
          'source_label': 'Zone override',
        },
      ],
    };

Widget _host(
  Map<String, dynamic> cfg, {
  Future<String> Function(int, int)? formatTime,
  Future<Map<String, dynamic>> Function(Map<String, dynamic>)? onSave,
}) =>
    MaterialApp(
      home: Scaffold(
        body: StageDeadlineSheetView(
          config: cfg,
          zoneId: 3,
          formatTime: formatTime ?? (h, m) async => 'BACKEND SAID $h:$m',
          onSave: onSave ?? (p) async => {'ok': true},
        ),
      ),
    );

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  testWidgets('every word on the sheet is the backend\'s', (t) async {
    await t.pumpWidget(_host(_config()));
    await t.pumpAndSettle();

    expect(find.text('Stage deadlines'), findsOneWidget);
    expect(find.text('Save deadlines'), findsOneWidget);
    expect(find.text('Working days'), findsOneWidget);
    // The mode chips are the payload's, both of them, on every row.
    expect(find.text('Clock time'), findsNWidgets(2));
    expect(find.text('Duration'), findsNWidgets(2));
    // The preview is printed verbatim — it is NOT rebuilt from due_time.
    expect(find.textContaining('Due 12:00 PM sharp'), findsOneWidget);
    expect(find.textContaining('Deadline 3h'), findsOneWidget);
    // No 24-hour string reaches the screen.
    expect(find.textContaining('12:00 PM'), findsWidgets);
    expect(find.textContaining('16:'), findsNothing);
  });

  testWidgets('mode decides the control: a time button OR a minutes field',
      (t) async {
    await t.pumpWidget(_host(_config()));
    await t.pumpAndSettle();

    // accept is a clock stage: its value is a button showing the 12-hour time.
    expect(find.widgetWithText(OutlinedButton, '12:00 PM'), findsOneWidget);
    // collect is a duration stage: exactly one minutes field, seeded from the
    // payload's own sla_minutes.
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('180'), findsOneWidget);
  });

  testWidgets('an unknown mode from the backend is still offered', (t) async {
    final cfg = _config();
    (cfg['modes'] as List).add({'key': 'shift', 'label': 'Shift end'});
    await t.pumpWidget(_host(cfg));
    await t.pumpAndSettle();
    expect(find.text('Shift end'), findsNWidgets(2));
  });

  testWidgets('switching a stage to duration swaps its control', (t) async {
    await t.pumpWidget(_host(_config()));
    await t.pumpAndSettle();

    // Tap "Duration" on the FIRST row (accept, currently clock).
    await t.tap(find.text('Duration').first);
    await t.pumpAndSettle();

    // Both rows are now duration: two minutes fields, no time button.
    expect(find.byType(TextField), findsNWidgets(2));
    expect(find.widgetWithText(OutlinedButton, '12:00 PM'), findsNothing);
  });

  testWidgets('the submitted payload carries mode, hour/minute and day numbers',
      (t) async {
    Map<String, dynamic>? sent;
    await t.pumpWidget(_host(_config(), onSave: (p) async {
      sent = p;
      return {'ok': false, 'message': 'not saved'};
    }));
    await t.pumpAndSettle();

    await t.tap(find.text('Save deadlines'));
    await t.pumpAndSettle();

    expect(sent, isNotNull);
    expect(sent!['zone_id'], 3);
    final rows = (sent!['rows'] as List).cast<Map<String, dynamic>>();
    expect(rows.length, 2);

    final accept = rows.firstWhere((r) => r['stage_key'] == 'accept');
    expect(accept['mode'], 'clock');
    expect(accept['due_hour'], 12);
    expect(accept['due_minute'], 0);

    final collect = rows.firstWhere((r) => r['stage_key'] == 'collect');
    expect(collect['mode'], 'duration');
    expect(collect['sla_minutes'], 180);

    // The working week goes as NUMBERS, and only the days the payload had on.
    expect(sent!['week_days'], [1, 2]);

    // A refusal prints the backend's message rather than a Dart apology.
    expect(find.text('not saved'), findsOneWidget);
  });

  testWidgets('a day chip toggles into the submitted week', (t) async {
    Map<String, dynamic>? sent;
    await t.pumpWidget(_host(_config(), onSave: (p) async {
      sent = p;
      return {'ok': false, 'message': ''};
    }));
    await t.pumpAndSettle();

    await t.ensureVisible(find.text('Sun'));
    await t.pumpAndSettle();
    await t.tap(find.text('Sun'));
    await t.pumpAndSettle();
    await t.tap(find.text('Save deadlines'));
    await t.pumpAndSettle();

    expect(sent!['week_days'], [1, 2, 7]);
  });

  testWidgets('a picked time is worded by the backend, never by Dart',
      (t) async {
    var asked = 0;
    await t.pumpWidget(_host(_config(), formatTime: (h, m) async {
      asked++;
      return 'HALF PAST FOUR';
    }));
    await t.pumpAndSettle();

    await t.tap(find.widgetWithText(OutlinedButton, '12:00 PM'));
    await t.pumpAndSettle();
    // The Material picker is open; accept its initial value.
    await t.tap(find.text('OK'));
    await t.pumpAndSettle();

    expect(asked, 1);
    expect(find.widgetWithText(OutlinedButton, 'HALF PAST FOUR'), findsOneWidget);
  });

  testWidgets('can_edit:false locks the sheet and prints the backend sentence',
      (t) async {
    var saves = 0;
    await t.pumpWidget(_host(_config(canEdit: false), onSave: (p) async {
      saves++;
      return {'ok': true};
    }));
    await t.pumpAndSettle();

    expect(find.text('Only a super admin can change a stage deadline.'),
        findsOneWidget);
    expect(find.text('Save deadlines'), findsNothing);

    final btn = t.widget<FilledButton>(find.byType(FilledButton));
    expect(btn.onPressed, isNull);

    await t.tap(find.widgetWithText(OutlinedButton, '12:00 PM'));
    await t.pumpAndSettle();
    expect(saves, 0);
    expect(find.text('OK'), findsNothing);
  });

  testWidgets('a board row prints deadline_label, and falls back to sla_label',
      (t) async {
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: OpsBoardView(payload: {
          'ok': true,
          'title': 'Ops board',
          'zone_label': 'All zones',
          'can_edit_sla': true,
          'deadline_button': 'Stage deadline settings',
          'sla_button': 'SLA settings',
          'chips': const [],
          'has_any': true,
          'rows': [
            {
              'order_id': 'a',
              'order_code': 'C1',
              'customer': 'Shop A',
              'amount_display': '₹1,000.00',
              'stage_key': 'accept',
              'stage_label': 'Accept',
              'owner_label': 'Partner',
              'next_action': 'Accept and start inquiry',
              'clock_label': '4m over',
              'deadline_label': 'Deadline 12:00 PM',
              'sla_label': 'Deadline 12:00 PM',
              'tone': 'red',
              'tone_label': 'Breached',
            },
            {
              'order_id': 'b',
              'order_code': 'C2',
              'customer': 'Shop B',
              'amount_display': '₹2,000.00',
              'stage_key': 'collect',
              'stage_label': 'Collect',
              'owner_label': 'Partner',
              'next_action': 'Collect from the shop',
              'clock_label': '2h left',
              // No deadline_label at all — a payload from before the rename.
              'sla_label': 'Deadline 3h',
              'tone': 'green',
              'tone_label': 'On time',
            },
          ],
        }, onEditSla: () {}),
      ),
    ));
    await t.pumpAndSettle();

    // The renamed key wins, and the word "SLA" is nowhere on the screen.
    expect(find.text('Stage deadline settings'), findsOneWidget);
    expect(find.text('SLA settings'), findsNothing);
    expect(find.text('Deadline 12:00 PM'), findsOneWidget);
    expect(find.text('Deadline 3h'), findsOneWidget);
    expect(find.text('4m over'), findsOneWidget);
  });
}
