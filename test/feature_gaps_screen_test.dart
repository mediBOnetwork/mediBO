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
  setUpAll(() => RenderLog.flushEnabled = false);

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

  testWidgets('a thrown RPC shows the error with a Retry, never a white screen',
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

    expect(find.textContaining('boom'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.refresh).last);
    await tester.pumpAndSettle();
    expect(find.text('No gaps recorded yet'), findsOneWidget);
  });
}
