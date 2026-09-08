import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/runner_boot_section.dart';

/// CHANGE #530 — the Runner boot card renders the boot doctor's verdict and
/// computes none of it.
///
/// This is the surface that tells Om a runner is refusing to claim after a
/// crash. Every sentence on it — the verdict, the repair lines, the released
/// count, the failed checks — is written by `runner_boot_status()`. The day
/// the app starts deducing "red" from a failed check itself, or pluralising a
/// count in Dart, this card stops matching what the runner actually did.
void main() {
  Widget host(Map<String, dynamic> data) => MaterialApp(
    home: Scaffold(body: SingleChildScrollView(child: RunnerBootSection(data: data))),
  );

  final green = {
    'ok': true,
    'title': 'Runner boot',
    'subtitle': 'Every runner runs the workspace doctor before it claims.',
    'mode_label': 'All runners green',
    'mode_tone': 'success',
    'counts_label': '7 green · 0 red (last 7 days)',
    'runners_head': 'Latest boot per runner',
    'recent_head': 'Recent boots',
    'empty_label': 'No runner has booted since this was switched on.',
    'runners': [
      {
        'agent': 'runner-2',
        'verdict': 'green',
        'verdict_label': 'Green — claiming',
        'tone': 'success',
        'at_label': '01 Sep 23:04 IST',
        'reason_label': 'Boot: start',
        'timing_label': 'Doctor ran in 0.6s',
        'released_label': 'No stale claims to release',
        'repairs_label': 'Workspace was already clean',
        'repairs': [],
        'checks': [
          {'key': 'db_reachable', 'label': 'Database reachable', 'ok': true, 'detail': 'answered'},
        ],
        'failed_label': '',
      },
    ],
    'recent': [
      {
        'at_label': '01 Sep 23:04 IST',
        'agent': 'runner-2',
        'verdict': 'green',
        'tone': 'success',
        'detail': 'Workspace green — claims allowed',
      },
    ],
  };

  testWidgets('a green boot prints the backend verdict and hides passing checks',
      (t) async {
    await t.pumpWidget(host(green));
    expect(find.text('Runner boot'), findsOneWidget);
    expect(find.text('All runners green'), findsOneWidget);
    expect(find.text('7 green · 0 red (last 7 days)'), findsOneWidget);
    expect(find.text('Green — claiming'), findsOneWidget);
    // The good news is the chip. A passing check is not printed as a line.
    expect(find.textContaining('Database reachable'), findsNothing);
    // The counts sentence is the BACKEND's, singular/plural and all.
    expect(
      find.textContaining('Workspace was already clean'),
      findsOneWidget,
    );
  });

  testWidgets('a red boot names only the FAILED checks, in the backend words',
      (t) async {
    final red = {
      ...green,
      'mode_label': '1 runner red',
      'mode_tone': 'error',
      'runners': [
        {
          'agent': 'runner-5',
          'verdict': 'red',
          'verdict_label': 'Red — refusing to claim',
          'tone': 'error',
          'at_label': '01 Sep 23:10 IST',
          'reason_label': 'Boot: start',
          'timing_label': 'Doctor ran in 1.2s',
          'released_label': '2 stale claims released',
          'repairs_label': '1 repair applied',
          'repairs': [
            {
              'key': 'git_lock',
              'label': 'Stale git lock removed',
              'detail': 'index.lock (age 940s)',
            },
          ],
          'checks': [
            {'key': 'db_reachable', 'label': 'Database reachable', 'ok': true, 'detail': 'answered'},
            {
              'key': 'disk_space',
              'label': 'Disk headroom',
              'ok': false,
              'detail': '0.4 GB free (98% used) — under the 2 GB floor',
            },
          ],
          'failed_label': '1 check(s) failed',
        },
      ],
    };
    await t.pumpWidget(host(red));
    expect(find.text('Red — refusing to claim'), findsOneWidget);
    expect(find.text('1 check(s) failed'), findsOneWidget);
    // The failed check prints label + the backend's own detail.
    expect(
      find.textContaining('Disk headroom — 0.4 GB free (98% used)'),
      findsOneWidget,
    );
    // The passing one still does not.
    expect(find.textContaining('Database reachable —'), findsNothing);
    // A repair is the backend's sentence, not a Dart summary of it.
    expect(
      find.textContaining('Stale git lock removed — index.lock (age 940s)'),
      findsOneWidget,
    );
    // The released count arrives pluralised by the backend.
    expect(find.textContaining('2 stale claims released'), findsOneWidget);
  });

  testWidgets('no boots yet is the backend empty state, never a blank card',
      (t) async {
    await t.pumpWidget(host({...green, 'runners': [], 'recent': []}));
    expect(
      find.text('No runner has booted since this was switched on.'),
      findsOneWidget,
    );
    expect(find.text('Latest boot per runner'), findsNothing);
  });

  testWidgets('ok:false renders the backend refusal, and nothing when silent',
      (t) async {
    await t.pumpWidget(host({'ok': false, 'error': 'Super admin only.'}));
    expect(find.text('Super admin only.'), findsOneWidget);

    await t.pumpWidget(host({'ok': false}));
    expect(find.byType(Card), findsNothing);
    expect(find.textContaining('Runner boot'), findsNothing);
  });
}
