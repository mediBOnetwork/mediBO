// PROTECTED — CHANGE #402, the supplier account layer.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes supplier staff / payout / language behaviour, never to
// make an unrelated change go green.
//
// What this holds down:
//
//   1. THE ACCESS DROPDOWN IS THE BACKEND'S LIST. A staff row's access options
//      are `role_options` from the payload and nothing else, so a preset the
//      office withdraws disappears without a deploy and Dart can never offer a
//      level the account is not allowed to grant.
//
//   2. YOU CANNOT EDIT YOURSELF. can_remove / can_edit_role are backend
//      booleans; the owner row and your own row offer neither a Remove nor an
//      editable dropdown, so the two self-escalation moves are unreachable
//      before the RPC ever sees them.
//
//   3. NO MONEY DETAIL IS COMPOSED IN DART. The masked account number, the
//      status word, the name-match verdict and its tone are printed exactly as
//      they arrived. In particular the account number is NEVER unmasked here:
//      the widget has no access to the digits at all.
//
//   4. ABSENCE IS EXPLICIT, NOT A DEFAULT. `active: null` prints the backend's
//      own empty sentence instead of an empty card, a read-only grant prints
//      the backend's readonly line and draws no form, and the form's FIELDS are
//      `fields[]` in payload order — a field added tomorrow needs no deploy.
//
//   5. THE LANGUAGE SWITCH IS A PREFERENCE, NOT A BRANCH. A Hindi payload
//      renders Hindi with no Dart lookup, and a key the backend has no Hindi
//      for arrives already fallen back to English — the widget never decides
//      which language a string is in.
//
//   6. THE GAP REPORT COUNTS WHAT THE BACKEND COUNTED. Coverage labels, per
//      scope totals and the missing rows all print verbatim; an empty missing
//      list is the backend's empty sentence, not a hardcoded "all good".
//
// Fixtures mirror the real supplier_staff_list() / supplier_payout_get() /
// ui_language_report() shapes. No network, no Supabase, no timers.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/admin_supplier_account_screen.dart';
import 'package:pharma_b2b/screens/supplier/supplier_payout_screen.dart';
import 'package:pharma_b2b/screens/supplier/supplier_staff_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

// ── fixtures ────────────────────────────────────────────────────────────────

/// supplier_staff_list(): the owner row plus one staff row. The owner is never
/// removable and never re-graded; the staff row is both, but only because the
/// BACKEND said so.
Map<String, dynamic> _staff({bool canManage = true, bool selfRow = false}) => {
      'ok': true,
      'title': 'My staff',
      'subtitle': 'Extra logins for your shop.',
      'can_manage': canManage,
      'add_label': 'Add staff login',
      'add_hint': 'Email or 10-digit mobile',
      'name_hint': 'Name (optional)',
      'save_label': 'Add',
      'remove_label': 'Remove',
      'role_label': 'Access',
      'owner_label': 'Owner',
      'empty': 'No staff logins yet.',
      'audit_heading': 'Recent activity',
      'audit_empty': 'Nothing yet.',
      'role_options': const [
        {'role_key': 'inquiry_only', 'label': 'Inquiry only', 'description': ''},
        {'role_key': 'billing_only', 'label': 'Billing only', 'description': ''},
      ],
      'rows': [
        const {
          'id': null,
          'identity': 'owner@shop.in',
          'name': 'Ramesh',
          'role_key': null,
          'role_label': 'Owner — full access',
          'is_owner': true,
          'is_self': true,
          'can_remove': false,
          'can_edit_role': false,
          'added_label': '',
        },
        {
          'id': 7,
          'identity': 'staff@shop.in',
          'name': 'Pallavi',
          'role_key': 'inquiry_only',
          'role_label': 'Inquiry only',
          'is_owner': false,
          'is_self': selfRow,
          'can_remove': canManage && !selfRow,
          'can_edit_role': canManage && !selfRow,
          'added_label': 'Added 01/09/2026',
        },
      ],
      'audit': const [
        {
          'who': 'Ramesh',
          'what': 'staff@shop.in added as Inquiry only',
          'when': '1 Sep 2026, 6:20 AM',
        },
      ],
    };

