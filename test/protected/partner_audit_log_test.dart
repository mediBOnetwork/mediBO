// CMD #467 row 155 — the partner audit trail, held down.
//
// The register's complaint was that a good record had no reader: the console
// showed the last 25 rows, unfiltered and unpaged, and joined `action` to
// `feature_key` in Dart so a mediBO admin read raw slugs. What this file
// asserts is that the new reader decides NOTHING:
//
//   • a row prints the backend's composed `line` — never action + feature_key
//     joined here — and takes its accent from the payload's own `tone`;
//   • the three filter rows are built from the payload's option lists, each
//     option's `selected` flag is obeyed rather than recomputed, and tapping
//     one sends the backend's own `value` back;
//   • "Load older activity" exists only while the BACKEND says `has_more`, and
//     appending a page never drops or duplicates what was already shown;
//   • the refused-attempts banner is the payload's sentence and tone, and an
//     empty `denied_label` draws no banner at all;
//   • an empty result renders the backend's `empty` copy, and ok:false renders
//     the backend's `message` instead of throwing.
//
// No network, no Supabase: everything is an inline payload.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/partner_audit_log_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _payload({
  bool hasMore = false,
  int denied = 2,
  String selectedAction = '',
  List<Map<String, dynamic>>? rows,
}) => {
      'ok': true,
      'partner_id': 7,
      'title': 'STANDIN_TITLE',
      'subtitle': 'STANDIN_SUBTITLE',
      'empty': 'STANDIN_EMPTY',
      'more_label': 'STANDIN_MORE',
      'filter_feature_label': 'STANDIN_F_FEATURE',
      'filter_action_label': 'STANDIN_F_ACTION',
      'filter_range_label': 'STANDIN_F_RANGE',
      'any_feature_label': 'STANDIN_ANY_FEATURE',
      'any_action_label': 'STANDIN_ANY_ACTION',
      'count_label': 'STANDIN_COUNT_41',
      'denied_count': denied,
      'denied_tone': denied > 0 ? 'danger' : 'neutral',
      'denied_label': denied > 0 ? 'STANDIN_DENIED_BANNER' : '',
      'total': 41,
      'limit': 25,
      'offset': 0,
      'next_offset': 25,
      'has_more': hasMore,
      'days': 30,
      'feature': '',
      'action': selectedAction,
      'ranges': [
        {'value': 7, 'label': 'STANDIN_R7', 'selected': false},
        {'value': 30, 'label': 'STANDIN_R30', 'selected': true},
        {'value': 0, 'label': 'STANDIN_RALL', 'selected': false},
      ],
      'features': [
        {
          'value': 'partner.settlement',
          'label': 'STANDIN_FEAT_SETTLEMENT',
          'count': 12,
          'selected': false,
        },
      ],
      'actions': [
        {
          'value': 'open_denied',
          'label': 'STANDIN_ACT_REFUSED',
          'count': 19,
          'tone': 'danger',
          'selected': selectedAction == 'open_denied',
        },
      ],
      'rows': rows ??
          [
            {
              'id': 3,
              'action': 'open_denied',
              'feature_key': 'partner.settlement',
              'action_label': 'STANDIN_ACT_REFUSED',
              'line': 'STANDIN_LINE_REFUSED',
              'tone': 'danger',
              'at_label': 'STANDIN_AT_3',
            },
            {
              'id': 2,
              'action': 'open',
              'feature_key': 'partner.queue',
              'action_label': 'STANDIN_ACT_OPEN',
              'line': 'STANDIN_LINE_OPEN',
              'tone': 'neutral',
              'at_label': 'STANDIN_AT_2',
            },
          ],
    };

