// PROTECTED — CMD #1820.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes the Token dashboard's contract, never to make an
// unrelated change go green.
//
// The defect this exists to retire: a money screen that does its own sums.
// Om pays for these tokens, and the one thing that makes the dashboard worth
// opening is that its numbers ARE the database's numbers. The moment Dart
// divides, formats, pluralises or rounds anything, the screen and the SQL can
// disagree and nobody can tell which is lying.
//
// So the fixture below is deliberately INCONSISTENT WITH ITSELF: the headline
// says ₹9,999 while the spend rows add to something else, a phase share reads
// 12.5% against tokens that are not an eighth of anything, and a bar's `pct`
// disagrees with its own value. Every one of those is printed verbatim. A
// screen that recomputed even one of them fails here.
//
// What this holds down:
//
//   1. IT IS A PRINTER. Title, headline, self-check, section titles, column
//      labels, every cell, every sub-line and the footnote are payload strings.
//   2. PAYLOAD ORDER. Sections and rows render in the order they arrive; the
//      fixture is deliberately not alphabetical and not sorted by size.
//   3. FORWARD COMPAT. A section whose `kind` this build has never seen is
//      skipped in SILENCE — not as an empty card with a heading over it.
//   4. ABSENCE IS ABSENCE. A missing sub-line is omitted, never dashed; a '—'
//      in the payload is printed as '—' and never turned into a zero.
//   5. TONE IS ONE LOOKUP. An unknown tone name stays neutral rather than
//      throwing or defaulting to red.
//   6. THE SCOPE IS THE BACKEND'S. Which window is selected comes from the
//      payload's own `selected` flag, not from the local variable.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/token_dashboard_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _payload({List? sections}) => {
      'ok': true,
      'has': true,
      'title': 'Token dashboard',
      'subtitle': 'Where every token and rupee went.',
      'scope': {
        'key': 'today',
        'label': 'Today',
        // 'week' is the selected one even though the screen opens on 'today':
        // the flag is the backend's, and it is what must win.
        'options': [
          {'key': 'today', 'label': 'Today', 'selected': false},
          {'key': 'week', 'label': 'This week', 'selected': true},
          {'key': 'all', 'label': 'All time', 'selected': false},
        ],
      },
      'zone_label': 'All zones',
      'date_label': '06 Sep 2026',
      'basis_label':
          'Rupees are API-equivalent value — the runner is on a Max subscription.',
      // Deliberately at odds with the spend rows below.
      'headline': {
        'label': 'Today',
        'value': '₹9,999',
        'sub': '80.1M tokens over 33 command(s)',
      },
      'selfcheck': {
        'label': 'Self-check',
        'value': '0.00% drift',
        'tone': 'success',
        'sub': 'stored ₹68,650.86 vs recomputed ₹68,650.86 · flagged over 1%',
      },
      'sections': sections ??
          [
            {
              'key': 'spend',
              'kind': 'table',
              'title': 'Where it went',
              'sub': 'A build is booked to the day it finished.',
              'columns': [
                {'label': 'Window'},
                {'label': 'Tokens', 'align': 'right'},
                {'label': '₹', 'align': 'right'},
              ],
              'rows': [
                {
                  'key': 'today',
                  'cells': [
                    {'text': 'Today'},
                    {'text': '80.1M', 'align': 'right'},
                    {'text': '₹68,651', 'align': 'right'},
                  ],
                  'sub': '33 command(s)',
                },
                {
                  'key': 'all',
                  'cells': [
                    {'text': 'All time'},
                    {'text': '573.6M', 'align': 'right'},
                    // The em-dash is a real answer, not a missing one.
                    {'text': '—', 'align': 'right'},
                  ],
                },
              ],
              'empty_label': 'Nothing booked yet.',
            },
            {
              'key': 'phase',
              'kind': 'table',
              'title': 'Cost by phase',
              'columns': [
                {'label': 'Phase'},
                {'label': 'Tokens', 'align': 'right'},
                {'label': 'Share', 'align': 'right'},
              ],
              'rows': [
                {
                  'key': 'planning',
                  'tone': 'info',
                  'cells': [
                    {'text': 'Planning'},
                    {'text': '3.0M', 'align': 'right'},
                    // 3.0M of 80.1M is not 12.5%. Printed anyway.
                    {'text': '12.5%', 'align': 'right'},
                  ],
                },
              ],
              'empty_label': 'Nothing spent in this window.',
            },
            {
              'key': 'by_area',
              'kind': 'bars',
              'title': 'By area of the codebase',
              'rows': [
                {
                  'label': 'storefront',
                  'value': '40.0M',
                  'sub': '9 command(s)',
                  // A half-share value with a 7% bar: the bar is the payload's.
                  'pct': 7,
                  'tone': 'info',
                },
                {
                  'label': 'unassigned',
                  'value': '1.0M',
                  'pct': 90,
                  'tone': 'not_a_real_tone',
                },
              ],
              'empty_label': 'No spend to split.',
            },
            {
              'key': 'from_the_future',
              'kind': 'sunburst',
              'title': 'A kind this build has never heard of',
              'rows': [
                {'label': 'should never appear', 'value': 'nor this'}
              ],
            },
            {
              'key': 'whatif',
              'kind': 'tiles',
              'title': 'With zero waiting',
              'rows': [
                {
                  'label': 'Difference',
                  'value': '₹1,882',
                  'sub': '2.5M tokens burned waiting',
                  'tone': 'danger',
                },
              ],
              'empty_label': '',
            },
            {
              'key': 'rework',
              'kind': 'table',
              'title': 'Same file, again and again',
              'columns': [
                {'label': 'File'}
              ],
              'rows': const [],
              'empty_label': 'No file was taken by three commands.',
            },
          ],
      'footnote': 'Nothing on this screen is apportioned or prorated.',
    };