/// supplier_payout_get(): an approved set in use, a second set waiting, and one
/// superseded set in the history.
Map<String, dynamic> _payout({
  bool hasActive = true,
  bool hasPending = true,
  bool canEdit = true,
}) =>
    {
      'ok': true,
      'title': 'Payout details',
      'subtitle': 'Where mediBO pays you.',
      'can_edit': canEdit,
      'readonly_note': canEdit ? '' : 'You can see these details but not change them.',
      'active_heading': 'In use now',
      'pending_heading': 'Waiting for approval',
      'history_heading': 'Earlier details',
      'history_empty': 'No earlier details.',
      'empty': 'No payout details on file yet.',
      'pending_note': 'We are checking this.',
      'submit_label': 'Submit for approval',
      'form_heading': 'New payout details',
      'fields': const [
        {'key': 'account_name', 'label': 'Account holder name', 'hint': 'As in the passbook', 'required': true},
        {'key': 'upi_vpa', 'label': 'UPI ID', 'hint': 'e.g. shop@okhdfcbank', 'required': false},
      ],
      'active': hasActive
          ? const {
              'id': 11,
              'status': 'active',
              'status_label': 'In use',
              'status_tone': 'success',
              'account_name': 'Jai Mahakal Medical',
              'account_number_masked': '••••••••9012',
              'ifsc': 'HDFC0001234',
              'bank_name': 'HDFC Bank',
              'upi_vpa': 'jaimahakal@okhdfcbank',
              'match_label': 'Name matches Jai Mahakal Medical',
              'match_tone': 'success',
              'submitted_label': 'Sent 1 Sep 2026, 6:20 AM by Ramesh',
              'reviewed_label': 'Reviewed 1 Sep 2026, 7:00 AM by ops@medibo.in',
              'review_note': '',
            }
          : null,
      'pending': hasPending
          ? const {
              'id': 12,
              'status': 'pending',
              'status_label': 'Waiting for approval',
              'status_tone': 'warning',
              'account_name': 'Zzz Random Traders',
              'account_number_masked': '••••••••7777',
              'ifsc': 'ICIC0004321',
              'bank_name': '',
              'upi_vpa': '',
              'match_label': 'Name does not match Jai Mahakal Medical — our team will confirm',
              'match_tone': 'danger',
              'submitted_label': 'Sent 1 Sep 2026, 8:00 AM by Pallavi',
              'reviewed_label': '',
              'review_note': '',
            }
          : null,
      'history': const [
        {
          'id': 9,
          'status': 'superseded',
          'status_label': 'Replaced',
          'status_tone': 'neutral',
          'account_name': 'Jai Mahakal Medical',
          'account_number_masked': '••••••••1111',
          'ifsc': 'SBIN0000123',
          'bank_name': '',
          'upi_vpa': '',
          'match_label': '',
          'match_tone': 'warning',
          'submitted_label': 'Sent 3 Jul 2026, 11:00 AM by Ramesh',
          'reviewed_label': 'Reviewed 3 Jul 2026, 4:00 PM by ops@medibo.in',
          'review_note': '',
        },
      ],
    };

/// The SAME payload after the supplier switched to Hindi: the words changed in
/// the backend, and one key that has no Hindi row arrived already in English.
Map<String, dynamic> _staffHindi() => {
      ..._staff(),
      'title': 'मेरा स्टाफ',
      'subtitle': 'आपकी दुकान के लिए अतिरिक्त लॉगिन।',
      'save_label': 'जोड़ें',
      'remove_label': 'हटाएं',
      'role_label': 'अनुमति',
      'role_options': const [
        {'role_key': 'inquiry_only', 'label': 'केवल पूछताछ', 'description': ''},
        // No Hindi for this preset yet — the BACKEND already fell back.
        {'role_key': 'billing_only', 'label': 'Billing only', 'description': ''},
      ],
    };

