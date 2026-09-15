// PROTECTED — CHANGE #692, partner onboarding: the agreement e-sign, the KYC
// documents, and the go-live gate.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes this behaviour, never to make an unrelated change go
// green.
//
// What this holds down:
//
//   1. THE GATE IS A SENTENCE, NOT A SUM. `blocking_reason` and every blocker
//      line print exactly as they arrived. The fixture deliberately sends a
//      reason that does NOT match its own counts, so a screen that re-composed
//      "3 documents outstanding" from the rows would fail here.
//
//   2. SIGNED IS A FLAG. `is_signed` / `can_sign` decide the button and the
//      chip — never the presence of a signer name, never a date compared in
//      Dart. An already-signed agreement offers no Sign button even though the
//      body and the version line are still on the screen.
//
//   3. A VERIFIED DOCUMENT CANNOT BE RE-UPLOADED FROM THE SCREEN, because the
//      BACKEND said can_upload:false. A rejected one can, and prints the
//      backend's own reject_line rather than a reason assembled here.
//
//   4. THE E-SIGN IS TWO CALLS AND THE SECOND ONE CARRIES ONLY THE CODE. Start
//      sends signer_name + phone; verify sends the code. The screen never
//      sends the OTP anywhere else and never marks itself signed locally — it
//      reloads and renders whatever the backend then says.
//
//   5. ROWS RENDER IN PAYLOAD ORDER. The fixture is deliberately not
//      alphabetical, so a client-side sort fails.
//
// Fixtures mirror the real partner_documents_screen() shape. No network, no
// Supabase, no timers.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/partner/partner_documents_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

/// The blocked state: nothing signed, three documents in three different
/// states. `blocking_reason` says "two things" while the rows below would let a
/// widget count differently — that mismatch is the point.
Map<String, dynamic> _blocked() => {
      'ok': true,
      'partner_id': 22,
      'partner_name': 'Bilaspur Medical Agency',
      'title': 'My documents',
      'golive': {
        'ok': true,
        'ready': false,
        'heading': 'Go-live',
        'status_label': 'Not ready to take orders',
        'status_tone': 'warning',
        'blocking_reason':
            'This partner cannot be given orders yet: the partner agreement is '
                'not signed and 2 required document(s) are not verified',
        'blockers': [
          {
            'key': 'agreement',
            'text': 'the partner agreement is not signed',
            'tone': 'danger',
          },
          {
            'key': 'kyc',
            'text': '2 required document(s) are not verified',
            'count': 2,
            'tone': 'warning',
          },
        ],
      },
      'agreement': {
        'ok': true,
        'heading': 'Partner agreement',
        'sub': 'Read the agreement, then sign it with the code we send.',
        'has_version': true,
        'version': 1,
        'version_label': 'Version 1 · effective 03/09/2026',
        'title': 'mediBO zone partner agreement',
        'body': '1. Parties\nThis agreement is between…',
        'status': 'unsigned',
        'status_label': 'Not signed',
        'status_tone': 'warning',
        'is_signed': false,
        'needs_signature': true,
        'can_sign': true,
        'sign_label': 'Sign the agreement',
        'name_hint': 'Full name of the person signing',
        'phone_hint': 'WhatsApp number for the code',
        'code_hint': '6-digit code',
        'send_label': 'Send code',
        'verify_label': 'Verify and sign',
        'awaiting_code': false,
        'signed_line': '',
        'signed_ip_line': '',
        'doc_label': 'Signed copy (PDF)',
        'has_doc': false,
        'doc_bucket': '',
        'doc_path': '',
        'doc_building': false,
        'doc_building_label': 'Preparing the signed copy…',
      },
      'kyc': {
        'ok': true,
        'partner_id': 22,
        'heading': 'My documents',
        'sub': 'Upload each document once.',
        'can_write': true,
        'is_admin': false,
        'progress_label': '1 of 3 verified',
        'summary_label': '2 document(s) still outstanding',
        'summary_tone': 'warning',
        'all_verified': false,
        // Deliberately NOT alphabetical: GST first, then PAN, then the licence.
        'rows': [
          {
            'doc_key': 'gst',
            'label': 'GST certificate',
            'hint': 'Registration certificate showing the GSTIN',
            'required': true,
            'required_label': 'Required',
            'wants_number': true,
            'wants_expiry': false,
            'number_hint': 'Number as printed',
            'expiry_hint': 'Valid until',
            'status': 'verified',
            'status_label': 'Verified',
            'status_tone': 'success',
            'has_file': true,
            'bucket': 'partner-receipts',
            'path': 'p22/kyc/gst-1.pdf',
            'number': '22AAAAA0000A1Z5',
            'expiry_label': '',
            'uploaded_label': 'Uploaded 01/09/2026',
            'reject_reason': '',
            'reject_line': '',
            'can_upload': false,
            'upload_label': 'Replace',
            'view_label': 'View',
            'can_review': false,
            'verify_label': 'Verify',
            'reject_label': 'Reject',
            'reject_hint': 'Why is it being rejected?',
          },
          {
            'doc_key': 'pan',
            'label': 'PAN card',
            'hint': 'PAN of the firm named on the licence',
            'required': true,
            'required_label': 'Required',
            'wants_number': true,
            'wants_expiry': false,
            'number_hint': 'Number as printed',
            'expiry_hint': 'Valid until',
            'status': 'rejected',
            'status_label': 'Rejected',
            'status_tone': 'danger',
            'has_file': true,
            'bucket': 'partner-receipts',
            'path': 'p22/kyc/pan-1.pdf',
            'number': 'AAAAA0000A',
            'expiry_label': '',
            'uploaded_label': 'Uploaded 02/09/2026',
            'reject_reason': 'Blurred, the number is unreadable',
            'reject_line': 'Rejected: Blurred, the number is unreadable',
            'can_upload': true,
            'upload_label': 'Replace',
            'view_label': 'View',
            'can_review': false,
            'verify_label': 'Verify',
            'reject_label': 'Reject',
            'reject_hint': 'Why is it being rejected?',
          },
          {
            'doc_key': 'dl_20b',
            'label': 'Drug Licence 20B',
            'hint': 'Wholesale drug licence, Form 20B',
            'required': true,
            'required_label': 'Required',
            'wants_number': true,
            'wants_expiry': true,
            'number_hint': 'Number as printed',
            'expiry_hint': 'Valid until',
            'status': 'missing',
            'status_label': 'Not uploaded',
            'status_tone': 'neutral',
            'has_file': false,
            'bucket': '',
            'path': '',
            'number': '',
            'expiry_label': '',
            'uploaded_label': '',
            'reject_reason': '',
            'reject_line': '',
            'can_upload': true,
            'upload_label': 'Upload',
            'view_label': 'View',
            'can_review': false,
            'verify_label': 'Verify',
            'reject_label': 'Reject',
            'reject_hint': 'Why is it being rejected?',
          },
        ],
      },
      'licence': {'ok': false},
    };

