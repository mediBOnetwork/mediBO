// PROTECTED — CHANGE #1802.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes Android-release behaviour, never to make an unrelated
// change go green.
//
// What this holds down. #1801 was told to build the AAB and publish it to
// Play. It closed 8/8 green as "backend only, nothing to deploy" while
// `targets_android` was true and android_status / android_artifact_url /
// android_built_at were all still at their defaults. The backend now refuses
// that completion; this card is the surface that shows the refusal, and it is
// a PRINTER:
//
//   1. Every word is `dev_cmd_get(id).row.android`'s — title, status label,
//      sub-line, link label and the blocker sentence. The fixture deliberately
//      pairs a status of 'published' with the LABEL 'Shipped, allegedly' and a
//      tone of 'warning', so a card that re-derived either from the status
//      string fails here.
//
//   2. The blocker is the SAME sentence dev_cmd_complete raises with. It is
//      printed whole; the screen never shortens it, never substitutes its own
//      wording, and never renders a friendly placeholder when it is empty.
//
//   3. `has: false` — a command that never asked for an Android release —
//      draws nothing at all. Not an empty card, not a grey "not built" chip.
//      That is what keeps this block free on the 700-odd rows that will never
//      ship an APK.
//
//   4. Absence is omission, not a dash. No sub-line, no artifact URL and no
//      link label each remove their row rather than printing an empty one; a
//      URL without its label is not a tappable mystery.
//
//   5. A tone the build has never heard of stays neutral rather than being
//      guessed at from the status — the same rule every other dev-queue tone
//      lookup follows.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/dev_queue_android.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/dev_queue_common.dart';

const _blocker =
    'An Android release was asked for and never built — android_status is '
    'still not_requested. Build and publish it, record it with '
    'dev_cmd_android_record, or drop it on the record with '
    'dev_cmd_android_skip.';

Map<String, dynamic> _row({
  bool has = true,
  String status = 'published',
  String label = 'Shipped, allegedly',
  String tone = 'warning',
  String sub = '1.3.24 (38) · 06 Sep 2026, 01:41 AM IST',
  String url = 'https://example.test/medibo-1.3.24.apk',
  String urlLabel = 'Download the APK',
  String blocker = '',
}) =>
    {
      'id': 1802,
      'status': 'building',
      'android': {
        'has': has,
        'title': 'Android release',
        'status': status,
        'label': label,
        'tone': tone,
        'sub': sub,
        'url': url,
        'url_label': urlLabel,
        'blocker': blocker,
      },
    };

Future<void> _pump(WidgetTester tester, Map<String, dynamic> row,
        {void Function(String)? onOpen}) =>
    tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: AndroidReleaseCard(row: row, onOpen: onOpen),
        ),
      ),
    ));

void main() {
  // The card calls RenderLog.write; its 800 ms debounce is a real Timer that
  // would outlive the test and try to reach Supabase.
  setUpAll(() => RenderLog.flushEnabled = false);

  testWidgets('every word is the payload\'s, even when it disagrees with the status',
      (tester) async {
    await _pump(tester, _row());

    expect(find.text('Android release'), findsOneWidget);
    // The status is 'published'; the LABEL is the backend's own wording and is
    // what appears. Nothing here maps a status enum to a Dart string.
    expect(find.text('Shipped, allegedly'), findsOneWidget);
    expect(find.text('Published to Play'), findsNothing);
    expect(find.text('1.3.24 (38) · 06 Sep 2026, 01:41 AM IST'), findsOneWidget);
    expect(find.text('Download the APK'), findsOneWidget);
  });

  testWidgets('the blocker prints whole — it is the gate\'s own sentence',
      (tester) async {
    await _pump(tester, _row(status: 'not_requested', label: 'Not built', blocker: _blocker));

    expect(find.text(_blocker), findsOneWidget);
    expect(AndroidRelease.fromRow(_row(blocker: _blocker)).blocked, isTrue);
  });

  testWidgets('a clear gate prints no blocker box at all', (tester) async {
    await _pump(tester, _row());
    expect(find.byIcon(Icons.block), findsNothing);
    expect(AndroidRelease.fromRow(_row()).blocked, isFalse);
  });

  testWidgets('has:false draws nothing at all', (tester) async {
    await _pump(tester, _row(has: false));
    expect(find.text('Android release'), findsNothing);
    expect(find.byType(ToneChip), findsNothing);
    expect(find.byIcon(Icons.android), findsNothing);
  });

  testWidgets('a row with no android block at all is the same as has:false',
      (tester) async {
    await _pump(tester, {'id': 1799, 'status': 'completed'});
    expect(find.byType(ToneChip), findsNothing);
    expect(AndroidRelease.fromRow(const {'id': 1}).has, isFalse);
  });

  testWidgets('an absent sub-line is omitted, never dashed', (tester) async {
    await _pump(tester, _row(sub: ''));
    expect(find.text('—'), findsNothing);
    expect(find.text('-'), findsNothing);
    expect(find.text('Android release'), findsOneWidget);
  });

  testWidgets('a URL without its label is not offered', (tester) async {
    await _pump(tester, _row(urlLabel: ''));
    expect(find.byIcon(Icons.download), findsNothing);
  });

  testWidgets('an absent URL removes the link row', (tester) async {
    await _pump(tester, _row(url: ''));
    expect(find.text('Download the APK'), findsNothing);
    expect(find.byIcon(Icons.download), findsNothing);
  });

  testWidgets('the link hands the backend\'s url back, exactly once',
      (tester) async {
    final opened = <String>[];
    await _pump(tester, _row(), onOpen: opened.add);
    await tester.tap(find.text('Download the APK'));
    await tester.pump();
    expect(opened, ['https://example.test/medibo-1.3.24.apk']);
  });

  test('an unknown tone stays neutral rather than being guessed', () {
    // 'chartreuse' is not a tone this build knows; it must not fall through to
    // success just because the status says published.
    expect(toneByName('chartreuse'), toneByName('neutral'));
    expect(toneByName('chartreuse') == toneByName('success'), isFalse);
  });

  test('androidTone knows the two terminal states the gate added', () {
    // Before #1802 both fell to default, so a shipped release wore the same
    // grey as one that was never built.
    expect(androidTone('published'), androidTone('built'));
    expect(androidTone('skipped') == androidTone('built'), isFalse);
  });
}
