// PROTECTED — CHANGE #706.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes smart-verification behaviour.
//
// What this holds down, on the ONE block all three KYC surfaces share:
//
//   1. NOTHING IS COMPUTED. The tier chip, the verdict sentence, every check
//      label, every "OK / Check / Failed" word and every explanation is a
//      backend string printed verbatim. The fixture deliberately disagrees
//      with itself — a check whose status is `pass` carries a `fail` word, and
//      the geo detail names a distance the payload's own `metres` contradicts
//      — so any Dart that re-derives a label or a verdict from the data fails
//      here instead of on a real applicant.
//
//   2. ABSENCE IS A STATE, NOT A BLANK. `has:false` renders the backend's
//      own waiting note; a null or empty `verify` renders nothing at all, so
//      a payload from a build that predates this change still draws.
//
//   3. CHECKS RENDER IN PAYLOAD ORDER. The fixture is deliberately not
//      alphabetical and not sorted by severity.
//
//   4. THE CONFLICTING ACCOUNT IS NAMED. A duplicate is not the word
//      "duplicate": the block prints who already holds the number.
//
//   5. THE RE-UPLOAD PATH IS THE BACKEND'S WORDING. After a hard fail the
//      applicant's button caption becomes `verify.reupload_label`; with no
//      such string it stays the panel's own `button_label`. The panel never
//      composes either one.
//
//   6. A REFUSAL IS NOT A THANK-YOU. The public token page keeps the applicant
//      on the form with the backend's refusal above it, so a duplicate licence
//      can be corrected and resent — it must never draw the success tick over
//      a refusal (which is what it did before this change).
//
// No network, no Supabase, no goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/kyc/kyc_verify_block.dart';
import 'package:pharma_b2b/screens/kyc/kyc_panel.dart';
import 'package:pharma_b2b/screens/public/kyc_upload_form_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

// ── fixtures ─────────────────────────────────────────────────────────────────

Map<String, dynamic> _check(String key, String label, String status,
        String statusLabel, String tone, String detail,
        {Map<String, dynamic>? extra}) =>
    {
      'key': key,
      'label': label,
      'status': status,
      'status_label': statusLabel,
      'tone': tone,
      'detail': detail,
      ...?extra,
    };

/// A run the backend flagged for a human: the geo check is far, everything
/// else passed. Deliberately inconsistent so a client-side re-derivation of
/// any string is visible.
Map<String, dynamic> _reviewVerify() => {
      'has': true,
      'title': 'Automatic checks',
      'subtitle': 'We read the document and compared it with what you entered.',
      'tier': 'review',
      'tier_label': 'Needs a human look',
      'verdict': 'manual',
      'verdict_label': 'Sent for manual review',
      'tone': 'warning',
      'actor': 'auto',
      'actor_label': 'Automatic',
      'note': '',
      'reason': '',
      'applied': false,
      'approved_account': false,
      'approved_label': '',
      'decided_label': 'Decided 4 minutes ago',
      'ocr_status': 'done',
      'mismatch_count': 1,
      'mismatch_heading': 'What did not match',
      'mismatch_label': '1 to check',
      'conflict_heading': 'Already registered to',
      'conflict': null,
      'reupload_label': '',
      'checks': [
        // NOT alphabetical, NOT severity-ordered: payload order is the order.
        _check('geo', 'Address vs map pin', 'warn', 'Check', 'warning',
            'The map pin is 106.2 km from the address on the document — further than 500 m.',
            extra: {'metres': 12, 'geo': {'source': 'osm', 'lat': 22.07, 'lng': 82.14}}),
        // status pass, but the WORD is the backend's — a Dart map from
        // status->word would print "OK" here and fail.
        _check('ocr_read', 'Document readable', 'pass', 'Failed', 'success',
            'The document was read successfully.'),
        _check('dup_dl', 'Licence used elsewhere', 'pass', 'OK', 'success',
            'Not used by any other account.'),
      ],
    };

