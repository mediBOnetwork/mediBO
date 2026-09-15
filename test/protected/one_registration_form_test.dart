// PROTECTED — CMD #2061.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes customer registration.
//
// What this holds down:
//
//   1. ONE FORM. The details and the documents are one screen. The fields and
//      the document rows are rendered together off ONE payload, and the
//      screen never asks for a second route to finish.
//
//   2. THE FIELD LIST IS THE PAYLOAD'S. A schema that no longer carries Other
//      contact / Delivery range / Payment term renders none of them — there is
//      no Dart-side fallback list that could put a removed field back.
//
//   3. THE DOCUMENTS ARE THE ZONE'S. Every row's star, requirement word,
//      Upload caption and skip caption is printed verbatim; a document the
//      backend did not send is simply not on the screen (that is what Off is).
//
//   4. A SKIPPED MANDATORY PAPER NEVER BLOCKS SUBMIT. Submit stays enabled,
//      and the ONE call carries exactly the keys that were tapped —
//      an untouched row is omitted, never defaulted to "I don't have this".
//
//   5. DOCS PENDING IS THE BACKEND'S SENTENCE. The line and the Resume caption
//      are printed as they arrive; Dart never composes "Docs pending: X".
//
// No network, no Supabase, no goldens.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/auth/one_registration_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/registration_documents_section.dart';

// ── fixtures — the shape customer_registration_payload() returns ────────────

Map<String, dynamic> _docBlock({bool skipped = false, bool hasFile = false}) => {
      'show': true,
      'title': 'Documents',
      'subtitle': 'Starred papers are needed before your account can be approved.',
      'skip_note': 'Skipping a starred paper is fine — you can submit now.',
      'required_count': 1,
      'required_left': skipped || !hasFile ? 1 : 0,
      'rows': [
        {
          'key': 'dl_20b',
          'label': 'Drug Licence 20B',
          'hint': 'Retail licence for allopathic medicines',
          'mode': 'mandatory',
          'required': true,
          'star': ' *',
          'requirement_label': 'Required',
          'requirement_tone': 'warning',
          'camera_only': false,
          'has_file': hasFile,
          'file_name': hasFile ? 'dl.jpg' : '',
          'skipped': skipped,
          'state': skipped ? 'skipped' : (hasFile ? 'uploaded' : 'empty'),
          'state_label': skipped
              ? "You said you don't have this"
              : (hasFile ? 'Added' : ''),
          'state_tone': 'neutral',
          'upload_label': hasFile ? 'Replace' : 'Upload',
          'add_label': 'Upload',
          'replace_label': 'Replace',
          'skip_label': "I don't have this",
          'undo_label': 'Undo',
          'bucket': 'kyc-docs',
        },
        {
          'key': 'gst',
          'label': 'GST Certificate',
          'hint': '',
          'mode': 'optional',
          'required': false,
          'star': '',
          'requirement_label': 'Optional',
          'requirement_tone': 'neutral',
          'camera_only': false,
          'has_file': false,
          'file_name': '',
          'skipped': false,
          'state': 'empty',
          'state_label': '',
          'state_tone': 'neutral',
          'upload_label': 'Upload',
          'add_label': 'Upload',
          'replace_label': 'Replace',
          'skip_label': "I don't have this",
          'undo_label': 'Undo',
          'bucket': 'kyc-docs',
        },
      ],
    };

Map<String, dynamic> _schema() => {
      'ok': true,
      'context': 'signup',
      'loading_label': 'Loading the form…',
      'required_suffix': ' *',
      'sections': [
        {
          'key': 'business',
          'title': 'Business',
          'fields': [
            {
              'key': 'pharmacy_name',
              'section': 'business',
              'label': 'Pharmacy name',
              'hint': '',
              'type': 'text',
              'required': true,
              'sort_order': 10,
              'half_width': false,
              'max_lines': 1,
              'options': [],
            },
          ],
        },
      ],
      'fields': [
        {
          'key': 'pharmacy_name',
          'section': 'business',
          'label': 'Pharmacy name',
          'hint': '',
          'type': 'text',
          'required': true,
          'sort_order': 10,
          'half_width': false,
          'max_lines': 1,
          'options': [],
        },
      ],
      'required_fields': ['pharmacy_name'],
      'geo': {},
      'gst': {},
    };

