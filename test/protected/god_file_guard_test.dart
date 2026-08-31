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

  test('home_shell.dart is still on the list until it is actually sharded', () {
    // #327 LAYER 1 deferred the home_shell shard to #340 because the file was
    // leased for the whole command. This test is the receipt: when #340 lands,
    // this expectation flips and whoever does it must come here and say so —
    // which is exactly the moment to check the shards are real.
    final shell = files.where((f) => f['path'] == 'lib/screens/home_shell.dart');
    expect(shell, hasLength(1),
        reason: 'home_shell.dart left the god-file list — if it was sharded, '
            'update this test to assert the shards instead');
    expect((shell.first['concerns'] as List).length, greaterThan(1),
        reason: 'it is the multi-concern case the whole layer exists for');
  });
}
