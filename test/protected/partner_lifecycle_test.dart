// CMD #466 — the partner lifecycle layer, on the three surfaces it lives on.
//
// Holds down: a partner's STATUS, their LICENCE EXPIRY and their SETTLEMENT
// DOCUMENT are backend payloads printed verbatim. The three defects this
// retires (feature_gaps 150 / 153 / 154) were all "the app decides", so what is
// asserted here is that it does not:
//
//   • the status chip, its tone, and the three consequence blocks (routing,
//     work in hand, open balance) are the payload's strings — including the
//     count and the rupee amount inside them, which are never formatted here;
//   • Suspend / Resume appear only on `can_act`, and which of the two is drawn
//     is `is_suspended` — never inferred from anything else;
//   • a licence row prints `expiry_label` and `tone` as sent, and the "Set
//     expiry" affordance follows `can_edit`, so a partner login sees the dates
//     and cannot change them;
//   • the statement offers its document only on document.has, and the GST card
//     draws the backend's OWN line list — a registered partner sees the tax
//     ladder, an unregistered one sees only the note, and no rate is computed
//     in Dart.
//
// No network, no Supabase: the PartnerRpc seam answers every call inline.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/admin_partner_console_screen.dart';
import 'package:pharma_b2b/screens/partner/partner_statement_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _lifecycle({
  bool suspended = false,
  bool canAct = true,
}) => {
      'ok': true,
      'partner_id': 1,
      'partner_name': 'STANDIN_PARTNER',
      'heading': 'STANDIN_STATUS_HEADING',
      'status': suspended ? 'suspended' : 'active',
      'status_tone': suspended ? 'danger' : 'success',
      'status_label': suspended ? 'STANDIN_SUSPENDED' : 'STANDIN_ACTIVE',
      'is_suspended': suspended,
      'can_act': canAct,
      'suspend_label': 'STANDIN_SUSPEND_BTN',
      'resume_label': 'STANDIN_RESUME_BTN',
      'reason_hint': 'STANDIN_REASON_HINT',
      'suspend_reason': suspended ? 'STANDIN_REASON' : '',
      'suspended_since': suspended ? 'STANDIN_SINCE' : '',
      'has_replacement': false,
      'blocks': [
        {
          'key': 'routing',
          'heading': 'STANDIN_ROUTING_HEAD',
          'text': 'STANDIN_ROUTING_TEXT',
          'tone': 'info',
        },
        {
          'key': 'inflight',
          'heading': 'STANDIN_INFLIGHT_HEAD',
          'count': 31,
          'text': 'STANDIN_INFLIGHT_TEXT_31',
          'tone': 'warning',
        },
        {
          'key': 'balance',
          'heading': 'STANDIN_BALANCE_HEAD',
          'count': 2,
          'amount': 'STANDIN_AMOUNT',
          'text': 'STANDIN_BALANCE_TEXT',
          'tone': 'info',
        },
      ],
    };

Map<String, dynamic> _licences({bool canEdit = true}) => {
      'ok': true,
      'heading': 'STANDIN_LIC_HEADING',
      'sub': 'STANDIN_LIC_SUB',
      'set_label': 'STANDIN_SET_EXPIRY',
      'can_edit': canEdit,
      'alert_label': 'STANDIN_LIC_ALERT',
      'alert_tone': 'warning',
      'rows': [
        {
          'kind': 'dl_20b',
          'label': 'STANDIN_DL20B',
          'number': 'STANDIN_DL20B_NO',
          'has_number': true,
          'expiry_iso': '2026-09-13',
          'expiry_label': 'STANDIN_DL20B_EXPIRY',
          'tone': 'warning',
          'can_edit': canEdit,
        },
        {
          'kind': 'agreement',
          'label': 'STANDIN_AGREEMENT',
          'number': 'STANDIN_NO_NUMBER',
          'has_number': false,
          'expiry_iso': null,
          'expiry_label': 'STANDIN_NO_EXPIRY',
          'tone': 'neutral',
          'can_edit': canEdit,
        },
      ],
    };

Map<String, dynamic> _console({
  Map<String, dynamic>? lifecycle,
  Map<String, dynamic>? licences,
}) => {
      'ok': true,
      'partner_id': 1,
      'users_title': 'STANDIN_USERS',
      'users_subtitle': '',
      'empty_users': 'STANDIN_EMPTY_USERS',
      'add_label': 'STANDIN_ADD',
      'add_hint': '',
      'name_hint': '',
      'remove_label': 'STANDIN_REMOVE',
      'perm_title': 'STANDIN_PERMS',
      'perm_subtitle': '',
      'zone_locked_label': 'STANDIN_ZONE_LOCKED',
      'audit_title': 'STANDIN_AUDIT',
      'empty_audit': 'STANDIN_EMPTY_AUDIT',
      'users': const [],
      'features': const [],
      'audit': const [],
      if (lifecycle != null) 'lifecycle': lifecycle,
      if (licences != null) 'licences': licences,
    };

