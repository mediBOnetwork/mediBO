// PROTECTED — CHANGE #227. The date/zone scope contract, held down on the
// Flutter side.
//
// The backend half is guarded by the rg behaviour test `flow_scope_contract`
// (it fails if any RPC on `scope_contract` loses admin_active_date()/
// scope_date() or admin_active_zone()/scope_zone(), or if zone_effective()
// reappears on a contracted admin display RPC — that helper collapses the
// super-admin's "All zones" to the default zone, which is exactly how one zone
// of orders went missing).
//
// This file holds the half a migration cannot:
//   * the Scope Audit screen is reachable — a nav entry AND a router case;
//   * it renders the payload and computes nothing — no DateTime.now(), no
//     zone/date filtering in Dart, no hardcoded display strings;
//   * no screen in the flow re-implements the date or zone filter client-side,
//     which is how two screens drifted apart in the first place.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) {
  final f = File(path);
  if (!f.existsSync()) {
    throw StateError('$path is missing — did it move?');
  }
  return f.readAsStringSync();
}

/// Strips comments so a phrase quoted in a comment cannot trip a scan.
String _code(String src) {
  src = src.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
  final out = StringBuffer();
  for (final line in src.split('\n')) {
    final i = line.indexOf('//');
    out.writeln(i >= 0 ? line.substring(0, i) : line);
  }
  return out.toString();
}

void main() {
  final screen = _read('lib/screens/admin/admin_scope_audit_screen.dart');
  final screenCode = _code(screen);
  final nav = _read('lib/screens/admin/admin_nav_entries.dart');
  final shell = _read('lib/screens/home_shell.dart');

  group('the Scope Audit screen is reachable', () {
    test('an admin nav surface offers the route', () {
      expect(nav.contains("route: 'scope_audit'"), isTrue,
          reason: 'no nav entry offers scope_audit — the screen would exist '
              'but no admin could ever open it');
    });

    test('the router handles the route', () {
      expect(shell.contains("case 'scope_audit':"), isTrue,
          reason: '_handleAdminNav has no case for scope_audit — the row would '
              'render and do nothing on tap (the #645/#646 bug)');
    });

    test('the router actually pushes THIS screen', () {
      expect(shell.contains('AdminScopeAuditScreen()'), isTrue);
      expect(shell.contains("import 'admin/admin_scope_audit_screen.dart'"),
          isTrue,
          reason: 'the route pushes a screen that is not imported here');
    });
  });

  group('the screen renders the payload and decides nothing', () {
    test('it reads exactly one RPC', () {
      final rpcs = RegExp(r"\.rpc\(\s*'([a-z0-9_]+)'")
          .allMatches(screenCode)
          .map((m) => m.group(1)!)
          .toSet();
      expect(rpcs, <String>{'admin_scope_audit'},
          reason: 'the audit is ONE backend call; a second source of truth is '
              'the very drift this change removes');
    });

    test('it never invents a date or a zone', () {
      for (final banned in <String>[
        'DateTime.now(',
        'DateTime.parse(',
        'admin_active_date',
        'admin_set_date_scope',
        'admin_set_zone_scope',
        'zone_effective',
      ]) {
        expect(screenCode.contains(banned), isFalse,
            reason: '$banned in the screen — the date and zone scope are '
                'resolved in the BACKEND, never here');
      }
    });

    test('it does not filter or sort the backend rows', () {
      for (final banned in <String>['.sort(', '.where(', 'compareTo(']) {
        expect(screenCode.contains(banned), isFalse,
            reason: '$banned in the screen — stages and rows are rendered in '
                'payload order; ordering is the backends job');
      }
    });

    test('every status word comes from the payload, none from Dart', () {
      // The backend supplies status_label / date_label / zone_label /
      // banner_label. None of those words may be written here.
      for (final banned in <String>[
        "'Scoped'",
        "'Exempt'",
        "'Scope missing'",
        "'All zones'",
        "'Today'",
        "'Yesterday'",
      ]) {
        expect(screenCode.contains(banned), isFalse,
            reason: '$banned is a display string written in Dart — it belongs '
                'in ui_copy and must arrive in the payload');
      }
      for (final key in <String>[
        "row['status_label']",
        "row['date_label']",
        "row['zone_label']",
        "d?['banner_label']",
        "d?['scope_line']",
        "d?['rule_body']",
      ]) {
        expect(screen.contains(key), isTrue,
            reason: '$key is not rendered — a backend string the screen owes '
                'the admin is being dropped');
      }
    });

    test('tone strings map to design tokens, never to raw colours', () {
      expect(RegExp(r'Color\(0x').hasMatch(screenCode), isFalse,
          reason: 'a hardcoded colour literal — use Ds.c.* (DESIGN.md)');
      expect(screenCode.contains('fontSize:'), isFalse,
          reason: 'a raw font size — use Ds.t.* (DESIGN.md)');
      for (final tone in <String>['success', 'warning', 'danger', 'info']) {
        expect(screenCode.contains("case '$tone':"), isTrue,
            reason: 'tone "$tone" has no token mapping');
      }
    });

    test('it proves it painted, so a live deploy can be verified', () {
      expect(screen.contains("RenderLog.write('c227_scope_audit_screen'"),
          isTrue,
          reason: 'no render-log key — the deploy could not be proven');
      expect(screen.contains("RenderLog.write('c227_scope_audit_rows'"), isTrue);
    });
  });

  group('no flow screen re-implements the scope in Dart', () {
    // The scope is applied ONCE, in the backend RPC. A client-side date or zone
    // filter on top of a payload that is already scoped is how two screens
    // showing "the same day" started disagreeing.
    const flowScreens = <String>[
      'lib/screens/admin/admin_bill_pipeline_screen.dart',
      'lib/screens/admin/admin_scope_audit_screen.dart',
    ];

    test('they do not filter rows by zone_id or a date in Dart', () {
      for (final path in flowScreens) {
        final src = _code(_read(path));
        expect(RegExp(r"where\([^)]*zone_id").hasMatch(src), isFalse,
            reason: '$path filters by zone_id in Dart — the RPC already did');
        expect(RegExp(r"where\([^)]*the_date").hasMatch(src), isFalse,
            reason: '$path filters by date in Dart — the RPC already did');
      }
    });
  });
}
