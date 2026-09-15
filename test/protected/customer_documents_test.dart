// PROTECTED — CMD #1937.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes the customer Documents contract.
//
// What this holds down, for the ONE widget the reviewer's Documents tab and the
// shop's own Licence & documents page both render:
//
//   1. ROW ORDER IS THE PAYLOAD'S. customer_documents_screen() orders by
//      customer_doc_types.sort_order in Postgres; the fixture is deliberately
//      not alphabetical, so any client-side sort fails this test.
//
//   2. EVERY STRING IS THE BACKEND'S, VERBATIM. The status chip, the number
//      line, the valid-till line, the rejection sentence and the header summary
//      are printed exactly as sent — never re-worded, never re-pluralised and
//      never assembled in Dart. In particular the header is ONE `summary_line`,
//      not "summary_label" plus a separator the app chose.
//
//   3. ACTIONS ARE THE BACKEND'S LIST. A row draws exactly the buttons in
//      `actions[]`, with their labels, in their order. A viewer the payload gave
//      no Approve gets no Approve — the widget never infers one from a status.
//
//   4. REJECT CARRIES A REASON. Approve calls kyc_review_set with
//      status 'verified'; Reject opens the reason sheet and submits the typed
//      sentence as p_reason. A rejection is never sent reasonless (the RPC
//      refuses one, and the sheet's button mirrors that rule).
//
//   5. THE APPROVE-ACCOUNT BUTTON IS THE #1935 GATE. `approve.can` false means
//      disabled, with the backend's own reason printed under it — never a
//      button that fails after the tap.
//
//   6. NOT-OK RENDERS THE BACKEND'S MESSAGE. ok:false is an error state with
//      that sentence and Retry, not an exception and not an empty list.
//
// No network, no Supabase, no goldens.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/customer_documents_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _row({
  required String kind,
  required String label,
  String status = 'missing',
  String statusLabel = 'Missing',
  String tone = 'warning',
  String numberLine = '',
  String validLine = '',
  String reasonLine = '',
  bool hasFile = false,
  List<Map<String, dynamic>> actions = const [],
}) =>
    {
      'kind': kind,
      'label': label,
      'hint': '',
      'required': true,
      'requirement_label': 'Required',
      'has_file': hasFile,
      'doc_id': hasFile ? 'doc-$kind' : null,
      'bucket': 'kyc-docs',
      'path': hasFile ? 'u/$kind.jpg' : '',
      'file_name': hasFile ? '$kind.jpg' : '',
      'is_image': hasFile,
      'camera_only': false,
      'number': '',
      'number_line': numberLine,
      'valid_to': null,
      'valid_line': validLine,
      'status': status,
      'status_label': statusLabel,
      'status_tone': tone,
      'reason': '',
      'reason_line': reasonLine,
      'source_line': '',
      'sheet_title': 'Add $label',
      'actions': actions,
    };

const _approveAction = {
  'key': 'approve',
  'label': 'Approve',
  'tone': 'success',
  'style': 'filled',
};
const _rejectAction = {
  'key': 'reject',
  'label': 'Reject',
  'tone': 'danger',
  'style': 'outlined',
};
const _uploadAction = {
  'key': 'upload',
  'label': 'Upload',
  'tone': 'brand',
  'style': 'filled',
};

Map<String, dynamic> _payload({
  required List<Map<String, dynamic>> rows,
  bool canReview = true,
  Map<String, dynamic>? approve,
  String summaryLine = '1 of 3 verified · Drug Licence 20B missing',
}) =>
    {
      'ok': true,
      'customer_id': 'cust-1',
      'customer_name': 'SHREE MEDICAL STORES',
      'is_self': false,
      'can_review': canReview,
      'can_upload': true,
      'title': 'Documents',
      'subtitle': 'Licence and KYC documents for this shop.',
      'empty_note': 'No document types are configured yet.',
      'retry_label': 'Retry',
      'summary_line': summaryLine,
      'summary_tone': 'warning',
      'verified_count': 1,
      'total_count': 3,
      'approve': approve ??
          {
            'can': false,
            'is_approved': false,
            'label': 'Approve account',
            'reason': 'Drug Licence 20B missing',
            'has_fix': false,
          },
      'viewer_title': 'Document',
      'viewer_close': 'Close',
      'view_label': 'View',
      'reject_title': 'Why is it rejected?',
      'reject_hint': 'The shop sees this sentence, so say what to fix.',
      'reject_label': 'Reason',
      'reject_submit': 'Reject document',
      'reject_cancel': 'Cancel',
      'upload_camera': 'Take a photo',
      'upload_file': 'Choose a file',
      'rows': rows,
    };

