// CHANGE #327 · LAYER 1 guard — the god-file scanner, frozen as a test.
//
// The bug class: home_shell.dart grew to 5,139 lines holding boot, routing,
// nav, auth, the cart panel and the view-as previews at once. Two unrelated
// commands — a partner-routing fix (#326) and a dashboard rebuild (#325) —
// therefore collided on ONE file, and #325 parked mid-build holding a loaded
// context while it waited for the lease. Sharding removes a hot spot after the
// fact; this scanner is what stops the next one forming quietly.
//
// What is pinned here is the scanner's JUDGEMENT, not its output: the exact
// list of 52 files changes every time someone edits a screen, so asserting the
// list would be a test that fails for the wrong reason weekly. Instead this
// asserts the rules that decide membership, and — critically — that the guard
// is a REPORT and never a GATE. The repo's three biggest files are 13k–15k
// line admin screens; a gating guard would block every deploy tomorrow instead
// of paying the debt down deliberately.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Runs the scanner exactly the way scripts/god_files.sh does.
Map<String, dynamic> _scan() {
  final r = Process.runSync('dart', ['run', 'tool/god_files.dart', '--json']);
  if (r.exitCode != 0) {
    throw StateError('god_files.dart --json failed: ${r.stderr}');
  }
  // `dart run` prefixes build-hook chatter on stdout; the payload is the JSON
  // object, so start at its first brace rather than assuming a clean stream.
  final out = r.stdout as String;
  final start = out.indexOf('{');
  if (start < 0) throw StateError('no JSON in scanner output: $out');
  return jsonDecode(out.substring(start)) as Map<String, dynamic>;
}