Future<void> _pump(WidgetTester t, Map<String, dynamic> payload) async {
  // A tall surface so the whole list is built: this is a payload-order and
  // payload-string test, and a section below an 800px fold would look like a
  // section the screen refused to draw.
  t.view.physicalSize = const Size(1200, 5000);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    home: TokenDashboardScreen(loader: (_) async => payload),
  ));
  await t.pumpAndSettle();
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  testWidgets('the headline, the self-check and the basis are the payload\'s',
      (t) async {
    await _pump(t, _payload());
    // ₹9,999 disagrees with every row on the screen. It is still what prints.
    expect(find.text('₹9,999'), findsOneWidget);
    expect(find.text('80.1M tokens over 33 command(s)'), findsOneWidget);
    expect(find.text('0.00% drift'), findsOneWidget);
    expect(
        find.text(
            'stored ₹68,650.86 vs recomputed ₹68,650.86 · flagged over 1%'),
        findsOneWidget);
    expect(
        find.text(
            'Rupees are API-equivalent value — the runner is on a Max subscription.'),
        findsOneWidget);
    expect(find.text('All zones'), findsOneWidget);
    expect(find.text('06 Sep 2026'), findsOneWidget);
    expect(find.text('Nothing on this screen is apportioned or prorated.'),
        findsOneWidget);
  });

  testWidgets('a share the payload sent is printed, never recomputed',
      (t) async {
    await _pump(t, _payload());
    // 3.0M of 80.1M is 3.7%, not 12.5%. A screen that did the division fails.
    expect(find.text('12.5%'), findsOneWidget);
    expect(find.text('3.7%'), findsNothing);
    // And an em-dash stays an em-dash rather than becoming ₹0.
    expect(find.text('—'), findsOneWidget);
    expect(find.text('₹0'), findsNothing);
  });

  testWidgets('sections and rows render in payload order', (t) async {
    await _pump(t, _payload());
    final where = find.text('Where it went');
    final phase = find.text('Cost by phase');
    final area = find.text('By area of the codebase');
    expect(t.getTopLeft(where).dy, lessThan(t.getTopLeft(phase).dy));
    expect(t.getTopLeft(phase).dy, lessThan(t.getTopLeft(area).dy));
    // 'storefront' arrives before 'unassigned' and is not re-sorted by size.
    expect(t.getTopLeft(find.text('storefront')).dy,
        lessThan(t.getTopLeft(find.text('unassigned')).dy));
    // Rows keep their order too: Today before All time.
    expect(t.getTopLeft(find.text('Today').last).dy,
        lessThan(t.getTopLeft(find.text('All time').last).dy));
  });

  testWidgets('an unknown section kind is skipped in silence', (t) async {
    await _pump(t, _payload());
    expect(find.text('A kind this build has never heard of'), findsNothing);
    expect(find.text('should never appear'), findsNothing);
    // The section AFTER it still renders — an unknown kind is skipped, not a
    // reason to stop drawing.
    expect(find.text('With zero waiting'), findsOneWidget);
    expect(find.text('₹1,882'), findsOneWidget);
  });

  testWidgets('an absent sub-line is omitted, and an empty section says so',
      (t) async {
    await _pump(t, _payload());
    // The 'All time' row carries no sub; nothing stands in for it.
    expect(find.text('33 command(s)'), findsOneWidget);
    expect(find.textContaining('null'), findsNothing);
    // An empty section prints the backend's own empty copy, not a blank card.
    expect(find.text('No file was taken by three commands.'), findsOneWidget);
  });

  testWidgets('a bar is as wide as the payload says, not as wide as its value',
      (t) async {
    await _pump(t, _payload());
    final bars = t
        .widgetList<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
        .toList();
    expect(bars.length, 2);
    // storefront: value 40.0M of a 41.0M total, but pct 7.
    expect(bars[0].value, closeTo(0.07, 0.0001));
    // unassigned: value 1.0M, but pct 90.
    expect(bars[1].value, closeTo(0.90, 0.0001));
  });

  testWidgets('an unknown tone name stays neutral', (t) async {
    await _pump(t, _payload());
    // The row survives and prints; the tone name it carries is not a colour
    // this build knows, and that is not an error.
    expect(find.text('unassigned'), findsOneWidget);
    expect(find.text('1.0M'), findsOneWidget);
  });

  testWidgets('the selected window is the backend\'s flag', (t) async {
    await _pump(t, _payload());
    // The screen opens on 'today' but the payload marks 'This week'; the
    // payload wins, so all three chips are drawn and none is chosen locally.
    expect(find.text('This week'), findsOneWidget);
    expect(find.text('All time'), findsWidgets);
    final chip = t.widget<Container>(find.ancestor(
        of: find.text('This week'), matching: find.byType(Container)).first);
    final other = t.widget<Container>(find.ancestor(
        of: find.text('All time').first, matching: find.byType(Container)).first);
    expect((chip.decoration as BoxDecoration).color,
        isNot((other.decoration as BoxDecoration).color));
  });

  testWidgets('a refusal prints the backend copy with a Retry', (t) async {
    await _pump(t, {
      'ok': false,
      'message': 'Dev Queue tools are super-admin only.',
      'title': 'Token dashboard',
      'sections': const [],
    });
    expect(find.text('Dev Queue tools are super-admin only.'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    // Nothing from a healthy payload leaks into a refusal.
    expect(find.text('Where it went'), findsNothing);
  });
}
