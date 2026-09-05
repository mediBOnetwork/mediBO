import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/visual_baselines_screen.dart';
import 'package:pharma_b2b/screens/admin/feature_gaps_screen.dart';
import 'package:pharma_b2b/utils/payment_proof.dart';
import 'package:pharma_b2b/utils/render_log.dart';

/// CHANGE #637 — the two surfaces the self-testing bot reports through are
/// PRINTERS, and this holds them to it.
///
/// The fixture is deliberately self-contradictory where a screen might be
/// tempted to compute: the payload's `diff_label` says "4.20% of the picture
/// differs" while its status word says "Changed" and NO percentage appears
/// anywhere else, so a card that derived its own sentence from a number would
/// have nothing to derive it from; the headline's value (2) disagrees with the
/// number of rows (3), so a card that counted the rows it was handed fails;
/// and the filter counts disagree with the rows too, for the same reason.
///
/// The other half is the class of bug the lane exists to retire: an approval
/// that the SERVER did not make must never appear made, an absent baseline must
/// draw nothing rather than an empty frame, and a finding's source and the spec
/// line it contradicts must print verbatim.
Map<String, dynamic> _home({
  bool canApprove = true,
  bool hasBaseline = true,
  bool pending = true,
}) =>
    <String, dynamic>{
      'ok': true,
      'title': 'Visual baselines',
      'subtitle': 'Every registered screen, per role, at two widths',
      'run_id': 91,
      'headline': {
        'value': '2',
        'label': 'Awaiting review',
        'tone': 'warning',
        'sub': '2 screenshot(s) differ from an approved baseline or have none yet.',
      },
      'filters': [
        {'key': 'review', 'label': 'Needs review', 'count': 2, 'selected': true},
        {'key': 'changed', 'label': 'Changed', 'count': 1, 'selected': false},
        {'key': 'all', 'label': 'All', 'count': 9, 'selected': false},
      ],
      'empty_label': 'Nothing matches this filter.',
      'approve_all': {
        'has': pending,
        'label': 'Approve every shot in this run',
        'run_id': 91,
      },
      'run_now': {'label': 'Run the visual pass'},
      'rows': [
        {
          'shot_id': 501,
          'feature_key': 'cust.orders',
          'label': 'My Orders',
          'sub_label': 'cust.orders · customer · Phone',
          'status_label': 'Changed',
          'tone': 'warning',
          'detail': 'This screen no longer matches its approved baseline at this width.',
          'diff_label': '4.20% of the picture differs',
          'current': {'label': 'This run', 'bucket': 'test-artifacts', 'path': 'run-91/a/phone.png'},
          'baseline': {
            'has': hasBaseline,
            'label': 'Approved baseline',
            'bucket': 'test-artifacts',
            'path': hasBaseline ? 'run-70/a/phone.png' : '',
            'sub': hasBaseline ? 'approved 6d ago' : '',
          },
          'diff': {
            'has': true,
            'label': 'What changed',
            'bucket': 'test-artifacts',
            'path': 'run-91/a/phone-diff.png',
          },
          'can_approve': canApprove,
          'approve_label': 'Approve as baseline',
          'reviewed_label': canApprove ? '' : 'Reviewed',
        },
        {
          'shot_id': 502,
          'feature_key': 'sup.shop',
          'label': 'Supplier shop',
          'sub_label': 'sup.shop · supplier · Desktop',
          'status_label': 'Blank screen',
          'tone': 'danger',
          'detail': 'Almost the whole screen is one flat colour at this width.',
          'diff_label': 'No approved baseline yet',
          'current': {'label': 'This run', 'bucket': 'test-artifacts', 'path': 'run-91/b/desktop.png'},
          'baseline': {'has': false, 'label': 'Approved baseline', 'bucket': '', 'path': '', 'sub': ''},
          'diff': {'has': false, 'label': 'What changed', 'bucket': '', 'path': ''},
          'can_approve': true,
          'approve_label': 'Approve as baseline',
          'reviewed_label': '',
        },
        {
          'shot_id': 503,
          'feature_key': 'admin.money',
          'label': 'Money',
          'sub_label': 'admin.money · admin · Phone',
          'status_label': 'Matches baseline',
          'tone': 'success',
          'detail': '',
          'diff_label': '0.00% of the picture differs',
          'current': {'label': 'This run', 'bucket': 'test-artifacts', 'path': 'run-91/c/phone.png'},
          'baseline': {
            'has': true,
            'label': 'Approved baseline',
            'bucket': 'test-artifacts',
            'path': 'run-70/c/phone.png',
            'sub': 'approved 6d ago',
          },
          'diff': {'has': false, 'label': 'What changed', 'bucket': '', 'path': ''},
          'can_approve': false,
          'approve_label': 'Approve as baseline',
          'reviewed_label': 'Reviewed',
        },
      ],
      'runs': {
        'title': 'Recent visual runs',
        'none_label': 'The visual lane has not run yet.',
        'rows': [
          {'label': 'Run 91', 'sub': '2h ago · visual', 'value': '18', 'tone': 'warning'},
        ],
      },
    };