Future<void> _pumpConsole(
  WidgetTester tester,
  Map<String, dynamic> payload, {
  void Function(Map<String, dynamic>)? onSuspend,
  VoidCallback? onResume,
  void Function(Map<String, dynamic>)? onLicence,
}) async {
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: PartnerConsoleView(
        payload: payload,
        identity: TextEditingController(),
        name: TextEditingController(),
        onAdd: () {},
        onRemove: (_) {},
        onAccess: (_, __) {},
        onSuspend: onSuspend,
        onResume: onResume,
        onLicence: onLicence,
      ),
    ),
  ));
  await tester.pump();
}

Map<String, dynamic> _statement({
  bool hasDocument = true,
  bool registered = true,
}) => {
      'ok': true,
      'subtitle': 'STANDIN_STMT_SUBTITLE',
      'footnote': 'STANDIN_STMT_FOOTNOTE',
      'empty_text': 'STANDIN_STMT_EMPTY',
      'partner': 'STANDIN_PARTNER',
      'periods': {
        'heading': 'STANDIN_PERIODS',
        'empty_text': 'STANDIN_PERIODS_EMPTY',
        'rows': const [],
      },
      'document': {
        'has': hasDocument,
        'kind': 'statement',
        'ref': '10',
        'title': 'STANDIN_DOC_TITLE',
        'button_label': 'STANDIN_DOWNLOAD',
        'building_message': 'STANDIN_BUILDING',
        'ready_message': 'STANDIN_READY',
        'error_message': 'STANDIN_DOC_ERROR',
      },
      'gst': {
        'heading': 'STANDIN_GST_HEADING',
        'registered': registered,
        'note': registered ? 'STANDIN_GST_NOTE_REG' : 'STANDIN_GST_NOTE_UNREG',
        'lines': registered
            ? const [
                {'label': 'STANDIN_TAXABLE_LBL', 'value': 'STANDIN_TAXABLE_VAL'},
                {'label': 'STANDIN_CGST_LBL', 'value': 'STANDIN_CGST_VAL'},
                {
                  'label': 'STANDIN_TOTAL_LBL',
                  'value': 'STANDIN_TOTAL_VAL',
                  'bold': true,
                },
              ]
            : const [],
      },
      'statement': null,
    };

int _pumpSeq = 0;

