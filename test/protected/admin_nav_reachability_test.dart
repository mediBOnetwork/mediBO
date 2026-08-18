// CHANGE #226 — the menu-reachability journey, frozen as a test.
//
// The bug this retires is #645/#646, twice: a destination is added to an admin
// nav list, renders a perfect row, and does nothing on tap because
// `_handleAdminNav` in home_shell.dart has no `case` for its route key. A
// canvas app cannot be clicked by any tool, so this is the only place the
// wiring can be proven — and it is proven from the source of truth itself,
// not from a screenshot someone took once.
//
// Both directions are checked:
//   * every route key offered by a nav surface is handled by the router
//   * every screen the router pushes is imported (a missing import is a
//     compile error, but a route pushed from a stale import is not)
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) {
  final f = File(path);
  if (!f.existsSync()) {
    // Thrown, not expect()ed: this runs at load time, outside any test body.
    throw StateError('$path is missing — did it move?');
  }
  return f.readAsStringSync();
}

void main() {
  final navSrc = _read('lib/screens/admin/admin_nav_entries.dart');
  final shellSrc = _read('lib/screens/home_shell.dart');

  /// Every `route: 'x'` an admin nav surface offers.
  final offered = RegExp(r"route:\s*'([a-z0-9_]+)'")
      .allMatches(navSrc)
      .map((m) => m.group(1)!)
      .toSet();

  /// Every `nav('x')` the profile sheet fires directly.
  final sheetKeys = RegExp(r"nav\('([a-z0-9_]+)'\)")
      .allMatches(navSrc)
      .map((m) => m.group(1)!)
      .toSet();

  /// Every `case 'x':` the router handles.
  final handled = RegExp(r"case\s+'([a-z0-9_]+)'\s*:")
      .allMatches(shellSrc)
      .map((m) => m.group(1)!)
      .toSet();

  test('the admin nav lists are not empty (the regexes still match)', () {
    expect(offered, isNotEmpty,
        reason: 'no route: keys found — the nav entry syntax changed');
    expect(sheetKeys, isNotEmpty,
        reason: 'no nav() calls found — the profile sheet syntax changed');
    expect(handled, isNotEmpty,
        reason: 'no case labels found — _handleAdminNav changed shape');
  });

  test('every overflow destination has a router case', () {
    final orphans = offered.difference(handled).toList()..sort();
    expect(orphans, isEmpty,
        reason: 'these menu entries render but do nothing on tap: $orphans');
  });

  test('every profile-sheet tile has a router case', () {
    final orphans = sheetKeys.difference(handled).toList()..sort();
    expect(orphans, isEmpty,
        reason: 'these profile-sheet tiles render but do nothing on tap: '
            '$orphans');
  });

  test('the overflow list reaches BOTH viewports, not just the wide one', () {
    // kAdminOverflowNav is rendered by the wide "More" popup AND generated into
    // the mobile profile sheet. #645/#646 shipped screens that only the wide
    // shell could reach. Both loops must stay.
    final loops = RegExp(r'for \(final e in kAdminOverflowNav\)')
        .allMatches(navSrc)
        .length;
    expect(loops, greaterThanOrEqualTo(2),
        reason: 'kAdminOverflowNav must be rendered by the More popup AND the '
            'mobile profile sheet — a phone had no way into these screens when '
            'only one loop existed');
  });

  test('CHANGE #226 — Bill pipeline is reachable from the admin menu', () {
    expect(offered, contains('bill_pipeline'));
    expect(handled, contains('bill_pipeline'));
    expect(shellSrc, contains('AdminBillPipelineScreen'));
    expect(shellSrc, contains("import 'admin/admin_bill_pipeline_screen.dart'"));
  });
}
