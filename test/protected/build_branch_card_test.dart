// CHANGE #1470 — the Build-branch card is a PRINTER, and a refusal can never
// again be silent.
//
// #1149 shipped the branch lifecycle with no Flutter surface at all, so when
// the switch-on gate refused (a token read that errored to empty, then a
// 30-minute backoff behind a bare `return 0`) there was, by construction,
// nowhere for the reason to appear. Om was told "branch: off" for two days.
// These tests hold down the two halves of the cure: the card prints
// `build_branch_card()` verbatim, and it prints the BLOCKED sentence whenever
// the backend sends one.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/dev_queue_branch.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Widget _host(Map<String, dynamic> branch) => MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: BuildBranchCard(branch: branch)),
      ),
    );

// Deliberately inconsistent with itself: `display` says BLOCKED while `status`
// would read "off" and the newest attempt is an adopt. A card that re-derived
// its own sentence from any of those fields fails here.
final _blocked = <String, dynamic>{
  'has': true,
  'title': 'Build branch',
  'display': 'Branch blocked: SUPABASE_ACCESS_TOKEN not in the vault',
  'tone': 'failed',
  'blocked': true,
  'sub': null,
  'attempts_title': 'Recent attempts',
  'attempts_none': 'No attempt has been recorded yet.',
  'attempts': [
    {'at_display': '05 Sep 17:07', 'label': 'token — not in the vault', 'tone': 'failed'},
    {'at_display': '05 Sep 16:52', 'label': 'create — queue has work', 'tone': 'building'},
    {'at_display': '04 Sep 14:44', 'label': 'ready', 'tone': 'completed'},
  ],
};

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  testWidgets('a blocked gate prints the backend reason, never a bare "off"',
      (t) async {
    await t.pumpWidget(_host(_blocked));
    expect(find.text('Branch blocked: SUPABASE_ACCESS_TOKEN not in the vault'),
        findsOneWidget);
    // The word "off" is the resting state and must not be invented here.
    expect(find.text('branch: off'), findsNothing);
  });

  testWidgets('every attempt is drawn, in payload order', (t) async {
    await t.pumpWidget(_host(_blocked));
    expect(find.text('Recent attempts'), findsOneWidget);
    for (final a in (_blocked['attempts'] as List)) {
      expect(find.text((a as Map)['label'] as String), findsOneWidget);
      expect(find.text(a['at_display'] as String), findsOneWidget);
    }
    // Payload order, top to bottom — no client-side sort by date or tone.
    final ys = [
      for (final a in (_blocked['attempts'] as List))
        t.getTopLeft(find.text((a as Map)['label'] as String)).dy
    ];
    expect(ys[0] < ys[1] && ys[1] < ys[2], isTrue);
    expect(find.text('No attempt has been recorded yet.'), findsNothing);
  });

  testWidgets('has:false draws nothing at all', (t) async {
    await t.pumpWidget(_host({'has': false, 'display': 'branch: on · 2h 14m'}));
    expect(find.text('branch: on · 2h 14m'), findsNothing);
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('an absent sub-line is omitted, never dashed', (t) async {
    await t.pumpWidget(_host(_blocked));
    expect(find.text('—'), findsNothing);
    expect(find.text('-'), findsNothing);

    final withSub = Map<String, dynamic>.from(_blocked)
      ..['sub'] = 'wdkurruzrjxqxhwbkvuz · 3 builds';
    await t.pumpWidget(_host(withSub));
    expect(find.text('wdkurruzrjxqxhwbkvuz · 3 builds'), findsOneWidget);
  });

  testWidgets('an empty attempt list prints the backend empty state',
      (t) async {
    final none = Map<String, dynamic>.from(_blocked)..['attempts'] = const [];
    await t.pumpWidget(_host(none));
    expect(find.text('No attempt has been recorded yet.'), findsOneWidget);
  });

  testWidgets('a tone this build has never heard of still draws, neutral',
      (t) async {
    final odd = Map<String, dynamic>.from(_blocked)
      ..['tone'] = 'chartreuse'
      ..['attempts'] = [
        {'at_display': '05 Sep 18:00', 'label': 'reap_orphan — deleting', 'tone': 'wat'}
      ];
    await t.pumpWidget(_host(odd));
    expect(t.takeException(), isNull);
    expect(find.text('reap_orphan — deleting'), findsOneWidget);
  });

  testWidgets('the on state prints the backend sentence with its own age',
      (t) async {
    final on = Map<String, dynamic>.from(_blocked)
      ..['display'] = 'branch: on · 2h 14m'
      ..['tone'] = 'completed'
      ..['blocked'] = false;
    await t.pumpWidget(_host(on));
    // The age is the backend's; nothing here computes one from created_at.
    expect(find.text('branch: on · 2h 14m'), findsOneWidget);
  });
}
