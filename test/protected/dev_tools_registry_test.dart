// PROTECTED — CHANGE #349.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes the Dev Queue tools surface, never to make an unrelated
// change go green.
//
// The defect this exists to retire: the Dev Queue's tools lived in the
// AppBar's `actions:` list — nine bare IconButtons in a Row. A Row does not
// wrap and does not scroll, so on a phone the last tools rendered past the
// right edge and were unreachable, and the ones that fitted carried no label.
//
// What this holds down:
//
//   1. ONE SURFACE, EVERY TOOL LABELLED. Groups and items render IN PAYLOAD
//      ORDER (the fixture is deliberately not alphabetical) with the backend's
//      own label and description. No heading, no caption and no empty state is
//      written in Dart.
//
//   2. IT SCROLLS. The sheet's body is a scrollable, so a tool can never be
//      off the bottom the way it used to be off the right.
//
//   3. THE HARD GATE, BOTH WAYS. A tool the registry did not send cannot be
//      rendered (it is not in the payload at all), and a tool this build has
//      no screen for is DROPPED rather than drawn as a dead row. A group left
//      with nothing is dropped too — never an empty heading.
//
//   4. kDevToolKeys AND THE PAYLOAD AGREE. Every tool the registry migration
//      registers must be openable by this build.
//
//   5. REFUSALS AND EMPTINESS ARE THE BACKEND'S WORDS. ok:false prints the
//      payload's `message`; an empty payload prints its `empty_label`.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/dev_queue_screen.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/dev_tools_sheet.dart';
import 'package:pharma_b2b/utils/render_log.dart';

/// A dev_tools() reply. Group order and item order are deliberately NOT
/// alphabetical, so a client-side sort would be visible.
Map<String, dynamic> _payload() => {
      'ok': true,
      'title': 'Dev Queue tools',
      'subtitle': 'Every tool, labelled.',
      'search_hint': 'Filter tools',
      'empty_label': 'No tool is registered for your role.',
      'button_label': 'Tools',
      'tool_count': 4,
      'badge_total': 2,
      'groups': [
        {
          'key': 'Runtime & health',
          'label': 'Runtime & health',
          'items': [
            {
              'feature_key': 'devtool.signin_diag',
              'tool_key': 'signin_diag',
              'label': 'Sign-in diagnostics',
              'description': 'Why a login failed, per attempt',
              'icon_key': 'key',
              'icon_letter': 'S',
              'badge_count': 0,
              'badge_label': null,
            },
            {
              'feature_key': 'devtool.cron_health',
              'tool_key': 'cron_health',
              'label': 'Cron health',
              'description': 'Schedules and the three lanes',
              'icon_key': 'schedule',
              'icon_letter': 'C',
              'badge_count': 0,
              'badge_label': null,
            },
          ],
        },
        {
          'key': 'Proof & QA',
          'label': 'Proof & QA',
          'items': [
            {
              'feature_key': 'devtool.drafts',
              'tool_key': 'drafts_inbox',
              'label': 'Drafts inbox',
              'description': 'Commands still asking their questions',
              'icon_key': 'drafts',
              'icon_letter': 'D',
              'badge_count': 2,
              'badge_label': '2 drafts waiting',
            },
            {
              'feature_key': 'devtool.ghost',
              'tool_key': 'a_tool_this_build_has_no_screen_for',
              'label': 'Ghost tool',
              'description': 'Registered, but this build cannot open it',
              'icon_key': 'bug',
              'icon_letter': 'G',
              'badge_count': 0,
              'badge_label': null,
            },
          ],
        },
      ],
    };

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

