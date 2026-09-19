// PROTECTED — CMD #2093.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes the app picker, the UTR switch or the collection
// header on the Payment alerts screen.
//
// ₹50,000 turned out to be a PhonePe ad and ₹5 a PhonePe chat. The two
// switches that stop that are on this screen, and neither of them may ever
// start deciding anything in Dart:
//
//   1. THE PICKER IS THE PAYLOAD'S ORDER. Business apps come first because
//      the backend sent them first, not because Dart sorted on a kind word.
//      A group heading is drawn where the payload's own order changes kind.
//
//   2. THE SWITCH SENDS A PATCH AND REDRAWS THE ANSWER. Turning an app off
//      sends {id, enabled:false} to payment_alert_rule_save and then reloads
//      the screen — the new state and the new count line come back from the
//      backend. Dart never flips the switch optimistically.
//
//   3. can_edit IS THE BACKEND'S. A payload that says a row may not be edited
//      renders a switch nobody can move, and no Dart role check exists.
//
//   4. THE UTR HINT IS ONE STRING. The sentence under "Look for UTR" arrives
//      already chosen for the state it is in; Dart must not own two literals
//      and a ternary.
//
//   5. THE HEADER PRINTS THE MODE AND THE UPI ID VERBATIM, including the
//      "no UPI id" line — absence is a backend sentence, not an empty widget.
//
// No network, no Supabase, no goldens. Phone viewport, as every mediBO screen
// is designed and proven at.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/payment_alerts_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _app(
  int id,
  String label,
  String pkg,
  String kindLabel,
  bool on, {
  bool canEdit = true,
}) => {
      'id': id,
      'label': label,
      'package_name': pkg,
      'kind_label': kindLabel,
      'enabled': on,
      'state_label': on ? 'On' : 'Off',
      'state_tone': on ? 'success' : 'muted',
      'can_edit': canEdit,
    };

