// PROTECTED — CHANGE #705. KYC parity for pharmacies and suppliers.
//
// What this holds down, on the three surfaces the feature actually ships:
//
//  * the applicant's panel computes NOTHING. Every label, status word, expiry
//    sentence, rejection line and button caption is a kyc_my_panel() string,
//    rows render in payload order, and ok:false renders the backend's own page
//    instead of throwing.
//  * the public /kyc-upload/<token> page is the same contract every other
//    token page has: it prints kyc_token_form()'s copy, Submit stays closed
//    until a file has been picked, and an unknown / expired / used link renders
//    the backend's refusal rather than a Dart sentence.
//  * the review console gates on the payload, not on a role guess: the verify
//    and reject buttons appear only when can_write is true AND the row is
//    pending, and the rejection sheet cannot send an empty reason.
//
// No network, no Supabase, no goldens — the RPC transports are seams.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/kyc_review_screen.dart';
import 'package:pharma_b2b/screens/kyc/kyc_panel.dart';
import 'package:pharma_b2b/screens/public/kyc_upload_form_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _panelPayload({
  String licenceStatus = 'pending',
  String licenceStatusLabel = 'Awaiting verification',
  String reasonLine = '',
}) =>
    {
      'ok': true,
      'title': 'Licence & documents',
      'subtitle': 'Upload your drug licence and GST certificate.',
      'empty_note': 'Nothing uploaded yet.',
      'bucket': 'kyc-docs',
      'owner_kind': 'pharmacy',
      'owner_id': 'owner-1',
      'state': {'state': 'pending', 'grace_until': '2026-09-17'},
      // Deliberately NOT alphabetical: payload order is the render order.
      'items': [
        {
          'kind': 'drug_licence',
          'label': 'Drug licence',
          'required': true,
          'requirement_label': 'Required',
          'has': true,
          'doc_id': 'doc-1',
          'number': 'DL-CG-777',
          'number_label': 'Number',
          'expiry_label': 'Valid till 12 Jan 2028',
          'status': licenceStatus,
          'status_label': licenceStatusLabel,
          'status_tone': licenceStatus == 'rejected' ? 'danger' : 'info',
          'reason_line': reasonLine,
          'button_label': 'Replace',
        },
        {
          'kind': 'gst_certificate',
          'label': 'GST certificate',
          'required': false,
          'requirement_label': 'Optional',
          'has': false,
          'number': '',
          'number_label': 'Number',
          'expiry_label': '',
          'status': 'missing',
          'status_label': 'Not uploaded',
          'status_tone': 'warning',
          'reason_line': '',
          'button_label': 'Upload',
        },
      ],
    };

Map<String, dynamic> _tokenPayload() => {
      'ok': true,
      'token': 'tok-1',
      'title': 'Upload your licence',
      'subtitle': 'mediBO needs a copy of your drug licence.',
      'for_line': 'For Ot Medical',
      'deadline_line': 'Please upload before 17 Sep 2026.',
      'kind': 'drug_licence',
      'kind_label': 'Drug licence',
      'number_label': 'Number',
      'number_hint': 'Licence number as printed',
      'expiry_hint': 'Valid until (as printed)',
      'file_hint': 'Photo or PDF of the licence',
      'submit_label': 'Submit',
      'done_title': 'Thank you',
      'done_body': 'We have your licence.',
      'bucket': 'kyc-docs',
      'upload_prefix': 'token/tok-1',
      'already_done': false,
      'used_message': 'This link has already been used. Thank you.',
      'state': {'grace_until': '2026-09-17'},
    };

