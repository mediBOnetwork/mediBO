// PROTECTED — CMD #2015.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes order-alert SILENCE behaviour, never to make an
// unrelated change go green.
//
// What this holds down — the Android app rang a synthetic test alert
// endlessly and the only escape was uninstalling it. Four causes, four rules:
//
//   1. THE RING IS NEVER AN ALARM. `OrderAlert.kt` must not ask Android for
//      USAGE_ALARM, must not setBypassDnd(true), must not loop the player and
//      must not raise a full-screen intent — each of those deliberately
//      bypasses silent mode, vibrate mode, Do Not Disturb or the volume keys,
//      which is exactly what made the ring unstoppable. The manifest must not
//      carry USE_FULL_SCREEN_INTENT either: a permission that is not held
//      cannot be used by accident later.
//
//   2. THE SOUND IS GATED AND BOUNDED. The player checks the ringer mode, the
//      ring-stream volume and the interruption filter before a note, listens
//      for a volume-key / ringer-mode change while it plays, and is never
//      looped. A note that cannot be stopped is the bug.
//
//   3. THE SERVER IS THE ONLY AUTHORITY ON WHAT EXISTS. The app asks
//      `order_alert_reconcile` on start and on every foreground and hands the
//      list to Android verbatim. Nothing in Dart raises, re-raises or re-rings
//      an alert on its own.
//
//   4. STOP IS THE BACKEND'S WORD, ON ITS OWN ROW. The card draws a Stop
//      action only when the payload sent the word, prints it verbatim, and
//      gives it a full-width 44 px row — at 360 px a third button beside
//      Reject and Accept squeezes all three below a readable width.
//
// No network, no Supabase, no camera: the widget half renders an inline
// payload and the source half reads the two files the policy lives in.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/order_alerts_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _item() => {
      'alert_id': 42,
      'order_id': 'ord-1',
      'order_code': 'CPO1409',
      'customer': 'Om Medicals',
      'amount_display': '₹2,337.30',
      'stage_label': 'New',
      'age_label': '2m ago',
      'accept_label': 'Accept',
      'reject_label': 'Reject',
      'accept_note': 'Open the order to see the items.',
      'can_accept': true,
      'can_reject': true,
      'paid': false,
      'critical': false,
      'credit_blocked': false,
    };