/// The unblocked state: signed, everything verified, nothing left to do.
Map<String, dynamic> _ready() {
  final d = _blocked();
  d['golive'] = {
    'ok': true,
    'ready': true,
    'heading': 'Go-live',
    'status_label': 'Ready to take orders',
    'status_tone': 'success',
    'blocking_reason': '',
    'blockers': <Map<String, dynamic>>[],
  };
  d['agreement'] = {
    ...Map<String, dynamic>.from(d['agreement'] as Map),
    'status': 'signed',
    'status_label': 'Signed',
    'status_tone': 'success',
    'is_signed': true,
    'needs_signature': false,
    'can_sign': false,
    'signed_line': 'Signed by Ravi Verma on 03/09/2026 18:40',
    'signed_ip_line': 'From 203.0.113.9',
    'has_doc': true,
    'doc_bucket': 'partner-receipts',
    'doc_path': 'p22/agreement/7.pdf',
  };
  return d;
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('CHANGE #692 — the go-live gate', () {
    testWidgets('prints the backend sentence, never one composed here',
        (tester) async {
      final payload = _blocked();
      await tester.pumpWidget(_host(PartnerDocumentsScreen(
        api: (fn, p) async => payload,
      )));
      await tester.pumpAndSettle();

      // The blocker LINES are the payload's, verbatim.
      expect(find.text('the partner agreement is not signed'), findsOneWidget);
      expect(find.text('2 required document(s) are not verified'),
          findsOneWidget);
      // …and the chip is the payload's word, not derived from `ready`.
      expect(find.text('Not ready to take orders'), findsOneWidget);
    });

    testWidgets('ready is the backend flag: no blockers are drawn',
        (tester) async {
      await tester.pumpWidget(_host(PartnerDocumentsScreen(
        api: (fn, p) async => _ready(),
      )));
      await tester.pumpAndSettle();

      expect(find.text('Ready to take orders'), findsOneWidget);
      expect(find.text('the partner agreement is not signed'), findsNothing);
    });
  });

  group('CHANGE #692 — the agreement', () {
    testWidgets('unsigned offers the backend caption; signed offers no button',
        (tester) async {
      await tester.pumpWidget(_host(PartnerDocumentsScreen(
        key: const ValueKey('unsigned'),
        api: (fn, p) async => _blocked(),
      )));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(FilledButton, 'Sign the agreement'),
          findsOneWidget);
      expect(find.text('Not signed'), findsOneWidget);

      // A DIFFERENT key, so the screen is rebuilt from its own initState with
      // the signed payload rather than reusing the unsigned state.
      await tester.pumpWidget(_host(PartnerDocumentsScreen(
        key: const ValueKey('signed'),
        api: (fn, p) async => _ready(),
      )));
      await tester.pumpAndSettle();
      // can_sign:false — the button is gone even though the body is still here.
      expect(find.widgetWithText(FilledButton, 'Sign the agreement'),
          findsNothing);
      expect(find.text('Signed'), findsOneWidget);
      expect(find.text('Signed by Ravi Verma on 03/09/2026 18:40'),
          findsOneWidget);
      expect(find.text('From 203.0.113.9'), findsOneWidget);
    });

    testWidgets('the e-sign is start(name+phone) then verify(code)',
        (tester) async {
      final calls = <(String, Map<String, dynamic>)>[];
      await tester.pumpWidget(_host(PartnerDocumentsScreen(
        api: (fn, p) async {
          calls.add((fn, p));
          if (fn == 'partner_documents_screen') return _blocked();
          return {'ok': true, 'message': 'Code sent on WhatsApp.'};
        },
      )));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Sign the agreement'));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.widgetWithText(TextField, 'Full name of the person signing'),
          'Ravi Verma');
      await tester.enterText(
          find.widgetWithText(TextField, 'WhatsApp number for the code'),
          '9876500022');
      await tester.tap(find.widgetWithText(FilledButton, 'Send code'));
      await tester.pumpAndSettle();
      // The success toast is a real 4-second Timer; let it expire inside the
      // test rather than outliving the widget tree.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      final start =
          calls.lastWhere((c) => c.$1 == 'partner_agreement_sign_start');
      final startBody = Map<String, dynamic>.from(start.$2['p'] as Map);
      expect(startBody['signer_name'], 'Ravi Verma');
      expect(startBody['phone'], '9876500022');
      // The code is NOT part of the first call.
      expect(startBody.containsKey('code'), isFalse);

      // The sheet now asks for the code, and verify carries only that.
      await tester.enterText(
          find.widgetWithText(TextField, '6-digit code'), '123456');
      await tester.tap(find.widgetWithText(FilledButton, 'Verify and sign'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      final verify =
          calls.lastWhere((c) => c.$1 == 'partner_agreement_sign_verify');
      final verifyBody = Map<String, dynamic>.from(verify.$2['p'] as Map);
      expect(verifyBody['code'], '123456');
      expect(verifyBody.containsKey('phone'), isFalse);
    });
  });

  group('CHANGE #692 — the KYC documents', () {
    testWidgets('rows render in payload order, not alphabetically',
        (tester) async {
      await tester.pumpWidget(_host(PartnerDocumentsScreen(
        api: (fn, p) async => _blocked(),
      )));
      await tester.pumpAndSettle();

      final gst = tester.getTopLeft(find.text('GST certificate')).dy;
      final pan = tester.getTopLeft(find.text('PAN card')).dy;
      final dl = tester.getTopLeft(find.text('Drug Licence 20B')).dy;
      expect(gst, lessThan(pan));
      expect(pan, lessThan(dl));
    });

    testWidgets('can_upload is the backend flag, and a rejection prints its '
        'own line', (tester) async {
      await tester.pumpWidget(_host(PartnerDocumentsScreen(
        api: (fn, p) async => _blocked(),
      )));
      await tester.pumpAndSettle();

      // 'Rejected: …' is the payload's sentence, never built from the reason.
      expect(find.text('Rejected: Blurred, the number is unreadable'),
          findsOneWidget);

      // The VERIFIED row (can_upload:false) offers no Replace; the other two do.
      expect(find.widgetWithText(OutlinedButton, 'Replace'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Upload'), findsOneWidget);

      // can_review:false everywhere -> no Verify button on the partner's side.
      expect(find.widgetWithText(FilledButton, 'Verify'), findsNothing);
    });

    testWidgets('an ok:false payload prints the backend refusal, never throws',
        (tester) async {
      await tester.pumpWidget(_host(PartnerDocumentsScreen(
        api: (fn, p) async =>
            {'ok': false, 'error': 'no_partner', 'message': 'That partner does not exist.'},
      )));
      await tester.pumpAndSettle();
      expect(find.text('That partner does not exist.'), findsOneWidget);
    });
  });
}