Future<void> _pumpStatement(
    WidgetTester tester, Map<String, dynamic> payload) async {
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: PartnerStatementScreen(
        // A fresh key each pump, so re-pumping in one test genuinely rebuilds
        // the screen instead of reusing the previous payload's State.
        key: ValueKey('stmt_${_pumpSeq++}'),
        rpc: (fn, params) async => payload,
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('CMD #466 row 154 — the partner status card', () {
    testWidgets('status, tone and all three consequence blocks print verbatim',
        (tester) async {
      await _pumpConsole(tester, _console(lifecycle: _lifecycle()));

      expect(find.text('STANDIN_STATUS_HEADING'), findsOneWidget);
      expect(find.text('STANDIN_ACTIVE'), findsOneWidget);
      expect(find.text('STANDIN_PARTNER'), findsOneWidget);

      // The consequences the register said were undefined — including the
      // count and the rupee amount, which arrive already inside the sentence.
      expect(find.text('STANDIN_ROUTING_HEAD'), findsOneWidget);
      expect(find.text('STANDIN_ROUTING_TEXT'), findsOneWidget);
      expect(find.text('STANDIN_INFLIGHT_HEAD'), findsOneWidget);
      expect(find.text('STANDIN_INFLIGHT_TEXT_31'), findsOneWidget);
      expect(find.text('STANDIN_BALANCE_HEAD'), findsOneWidget);
      expect(find.text('STANDIN_BALANCE_TEXT'), findsOneWidget);
      expect(find.text('STANDIN_AMOUNT'), findsOneWidget);
    });

    testWidgets('which button is drawn is is_suspended, never inferred',
        (tester) async {
      await _pumpConsole(tester, _console(lifecycle: _lifecycle()),
          onSuspend: (_) {}, onResume: () {});
      expect(find.byKey(const ValueKey('partner_suspend')), findsOneWidget);
      expect(find.byKey(const ValueKey('partner_resume')), findsNothing);
      expect(find.text('STANDIN_SUSPEND_BTN'), findsOneWidget);

      await _pumpConsole(
          tester, _console(lifecycle: _lifecycle(suspended: true)),
          onSuspend: (_) {}, onResume: () {});
      expect(find.byKey(const ValueKey('partner_resume')), findsOneWidget);
      expect(find.byKey(const ValueKey('partner_suspend')), findsNothing);
      expect(find.text('STANDIN_RESUME_BTN'), findsOneWidget);
      // and the suspension says who and why, in the backend's words
      expect(find.text('STANDIN_SINCE'), findsOneWidget);
      expect(find.text('STANDIN_REASON'), findsOneWidget);
    });

    testWidgets('can_act false offers no action at all', (tester) async {
      await _pumpConsole(
          tester, _console(lifecycle: _lifecycle(canAct: false)),
          onSuspend: (_) {}, onResume: () {});
      expect(find.byKey(const ValueKey('partner_suspend')), findsNothing);
      expect(find.byKey(const ValueKey('partner_resume')), findsNothing);
      // the status itself is still readable
      expect(find.text('STANDIN_ACTIVE'), findsOneWidget);
    });

    testWidgets('a payload with no lifecycle block draws no card',
        (tester) async {
      await _pumpConsole(tester, _console());
      expect(find.text('STANDIN_STATUS_HEADING'), findsNothing);
    });
  });

  group('CMD #466 row 153 — licence expiry', () {
    testWidgets('every row prints the backend expiry line and alert',
        (tester) async {
      await _pumpConsole(tester, _console(licences: _licences()),
          onLicence: (_) {});
      expect(find.text('STANDIN_LIC_HEADING'), findsOneWidget);
      expect(find.text('STANDIN_LIC_ALERT'), findsOneWidget);
      expect(find.text('STANDIN_DL20B'), findsOneWidget);
      expect(find.text('STANDIN_DL20B_NO'), findsOneWidget);
      expect(find.text('STANDIN_DL20B_EXPIRY'), findsOneWidget);
      // an absent expiry is the backend's sentence, not a blank
      expect(find.text('STANDIN_NO_EXPIRY'), findsOneWidget);
      expect(find.text('STANDIN_NO_NUMBER'), findsOneWidget);
    });

    testWidgets('the Set-expiry affordance follows can_edit', (tester) async {
      await _pumpConsole(tester, _console(licences: _licences()),
          onLicence: (_) {});
      expect(find.text('STANDIN_SET_EXPIRY'), findsNWidgets(2));

      await _pumpConsole(
          tester, _console(licences: _licences(canEdit: false)),
          onLicence: (_) {});
      expect(find.text('STANDIN_SET_EXPIRY'), findsNothing);
      // the dates stay readable even when they cannot be changed
      expect(find.text('STANDIN_DL20B_EXPIRY'), findsOneWidget);
    });

    testWidgets('tapping a row hands back that row, not an index',
        (tester) async {
      Map<String, dynamic>? got;
      await _pumpConsole(tester, _console(licences: _licences()),
          onLicence: (r) => got = r);
      await tester.tap(find.text('STANDIN_SET_EXPIRY').first);
      await tester.pump();
      expect(got?['kind'], 'dl_20b');
      expect(got?['expiry_iso'], '2026-09-13');
    });
  });

  group('CMD #466 row 150 — the statement document and its GST block', () {
    testWidgets('the download button appears only on document.has',
        (tester) async {
      await _pumpStatement(tester, _statement());
      expect(find.text('STANDIN_DOWNLOAD'), findsOneWidget);

      await _pumpStatement(tester, _statement(hasDocument: false));
      expect(find.text('STANDIN_DOWNLOAD'), findsNothing);
    });

    testWidgets('a registered partner gets the backend tax ladder verbatim',
        (tester) async {
      await _pumpStatement(tester, _statement());
      expect(find.text('STANDIN_GST_HEADING'), findsOneWidget);
      expect(find.text('STANDIN_TAXABLE_LBL'), findsOneWidget);
      expect(find.text('STANDIN_TAXABLE_VAL'), findsOneWidget);
      expect(find.text('STANDIN_CGST_LBL'), findsOneWidget);
      expect(find.text('STANDIN_TOTAL_VAL'), findsOneWidget);
      expect(find.text('STANDIN_GST_NOTE_REG'), findsOneWidget);
    });

    testWidgets('an unregistered partner gets the note and no ladder',
        (tester) async {
      await _pumpStatement(tester, _statement(registered: false));
      expect(find.text('STANDIN_GST_NOTE_UNREG'), findsOneWidget);
      expect(find.text('STANDIN_TAXABLE_LBL'), findsNothing);
      expect(find.text('STANDIN_CGST_LBL'), findsNothing);
    });
  });
}
