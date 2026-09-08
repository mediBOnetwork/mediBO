import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/dev_queue/journey_bot_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

/// CHANGE #635 — the Journey bot panel is a PRINTER.
///
/// The bot's whole point is that the roles, the hostile variants and the nine
/// pipeline stages are ROWS: adding one is an INSERT. A screen that counted
/// them, ordered them, named a verdict or worded a scenario in Dart would go
/// stale the moment somebody inserted the tenth, and would do it silently.
///
/// So the fixture below is deliberately self-inconsistent: its headline says
/// 3/9 while its rows contain two passes, its chips claim 12 hostile variants
/// while its pipeline lists three stages, and its scenario labels do not match
/// their scenario keys. Every assertion here is that the SCREEN printed the
/// payload anyway.
void main() {
  setUpAll(() {
    RenderLog.flushEnabled = false;
  });

  Map<String, dynamic> payload({
    List<Map<String, dynamic>>? rows,
    List<Map<String, dynamic>>? gaps,
    Map<String, dynamic>? smoke,
    List<Map<String, dynamic>>? pipeline,
  }) =>
      {
        'ok': true,
        'title': 'Journey bot',
        'subtitle': 'Every registered feature, driven as every role.',
        'headline': {
          // deliberately disagrees with `rows` below
          'value': '3/9',
          'label': 'journeys passed in the last run',
          'sub_label': 'prod_smoke · 4m ago · 2 console error(s)',
          'tone': 'danger',
        },
        'chips': [
          {'key': 'roles', 'label': '9 roles driven'},
          {'key': 'hostile', 'label': '12 hostile variants'},
          {'key': 'gaps', 'label': '1 open gap(s)', 'tone': 'danger'},
        ],
        'filters': [
          {'key': 'all', 'label': 'All'},
          {'key': 'deny', 'label': 'Must be blocked'},
        ],
        'filter': 'all',
        'rows': rows ??
            [
              {
                'feature_key': 'cust.orders',
                'label': 'My Orders',
                'role': 'customer',
                'role_label': 'Customer',
                'scenario': 'happy_path',
                // the label deliberately is NOT derived from the key
                'scenario_label': 'The ordinary one',
                'verdict': 'passed',
                'verdict_label': 'All good',
                'tone': 'success',
                'duration_label': '31s',
                'steps_label': '11 step(s)',
                'error': '',
              },
              {
                'feature_key': 'cust.orders',
                'label': 'My Orders',
                'role': 'supplier',
                'role_label': 'Supplier',
                'scenario': 'deny',
                'scenario_label': 'Must be blocked',
                'verdict': 'failed',
                'verdict_label': 'Reached it',
                'tone': 'danger',
                'duration_label': '2s',
                'steps_label': '1 step(s)',
                'error': "place_order_v2 answered role 'supplier'",
              },
            ],
        'rows_title': 'Journeys in this run',
        'empty_label': 'Nothing matches this filter.',
        'matrix': [
          {
            'role': 'customer',
            'label': 'Customer',
            'value': '14',
            'sub_label': '13 passed · 1 failed',
            'tone': 'danger',
          },
          {
            'role': 'mr',
            'label': 'MR / agency',
            'value': '0',
            'sub_label': '0 passed · 0 failed · no test login yet',
            'tone': 'warning',
          },
        ],
        'matrix_title': 'Role matrix',
        'pipeline': pipeline ??
            [
              {
                'stage_key': 'placed',
                'label': 'Order placed',
                'note': 'customer places an order',
                'value': '1 / 9',
                'tone': 'success',
              },
              {
                'stage_key': 'inquiry',
                'label': 'Inquiry sent',
                'note': 'the waterfall asks ranked suppliers',
                'value': '2 / 9',
                'tone': 'success',
              },
              {
                'stage_key': 'pack',
                'label': 'Packed',
                'note': 'Pack marks the order ready',
                'value': '6 / 9',
                'tone': 'danger',
              },
            ],
        'pipeline_title': 'Full order pipeline',
        'gaps': gaps ??
            [
              {
                'id': 7,
                'title': 'My Orders failed for supplier (deny)',
                'sub_label': 'customer · high · deny',
                'evidence': "place_order_v2 answered role 'supplier'",
                'repro_label':
                    'bash scripts/autotest.sh --feature cust.orders --role supplier',
                'tone': 'danger',
              },
            ],
        'gaps_title': 'Open gaps filed by the bot',
        'gaps_empty': 'No open gaps.',
        'smoke': smoke ??
            {
              'ok': false,
              'label': 'Critical-path smoke FAILED',
              'tone': 'danger',
              'detail': 'run 41 · 1 of 7 critical features failed',
            },
        'smoke_title': 'Deploy gate',
        'runs': [
          {
            'id': 41,
            'label': 'prod_smoke · 4m ago',
            'sub_label': '6 passed · 1 failed · 0 blocked',
            'status_label': 'Failed',
            'tone': 'danger',
          },
        ],
        'runs_title': 'Recent runs',
        'footnote': 'Roles, hostile variants and the nine stages are rows.',
      };

  // A tall surface, because this screen is one ListView and a 600px viewport
  // would leave the gaps and the empty states unbuilt — which would make the
  // assertions below pass for the wrong reason.
  Future<void> pump(WidgetTester t, Map<String, dynamic> p) async {
    t.view.physicalSize = const Size(1200, 4200);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(MaterialApp(
      home: JourneyBotScreen(load: (_) async => p),
    ));
    await t.pumpAndSettle();
  }

  testWidgets('the headline is the payload, not a count of the rows',
      (t) async {
    await pump(t, payload());
    // Two rows are on screen and one of them passed. The headline still says
    // 3/9, because the BACKEND said so.
    expect(find.text('3/9'), findsOneWidget);
    expect(find.text('journeys passed in the last run'), findsOneWidget);
    expect(find.text('1/2'), findsNothing);
    expect(find.text('2'), findsNothing);
  });

  testWidgets('scenario and verdict labels are printed, never derived',
      (t) async {
    await pump(t, payload());
    // 'happy_path' would title-case to "Happy path"; the payload said
    // something else and the payload wins.
    expect(find.textContaining('The ordinary one'), findsOneWidget);
    expect(find.text('All good'), findsOneWidget);
    expect(find.text('Reached it'), findsOneWidget);
    expect(find.textContaining('Happy path'), findsNothing);
    expect(find.text('Passed'), findsNothing);
    expect(find.text('Failed'), findsWidgets); // only the run row's own label
  });

  testWidgets('chips print their own counts even when nothing agrees',
      (t) async {
    await pump(t, payload());
    expect(find.text('9 roles driven'), findsOneWidget);
    // Three pipeline stages are listed; the chip claims twelve variants. The
    // screen counts neither.
    expect(find.text('12 hostile variants'), findsOneWidget);
    expect(find.text('1 open gap(s)'), findsOneWidget);
  });

  testWidgets('the nine stages render in payload order, tones and all',
      (t) async {
    await pump(t, payload());
    final labels = t
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.data ?? '')
        .where((s) => s == 'Order placed' || s == 'Inquiry sent' || s == 'Packed')
        .toList();
    expect(labels, ['Order placed', 'Inquiry sent', 'Packed']);
    // The value is the backend's "n / 9" string — never rebuilt from an index.
    expect(find.text('6 / 9'), findsOneWidget);
  });

  testWidgets('the deploy gate prints the backend sentence, not a verdict '
      'derived from ok', (t) async {
    await pump(t, payload());
    expect(find.text('Critical-path smoke FAILED'), findsOneWidget);
    expect(find.text('run 41 · 1 of 7 critical features failed'), findsOneWidget);
  });

  testWidgets('a gap carries its own repro command', (t) async {
    await pump(t, payload());
    expect(
        find.text(
            'bash scripts/autotest.sh --feature cust.orders --role supplier'),
        findsOneWidget);
    expect(find.text('My Orders failed for supplier (deny)'), findsOneWidget);
  });

  testWidgets('no gaps is the backend empty state, never a dash', (t) async {
    await pump(t, payload(gaps: const []));
    expect(find.text('No open gaps.'), findsOneWidget);
    expect(find.text('-'), findsNothing);
    expect(find.text('—'), findsNothing);
  });

  testWidgets('no journeys renders the backend empty line', (t) async {
    await pump(t, payload(rows: const []));
    expect(find.text('Nothing matches this filter.'), findsOneWidget);
  });

  testWidgets('an unknown tone stays neutral instead of throwing', (t) async {
    final p = payload();
    (p['rows'] as List)[0]['tone'] = 'chartreuse';
    (p['smoke'] as Map)['tone'] = 'chartreuse';
    await pump(t, p);
    expect(find.text('All good'), findsOneWidget);
    expect(find.text('Critical-path smoke FAILED'), findsOneWidget);
  });

  testWidgets('a role with no login prints the backend note, not a zero',
      (t) async {
    await pump(t, payload());
    expect(find.textContaining('no test login yet'), findsOneWidget);
  });
}
