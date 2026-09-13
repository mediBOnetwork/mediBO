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
  // CMD #1914 — the chip, the ONE plain sentence and the folded worksheet.
  String chipLabel = 'Uploaded',
  bool chipBusy = false,
  String plainReason = '',
  String checksShowLabel = '',
  Map<String, dynamic>? help,
  Map<String, dynamic>? waTimeline,
}) =>
    {
      'ok': true,
      'title': 'Licence & documents',
      'subtitle': 'Upload your drug licence and GST certificate.',
      'empty_note': 'Nothing uploaded yet.',
      'bucket': 'kyc-docs',
      'owner_kind': 'pharmacy',
      'owner_id': 'owner-1',
      // Deliberately NOT owner_id: the folder the storage policy admits is the
      // signed-in USER's, and the payload is the only place that knows it.
      'upload_prefix': 'auth-user-9',
      'state': {'state': 'pending', 'grace_until': '2026-09-17'},
      if (help != null) 'help': help,
      if (waTimeline != null) 'wa_timeline': waTimeline,
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
          'chip_label': chipLabel,
          'chip_tone': licenceStatus == 'rejected' ? 'danger' : 'info',
          'chip_busy': chipBusy,
          'plain_reason': plainReason,
          'checks_show_label': checksShowLabel,
          'checks_hide_label': 'Hide checks',
          'reason_line': reasonLine,
          'meta_line': 'Required  ·  Number: DL-CG-777  ·  Valid till 12 Jan 2028',
          'preview_empty_label': 'No file yet',
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
          'chip_label': 'Not uploaded',
          'chip_tone': 'warning',
          'chip_busy': false,
          'plain_reason': '',
          'checks_show_label': '',
          'checks_hide_label': 'Hide checks',
          'reason_line': '',
          'meta_line': 'Optional  ·  No file yet',
          'preview_empty_label': 'No file yet',
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
    KycPanel.launchTransport = null;
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
      // CMD #1914 — Required/Optional now live inside the card's ONE meta line,
      // joined by the backend (`meta_line`) rather than by this file.
      expect(find.text('Required  ·  Number: DL-CG-777  ·  Valid till 12 Jan 2028'),
          findsOneWidget);
      expect(find.text('Optional  ·  No file yet'), findsOneWidget);
      // CMD #1914 — the chip is ONE word off the payload. `status_label` is
      // still what a payload without a chip falls back to (see below), so both
      // fields stay under test.
      expect(find.text('Uploaded'), findsOneWidget);
      expect(find.text('Not uploaded'), findsOneWidget);
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

    testWidgets(
        'CMD #1914 — the rejection is the backend\'s ONE plain sentence, and '
        'the composed machine line never reaches the surface', (t) async {
      KycPanel.rpcTransport = (fn, p) async => _panelPayload(
            licenceStatus: 'rejected',
            licenceStatusLabel: 'Rejected',
            chipLabel: 'Rejected',
            plainReason: 'GSTIN could not be read — upload a clearer photo.',
            // The old red paragraph is still in the payload. It must NOT print:
            // choosing the sentence is the backend's job, and it chose the one
            // above.
            reasonLine: 'Rejected: Automatically rejected: the GSTIN check '
                'digit is wrong. Upload a corrected document to try again.',
          );
      await t.pumpWidget(const MaterialApp(home: Scaffold(body: KycPanel())));
      await t.pumpAndSettle();
      expect(find.text('GSTIN could not be read — upload a clearer photo.'),
          findsOneWidget);
      expect(
          find.textContaining('Automatically rejected:'), findsNothing);
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
      final target =
          KycPanel.storagePath(_panelPayload(), 'drug_licence', 'jpg', 1);
      await KycPanel.upload(
          'kyc-docs', target!, Uint8List.fromList([1, 2, 3]), 'image/jpeg');
      expect(seenBucket, 'kyc-docs');
      // the PAYLOAD's prefix, never owner_id and never a client-built folder
      expect(seenPath, 'auth-user-9/drug_licence_1.jpg');
      expect(seenArgs, isNull); // no write happened without a real pick
    });

    // ── CMD #1914 ────────────────────────────────────────────────────────
    // The upload screen stopped reading like a debug log. What is held down
    // here is that every one of those decisions stayed in the backend.
    testWidgets('the chip is the backend\'s word, and the spinner spins only '
        'when the backend says the checks are running', (t) async {
      KycPanel.rpcTransport = (fn, p) async => _panelPayload(
          chipLabel: 'Checking', chipBusy: true);
      await t.pumpWidget(const MaterialApp(home: Scaffold(body: KycPanel())));
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));
      expect(find.text('Checking'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsWidgets);
    });

    testWidgets('chip_busy:false leaves no spinner on the card', (t) async {
      KycPanel.rpcTransport = (fn, p) async =>
          _panelPayload(chipLabel: 'Verified', chipBusy: false);
      await t.pumpWidget(const MaterialApp(home: Scaffold(body: KycPanel())));
      await t.pumpAndSettle();
      expect(find.text('Verified'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('a payload with no chip falls back to status_label, so an '
        'older backend still renders', (t) async {
      KycPanel.rpcTransport = (fn, p) async {
        final payload = _panelPayload();
        for (final it in (payload['items'] as List)) {
          (it as Map).remove('chip_label');
          it.remove('chip_tone');
          it.remove('chip_busy');
        }
        return payload;
      };
      await t.pumpWidget(const MaterialApp(home: Scaffold(body: KycPanel())));
      await t.pumpAndSettle();
      expect(find.text('Awaiting verification'), findsOneWidget);
      expect(find.text('Not uploaded'), findsOneWidget);
    });

    testWidgets('the help row launches the URL the BACKEND built — this file '
        'never composes a phone number or a WhatsApp message', (t) async {
      final launched = <String>[];
      KycPanel.launchTransport = (url) async {
        launched.add(url);
        return true;
      };
      KycPanel.rpcTransport = (fn, p) async => _panelPayload(help: {
            'title': 'Stuck? We will do it for you',
            'note': 'Call us, or send the photo on WhatsApp.',
            'call_label': 'Call 93292 52090',
            'call_url': 'tel:+919329252090',
            'wa_label': 'WhatsApp',
            'wa_url': 'https://wa.me/919329252090?text=Hi%20mediBO%2C%20I%20'
                'need%20help%20with%20my%20Drug%20licence.%20Customer%20code'
                '%3A%20SMS100.',
          });
      await t.pumpWidget(const MaterialApp(home: Scaffold(body: KycPanel())));
      await t.pumpAndSettle();

      expect(find.text('Stuck? We will do it for you'), findsOneWidget);
      await t.tap(find.text('Call 93292 52090'));
      await t.tap(find.text('WhatsApp'));
      await t.pumpAndSettle();

      // ONE tap each, and the strings go out byte for byte: the customer code
      // and the document type are already inside the wa.me text.
      expect(launched.length, 2);
      expect(launched.first, 'tel:+919329252090');
      expect(launched.last, contains('wa.me/919329252090?text='));
      expect(launched.last, contains('Customer%20code%3A%20SMS100'));
    });

    testWidgets('no help block in the payload draws no troubleshooting row',
        (t) async {
      KycPanel.rpcTransport = (fn, p) async => _panelPayload();
      await t.pumpWidget(const MaterialApp(home: Scaffold(body: KycPanel())));
      await t.pumpAndSettle();
      expect(find.text('WhatsApp'), findsNothing);
    });

    testWidgets('the WhatsApp timeline row prints the backend line, or the '
        'backend\'s empty sentence', (t) async {
      KycPanel.rpcTransport = (fn, p) async => _panelPayload(waTimeline: {
            'kind': 'timeline',
            'title': 'WhatsApp',
            'empty': 'No WhatsApp message has gone out yet.',
            'items': [
              {
                'line': 'WhatsApp sent: Approved · 2 Sep 4:12 PM',
                'title': 'WhatsApp sent: Approved',
                'subtitle': '',
                'when': '2 Sep 4:12 PM',
                'tone': 'success',
              },
              {
                'line': 'WhatsApp not sent: Licence rejected · 8 Sep 9:40 PM',
                'title': 'WhatsApp not sent: Licence rejected',
                'subtitle': 'No WhatsApp number on file.',
                'when': '8 Sep 9:40 PM',
                'tone': 'warning',
              },
            ],
          });
      await t.pumpWidget(const MaterialApp(home: Scaffold(body: KycPanel())));
      await t.pumpAndSettle();
      expect(find.text('WhatsApp sent: Approved · 2 Sep 4:12 PM'),
          findsOneWidget);
      expect(find.text('No WhatsApp number on file.'), findsOneWidget);
    });

    testWidgets('an empty timeline prints the backend empty sentence',
        (t) async {
      KycPanel.rpcTransport = (fn, p) async => _panelPayload(waTimeline: {
            'kind': 'timeline',
            'title': 'WhatsApp',
            'empty': 'No WhatsApp message has gone out yet.',
            'items': const [],
          });
      await t.pumpWidget(const MaterialApp(home: Scaffold(body: KycPanel())));
      await t.pumpAndSettle();
      expect(
          find.text('No WhatsApp message has gone out yet.'), findsOneWidget);
    });

    testWidgets('no upload yet says so in the backend\'s words, and the card '
        'still draws', (t) async {
      KycPanel.rpcTransport = (fn, p) async => _panelPayload();
      await t.pumpWidget(const MaterialApp(home: Scaffold(body: KycPanel())));
      await t.pumpAndSettle();
      expect(find.text('Optional  ·  No file yet'), findsOneWidget);
    });

    test('no upload_prefix means no upload, never a guessed folder', () {
      final p = _panelPayload()..remove('upload_prefix');
      expect(KycPanel.storagePath(p, 'drug_licence', 'jpg', 1), isNull);
      expect(KycPanel.storagePath(_panelPayload(), 'gst_certificate', 'pdf', 7),
          'auth-user-9/gst_certificate_7.pdf');
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