Map<String, dynamic> _payload({
  bool utrOn = true,
  bool canEdit = true,
  bool phonePeOn = false,
  bool hasUpi = true,
}) => {
      'ok': true,
      'title': 'Payment alerts',
      'retry_label': 'Retry',
      'empty_label': 'No payment notifications for this zone and date yet.',
      'empty_hint': 'Alerts appear here the moment the phone forwards one.',
      'filters': const [],
      'rows': const [],
      'header': {
        'title': 'How money is collected',
        'mode_label': 'Manual UPI',
        'mode_tone': 'success',
        'upi_label': 'UPI ID',
        'upi_value': hasUpi ? 'medibo@hdfcbank' : 'No UPI ID is active',
        'upi_name': hasUpi ? 'mediBO Retail' : '',
        'has_upi': hasUpi,
      },
      'utr': {
        'title': 'Look for UTR',
        'on': utrOn,
        'hint': utrOn
            ? 'On: a notification without a UTR, Ref or RRN is dropped and never shown.'
            : 'Off: every credit that is read is shown, with or without a reference.',
        'can_edit': canEdit,
      },
      'apps': {
        'title': 'Which apps to listen to',
        'hint': 'Off means this phone never even reads that app.',
        'empty_label': 'No payment apps configured yet.',
        'count_label': '2 of 3 apps on',
        'can_edit': canEdit,
        'rows': [
          _app(3, 'PhonePe for Business', 'com.phonepe.business.app',
              'Business apps', true, canEdit: canEdit),
          _app(9, 'SBI YONO', 'com.sbi.lotusintouch', 'Bank apps', true,
              canEdit: canEdit),
          _app(21, 'PhonePe', 'com.phonepe.app', 'Personal apps', phonePeOn,
              canEdit: canEdit),
        ],
      },
    };

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  Future<void> phone(WidgetTester t, {double width = 360}) async {
    t.view.physicalSize = Size(width, 900);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
  }

  Future<void> openPicker(WidgetTester t) async {
    await t.tap(find.text('Which apps to listen to'));
    await t.pumpAndSettle();
  }

  testWidgets('the header prints the collection mode and the active UPI id',
      (t) async {
    await phone(t);
    await t.pumpWidget(MaterialApp(
      home: PaymentAlertsScreen(rpc: (fn, args) async => _payload()),
    ));
    await t.pumpAndSettle();

    expect(find.text('How money is collected'), findsOneWidget);
    expect(find.text('Manual UPI'), findsOneWidget);
    expect(find.text('UPI ID'), findsOneWidget);
    expect(find.text('medibo@hdfcbank'), findsOneWidget);
    expect(find.text('mediBO Retail'), findsOneWidget);
  });

  testWidgets('no active UPI id is a backend sentence, not a blank', (t) async {
    await phone(t);
    await t.pumpWidget(MaterialApp(
      home: PaymentAlertsScreen(
        rpc: (fn, args) async => _payload(hasUpi: false),
      ),
    ));
    await t.pumpAndSettle();

    expect(find.text('No UPI ID is active'), findsOneWidget);
  });

  testWidgets('the UTR hint is the one string the payload chose', (t) async {
    await phone(t);
    await t.pumpWidget(MaterialApp(
      home: PaymentAlertsScreen(
        rpc: (fn, args) async => _payload(utrOn: false),
      ),
    ));
    await t.pumpAndSettle();

    expect(find.text('Look for UTR'), findsOneWidget);
    expect(
      find.text(
        'Off: every credit that is read is shown, with or without a reference.',
      ),
      findsOneWidget,
    );
    // The other sentence is not in the build at all: Dart holds neither.
    expect(
      find.text(
        'On: a notification without a UTR, Ref or RRN is dropped and never shown.',
      ),
      findsNothing,
    );
  });

  testWidgets('the UTR switch sends the flag to payment_alert_utr_set',
      (t) async {
    await phone(t);
    final calls = <String>[];
    Map<String, dynamic>? sent;
    await t.pumpWidget(MaterialApp(
      home: PaymentAlertsScreen(
        rpc: (fn, args) async {
          calls.add(fn);
          if (fn == 'payment_alert_utr_set') {
            sent = args;
            return {'ok': true, 'toast': 'Saved.'};
          }
          return _payload();
        },
      ),
    ));
    await t.pumpAndSettle();

    await t.tap(find.bySemanticsIdentifier('pay_alert_utr_switch'));
    await t.pumpAndSettle();

    expect(calls.contains('payment_alert_utr_set'), isTrue);
    expect(sent?['p_on'], isFalse); // it was on; the tap asks for off
    // The screen re-reads itself: the new state is the backend's answer.
    expect(calls.where((c) => c == 'payment_alerts_screen').length,
        greaterThanOrEqualTo(2));
  });

  testWidgets('the picker keeps the payload order: business, bank, personal',
      (t) async {
    await phone(t);
    await t.pumpWidget(MaterialApp(
      home: PaymentAlertsScreen(rpc: (fn, args) async => _payload()),
    ));
    await t.pumpAndSettle();
    expect(find.text('2 of 3 apps on'), findsOneWidget);
    await openPicker(t);

    final business = t.getTopLeft(find.text('PhonePe for Business')).dy;
    final bank = t.getTopLeft(find.text('SBI YONO')).dy;
    final personal = t.getTopLeft(find.text('PhonePe')).dy;
    expect(business, lessThan(bank));
    expect(bank, lessThan(personal));

    // The headings come from the rows' own kind_label, drawn at the boundary.
    expect(find.text('Business apps'), findsOneWidget);
    expect(find.text('Bank apps'), findsOneWidget);
    expect(find.text('Personal apps'), findsOneWidget);
    // The package is on the row, so an admin can tell two PhonePe apps apart.
    expect(find.text('com.phonepe.business.app'), findsOneWidget);
    expect(find.text('com.phonepe.app'), findsOneWidget);
  });

  testWidgets('turning one app off sends the patch and reloads the screen',
      (t) async {
    await phone(t);
    final calls = <String>[];
    Map<String, dynamic>? patch;
    await t.pumpWidget(MaterialApp(
      home: PaymentAlertsScreen(
        rpc: (fn, args) async {
          calls.add(fn);
          if (fn == 'payment_alert_rule_save') {
            patch = args;
            return {'ok': true, 'toast': 'Rule saved.'};
          }
          return _payload();
        },
      ),
    ));
    await t.pumpAndSettle();
    await openPicker(t);

    await t.tap(find.bySemanticsIdentifier('pay_alert_app_3'));
    await t.pumpAndSettle();

    expect(calls.contains('payment_alert_rule_save'), isTrue);
    final p = patch?['p_patch'] as Map?;
    expect(p?['id'], 3);
    expect(p?['enabled'], isFalse);
    // Nothing is flipped locally: the screen asks the backend again.
    expect(calls.where((c) => c == 'payment_alerts_screen').length,
        greaterThanOrEqualTo(2));
  });

  testWidgets('can_edit:false leaves a switch nobody can move', (t) async {
    await phone(t);
    final calls = <String>[];
    await t.pumpWidget(MaterialApp(
      home: PaymentAlertsScreen(
        rpc: (fn, args) async {
          calls.add(fn);
          return _payload(canEdit: false);
        },
      ),
    ));
    await t.pumpAndSettle();
    await openPicker(t);

    await t.tap(find.bySemanticsIdentifier('pay_alert_app_3'));
    await t.pumpAndSettle();
    await t.tap(find.bySemanticsIdentifier('pay_alert_utr_switch'));
    await t.pumpAndSettle();

    expect(calls.contains('payment_alert_rule_save'), isFalse);
    expect(calls.contains('payment_alert_utr_set'), isFalse);
  });

  testWidgets('an app the payload turned off still renders its Off word',
      (t) async {
    await phone(t, width: 412);
    await t.pumpWidget(MaterialApp(
      home: PaymentAlertsScreen(
        rpc: (fn, args) async => _payload(phonePeOn: false),
      ),
    ));
    await t.pumpAndSettle();
    await openPicker(t);

    expect(find.text('Off'), findsOneWidget);
    expect(find.text('On'), findsNWidgets(2));
    expect(tester_noOverflow(t), isTrue);
  });
}

/// The phone viewport is the contract: a picker that overflows at 360 or 412
/// is a picker an admin cannot use. Flutter reports an overflow as an
/// exception, so the absence of one is the assertion.
bool tester_noOverflow(WidgetTester t) => t.takeException() == null;