/// The payload order is NOT alphabetical and NOT status-grouped: a client sort
/// of any kind reorders these three.
final _threeRows = [
  _row(
    kind: 'dl_20b',
    label: 'Drug Licence 20B',
    actions: const [_uploadAction],
  ),
  _row(
    kind: 'gst',
    label: 'GST Certificate',
    status: 'verified',
    statusLabel: 'Verified',
    tone: 'success',
    numberLine: 'No. 23AABCU9603R1ZX',
    validLine: 'Valid till 31 Mar 2027',
    hasFile: true,
    actions: const [_rejectAction],
  ),
  _row(
    kind: 'pan',
    label: 'PAN Card',
    status: 'rejected',
    statusLabel: 'Rejected',
    tone: 'danger',
    numberLine: 'No. AABCU9603R',
    reasonLine: 'Rejected: The photo is blurred.',
    hasFile: true,
    actions: const [_approveAction, _rejectAction],
  ),
];

void main() {
  // Mobile-first: every assertion below is made at a 360 px phone viewport, the
  // width 99% of mediBO runs at.
  final calls = <({String fn, Map<String, dynamic>? params})>[];

  setUpAll(() => RenderLog.flushEnabled = false);

  setUp(() {
    calls.clear();
    CustomerDocumentsTransport.signedUrl = (_, _) async => '';
    CustomerDocumentsTransport.upload =
        (_, path, _, _) async => path;
    CustomerDocumentsTransport.pick = (_) async =>
        (name: 'dl.jpg', ext: 'jpg', bytes: Uint8List(3));
  });

  tearDown(() {
    CustomerDocumentsTransport.rpc = null;
    CustomerDocumentsTransport.signedUrl = null;
    CustomerDocumentsTransport.upload = null;
    CustomerDocumentsTransport.pick = null;
  });

  void wire(Map<String, dynamic> payload,
      {Map<String, dynamic>? writeResult}) {
    CustomerDocumentsTransport.rpc = (fn, params) async {
      calls.add((fn: fn, params: params));
      if (fn == 'customer_documents_screen') return payload;
      return writeResult ?? {'ok': true, 'message': 'Marked verified.'};
    };
  }

  Future<void> pump(WidgetTester tester, {bool embedded = false}) async {
    tester.view.physicalSize = const Size(360, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // A fresh key per pump: without one the State is reused across a second
    // pumpWidget in the same test and the FIRST payload keeps rendering.
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CustomerDocumentsPanel(
          key: UniqueKey(),
          customerId: 'cust-1',
          embedded: embedded,
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('1. rows render in payload order — no client sort',
      (tester) async {
    wire(_payload(rows: _threeRows));
    await pump(tester);

    final labels = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .where((s) =>
            s == 'Drug Licence 20B' || s == 'GST Certificate' || s == 'PAN Card')
        .toList();
    expect(labels, ['Drug Licence 20B', 'GST Certificate', 'PAN Card']);
  });

  testWidgets('2. every line is the payload string, verbatim', (tester) async {
    wire(_payload(rows: _threeRows));
    await pump(tester);

    // The header is ONE sentence built in SQL — the widget never joins a count
    // to a missing-docs clause with a separator of its own.
    expect(find.text('1 of 3 verified · Drug Licence 20B missing'), findsOne);
    expect(find.text('Missing'), findsOne);
    expect(find.text('Verified'), findsOne);
    expect(find.text('Rejected'), findsOne);
    expect(find.text('No. 23AABCU9603R1ZX'), findsOne);
    expect(find.text('Valid till 31 Mar 2027'), findsOne);
    expect(find.text('Rejected: The photo is blurred.'), findsOne);
  });

  testWidgets('3. a row draws exactly the backend actions[]', (tester) async {
    wire(_payload(rows: _threeRows));
    await pump(tester);

    // dl_20b offered Upload only; gst offered Reject only; pan offered both.
    // Two Rejects, one Approve, one Upload — nothing inferred from a status.
    expect(find.widgetWithText(OutlinedButton, 'Reject'), findsNWidgets(2));
    expect(find.widgetWithText(FilledButton, 'Approve'), findsOne);
    expect(find.widgetWithText(FilledButton, 'Upload'), findsOne);

    // The reviewer flag off means the payload sends no verdict actions at all,
    // and the widget adds none back.
    final selfRows = [
      _row(
        kind: 'gst',
        label: 'GST Certificate',
        status: 'submitted',
        statusLabel: 'Submitted',
        tone: 'info',
        hasFile: true,
        actions: const [],
      ),
    ];
    wire(_payload(rows: selfRows, canReview: false));
    await pump(tester);
    expect(find.text('Approve'), findsNothing);
    expect(find.text('Reject'), findsNothing);
  });

  testWidgets('4. approve verifies; reject carries the typed reason',
      (tester) async {
    // ONE row, so both verdict buttons are on screen at a phone width and the
    // taps are unambiguous.
    wire(_payload(rows: [_threeRows.last]));
    await pump(tester);

    await tester.tap(find.widgetWithText(FilledButton, 'Approve'));
    await tester.pumpAndSettle();

    final approve = calls.firstWhere((c) => c.fn == 'kyc_review_set');
    expect(approve.params?['p_status'], 'verified');
    expect(approve.params?['p_doc_id'], 'doc-pan');
    expect(approve.params?['p_reason'], isNull);

    calls.clear();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Reject').first);
    await tester.pumpAndSettle();
    expect(find.text('Why is it rejected?'), findsOne);

    // Reason empty → the RPC refuses a reasonless rejection, so the button is
    // disabled rather than discovering that after the tap.
    final submit = find.widgetWithText(FilledButton, 'Reject document');
    expect(tester.widget<FilledButton>(submit).onPressed, isNull);

    await tester.enterText(find.byType(TextField), 'Number is not readable.');
    await tester.pumpAndSettle();
    await tester.tap(submit);
    await tester.pumpAndSettle();

    final reject = calls.firstWhere((c) => c.fn == 'kyc_review_set');
    expect(reject.params?['p_status'], 'rejected');
    expect(reject.params?['p_reason'], 'Number is not readable.');
  });

  testWidgets('5. Approve account is the #1935 gate, with its reason',
      (tester) async {
    wire(_payload(rows: _threeRows));
    await pump(tester);

    // The row's verdict button and the account gate never read the same word:
    // the gate is 'Approve account', and it is disabled.
    final gate = find.widgetWithText(FilledButton, 'Approve account');
    final disabled = tester
        .widgetList<FilledButton>(find.byType(FilledButton))
        .where((b) => b.onPressed == null);
    expect(disabled, isNotEmpty);
    expect(find.text('Drug Licence 20B missing'), findsOne);
    expect(gate, findsOne);

    // can:true enables it, and the refusal sentence is gone.
    wire(_payload(
      rows: _threeRows,
      approve: const {
        'can': true,
        'is_approved': false,
        'label': 'Approve account',
        'reason': '',
        'has_fix': false,
      },
      summaryLine: '3 of 3 verified · All documents verified',
    ));
    await pump(tester);
    expect(find.text('Drug Licence 20B missing'), findsNothing);
  });

  testWidgets('6. ok:false prints the backend message with Retry',
      (tester) async {
    CustomerDocumentsTransport.rpc = (fn, params) async {
      calls.add((fn: fn, params: params));
      return {
        'ok': false,
        'error': 'not_authorized',
        'message': 'You do not have access to these documents.',
        'retry_label': 'Retry',
      };
    };
    await pump(tester);

    expect(find.text('You do not have access to these documents.'), findsOne);
    expect(find.widgetWithText(OutlinedButton, 'Retry'), findsOne);
    expect(find.text('Approve'), findsNothing);
  });

  testWidgets('7. upload goes through the backend path, as this customer',
      (tester) async {
    wire(_payload(rows: _threeRows), writeResult: {
      'ok': true,
      'bucket': 'kyc-docs',
      'path': 'uid/cust-1/dl_20b-x.jpg',
      'message': 'Document saved.',
    });
    await pump(tester);

    await tester.tap(find.widgetWithText(FilledButton, 'Upload'));
    await tester.pumpAndSettle();
    // The sheet asks camera or file — both are the payload's own captions.
    expect(find.text('Take a photo'), findsOne);
    await tester.tap(find.text('Take a photo'));
    await tester.pumpAndSettle();

    final pathCall =
        calls.firstWhere((c) => c.fn == 'customer_doc_upload_path');
    expect(pathCall.params?['p_customer_id'], 'cust-1');
    expect(pathCall.params?['p_kind'], 'dl_20b');

    final reg =
        calls.firstWhere((c) => c.fn == 'customer_doc_upload_register');
    expect(reg.params?['p_customer_id'], 'cust-1');
    expect(reg.params?['p_kind'], 'dl_20b');
    expect(reg.params?['p_path'], 'uid/cust-1/dl_20b-x.jpg');
  });
}