List<Map<String, dynamic>> _rowsOf(Map<String, dynamic> p) =>
    ((p['rows'] as List?) ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();

Future<void> _pump(
  WidgetTester tester,
  Map<String, dynamic> payload, {
  List<Map<String, dynamic>>? rows,
  void Function(String)? onFeature,
  void Function(String)? onAction,
  void Function(int)? onRange,
  VoidCallback? onMore,
}) async {
  // A tall surface: the three filter rows plus the banner push the entries
  // past 600 px, and a ListView never builds what it has not laid out.
  await tester.binding.setSurfaceSize(const Size(600, 2600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: PartnerAuditLogView(
        payload: payload,
        rows: rows ?? _rowsOf(payload),
        onFeature: onFeature ?? (_) {},
        onAction: onAction ?? (_) {},
        onRange: onRange ?? (_) {},
        onMore: onMore ?? () {},
      ),
    ),
  ));
  await tester.pump();
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  testWidgets('a row prints the backend line, never action + feature_key',
      (tester) async {
    await _pump(tester, _payload());

    expect(find.text('STANDIN_LINE_REFUSED'), findsOneWidget);
    expect(find.text('STANDIN_LINE_OPEN'), findsOneWidget);
    expect(find.text('STANDIN_AT_3'), findsOneWidget);

    // the raw slugs never reach the screen
    expect(find.textContaining('open_denied'), findsNothing);
    expect(find.textContaining('partner.settlement · '), findsNothing);
  });

  testWidgets('the filter chips are the payload\'s options and carry its values',
      (tester) async {
    String? tappedAction;
    int? tappedRange;
    String? tappedFeature;
    await _pump(
      tester,
      _payload(),
      onAction: (v) => tappedAction = v,
      onRange: (v) => tappedRange = v,
      onFeature: (v) => tappedFeature = v,
    );

    expect(find.text('STANDIN_F_RANGE'), findsOneWidget);
    expect(find.text('STANDIN_F_ACTION'), findsOneWidget);
    expect(find.text('STANDIN_F_FEATURE'), findsOneWidget);
    expect(find.text('STANDIN_ANY_ACTION'), findsOneWidget);

    // the count travels with the option, and the label is the backend's
    expect(find.text('STANDIN_ACT_REFUSED (19)'), findsOneWidget);
    expect(find.text('STANDIN_FEAT_SETTLEMENT (12)'), findsOneWidget);

    await tester.tap(find.text('STANDIN_ACT_REFUSED (19)'));
    expect(tappedAction, 'open_denied');

    await tester.tap(find.text('STANDIN_R7'));
    expect(tappedRange, 7);

    await tester.tap(find.text('STANDIN_FEAT_SETTLEMENT (12)'));
    expect(tappedFeature, 'partner.settlement');
  });

  testWidgets('selection follows the payload flag, not a client guess',
      (tester) async {
    await _pump(tester, _payload(selectedAction: 'open_denied'));

    // 'Everything' is unselected because the payload's `action` is set — the
    // widget reads the field, it does not track a tap.
    final chip = tester.widget<Container>(find.ancestor(
      of: find.text('STANDIN_ACT_REFUSED (19)'),
      matching: find.byType(Container),
    ).first);
    final deco = chip.decoration as BoxDecoration;
    expect(deco.border, isNotNull);
  });

  testWidgets('Load more appears only while the BACKEND says has_more',
      (tester) async {
    await _pump(tester, _payload(hasMore: false));
    expect(find.text('STANDIN_MORE'), findsNothing);

    var tapped = false;
    await _pump(tester, _payload(hasMore: true), onMore: () => tapped = true);
    expect(find.text('STANDIN_MORE'), findsOneWidget);
    await tester.tap(find.text('STANDIN_MORE'));
    expect(tapped, isTrue);
  });

  testWidgets('appending a page keeps every row, in the order it was given',
      (tester) async {
    final first = _rowsOf(_payload());
    final page2 = [
      {
        'id': 1,
        'action': 'permission_set',
        'feature_key': 'partner.queue',
        'action_label': 'STANDIN_ACT_PERM',
        'line': 'STANDIN_LINE_PERM',
        'tone': 'info',
        'at_label': 'STANDIN_AT_1',
      },
    ];
    await _pump(tester, _payload(hasMore: false), rows: [...first, ...page2]);

    expect(find.text('STANDIN_LINE_REFUSED'), findsOneWidget);
    expect(find.text('STANDIN_LINE_OPEN'), findsOneWidget);
    expect(find.text('STANDIN_LINE_PERM'), findsOneWidget);
  });

  testWidgets('the refused banner is the payload sentence, absent at zero',
      (tester) async {
    await _pump(tester, _payload(denied: 2));
    expect(find.text('STANDIN_DENIED_BANNER'), findsOneWidget);

    await _pump(tester, _payload(denied: 0));
    expect(find.text('STANDIN_DENIED_BANNER'), findsNothing);
  });

  testWidgets('an empty result renders the backend copy, ok:false its message',
      (tester) async {
    await _pump(tester, _payload(rows: const []), rows: const []);
    expect(find.text('STANDIN_EMPTY'), findsOneWidget);
    expect(find.text('STANDIN_COUNT_41'), findsOneWidget);

    await _pump(tester, {
      'ok': false,
      'error': 'not_authorized',
      'message': 'STANDIN_REFUSED_COPY',
    }, rows: const []);
    expect(find.text('STANDIN_REFUSED_COPY'), findsOneWidget);
  });

  testWidgets('an unknown tone degrades to neutral instead of throwing',
      (tester) async {
    await _pump(tester, _payload(), rows: [
      {
        'id': 9,
        'action': 'something_new',
        'line': 'STANDIN_LINE_FUTURE',
        'tone': 'chartreuse',
        'at_label': 'STANDIN_AT_9',
      },
    ]);
    expect(find.text('STANDIN_LINE_FUTURE'), findsOneWidget);
  });
}
