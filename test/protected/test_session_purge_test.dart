// PROTECTED — CMD #1852.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes purge-reporting behaviour, never to make an unrelated
// change go green.
//
// What this holds down — the End & purge verdict is a PRINTER, and the one
// screen in the app whose whole job is to say whether a wipe can be trusted:
//
//   1. Every word is `test_session_outcome()`'s. Title, each row's label and
//      value, the fingerprint sentence and the close button. The fixture
//      deliberately makes its own numbers DISAGREE — 12 writes reversed, 4
//      rows swept, and 7 still held — so a sheet that added anything up, or
//      derived the title from the rows, fails here.
//
//   2. A mismatch is never softened. The fixture's verdict names a table and
//      carries tone `danger`; the sheet prints that sentence verbatim rather
//      than a Dart summary of it. This is the rule the whole command exists
//      for: a purge that cannot be proven complete must not read as success.
//
//   3. Absence is a flag, not an empty string. `has:false` draws nothing at
//      all, an absent verdict omits its block rather than printing a dash,
//      and an absent close word draws no button.
//
//   4. Tone is carried, not inferred. Colour comes from the payload's own
//      `tone` through one lookup; a tone this build has never heard of stays
//      neutral instead of being guessed from the value.
//
//   5. Rows render in PAYLOAD ORDER. The fixture is deliberately not sorted by
//      label, by value or by tone, so any client-side sort fails here.
//
//   6. THE BANNER ACTUALLY SHOWS IT. End & purge is the only way into this
//      sheet, so the wiring is held down here too: a reply carrying a verdict
//      opens the sheet and does NOT fall back to the one-line snackbar, and a
//      reply with no verdict (an older backend, a refusal, an error) still
//      shows the backend's sentence exactly as it did before.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/design_tokens.dart';
import 'package:pharma_b2b/widgets/test_mode_banner.dart';
import 'package:pharma_b2b/widgets/test_purge_outcome.dart';

Map<String, dynamic> _outcome({
  bool has = true,
  String tone = 'danger',
  String verdict =
      'Purge incomplete — these tables still differ: notification_log',
  String verdictTone = 'danger',
  String close = 'Done',
  List<Map<String, dynamic>>? lines,
}) =>
    {
      'has': has,
      'title': 'Purge incomplete',
      'tone': tone,
      // Deliberately unsorted, and deliberately inconsistent with each other.
      'lines': lines ??
          const [
            {'label': 'Writes reversed', 'value': '12', 'tone': 'neutral'},
            {'label': 'Rows still held', 'value': '7', 'tone': 'danger'},
            {'label': 'Files removed', 'value': '0', 'tone': 'aubergine'},
            {'label': 'Rows removed by the sweep', 'value': '4', 'tone': 'neutral'},
          ],
      'verdict': verdict,
      'verdict_tone': verdictTone,
      'close': close,
    };

Widget _host(Map<String, dynamic> outcome) => MaterialApp(
      home: Scaffold(body: TestPurgeOutcomeSheet(outcome: outcome)),
    );

