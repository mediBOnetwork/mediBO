// PROTECTED — CMD #2250.
//
// See CLAUDE.md: this runs before EVERY deploy and may only be edited by a
// CHANGE that deliberately changes the behaviour below — never to make an
// unrelated change go green.
//
// What this holds down, on the three surfaces UPI money is decided on:
//
//   1. THE OUTCOME IS THE BACKEND'S WORD. "Verified · order no.", "Waiting" and
//      "Not matched" are `outcome_label` printed verbatim with `outcome_tone`.
//      Dart never derives the chip from `status`, from a match_reason string or
//      from "has an order_id" — the payload already decided.
//
//   2. THE BUTTON SET IS DATA. The detail sheet draws exactly the `actions[]`
//      the backend sent, in that order, and sends back that action's own `key`.
//      An alert with two actions gets two buttons; adding "Undo" is a backend
//      row, not a Dart branch.
//
//   3. THE FILTERS ARE THE BACKEND'S. The chip row is `filters[]` verbatim, and
//      tapping one asks the server again with that key. The list is never
//      filtered client-side.
//
//   4. THE PARTNER PHONE'S HEALTH IS COMPUTED ON READ. The banner, the three
//      fix steps and their done/off chips all arrive rendered; the screen owns
//      no staleness rule and no timer.
//
//   5. SWITCHING TO A PERSONAL UPI IS THE BACKEND'S REFUSAL. upi_make_active
//      answers `confirm_personal` with the sheet's own copy, and only a second,
//      confirmed call switches. The warning's wording is never typed in Dart.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/payment_alerts_screen.dart';
import 'package:pharma_b2b/screens/admin/payment_payee_section.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _alert({
  required String id,
  required String amount,
  required String outcome,
  required String tone,
  List<Map<String, dynamic>> actions = const [],
  List<Map<String, dynamic>> rows = const [],
}) =>
    {
      'ok': true,
      'alert_id': id,
      'amount_label': amount,
      'outcome_label': outcome,
      'outcome_tone': tone,
      'outcome_key': outcome.toLowerCase(),
      'sender_label': 'RANDOM PERSON',
      'list_sub': '4:01 pm · CPO290926CHA102O1',
      'subtitle': 'Verified automatically at 3:40 pm',
      'rows': rows,
      'actions': actions,
    };

Map<String, dynamic> _screen({
  String filter = '',
  List<Map<String, dynamic>>? rows,
  Map<String, dynamic>? phone,
}) =>
    {
      'ok': true,
      'title': 'Payment alerts',
      'empty_label': 'No payment notifications for this zone and date yet.',
      'empty_hint': 'Alerts appear here the moment the phone forwards one.',
      'retry_label': 'Retry',
      'active_filter': filter,
      'filters': const [
        {'key': '', 'label': 'All', 'count': 5},
        {'key': 'verified', 'label': 'Verified', 'count': 3},
        {'key': 'waiting', 'label': 'Waiting', 'count': 1},
        {'key': 'not_matched', 'label': 'Not matched', 'count': 1},
      ],
      'phone': phone ?? const {'ok': false},
      'rows': rows ??
          [
            _alert(
                id: 'a1',
                amount: '₹1,377.92',
                outcome: 'Verified · name',
                tone: 'success'),
            _alert(
                id: 'a2',
                amount: '₹431.64',
                outcome: 'Waiting',
                tone: 'info'),
            _alert(
                id: 'a3',
                amount: '₹2,150.00',
                outcome: 'Not matched',
                tone: 'warning'),
          ],
    };

