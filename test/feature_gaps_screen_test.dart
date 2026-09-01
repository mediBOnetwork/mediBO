// CHANGE #312 — the feature_gaps register screen prints the backend, verbatim.
//
// The register is the foundation five journey audits will write into, so the
// thing worth pinning is that NOTHING on this screen is worded, ordered,
// coloured or counted in Dart: the title, the chips, the counts, the field
// labels, the buttons, the empty state and the order of the list all arrive in
// the payload. A deliberately non-alphabetical, non-severity-sorted fixture
// proves the list is not re-sorted client-side.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/feature_gaps_screen.dart';
import 'package:pharma_b2b/services/ui_copy.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _payload({
  List<Map<String, dynamic>>? rows,
  String surface = 'all',
}) =>
    <String, dynamic>{
      'ok': true,
      'title': 'Feature gaps',
      'subtitle': 'Ranked worst first.',
      'refresh': 'Refresh',
      'rows': rows ?? const [],
      'has_rows': (rows ?? const []).isNotEmpty,
      'empty_title': 'No gaps recorded yet',
      'empty_body': 'The audits write their findings here.',
      'field_labels': const {
        'journey_step': 'Journey step',
        'evidence': 'Evidence',
        'suggestion': 'Suggestion',
        'effort': 'Effort',
        'notes': 'Notes',
        'dev_command': 'Dev command',
        'found': 'Found',
      },
      'filters': [
        {
          'key': 'surface',
          'label': 'Surface',
          'value': surface,
          'options': const [
            {'value': 'all', 'label': 'All', 'tone': null},
            {'value': 'customer', 'label': 'Customer', 'tone': null},
            {'value': 'delivery', 'label': 'Delivery', 'tone': null},
          ],
        },
        {
          'key': 'sort',
          'label': 'Sort',
          'value': 'severity',
          'options': const [
            {'value': 'severity', 'label': 'Worst first', 'tone': null},
            {'value': 'recent', 'label': 'Newest first', 'tone': null},
          ],
        },
      ],
      'counts': {
        'title': 'In this view',
        'total': (rows ?? const []).length,
        'total_label': '${(rows ?? const []).length} findings',
        'register_label': '9 in the register',
        'groups': [
          {
            'key': 'surface',
            'label': 'By surface',
            'items': const [
              {'key': 'customer', 'label': 'Customer', 'tone': null, 'count': 2},
            ],
          },
          {
            'key': 'type',
            'label': 'By type',
            // An empty group is an absence the backend chose — it must draw
            // nothing, not an empty heading.
            'items': const [],
          },
        ],
      },
    };

Map<String, dynamic> _row({
  required int id,
  required String title,
  String status = 'open',
  List<Map<String, dynamic>> actions = const [
    {'action': 'approve', 'label': 'Approve', 'tone': 'brand'},
    {'action': 'reject', 'label': 'Reject', 'tone': 'danger'},
  ],
  String? evidence,
  String? notes,
}) =>
    <String, dynamic>{
      'id': id,
      'title': title,
      'surface': 'customer',
      'surface_label': 'Customer',
      'journey_step': 'Checkout',
      'type': 'broken',
      'type_label': 'Broken',
      'type_tone': 'danger',
      'severity': 'low',
      'severity_label': 'Low',
      'severity_tone': 'neutral',
      'status': status,
      'status_label': status == 'approved' ? 'Approved' : 'Open',
      'status_tone': status == 'approved' ? 'success' : 'warning',
      'evidence': evidence,
      'suggestion': 'Return the refusal copy.',
      'effort_guess': 'S',
      'notes': notes,
      'dev_command_id': null,
      'found_label': '30 Aug 2026, 11:42 PM',
      'actions': actions,
    };

Widget _host(FeatureGapsListRpc list, FeatureGapStatusRpc status) => MaterialApp(
      home: FeatureGapsScreen(listRpc: list, statusRpc: status),
    );