void main() {
  testWidgets('every word on the sheet is the payload, verbatim',
      (tester) async {
    await tester.pumpWidget(_host(_outcome()));

    expect(find.text('Purge incomplete'), findsOneWidget);
    expect(find.text('Writes reversed'), findsOneWidget);
    expect(find.text('12'), findsOneWidget);
    expect(find.text('Rows removed by the sweep'), findsOneWidget);
    expect(find.text('4'), findsOneWidget);
    expect(find.text('Rows still held'), findsOneWidget);
    expect(find.text('7'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);

    // The numbers do not add up on purpose: nothing here is computed.
    expect(find.text('23'), findsNothing);
    expect(find.text('16'), findsNothing);
  });

  testWidgets('the fingerprint verdict is printed, not summarised',
      (tester) async {
    await tester.pumpWidget(_host(_outcome()));
    expect(
      find.text('Purge incomplete — these tables still differ: notification_log'),
      findsOneWidget,
    );

    // …and the success wording is the backend's too, not a Dart branch on a
    // boolean the sheet never sees.
    await tester.pumpWidget(_host(_outcome(
      tone: 'success',
      verdict: 'Every table is byte-identical to before the session started.',
      verdictTone: 'success',
    )));
    await tester.pumpAndSettle();
    expect(
      find.text('Every table is byte-identical to before the session started.'),
      findsOneWidget,
    );
  });

  testWidgets('lines render in payload order — no client-side sort',
      (tester) async {
    await tester.pumpWidget(_host(_outcome()));
    final labels = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data)
        .where((d) =>
            d == 'Writes reversed' ||
            d == 'Rows still held' ||
            d == 'Files removed' ||
            d == 'Rows removed by the sweep')
        .toList();
    expect(labels, const [
      'Writes reversed',
      'Rows still held',
      'Files removed',
      'Rows removed by the sweep',
    ]);
  });

  testWidgets('tone is one lookup; an unknown tone stays neutral',
      (tester) async {
    await tester.pumpWidget(_host(_outcome()));
    final held = tester.widget<Text>(find.text('7'));
    expect(held.style?.color, Ds.c.danger);

    // 'aubergine' is not a tone this build knows. It must not throw and must
    // not be guessed at from the value — a red 0 is how a real red stops being
    // read.
    final files = tester.widget<Text>(find.text('0'));
    expect(files.style?.color, Ds.c.text);
  });

  testWidgets('has:false draws nothing at all', (tester) async {
    await tester.pumpWidget(_host(_outcome(has: false)));
    expect(find.text('Purge incomplete'), findsNothing);
    expect(find.text('Writes reversed'), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
    expect(TestPurgeOutcomeSheet.has(_outcome(has: false)), isFalse);
    expect(TestPurgeOutcomeSheet.has(null), isFalse);
    expect(TestPurgeOutcomeSheet.has(_outcome()), isTrue);
  });

  testWidgets('an absent verdict or close word is omitted, never dashed',
      (tester) async {
    await tester.pumpWidget(_host(_outcome(verdict: '', close: '')));
    expect(find.byKey(const ValueKey('test_purge_verdict')), findsNothing);
    expect(find.byKey(const ValueKey('test_purge_close')), findsNothing);
    expect(find.text('-'), findsNothing);
    expect(find.text('—'), findsNothing);
    // The rows it DID send are still there.
    expect(find.text('Writes reversed'), findsOneWidget);
  });

  testWidgets('an empty lines list is a sheet with no rows, not a crash',
      (tester) async {
    await tester.pumpWidget(_host(_outcome(lines: const [])));
    expect(find.text('Purge incomplete'), findsOneWidget);
    expect(find.text('Writes reversed'), findsNothing);
  });

  // ── 6. the banner is the door ──────────────────────────────────────────
  //
  // The sheet above is worthless if nothing opens it. `TestModeBanner` is
  // mounted over every route of every role, and its End & purge action is the
  // one entry point; these hold the wiring down.
  group('End & purge opens the verdict sheet', () {
    const live = <String, dynamic>{
      'on': true,
      'session_id': 31,
      'text': 'TEST MODE — nothing here is real',
      'badge': 'TEST',
      'can_end': true,
      'end_action': 'End & purge',
    };

    Widget banner(Future<Map<String, dynamic>> Function() run) => MaterialApp(
          home: Scaffold(
            body: TestModeBanner(payload: live, onEndPurge: run),
          ),
        );

    testWidgets('a reply carrying a verdict opens the sheet, not a snackbar',
        (tester) async {
      await tester.pumpWidget(banner(() async => {
            'ok': true,
            'done': true,
            'message': 'Test session ended and its rows purged.',
            'outcome': _outcome(),
          }));
      await tester.tap(find.byKey(const ValueKey('test_session_end_purge')));
      await tester.pumpAndSettle();

      // The backend's title, its row labels and its fingerprint sentence.
      expect(find.text('Purge incomplete'), findsOneWidget);
      expect(find.text('Writes reversed'), findsOneWidget);
      expect(
        find.text(
            'Purge incomplete — these tables still differ: notification_log'),
        findsOneWidget,
      );
      // The old one-line answer is NOT also shown: a sheet and a snackbar
      // saying different things about the same purge is the bug, not a bonus.
      expect(find.byType(SnackBar), findsNothing);
      expect(find.text('Test session ended and its rows purged.'), findsNothing);

      // The close word is the backend's, and it dismisses the sheet.
      await tester.tap(find.byKey(const ValueKey('test_purge_close')));
      await tester.pumpAndSettle();
      expect(find.text('Purge incomplete'), findsNothing);
    });

    testWidgets('a success verdict is shown in the backend\'s own words too',
        (tester) async {
      await tester.pumpWidget(banner(() async => {
            'ok': true,
            'done': true,
            'outcome': {
              'has': true,
              'title': 'Test session purged',
              'tone': 'success',
              'lines': const [
                {'label': 'Writes reversed', 'value': '41', 'tone': 'neutral'},
              ],
              'verdict':
                  'The database is byte-for-byte what it was before the session.',
              'verdict_tone': 'success',
              'close': 'Done',
            },
          }));
      await tester.tap(find.byKey(const ValueKey('test_session_end_purge')));
      await tester.pumpAndSettle();
      expect(find.text('Test session purged'), findsOneWidget);
      expect(
        find.text(
            'The database is byte-for-byte what it was before the session.'),
        findsOneWidget,
      );
      expect(find.text('41'), findsOneWidget);
    });

    testWidgets('no verdict — the backend\'s sentence still shows, as before',
        (tester) async {
      await tester.pumpWidget(banner(() async => {
            'ok': true,
            'done': true,
            'message': 'Test session ended and its rows purged.',
          }));
      await tester.tap(find.byKey(const ValueKey('test_session_end_purge')));
      await tester.pumpAndSettle();
      expect(find.text('Test session ended and its rows purged.'),
          findsOneWidget);
    });

    testWidgets('has:false is an absence of verdict, not an empty sheet',
        (tester) async {
      await tester.pumpWidget(banner(() async => {
            'ok': false,
            'error': 'not_owner',
            'message': 'Only the device that started this session can end it.',
            'outcome': const {'has': false},
          }));
      await tester.tap(find.byKey(const ValueKey('test_session_end_purge')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('test_purge_close')), findsNothing);
      expect(find.text('Only the device that started this session can end it.'),
          findsOneWidget);
    });
  });
}
