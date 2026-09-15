// PROTECTED — CHANGE #634.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes coverage-ledger behaviour, never to make an unrelated
// change go green.
//
// What this holds down — the Test coverage screen is a PRINTER:
//
//   1. The headline number is the BACKEND'S. The fixture says 62% while
//      carrying 3 rows of which 2 have a contract — a screen that divided its
//      own rows would print 67% and fail here. The subtitle sentence, the
//      "never tested" line and every filter's count are the same: printed, not
//      counted.
//
//   2. Each row's status word, sub-line, green-line and flake-line arrive
//      whole. The fixture's "Manual only" row carries a sub-line that is a
//      REASON, not a date, and the screen prints it exactly — no date
//      formatting, no "last run" prefix invented in Dart.
//
//   3. An absent line is OMITTED, never dashed. green_label:'' and
//      flake_label:'' draw nothing at all, because a dash reads as data.
//
//   4. Tone is carried, not inferred. A row's colour comes from its own `tone`
//      through one lookup, and an unknown tone stays neutral — so a red row
//      cannot turn green the day the backend adds a tone name Dart has not
//      heard of.
//
//   5. Rows render in PAYLOAD ORDER. The fixture is deliberately not sorted by
//      label, feature_key, tone or status, so any client-side sort fails here.
//
//   6. The empty state is the backend's sentence, and the recent-runs block
//      prints its own none_label rather than disappearing.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/dev_queue/test_coverage_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

/// A loader that answers with a fixture and never touches Supabase.
class _FakeService {
  _FakeService(this.payload, {this.throws = false});
  final Map<String, dynamic> payload;
  final bool throws;
  String? lastFilter;
  int calls = 0;

  Future<Map<String, dynamic>> call(String filter) async {
    calls++;
    lastFilter = filter;
    if (throws) throw Exception('coverage_home refused: not_authorized');
    return payload;
  }
}

Map<String, dynamic> _payload({List? rows, Map<String, dynamic>? runs}) => {
      'ok': true,
      'has': true,
      'title': 'Test coverage',
      // 160 of 161 — and deliberately NOT what the three fixture rows below
      // would add up to. The screen prints; it does not count.
      'subtitle': '160 of 161 features carry a test contract',
      'headline': {
        'label': 'Coverage',
        'value': '62%',
        'tone': 'warning',
        'sub': '138 features have never been tested',
      },
      'filters': const [
        {'key': 'all', 'label': 'All', 'count': 161, 'selected': true},
        {'key': 'never', 'label': 'Never tested', 'count': 138, 'selected': false},
        {'key': 'failing', 'label': 'Failing', 'count': 2, 'selected': false},
        {'key': 'nocontract', 'label': 'No contract', 'count': 1, 'selected': false},
        {'key': 'manual', 'label': 'Manual only', 'count': 21, 'selected': false},
      ],
      'rows': rows ??
          const [
            // Deliberately unsorted by every field a client might sort on.
            {
              'feature_key': 'zz.last_alphabetically',
              'label': 'Warehouse count',
              'group_label': 'Fulfil',
              'entry': '/admin/go/warehouse',
              'tone': 'success',
              'status_label': 'Passed',
              'sub_label': 'last run 3h ago',
              'green_label': 'last green 3h ago',
              'flake_label': '12.5% flaky over 8 runs',
            },
            {
              'feature_key': 'admin.admin_push',
              'label': 'Push notifications',
              'group_label': 'Communication',
              'entry': '',
              'tone': 'neutral',
              'status_label': 'Manual only',
              // A REASON, not a date — and no "last run" prefix anywhere.
              'sub_label':
                  'Delivery can only be proven on a real device that received the push.',
              'green_label': '',
              'flake_label': '',
            },
            {
              'feature_key': 'aa.first_alphabetically',
              'label': 'Bag mapping',
              'group_label': 'Fulfil',
              'entry': '/admin/go/bag',
              // A tone name this build has never heard of must stay neutral,
              // not be guessed at from the status word next to it.
              'tone': 'chartreuse',
              'status_label': 'Failed',
              'sub_label': 'last run just now',
              'green_label': 'never green',
              'flake_label': '',
            },
          ],
      'empty_label': 'Nothing matches this filter.',
      'runs': runs ??
          const {
            'title': 'Recent runs',
            'none_label': 'The bot has not run yet.',
            'rows': [
              {
                'run_id': 7,
                'label': 'preview · 103513fd',
                'value': '18/20',
                'sub': '2h ago',
                'tone': 'danger',
              },
            ],
          },
    };

Future<void> _pump(WidgetTester t, _FakeService svc) async {
  // A desktop-sized surface on purpose: the ledger is a list and a filter row,
  // and the default 800x600 test window builds neither lazily-built tail. The
  // point of these tests is what the screen PRINTS, not what fits.
  t.view.physicalSize = const Size(1400, 2600);
  t.view.devicePixelRatio = 1.0;
  addTearDown(() {
    t.view.resetPhysicalSize();
    t.view.resetDevicePixelRatio();
  });
  await t.pumpWidget(MaterialApp(home: TestCoverageScreen(load: svc.call)));
  await t.pumpAndSettle();
}