void main() {
  final report = _scan();
  final files = (report['files'] as List)
      .map((e) => Map<String, dynamic>.from(e as Map))
      .toList();

  test('the scanner actually walked the tree', () {
    expect((report['scanned'] as num).toInt(), greaterThan(100),
        reason: 'it should see every Dart file under lib/, not a handful');
    expect(files, isNotEmpty,
        reason: 'this repo has known god-files; an empty report means the '
            'scanner stopped seeing them, not that the debt was paid');
  });

  test('every flagged file names WHY it was flagged', () {
    for (final f in files) {
      expect(f['path'], isNotEmpty);
      expect((f['reason'] ?? '').toString(), isNotEmpty,
          reason: '${f['path']} was flagged with no reason — an unexplained '
              'entry is noise nobody will act on');
      expect(f['oversize'] == true || f['multi_concern'] == true, isTrue,
          reason: '${f['path']} matched neither rule but was flagged anyway');
    }
  });

  test('the two rules are the ones the thresholds describe', () {
    for (final f in files) {
      final lines = (f['lines'] as num).toInt();
      final concerns = (f['concerns'] as List).length;
      if (f['oversize'] == true) {
        expect(lines, greaterThan(900),
            reason: '${f['path']} is oversize at $lines lines?');
      }
      if (f['multi_concern'] == true) {
        // The concern rule has a floor: small files with several concerns are
        // just normal widgets, and flagging them would drown the real debt.
        expect(lines, greaterThanOrEqualTo(400),
            reason: '${f['path']} is under the concern floor');
        expect(concerns, greaterThan(1),
            reason: '${f['path']} is multi_concern with $concerns concern(s)');
      }
    }
  });

  test('ordinary widgets stay off the list', () {
    // The scanner must stay quiet about most of the repo, or the list becomes
    // 344 files long and means nothing. Asserted as a RATIO and a rule rather
    // than a hardcoded filename list: the specific files churn every week, so
    // naming them would make this fail for the wrong reason. (An earlier draft
    // did name them, and nav_registry_view.dart — 444 lines, nav + a profile
    // menu — is flagged legitimately under the >400-line multi-concern rule.)
    final scanned = (report['scanned'] as num).toInt();
    expect(files.length, lessThan(scanned ~/ 3),
        reason: 'flagging ${files.length} of $scanned files is noise, not a '
            'debt register');

    // And nothing under the floor may be flagged for concerns alone.
    for (final f in files) {
      if (f['oversize'] == true) continue;
      expect((f['lines'] as num).toInt(), greaterThanOrEqualTo(400),
          reason: '${f['path']} is a small file flagged on concerns alone — '
              'that is the false positive the floor exists to prevent');
    }
  });

  test('the guard is a REPORT, never a deploy gate', () {
    // This is the assertion that matters most. The three biggest files here
    // are 13k–15k-line admin screens that predate the scanner; if any of this
    // ever becomes a gate, every deploy stops until they are sharded, and the
    // scanner gets deleted rather than the debt paid.
    final src = File('tool/god_files.dart').readAsStringSync();
    expect(src, isNot(contains('exitCode = 1')),
        reason: 'the scanner must not fail the build');
    expect(src, isNot(contains('exit(1)')),
        reason: 'the scanner must not fail the build');

    final sh = File('scripts/god_files.sh').readAsStringSync();
    expect(sh, isNot(contains('exit 1')),
        reason: 'the poster must not fail the build either');

    // And the rg side files it at warn, which is visible but never counted
    // into rg_check's critical total.
    expect(sh.contains('dev_god_files_report') || sh.contains('god_files'),
        isTrue,
        reason: 'the scan must be posted somewhere Om can read it');
  });

  test('CHANGE #340 — the shell stopped mixing concerns', () {
    // #327 wrote a tripwire here: "home_shell.dart left the god-file list — if
    // it was sharded, update this test to assert the shards instead". #340
    // sharded it and the tripwire fired; this is that update.
    //
    // The spec predicted the file would leave the list entirely at ~1,300
    // lines. It does not, and that prediction was simply arithmetic against
    // the wrong number: the oversize threshold is 900, so 1,396 is still over
    // it. Raising the threshold to make this green would be gaming the guard,
    // so the assertion is the thing that actually mattered instead.
    //
    // What the shard fixed is CONCERN COUNT, not size. 5,120 lines carrying
    // nine concerns (boot/routing, navigation, auth, cart, search, profile,
    // catalog, admin, orders) became 1,396 lines carrying ONE: boot/routing.
    // Nine concerns in one file is why a partner-routing command and a
    // dashboard command collided on it; one concern is why they no longer can.
    final shell = files.where((f) => f['path'] == 'lib/screens/home_shell.dart');
    if (shell.isNotEmpty) {
      final f = shell.first;
      expect((f['lines'] as num).toInt(), lessThan(2000),
          reason: 'the shell is growing back towards the 5,120 lines it was');
      expect(f['multi_concern'], isFalse,
          reason: 'the shell has started mixing concerns again — that is the '
              'property that made it a collision point, not its size');
      expect((f['concerns'] as List), equals(['boot/routing']),
          reason: 'the shell keeps exactly one job: boot and routing');
    }
  });

  test('CHANGE #340 — the eight shards exist, and none is oversize', () {
    // The failure mode of any shard is trading one 5k-line file for one 4k-line
    // file and seven stubs. Every part must be a bounded piece of work.
    const parts = [
      'shell_mobile_chrome', 'shell_cart_panel', 'shell_login_panel',
      'shell_bottom_bars', 'shell_header_chrome', 'shell_admin_chrome',
      'shell_sidebar', 'shell_view_as',
    ];
    final byPath = {for (final f in files) f['path'] as String: f};
    final shellSrc = File('lib/screens/home_shell.dart').readAsStringSync();

    for (final part in parts) {
      final path = 'lib/screens/shell/$part.dart';
      expect(File(path).existsSync(), isTrue, reason: '$path is missing');
      // Wired into the library, or its private widgets vanish from the shell.
      expect(shellSrc, contains("part 'shell/$part.dart';"),
          reason: '$part is not wired into home_shell.dart');
      // Three parts still carry more than one concern and are legitimately
      // flagged for it; none of them may be OVERSIZE, which would mean the
      // shard merely moved the bulk somewhere else.
      final f = byPath[path];
      if (f != null) {
        expect(f['oversize'], isFalse,
            reason: '$path is over 900 lines — the shard moved the debt '
                'instead of paying it');
      }
    }
  });
}
