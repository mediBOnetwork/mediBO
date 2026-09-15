// PROTECTED — CMD #1866.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes what the Deploy lane says about the wait gate, never to
// make an unrelated change go green.
//
// WHAT THIS HOLDS DOWN. On 07 Sep 15:52 IST #1863 was parked on the deploy lock
// that its OWN direct deploy was holding: the runner was released, the next
// session cold-read the whole context, and a five-control wiring job cost 4.4M
// tokens. Two things had to become visible for that to stop being invisible —
// WHO holds the lock, and WHAT the gate decided — and both are backend strings.
//
//   1. THE LOCK LABEL IS ONE BACKEND STRING. "deploy lock — #1863 (own)" and
//      "deploy lock — #1864" differ by a suffix the SERVER adds, because only
//      the server knows which command is asking. The fixture deliberately pairs
//      a lock_label of "deploy lock — #1864" with a lock_command_id of 1866 and
//      a holder agent of 'runner-1' — a card that re-derived "(own)" from those
//      ids, or from the holder name, fails here.
//
//   2. TONE IS A LOOKUP, NEVER A DEDUCTION. The same fixture gives that
//      "somebody else's" label the 'info' tone. A card that coloured the chip
//      by asking "does the label end in (own)?" fails.
//
//   3. ABSENCE DRAWS NOTHING. No lock_label → no chip (not a dash, not the word
//      "free"); gate.has:false → no title, no subtitle, no rows, no zero.
//
//   4. GATE ROWS RENDER IN PAYLOAD ORDER and print verbatim. The fixture is
//      deliberately neither alphabetical nor in time order, and one row's
//      decision word ('park') sits BELOW a later timestamp — the order is the
//      backend's, and the sentence is the backend's.
//
//   5. AN UNKNOWN DECISION STILL RENDERS. A new gate decision is an INSERT, not
//      a deploy: an unrecognised tone name falls back to neutral instead of
//      throwing, and the row is still drawn.
//
//   6. THE PARK COUNT IS THE BACKEND'S SENTENCE. The fixture says "No parks in
//      the last 24h." while the rows below it contain a row whose decision IS
//      'park' — because the count is a 24-hour query in SQL, not a tally of the
//      eight rows this card happens to be showing.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/deploy_lane_section.dart';

Widget _host(Map<String, dynamic> data) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(child: DeployLaneSection(data: data)),
  ),
);

/// The smallest payload the card will draw: everything this file does not
/// assert on is present but empty, so a failure here is about the gate.
Map<String, dynamic> _payload({Map<String, dynamic>? lane, Object? gate}) => {
  'ok': true,
  'title': 'Deploy lane',
  'subtitle': 'Direct deploys — each command holds the deploy lock.',
  'mode_label': 'DIRECT (deploy_lock)',
  'mode_tone': 'info',
  'lane': {
    'busy': true,
    'label': 'Lane held by runner-1',
    'detail': 'CMD #1866 · held 41s',
    'held_label': '41s',
    'tone': 'info',
    ...?lane,
  },
  'queue': {'count': 0, 'label': 'Queue empty', 'rows': const []},
  'metrics': const {
    'heading': 'Wait vs hold, last 7 days',
    'avg_hold_label': 'avg lane hold 300s',
    'avg_wait_label': 'no queue wait recorded yet',
    'target_label': 'target hold under 60s',
    'tone': 'info',
  },
  'recent_heading': 'Recent deploys',
  'recent': const [],
  'stale_heading': 'Stale claims',
  'stale_empty': 'No claim is holding a queue slot past its TTL.',
  'stale': const [],
  'smoke': const {'has': false},
  'batches': const {'has': false},
  if (gate != null) 'gate': gate,
};

/// Deliberately out of order, and deliberately at odds with the count above it.
Map<String, dynamic> _gate() => {
  'has': true,
  'title': 'Wait gate',
  'subtitle':
      'Parking is OFF (wait_gate.park_enabled=false) — a blocked session '
      'sleeps or holds; it is never released and nothing is ever re-read.',
  'chip': 'park OFF',
  'chip_tone': 'success',
  'parks_24h_label': 'No parks in the last 24h.',
  'parks_24h_tone': 'success',
  'empty': 'No gate decisions recorded yet.',
  'rows': const [
    {
      'label': '#1866 · deploy',
      'detail':
          'deploy lock — #1866 (own) — own deploy running under the deploy '
          'lock · ~540s · 07 Sep 21:42 IST',
      'value': 'mine',
      'tone': 'success',
    },
    {
      // Older than the row above it: payload order, not time order.
      'label': '#1863 · deploy',
      'detail': 'deploy lock — #1859 — queued behind another lane · ~900s '
          '· 07 Sep 15:52 IST',
      'value': 'park',
      'tone': 'danger',
    },
    {
      // A decision this build has never heard of, with a tone to match.
      'label': '#1870 · grant',
      'detail': 'no holder — waiting on a Google grant · 07 Sep 22:10 IST',
      'value': 'escalated',
      'tone': 'ultraviolet',
    },
  ],
};