/// The toast is a real OverlayEntry with a real 4-second dismissal timer. A
/// widget test that ends while it is pending fails on a pending timer, which
/// says nothing about the screen — so every test that provokes one waits it
/// out rather than pretending the toast is not there.
Future<void> _letTheToastGo(WidgetTester t) async {
  await t.pump(const Duration(seconds: 5));
  await t.pumpAndSettle();
}

/// A loader that never touches Supabase and never resolves to a real image:
/// this suite is about the WORDS and the decisions, not about pixels.
final PaymentProofLoader _noImages = PaymentProofLoader(
  signer: (bucket, path, ttl, transform) async => throw StateError('no network in a VM test'),
);

Widget _screen(
  Map<String, dynamic> payload, {
  List<int>? approved,
  List<int>? approvedRuns,
  Map<String, dynamic>? approveResult,
  List<String>? loadedFilters,
}) =>
    MaterialApp(
      home: VisualBaselinesScreen(
        imageLoader: _noImages,
        load: (filter) async {
          loadedFilters?.add(filter);
          return payload;
        },
        approve: (id) async {
          approved?.add(id);
          return approveResult ?? <String, dynamic>{'ok': true, 'message': 'Baseline approved.'};
        },
        approveRun: (id) async {
          approvedRuns?.add(id);
          return <String, dynamic>{'ok': true, 'message': '2 baseline(s) approved.'};
        },
        runRequest: (lane) async =>
            <String, dynamic>{'ok': true, 'message': 'Queued — the VM picks it up on its next pass.'},
      ),
    );