/// The default 800x600 test window scrolls the list out of the tree, which
/// would make "the third card is missing" look like a sort bug. Every case
/// here is about WHAT is drawn, so give it a viewport tall enough to draw it.
void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(1000, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  setUpAll(() {
    RenderLog.flushEnabled = false;
    // CHANGE #459 · GAP 179 — the error state is ui_copy now, so the fixture
    // carries the same rows the backend serves for these two codes.
    UiCopy.debugSet(const {
      'error.generic.title': 'Could not load this',
      'error.generic.body': 'Something went wrong on our side. Try again in a moment.',
      'error.generic.action': 'Try again',
      'error.42501.title': 'Admins only',
      'error.42501.body':
          'This screen is for signed-in mediBO admins. Sign in with an admin account to open it.',
      'error.42501.action': 'Sign in',
    });
  });

  testWidgets('empty register renders the backend copy, not a Dart sentence',
      (tester) async {
    _tall(tester);
    await tester.pumpWidget(_host(
      (_) async => _payload(),
      (_, __) async => const {'ok': true},
    ));
    await tester.pumpAndSettle();

    expect(find.text('Feature gaps'), findsOneWidget);
    expect(find.text('No gaps recorded yet'), findsOneWidget);
    expect(find.text('The audits write their findings here.'), findsOneWidget);
    // Counts still render: the header is not conditional on having rows.
    expect(find.text('0 findings'), findsOneWidget);
    expect(find.text('9 in the register'), findsOneWidget);
  });

  testWidgets('rows render in PAYLOAD order — never re-sorted in Dart',
      (tester) async {
    _tall(tester);
    // Deliberately not alphabetical and not severity-ordered.
    await tester.pumpWidget(_host(
      (_) async => _payload(rows: [
        _row(id: 3, title: 'Zebra gap'),
        _row(id: 1, title: 'Alpha gap'),
        _row(id: 2, title: 'Middle gap'),
      ]),
      (_, __) async => const {'ok': true},
    ));
    await tester.pumpAndSettle();

    final titles = tester
        .widgetList<FeatureGapCard>(find.byType(FeatureGapCard))
        .map((c) => c.row['title'])
        .toList();
    expect(titles, ['Zebra gap', 'Alpha gap', 'Middle gap']);
  });

  testWidgets('a chip is a payload string and an empty field draws nothing',
      (tester) async {
    _tall(tester);
    await tester.pumpWidget(_host(
      (_) async => _payload(rows: [
        _row(id: 1, title: 'One', evidence: 'RPC returned []', notes: null),
      ]),
      (_, __) async => const {'ok': true},
    ));
    await tester.pumpAndSettle();

    expect(find.text('Low'), findsOneWidget);
    expect(find.text('Broken'), findsOneWidget);
    expect(find.text('Open'), findsOneWidget);
    expect(find.text('Evidence'), findsOneWidget);
    expect(find.text('RPC returned []'), findsOneWidget);
    // notes is null in the payload → no label, no dash invented in Dart.
    expect(find.text('Notes'), findsNothing);
    // An empty count group draws no heading.
    expect(find.text('By surface'), findsOneWidget);
    expect(find.text('By type'), findsNothing);
  });

  testWidgets('only the actions the backend sent are offered', (tester) async {
    _tall(tester);
    await tester.pumpWidget(_host(
      (_) async => _payload(rows: [
        _row(
          id: 1,
          title: 'Already approved',
          status: 'approved',
          actions: const [
            {'action': 'reject', 'label': 'Reject', 'tone': 'danger'},
          ],
        ),
      ]),
      (_, __) async => const {'ok': true},
    ));
    await tester.pumpAndSettle();

    expect(find.text('Reject'), findsOneWidget);
    expect(find.text('Approve'), findsNothing);
    expect(find.text('Approved'), findsOneWidget);
  });

  testWidgets('approve sends the register status and reloads on ok',
      (tester) async {
    _tall(tester);
    final statusCalls = <List<Object>>[];
    var loads = 0;
    await tester.pumpWidget(_host(
      (_) async {
        loads++;
        return _payload(rows: [
          _row(id: 42, title: 'Needs building', status: loads == 1 ? 'open' : 'approved'),
        ]);
      },
      (id, status) async {
        statusCalls.add([id, status]);
        return const {'ok': true, 'message': 'Approved.'};
      },
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Approve'));
    await tester.pumpAndSettle();
    // The confirmation toast is an OverlayEntry on a real delayed timer; let it
    // expire so the binding does not report it as a leak.
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();

    expect(statusCalls, [
      [42, 'approved']
    ]);
    expect(loads, 2);
  });

  testWidgets('picking a filter re-asks the BACKEND with that value',
      (tester) async {
    _tall(tester);
    final asked = <Map<String, dynamic>>[];
    await tester.pumpWidget(_host(
      (params) async {
        asked.add(params);
        return _payload(surface: '${params['p_surface']}');
      },
      (_, __) async => const {'ok': true},
    ));
    await tester.pumpAndSettle();

    expect(asked.first['p_surface'], 'all');

    await tester.tap(find.text('All'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delivery').last);
    await tester.pumpAndSettle();

    expect(asked.length, 2);
    expect(asked.last['p_surface'], 'delivery');
    // The sort the backend chose rides along untouched.
    expect(asked.last['p_sort'], 'severity');
  });

  // CHANGE #459 · GAP 179 — this test used to assert the OPPOSITE: it pumped
  // `Exception('boom')` and demanded the word "boom" appear on screen. That is
  // the defect the register recorded as row 179 — a signed-out visit printed
  // `PostgrestException(message: permission denied for function
  // feature_gaps_list, code: 42501, ...)` centred on the page. The RPC was
  // refusing correctly; the screen was the bug. The contract is now inverted:
  // only the driver's CODE survives the catch, and the words are ui_copy's.
  testWidgets('a thrown RPC shows BACKEND copy, never the driver sentence',
      (tester) async {
    var attempt = 0;
    await tester.pumpWidget(_host(
      (_) async {
        attempt++;
        if (attempt == 1) throw Exception('boom');
        return _payload();
      },
      (_, __) async => const {'ok': true},
    ));
    await tester.pumpAndSettle();

    // The driver's own sentence never reaches the visitor.
    expect(find.textContaining('boom'), findsNothing);
    expect(find.textContaining('Exception'), findsNothing);

    // What they see is the backend's copy for this code family, verbatim.
    expect(find.text('Could not load this'), findsOneWidget);
    expect(find.text('Something went wrong on our side. Try again in a moment.'),
        findsOneWidget);

    // A transient error is retryable, and the action label is the backend's.
    await tester.tap(find.widgetWithText(FilledButton, 'Try again'));
    await tester.pumpAndSettle();
    expect(find.text('No gaps recorded yet'), findsOneWidget);
    expect(attempt, 2);
  });

  // A REFUSAL is a different answer, and the screen must not offer a retry the
  // visitor cannot win: 42501 renders its own copy and no button at all.
  testWidgets('42501 renders the refusal copy and offers no retry',
      (tester) async {
    var attempt = 0;
    await tester.pumpWidget(_host(
      (_) async {
        attempt++;
        throw _Refused();
      },
      (_, __) async => const {'ok': true},
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('permission denied'), findsNothing);
    expect(find.text('Admins only'), findsOneWidget);
    expect(
        find.text(
            'This screen is for signed-in mediBO admins. Sign in with an admin account to open it.'),
        findsOneWidget);
    // isRefusal -> the screen passes no callback, so no button is drawn.
    expect(find.byType(FilledButton), findsNothing);
    expect(attempt, 1);
  });
}

/// A stand-in for the driver's own exception: it carries `code` and a message
/// the visitor must never see. Duck-typed exactly like PostgrestException, and
/// deliberately not importing it.
class _Refused implements Exception {
  final String code = '42501';
  @override
  String toString() =>
      'PostgrestException(message: permission denied for function '
      'feature_gaps_list, code: 42501, details: , hint: null)';
}
