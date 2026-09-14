// CMD #1935 — what step 2 of customer onboarding may never go back to doing.
//
// The checklist is a TABLE (customer_doc_types) rendered through ONE RPC. The
// three things that make that true, and that a later refactor would quietly
// undo, are held down here:
//
//   1. Items render in PAYLOAD ORDER, and every string on a card — label,
//      requirement caption, chip, button — is the backend's. The fixture is
//      deliberately not alphabetical.
//   2. "I don't have this" appears ONLY where the backend said can_skip. A
//      REQUIRED document has no checkbox at all — not a disabled one — and
//      dl_20b is required in the fixture for exactly that reason.
//   3. The skip call sends the backend's own key and the boolean, and the
//      screen re-renders from the CHECKLIST THE RPC RETURNED rather than
//      flipping its own copy of the row.
//
// Plus the summary line: how many required documents are left is counted in
// the backend and printed verbatim, so "1 required document still to upload."
// is never pluralised in Dart.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/auth/customer_docs_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _item({
  required String key,
  required String label,
  required bool required_,
  String status = 'missing',
  String statusLabel = 'Not uploaded',
  String statusTone = 'warning',
  bool skipped = false,
  String retake = '',
}) =>
    {
      'key': key,
      'label': label,
      'hint': '',
      'required': required_,
      'can_skip': !required_,
      'skip_label': required_ ? '' : "I don't have this",
      'skipped': skipped,
      'requirement_label': required_ ? 'Required' : 'Optional',
      'camera_only': false,
      'camera_only_note': '',
      'has': status != 'missing',
      'status': status,
      'status_label': statusLabel,
      'status_tone': statusTone,
      'action_label': 'Upload',
      'retake_reason': retake,
      'retake_label': 'Retake',
      'number': '',
    };

Map<String, dynamic> _payload({
  List<Map<String, dynamic>>? items,
  int left = 1,
}) =>
    {
      'ok': true,
      'bucket': 'kyc-docs',
      'upload_prefix': 'u1',
      'title': 'Your documents',
      'step_label': 'Step 2 of 2',
      'subtitle': 'Upload what you have.',
      'close_label': 'Close',
      'empty_line': 'No documents are being collected right now.',
      'items': items ??
          [
            _item(key: 'dl_20b', label: 'Drug Licence 20B', required_: true),
            _item(key: 'gst', label: 'GST Certificate', required_: false),
            _item(key: 'pan', label: 'PAN Card', required_: false),
          ],
      'item_count': 3,
      'required_left': left,
      'done': left == 0,
      'summary_title': left == 0 ? 'All required documents are in' : '',
      'summary_line': left == 0
          ? 'We will verify them and approve your account.'
          : '$left required document still to upload.',
      'summary_tone': left == 0 ? 'success' : 'warning',
    };

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  tearDown(() {
    CustomerDocsScreen.rpcTransport = null;
    CustomerDocsScreen.uploadTransport = null;
  });

  Future<void> pump(WidgetTester t) async {
    await t.pumpWidget(const MaterialApp(home: CustomerDocsScreen()));
    await t.pumpAndSettle();
  }

  testWidgets('renders the payload verbatim, in payload order', (t) async {
    CustomerDocsScreen.rpcTransport = (fn, p) async {
      expect(fn, 'kyc_doc_checklist');
      return _payload();
    };
    await pump(t);

    expect(find.text('Step 2 of 2'), findsOneWidget);
    expect(find.text('1 required document still to upload.'), findsOneWidget);

    // Payload order, not alphabetical: Drug Licence 20B, GST, PAN.
    final labels = t
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.data ?? '')
        .where((s) =>
            s == 'Drug Licence 20B' || s == 'GST Certificate' || s == 'PAN Card')
        .toList();
    expect(labels, ['Drug Licence 20B', 'GST Certificate', 'PAN Card']);
  });

  testWidgets('a required doc offers no skip; an optional one does', (t) async {
    CustomerDocsScreen.rpcTransport = (fn, p) async => _payload();
    await pump(t);

    // Two optional documents in the fixture, so exactly two checkboxes — the
    // required one contributes none rather than a disabled one.
    expect(find.byType(Checkbox), findsNWidgets(2));
    expect(find.text("I don't have this"), findsNWidgets(2));
  });

  testWidgets('skip sends the backend key and re-renders the RPC reply',
      (t) async {
    final calls = <Map<String, dynamic>>[];
    CustomerDocsScreen.rpcTransport = (fn, p) async {
      calls.add({'fn': fn, ...?p});
      if (fn == 'kyc_doc_skip') {
        return {
          'ok': true,
          'message': 'Noted — you can upload it later.',
          'checklist': _payload(items: [
            _item(key: 'dl_20b', label: 'Drug Licence 20B', required_: true),
            _item(
                key: 'gst',
                label: 'GST Certificate',
                required_: false,
                status: 'not_available',
                statusLabel: 'Marked not available',
                statusTone: 'neutral',
                skipped: true),
            _item(key: 'pan', label: 'PAN Card', required_: false),
          ]),
        };
      }
      return _payload();
    };
    await pump(t);

    await t.tap(find.byType(Checkbox).first);
    await t.pumpAndSettle();

    final skip = calls.firstWhere((c) => c['fn'] == 'kyc_doc_skip');
    expect(skip['p_key'], 'gst');
    expect(skip['p_skip'], true);
    // The new state is the SERVER's — the screen printed the label the reply
    // carried, not a word of its own.
    expect(find.text('Marked not available'), findsOneWidget);
  });

  testWidgets('an unreadable document asks for a retake, in backend copy',
      (t) async {
    CustomerDocsScreen.rpcTransport = (fn, p) async => _payload(items: [
          _item(
              key: 'gst',
              label: 'GST Certificate',
              required_: false,
              status: 'submitted',
              statusLabel: 'Submitted',
              statusTone: 'info',
              retake: 'GSTIN could not be read — upload a clearer photo.'),
        ]);
    await pump(t);

    expect(find.text('GSTIN could not be read — upload a clearer photo.'),
        findsOneWidget);
    // The button becomes the backend's retake word, not "Upload" again.
    expect(find.text('Retake'), findsOneWidget);
  });

  testWidgets('a refusal renders the backend sentence, never a throw',
      (t) async {
    CustomerDocsScreen.rpcTransport = (fn, p) async => {
          'ok': false,
          'error': 'not_signed_in',
          'title': 'Your documents',
          'message': 'Sign in to upload your documents.',
          'items': <dynamic>[],
        };
    await pump(t);

    expect(find.text('Sign in to upload your documents.'), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing);
  });

  testWidgets('an empty checklist is an empty state, not a blank screen',
      (t) async {
    CustomerDocsScreen.rpcTransport = (fn, p) async =>
        _payload(items: <Map<String, dynamic>>[], left: 0);
    await pump(t);

    expect(find.text('No documents are being collected right now.'),
        findsOneWidget);
    expect(find.text('All required documents are in'), findsOneWidget);
  });
}
