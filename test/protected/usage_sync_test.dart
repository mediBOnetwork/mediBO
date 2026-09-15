// PROTECTED — the Claude usage block is a PRINTER (CHANGE #1365).
//
// The bug this holds down was invisible precisely because the card looked fine.
// The VM idled on 4 Sep with the weekly limit at 100%. It booted, the fetcher
// died on every tick ("no token" — the OAuth token is only refreshed by a Claude
// Code session, and no session existed), and the card kept printing "synced 15h
// ago" over a percentage whose window had already reset. The supervisor believed
// it, shrank the pool to one, nothing claimed, so no session started, so the
// token was never refreshed. A closed loop no test could see, because every
// number on screen was plausible.
//
// So the rule is: this widget decides NOTHING about usage. The fixtures below
// deliberately disagree with themselves — a limit whose `percent` is 0 while its
// `pct_display` says '100%', a payload marked `stale` while its tone says
// completed — and a card that recomputed any of it fails.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/dev_queue/usage_meter.dart';
import 'package:pharma_b2b/services/ui_copy.dart';

Map<String, dynamic> _healthy() => {
      'has_usage': true,
      'limits': [
        {
          'label': 'Current session · 5h',
          'percent': 31,
          'pct_display': '31%',
          'tone': 'completed',
          'resets_display': 'Resets in 2h 19m',
          'expired': false,
          'stale_ignored': false,
        },
        {
          'label': 'Weekly · all models',
          'percent': 5,
          'pct_display': '5%',
          'tone': 'completed',
          'resets_display': 'Resets Sat 12 Sep',
          'expired': false,
          'stale_ignored': false,
        },
      ],
      'quota_pct': 31,
      'quota_unknown': false,
      'quota_shrink': false,
      'fetch_failing': false,
      'updated_display': 'synced just now',
      'updated_tone': 'completed',
      'stale': false,
      'spend_display': '412K · ₹1,204 (5h)',
      'today_display': 'Today: 1.2M · ₹3,880 · 9 cmds',
    };

Future<void> _pump(WidgetTester t, Map<String, dynamic> usage,
        {VoidCallback? onRates}) =>
    t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: UsageMeter(usage: usage, onRates: onRates),
        ),
      ),
    ));

void main() {
  setUpAll(() {
    // The copy layer is a backend table; in the VM test it falls back to its
    // keys, which is all these assertions need — nothing here checks copy.
    UiCopy.debugSet(const {
      'dev_queue.usage_label': 'Claude usage',
      'dev_queue.plan_note': 'Max 20x plan',
      'dev_queue.rates_open': 'Rates',
    });
  });

  testWidgets('the sync line and its tone are the backend sentence, verbatim',
      (t) async {
    await _pump(t, _healthy());
    expect(find.text('synced just now'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(find.byIcon(Icons.sync_problem), findsNothing);
  });

  testWidgets('a failing fetcher prints its reason instead of a freshness lie',
      (t) async {
    // This is the exact payload dev_cmd_session_usage() returns while
    // usage_fetch_error is the newest thing that happened to the fetcher.
    final u = _healthy()
      ..['fetch_failing'] = true
      ..['fetch_error_reason'] =
          'Claude login not usable — claudeAiOauth.accessToken absent'
      ..['updated_display'] =
          'sync failing: Claude login not usable — claudeAiOauth.accessToken absent'
      ..['updated_tone'] = 'failed'
      ..['stale'] = true;
    await _pump(t, u);

    expect(
        find.text(
            'sync failing: Claude login not usable — claudeAiOauth.accessToken absent'),
        findsOneWidget);
    // Never "synced Nh ago" alongside it, and never the healthy tick.
    expect(find.textContaining('synced'), findsNothing);
    expect(find.byIcon(Icons.sync_problem), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsNothing);
    expect(laidOutWithoutOverflow(t), isTrue);
  });

  testWidgets('every percentage on screen is the payload string, not a sum',
      (t) async {
    // An EXPIRED window: the backend counted it as 0 and says so in
    // resets_display, while raw_percent remembers the 100 that was read before
    // the window reset. The card must print the backend's 0%-shaped strings.
    final u = _healthy()
      ..['limits'] = [
        {
          'label': 'Weekly · all models',
          'percent': 0,
          'raw_percent': 100,
          'pct_display': '0%',
          'tone': 'completed',
          'resets_display': 'window reset — counted as 0% until the next sync',
          'expired': true,
          'stale_ignored': false,
        },
      ];
    await _pump(t, u);
    expect(find.text('0%'), findsOneWidget);
    expect(find.text('100%'), findsNothing);
    expect(find.text('window reset — counted as 0% until the next sync'),
        findsOneWidget);
  });

  testWidgets('a stale-ignored reading draws the backend copy, not an empty card',
      (t) async {
    final u = _healthy()
      ..['quota_unknown'] = true
      ..['limits'] = [
        {
          'label': 'Current session · 5h',
          'percent': 0,
          'raw_percent': 74,
          'pct_display': '0%',
          'tone': 'completed',
          'resets_display': 'sync too old — not used for pool decisions',
          'expired': false,
          'stale_ignored': true,
        },
      ];
    await _pump(t, u);
    expect(find.text('sync too old — not used for pool decisions'),
        findsOneWidget);
    expect(find.text('74%'), findsNothing);
  });

  testWidgets('bars render in payload order — the card never sorts', (t) async {
    final u = _healthy()
      ..['limits'] = [
        {'label': 'Weekly · Fable', 'percent': 8, 'pct_display': '8%', 'tone': 'completed', 'resets_display': ''},
        {'label': 'Current session · 5h', 'percent': 31, 'pct_display': '31%', 'tone': 'completed', 'resets_display': ''},
        {'label': 'Weekly · all models', 'percent': 5, 'pct_display': '5%', 'tone': 'completed', 'resets_display': ''},
      ];
    await _pump(t, u);
    final labels = t
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.data ?? '')
        .where((s) => s.startsWith('Weekly') || s.startsWith('Current'))
        .toList();
    expect(labels,
        ['Weekly · Fable', 'Current session · 5h', 'Weekly · all models']);
  });

  testWidgets('an absent block is omitted, never dashed or defaulted',
      (t) async {
    await _pump(t, {'has_usage': false, 'limits': const []});
    // No sync chip, no spend lines, no bars — and no crash on the empty payload.
    expect(find.byIcon(Icons.check_circle), findsNothing);
    expect(find.byIcon(Icons.sync_problem), findsNothing);
    expect(find.textContaining('₹'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('the rates chip appears only when the screen offers the action',
      (t) async {
    await _pump(t, _healthy());
    expect(find.byType(InkWell), findsNothing);
    var tapped = 0;
    await _pump(t, _healthy(), onRates: () => tapped++);
    expect(find.byType(InkWell), findsOneWidget);
    await t.tap(find.byType(InkWell));
    expect(tapped, 1);
  });
}

/// True when nothing overflowed while laying the card out. A long failure
/// sentence used to be the one string the chip could not hold.
bool laidOutWithoutOverflow(WidgetTester t) => t.takeException() == null;