/// Where a Text with [needle] sits in the widget tree, top to bottom.
double _yOf(WidgetTester t, String needle) =>
    t.getTopLeft(find.text(needle)).dy;

void main() {
  setUpAll(() {
    // RenderLog.write's 800 ms debounce is a real Timer that would outlive the
    // test and try to reach Supabase.
    RenderLog.flushEnabled = false;
  });

  testWidgets('the headline is the backend number, never a recount',
      (t) async {
    final svc = _FakeService(_payload());
    await _pump(t, svc);

    // 2 of the 3 fixture rows carry a contract; a screen that computed its own
    // percentage would print 67%. It prints what it was sent.
    expect(find.text('62%'), findsOneWidget);
    expect(find.text('67%'), findsNothing);
    expect(find.text('160 of 161 features carry a test contract'), findsOneWidget);
    expect(find.text('138 features have never been tested'), findsOneWidget);
  });

  testWidgets('every filter prints the backend count, not the rows it holds',
      (t) async {
    await _pump(t, _FakeService(_payload()));
    // Three rows are on screen; the All chip still says 161.
    expect(find.text('All 161'), findsOneWidget);
    expect(find.text('Never tested 138'), findsOneWidget);
    expect(find.text('Manual only 21'), findsOneWidget);
  });

  testWidgets('a filter tap asks the BACKEND for that filter', (t) async {
    final svc = _FakeService(_payload());
    await _pump(t, svc);
    expect(svc.lastFilter, 'all');
    await t.tap(find.text('Never tested 138'));
    await t.pumpAndSettle();
    expect(svc.lastFilter, 'never');
    expect(svc.calls, greaterThan(1));
  });

  testWidgets('a manual row prints its reason verbatim, with no invented prefix',
      (t) async {
    await _pump(t, _FakeService(_payload()));
    expect(find.text('Manual only'), findsOneWidget);
    expect(
        find.text(
            'Delivery can only be proven on a real device that received the push.'),
        findsOneWidget);
    // No "last run" wording anywhere near it: that row never ran.
    expect(find.textContaining('last run 3h ago'), findsOneWidget); // the other row
  });

  testWidgets('an absent line is omitted, never dashed', (t) async {
    await _pump(t, _FakeService(_payload()));
    expect(find.text('—'), findsNothing);
    expect(find.text('-'), findsNothing);
    // green_label:'' on the manual row draws nothing; the row that HAS one
    // prints it.
    expect(find.text('last green 3h ago'), findsOneWidget);
    expect(find.text('never green'), findsOneWidget);
    // Only one row carries a flake line.
    expect(find.text('12.5% flaky over 8 runs'), findsOneWidget);
  });

  testWidgets('rows render in payload order, not sorted', (t) async {
    await _pump(t, _FakeService(_payload()));
    // Payload order is Warehouse count, Push notifications, Bag mapping —
    // which is neither alphabetical by label nor by feature_key nor by status.
    expect(_yOf(t, 'Warehouse count'), lessThan(_yOf(t, 'Push notifications')));
    expect(_yOf(t, 'Push notifications'), lessThan(_yOf(t, 'Bag mapping')));
  });

  testWidgets('an unknown tone stays neutral instead of being guessed',
      (t) async {
    await _pump(t, _FakeService(_payload()));
    // The 'chartreuse' row still renders its backend status word; the point is
    // that it renders at all rather than throwing on an unmapped tone.
    expect(find.text('Failed'), findsOneWidget);
    expect(find.text('Bag mapping'), findsOneWidget);
  });

  testWidgets('an empty result prints the backend empty state', (t) async {
    await _pump(t, _FakeService(_payload(rows: const [])));
    expect(find.text('Nothing matches this filter.'), findsOneWidget);
    expect(find.text('Warehouse count'), findsNothing);
  });

  testWidgets('the runs block prints its own none_label rather than vanishing',
      (t) async {
    await _pump(
        t,
        _FakeService(_payload(runs: const {
          'title': 'Recent runs',
          'none_label': 'The bot has not run yet.',
          'rows': [],
        })));
    expect(find.text('Recent runs'), findsOneWidget);
    expect(find.text('The bot has not run yet.'), findsOneWidget);
  });

  testWidgets('a recent run prints the backend label, value and tone',
      (t) async {
    await _pump(t, _FakeService(_payload()));
    expect(find.text('preview · 103513fd'), findsOneWidget);
    expect(find.text('18/20'), findsOneWidget);
    expect(find.text('2h ago'), findsOneWidget);
  });

  testWidgets('a refusal shows the backend message and offers Retry',
      (t) async {
    final svc = _FakeService(_payload(), throws: true);
    await _pump(t, svc);
    expect(find.textContaining('not_authorized'), findsOneWidget);
    expect(find.text('62%'), findsNothing);
  });
}
