// CMD #1913 — the Profile & KYC tab on the customer page, pinned.
//
// Three faults met here and the fix is entirely in the backend, so what this
// file holds down is the CONTRACT the backend now depends on:
//
//   * the tab renders from a payload like every other tab — a `kv` block whose
//     chip is the KYC verdict, and a `list` block of the documents;
//   * a PENDING document carries Verify / Reject, and Reject collects the
//     reason and hands it to kyc_review_set as `p_reason`. If the confirm ever
//     stops passing `reason_arg` through, a rejection reaches the shop with no
//     explanation — the exact thing kyc_review.err_no_reason exists to prevent;
//   * a document with no actions (already verified) renders no buttons.
//
// The strings are ALL payload. A regression that starts wording the chip, the
// status or the buttons in Dart fails here.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/admin_customer_page.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _page() => {
      'ok': true,
      'customer_id': 'c-1',
      'title': 'Prince Pharmacy',
      'subtitle': 'Raipur  ·  PRI101',
      'back_label': 'Customers',
      'empty_label': 'Nothing here yet.',
      'chips': const [],
      'contacts': const [],
      'menu': const [],
      'tabs': const [
        {'key': 'info', 'label': 'Info', 'rpc': 'admin_customer_tab_info'},
        {
          'key': 'profile',
          'label': 'Profile & KYC',
          'rpc': 'admin_customer_tab_profile'
        },
      ],
      'default_tab': 'profile',
    };

Map<String, dynamic> _profileTab() => {
      'ok': true,
      'blocks': [
        {
          'kind': 'kv',
          'title': 'KYC status',
          'chip': {
            'show': true,
            'label': 'KYC awaiting review',
            'bg': '#EFF6FF',
            'fg': '#1E40AF',
          },
          'rows': [
            {'label': 'Status', 'value': 'Awaiting verification'},
            {'label': 'Drug licence', 'value': 'CG-RPR-20B-4471'},
          ],
        },
        {
          'kind': 'list',
          'title': 'Uploaded documents',
          'empty': 'This shop has not uploaded anything yet.',
          'items': [
            {
              'title': 'Drug licence',
              'subtitle': 'licence.jpg  ·  CG-RPR-20B-4471',
              'meta': 'Uploaded 4 minutes ago  ·  13 Oct 2027',
              'chip': {
                'show': true,
                'label': 'Awaiting verification',
                'bg': '#EFF6FF',
                'fg': '#1E40AF',
              },
              'actions': [
                {
                  'label': 'Verify',
                  'tone': 'success',
                  'rpc': 'kyc_review_set',
                  'args': {'p_doc_id': 'doc-1', 'p_status': 'verified'},
                },
                {
                  'label': 'Reject',
                  'tone': 'danger',
                  'rpc': 'kyc_review_set',
                  'args': {'p_doc_id': 'doc-1', 'p_status': 'rejected'},
                  'confirm': {
                    'title': 'Reject this document?',
                    'body': 'The shop sees your reason word for word.',
                    'ok': 'Reject',
                    'cancel': 'Cancel',
                    'needs_reason': true,
                    'reason_arg': 'p_reason',
                    'reason_hint': 'Tell them what is wrong.',
                    'reason_error': 'A rejection needs a reason.',
                  },
                },
              ],
            },
            {
              'title': 'GST certificate',
              'subtitle': 'gst.pdf',
              'meta': 'Uploaded 2 days ago  ·  No expiry on file',
              'chip': {
                'show': true,
                'label': 'Verified',
                'bg': '#D1FAE5',
                'fg': '#065F46',
              },
              'actions': const [],
            },
          ],
        },
      ],
    };

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);
  tearDown(() => AdminCustomerPage.rpcOverride = null);

  Future<void> tall(WidgetTester t) async {
    await t.binding.setSurfaceSize(const Size(1200, 2400));
    addTearDown(() => t.binding.setSurfaceSize(null));
  }

  testWidgets('Profile & KYC renders the verdict, the documents and their '
      'status — every string from the payload', (t) async {
    await tall(t);
    AdminCustomerPage.rpcOverride = (rpc, params) async {
      if (rpc == 'admin_customer_page') return _page();
      if (rpc == 'admin_customer_tab_profile') return _profileTab();
      return {'ok': true, 'blocks': const []};
    };
    await t.pumpWidget(
        const MaterialApp(home: AdminCustomerPage(customerId: 'c-1')));
    await t.pumpAndSettle();

    expect(find.text('Profile & KYC'), findsOneWidget);
    expect(find.text('KYC status'), findsOneWidget);
    expect(find.text('KYC awaiting review'), findsOneWidget);
    expect(find.text('CG-RPR-20B-4471'), findsOneWidget);
    expect(find.text('Uploaded documents'), findsOneWidget);
    expect(find.text('Drug licence'), findsWidgets);
    expect(find.text('Uploaded 4 minutes ago  ·  13 Oct 2027'), findsOneWidget);
    // The verdict a reviewer already gave is on the row, and carries no buttons.
    expect(find.text('Verified'), findsOneWidget);
    expect(find.text('Verify'), findsOneWidget);
    expect(find.text('Reject'), findsOneWidget);
  });

  testWidgets('Reject collects the reason and sends it as the argument the '
      'payload named', (t) async {
    await tall(t);
    Map<String, dynamic>? sent;
    AdminCustomerPage.rpcOverride = (rpc, params) async {
      if (rpc == 'admin_customer_page') return _page();
      if (rpc == 'admin_customer_tab_profile') return _profileTab();
      if (rpc == 'kyc_review_set') {
        sent = Map<String, dynamic>.from(params);
        return {'ok': true, 'message': 'Rejected.'};
      }
      return {'ok': true, 'blocks': const []};
    };
    await t.pumpWidget(
        const MaterialApp(home: AdminCustomerPage(customerId: 'c-1')));
    await t.pumpAndSettle();

    await t.tap(find.text('Reject').first);
    await t.pumpAndSettle();
    expect(find.text('Reject this document?'), findsOneWidget);

    // An empty reason is refused with the backend's own error copy.
    await t.tap(find.widgetWithText(FilledButton, 'Reject'));
    await t.pumpAndSettle();
    expect(find.text('A rejection needs a reason.'), findsOneWidget);
    expect(sent, isNull);

    await t.enterText(find.byType(TextField), 'Licence number is unreadable');
    await t.tap(find.widgetWithText(FilledButton, 'Reject'));
    await t.pumpAndSettle();
    // The success toast owns a real Timer; let it expire inside the test.
    await t.pump(const Duration(seconds: 6));

    expect(sent, isNotNull);
    expect(sent!['p_doc_id'], 'doc-1');
    expect(sent!['p_status'], 'rejected');
    expect(sent!['p_reason'], 'Licence number is unreadable');
  });
}