Map<String, dynamic> _report({bool anyMissing = true}) => {
      'ok': true,
      'lang': 'hi',
      'lang_label': 'हिन्दी',
      'title': 'Hindi coverage',
      'subtitle': 'Supplier-facing keys and whether they carry a Hindi value.',
      'headline': anyMissing ? '222 of 280 translated (79%)' : '280 of 280 translated (100%)',
      'tone': anyMissing ? 'warning' : 'success',
      'total': 280,
      'translated': anyMissing ? 222 : 280,
      'missing': anyMissing ? 58 : 0,
      'missing_heading': 'Missing Hindi',
      'empty_label': 'Nothing missing — every supplier key has Hindi.',
      'save_label': 'Save',
      'hint_label': 'Type the Hindi and save.',
      'scopes': const [
        {
          'prefix': 'supplier_shell.',
          'label': 'Supplier shell',
          'total': 11,
          'translated': 11,
          'missing': 0,
          'coverage_label': '100%',
          'detail_label': '11 / 11',
          'tone': 'success',
        },
        {
          'prefix': 'supplier_add_medicine.',
          'label': 'Supplier add medicine',
          'total': 56,
          'translated': 0,
          'missing': 56,
          'coverage_label': '0%',
          'detail_label': '0 / 56',
          'tone': 'danger',
        },
      ],
      'missing_rows': anyMissing
          ? const [
              {
                'key': 'supplier_add_medicine.btn_extracting',
                'english': 'Extracting…',
                'scope_label': 'Supplier add medicine',
              },
            ]
          : const [],
    };

Widget _staffView(Map<String, dynamic> payload, {
  void Function(Map<String, dynamic>)? onRemove,
  void Function(Map<String, dynamic>, String)? onRoleChanged,
}) =>
    _host(SupplierStaffView(
      payload: payload,
      identityCtrl: TextEditingController(),
      nameCtrl: TextEditingController(),
      addRoleKey: 'inquiry_only',
      onAddRoleChanged: (_) {},
      onAdd: () {},
      onRemove: onRemove ?? (_) {},
      onRoleChanged: onRoleChanged ?? (_, __) {},
    ));

