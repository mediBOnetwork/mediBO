// CMD #415 — the khata book renders the backend and decides nothing.
//
// The failure this file exists to prevent is the one every ledger screen
// invites: Dart deciding that ₹1,250 is "overdue", formatting a rupee, or
// pluralising "20 days". Every assertion below is that a STRING FROM THE
// PAYLOAD reached the screen unchanged — and, for the reminder, that the
// sentence the pharmacist approves is byte-for-byte the one the backend
// composed.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/pharmacy/khata_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _home({
  List<Map<String, dynamic>>? accounts,
  Map<String, dynamic>? collector,
}) => {
  'ok': true,
  'shop_name': 'Chandra Medicom',
  'labels': {
    'title': 'Khata',
    'outstanding': 'Outstanding',
    'add': 'New account',
    'search_hint': 'Search name or phone',
    'settings': 'Reminder settings',
    'retry': 'Retry',
    'load_failed': 'The khata book could not be loaded.',
    'save': 'Save',
    'cancel': 'Not now',
    'record_payment': 'Record payment',
    'amount': 'Amount',
    'note': 'Note',
    'name': 'Name',
    'phone': 'Phone',
    'limit': 'Credit limit (optional)',
  },
  'filters': [
    {'key': 'due', 'label': 'With balance', 'selected': true},
    {'key': 'all', 'label': 'All', 'selected': false},
  ],
  'totals': {
    'outstanding_display': '₹4,310.00',
    'accounts_label': '7 accounts',
    'due_label': '3 with a balance',
  },
  'collector': collector ?? {
    'title': 'Reminders',
    'enabled': false,
    'status_label': 'Off — no patient is messaged.',
    'status_tone': 'info',
    'sent_today_label': '0 sent today',
    'upi': {
      'has': false,
      'vpa': '',
      'label': 'Your UPI address',
      'hint': 'Reminders carry a pay link to THIS address.',
      'set_label': 'Save UPI address',
      'confirm_label': 'Yes, that is mine',
      'vpa_label': 'UPI ID (name@bank)',
      'name_label': 'Name shown to the patient',
    },
    'ladder': [],
  },
  'accounts': accounts ?? const [],
  'empty': {
    'title': 'No khata accounts yet',
    'hint': 'A bill saved on khata opens the account by itself.',
  },
  'methods': [
    {'key': 'cash', 'label': 'Cash'},
    {'key': 'upi', 'label': 'UPI'},
  ],
  'kinds': [
    {'key': 'patient', 'label': 'Patient'},
    {'key': 'doctor', 'label': 'Doctor'},
  ],
};

Map<String, dynamic> _acct(Map<String, dynamic> over) => {
  'id': 'acct-1',
  'name': 'Sunita Verma',
  'kind_label': 'Patient',
  'phone_display': '9876543210',
  'balance_display': '₹1,250.00',
  'age_label': '20 days old',
  'tone': 'warning',
  'settled': false,
  ...over,
};

