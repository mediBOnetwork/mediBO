// PROTECTED — CMD #2076.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes the Firebase Test Lab gate, never to make an unrelated
// change go green.
//
// What this holds down. The web build never compiles or runs the Kotlin
// plugins, so an Android release is gated on one Firebase Test Lab matrix and
// the verdict is shown on the Dev Queue row. The screen is a PRINTER of
// `dev_cmd_get(id).testlab` and of the row's `testlab_chip` / `testlab_tone`:
//
//   1. Every word is the backend's — title, status label, device line,
//      detail, the per-check labels and their ok/failed words, the proof
//      labels, the console link label. The fixture pairs status 'passed'
//      with the LABEL 'Green, allegedly' and tone 'warning', so a card that
//      re-derived either from the status string fails here.
//
//   2. `has: false` draws nothing at all — not an empty card, not a grey
//      "not run" chip. That keeps the block free on every command that never
//      ships an APK (the spec: web-only commands skip this entirely).
//
//   3. Absence is omission: no checks → no checks section; no proofs → no
//      evidence section; a console URL without its label is not a tappable
//      mystery.
//
//   4. A proof is a private-bucket object. Tapping one asks the SCREEN's
//      signer for (bucket, path) and opens exactly the URL it answered — the
//      card never builds a storage URL of its own.
//
//   5. The row chip is the backend's string, '' when the command has no
//      verdict; a tone the build has never heard of stays neutral.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/dev_queue_android.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/dev_queue_common.dart';

Map<String, dynamic> _block({
  bool has = true,
  String status = 'passed',
  String label = 'Green, allegedly',
  String tone = 'warning',
  String sub = 'MediumPhone.arm API 33 · 4m 12s · 18 Sep 2026, 11:40 PM IST',
  String detail = 'Passed on MediumPhone.arm API 33 in 4m 12s · 3 check(s) green',
  String url = 'https://console.firebase.google.com/project/medibo-23aee/testlab/histories/h/matrices/m',
  String urlLabel = 'Open the matrix in the Firebase console',
  List<Map<String, dynamic>>? checks,
  List<Map<String, dynamic>>? proofs,
}) =>
    {
      'has': has,
      'status': status,
      'title': 'Firebase Test Lab',
      'label': label,
      'tone': tone,
      'sub': sub,
      'detail': detail,
      'url': url,
      'url_label': urlLabel,
      'checks_title': 'Checks derived from the spec',
      'checks': checks ??
          [
            {'key': 'boot_first_frame', 'label': 'App boots and paints its first frame', 'ok': true, 'status': 'ok', 'tone': 'success', 'detail': 'Scaffold painted'},
            {'key': 'channel_play_update', 'label': 'Play in-app update plugin answers', 'ok': false, 'status': 'failed', 'tone': 'danger', 'detail': 'no handler for in.medibo.app/play_update.available'},
            {'key': 'fcm_token', 'label': 'Firebase Messaging issues a device token', 'ok': null, 'status': 'pending', 'tone': 'neutral', 'detail': ''},
          ],
      'proofs_title': 'Evidence from the device',
      'proofs': proofs ??
          [
            {'kind': 'video', 'label': 'Video of the run', 'path': '2076/testlab/7/video.mp4', 'bucket': 'dev-cmd-proofs'},
            {'kind': 'logcat', 'label': 'Logcat', 'path': '2076/testlab/7/logcat.txt', 'bucket': 'dev-cmd-proofs'},
          ],
    };

Widget _host(Widget child) => MaterialApp(
    home: Scaffold(body: SingleChildScrollView(child: child)));