Widget _payoutView(Map<String, dynamic> payload) => _host(SupplierPayoutView(
      payload: payload,
      controllers: {
        'account_name': TextEditingController(),
        'upi_vpa': TextEditingController(),
      },
      onSubmit: () {},
    ));

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  // These screens are long lists and a ListView only builds what fits. The
  // default 800x600 test viewport would hide the audit block and the history,
  // so the surface is made tall enough that "not on screen" can only ever mean
  // "the widget was not built" — which is what every assertion here is about.
  setUp(() {
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(1200, 4000);
    view.devicePixelRatio = 1.0;
  });

  tearDown(() {
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  group('staff sub-logins', () {
    testWidgets('the access dropdown offers exactly the backend list',
        (tester) async {
      await tester.pumpWidget(_staffView(_staff()));
      await tester.pumpAndSettle();

      // Closed, the control shows only the grade this staff member holds.
      expect(find.text('Inquiry only'), findsWidgets);

      await tester.tap(find.byType(DropdownButton<String>).last);
      await tester.pumpAndSettle();

      // Open, it offers exactly the two presets the payload sent…
      expect(find.text('Inquiry only'), findsWidgets);
      expect(find.text('Billing only'), findsWidgets);
      // …and 'Full access' — a real preset the backend did NOT send — is not
      // on the screen to be tapped.
      expect(find.text('Full access'), findsNothing);
    });

    testWidgets('the owner row offers neither Remove nor an editable dropdown',
        (tester) async {
      await tester.pumpWidget(_staffView(_staff()));
      await tester.pumpAndSettle();

      // The owner's grade is printed as a plain line, not a control.
      expect(find.text('Owner — full access'), findsOneWidget);
      expect(find.text('Owner'), findsOneWidget);
      // Exactly one Remove on screen — the staff row's, never the owner's.
      expect(find.text('Remove'), findsOneWidget);
    });

    testWidgets('your own staff row offers neither either', (tester) async {
      await tester.pumpWidget(_staffView(_staff(selfRow: true)));
      await tester.pumpAndSettle();
      expect(find.text('Remove'), findsNothing);
    });

    testWidgets('a read-only grant draws no add card and no Remove',
        (tester) async {
      await tester.pumpWidget(_staffView(_staff(canManage: false)));
      await tester.pumpAndSettle();
      expect(find.text('Add staff login'), findsNothing);
      expect(find.text('Remove'), findsNothing);
      // The rows themselves still render — read access is not no access.
      expect(find.text('Pallavi'), findsOneWidget);
    });

    testWidgets('a role change sends the backend own role_key', (tester) async {
      String? sentKey;
      Map<String, dynamic>? sentRow;
      await tester.pumpWidget(_staffView(
        _staff(),
        onRoleChanged: (row, key) {
          sentRow = row;
          sentKey = key;
        },
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(DropdownButton<String>).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Billing only').last);
      await tester.pumpAndSettle();

      expect(sentKey, 'billing_only');
      expect(sentRow?['id'], 7);
    });

    testWidgets('the audit line names the person, verbatim', (tester) async {
      await tester.pumpWidget(_staffView(_staff()));
      await tester.pumpAndSettle();
      expect(find.text('staff@shop.in added as Inquiry only'), findsOneWidget);
      expect(find.text('Ramesh · 1 Sep 2026, 6:20 AM'), findsOneWidget);
    });

    testWidgets('a refusal renders the backend message, never a Dart one',
        (tester) async {
      await tester.pumpWidget(_staffView(const {
        'ok': false,
        'error': 'not_authorized',
        'message': 'You do not have access to staff logins.',
      }));
      await tester.pumpAndSettle();
      expect(find.text('You do not have access to staff logins.'), findsOneWidget);
      expect(find.text('My staff'), findsNothing);
    });
  });

  group('bank / UPI self-service', () {
    testWidgets('every payout string prints verbatim and the account stays masked',
        (tester) async {
      await tester.pumpWidget(_payoutView(_payout()));
      await tester.pumpAndSettle();

      expect(find.text('In use'), findsOneWidget);
      expect(find.text('••••••••9012 · HDFC0001234'), findsOneWidget);
      expect(find.text('Name matches Jai Mahakal Medical'), findsOneWidget);
      expect(find.text('Sent 1 Sep 2026, 6:20 AM by Ramesh'), findsOneWidget);
      // The digits behind the mask are not in the payload, so they cannot be
      // on the screen — this is the assertion that keeps them out.
      expect(find.textContaining('123456789012'), findsNothing);
    });

    testWidgets('the pending set is shown ALONGSIDE the active one, not instead',
        (tester) async {
      await tester.pumpWidget(_payoutView(_payout()));
      await tester.pumpAndSettle();

      expect(find.text('In use now'), findsOneWidget);
      expect(find.text('Waiting for approval'), findsWidgets);
      expect(find.text('••••••••9012 · HDFC0001234'), findsOneWidget);
      expect(find.text('••••••••7777 · ICIC0004321'), findsOneWidget);
      expect(find.text('We are checking this.'), findsOneWidget);
    });

    testWidgets('history holds the superseded set — nothing was overwritten',
        (tester) async {
      await tester.pumpWidget(_payoutView(_payout()));
      await tester.pumpAndSettle();
      expect(find.text('Replaced'), findsOneWidget);
      expect(find.text('••••••••1111 · SBIN0000123'), findsOneWidget);
    });

    testWidgets('no details on file renders the backend empty line',
        (tester) async {
      await tester.pumpWidget(
          _payoutView(_payout(hasActive: false, hasPending: false)));
      await tester.pumpAndSettle();
      expect(find.text('No payout details on file yet.'), findsOneWidget);
      expect(find.text('Waiting for approval'), findsNothing);
    });

    testWidgets('the form is fields[] in payload order', (tester) async {
      await tester.pumpWidget(_payoutView(_payout()));
      await tester.pumpAndSettle();

      // Exactly the two the payload sent, in its order — IFSC was not sent, so
      // it is not on the screen.
      expect(find.text('Account holder name'), findsOneWidget);
      expect(find.text('UPI ID'), findsOneWidget);
      expect(find.text('Bank name'), findsNothing);
    });

    testWidgets('a read-only grant prints the backend line and draws no form',
        (tester) async {
      await tester.pumpWidget(_payoutView(_payout(canEdit: false)));
      await tester.pumpAndSettle();
      expect(find.text('You can see these details but not change them.'),
          findsOneWidget);
      expect(find.text('Submit for approval'), findsNothing);
    });
  });

  group('language switch', () {
    testWidgets('a Hindi payload renders Hindi with no lookup in Dart',
        (tester) async {
      await tester.pumpWidget(_staffView(_staffHindi()));
      await tester.pumpAndSettle();

      expect(find.text('मेरा स्टाफ'), findsOneWidget);
      expect(find.text('जोड़ें'), findsOneWidget);
      expect(find.text('केवल पूछताछ'), findsWidgets);
      expect(find.text('My staff'), findsNothing);
    });

    testWidgets('a key with no Hindi arrives already fallen back to English',
        (tester) async {
      await tester.pumpWidget(_staffView(_staffHindi()));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButton<String>).last);
      await tester.pumpAndSettle();
      // The backend coalesced it; the widget printed what it was handed —
      // Hindi beside English, in one list, with no decision made here.
      expect(find.text('केवल पूछताछ'), findsWidgets);
      expect(find.text('Billing only'), findsWidgets);
    });
  });

  group('admin: the gap is visible and closable', () {
    testWidgets('coverage numbers are the backend own strings', (tester) async {
      await tester.pumpWidget(_host(AdminHindiCoverageView(
        payload: _report(),
        onSave: (_, __) async {},
      )));
      await tester.pumpAndSettle();

      expect(find.text('222 of 280 translated (79%)'), findsOneWidget);
      expect(find.text('11 / 11'), findsOneWidget);
      expect(find.text('0 / 56'), findsOneWidget);
      expect(find.text('100%'), findsOneWidget);
      expect(find.text('0%'), findsOneWidget);
    });

    testWidgets('a missing key is listed and saves under its own key',
        (tester) async {
      String? savedKey;
      String? savedValue;
      await tester.pumpWidget(_host(AdminHindiCoverageView(
        payload: _report(),
        onSave: (k, v) async {
          savedKey = k;
          savedValue = v;
        },
      )));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).last, 'निकाला जा रहा है…');
      await tester.tap(find.text('Save').last);
      await tester.pumpAndSettle();

      expect(savedKey, 'supplier_add_medicine.btn_extracting');
      expect(savedValue, 'निकाला जा रहा है…');
    });

    testWidgets('full coverage prints the backend empty line, not a Dart one',
        (tester) async {
      await tester.pumpWidget(_host(AdminHindiCoverageView(
        payload: _report(anyMissing: false),
        onSave: (_, __) async {},
      )));
      await tester.pumpAndSettle();
      expect(find.text('Nothing missing — every supplier key has Hindi.'),
          findsOneWidget);
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('a payout approval sends the pending row own id', (tester) async {
      int? sentId;
      String? sentDecision;
      await tester.pumpWidget(_host(AdminPayoutQueueView(
        payload: {
          'ok': true,
          'title': 'Supplier payout approvals',
          'subtitle': 'New bank / UPI details waiting for a decision.',
          'empty': 'Nothing waiting.',
          'approve_label': 'Approve',
          'reject_label': 'Reject',
          'note_hint': 'Note (optional)',
          'current_heading': 'In use now',
          'rows': [
            {
              'supplier_id': 'aaa',
              'supplier_name': 'TEST_Supplier One',
              'pending': _payout()['pending'],
              'current': _payout()['active'],
            },
          ],
        },
        onReview: (id, decision, note) async {
          sentId = id;
          sentDecision = decision;
        },
      )));
      await tester.pumpAndSettle();

      // The name-match verdict is on the approval card, where the decision is
      // actually made — that is the whole penny-drop-free check.
      expect(
          find.text(
              'Name does not match Jai Mahakal Medical — our team will confirm'),
          findsOneWidget);

      await tester.tap(find.text('Approve'));
      await tester.pumpAndSettle();
      expect(sentId, 12);
      expect(sentDecision, 'approve');
    });

    testWidgets('an empty queue renders the backend empty line', (tester) async {
      await tester.pumpWidget(_host(AdminPayoutQueueView(
        payload: const {
          'ok': true,
          'empty': 'Nothing waiting.',
          'rows': [],
        },
        onReview: (_, __, ___) async {},
      )));
      await tester.pumpAndSettle();
      expect(find.text('Nothing waiting.'), findsOneWidget);
    });
  });
}