Map<String, dynamic> _payload({
  bool pending = false,
  bool needs = true,
  bool imported = false,
  bool skipped = false,
}) =>
    {
      'signed_in': true,
      'needs': needs,
      'stage': needs ? 'form' : 'done',
      'route': '/complete-registration',
      'customer_id': imported ? 'cid-1' : null,
      'title': 'Register your pharmacy',
      'subtitle': 'One form. Fill what applies and submit.',
      'submit_label': 'Submit registration',
      'submitting_label': 'Submitting…',
      'error_label': 'We could not save that. Try once more.',
      'retry_label': 'Try again',
      'close_label': 'Close',
      'done_title': 'You are registered',
      'done_line': 'Nothing else is pending.',
      'imported': {
        'is': imported,
        'note': imported ? 'We already have your shop on file.' : '',
      },
      'schema': _schema(),
      'prefill': const {},
      'draft': const {},
      'has_draft': false,
      'draft_note': '',
      'documents': _docBlock(skipped: skipped),
      'docs_pending': {
        'show': pending,
        'title': 'Docs pending',
        'line': 'Docs pending: Drug Licence 20B',
        'docs': 'Drug Licence 20B',
        'cta': 'Resume',
        'route': '/complete-registration',
        'anchor': 'documents',
        'tone': 'warning',
      },
      // There are no steps any more.
      'steps': const [],
      'step': const {'n': 1, 'total': 1},
      'required_left': 1,
    };

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  tearDown(() => OneRegistrationScreen.rpcTransport = null);

  Future<void> pump(WidgetTester tester,
      {required Map<String, dynamic> payload,
      List<Map<String, dynamic>>? calls,
      Size size = const Size(360, 900)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    OneRegistrationScreen.rpcTransport = (fn, params) async {
      calls?.add({'fn': fn, 'params': params ?? const {}});
      if (fn == 'customer_registration_payload') return payload;
      if (fn == 'customer_registration_submit') {
        return {
          'ok': true,
          'tone': 'warning',
          'customer_id': 'cid-1',
          'message': 'Docs pending: Drug Licence 20B',
          'docs_pending': true,
          'docs_missing': 'Drug Licence 20B',
          'payload': payload,
        };
      }
      return null;
    };

    await tester.pumpWidget(const MaterialApp(home: OneRegistrationScreen()));
    await tester.pumpAndSettle();
  }

  testWidgets('1 — one screen: the fields and the documents render together',
      (tester) async {
    await pump(tester, payload: _payload());

    // The field list the payload sent.
    expect(find.text('Pharmacy name *'), findsOneWidget);
    // …and the documents, on the SAME screen.
    expect(find.text('Documents'), findsOneWidget);
    expect(find.text('Drug Licence 20B *'), findsOneWidget);
    expect(find.text('GST Certificate'), findsOneWidget);
    // One Submit, not a "Next step".
    expect(find.text('Submit registration'), findsOneWidget);
  });

  testWidgets('2 — a field the schema does not carry is nowhere on the screen',
      (tester) async {
    await pump(tester, payload: _payload());

    for (final gone in const [
      'Other contact',
      'Delivery range',
      'Payment term',
    ]) {
      expect(find.text(gone), findsNothing,
          reason: '$gone left the customer form in #2061 — no Dart fallback '
              'may put it back');
    }
  });

  testWidgets('3 — every document caption is the payload\'s, verbatim',
      (tester) async {
    await pump(tester, payload: _payload());

    expect(find.text('Required'), findsOneWidget);
    expect(find.text('Optional'), findsOneWidget);
    expect(find.text('Upload'), findsNWidgets(2));
    expect(find.text("I don't have this"), findsNWidgets(2));
    // A document configured Off never arrives, so it can never be drawn.
    expect(find.text('Shop Photo'), findsNothing);
  });

  testWidgets(
      '4 — skipping a mandatory paper keeps Submit live and sends only '
      'the keys that were tapped', (tester) async {
    final calls = <Map<String, dynamic>>[];
    await pump(tester, payload: _payload(), calls: calls);

    await tester.enterText(find.byType(TextField).first, 'Test Pharmacy');
    await tester.pumpAndSettle();

    // Tap "I don't have this" on the MANDATORY row only.
    await tester.tap(find.text("I don't have this").first);
    await tester.pumpAndSettle();

    // The backend's own undo caption appears; the optional row is untouched.
    expect(find.text('Undo'), findsOneWidget);
    expect(find.text("I don't have this"), findsOneWidget);

    final submit = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Submit registration'));
    expect(submit.onPressed, isNotNull,
        reason: 'a skipped mandatory document must never block Submit');

    await tester.ensureVisible(find.text('Submit registration'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Submit registration'));
    await tester.pumpAndSettle();

    final sub =
        calls.lastWhere((c) => c['fn'] == 'customer_registration_submit');
    final params = Map<String, dynamic>.from(sub['params'] as Map);
    expect(params['p_skips'], ['dl_20b'],
        reason: 'an untouched row is omitted, never defaulted to skipped');
    expect((params['p_values'] as Map)['pharmacy_name'], 'Test Pharmacy',
        reason: 'the form hands back what was typed, untouched');
  });

  testWidgets('5 — Docs pending prints the backend sentence, not a Dart one',
      (tester) async {
    await pump(tester, payload: _payload(pending: true));

    expect(find.text('Docs pending: Drug Licence 20B'), findsOneWidget);
    // Nothing in Dart composes the list, so no other wording of it exists.
    expect(find.textContaining('document(s)'), findsNothing);
  });

  testWidgets('6 — an imported customer gets the backend note, same screen',
      (tester) async {
    await pump(tester, payload: _payload(imported: true));

    expect(find.text('We already have your shop on file.'), findsOneWidget);
    expect(find.text('Documents'), findsOneWidget);
    expect(find.text('Submit registration'), findsOneWidget);
  });

  testWidgets('7 — the documents section is absent when show is false',
      (tester) async {
    final p = _payload();
    p['documents'] = {'show': false, 'rows': const []};
    await pump(tester, payload: p);

    expect(find.text('Documents'), findsNothing);
    expect(find.text('Drug Licence 20B *'), findsNothing);
    // The form itself is still there — Off hides the papers, not the form.
    expect(find.text('Pharmacy name *'), findsOneWidget);
  });

  testWidgets('8 — at 360px and 412px nothing overflows', (tester) async {
    for (final w in const [360.0, 412.0]) {
      await pump(tester,
          payload: _payload(pending: true), size: Size(w, 900));
      expect(tester.takeException(), isNull,
          reason: 'the registration form must lay out cleanly at ${w}px');
    }
  });

  test('9 — a PickedDoc is the file, not a decision about it', () {
    final d = PickedDoc(
        name: 'dl.jpg', ext: 'jpg', bytes: Uint8List.fromList(const [1, 2, 3]));
    expect(d.name, 'dl.jpg');
    expect(d.ext, 'jpg');
    expect(d.bytes.length, 3);
  });
}