void main() {
  setUpAll(() {
    // RenderLog's 800 ms debounce is a real Timer that would outlive the test.
    RenderLog.flushEnabled = false;
  });

  // A tall surface, because the assertions are about what the screen PRINTS and
  // a ListView only builds what fits: on the 800x600 default the second and
  // third rows are not in the tree at all, so "the backend's word is missing"
  // and "the row was never built" would look identical.
  setUp(() {
    final view = TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher.views.first;
    view.physicalSize = const Size(1200, 4000);
    view.devicePixelRatio = 1.0;
  });

  tearDown(() {
    final view = TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher.views.first;
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  group('Visual baselines is a printer', () {
    testWidgets('every word on the screen is the payload\'s', (t) async {
      await t.pumpWidget(_screen(_home()));
      await t.pump();

      expect(find.text('Visual baselines'), findsOneWidget);
      expect(find.text('Every registered screen, per role, at two widths'), findsOneWidget);
      // The headline value is printed, never counted: the fixture says 2 while
      // it carries 3 rows, so a screen that counted rows would show 3.
      expect(find.text('2'), findsOneWidget);
      expect(find.text('Awaiting review'), findsOneWidget);
      expect(
          find.text('2 screenshot(s) differ from an approved baseline or have none yet.'),
          findsOneWidget);

      // Filter label AND its count come together, and the count is the
      // backend's — 9 for "All" while three rows are on screen.
      expect(find.text('Needs review 2'), findsOneWidget);
      expect(find.text('All 9'), findsOneWidget);

      // Status words and their sentences, verbatim.
      expect(find.text('Changed'), findsOneWidget);
      expect(find.text('Blank screen'), findsOneWidget);
      expect(find.text('Matches baseline'), findsOneWidget);
      expect(find.text('4.20% of the picture differs'), findsOneWidget);
      expect(find.text('No approved baseline yet'), findsOneWidget);
      expect(find.text('Approve every shot in this run'), findsOneWidget);
      expect(find.text('Run the visual pass'), findsOneWidget);
      expect(find.text('Recent visual runs'), findsOneWidget);
    });

    testWidgets('rows render in payload order', (t) async {
      await t.pumpWidget(_screen(_home()));
      await t.pump();
      final orders = t.getTopLeft(find.text('My Orders')).dy;
      final shop = t.getTopLeft(find.text('Supplier shop')).dy;
      final money = t.getTopLeft(find.text('Money')).dy;
      expect(orders < shop, isTrue);
      expect(shop < money, isTrue);
    });

    testWidgets('an absent baseline draws NOTHING, never an empty frame', (t) async {
      await t.pumpWidget(_screen(_home()));
      await t.pump();
      // 'Approved baseline' is the caption on the baseline pane. Two of the
      // three rows have one; the blank-screen row must not draw a third.
      expect(find.text('Approved baseline'), findsNWidgets(2));
      // 'What changed' likewise appears only where the payload sent a diff.
      expect(find.text('What changed'), findsOneWidget);
      // The approval sub-line is omitted, not dashed.
      expect(find.text('-'), findsNothing);
    });

    testWidgets('can_approve is the BACKEND\'s decision, not the verdict', (t) async {
      await t.pumpWidget(_screen(_home()));
      await t.pump();
      // Two rows may be approved; the reviewed one shows its own word instead.
      expect(find.text('Approve as baseline'), findsNWidgets(2));
      expect(find.text('Reviewed'), findsOneWidget);
    });

    testWidgets('an empty run prints the backend\'s empty state', (t) async {
      final payload = _home();
      payload['rows'] = const [];
      payload['approve_all'] = {'has': false, 'label': '', 'run_id': 91};
      await t.pumpWidget(_screen(payload));
      await t.pump();
      expect(find.text('Nothing matches this filter.'), findsOneWidget);
      expect(find.text('Approve every shot in this run'), findsNothing);
    });
  });

  group('Approval is the server\'s, and it is re-read', () {
    testWidgets('one tap approves exactly that shot and reloads', (t) async {
      final approved = <int>[];
      final loads = <String>[];
      await t.pumpWidget(_screen(_home(), approved: approved, loadedFilters: loads));
      await t.pump();
      expect(loads.length, 1);

      await t.tap(find.byWidgetPredicate((w) =>
          w is Semantics && w.properties.identifier == 'visual_approve_501'));
      await t.pump();
      await t.pumpAndSettle();

      expect(approved, [501]);
      // The screen never marks a row approved by itself: it re-asks, and the
      // NEXT payload is what it draws.
      expect(loads.length, 2);
      await _letTheToastGo(t);
    });

    testWidgets('approve-all carries the run id the payload named', (t) async {
      final runs = <int>[];
      await t.pumpWidget(_screen(_home(), approvedRuns: runs));
      await t.pump();
      await t.tap(find.byWidgetPredicate((w) =>
          w is Semantics && w.properties.identifier == 'visual_approve_all'));
      await t.pump();
      await t.pumpAndSettle();
      expect(runs, [91]);
      await _letTheToastGo(t);
    });

    testWidgets('a refusal prints the backend\'s own message', (t) async {
      await t.pumpWidget(_screen(_home(),
          approveResult: <String, dynamic>{
            'ok': false,
            'error': 'not_authorized',
            'message': 'Visual baselines are super-admin only.'
          }));
      await t.pump();
      await t.tap(find.byWidgetPredicate((w) =>
          w is Semantics && w.properties.identifier == 'visual_approve_501'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(find.text('Visual baselines are super-admin only.'), findsOneWidget);
      await _letTheToastGo(t);
    });
  });

  group('A bot finding says what it is and what it contradicts', () {
    Map<String, dynamic> gapRow({String source = 'explore', String spec = '', String? shotPath}) =>
        <String, dynamic>{
          'id': 7,
          'title': 'Total shows ₹0.00 while three lines are priced',
          'severity_label': 'High',
          'severity_tone': 'danger',
          'type_label': 'Partly built',
          'type_tone': 'warning',
          'surface_label': 'Customer',
          'status_label': 'Open',
          'status_tone': 'info',
          'source_label': source == 'explore' ? 'Exploratory bot' : '',
          'source_tone': 'warning',
          'spec_line': spec,
          'confidence': 'high',
          'evidence': 'The cart header reads ₹0.00 above three priced lines.',
          'found_label': '2h ago',
          'shot': shotPath == null
              ? null
              : {'bucket': 'test-artifacts', 'path': shotPath},
          'actions': const [],
        };

    Widget card(Map<String, dynamic> row) => MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: FeatureGapCard(
                row: row,
                fieldLabels: const {
                  'evidence': 'Evidence',
                  'found': 'Found',
                  'spec_line': 'Contradicts',
                  'shot': 'Seen in',
                  'confidence': 'Confidence',
                  'repeat': 'Seen again',
                },
                busy: false,
                onAction: (_) {},
                imageLoader: _noImages,
              ),
            ),
          ),
        );

    testWidgets('the source chip and the spec line print verbatim', (t) async {
      await t.pumpWidget(card(gapRow(
          spec: 'What it is for: the cart totals every line the customer added')));
      await t.pump();
      expect(find.text('Exploratory bot'), findsOneWidget);
      expect(find.text('Contradicts'), findsOneWidget);
      expect(
          find.text('What it is for: the cart totals every line the customer added'),
          findsOneWidget);
      expect(find.text('Confidence'), findsOneWidget);
    });

    testWidgets('a repeat prints the backend sentence; one sighting prints nothing',
        (t) async {
      await t.pumpWidget(card(gapRow(spec: 'x')));
      await t.pump();
      expect(find.text('Seen again'), findsNothing);

      final repeated = gapRow(spec: 'x');
      repeated['repeat_label'] = 'reported by 4 runs, first on 02 Sep 2026';
      await t.pumpWidget(card(repeated));
      await t.pump();
      expect(find.text('Seen again'), findsOneWidget);
      // The sentence is printed, never assembled here: no count arrives
      // separately, so a card that worded it would have nothing to word.
      expect(find.text('reported by 4 runs, first on 02 Sep 2026'), findsOneWidget);
    });

    testWidgets('a hand-filed finding draws no source chip and no spec line',
        (t) async {
      await t.pumpWidget(card(gapRow(source: 'human')));
      await t.pump();
      expect(find.text('Exploratory bot'), findsNothing);
      // An absent spec line is an ABSENCE: no label, no dash.
      expect(find.text('Contradicts'), findsNothing);
      expect(find.text('Seen in'), findsNothing);
    });

    testWidgets('a finding with no screenshot draws no picture frame', (t) async {
      await t.pumpWidget(card(gapRow(spec: 'x')));
      await t.pump();
      expect(find.text('Seen in'), findsNothing);
      await t.pumpWidget(card(gapRow(spec: 'x', shotPath: 'run-91/a/top.png')));
      await t.pump();
      expect(find.text('Seen in'), findsOneWidget);
      await t.pumpAndSettle();
    });
  });
}