/// A hard fail: a duplicate licence, with the conflicting account named.
Map<String, dynamic> _rejectedVerify() => {
      'has': true,
      'title': 'Automatic checks',
      'subtitle': 'We read the document and compared it with what you entered.',
      'tier': 'hard_fail',
      'tier_label': 'Rejected automatically',
      'verdict': 'auto_rejected',
      'verdict_label': 'Rejected automatically',
      'tone': 'danger',
      'actor': 'auto',
      'actor_label': 'Automatic',
      'note': '',
      'reason':
          'Automatically rejected: this licence number belongs to another account '
              'Upload a corrected document to try again.',
      'applied': true,
      'approved_account': false,
      'approved_label': '',
      'decided_label': 'Decided just now',
      'ocr_status': 'done',
      'mismatch_count': 1,
      'mismatch_heading': 'What did not match',
      'mismatch_label': '1 to check',
      'conflict_heading': 'Already registered to',
      'conflict': {
        'has': true,
        'id_kind': 'dl',
        'owner_kind': 'supplier',
        'owner_name': 'Bharat Surgicals',
        'owner_city': 'Bilaspur',
        'owner_label': 'Supplier',
      },
      'reupload_label': 'Upload a corrected document',
      'checks': [
        _check('dup_dl', 'Licence used elsewhere', 'fail', 'Failed', 'danger',
            'Already registered to Bharat Surgicals (Supplier).',
            extra: {
              'conflict': {
                'has': true,
                'owner_kind': 'supplier',
                'owner_name': 'Bharat Surgicals',
                'owner_city': 'Bilaspur',
                'owner_label': 'Supplier',
              }
            }),
      ],
    };

Map<String, dynamic> _panelItem(
        {required String kind,
        required String buttonLabel,
        Map<String, dynamic>? verify}) =>
    {
      'kind': kind,
      'label': 'Drug licence',
      'required': true,
      'requirement_label': 'Required',
      'has': true,
      'doc_id': 'doc-$kind',
      'bucket': 'kyc-docs',
      'path': 'u/$kind.jpg',
      'file_name': '$kind.jpg',
      'number': 'CG/RPR/20B/706001',
      'number_label': 'Number',
      'valid_to': '2027-10-08',
      'expiry_label': 'Valid till 8 Oct 2027',
      'status': 'pending',
      'status_label': 'Awaiting verification',
      'status_tone': 'info',
      'reason_line': '',
      // CMD #1914 — the worksheet is FOLDED. The caption that opens it is a
      // backend string, and an item whose checks have not run carries none.
      'checks_show_label':
          (verify != null && verify['has'] == true) ? 'See checks' : '',
      'checks_hide_label': 'Hide checks',
      'button_label': buttonLabel,
      'verify': verify,
    };

