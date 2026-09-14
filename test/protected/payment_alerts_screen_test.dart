// CMD #1930 — what the payment alerts queue and its parser editor may NEVER
// start deciding for themselves.
//
// The whole feature is one promise: the backend decided, the screen printed it.
// These tests hold that promise down at a phone viewport.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/payment_alerts_screen.dart';
import 'package:pharma_b2b/screens/admin/payment_alert_rules_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _screenPayload({String status = 'unmatched'}) => {
      'ok': true,
      'title': 'Payment alerts',
      'subtitle': 'Payment notifications forwarded from the partner phone',
      'empty_label': 'No payment notifications for this zone and date yet.',
      'empty_hint': 'Alerts appear here the moment the partner phone forwards one.',
      'retry_label': 'Retry',
      'active_filter': '',
      'filters': [
        {'key': '', 'label': 'All', 'count': 2, 'chip_label': 'All 2'},
        {'key': 'unmatched', 'label': 'Needs a look', 'count': 1,
         'chip_label': 'Needs a look 1'},
      ],
      'rows': [
        {
          'alert_id': 'a-1',
          'status': status,
          'status_label': status == 'matched' ? 'Matched' : 'Needs a look',
          'status_tone': status == 'matched' ? 'success' : 'warning',
          'amount_label': '₹1,250.00',
          'app_label': 'Google Pay',
          'posted_label': '13 Sep, 10:50 pm',
          'utr_label': 'No UTR in the notification',
          'sender_label': 'Sender not named',
          'match_reason': 'More than one payment could be this one.',
          'order_code': status == 'matched' ? 'PO-9F2C' : '',
          'customer_label': status == 'matched' ? 'Sai Medicals' : '',
          'retry_match_label': status == 'matched' ? '' : 'Match again',
          'link_label': status == 'matched' ? '' : 'Link to an order',
          'ignore_label': status == 'matched' ? '' : 'Ignore',
        },
      ],
    };

Map<String, dynamic> _linkPayload() => {
      'ok': true,
      'alert_id': 'a-1',
      'title': 'Link this payment',
      'subtitle': 'Pick the order this ₹1,250.00 belongs to.',
      'empty_label': 'Nothing is waiting to be paid here.',
      'empty_hint': 'Only unverified payments for this zone and date.',
      'cancel_label': 'Close',
      'rows': [
        {
          'claim_id': 'c-far',
          'order_id': 'o-far',
          'title_label': 'Far Pharmacy',
          'order_label': 'PO-0001',
          'amount_label': '₹1,300.00',
          'time_label': '13 Sep, 09:00 pm',
          'utr_label': '111222333444',
          'delta_label': '₹50.00 more than the alert',
          'delta_tone': 'warning',
        },
        {
          'claim_id': 'c-exact',
          'order_id': 'o-exact',
          'title_label': 'Exact Pharmacy',
          'order_label': 'PO-0002',
          'amount_label': '₹1,250.00',
          'time_label': '13 Sep, 10:48 pm',
          'utr_label': '999888777666',
          'delta_label': 'Exactly this amount',
          'delta_tone': 'success',
        },
      ],
    };