Map<String, dynamic> _detail({
  Map<String, dynamic>? account,
  List<Map<String, dynamic>>? lines,
  bool canRemind = true,
}) => {
  'ok': true,
  'account': account ?? _acct(const {}),
  'labels': {
    'statement': 'Statement',
    'record_payment': 'Record payment',
    'statement_btn': 'Statement',
    'remind': 'Send reminder',
    'retry': 'Retry',
    'load_failed': 'The khata book could not be loaded.',
    'save': 'Save',
    'cancel': 'Not now',
    'amount': 'Amount',
    'note': 'Note',
  },
  'lines': lines ?? const [],
  'empty': {'title': 'No entries yet'},
  'can_remind': canRemind,
  'methods': [
    {'key': 'cash', 'label': 'Cash'},
    {'key': 'upi', 'label': 'UPI'},
  ],
};

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  Future<void> pump(WidgetTester t, Widget w) async {
    await t.pumpWidget(MaterialApp(home: w));
    await t.pumpAndSettle();
  }

  group('khata home', () {
    testWidgets('every figure on the summary is the payload\'s own string',
        (t) async {
      await pump(
        t,
        KhataScreen(rpc: (fn, p) async => _home()),
      );

      // Not "₹4310.0", not "4,310" — the backend's finished string.
      expect(find.text('₹4,310.00'), findsOneWidget);
      expect(find.text('7 accounts · 3 with a balance'), findsOneWidget);
      expect(find.text('Outstanding'), findsOneWidget);
    });

    testWidgets('an account row prints balance, age and kind verbatim',
        (t) async {
      await pump(
        t,
        KhataScreen(
          rpc: (fn, p) async => _home(accounts: [_acct(const {})]),
        ),
      );

      expect(find.text('Sunita Verma'), findsOneWidget);
      expect(find.text('₹1,250.00'), findsOneWidget);
      // The screen never computes an age from a date — it prints the sentence.
      expect(find.text('20 days old'), findsOneWidget);
      expect(find.text('Patient · 9876543210'), findsOneWidget);
    });

    testWidgets('a settled account keeps the BACKEND\'s word for it', (t) async {
      await pump(
        t,
        KhataScreen(
          rpc: (fn, p) async => _home(accounts: [
            _acct({
              'balance_display': '₹0.00',
              'age_label': 'Settled',
              'tone': 'success',
              'settled': true,
            }),
          ]),
        ),
      );

      expect(find.text('Settled'), findsOneWidget);
      // and it decided that from `age_label`, not from the balance being zero
      expect(find.text('₹0.00'), findsOneWidget);
    });

    testWidgets('the over-limit warning prints when the payload sent one',
        (t) async {
      await pump(
        t,
        KhataScreen(
          rpc: (fn, p) async => _home(accounts: [
            _acct({
              'over_limit': true,
              'limit_warning': 'Over the ₹1,000.00 limit — balance is ₹1,250.00',
            }),
          ]),
        ),
      );
      expect(
        find.text('Over the ₹1,000.00 limit — balance is ₹1,250.00'),
        findsOneWidget,
      );
    });

    // Deliberately its own test rather than a second pumpWidget in the one
    // above: pumping the same widget TYPE reuses the State, so the screen never
    // re-boots and the assertion passes against the first payload's data.
    testWidgets('...and is absent when the payload did not — a limit is never '
        'inferred from the balance', (t) async {
      await pump(
        t,
        KhataScreen(
          rpc: (fn, p) async => _home(accounts: [
            // a balance well above any plausible limit, and NO limit_warning
            _acct({'balance_display': '₹99,999.00'}),
          ]),
        ),
      );
      expect(find.text('₹99,999.00'), findsOneWidget);
      expect(find.textContaining('Over the'), findsNothing);
    });

    testWidgets('the empty state is the payload, not a Dart sentence',
        (t) async {
      await pump(t, KhataScreen(rpc: (fn, p) async => _home()));
      expect(find.text('No khata accounts yet'), findsOneWidget);
      expect(
        find.text('A bill saved on khata opens the account by itself.'),
        findsOneWidget,
      );
    });

    testWidgets('a refusal renders the backend message and no book', (t) async {
      await pump(
        t,
        KhataScreen(
          rpc: (fn, p) async => {
            'ok': false,
            'error': 'not_a_pharmacy',
            'message': 'The khata book belongs to a pharmacy account.',
          },
        ),
      );
      expect(
        find.text('The khata book belongs to a pharmacy account.'),
        findsOneWidget,
      );
      expect(find.text('Outstanding'), findsNothing);
    });

    testWidgets('the selected filter comes from the payload, not local state',
        (t) async {
      await pump(
        t,
        KhataScreen(
          rpc: (fn, p) async => _home(),
        ),
      );
      final due = t.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, 'With balance'),
      );
      final all = t.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, 'All'),
      );
      expect(due.selected, isTrue);
      expect(all.selected, isFalse);
    });

    testWidgets('the collector card shows the backend status, not an inference',
        (t) async {
      await pump(
        t,
        KhataScreen(
          rpc: (fn, p) async => _home(collector: {
            'title': 'Reminders',
            'enabled': true,
            'status_label':
                'On — a gentle note at 7 days, firmer at 15, a last one at 30.',
            'status_tone': 'success',
            'sent_today_label': '4 sent today',
            'upi': {
              'has': true,
              'vpa': 'chandra@upi',
              'verified': true,
              'label': 'Your UPI address',
              'hint': 'h',
              'set_label': 'Save UPI address',
              'confirm_label': 'Yes, that is mine',
              'vpa_label': 'UPI ID (name@bank)',
              'name_label': 'Name shown to the patient',
            },
            'ladder': [],
          }),
        ),
      );
      expect(
        find.text(
            'On — a gentle note at 7 days, firmer at 15, a last one at 30.'),
        findsOneWidget,
      );
      expect(find.text('chandra@upi'), findsOneWidget);
      expect(find.text('4 sent today'), findsOneWidget);
    });
  });

  group('one account', () {
    testWidgets('a ledger line prints its own signed amount and balance',
        (t) async {
      await pump(
        t,
        KhataAccountScreen(
          accountId: 'acct-1',
          rpc: (fn, p) async => _detail(lines: [
            {
              'id': 'e2',
              'type': 'payment',
              'type_label': 'Payment',
              'date_label': '28 Aug 2026',
              'amount_display': '- ₹400.00',
              'tone': 'success',
              'balance_display': '₹850.00',
              'method_label': 'Cash',
            },
            {
              'id': 'e1',
              'type': 'sale',
              'type_label': 'Credit sale',
              'date_label': '20 Aug 2026',
              'amount_display': '+ ₹1,250.00',
              'tone': 'info',
              'balance_display': '₹1,250.00',
              'note': 'Bill JM/2026-27/00042',
            },
          ]),
        ),
      );

      // The sign is the backend's, including the space after it.
      expect(find.text('- ₹400.00'), findsOneWidget);
      expect(find.text('+ ₹1,250.00'), findsOneWidget);
      expect(find.text('₹850.00'), findsOneWidget);
      expect(find.text('Payment'), findsOneWidget);
      expect(find.text('Credit sale'), findsOneWidget);
      expect(
        find.text('20 Aug 2026 · Bill JM/2026-27/00042'),
        findsOneWidget,
      );
    });

    testWidgets('rows render in payload order — no client-side sort', (t) async {
      await pump(
        t,
        KhataAccountScreen(
          accountId: 'acct-1',
          rpc: (fn, p) async => _detail(lines: [
            {
              'id': 'b',
              'type_label': 'Payment',
              'date_label': '28 Aug 2026',
              'amount_display': '- ₹400.00',
              'tone': 'success',
              'balance_display': '₹850.00',
            },
            {
              'id': 'a',
              'type_label': 'Credit sale',
              'date_label': '20 Aug 2026',
              'amount_display': '+ ₹1,250.00',
              'tone': 'info',
              'balance_display': '₹1,250.00',
            },
          ]),
        ),
      );
      final payY = t.getTopLeft(find.text('Payment')).dy;
      final saleY = t.getTopLeft(find.text('Credit sale')).dy;
      expect(payY, lessThan(saleY));
    });

    testWidgets('Send reminder is disabled when the backend says it cannot',
        (t) async {
      await pump(
        t,
        KhataAccountScreen(
          accountId: 'acct-1',
          rpc: (fn, p) async => _detail(canRemind: false),
        ),
      );
      final btn = t.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Send reminder'),
      );
      expect(btn.onPressed, isNull);
    });

    testWidgets(
        'the reminder preview shows the composed sentence verbatim, UPI link included',
        (t) async {
      const composed =
          'Namaste Sunita Verma, ₹1,250.00 has been pending on your khata at '
          'Chandra Medicom for 20 days. Kindly clear it at your convenience: '
          'upi://pay?pa=chandra@upi&pn=Chandra Medicom&am=1250.00&cu=INR. '
          'Do call us if there is any difficulty.';

      await pump(
        t,
        KhataAccountScreen(
          accountId: 'acct-1',
          rpc: (fn, p) async {
            if (fn == 'khata_reminder_compose') {
              return {
                'ok': true,
                'stage': 2,
                'stage_label': 'Firmer — 15 days',
                'body': composed,
                'can_send': true,
                'preview_label': 'This is exactly what will be sent',
              };
            }
            return _detail();
          },
        ),
      );

      await t.tap(find.widgetWithText(OutlinedButton, 'Send reminder'));
      await t.pumpAndSettle();

      // Not a summary of it, not a re-wrap of it — the sentence itself.
      expect(find.text(composed), findsOneWidget);
      expect(find.text('Firmer — 15 days'), findsOneWidget);
      expect(find.text('This is exactly what will be sent'), findsOneWidget);
    });

    testWidgets('a blocked preview shows the reason and refuses to send',
        (t) async {
      await pump(
        t,
        KhataAccountScreen(
          accountId: 'acct-1',
          rpc: (fn, p) async {
            if (fn == 'khata_reminder_compose') {
              return {
                'ok': true,
                'stage': 1,
                'stage_label': 'Gentle — 7 days',
                'body': 'body',
                'can_send': false,
                'preview_label': 'This is exactly what will be sent',
                'blocked_reason':
                    'Add and confirm your UPI address to start sending.',
              };
            }
            return _detail();
          },
        ),
      );

      await t.tap(find.widgetWithText(OutlinedButton, 'Send reminder'));
      await t.pumpAndSettle();

      expect(
        find.text('Add and confirm your UPI address to start sending.'),
        findsOneWidget,
      );
      final send = t.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Send reminder'),
      );
      expect(send.onPressed, isNull);
    });

    testWidgets('a payment posts type=payment and carries a client_action_id',
        (t) async {
      Map<String, dynamic>? sent;
      await pump(
        t,
        KhataAccountScreen(
          accountId: 'acct-1',
          rpc: (fn, p) async {
            if (fn == 'khata_entry_add') {
              sent = p;
              return {'ok': true, 'message': '₹400.00 received'};
            }
            return _detail();
          },
        ),
      );

      await t.tap(find.widgetWithText(FilledButton, 'Record payment'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField).first, '400');
      await t.tap(find.widgetWithText(FilledButton, 'Save'));
      await t.pumpAndSettle();

      expect(sent, isNotNull);
      expect(sent!['p_type'], 'payment');
      expect(sent!['p_amount'], 400);
      expect(sent!['p_account_id'], 'acct-1');
      // The replay key is minted on the device, before the network is known to
      // exist — that is what makes a tapped-twice Save one entry, not two.
      expect(sent!['p_client_action_id'], isA<String>());
      expect((sent!['p_client_action_id'] as String).length, 36);
    });

    testWidgets('a refused payment shows the backend message and stays open',
        (t) async {
      await pump(
        t,
        KhataAccountScreen(
          accountId: 'acct-1',
          rpc: (fn, p) async {
            if (fn == 'khata_entry_add') {
              return {
                'ok': false,
                'error': 'bad_amount',
                'message': 'Enter an amount above zero.',
              };
            }
            return _detail();
          },
        ),
      );

      await t.tap(find.widgetWithText(FilledButton, 'Record payment'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField).first, '5');
      await t.tap(find.widgetWithText(FilledButton, 'Save'));
      await t.pumpAndSettle();

      expect(find.text('Enter an amount above zero.'), findsOneWidget);
      // still on the sheet, so the operator can correct it
      expect(find.widgetWithText(FilledButton, 'Save'), findsOneWidget);
    });
  });
}
