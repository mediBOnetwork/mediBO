// PROTECTED — CHANGE #349.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes icon-resolution behaviour, never to make an unrelated
// change go green.
//
// The defect this exists to retire: after #325 most dashboard tiles rendered
// as an empty pale square. `navIcon()` was a switch with a `default:` arm, so
// it could never answer "does this key resolve?" — it always returned
// something, and a registry row naming a key nobody had implemented drew a
// meaningless generic glyph on a tinted box. There was no gate anywhere that
// could see it.
//
// What this holds down:
//
//   1. RESOLUTION IS ASKABLE. `navIconResolves` is the question the switch
//      could not answer, and `kNavIcons` is the map it asks.
//
//   2. THE TWO CATALOGUES CANNOT DRIFT. Every key in `ui_icon` (seeded by
//      20260831190000_c349_icon_catalogue_and_dev_tools.sql) must exist in
//      `kNavIcons`, and vice versa. The SQL side is guarded by the
//      `nav_icons_resolve` regression-guard behaviour; this is the Dart side
//      of the same contract, and it reads the migration rather than a copy so
//      it cannot go stale.
//
//   3. NOTHING EVER RENDERS BLANK. A key that resolves draws its icon; a key
//      that does not draws the row's own initial — never an empty box. The
//      letter is the BACKEND's `icon_letter` when it sent one.
//
//   4. THE GLYPH IS CENTRED, NOT SQUEEZED. The box is laid out with an
//      explicit alignment so the glyph is measured loose inside it.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/nav_registry_view.dart';
import 'package:pharma_b2b/utils/render_log.dart';

/// The icon_key list the migration seeds into `ui_icon`, read from the
/// migration itself. If someone adds a key to Postgres and forgets Dart (the
/// exact shape of the #349 defect), this test goes red on the next deploy.
Set<String> _catalogueFromMigration() {
  final file = File(
      'supabase/migrations/20260831190000_c349_icon_catalogue_and_dev_tools.sql');
  expect(file.existsSync(), isTrue,
      reason: 'the ui_icon catalogue migration must stay in the repo');
  final sql = file.readAsStringSync();
  final start = sql.indexOf('insert into public.ui_icon');
  final end = sql.indexOf('on conflict (icon_key)', start);
  expect(start >= 0 && end > start, isTrue,
      reason: 'the ui_icon seed block must stay recognisable');
  final block = sql.substring(start, end);
  return RegExp(r"\('([a-z0-9_]+)',")
      .allMatches(block)
      .map((m) => m.group(1)!)
      .toSet();
}

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: Center(child: child)));

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  test('every catalogued icon_key resolves to a real glyph, and no more', () {
    final catalogue = _catalogueFromMigration();
    expect(catalogue.length, greaterThan(40),
        reason: 'the seed block should have been parsed, not missed');

    final missingInDart = catalogue.difference(kNavIcons.keys.toSet());
    expect(missingInDart, isEmpty,
        reason: 'ui_icon names these keys but kNavIcons cannot draw them — '
            'a registry row using one would render as a blank square');

    final missingInSql = kNavIcons.keys.toSet().difference(catalogue);
    expect(missingInSql, isEmpty,
        reason: 'kNavIcons can draw these but ui_icon does not offer them — '
            'nav_icon_audit() would never know they are legal');

    for (final key in catalogue) {
      expect(navIconResolves(key), isTrue, reason: '$key must resolve');
    }
  });

  test('an unknown or empty key does NOT resolve', () {
    expect(navIconResolves('no_such_icon_key'), isFalse);
    expect(navIconResolves(''), isFalse);
    expect(navIconResolves(null), isFalse);
  });

  testWidgets('a resolvable key draws its icon', (t) async {
    await t.pumpWidget(_host(const NavGlyph(
      row: <String, dynamic>{
        'icon_key': 'handshake',
        'label': 'Partner settlement',
        'icon_letter': 'P',
      },
      box: 32,
      glyph: 20,
    )));
    expect(find.byIcon(kNavIcons['handshake']!), findsOneWidget);
    // the fallback must NOT also be painted
    expect(find.text('P'), findsNothing);
  });

  testWidgets('an unresolvable key draws the backend letter, never a blank',
      (t) async {
    await t.pumpWidget(_host(const NavGlyph(
      row: <String, dynamic>{
        'icon_key': 'brand_new_key_this_build_never_heard_of',
        'label': 'Profit & loss',
        'icon_letter': 'P',
      },
      box: 32,
      glyph: 20,
    )));
    expect(find.text('P'), findsOneWidget);
    expect(find.byType(Icon), findsNothing);
  });

  testWidgets('a missing icon_letter falls back to the row label initial',
      (t) async {
    await t.pumpWidget(_host(const NavGlyph(
      row: <String, dynamic>{'icon_key': 'nope', 'label': 'cron health'},
      box: 32,
      glyph: 20,
    )));
    expect(find.text('C'), findsOneWidget);
  });

  testWidgets('the glyph box is explicitly centred', (t) async {
    await t.pumpWidget(_host(const NavGlyph(
      row: <String, dynamic>{'icon_key': 'terminal', 'label': 'Dev Queue'},
      box: 32,
      glyph: 20,
    )));
    final box = t.widget<Container>(find.descendant(
        of: find.byType(NavGlyph), matching: find.byType(Container)));
    expect(box.alignment, Alignment.center,
        reason: 'without it the glyph is measured against the box tight '
            'constraints instead of being laid out loose and centred');
  });

  test('the fallback letter is deterministic and upper-case', () {
    expect(navIconLetter(const {'label': 'scope audit'}), 'S');
    expect(navIconLetter(const {'label': 'scope audit'}),
        navIconLetter(const {'label': 'scope audit'}));
    expect(navIconLetter(const {'icon_letter': 'x', 'label': 'Anything'}), 'X');
    expect(navIconLetter(const {}), '?');
  });
}