Map<String, dynamic> _rulesPayload() => {
      'ok': true,
      'title': 'Payment parser rules',
      'subtitle': 'One rule per payment app.',
      'empty_label': 'No parser rules yet.',
      'empty_hint': 'Add one rule per payment app.',
      'add_label': 'Add a payment app',
      'save_label': 'Save rule',
      'cancel_label': 'Cancel',
      'test_title': 'Test this rule',
      'test_hint': 'Paste a real notification here.',
      'test_run_label': 'Run the test',
      'fields': [
        {'key': 'label', 'label': 'Name', 'hint': 'Google Pay', 'lines': 1},
        {'key': 'package_name', 'label': 'App package', 'hint': 'com.x.y', 'lines': 1},
        {'key': 'amount_regex', 'label': 'Amount pattern', 'hint': 'Rs', 'lines': 2},
      ],
      'rows': [
        {
          'id': 7,
          'label': 'Google Pay',
          'package_name': 'com.google.pay',
          'package_label': 'com.google.pay',
          'amount_regex': 'Rs',
          'enabled': true,
          'status_label': 'On',
          'status_tone': 'success',
          'toggle_label': 'Turn off',
          'edit_label': 'Edit',
          'order_label': 'Tried #10',
          'note': '',
        },
      ],
    };

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  Future<void> phone(WidgetTester t) async {
    t.view.physicalSize = const Size(360, 780);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
  }

  testWidgets('the queue prints the backend row verbatim and nothing else',
      (t) async {
    await phone(t);
    await t.pumpWidget(MaterialApp(
      home: PaymentAlertsScreen(
        rpc: (fn, args) async => _screenPayload(),
      ),
    ));
    await t.pumpAndSettle();

    // Amount, chip, app, time and reason are the payload's strings — a Dart
    // build that formats ₹ or pluralises a chip fails here.
    expect(find.text('₹1,250.00'), findsOneWidget);
    expect(find.text('Needs a look'), findsOneWidget);
    expect(find.text('Needs a look 1'), findsOneWidget); // chip caption is ONE string
    expect(find.text('Google Pay'), findsOneWidget);
    expect(find.text('More than one payment could be this one.'), findsOneWidget);
  });

  testWidgets('a matched alert offers no action: the payload sent no labels',
      (t) async {
    await phone(t);
    await t.pumpWidget(MaterialApp(
      home: PaymentAlertsScreen(
        rpc: (fn, args) async => _screenPayload(status: 'matched'),
      ),
    ));
    await t.pumpAndSettle();

    expect(find.text('Matched'), findsOneWidget);
    // CMD #1929 pinned the matched claim as ONE joined line — customer, then
    // code — so that is what is asserted here too, not the two halves.
    expect(find.text('Sai Medicals · PO-9F2C'), findsOneWidget);
    // Absence is the backend's: empty ignore/retry labels mean no buttons,
    // never a client-side `if (status == matched)`.
    expect(find.text('Ignore'), findsNothing);
    expect(find.text('Match again'), findsNothing);
    expect(find.text('Link to an order'), findsNothing);
  });

  testWidgets('the link sheet keeps the backend ranking and sends the picked id',
      (t) async {
    await phone(t);
    final calls = <String>[];
    Map<String, dynamic>? linkArgs;
    await t.pumpWidget(MaterialApp(
      home: PaymentAlertsScreen(
        rpc: (fn, args) async {
          calls.add(fn);
          if (fn == 'payment_alert_link_options') return _linkPayload();
          if (fn == 'payment_alert_link') {
            linkArgs = args;
            return {'ok': true, 'toast': 'Payment linked and verified.'};
          }
          return _screenPayload();
        },
      ),
    ));
    await t.pumpAndSettle();

    await t.tap(find.text('Link to an order'));
    await t.pumpAndSettle();

    // Payload order is render order: the ₹50-off candidate came first and it
    // STAYS first. No client-side sort by closeness.
    final far = t.getTopLeft(find.text('Far Pharmacy')).dy;
    final exact = t.getTopLeft(find.text('Exact Pharmacy')).dy;
    expect(far, lessThan(exact));
    expect(find.text('Exactly this amount'), findsOneWidget);

    await t.tap(find.text('Exact Pharmacy'));
    await t.pumpAndSettle();

    expect(calls.contains('payment_alert_link'), isTrue);
    expect(linkArgs?['p_claim_id'], 'c-exact');
    expect(linkArgs?['p_alert_id'], 'a-1');
  });

  testWidgets('ignore is an RPC with the backend status, not a local flag',
      (t) async {
    await phone(t);
    Map<String, dynamic>? args;
    await t.pumpWidget(MaterialApp(
      home: PaymentAlertsScreen(
        rpc: (fn, a) async {
          if (fn == 'payment_alert_set_status') {
            args = a;
            return {'ok': true};
          }
          return _screenPayload();
        },
      ),
    ));
    await t.pumpAndSettle();

    await t.tap(find.text('Ignore'));
    await t.pumpAndSettle();
    expect(args?['p_status'], 'ignored');
    expect(args?['p_alert_id'], 'a-1');
  });

  testWidgets('the rule form is built from the payload fields, not from Dart',
      (t) async {
    await phone(t);
    Map<String, dynamic>? testPatch;
    await t.pumpWidget(MaterialApp(
      home: PaymentAlertRulesScreen(
        rpc: (fn, args) async {
          if (fn == 'payment_alert_rule_test') {
            testPatch = Map<String, dynamic>.from(args['p_patch'] as Map);
            return {
              'ok': true,
              'matched': true,
              'verdict_label': 'This rule reads the notification.',
              'verdict_tone': 'success',
              'rows': [
                {'label': 'Amount', 'value': '₹1,250.00', 'tone': 'success'},
              ],
            };
          }
          return _rulesPayload();
        },
      ),
    ));
    await t.pumpAndSettle();

    expect(find.text('Google Pay'), findsOneWidget);
    expect(find.text('On'), findsOneWidget);
    expect(find.text('Tried #10'), findsOneWidget);

    await t.tap(find.text('Edit'));
    await t.pumpAndSettle();

    // Three fields because the payload named three — a fourth regex is an
    // UPDATE to fields[], never an edit of this screen.
    expect(find.text('Name'), findsOneWidget);
    expect(find.text('App package'), findsOneWidget);
    expect(find.text('Amount pattern'), findsOneWidget);

    await t.tap(find.text('Run the test'));
    await t.pumpAndSettle();

    // The test box runs the rule the ADMIN is editing, saved or not.
    expect(testPatch?['label'], 'Google Pay');
    expect(testPatch?['id'], 7);
    expect(find.text('This rule reads the notification.'), findsOneWidget);
    expect(find.text('₹1,250.00'), findsOneWidget);
  });

  testWidgets('turning a rule off sends the whole decision to the backend',
      (t) async {
    await phone(t);
    Map<String, dynamic>? patch;
    await t.pumpWidget(MaterialApp(
      home: PaymentAlertRulesScreen(
        rpc: (fn, args) async {
          if (fn == 'payment_alert_rule_save') {
            patch = Map<String, dynamic>.from(args['p_patch'] as Map);
            return _rulesPayload();
          }
          return _rulesPayload();
        },
      ),
    ));
    await t.pumpAndSettle();

    await t.tap(find.text('Turn off'));
    await t.pumpAndSettle();
    expect(patch?['id'], 7);
    expect(patch?['enabled'], false);
  });
}
