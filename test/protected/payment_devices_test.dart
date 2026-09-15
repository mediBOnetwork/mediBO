// PROTECTED — CMD #2050. The Devices section on the Payment alerts screen.
//
// The feature this section exists to fix was invisible: payment_alert_device
// had zero rows on live and no screen could pair a phone. What must never
// regress is that the section DECIDES NOTHING —
//
//   * the pairing state, its chip caption and its tone are the payload's;
//   * the section is FULLY live on the web — a paired phone's speak switch and
//     volume are editable from a laptop — and the ONE device-local control,
//     listening, is inert off-device because the payload said listener_editable
//     is false, never because Dart looked at kIsWeb;
//   * a toggle sends the backend's own field names for exactly the ONE thing
//     that changed, and nothing else;
//   * rows are printed in payload order (the fixture is deliberately not
//     alphabetical), and every label — last seen, last payment, the date-scoped
//     "heard on" line — is printed verbatim, never composed here.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/payment_devices_section.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _device({
  required String id,
  required String label,
  bool isThis = false,
  bool listener = true,
  bool speak = true,
  int volume = 100,
  bool listenerEditable = true,
}) => {
      'device_id': id,
      'is_this_device': isThis,
      'label': label,
      'this_label': 'This phone',
      'status_label': listener ? 'On' : 'Off',
      'status_tone': listener ? 'success' : 'warning',
      'listener_label': 'Listening',
      'listener_on': listener,
      'listener_editable': listenerEditable,
      'listener_note': listenerEditable
          ? ''
          : 'Only this phone can switch listening on — it is an Android permission.',
      'speak_editable': true,
      'volume_editable': true,
      'speak_label': 'Speak the amount',
      'speak_on': speak,
      'speak_state': speak ? 'On' : 'Muted',
      'volume': volume,
      'volume_label': 'Volume',
      'last_seen': 'Last seen 15 Sep, 09:40 pm',
      'last_alert': 'No payment heard yet',
      'today_label': '2 heard on 15 Sep',
      'version_label': 'App 1.3.28',
      'zone_id': 1,
    };

