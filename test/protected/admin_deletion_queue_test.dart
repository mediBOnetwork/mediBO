// Holds down: the admin Deletion Requests queue lists rows verbatim from
// admin_deletion_request_list, Approve/Reject call admin_review_deletion_request
// with the right decision, and the way IN to that queue still wears its count.
//
// CHANGE #325 moved where that badge lives, and this file moved with it. The
// count used to be a plain int handed to AdminProfileMenuTiles, because
// Deletion Requests was one of ~20 features in the profile dropdown. It is now
// a registered feature in the "Customers & Suppliers" dashboard category, and
// its count arrives as the registry tile's own `badge_count` (badge_source
// 'deletion_requests', resolved in nav_badge_counts()). The behaviour under
// test is unchanged — a queue with seven pending requests must SAY seven on
// the way in — only the surface that says it moved.
//
// No network, no Supabase — the list/review RPCs are injected and the tile is
// fed an inline payload, so both stay VM-testable.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ui_copy_fixture.dart';

import 'package:pharma_b2b/screens/admin/admin_deletion_request_screen.dart';
import 'package:pharma_b2b/screens/admin/nav_registry_view.dart';
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
  setUp(seedUiCopy);
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

  testWidgets('the dashboard tile wears the deletion count', (tester) async {
    // The registry row, exactly as nav_registry() ships it.
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: NavTile(
            tile: const {
              'feature_key': 'admin.deletion_requests',
              'label': 'Deletion Requests',
              'icon_key': 'person_remove',
              'route_key': 'deletion_requests',
              'badge_count': 7,
              'badge_label': '7 deletion requests',
              'pinned': false,
            },
            onOpen: (_) {},
            onPin: (_) async => const {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Deletion Requests'), findsOneWidget);
    expect(find.text('7'), findsOneWidget);
  });

  testWidgets('a tap on that tile carries the queue route to the shell',
      (tester) async {
    // The other half of the badge's job: the count is only useful if the way in
    // actually opens the queue. #645/#646 shipped rows that did nothing.
    Map<String, dynamic>? opened;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: NavTile(
          tile: const {
            'feature_key': 'admin.deletion_requests',
            'label': 'Deletion Requests',
            'icon_key': 'person_remove',
            'route_key': 'deletion_requests',
            'deep_link': '/admin/go/deletion_requests',
            'badge_count': 7,
            'pinned': false,
          },
          onOpen: (t) => opened = t,
          onPin: (_) async => const {},
        ),
      ),
    ));
    await tester.tap(find.text('Deletion Requests'));
    expect(opened?['route_key'], 'deletion_requests');
    expect(opened?['deep_link'], '/admin/go/deletion_requests');
  });
}
