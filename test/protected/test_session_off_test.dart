import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/services/test_session.dart';
import 'package:pharma_b2b/widgets/test_mode_banner.dart';

/// CHANGE #1821 — OFF MEANS OFF, AND THE STRIP IS A PRINTER.
///
/// Om stopped test mode, closed the app, and five minutes later the red strip
/// was back — on his CUSTOMER login too. The cause was in the backend (the
/// post-deploy smoke opened a GLOBAL 12-hour session and `test_session_banner`
/// never looked at what kind of session it had found), and that half is held
/// down by the migration's own proofs. What this file holds down is the half
/// that lives in Dart, because it is the half that could quietly grow the bug
/// back: the strip must have NO memory and NO opinion.
///
///  * `on` is the only thing that decides whether it is drawn — never a
///    remembered flag, never a session id, never "we saw one earlier".
///  * every word is the payload's. The fixture's `text`, `badge` and `label`
///    deliberately disagree with each other and with anything a Dart default
///    would produce.
///  * `on: 'true'` (a string) is NOT on. A truthy-ish payload must not raise a
///    platform-wide alarm.
void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  Widget host(Widget child) => MaterialApp(
        home: Scaffold(body: TestModeBannerHost(child: child)),
      );

  const bodyKey = Key('body');
  const body = SizedBox(key: bodyKey, width: 10, height: 10);

  const onPayload = <String, dynamic>{
    'on': true,
    'badge': 'PROOFING',
    'text': 'THIS RUN IS NOT REAL',
    'label': 'Om walks the order flow',
    'ends_label': 'Auto-ends 07 Sep 01:33',
    'poll_ms': 20000,
    'session_id': 96,
  };

  testWidgets('on:false draws nothing at all', (t) async {
    TestSessionState.instance.debugSet(const {'on': false, 'poll_ms': 20000});
    await t.pumpWidget(host(body));
    expect(find.byKey(bodyKey), findsOneWidget);
    expect(find.byType(TestModeBanner), findsNothing);
  });

  testWidgets('an empty payload draws nothing — absence is not "on"',
      (t) async {
    TestSessionState.instance.debugSet(const {});
    await t.pumpWidget(host(body));
    expect(find.byType(TestModeBanner), findsNothing);
  });

  testWidgets('every word on the strip is the payload\'s', (t) async {
    TestSessionState.instance.debugSet(onPayload);
    await t.pumpWidget(host(body));
    expect(find.byType(TestModeBanner), findsOneWidget);
    expect(find.text('PROOFING'), findsOneWidget);
    expect(find.text('THIS RUN IS NOT REAL'), findsOneWidget);
    expect(
      find.text('Om walks the order flow  ·  Auto-ends 07 Sep 01:33'),
      findsOneWidget,
    );
    // Nothing a Dart default would have produced.
    expect(find.text('TEST'), findsNothing);
    expect(find.text('TEST MODE — nothing here is real'), findsNothing);
  });

  testWidgets('the strip has NO memory: on -> off clears it in place',
      (t) async {
    TestSessionState.instance.debugSet(onPayload);
    await t.pumpWidget(host(body));
    expect(find.byType(TestModeBanner), findsOneWidget);

    // This is Om closing the app and coming back: the SERVER says off, and the
    // only correct redraw is one with no strip in it.
    TestSessionState.instance.debugSet(const {'on': false, 'poll_ms': 20000});
    await t.pump();
    expect(find.byType(TestModeBanner), findsNothing);
    expect(find.byKey(bodyKey), findsOneWidget);
  });

  testWidgets('a strip with no words still renders and never throws',
      (t) async {
    TestSessionState.instance.debugSet(const {'on': true});
    await t.pumpWidget(host(body));
    expect(find.byType(TestModeBanner), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  test('isOn is the payload flag, not a truthy guess', () {
    final s = TestSessionState.instance;

    s.debugSet(const {'on': true});
    expect(s.isOn, isTrue);

    s.debugSet(const {'on': false});
    expect(s.isOn, isFalse);

    // A backend that ever sends a STRING must not raise a platform-wide alarm
    // by accident, and a session id on its own is not a live session.
    s.debugSet(const {'on': 'true'});
    expect(s.isOn, isFalse);
    s.debugSet(const {'session_id': 96});
    expect(s.isOn, isFalse);

    s.debugSet(const {'on': false});
  });
}