Map<String, dynamic> _payload({
  bool native = true,
  bool paired = true,
  List<Map<String, dynamic>>? rows,
}) => {
      'ok': true,
      'title': 'Devices',
      'subtitle': 'The phones that listen for payments in this zone.',
      'count_label': '2 phones paired',
      'count': 2,
      'can_edit': true,
      'is_native': native,
      'note': native
          ? ''
          : 'Listening is switched on from the phone itself. Everything else here can be changed from any device.',
      'empty_label': 'No phone is listening yet',
      'empty_hint':
          'Open mediBO on the shop phone and turn on notification access — it pairs itself.',
      'pairing': {
        'title': native ? 'This phone' : 'Pairing a phone',
        'paired': paired,
        'status_label': !native ? '' : (paired ? 'Paired' : 'Not paired'),
        'status_tone': paired ? 'success' : 'warning',
        'status_sub': !native
            ? 'Open mediBO on the shop phone to pair it and turn on notification access.'
            : (paired
                ? 'This phone is registered and listening for payments.'
                : 'Turn on notification access to pair this phone.'),
        'cta_label': !native
            ? ''
            : (paired
                ? 'Manage notification access'
                : 'Turn on notification access'),
        'can_open_settings': native,
      },
      'rows': rows ??
          [
            _device(id: 'zeta', label: 'Zeta counter phone', isThis: true),
            _device(id: 'alpha', label: 'Alpha back office', listener: false,
                speak: false, volume: 40),
          ],
      'zone_id': 1,
      'date': '2026-09-15',
    };

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  Future<void> phone(WidgetTester t, [double w = 360]) async {
    t.view.physicalSize = Size(w, 780);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
  }

  Future<void> pump(
    WidgetTester t,
    Map<String, dynamic> payload, {
    List<List<Object?>>? calls,
    double width = 360,
    String platform = 'android',
  }) async {
    await phone(t, width);
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: PaymentDevicesSection(
            deviceId: 'zeta',
            platform: platform,
            rpc: (fn, args) async {
              calls?.add([fn, args]);
              return fn == 'payment_alert_device_set'
                  ? {'ok': true, 'device_id': args['p_device'], 'toast': 'Saved.'}
                  : payload;
            },
          ),
        ),
      ),
    ));
    await t.pumpAndSettle();
  }

  testWidgets('the section prints the backend payload verbatim', (t) async {
    await pump(t, _payload());

    expect(find.text('Devices'), findsOneWidget);
    expect(find.text('2 phones paired'), findsOneWidget);
    expect(find.text('Paired'), findsOneWidget);
    expect(find.text('This phone is registered and listening for payments.'),
        findsOneWidget);
    expect(find.text('Manage notification access'), findsOneWidget);
    expect(find.text('Zeta counter phone'), findsOneWidget);
    expect(find.text('Alpha back office'), findsOneWidget);
    // The date-scoped line is ONE backend string: a Dart build that joined a
    // count to a date would fail here.
    expect(find.text('2 heard on 15 Sep'), findsNWidgets(2));
    expect(find.text('Last seen 15 Sep, 09:40 pm'), findsNWidgets(2));
  });

  testWidgets('rows keep payload order — no client-side sort', (t) async {
    await pump(t, _payload());
    final labels = t
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.data ?? '')
        .where((s) => s == 'Zeta counter phone' || s == 'Alpha back office')
        .toList();
    expect(labels, ['Zeta counter phone', 'Alpha back office']);
  });

  testWidgets('not paired renders the backend refusal wording, not ours',
      (t) async {
    await pump(t, _payload(paired: false));
    expect(find.text('Not paired'), findsOneWidget);
    expect(find.text('Turn on notification access to pair this phone.'),
        findsOneWidget);
    expect(find.text('Turn on notification access'), findsOneWidget);
  });

  testWidgets('the web gets the WHOLE section — only listening is device-local',
      (t) async {
    await pump(
      t,
      _payload(native: false, paired: false, rows: [
        _device(id: 'zeta', label: 'Zeta counter phone', listenerEditable: false),
        _device(
            id: 'alpha',
            label: 'Alpha back office',
            listener: false,
            speak: false,
            volume: 40,
            listenerEditable: false),
      ]),
      platform: 'web',
    );

    // Every paired phone is listed, with its state — this is NOT an Android
    // -only surface.
    expect(find.text('Zeta counter phone'), findsOneWidget);
    expect(find.text('Alpha back office'), findsOneWidget);
    expect(find.text('Last seen 15 Sep, 09:40 pm'), findsNWidgets(2));
    expect(find.text('No payment heard yet'), findsNWidgets(2));

    // Speak + volume stay editable from a laptop: they are server-side
    // settings the phone obeys.
    expect(find.byType(Slider), findsNWidgets(2));
    final switches = t.widgetList<Switch>(find.byType(Switch)).toList();
    expect(switches.length, 4);
    // listener switches (index 0, 2) inert; speak switches (1, 3) live.
    expect(switches[0].onChanged, isNull);
    expect(switches[1].onChanged, isNotNull);
    expect(switches[2].onChanged, isNull);
    expect(switches[3].onChanged, isNotNull);

    // The reason listening cannot be flipped here is the backend's sentence.
    expect(
      find.text(
          'Only this phone can switch listening on — it is an Android permission.'),
      findsNWidgets(2),
    );
    // No Android settings button on a laptop, and the backend says why.
    expect(find.text('Manage notification access'), findsNothing);
    expect(find.text('Turn on notification access'), findsNothing);
    expect(
      find.text(
          'Open mediBO on the shop phone to pair it and turn on notification access.'),
      findsOneWidget,
    );
  });

  testWidgets('a web edit sends the same RPC the phone sends', (t) async {
    final calls = <List<Object?>>[];
    await pump(
      t,
      _payload(native: false, rows: [
        _device(id: 'alpha', label: 'Alpha back office', listenerEditable: false),
      ]),
      calls: calls,
      platform: 'web',
    );
    calls.clear();

    final speak = find.byType(Switch).at(1);
    await t.ensureVisible(speak);
    await t.pumpAndSettle();
    await t.tap(speak);
    await t.pumpAndSettle();

    final set = calls.firstWhere((c) => c[0] == 'payment_alert_device_set');
    final args = set[1] as Map<String, dynamic>;
    expect(args['p_device'], 'alpha');
    expect(args['p_speak_enabled'], false);
    expect(args.containsKey('p_listener_enabled'), isFalse);
  });

  testWidgets('a toggle sends exactly the one field that changed', (t) async {
    final calls = <List<Object?>>[];
    await pump(t, _payload(), calls: calls);
    calls.clear();

    // The second row's speak switch (row 2 is muted); switches come in
    // listener-then-speak order per row.
    final target = find.byType(Switch).at(3);
    await t.ensureVisible(target);
    await t.pumpAndSettle();
    await t.tap(target);
    await t.pumpAndSettle();

    final set = calls.firstWhere((c) => c[0] == 'payment_alert_device_set');
    final args = set[1] as Map<String, dynamic>;
    expect(args['p_device'], 'alpha');
    expect(args['p_speak_enabled'], true);
    expect(args.containsKey('p_listener_enabled'), isFalse);
    expect(args.containsKey('p_volume'), isFalse);
  });

  testWidgets('an empty registry is an empty STATE, not a blank area',
      (t) async {
    await pump(t, _payload(rows: const [], paired: false));
    expect(find.text('No phone is listening yet'), findsOneWidget);
    expect(
      find.text(
          'Open mediBO on the shop phone and turn on notification access — it pairs itself.'),
      findsOneWidget,
    );
  });

  testWidgets('no horizontal overflow at 320, 360, 412 or 480', (t) async {
    for (final w in [320.0, 360.0, 412.0, 480.0]) {
      await pump(t, _payload(), width: w);
      expect(tester_exceptions(), isEmpty, reason: 'overflow at ${w}px');
    }
  });
}

/// Flutter reports an overflow as a framework exception; a clean pump has none.
List<Object> tester_exceptions() {
  final e = <Object>[];
  final caught = TestWidgetsFlutterBinding.instance.takeException();
  if (caught != null) e.add(caught);
  return e;
}
