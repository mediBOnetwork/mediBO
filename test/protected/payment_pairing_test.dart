// PROTECTED — CMD #2067. The pairing contract on a REAL phone.
//
// The failure this holds down happened on Om's handset, not in a fixture:
// notification access was granted, Android's own settings screen said ON, the
// Devices card still said "Not paired", and two ₹1 UPI credits were never
// heard. Nothing was wrong with the parser. The section that owns the
// "Turn on notification access" button only ever READ the registry — it never
// started the listener service, so the backend's package allow-list was never
// handed to Android (every notification dropped on the phone) and
// payment_alert_device_register() was never called (no row, so "Not paired"
// forever).
//
// What must never regress:
//   * "Paired" is not a status the app composes. Pairing, listening and the
//     bind are three separate backend facts and the card prints the sentence
//     the BACKEND built out of them — "Paired · Listening on" included.
//   * A phone whose listener is granted but NOT bound is not shown as healthy:
//     the row carries a second chip, and the pairing card offers the backend's
//     own restart button. Both exist only because the payload sent them.
//   * The section renders every device string verbatim and in payload order.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/payment_devices_section.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _row({
  required String id,
  required String label,
  bool isThis = false,
  bool listener = true,
  String boundState = 'Running',
  String boundTone = 'success',
}) => {
      'device_id': id,
      'is_this_device': isThis,
      'label': label,
      'this_label': 'This phone',
      'status_label': listener ? 'On' : 'Off',
      'status_tone': listener ? 'success' : 'warning',
      'listener_label': 'Listening',
      'listener_on': listener,
      'listener_editable': isThis,
      'listener_note': isThis ? '' : 'Only this phone can switch listening on.',
      'bound_label': 'Listener',
      'bound': boundState == 'Running',
      'bound_state': boundState,
      'bound_tone': boundTone,
      'speak_editable': true,
      'volume_editable': true,
      'speak_label': 'Speak the amount',
      'speak_on': true,
      'speak_state': 'On',
      'volume': 100,
      'volume_label': 'Volume',
      'last_seen': 'Last seen 17 Sep, 01:18 am',
      'last_alert': 'No payment heard yet',
      'today_label': 'Nothing heard on 17 Sep',
      'version_label': 'App 1.3.30 (51)',
      'zone_id': 1,
    };

Map<String, dynamic> _payload({
  required String statusLabel,
  required String statusTone,
  required String statusSub,
  String rebindLabel = '',
  bool paired = true,
  bool listening = true,
  bool bound = true,
  List<Map<String, dynamic>>? rows,
}) => {
      'ok': true,
      'title': 'Devices',
      'count_label': '1 phone paired',
      'count': 1,
      'can_edit': true,
      'is_native': true,
      'note': '',
      'empty_label': 'No phone is listening yet',
      'empty_hint': 'Open mediBO on the shop phone and turn on notification access.',
      'pairing': {
        'title': 'This phone',
        'paired': paired,
        'listening': listening,
        'bound': bound,
        'status_label': statusLabel,
        'status_tone': statusTone,
        'status_sub': statusSub,
        'cta_label': 'Manage notification access',
        'rebind_label': rebindLabel,
        'can_open_settings': true,
      },
      'rows': rows ?? [_row(id: 'zeta', label: 'realme RMX3771', isThis: true)],
      'zone_id': 1,
      'date': '2026-09-17',
    };

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  Future<void> pump(
    WidgetTester t,
    Map<String, dynamic> payload, {
    double width = 360,
  }) async {
    t.view.physicalSize = Size(width, 900);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: PaymentDevicesSection(
            deviceId: 'zeta',
            platform: 'android',
            rpc: (fn, args) async => payload,
          ),
        ),
      ),
    ));
    await t.pumpAndSettle();
  }

  testWidgets('a paired, listening phone prints the BACKEND sentence', (t) async {
    await pump(
      t,
      _payload(
        statusLabel: 'Paired · Listening on',
        statusTone: 'success',
        statusSub: 'This phone is paired and its notification listener is running.',
      ),
    );

    // The one thing the 17 Sep phone could not say.
    expect(find.text('Paired · Listening on'), findsOneWidget);
    expect(
      find.text('This phone is paired and its notification listener is running.'),
      findsOneWidget,
    );
    // Nothing the app invented: "Paired" alone is not a caption this file owns.
    expect(find.text('Paired'), findsNothing);
    // The restart button exists only when the backend sent its label.
    expect(find.byKey(const Key('c2067_rebind_cta')), findsNothing);
  });

  testWidgets('granted but never bound is NOT shown as healthy', (t) async {
    await pump(
      t,
      _payload(
        statusLabel: 'Paired · Listening off',
        statusTone: 'warning',
        statusSub: 'Notification access is on but the listener has not started yet.',
        rebindLabel: 'Restart the listener',
        bound: false,
        rows: [
          _row(
            id: 'zeta',
            label: 'realme RMX3771',
            isThis: true,
            boundState: 'Not running',
            boundTone: 'warning',
          ),
        ],
      ),
    );

    expect(find.text('Paired · Listening off'), findsOneWidget);
    // The second chip: the permission says On, the SERVICE says Not running.
    expect(find.text('On'), findsWidgets);
    expect(find.text('Not running'), findsOneWidget);
    // The backend's own restart button, worded by the backend.
    final cta = find.byKey(const Key('c2067_rebind_cta'));
    expect(cta, findsOneWidget);
    expect(find.text('Restart the listener'), findsOneWidget);
    // Touch target: a phone-first screen never ships a 30px button.
    expect(t.getSize(cta).height, greaterThanOrEqualTo(44));
  });

  testWidgets('no bound_state in the payload draws no bound chip', (t) async {
    final row = _row(id: 'zeta', label: 'realme RMX3771', isThis: true)
      ..remove('bound_state')
      ..remove('bound_tone');
    await pump(
      t,
      _payload(
        statusLabel: 'Paired · Listening on',
        statusTone: 'success',
        statusSub: 'Running.',
        rows: [row],
      ),
    );
    expect(find.text('Running'), findsNothing);
    expect(find.text('Not running'), findsNothing);
  });

  testWidgets('rows print in payload order at 412px too', (t) async {
    await pump(
      t,
      _payload(
        statusLabel: 'Paired · Listening on',
        statusTone: 'success',
        statusSub: 'Running.',
        rows: [
          _row(id: 'zeta', label: 'Zed counter phone', isThis: true),
          _row(id: 'alpha', label: 'Alpha back office', listener: false,
              boundState: 'Not running', boundTone: 'warning'),
        ],
      ),
      width: 412,
    );
    final zed = t.getTopLeft(find.text('Zed counter phone')).dy;
    final alpha = t.getTopLeft(find.text('Alpha back office')).dy;
    expect(zed, lessThan(alpha));
    // Verbatim, never re-formatted here.
    expect(find.text('Last seen 17 Sep, 01:18 am'), findsWidgets);
    expect(find.text('Nothing heard on 17 Sep'), findsWidgets);
    expect(find.text('App 1.3.30 (51)'), findsWidgets);
  });
}
