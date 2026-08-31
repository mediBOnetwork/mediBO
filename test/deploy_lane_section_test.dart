import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medibo/screens/admin/dev_queue/deploy_lane_section.dart';

/// CHANGE #324 — the Deploy lane section computes NOTHING.
///
/// Every duration, every label and every empty state in this card is a string
/// `deploy_lane_status()` built. The bug this pins down is the one the command
/// existed to fix: the lane's own numbers were unmeasurable because
/// `deployed_at` was never stamped, so a card that quietly re-derived "held
/// 30s" in Dart from a null would have looked healthy while the lane was
/// stuck. Nothing here is derived — if the payload does not say it, it does
/// not appear.
Widget _wrap(Map<String, dynamic> data) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(child: DeployLaneSection(data: data)),
  ),
);

Map<String, dynamic> _payload({
  Map<String, dynamic>? lane,
  Map<String, dynamic>? queue,
  Map<String, dynamic>? batch,
  List<dynamic>? recent,
  List<dynamic>? stale,
}) => {
  'ok': true,
  'title': 'Deploy lane',
  'subtitle': 'Merge queue — runners push a branch and leave.',
  'mode_label': 'MERGE QUEUE',
  'mode_tone': 'success',
  'lane':
      lane ??
      {
        'busy': false,
        'label': 'Lane free',
        'detail': 'Nothing merging right now.',
        'held_label': '—',
        'over_target': false,
        'tone': 'success',
      },
  'queue':
      queue ??
      {
        'count': 0,
        'label': 'Queue empty',
        'empty_hint': 'Runners push a branch here and go back to building.',
        'rows': const [],
      },
  'batch': batch,
  'metrics': {
    'heading': 'Wait vs hold, last 7 days',
    'samples': 21,
    'avg_hold_label': 'avg lane hold 215s',
    'avg_wait_label': 'no queue wait recorded yet',
    'target_label': 'target hold under 60s',
    'tone': 'warning',
  },
  'recent_heading': 'Recent deploys',
  'recent': recent ?? const [],
  'stale_heading': 'Stale claims',
  'stale_empty': 'No claim is holding a queue slot past its TTL.',
  'stale': stale ?? const [],
};

