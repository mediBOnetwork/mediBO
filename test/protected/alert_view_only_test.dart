// CMD #2154 — every staff alert popup has ONE button: View.
//
// Holds down: the sign-up alert card (pharmacy, supplier, MR, company,
// delivery partner) draws exactly one button whose label is the backend's
// view.label; there is no Approve / Reject / Skip / Dismiss on it; View reports
// view and Mute reports mute (mute never leaves the alert); every line is the
// payload's `card` verbatim; and the new-order popup draws no second button
// when the backend sends an empty secondary_label.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/design_tokens.dart';
import 'package:pharma_b2b/screens/admin/admin_alert_card.dart';
import 'package:pharma_b2b/screens/admin/order_alert_popup.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _card({String name = 'Om Medicals'}) => {
      'title': 'NEW REGISTRATION',
      'name': name,
      'subtitle': 'Om Prakash',
      'detail': '9876543210  ·  Raipur, Chhattisgarh',
    };

const _view = {
  'label': 'View',
  'route': 'customers',
  'params': {'id': 'pp-2154'},
};

Future<void> _pump(WidgetTester tester, Widget child, {double width = 360}) async {
  tester.view.physicalSize = Size(width, 780);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: child))));
  await tester.pump();
}

Widget _alert({VoidCallback? onView, VoidCallback? onMute, String name = 'Om Medicals'}) =>
    AdminAlertCard(
      heading: 'NEW REGISTRATION',
      card: _card(name: name),
      view: _view,
      muted: false,
      onView: onView ?? () {},
      onMute: onMute ?? () {},
    );

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  testWidgets('one button, labelled by the backend', (tester) async {
    await _pump(tester, _alert());
    expect(find.byType(FilledButton), findsOneWidget);
    expect(find.byType(OutlinedButton), findsNothing);
    expect(find.byType(TextButton), findsNothing);
    expect(find.text('View'), findsOneWidget);
    for (final gone in const ['Approve', 'Reject', 'Skip', 'Dismiss']) {
      expect(find.text(gone), findsNothing);
    }
  });

  testWidgets('every line is the payload, verbatim', (tester) async {
    await _pump(tester, _alert());
    for (final s in const [
      'NEW REGISTRATION',
      'Om Medicals',
      'Om Prakash',
      '9876543210  ·  Raipur, Chhattisgarh',
    ]) {
      expect(find.text(s), findsOneWidget);
    }
  });

  testWidgets('View reports view; mute reports mute and nothing else',
      (tester) async {
    var views = 0, mutes = 0;
    await _pump(tester, _alert(onView: () => views++, onMute: () => mutes++));
    await tester.tap(find.byIcon(Icons.volume_up_outlined));
    expect((views, mutes), (0, 1));
    await tester.tap(find.text('View'));
    expect((views, mutes), (1, 1));
  });

  testWidgets('no view label from the backend draws no button', (tester) async {
    await _pump(
        tester,
        AdminAlertCard(
          heading: 'NEW REGISTRATION',
          card: _card(),
          view: const {},
          muted: false,
          onView: () {},
          onMute: () {},
        ));
    expect(find.byType(FilledButton), findsNothing);
  });

  for (final w in const [320.0, 360.0, 412.0, 480.0]) {
    testWidgets('fits a ${w.toInt()}px phone, View >= 44px', (tester) async {
      await _pump(
          tester,
          _alert(name: 'Sri Venkateswara Medical & General Stores, Kukatpally Hyderabad'),
          width: w);
      expect(tester.takeException(), isNull);
      final btn = tester.getRect(find.byType(FilledButton));
      expect(btn.height, greaterThanOrEqualTo(Ds.touch.minTarget));
    });
  }

  testWidgets('order popup: empty secondary_label draws View only',
      (tester) async {
    var opened = 0;
    await _pump(
        tester,
        OrderAlertPopup(
          popup: const {
            'ok': true,
            'show': true,
            'order_id': 'ord-2154',
            'title': 'New order',
            'customer_name': 'Om Medicals',
            'amount_display': '₹1,200.00',
            'primary_label': 'View',
            'secondary_label': '',
          },
          onOpen: () => opened++,
          onLater: () {},
        ));
    expect(find.byType(FilledButton), findsOneWidget);
    expect(find.byType(OutlinedButton), findsNothing);
    await tester.tap(find.text('View'));
    expect(opened, 1);
  });
}