Future<void> _pump(WidgetTester tester, Widget child, {double width = 360}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: SingleChildScrollView(child: child)),
  ));
  await tester.pump();
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('Stop is the backend\'s word, on its own row', () {
    testWidgets('no stop_label — no Stop action at all', (tester) async {
      await _pump(tester, OrderAlertCard(item: _item()));
      expect(find.text('Stop'), findsNothing);
    });

    testWidgets('the payload\'s word is printed verbatim, never "Stop"',
        (tester) async {
      var tapped = 0;
      await _pump(
        tester,
        OrderAlertCard(
          item: _item(),
          stopLabel: 'Chup karo',
          onStop: () => tapped++,
        ),
      );
      // Verbatim: a Dart literal would have printed "Stop" here.
      expect(find.text('Chup karo'), findsOneWidget);
      expect(find.text('Stop'), findsNothing);
      await tester.tap(find.text('Chup karo'));
      await tester.pump();
      expect(tapped, 1);
    });

    testWidgets('Stop keeps a 44px target at 360px and does not crowd the row',
        (tester) async {
      await _pump(
        tester,
        OrderAlertCard(item: _item(), stopLabel: 'Stop', onStop: () {}),
      );
      final box = tester.getRect(find.text('Stop'));
      final accept = tester.getRect(find.text('Accept'));
      final reject = tester.getRect(find.text('Reject'));
      // Its own row: below both of the decision buttons, never beside them.
      expect(box.top, greaterThan(accept.bottom));
      expect(box.top, greaterThan(reject.bottom));
      final button = tester.getSize(
        find.ancestor(of: find.text('Stop'), matching: find.byType(TextButton)),
      );
      expect(button.height, greaterThanOrEqualTo(44.0));
    });

    testWidgets('a busy card cannot fire Stop twice', (tester) async {
      var tapped = 0;
      await _pump(
        tester,
        OrderAlertCard(
          item: _item(),
          busy: true,
          stopLabel: 'Stop',
          onStop: () => tapped++,
        ),
      );
      await tester.tap(find.text('Stop'));
      await tester.pump();
      expect(tapped, 0);
    });
  });

  group('the ring is never an alarm', () {
    final kt = File('android/app/src/main/kotlin/in/medibo/app/OrderAlert.kt');
    final manifest = File('android/app/src/main/AndroidManifest.xml');

    test('OrderAlert.kt asks for no alarm, no DND bypass, no loop, no takeover',
        () {
      final src = kt.readAsStringSync();
      expect(src.contains('USAGE_ALARM'), isFalse,
          reason: 'USAGE_ALARM plays on STREAM_ALARM, which silent mode, '
              'vibrate mode and the volume keys do not touch.');
      expect(src.contains('setBypassDnd(true)'), isFalse,
          reason: 'Do Not Disturb must silence an order alert.');
      expect(src.contains('isLooping = true'), isFalse,
          reason: 'A looped note is a ring with no end.');
      expect(src.contains('setFullScreenIntent'), isFalse,
          reason: 'A full-screen takeover is the alarm/calling treatment.');
      expect(src.contains('RingtoneManager.TYPE_ALARM'), isFalse,
          reason: 'The alarm ringtone is not this app to play.');
    });

    test('the sound is gated on the ringer, the volume and DND', () {
      final src = kt.readAsStringSync();
      expect(src.contains('RINGER_MODE_NORMAL'), isTrue);
      expect(src.contains('STREAM_RING'), isTrue);
      expect(src.contains('currentInterruptionFilter'), isTrue);
      expect(src.contains('USAGE_NOTIFICATION_RINGTONE'), isTrue);
      // A volume key press and a ringer flip both stop a note mid-play.
      expect(src.contains('RINGER_MODE_CHANGED_ACTION'), isTrue);
      expect(src.contains('android.media.VOLUME_CHANGED_ACTION'), isTrue);
    });

    test('the channel id moved — an old channel cannot be un-bypassed', () {
      final src = kt.readAsStringSync();
      expect(src.contains('medibo_order_alert_v2'), isTrue);
      expect(src.contains('deleteNotificationChannel'), isTrue,
          reason: 'The alarm-usage channel from CHANGE #306 must be removed '
              'from phones that already have it.');
    });

    test('a synthetic alert is refused on the device too', () {
      final src = kt.readAsStringSync();
      expect(src.contains('is_synthetic'), isTrue,
          reason: 'The alert that could not be dismissed named a row the '
              'phone could not see.');
    });

    test('the manifest holds no full-screen-intent permission', () {
      expect(manifest.readAsStringSync().contains('USE_FULL_SCREEN_INTENT'),
          isFalse);
    });
  });

  group('the server is the only authority', () {
    final svc = File('lib/services/order_alert_service.dart');

    test('reconcile runs on start and on every foreground', () {
      final src = svc.readAsStringSync();
      expect(src.contains("_db.rpc('order_alert_reconcile')"), isTrue);
      expect(src.contains('didChangeAppLifecycleState'), isTrue);
      expect(src.contains('AppLifecycleState.resumed'), isTrue);
      expect(src.contains("invokeMethod('reconcile'"), isTrue);
    });

    test('Dart stops alerts through the backend, never on its own', () {
      final src = svc.readAsStringSync();
      expect(src.contains("_db.rpc('order_alert_stop'"), isTrue);
      // The ids handed to Android are the payload's, unfiltered.
      expect(src.contains("reconcileState?['live_ids']"), isTrue);
    });
  });
}