void main() {
  testWidgets('renders the backend headline, mode chip and subtitle verbatim', (
    t,
  ) async {
    await t.pumpWidget(_wrap(_payload()));
    expect(find.text('Deploy lane'), findsOneWidget);
    expect(find.text('MERGE QUEUE'), findsOneWidget);
    expect(
      find.text('Merge queue — runners push a branch and leave.'),
      findsOneWidget,
    );
  });

  testWidgets('an empty queue shows the backend hint, never a Dart sentence', (
    t,
  ) async {
    await t.pumpWidget(_wrap(_payload()));
    expect(find.text('Queue empty'), findsOneWidget);
    expect(
      find.text('Runners push a branch here and go back to building.'),
      findsOneWidget,
    );
  });

  testWidgets('waiting branches render in payload order with their own waits', (
    t,
  ) async {
    // Deliberately NOT sorted by wait time: the backend already ordered them
    // by pushed_at and the card must not re-sort.
    await t.pumpWidget(
      _wrap(
        _payload(
          queue: {
            'count': 2,
            'label': '2 branches waiting',
            'empty_hint': 'unused',
            'rows': [
              {
                'entry_id': 1,
                'label': '#310 · zone fix',
                'detail': 'runner-2 · c310',
                'value_label': 'waiting 12s',
                'tone': 'info',
              },
              {
                'entry_id': 2,
                'label': '#311 · billing tab',
                'detail': 'runner-5 · c311',
                'value_label': 'waiting 240s',
                'tone': 'info',
              },
            ],
          },
        ),
      ),
    );
    expect(find.text('2 branches waiting'), findsOneWidget);
    expect(find.text('waiting 12s'), findsOneWidget);
    expect(find.text('waiting 240s'), findsOneWidget);

    final first = t.getTopLeft(find.text('#310 · zone fix')).dy;
    final second = t.getTopLeft(find.text('#311 · billing tab')).dy;
    expect(first, lessThan(second));
  });

  testWidgets('a held lane prints the backend hold string, not a computed one', (
    t,
  ) async {
    await t.pumpWidget(
      _wrap(
        _payload(
          lane: {
            'busy': true,
            'label': 'Lane held by merge-worker',
            'detail': 'merge batch · held 41s',
            'held_label': '41s',
            'over_target': false,
            'tone': 'info',
          },
        ),
      ),
    );
    expect(find.text('Lane held by merge-worker'), findsOneWidget);
    expect(find.text('merge batch · held 41s'), findsOneWidget);
    expect(find.text('41s'), findsOneWidget);
  });

  testWidgets('no batch in the payload means no batch row is invented', (
    t,
  ) async {
    await t.pumpWidget(_wrap(_payload()));
    expect(find.textContaining('Batch '), findsNothing);

    await t.pumpWidget(
      _wrap(
        _payload(
          batch: {
            'id': 7,
            'status': 'deploying',
            'label': 'Batch 7 · 3 branch(es)',
            'value_label': 'deploying',
            'tone': 'info',
          },
        ),
      ),
    );
    expect(find.text('Batch 7 · 3 branch(es)'), findsOneWidget);
    expect(find.text('deploying'), findsOneWidget);
  });

  testWidgets('a never-released claim shows the backend words for it', (
    t,
  ) async {
    // This is the exact shape of 827 and 829: finished work whose registry row
    // stayed 'claimed' and kept holding a queue slot.
    await t.pumpWidget(
      _wrap(
        _payload(
          stale: [
            {
              'change_no': 827,
              'label': '#827 · Profit & loss',
              'detail': 'runner-2',
              'value_label': 'held since 31 Aug 12:24 IST',
              'tone': 'warning',
            },
          ],
        ),
      ),
    );
    expect(find.text('Stale claims'), findsOneWidget);
    expect(find.text('#827 · Profit & loss'), findsOneWidget);
    expect(find.text('held since 31 Aug 12:24 IST'), findsOneWidget);
    expect(
      find.text('No claim is holding a queue slot past its TTL.'),
      findsNothing,
    );
  });

  testWidgets('no stale claim shows the backend empty state', (t) async {
    await t.pumpWidget(_wrap(_payload()));
    expect(
      find.text('No claim is holding a queue slot past its TTL.'),
      findsOneWidget,
    );
  });

  testWidgets('wait vs hold metrics print verbatim, including the absence', (
    t,
  ) async {
    await t.pumpWidget(_wrap(_payload()));
    expect(find.text('Wait vs hold, last 7 days'), findsOneWidget);
    expect(find.text('avg lane hold 215s'), findsOneWidget);
    // The absence of a measurement is the BACKEND's sentence, not a "0s".
    expect(find.text('no queue wait recorded yet'), findsOneWidget);
    expect(find.text('target hold under 60s'), findsOneWidget);
  });

  testWidgets('recent deploys carry the backend timing string per row', (
    t,
  ) async {
    await t.pumpWidget(
      _wrap(
        _payload(
          recent: [
            {
              'change_no': 830,
              'label': '#830 · settlement',
              'detail': 'runner-1',
              'value_label': 'held 142s',
              'tone': 'success',
            },
            {
              'change_no': 829,
              'label': '#829 · partner login',
              'detail': 'runner-4',
              'value_label': 'held 140s · waited 33s',
              'tone': 'success',
            },
          ],
        ),
      ),
    );
    expect(find.text('Recent deploys'), findsOneWidget);
    expect(find.text('held 142s'), findsOneWidget);
    expect(find.text('held 140s · waited 33s'), findsOneWidget);
  });

  testWidgets('ok:false renders the backend refusal, never a thrown error', (
    t,
  ) async {
    await t.pumpWidget(
      _wrap({'ok': false, 'error': 'dev_queue: not authorized'}),
    );
    expect(find.text('dev_queue: not authorized'), findsOneWidget);
    expect(find.text('Deploy lane'), findsNothing);
  });

  testWidgets('ok:false with no message renders nothing at all', (t) async {
    await t.pumpWidget(_wrap(const {'ok': false}));
    expect(find.byType(Text), findsNothing);
  });
}