void main() {
  testWidgets('the lock label is the backend\'s string, with its own tone', (
    t,
  ) async {
    await t.pumpWidget(
      _host(
        _payload(
          lane: {
            // The card is #1866's, the lock is #1864's — and the SERVER is the
            // only thing that gets to say so.
            'lock_label': 'deploy lock — #1864',
            'lock_tone': 'info',
            'lock_command_id': 1866,
            'label': 'Lane held by runner-1',
          },
        ),
      ),
    );

    expect(find.text('deploy lock — #1864'), findsOneWidget);
    // Nothing anywhere re-words it into an ownership claim.
    expect(find.textContaining('(own)'), findsNothing);
  });

  testWidgets('no lock label draws no chip — not a dash, not "free"', (
    t,
  ) async {
    await t.pumpWidget(_host(_payload()));
    // The lane's own subtitle mentions the deploy lock; what must be absent is
    // the LABEL, whose shape is always "deploy lock — <who>".
    expect(find.textContaining('deploy lock — '), findsNothing);
    expect(find.text('—'), findsNothing);
  });

  testWidgets('gate has:false draws nothing at all', (t) async {
    await t.pumpWidget(_host(_payload(gate: const {'has': false})));
    expect(find.text('Wait gate'), findsNothing);
    expect(find.textContaining('park OFF'), findsNothing);
    expect(find.textContaining('No parks'), findsNothing);
  });

  testWidgets('an absent gate block is absent, and the card still renders', (
    t,
  ) async {
    await t.pumpWidget(_host(_payload()));
    expect(find.text('Deploy lane'), findsOneWidget);
    expect(find.text('Wait gate'), findsNothing);
  });

  testWidgets('gate rows print verbatim, in payload order', (t) async {
    await t.pumpWidget(_host(_payload(gate: _gate())));

    expect(find.text('Wait gate'), findsOneWidget);
    expect(find.text('park OFF'), findsOneWidget);
    expect(
      find.textContaining('Parking is OFF (wait_gate.park_enabled=false)'),
      findsOneWidget,
    );

    for (final row in (_gate()['rows'] as List)) {
      final r = row as Map;
      expect(find.text(r['label'] as String), findsOneWidget);
      expect(find.text(r['detail'] as String), findsOneWidget);
      expect(find.text(r['value'] as String), findsOneWidget);
    }

    // Payload order: the 'mine' row is drawn above the older 'park' row.
    final mine = t.getTopLeft(find.text('#1866 · deploy')).dy;
    final park = t.getTopLeft(find.text('#1863 · deploy')).dy;
    final grant = t.getTopLeft(find.text('#1870 · grant')).dy;
    expect(mine, lessThan(park));
    expect(park, lessThan(grant));
  });

  testWidgets('a decision this build has never heard of still renders', (
    t,
  ) async {
    await t.pumpWidget(_host(_payload(gate: _gate())));
    // Unknown verdict word, unknown tone name: drawn, neutral, no throw.
    expect(find.text('escalated'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('the 24h park count is the backend\'s sentence, not a tally', (
    t,
  ) async {
    await t.pumpWidget(_host(_payload(gate: _gate())));
    // A 'park' row is on screen; the sentence above it still says none, because
    // the count is a 24-hour SQL query and this list is the last eight rows.
    expect(find.text('park'), findsOneWidget);
    expect(find.text('No parks in the last 24h.'), findsOneWidget);
  });

  testWidgets('an absent park count omits its line rather than printing zero', (
    t,
  ) async {
    final g = _gate()..remove('parks_24h_label');
    await t.pumpWidget(_host(_payload(gate: g)));
    expect(find.text('Wait gate'), findsOneWidget);
    expect(find.textContaining('parks in the last 24h'), findsNothing);
    expect(find.text('0'), findsNothing);
  });
}
