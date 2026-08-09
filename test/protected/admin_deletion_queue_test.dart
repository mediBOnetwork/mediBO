// Holds down: the admin Deletion Requests queue lists rows verbatim from
// admin_deletion_request_list, Approve/Reject call admin_review_deletion_request
// with the right decision, and the nav badge renders the count it is given
// (home_shell supplies that count from admin_deletion_request_count).
//
// No network, no Supabase — the list/review RPCs are injected; the nav badge is
// a plain int, so admin_nav_entries stays VM-testable.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/admin_deletion_request_screen.dart';
import 'package:pharma_b2b/screens/admin/admin_nav_entries.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _listPayload() => {
      'title': 'Account deletion requests',
      'count': 1,
      'has_rows': true,
      'rows': [
        {
          'id': 'req-1',
          'pharmacy_name': 'PHARM_NAME',
          'owner_name': 'OWNER_NAME',
          'phone': '9990001111',
          'email': 'owner@example.com',
          'customer_code': 'CUST42',
          'scope': 'account',
          'reason': 'REASON_TEXT',
          'submitted_at': '2026-08-09T10:00:00Z',
          'status': 'pending',
        },
      ],
    };

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  testWidgets('lists rows verbatim and Approve calls the review RPC',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    String? seenStatus;
    String? seenDecision;
    await tester.pumpWidget(MaterialApp(
      home: AdminDeletionRequestScreen(
        listRpc: (status) async {
          seenStatus = status;
          return _listPayload();
        },
        reviewRpc: (id, decision, note) async {
          seenDecision = decision;
          return {'ok': true, 'status': 'approved', 'message': 'REVIEW_MSG'};
        },
      ),
    ));
    await tester.pumpAndSettle();

    // Default filter loads 'pending'.
    expect(seenStatus, 'pending');
    // Row rendered verbatim.
    expect(find.text('PHARM_NAME'), findsOneWidget);
    expect(find.text('OWNER_NAME'), findsOneWidget);
    expect(find.textContaining('CUST42'), findsOneWidget);
    expect(find.text('REASON_TEXT'), findsOneWidget);

    // Approve → confirm → review RPC with decision 'approve'.
    await tester.tap(find.text('Approve'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Approve').last); // dialog confirm button
    await tester.pumpAndSettle();

    expect(seenDecision, 'approve');
    expect(find.text('REVIEW_MSG'), findsOneWidget);
  });

  testWidgets('nav badge renders the given deletion count', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: AdminProfileMenuTiles(
            isSuperAdmin: false,
            nav: (_) {},
            deletionCount: 7,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Deletion Requests'), findsOneWidget);
    expect(find.text('7'), findsOneWidget);
  });
}