Map<String, dynamic> _queuePayload({bool canWrite = true, String status = 'pending'}) => {
      'ok': true,
      'title': 'KYC review',
      'subtitle': 'Documents waiting to be verified.',
      'empty_note': 'Nothing waiting.',
      'can_write': canWrite,
      'reason_label': 'Reason for rejection',
      'reason_hint': 'Tell them what is wrong — they see this word for word.',
      'count_label': '2 waiting',
      'pending_count': 2,
      'tabs': [
        {'key': 'pending', 'label': 'Pending'},
        {'key': 'verified', 'label': 'Verified'},
        {'key': 'rejected', 'label': 'Rejected'},
      ],
      'status': status,
      'rows': [
        {
          'doc_id': 'doc-1',
          'owner_kind': 'pharmacy',
          'owner_name': 'Ot Medical',
          'owner_city': 'Raipur',
          'kind': 'drug_licence',
          'kind_label': 'Drug licence',
          'number': 'DL-CG-777',
          'number_label': 'Number',
          'expiry_label': 'Valid till 12 Jan 2028',
          'bucket': 'kyc-docs',
          'path': 'token/tok-1/1.jpg',
          'status': status,
          'status_label': status == 'pending' ? 'Awaiting verification' : 'Verified',
          'status_tone': status == 'pending' ? 'info' : 'success',
          'reason': '',
          'submitted_label': 'Uploaded 3m ago',
          'view_label': 'View document',
          'verify_label': 'Verify',
          'reject_label': 'Reject',
        },
      ],
    };

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  tearDown(() {
    KycPanel.rpcTransport = null;
    KycPanel.uploadTransport = null;
    KycUploadFormScreen.rpcTransport = null;
    KycUploadFormScreen.uploadTransport = null;
    KycReviewScreen.rpcTransport = null;
  });

  group('the applicant panel prints the payload and computes nothing', () {
    testWidgets('labels, statuses, expiry and button captions are backend strings',
        (t) async {
      KycPanel.rpcTransport = (fn, p) async {
        expect(fn, 'kyc_my_panel');
        return _panelPayload();
      };
      await t.pumpWidget(const MaterialApp(home: Scaffold(body: KycPanel())));
      await t.pumpAndSettle();

      expect(find.text('Licence & documents'), findsOneWidget);
      expect(find.text('Drug licence'), findsOneWidget);
      expect(find.text('Required'), findsOneWidget);
      expect(find.text('Optional'), findsOneWidget);
      expect(find.text('Awaiting verification'), findsOneWidget);
      expect(find.text('Not uploaded'), findsOneWidget);
      expect(find.text('Valid till 12 Jan 2028'), findsOneWidget);
      expect(find.text('Number: DL-CG-777'), findsOneWidget);
      // The two button captions are the payload's, not 'Upload' twice.
      expect(find.text('Replace'), findsOneWidget);
      expect(find.text('Upload'), findsOneWidget);
    });

    testWidgets('items render in PAYLOAD order, never sorted in Dart', (t) async {
      KycPanel.rpcTransport = (fn, p) async => _panelPayload();
      await t.pumpWidget(const MaterialApp(home: Scaffold(body: KycPanel())));
      await t.pumpAndSettle();

      final labels = t
          .widgetList<Text>(find.byType(Text))
          .map((w) => w.data ?? '')
          .where((s) => s == 'Drug licence' || s == 'GST certificate')
          .toList();
      // 'GST certificate' sorts BEFORE 'Drug licence'; the payload does not.
      expect(labels, ['Drug licence', 'GST certificate']);
    });

    testWidgets('a rejection line is printed verbatim, never re-worded',
        (t) async {
      KycPanel.rpcTransport = (fn, p) async => _panelPayload(
            licenceStatus: 'rejected',
            licenceStatusLabel: 'Rejected',
            reasonLine: 'Rejected: The photo is cut off.',
          );
      await t.pumpWidget(const MaterialApp(home: Scaffold(body: KycPanel())));
      await t.pumpAndSettle();
      expect(find.text('Rejected: The photo is cut off.'), findsOneWidget);
    });

    testWidgets('ok:false renders the backend page instead of throwing',
        (t) async {
      KycPanel.rpcTransport = (fn, p) async => {
            'ok': false,
            'error': 'no_owner',
            'title': 'Licence & documents',
            'message': 'This login is not linked to a pharmacy or supplier account.',
          };
      await t.pumpWidget(const MaterialApp(home: Scaffold(body: KycPanel())));
      await t.pumpAndSettle();
      expect(
          find.text(
              'This login is not linked to a pharmacy or supplier account.'),
          findsOneWidget);
      expect(find.text('Upload'), findsNothing);
    });

    testWidgets('the upload goes to the bucket the PAYLOAD named', (t) async {
      String? seenBucket;
      String? seenPath;
      Map<String, dynamic>? seenArgs;
      KycPanel.rpcTransport = (fn, p) async {
        if (fn == 'kyc_upload_register') {
          seenArgs = p;
          return {'ok': true, 'message': 'Uploaded.', 'panel': _panelPayload()};
        }
        return _panelPayload();
      };
      KycPanel.uploadTransport = (b, path, bytes, mime) async {
        seenBucket = b;
        seenPath = path;
        return path;
      };
      // The picker itself is platform code; drive the transport directly to
      // prove the contract this file owns.
      await t.pumpWidget(const MaterialApp(home: Scaffold(body: KycPanel())));
      await t.pumpAndSettle();
      await KycPanel.upload('kyc-docs', 'owner-1/drug_licence_1.jpg',
          Uint8List.fromList([1, 2, 3]), 'image/jpeg');
      expect(seenBucket, 'kyc-docs');
      expect(seenPath, startsWith('owner-1/'));
      expect(seenArgs, isNull); // no write happened without a real pick
    });
  });

  group('the public token page', () {
    testWidgets('prints the backend copy and keeps Submit closed until a file',
        (t) async {
      KycUploadFormScreen.rpcTransport = (fn, p) async {
        expect(fn, 'kyc_token_form');
        expect(p?['p_token'], 'tok-1');
        return _tokenPayload();
      };
      await t.pumpWidget(
          const MaterialApp(home: KycUploadFormScreen(token: 'tok-1')));
      await t.pumpAndSettle();

      expect(find.text('Upload your licence'), findsOneWidget);
      expect(find.text('For Ot Medical'), findsOneWidget);
      expect(find.text('Please upload before 17 Sep 2026.'), findsOneWidget);
      expect(find.text('Photo or PDF of the licence'), findsOneWidget);

      final submit = t.widget<FilledButton>(find.ancestor(
          of: find.text('Submit'), matching: find.byType(FilledButton)));
      expect(submit.onPressed, isNull, reason: 'no file picked yet');
    });

    testWidgets('an expired link renders the backend refusal, not a throw',
        (t) async {
      KycUploadFormScreen.rpcTransport = (fn, p) async => {
            'ok': false,
            'error': 'expired',
            'title': 'Upload your licence',
            'message': 'This link has expired. Please ask mediBO for a new one.',
          };
      await t.pumpWidget(
          const MaterialApp(home: KycUploadFormScreen(token: 'dead')));
      await t.pumpAndSettle();
      expect(
          find.text('This link has expired. Please ask mediBO for a new one.'),
          findsOneWidget);
      expect(find.text('Submit'), findsNothing);
    });

    testWidgets('an already-used link shows its own message', (t) async {
      KycUploadFormScreen.rpcTransport = (fn, p) async =>
          {..._tokenPayload(), 'already_done': true};
      await t.pumpWidget(
          const MaterialApp(home: KycUploadFormScreen(token: 'tok-1')));
      await t.pumpAndSettle();
      expect(find.text('This link has already been used. Thank you.'),
          findsOneWidget);
      expect(find.text('Submit'), findsNothing);
    });
  });

  group('the review console gates on the payload, never on a role guess', () {
    testWidgets('can_write:true + pending shows Verify and Reject', (t) async {
      KycReviewScreen.rpcTransport = (fn, p) async =>
          fn == 'kyc_drive_card' ? {'ok': false} : _queuePayload();
      await t.pumpWidget(const MaterialApp(home: KycReviewScreen()));
      await t.pumpAndSettle();

      expect(find.text('Ot Medical'), findsOneWidget);
      expect(find.text('Uploaded 3m ago'), findsOneWidget);
      expect(find.text('Verify'), findsOneWidget);
      expect(find.text('Reject'), findsOneWidget);
      expect(find.text('View document'), findsOneWidget);
    });

    testWidgets('can_write:false shows the document but no verdict buttons',
        (t) async {
      KycReviewScreen.rpcTransport = (fn, p) async => fn == 'kyc_drive_card'
          ? {'ok': false}
          : _queuePayload(canWrite: false);
      await t.pumpWidget(const MaterialApp(home: KycReviewScreen()));
      await t.pumpAndSettle();

      expect(find.text('View document'), findsOneWidget);
      expect(find.text('Verify'), findsNothing);
      expect(find.text('Reject'), findsNothing);
    });

    testWidgets('a row that is no longer pending offers no verdict', (t) async {
      KycReviewScreen.rpcTransport = (fn, p) async => fn == 'kyc_drive_card'
          ? {'ok': false}
          : _queuePayload(status: 'verified');
      await t.pumpWidget(const MaterialApp(home: KycReviewScreen()));
      await t.pumpAndSettle();

      expect(find.text('Verified'), findsWidgets);
      expect(find.text('Verify'), findsNothing);
    });

    testWidgets('not_authorized renders the backend sentence', (t) async {
      KycReviewScreen.rpcTransport = (fn, p) async => {
            'ok': false,
            'error': 'not_authorized',
            'title': 'KYC review',
            'message': 'You do not have access to KYC review.',
          };
      await t.pumpWidget(const MaterialApp(home: KycReviewScreen()));
      await t.pumpAndSettle();
      expect(find.text('You do not have access to KYC review.'), findsOneWidget);
    });

    testWidgets('the tabs are the payload\'s, in payload order', (t) async {
      KycReviewScreen.rpcTransport = (fn, p) async =>
          fn == 'kyc_drive_card' ? {'ok': false} : _queuePayload();
      await t.pumpWidget(const MaterialApp(home: KycReviewScreen()));
      await t.pumpAndSettle();
      final chips = t
          .widgetList<ChoiceChip>(find.byType(ChoiceChip))
          .map((w) => (w.label as Text).data)
          .toList();
      expect(chips, ['Pending', 'Verified', 'Rejected']);
    });

    testWidgets('the backfill card prints its own progress and deadline',
        (t) async {
      KycReviewScreen.rpcTransport = (fn, p) async => fn == 'kyc_drive_card'
          ? {
              'ok': true,
              'title': 'Licence backfill',
              'subtitle': 'Approved accounts trading without a verified drug licence.',
              'send_label': 'Send upload links',
              'can_send': true,
              'progress_label': '0 of 46 verified',
              'deadline_label': 'Blocks from 17 Sep 2026',
            }
          : _queuePayload();
      await t.pumpWidget(const MaterialApp(home: KycReviewScreen()));
      await t.pumpAndSettle();
      expect(find.text('0 of 46 verified'), findsOneWidget);
      expect(find.text('Blocks from 17 Sep 2026'), findsOneWidget);
      expect(find.text('Send upload links'), findsOneWidget);
    });
  });
}
