// CMD #1960 — the command detail page on a phone.
//
// LESSONS, QA and JOURNEYS ran for screens each, and the conversation — the
// one part of a command Om replies to — sat underneath all three. These tests
// hold down the cure: the three sections are COLLAPSED dropdowns whose header
// words come from the backend, the open/closed choice is remembered per device,
// and the conversation is rendered ABOVE them.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/dev_queue_common.dart';
import 'package:pharma_b2b/services/ui_copy.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'dart:io';

// The chip format is a BACKEND string with a {n} slot — a Dart-side '4 items'
// would put the wording back in the app.
const _copy = <String, String>{
  'dev_queue.section_count_chip': '{n}',
  'dev_queue.section_expand': 'Show',
  'dev_queue.section_collapse': 'Hide',
  'dev_queue.status_paused': 'Paused',
};

Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child)));

Widget _section({String key = 'lessons', int count = 4}) => DqCollapsible(
      sectionKey: key,
      title: 'Lessons',
      count: count,
      builder: (_) => const Text('BODY-ROWS'),
    );

void main() {
  setUpAll(() {
    RenderLog.flushEnabled = false;
    UiCopy.debugSet(_copy);
  });

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('a section starts collapsed: header only, no body', (t) async {
    await t.pumpWidget(_host(_section()));
    await t.pumpAndSettle();

    expect(find.text('LESSONS'), findsOneWidget);
    // The count chip is the backend's format with the count substituted.
    expect(find.text('4'), findsOneWidget);
    expect(find.byIcon(Icons.expand_more), findsOneWidget);
    // Collapsed means the body was never built.
    expect(find.text('BODY-ROWS'), findsNothing);
  });

  testWidgets('tapping the header opens it and remembers the choice',
      (t) async {
    await t.pumpWidget(_host(_section()));
    await t.pumpAndSettle();

    await t.tap(find.text('LESSONS'));
    await t.pumpAndSettle();

    expect(find.text('BODY-ROWS'), findsOneWidget);
    expect(find.byIcon(Icons.expand_less), findsOneWidget);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('${DqCollapsible.prefsPrefix}lessons'), isTrue);
  });

  testWidgets('a remembered open section comes back open on this device',
      (t) async {
    SharedPreferences.setMockInitialValues(
        <String, Object>{'${DqCollapsible.prefsPrefix}qa': true});

    await t.pumpWidget(_host(_section(key: 'qa', count: 0)));
    await t.pumpAndSettle();

    expect(find.text('BODY-ROWS'), findsOneWidget);
    // Zero is still printed — an empty section says so rather than vanishing.
    expect(find.text('0'), findsOneWidget);
  });

  testWidgets('the memory is per section, not one flag for all', (t) async {
    SharedPreferences.setMockInitialValues(
        <String, Object>{'${DqCollapsible.prefsPrefix}lessons': true});

    await t.pumpWidget(_host(Column(children: [
      _section(),
      _section(key: 'journeys', count: 2),
    ])));
    await t.pumpAndSettle();

    // Lessons remembered open, journeys still collapsed.
    expect(find.text('BODY-ROWS'), findsOneWidget);
    expect(find.byIcon(Icons.expand_more), findsOneWidget);
    expect(find.byIcon(Icons.expand_less), findsOneWidget);
  });

  test('the conversation is rendered above the three long sections', () {
    final src = File('lib/screens/admin/dev_queue/dev_queue_detail.dart')
        .readAsStringSync();
    final chat = src.indexOf('                _chat(),');
    final lessons = src.indexOf('                _lessonsCard(),');
    final qa = src.indexOf('                QaJourneySection(');
    expect(chat, greaterThan(0));
    expect(lessons, greaterThan(0));
    expect(qa, greaterThan(0));
    expect(chat, lessThan(lessons));
    expect(chat, lessThan(qa));
  });
}
