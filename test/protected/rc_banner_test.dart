// PROTECTED — CHANGE #1662.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes Remote-Control-health behaviour, never to make an
// unrelated change go green.
//
// WHAT THIS HOLDS DOWN — the worker card is a PRINTER about its own sessions.
//
// #239 already wrote a long comment explaining why Remote Control sessions
// would never churn again, and on 5 Sep they churned anyway: ~20 notifications
// in two minutes for slots that were building nothing. A comment is not a
// guard. This is.
//
//   1. THE SENTENCE IS THE BACKEND'S. `rc_banner` prints verbatim. The fixture
//      says "reopened 7 times in 10 min" while nothing in the payload counts to
//      seven, so a card that recomposed the sentence out of numbers it could
//      see would fail here.
//
//   2. ABSENCE DRAWS NOTHING. No `rc_banner` key, or an empty one, means no
//      banner at all — not an empty chip, not a reassuring green "sessions
//      healthy". A permanent all-clear is how a real red stops being read.
//
//   3. TONE IS CARRIED, NOT INFERRED. One lookup on the payload's own
//      `rc_banner_tone`; a tone this build has never heard of stays neutral
//      instead of being guessed at from the words in the sentence.
//
//   4. IT IS ITS OWN BANNER. The flapping banner and the pool's shrink banner
//      are independent: either can be present without the other, and both
//      render together when the backend sends both.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:pharma_b2b/screens/admin/dev_queue/dev_queue_service.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/dev_queue_workers.dart';
import 'package:pharma_b2b/utils/render_log.dart';

// autoRefreshToken:false — GoTrue otherwise starts a 10s periodic timer that
// outlives the widget tree and trips flutter_test's !timersPending.
DevQueueService _service() => DevQueueService(
      client: SupabaseClient('http://localhost:1', 'test-key',
          authOptions: const AuthClientOptions(autoRefreshToken: false)),
    );

Map<String, dynamic> _pool({Map<String, dynamic>? state}) => {
      'config': const {'cap': 4},
      'state': {
        'active_workers': 2,
        'workers': const [],
        ...?state,
      },
    };

Future<void> _pump(WidgetTester tester, Map<String, dynamic> pool) =>
    tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: WorkerGridCard(
            pool: pool,
            service: _service(),
            onChanged: () {},
          ),
        ),
      ),
    ));

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  const banner =
      'Remote Control flapping — runner-4 reopened 7 times in 10 min; '
      'reopening is paused';

  testWidgets('the flapping sentence is printed verbatim', (tester) async {
    await _pump(
        tester,
        _pool(state: {
          // Nothing here counts to seven. The card must not try.
          'rc_banner': banner,
          'rc_banner_tone': 'warning',
        }));
    expect(find.text(banner), findsOneWidget);
  });

  testWidgets('no rc_banner draws no banner at all', (tester) async {
    await _pump(tester, _pool());
    expect(find.textContaining('Remote Control'), findsNothing);
    expect(find.textContaining('flapping'), findsNothing);
    // Nor a reassuring all-clear invented on the card's own authority.
    expect(find.textContaining('healthy'), findsNothing);
  });

  testWidgets('an empty rc_banner is absence, not an empty row',
      (tester) async {
    await _pump(tester, _pool(state: {'rc_banner': '', 'rc_banner_tone': 'warning'}));
    expect(find.byIcon(Icons.link_off), findsNothing);
  });

  testWidgets('an unknown tone still renders the sentence', (tester) async {
    await _pump(
        tester,
        _pool(state: {
          'rc_banner': banner,
          'rc_banner_tone': 'aubergine',
        }));
    expect(find.text(banner), findsOneWidget);
    expect(find.byIcon(Icons.link_off), findsOneWidget);
  });

  testWidgets('the flapping banner and the shrink banner are independent',
      (tester) async {
    await _pump(
        tester,
        _pool(state: {
          'rc_banner': banner,
          'rc_banner_tone': 'warning',
          'shrink_display': 'Pool shrunk to 1 — Claude usage at 92%',
        }));
    expect(find.text(banner), findsOneWidget);
    expect(find.text('Pool shrunk to 1 — Claude usage at 92%'), findsOneWidget);

    await _pump(
        tester, _pool(state: {'shrink_display': 'Pool shrunk to 1 — load 7.2'}));
    expect(find.text('Pool shrunk to 1 — load 7.2'), findsOneWidget);
    expect(find.textContaining('Remote Control'), findsNothing);
  });
}