Map<String, dynamic> get _phoneStale => {
      'ok': true,
      'state': 'stale',
      'device_id': 'realme-RMX1931',
      'banner': {
        'tone': 'danger',
        'title': 'This phone stopped reporting',
        'body': "Last seen 19 Sep · payments won't verify on their own",
      },
      'fix_label': 'FIX IT IN 3 STEPS',
      'settings_label': 'Open phone settings',
      'test_label': 'Send ₹1 test to Vyapar',
      'phone_label': 'ON THIS PHONE',
      'apps_label': 'APPS WE READ',
      'toggles': const [],
      'apps': const [],
      'fix': const [
        {
          'n': 1,
          'label': 'Open mediBO Partner on this phone',
          'sub': 'Log in as Universal Pharma',
          'done': true,
          'chip': '✓'
        },
        {
          'n': 2,
          'label': 'Allow notification access',
          'sub': 'Needed to read Vyapar payments',
          'done': false,
          'chip': 'Off'
        },
        {
          'n': 3,
          'label': 'Battery: Unrestricted',
          'sub': 'Otherwise the phone stops listening at night',
          'done': false,
          'chip': 'Off'
        },
      ],
    };

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  Future<void> pumpAlerts(
    WidgetTester tester, {
    required Future<Map<String, dynamic>> Function(String?) screenRpc,
    Future<Map<String, dynamic>> Function(String, String, String?)? actRpc,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: PaymentAlertsScreen(
        screenRpc: screenRpc,
        actRpc: actRpc,
        listenRealtime: false,
      ),
    ));
    await tester.pumpAndSettle();
  }

  group('payment alerts list', () {
    testWidgets('1 · outcome chips are the payload, never derived in Dart',
        (tester) async {
      await pumpAlerts(tester, screenRpc: (_) async => _screen());

      // Scoped to the rows: "Waiting" and "Not matched" are also filter chips,
      // and both come from the same payload — neither is typed in Dart.
      Finder inRow(String t) => find.descendant(
          of: find.bySemanticsIdentifier('alert_row'), matching: find.text(t));
      expect(inRow('Verified · name'), findsOneWidget);
      expect(inRow('Waiting'), findsOneWidget);
      expect(inRow('Not matched'), findsOneWidget);
      // The amounts are printed as sent — no Dart currency formatting.
      expect(find.text('₹1,377.92'), findsOneWidget);
      expect(find.text('₹2,150.00'), findsOneWidget);
    });

    testWidgets('3 · tapping a filter re-asks the SERVER with its own key',
        (tester) async {
      final asked = <String?>[];
      await pumpAlerts(tester, screenRpc: (f) async {
        asked.add(f);
        // The server answers with one row for the chosen filter; a client-side
        // filter would have kept showing three.
        return _screen(filter: f ?? '', rows: [
          _alert(
              id: 'a2', amount: '₹431.64', outcome: 'Waiting', tone: 'info'),
        ]);
      });

      await tester.tap(find.bySemanticsIdentifier('alert_filter_waiting'));
      await tester.pumpAndSettle();

      expect(asked, ['', 'waiting']);
      expect(find.text('₹431.64'), findsOneWidget);
      expect(find.text('₹1,377.92'), findsNothing);
    });

    testWidgets('empty state prints the backend guidance, not a Dart string',
        (tester) async {
      await pumpAlerts(tester,
          screenRpc: (_) async => _screen(rows: const []));
      expect(find.text('No payment notifications for this zone and date yet.'),
          findsOneWidget);
    });

    testWidgets('a refusal renders the backend message and offers Retry',
        (tester) async {
      var calls = 0;
      await pumpAlerts(tester, screenRpc: (_) async {
        calls++;
        return {
          'ok': false,
          'error': 'not_authorized',
          'message': 'Payment alerts are visible to a partner or an admin.',
          'retry_label': 'Retry',
        };
      });
      expect(find.text('Payment alerts are visible to a partner or an admin.'),
          findsOneWidget);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(calls, 2);
    });
  });

  group('payment alert detail', () {
    testWidgets('2 · the sheet draws exactly the actions the backend sent',
        (tester) async {
      final sent = <String>[];
      await pumpAlerts(
        tester,
        screenRpc: (_) async => _screen(rows: [
          _alert(
            id: 'a1',
            amount: '₹1,377.92',
            outcome: 'Verified · name',
            tone: 'success',
            rows: const [
              {'label': 'Payer', 'value': 'CHANDRA SEKHAR RATRE'},
              {'label': 'Written off', 'value': '₹0.00'},
            ],
            actions: const [
              {'key': 'open_order', 'label': 'Open order', 'tone': 'primary_outline'},
              {'key': 'undo', 'label': 'Undo', 'tone': 'muted'},
            ],
          ),
        ]),
        actRpc: (id, action, claim) async {
          sent.add('$id:$action');
          return {'ok': true, 'message': 'Undone — the payment is open again.'};
        },
      );

      await tester.tap(find.bySemanticsIdentifier('alert_row'));
      await tester.pumpAndSettle();

      expect(find.text('CHANDRA SEKHAR RATRE'), findsOneWidget);
      expect(find.text('Written off'), findsOneWidget);
      expect(find.text('₹0.00'), findsOneWidget);
      expect(find.text('Open order'), findsOneWidget);
      expect(find.text('Undo'), findsOneWidget);

      await tester.tap(find.bySemanticsIdentifier('alert_act_undo'));
      // The toast the backend message rides on holds a 4-second Timer that
      // outlives pumpAndSettle; pump past its lifetime so it dismisses.
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      // The backend's own key travelled back — not a Dart word for it.
      expect(sent, ['a1:undo']);
    });

    testWidgets('a waiting alert offers only what the backend listed',
        (tester) async {
      await pumpAlerts(
        tester,
        screenRpc: (_) async => _screen(rows: [
          _alert(
            id: 'a2',
            amount: '₹431.64',
            outcome: 'Waiting',
            tone: 'info',
            actions: const [
              {'key': 'verify_now', 'label': 'Verify now', 'tone': 'primary'},
              {'key': 'not_this_order', 'label': 'Not this order', 'tone': 'muted'},
            ],
          ),
        ]),
      );
      await tester.tap(find.bySemanticsIdentifier('alert_row'));
      await tester.pumpAndSettle();
      expect(find.text('Verify now'), findsOneWidget);
      expect(find.text('Not this order'), findsOneWidget);
      expect(find.text('Undo'), findsNothing);
    });
  });

  group('partner phone block', () {
    testWidgets('4 · banner and the three fix steps are rendered verbatim',
        (tester) async {
      await pumpAlerts(tester,
          screenRpc: (_) async => _screen(phone: _phoneStale));

      expect(find.text('This phone stopped reporting'), findsOneWidget);
      expect(find.text("Last seen 19 Sep · payments won't verify on their own"),
          findsOneWidget);
      expect(find.text('FIX IT IN 3 STEPS'), findsOneWidget);
      expect(find.text('Allow notification access'), findsOneWidget);
      expect(find.text('Battery: Unrestricted'), findsOneWidget);
      // done/off is the payload's flag, not a Dart reading of last_seen_at.
      expect(find.text('✓'), findsOneWidget);
      expect(find.text('Off'), findsNWidgets(2));
      expect(find.bySemanticsIdentifier('phone_open_settings'), findsOneWidget);
    });
  });

  group('making a personal UPI active', () {
    testWidgets('5 · the warning is the backend refusal, confirmed once',
        (tester) async {
      final calls = <String>[];
      final rows = [
        {
          'id': 'u1',
          'pa': 'medibo@axl',
          'pn': 'Om Prakash Sahu',
          'is_active': false,
          'is_business': false,
          'type_label': 'Personal UPI',
          'pay_label': 'QR + screenshot only',
          'pay_tone': 'warning',
          'qr_label': 'No merchant QR',
          'has_merchant': false,
          'state_label': 'Make active',
          'can_activate': true,
        }
      ];

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: PaymentPayeeSection(
            screenRpc: () async => {
              'ok': true,
              'section_label': 'WHERE CUSTOMERS PAY',
              'add_label': '+ Add UPI',
              'empty_label': '',
              'empty_hint': '',
              'rows': rows,
              'see': const {'title': 'What customers see now', 'lines': []},
              'form': const {'title': 'Add UPI', 'types': []},
            },
            activateRpc: (id, confirm) async {
              calls.add('$id:$confirm');
              if (!confirm) {
                return {
                  'ok': false,
                  'error': 'confirm_personal',
                  'confirm': {
                    'title': 'Make a personal UPI active?',
                    'subtitle': 'Om Prakash Sahu · medibo@axl',
                    'warn_title': 'The Pay button turns off',
                    'warn_body':
                        'Banks can block many payments into a personal UPI.',
                    'cancel_label': 'Keep business',
                    'confirm_label': 'Switch anyway',
                  },
                };
              }
              return {'ok': true, 'message': 'That UPI account is now active.'};
            },
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.bySemanticsIdentifier('upi_make_active'));
      await tester.pumpAndSettle();

      // Every word of the warning came from the payload.
      expect(find.text('Make a personal UPI active?'), findsOneWidget);
      expect(find.text('The Pay button turns off'), findsOneWidget);
      expect(find.text('Keep business'), findsOneWidget);

      await tester.tap(find.bySemanticsIdentifier('upi_switch_anyway'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      // First call unconfirmed (the refusal), second confirmed. Never one call.
      expect(calls, ['u1:false', 'u1:true']);
    });

    testWidgets('Keep business leaves the active account alone', (tester) async {
      final calls = <String>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: PaymentPayeeSection(
            screenRpc: () async => {
              'ok': true,
              'section_label': 'WHERE CUSTOMERS PAY',
              'add_label': '+ Add UPI',
              'rows': [
                {
                  'id': 'u1',
                  'pa': 'medibo@axl',
                  'pn': 'Om Prakash Sahu',
                  'is_active': false,
                  'is_business': false,
                  'type_label': 'Personal UPI',
                  'pay_label': 'QR + screenshot only',
                  'pay_tone': 'warning',
                  'qr_label': 'No merchant QR',
                  'has_merchant': false,
                  'state_label': 'Make active',
                }
              ],
              'see': const {'title': '', 'lines': []},
              'form': const {'title': 'Add UPI', 'types': []},
            },
            activateRpc: (id, confirm) async {
              calls.add('$id:$confirm');
              return {
                'ok': false,
                'error': 'confirm_personal',
                'confirm': const {
                  'title': 'Make a personal UPI active?',
                  'subtitle': 'Om Prakash Sahu · medibo@axl',
                  'warn_title': 'The Pay button turns off',
                  'warn_body': 'Banks can block many payments.',
                  'cancel_label': 'Keep business',
                  'confirm_label': 'Switch anyway',
                },
              };
            },
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.bySemanticsIdentifier('upi_make_active'));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsIdentifier('upi_keep_business'));
      await tester.pumpAndSettle();

      expect(calls, ['u1:false']);
    });
  });
}
