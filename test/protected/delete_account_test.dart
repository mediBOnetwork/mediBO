// Holds down: the customer "Delete my account" / "Delete my data only" actions
// call request_account_deletion with the correct scope, and render the RPC's
// returned message verbatim — no deletion wording is invented in Dart.
//
// No network, no Supabase — the rpc is injected.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/widgets/delete_account_section.dart';

import 'ui_copy_fixture.dart';

Future<void> _pump(
    WidgetTester tester, DeletionRequestRpc rpc) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: DeleteAccountSection(rpc: rpc)),
  ));
  await tester.pumpAndSettle();
}

// The destructive buttons live in a collapsed "danger zone" so a tap meant for
// Logout can't hit Delete. Every action test opens it first.
Future<void> _expand(WidgetTester tester) async {
  await tester.tap(find.text('Delete account or data'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(seedUiCopy);

  testWidgets('the delete buttons are hidden until the danger zone is opened',
      (tester) async {
    await _pump(tester, (scope, reason) async => {'ok': true, 'message': 'x'});
    // Collapsed: neither destructive action is reachable.
    expect(find.text('Delete my account'), findsNothing);
    expect(find.text('Delete my data only'), findsNothing);

    await _expand(tester);
    expect(find.text('Delete my account'), findsOneWidget);
    expect(find.text('Delete my data only'), findsOneWidget);
  });

  testWidgets('Delete my account → confirm → request_account_deletion("account")',
      (tester) async {
    String? seenScope;
    await _pump(tester, (scope, reason) async {
      seenScope = scope;
      return {'ok': true, 'title': 'RESULT_TITLE', 'message': 'RESULT_MESSAGE'};
    });

    await _expand(tester);
    await tester.tap(find.text('Delete my account'));
    await tester.pumpAndSettle();
    // Confirm dialog is up; the RPC has NOT been called yet.
    expect(seenScope, isNull);

    // Continue is dead until the confirm word is typed.
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(seenScope, isNull, reason: 'a tap alone must not delete');

    await tester.enterText(find.byType(TextField).first, 'DELETE');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(seenScope, 'account');
    // Result dialog renders the RPC payload verbatim.
    expect(find.text('RESULT_TITLE'), findsOneWidget);
    expect(find.text('RESULT_MESSAGE'), findsOneWidget);
  });

  testWidgets('Delete my data only → request_account_deletion("data")',
      (tester) async {
    String? seenScope;
    await _pump(tester, (scope, reason) async {
      seenScope = scope;
      return {'ok': true, 'message': 'DATA_RESULT'};
    });

    await _expand(tester);
    await tester.tap(find.text('Delete my data only'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'DELETE');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(seenScope, 'data');
    expect(find.text('DATA_RESULT'), findsOneWidget);
  });

  testWidgets('Cancel does not call the RPC', (tester) async {
    var called = false;
    await _pump(tester, (scope, reason) async {
      called = true;
      return {'ok': true, 'message': 'x'};
    });

    await _expand(tester);
    await tester.tap(find.text('Delete my account'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(called, isFalse);
  });
}