Map<String, dynamic> _panel(List<Map<String, dynamic>> items) => {
      'ok': true,
      'title': 'Licence & documents',
      'subtitle': 'Upload your drug licence and GST certificate.',
      'empty_note': 'Nothing to upload.',
      'bucket': 'kyc-docs',
      'upload_prefix': 'user-uid',
      'owner_kind': 'pharmacy',
      'owner_id': 'pharm-1',
      'state': {'state': 'pending', 'clear': false},
      'verify_title': 'Automatic checks',
      'items': items,
    };

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  tearDown(() {
    KycPanel.rpcTransport = null;
    KycPanel.uploadTransport = null;
    KycUploadFormScreen.rpcTransport = null;
    KycUploadFormScreen.uploadTransport = null;
  });

  group('the checks block computes nothing', () {
    testWidgets('tier, verdict and every check word are printed verbatim',
        (tester) async {
      await tester.pumpWidget(_host(KycVerifyBlock(verify: _reviewVerify())));
      await tester.pump();

      expect(find.text('Automatic checks'), findsOneWidget);
      expect(find.text('Needs a human look'), findsOneWidget);
      expect(find.text('Sent for manual review'), findsOneWidget);

      // The geo sentence is the payload's. The block must not recompute a
      // distance from `metres` (12) — that would print "12 m".
      expect(
        find.text('The map pin is 106.2 km from the address on the document — '
            'further than 500 m.'),
        findsOneWidget,
      );
      expect(find.textContaining('12 m'), findsNothing);

      // A `pass` check whose word is 'Failed' still prints 'Failed'.
      expect(find.text('Document readable'), findsOneWidget);
      expect(find.text('Failed'), findsOneWidget);

      // The mismatch strip is the backend's heading and its own count string.
      expect(find.text('What did not match · 1 to check'), findsOneWidget);
      expect(find.text('Decided 4 minutes ago · Automatic'), findsOneWidget);
    });

    testWidgets('checks render in payload order, not sorted', (tester) async {
      await tester.pumpWidget(_host(KycVerifyBlock(verify: _reviewVerify())));
      await tester.pump();

      final labels = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .where((s) => s == 'Address vs map pin' ||
              s == 'Document readable' ||
              s == 'Licence used elsewhere')
          .toList();
      expect(labels,
          ['Address vs map pin', 'Document readable', 'Licence used elsewhere']);
    });

    testWidgets('a duplicate names the account that already holds the number',
        (tester) async {
      await tester.pumpWidget(_host(KycVerifyBlock(verify: _rejectedVerify())));
      await tester.pump();

      expect(find.text('Already registered to'), findsOneWidget);
      expect(find.text('Bharat Surgicals · Supplier · Bilaspur'), findsOneWidget);
      expect(
        find.textContaining('this licence number belongs to another account'),
        findsOneWidget,
      );
    });
  });

  group('absence is a state', () {
    testWidgets('has:false prints the backend waiting note', (tester) async {
      await tester.pumpWidget(_host(const KycVerifyBlock(verify: {
        'has': false,
        'title': 'Automatic checks',
        'empty_note': 'Reading the document…',
        'ocr_status': 'queued',
        'checks': [],
      })));
      await tester.pump();

      expect(find.text('Reading the document…'), findsOneWidget);
      // No verdict is invented while the document is still being read.
      expect(find.text('Needs a human look'), findsNothing);
    });

    testWidgets('a null verify draws nothing', (tester) async {
      await tester.pumpWidget(_host(const KycVerifyBlock(verify: null)));
      await tester.pump();
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('an empty verify draws nothing', (tester) async {
      await tester.pumpWidget(_host(const KycVerifyBlock(verify: {})));
      await tester.pump();
      expect(find.byType(Text), findsNothing);
    });
  });

  group('the applicant panel', () {
    testWidgets('a rejected document asks for a corrected one in the '
        "backend's words", (tester) async {
      KycPanel.rpcTransport = (fn, params) async {
        expect(fn, 'kyc_my_panel');
        return _panel([
          _panelItem(
              kind: 'drug_licence',
              buttonLabel: 'Replace',
              verify: _rejectedVerify()),
        ]);
      };

      await tester.pumpWidget(_host(const KycPanel()));
      await tester.pumpAndSettle();

      // reupload_label wins over button_label — and neither is composed here.
      expect(find.text('Upload a corrected document'), findsOneWidget);
      expect(find.text('Replace'), findsNothing);

      // CMD #1914 — the machine's worksheet is no longer the first thing on
      // the card. Its tier word is behind the link until the link is tapped.
      expect(find.text('Rejected automatically'), findsNothing);
      await tester.tap(find.text('See checks'));
      await tester.pumpAndSettle();
      expect(find.text('Rejected automatically'), findsWidgets);
      // …and it folds away again, in the backend's word for it.
      await tester.tap(find.text('Hide checks'));
      await tester.pumpAndSettle();
      expect(find.text('Rejected automatically'), findsNothing);
    });

    testWidgets('with no reupload_label the panel keeps its own caption',
        (tester) async {
      final v = _reviewVerify();
      KycPanel.rpcTransport = (fn, params) async => _panel([
            _panelItem(
                kind: 'drug_licence', buttonLabel: 'Replace', verify: v),
          ]);

      await tester.pumpWidget(_host(const KycPanel()));
      await tester.pumpAndSettle();

      expect(find.text('Replace'), findsOneWidget);
      expect(find.text('Upload a corrected document'), findsNothing);
    });

    testWidgets('an item with no verify still renders its row', (tester) async {
      KycPanel.rpcTransport = (fn, params) async => _panel([
            _panelItem(kind: 'drug_licence', buttonLabel: 'Upload'),
          ]);

      await tester.pumpWidget(_host(const KycPanel()));
      await tester.pumpAndSettle();

      expect(find.text('Drug licence'), findsOneWidget);
      expect(find.text('Upload'), findsOneWidget);
      expect(find.text('Automatic checks'), findsNothing);
    });
  });

  group('the public token page', () {
    Map<String, dynamic> form() => {
          'ok': true,
          'title': 'Upload your drug licence',
          'for_line': 'For Sharma Medical Stores',
          'subtitle': 'Attach a photo of the licence.',
          'deadline_line': '',
          'number_label': 'Licence number',
          'number_hint': 'As printed',
          'expiry_hint': 'Valid till',
          'file_hint': 'Choose a file',
          'submit_label': 'Send',
          'done_title': 'Thank you',
        };

    testWidgets('a refusal keeps the applicant on the form with the '
        "backend's sentence", (tester) async {
      var submitted = false;
      KycUploadFormScreen.rpcTransport = (fn, params) async {
        if (fn == 'kyc_token_form') return form();
        submitted = true;
        return {
          'ok': false,
          'error': 'duplicate',
          'tone': 'danger',
          'message':
              'This drug licence number is already registered to Bharat Surgicals.',
          'conflict': {'has': true, 'owner_name': 'Bharat Surgicals'},
        };
      };
      KycUploadFormScreen.uploadTransport =
          (bucket, path, bytes, mime) async => path;

      await tester
          .pumpWidget(const MaterialApp(home: KycUploadFormScreen(token: 't1')));
      await tester.pumpAndSettle();

      final state = tester.state(find.byType(KycUploadFormScreen)) as dynamic;
      // ignore: avoid_dynamic_calls
      await state.submitForTest();
      await tester.pumpAndSettle();

      expect(submitted, isTrue);
      expect(
        find.text(
            'This drug licence number is already registered to Bharat Surgicals.'),
        findsOneWidget,
      );
      // The thank-you must NOT be shown for a refusal.
      expect(find.text('Thank you'), findsNothing);
      // ...and the form is still there to correct and resend.
      expect(find.text('Send'), findsOneWidget);
    });

    testWidgets('a success shows the thank-you and the checks that already ran',
        (tester) async {
      KycUploadFormScreen.rpcTransport = (fn, params) async {
        if (fn == 'kyc_token_form') return form();
        return {
          'ok': true,
          'tone': 'success',
          'doc_id': 'doc-1',
          'message': 'We have your licence.',
          'verify': {
            'has': false,
            'title': 'Automatic checks',
            'empty_note': 'Reading the document…',
            'ocr_status': 'queued',
            'checks': [],
          },
        };
      };
      KycUploadFormScreen.uploadTransport =
          (bucket, path, bytes, mime) async => path;

      await tester
          .pumpWidget(const MaterialApp(home: KycUploadFormScreen(token: 't1')));
      await tester.pumpAndSettle();

      final state = tester.state(find.byType(KycUploadFormScreen)) as dynamic;
      // ignore: avoid_dynamic_calls
      await state.submitForTest();
      // pump, not pumpAndSettle: the "still reading" state carries a spinner
      // that by design never settles.
      await tester.pump();
      await tester.pump();

      expect(find.text('Thank you'), findsOneWidget);
      expect(find.text('We have your licence.'), findsOneWidget);
      expect(find.text('Reading the document…'), findsOneWidget);
    });
  });
}