void main() {
  setUpAll(() {
    RenderLog.flushEnabled = false;
  });

  testWidgets('prints every word of the block verbatim, never re-deriving from status', (tester) async {
    await tester.pumpWidget(_host(TestLabCard(row: {'testlab': _block()})));
    await tester.pump();

    expect(find.text('Firebase Test Lab'), findsOneWidget);
    expect(find.text('Green, allegedly'), findsOneWidget);
    expect(find.text('Test Lab passed'), findsNothing, reason: 'the label is the payload\'s, not a status map');
    expect(find.text('MediumPhone.arm API 33 · 4m 12s · 18 Sep 2026, 11:40 PM IST'), findsOneWidget);
    expect(find.text('Passed on MediumPhone.arm API 33 in 4m 12s · 3 check(s) green'), findsOneWidget);
    expect(find.text('Checks derived from the spec'), findsOneWidget);
    expect(find.text('App boots and paints its first frame'), findsOneWidget);
    expect(find.text('Play in-app update plugin answers'), findsOneWidget);
    expect(find.text('no handler for in.medibo.app/play_update.available'), findsOneWidget);
    expect(find.text('ok'), findsOneWidget);
    expect(find.text('failed'), findsOneWidget);
    expect(find.text('pending'), findsOneWidget);
    expect(find.text('Evidence from the device'), findsOneWidget);
    expect(find.text('Video of the run'), findsOneWidget);
    expect(find.text('Logcat'), findsOneWidget);
    expect(find.text('Open the matrix in the Firebase console'), findsOneWidget);

    // The chip carries the payload's tone, not one guessed from 'passed'.
    final chip = tester.widget<ToneChip>(find.widgetWithText(ToneChip, 'Green, allegedly'));
    expect(chip.tone, same(toneByName('warning')));
  });

  testWidgets('has:false draws nothing at all', (tester) async {
    await tester.pumpWidget(_host(TestLabCard(row: {'testlab': _block(has: false)})));
    await tester.pump();
    expect(find.byType(DqCard), findsNothing);
    expect(find.text('Firebase Test Lab'), findsNothing);

    await tester.pumpWidget(_host(const TestLabCard(row: {})));
    await tester.pump();
    expect(find.byType(DqCard), findsNothing);
  });

  testWidgets('absence is omission: no checks, no proofs, no unlabeled link', (tester) async {
    await tester.pumpWidget(_host(TestLabCard(
        row: {'testlab': _block(checks: const [], proofs: const [], urlLabel: '')})));
    await tester.pump();
    expect(find.text('Checks derived from the spec'), findsNothing);
    expect(find.text('Evidence from the device'), findsNothing);
    expect(find.byIcon(Icons.open_in_new), findsNothing);
    expect(find.text('Green, allegedly'), findsOneWidget);
  });

  testWidgets('a proof opens exactly the URL the signer answered for (bucket, path)', (tester) async {
    final asked = <String>[];
    final opened = <String>[];
    await tester.pumpWidget(_host(TestLabCard(
      row: {'testlab': _block()},
      onOpen: opened.add,
      signer: (bucket, path) async {
        asked.add('$bucket:$path');
        return 'https://signed.example/$path?token=abc';
      },
    )));
    await tester.pump();
    await tester.tap(find.text('Logcat'));
    await tester.pump();
    expect(asked, ['dev-cmd-proofs:2076/testlab/7/logcat.txt']);
    expect(opened, ['https://signed.example/2076/testlab/7/logcat.txt?token=abc']);

    await tester.tap(find.text('Open the matrix in the Firebase console'));
    await tester.pump();
    expect(opened.last,
        'https://console.firebase.google.com/project/medibo-23aee/testlab/histories/h/matrices/m');
  });

  test('the row chip is the backend string; absent is empty; unknown tone is neutral', () {
    expect(testLabChipOf({'id': 1}), '');
    expect(testLabChipOf({'testlab_chip': '🧪 Test Lab passed'}), '🧪 Test Lab passed');
    expect(testLabToneOf({'id': 1}), 'neutral');
    expect(toneByName(testLabToneOf({'testlab_tone': 'plaid'})), same(toneByName('neutral')));
    expect(toneByName(testLabToneOf({'testlab_tone': 'danger'})), same(toneByName('error')));
  });

  testWidgets('an unknown tone in the block stays neutral, never guessed from status', (tester) async {
    await tester.pumpWidget(_host(TestLabCard(row: {'testlab': _block(status: 'failed', tone: 'plaid')})));
    await tester.pump();
    final chip = tester.widget<ToneChip>(find.widgetWithText(ToneChip, 'Green, allegedly'));
    expect(chip.tone, same(toneByName('neutral')));
  });
}
