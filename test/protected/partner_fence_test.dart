// CHANGE #352 — the Partner fence card, on the screen a super-admin already
// opens to manage a partner (Payment and Partner -> a partner -> Partner
// console).
//
// The eight approved critical findings on the partner surface were all one
// shape: a partner authenticates as 'admin', so an admin-gated RPC answers it
// and nothing downstream asks which ZONE it is in or whether its matrix ever
// granted the feature. The backend now refuses; this file pins the half a
// human can see, so "we fixed it" cannot quietly become "we fixed it and
// nobody can tell".
//
// What is held down here:
//   1. Every number and every word on the card is the BACKEND's. The card
//      renders `fence.rows` verbatim, in payload order, and never computes a
//      count, a status word or a plural.
//   2. The status pill is `status_label`/`status_tone` — not a Dart guess made
//      from whether a count is zero.
//   3. Absence is explicit: no `fence` block -> no card at all (an older
//      backend must not crash the console), and a check that has not been run
//      shows the backend's own "not checked yet" line rather than a blank.
//   4. The live-check result renders the same way — one row per probe, with
//      the backend's own refused/STILL OPEN word and tone, so a regression
//      reads as red on the screen and not just in a log.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/admin_partner_console_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

/// The shape admin_partner_console() actually returns, trimmed to what this
/// file reads. The fence block is verbatim from partner_fence_card() on the
/// live schema after the migration.
Map<String, dynamic> consolePayload({Map<String, dynamic>? fence}) => {
      'ok': true,
      'partner_name': 'Jai Mahakal Medical And Surgical',
      'users_title': 'Logins',
      'users_subtitle': '',
      'empty_users': 'No logins yet',
      'add_hint': 'Phone or email',
      'name_hint': 'Name',
      'add_label': 'Add login',
      'remove_label': 'Remove',
      'perm_title': 'Access',
      'perm_subtitle': '',
      'zone_locked_label': 'Zone 1',
      'audit_title': 'Activity',
      'empty_audit': 'Nothing yet',
      'users': const [],
      'features': const [],
      'audit': const [],
      if (fence != null) 'fence': fence,
    };

Map<String, dynamic> fenceBlock() => {
      'title': 'Partner fence',
      'subtitle': 'What a partner login can reach over the raw API, not just '
          'which tile it is shown.',
      'status_label': 'Enforced',
      'status_tone': 'success',
      'verify_label': 'Run the live check',
      'never_run': 'Not checked yet in this session.',
      'rows': const [
        {
          'label': 'Admin RPCs now closed to a partner',
          'value': '184',
          'tone': 'success'
        },
        {
          'label': 'Fulfilment RPCs a partner may call',
          'value': '130',
          'tone': 'neutral'
        },
        {
          'label': 'Fulfilment RPCs clamped to the partner zone',
          'value': '9',
          'tone': 'success'
        },
        {
          'label': 'mediBO-only RPCs fenced off the partner surface',
          'value': '103',
          'tone': 'success'
        },
      ],
    };

Widget host(Map<String, dynamic> payload,
        {Map<String, dynamic>? result, VoidCallback? onVerify}) =>
    MaterialApp(
      home: Scaffold(
        body: PartnerConsoleView(
          payload: payload,
          identity: TextEditingController(),
          name: TextEditingController(),
          onAdd: () {},
          onRemove: (_) {},
          onAccess: (_, __) {},
          fenceResult: result,
          onVerifyFence: onVerify,
        ),
      ),
    );

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  testWidgets('the card prints the backend rows verbatim, in payload order',
      (tester) async {
    await tester.pumpWidget(host(consolePayload(fence: fenceBlock())));
    await tester.pumpAndSettle();

    expect(find.text('Partner fence'), findsOneWidget);
    // The four counts are the backend's strings — not recomputed, not
    // reformatted, not pluralised in Dart.
    for (final row in (fenceBlock()['rows'] as List)) {
      final m = Map<String, dynamic>.from(row as Map);
      expect(find.text(m['label'] as String), findsOneWidget);
      expect(find.text(m['value'] as String), findsOneWidget);
    }

    // Payload order, not alphabetical and not sorted by size.
    final labels = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .toList();
    expect(labels.indexOf('Admin RPCs now closed to a partner'),
        lessThan(labels.indexOf('Fulfilment RPCs a partner may call')));
  });

  testWidgets('the status pill is the backend word, not a Dart verdict',
      (tester) async {
    final bad = fenceBlock()
      ..['status_label'] = 'Not enforced'
      ..['status_tone'] = 'danger';
    await tester.pumpWidget(host(consolePayload(fence: bad)));
    await tester.pumpAndSettle();
    // Same numbers as the green fixture; only the backend's word changed.
    expect(find.text('Not enforced'), findsOneWidget);
    expect(find.text('Enforced'), findsNothing);
    expect(find.text('184'), findsOneWidget);
  });

  testWidgets('no fence block -> no card, and the console still renders',
      (tester) async {
    await tester.pumpWidget(host(consolePayload()));
    await tester.pumpAndSettle();
    expect(find.text('Partner fence'), findsNothing);
    expect(find.byKey(const ValueKey('partner_fence_verify')), findsNothing);
    // The rest of the screen is untouched.
    expect(find.text('Logins'), findsOneWidget);
    expect(find.text('Access'), findsOneWidget);
  });

  testWidgets('before a run the backend supplies the empty line', (tester) async {
    await tester.pumpWidget(host(consolePayload(fence: fenceBlock())));
    await tester.pumpAndSettle();
    expect(find.text('Not checked yet in this session.'), findsOneWidget);
    expect(find.text('Run the live check'), findsOneWidget);
  });

  testWidgets('the verify button is a real tap target and calls back',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(
        host(consolePayload(fence: fenceBlock()), onVerify: () => taps++));
    await tester.pumpAndSettle();

    final btn = find.byKey(const ValueKey('partner_fence_verify'));
    expect(tester.getSize(btn).height, greaterThanOrEqualTo(44.0));
    await tester.ensureVisible(btn);
    await tester.pumpAndSettle();
    await tester.tap(btn);
    await tester.pumpAndSettle();
    expect(taps, 1);
  });

  testWidgets('the live check renders one row per probe, backend words only',
      (tester) async {
    final result = {
      'ok': false,
      'title': 'Live check, as this partner',
      'summary': '13 / 14',
      'tone': 'danger',
      'rows': const [
        {
          'label': 'Gap #137 · fw_get_state(a ZONE-2 supplier)',
          'value': 'refused',
          'tone': 'success',
          'detail': 'RAISED: not_authorized_zone'
        },
        {
          'label': 'Gap #145 · rzp_webhook_log_recent(5)',
          'value': 'STILL OPEN',
          'tone': 'danger',
          'detail': 'ANSWERED'
        },
      ],
    };
    await tester.pumpWidget(
        host(consolePayload(fence: fenceBlock()), result: result));
    await tester.pumpAndSettle();

    expect(find.text('Live check, as this partner'), findsOneWidget);
    expect(find.text('13 / 14'), findsOneWidget);
    expect(find.text('refused'), findsOneWidget);
    // The failing probe keeps the backend's own word — Dart never softens it.
    expect(find.text('STILL OPEN'), findsOneWidget);
    expect(find.text('Gap #137 · fw_get_state(a ZONE-2 supplier)'), findsOneWidget);
    // ...and the "not checked yet" line is gone once a result exists.
    expect(find.text('Not checked yet in this session.'), findsNothing);
  });
}