Future<void> _pumpSheet(
  WidgetTester t, {
  Map<String, dynamic>? payload,
  Set<String>? available,
  List<Map<String, dynamic>>? picked,
}) async {
  await t.pumpWidget(_host(DevToolsSheet(
    load: () async => payload ?? _payload(),
    available: available ?? kDevToolKeys,
    onOpen: (tool) => picked?.add(tool),
  )));
  await t.pumpAndSettle();
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  testWidgets('groups and tools render in payload order, labelled', (t) async {
    await _pumpSheet(t);

    expect(find.text('Dev Queue tools'), findsOneWidget);
    expect(find.text('Every tool, labelled.'), findsOneWidget);

    // Group order is the payload's, not alphabetical ('Proof' < 'Runtime').
    final runtime = t.getTopLeft(find.text('Runtime & health')).dy;
    final proof = t.getTopLeft(find.text('Proof & QA')).dy;
    expect(runtime, lessThan(proof));

    // Item order inside a group is the payload's too.
    final signin = t.getTopLeft(find.text('Sign-in diagnostics')).dy;
    final cron = t.getTopLeft(find.text('Cron health')).dy;
    expect(signin, lessThan(cron));

    // Every tool carries its NAME and its DESCRIPTION — the icon row could
    // carry neither.
    expect(find.text('Why a login failed, per attempt'), findsOneWidget);
    expect(find.text('Commands still asking their questions'), findsOneWidget);
  });

  testWidgets('the surface scrolls — nothing can sit off the edge', (t) async {
    await _pumpSheet(t);
    expect(find.byType(Scrollable), findsWidgets);
  });

  testWidgets('a tool this build cannot open is dropped, not drawn dead',
      (t) async {
    await _pumpSheet(t);
    expect(find.text('Ghost tool'), findsNothing);
    // its group still renders, because a sibling survived
    expect(find.text('Drafts inbox'), findsOneWidget);
  });

  testWidgets('a group left with nothing renders no heading', (t) async {
    await _pumpSheet(t, available: const {'signin_diag', 'cron_health'});
    expect(find.text('Runtime & health'), findsOneWidget);
    expect(find.text('Proof & QA'), findsNothing);
    expect(find.text('Drafts inbox'), findsNothing);
  });

  testWidgets('the badge phrase is the backend’s, never pluralised in Dart',
      (t) async {
    await _pumpSheet(t);
    expect(find.text('2 drafts waiting'), findsOneWidget);
  });

  testWidgets('a tap hands back the backend row untouched', (t) async {
    final picked = <Map<String, dynamic>>[];
    await _pumpSheet(t, picked: picked);
    await t.tap(find.text('Cron health'));
    await t.pump();
    expect(picked.single['tool_key'], 'cron_health');
    expect(picked.single['feature_key'], 'devtool.cron_health');
  });

  testWidgets('ok:false renders the backend refusal, not an exception',
      (t) async {
    await _pumpSheet(t, payload: {
      'ok': false,
      'error': 'not_authorized',
      'message': 'Dev Queue tools are super-admin only.',
      'title': 'Dev Queue tools',
      'groups': const [],
      'tool_count': 0,
    });
    expect(find.text('Dev Queue tools are super-admin only.'), findsOneWidget);
  });

  testWidgets('an empty registry renders the backend empty state', (t) async {
    await _pumpSheet(t, payload: {
      'ok': true,
      'title': 'Dev Queue tools',
      'subtitle': '',
      'search_hint': 'Filter tools',
      'empty_label': 'No tool is registered for your role.',
      'groups': const [],
      'tool_count': 0,
    });
    expect(find.text('No tool is registered for your role.'), findsOneWidget);
  });

  test('every registered tool_key is one this build can open', () {
    final sql = File(
            'supabase/migrations/20260831190100_c349_dev_tools_registry.sql')
        .readAsStringSync();
    // route_key, then sort_order, then the owner — the shape of every VALUES
    // row in the dev_tools registration block.
    final registered = RegExp(r"'([a-z_]+)',\s*(\d+),\s*'medibo'")
        .allMatches(sql)
        .map((m) => m.group(1)!)
        .toSet();
    expect(registered.length, kDevToolKeys.length,
        reason: 'the migration registers ${registered.length} tools but this '
            'build knows ${kDevToolKeys.length}');
    expect(registered.difference(kDevToolKeys), isEmpty,
        reason: 'the registry registers a tool this build cannot open — it '
            'would be listed and then do nothing');
    expect(kDevToolKeys.difference(registered), isEmpty,
        reason: 'this build can open a tool the registry never registers — it '
            'would be reachable from nowhere, which is the #349 defect');
  });
}
