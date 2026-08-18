// CHANGE #222 — the gate that guards the gate.
//
// #222 folded testing INTO the build: scripts/deploy.sh now refuses to build
// unless scripts/selftest.sh (protected suite + focused test) is green.
//
// CHANGE #273 moved the third phase, rg_check(), OFF the build path. It is a
// heavy read against production, and firing it from the pre-build gate is how a
// 13,573 ms guard query landed on top of the per-minute cron burst at 10:01:24
// UTC on 2026-08-18, 33 seconds before Postgres went silent for two hours. It
// now runs once, after the live alias is confirmed, from
// scripts/rg_after_deploy.sh. The guard itself is NOT weakened: dev_cmd_complete()
// still raises on a red rg_check, so no command completes with a schema
// regression outstanding. This file pins BOTH halves — the build gate stays,
// and the guard keeps running after every deploy. That fix is only worth anything if it cannot be quietly undone — a
// future edit that drops the gate line from deploy.sh would restore exactly the
// old failure mode (ship red, fail QA, pay for a "Debug pass — verify & fix #N"
// twin) and nothing would notice.
//
// So the gate is pinned here, in the suite that runs before every deploy. Delete
// the gate and this test goes red, which stops the deploy that removed it.
//
// This file reads the shipped scripts as text on purpose. It asserts the
// CONTRACT (the gate exists, runs before the build, has no escape hatch), not
// the wording of any log line, so ordinary edits to those scripts stay free.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Strips shell comments so a rule is never "satisfied" by a line that merely
/// mentions it in prose. Only executable shell counts as enforcement.
String _code(String source) => source
    .split('\n')
    .map((line) {
      final trimmed = line.trimLeft();
      if (trimmed.startsWith('#')) return '';
      return line;
    })
    .join('\n');

void main() {
  final repoRoot = Directory.current.path;
  final deployFile = File('$repoRoot/scripts/deploy.sh');
  final selftestFile = File('$repoRoot/scripts/selftest.sh');

  group('the fold-in self-test gate is wired into the build', () {
    test('both scripts exist and are executable shell', () {
      expect(deployFile.existsSync(), isTrue,
          reason: 'scripts/deploy.sh is THE deploy path and must exist');
      expect(selftestFile.existsSync(), isTrue,
          reason: 'scripts/selftest.sh is the fold-in test gate (CHANGE #222); '
              'without it deploy.sh runs no tests at all');
    });

    test('deploy.sh calls the gate, and calls it BEFORE building', () {
      final code = _code(deployFile.readAsStringSync());

      final gateIndex = code.indexOf('scripts/selftest.sh');
      expect(gateIndex, greaterThan(-1),
          reason: 'deploy.sh must invoke scripts/selftest.sh. Removing this '
              'call restores the pre-#222 hole: deploys with a red suite.');

      // The gate is worthless after the fact — a bundle built from red code has
      // already cost the build. It must gate `flutter build`.
      final buildIndex = code.indexOf('flutter build web');
      expect(buildIndex, greaterThan(-1),
          reason: 'deploy.sh should still build the web bundle');
      expect(gateIndex, lessThan(buildIndex),
          reason: 'the self-test must run BEFORE `flutter build web`, so red '
              'tests mean no bundle is ever produced');
    });

    test('a red gate aborts the deploy instead of warning', () {
      final code = _code(deployFile.readAsStringSync());

      // Under `set -e` the status must be captured, or the abort branch is dead
      // code that never prints. Both halves of the contract are asserted.
      expect(code.contains('|| SELFTEST_STATUS=\$?'), isTrue,
          reason: 'deploy.sh runs under set -e; the gate exit code must be '
              'captured with `|| SELFTEST_STATUS=\$?`');
      expect(RegExp(r'SELFTEST_STATUS"?\s*-ne\s*0').hasMatch(code), isTrue,
          reason: 'deploy.sh must branch on a non-zero gate status');
      expect(RegExp(r'-ne 0[\s\S]{0,900}exit 1').hasMatch(code), isTrue,
          reason: 'a red gate must `exit 1`, not merely print a warning');
    });

    test('the gate has no skip flag — an opt-out is not a gate', () {
      final code = _code(deployFile.readAsStringSync());
      final gateLine = code
          .split('\n')
          .firstWhere((l) => l.contains('scripts/selftest.sh'), orElse: () => '');

      for (final escape in const [
        'SELFTEST_SKIP',
        'SKIP_TESTS',
        'NO_TESTS',
        '--skip',
      ]) {
        expect(code.contains(escape), isFalse,
            reason: 'deploy.sh must not offer "$escape": an escape hatch is how '
                'a gate quietly stops being a gate');
      }
      expect(gateLine.contains('|| true'), isFalse,
          reason: 'the gate call must never be swallowed with `|| true`');
    });
  });

  group('selftest.sh gates the build on tests', () {
    test('it runs the protected suite and the change\'s own focused test', () {
      final code = _code(selftestFile.readAsStringSync());

      expect(code.contains('flutter test test/protected/'), isTrue,
          reason: 'phase 1 is the protected regression suite');
      expect(code.contains('_test.dart'), isTrue,
          reason: 'phase 2 must discover the change\'s own focused test(s)');
    });

    test('it exits non-zero when a phase is red', () {
      final code = _code(selftestFile.readAsStringSync());
      expect(RegExp(r'exit 1').hasMatch(code), isTrue,
          reason: 'a red phase must exit non-zero, or deploy.sh cannot gate');
      expect(code.contains('exit 0'), isTrue,
          reason: 'an all-green run must exit 0 so the deploy proceeds');
    });

    test('it caps in-session retries instead of looping forever', () {
      final code = _code(selftestFile.readAsStringSync());
      expect(code.contains('ATTEMPT_CAP'), isTrue,
          reason: 'CHANGE #222 caps in-session fix attempts (default 3)');
      expect(code.contains('qa_report'), isTrue,
          reason: 'on hitting the cap the gate files qa_report(failed) and '
              'stops — it must never silently deploy or spin');
      expect(RegExp(r'exit 2').hasMatch(code), isTrue,
          reason: 'the cap path exits 2 so deploy.sh can report it distinctly');
    });
  });

  group('rg_check runs AFTER the deploy, never on the build path (#273)', () {
    final rgFile = File('$repoRoot/scripts/rg_after_deploy.sh');

    test('the post-deploy guard script exists', () {
      expect(rgFile.existsSync(), isTrue,
          reason: 'scripts/rg_after_deploy.sh is where rg_check() lives since '
              '#273. Without it the guard stops running at all — which is a '
              'bigger regression than the latency it was moved to avoid.');
    });

    test('deploy.sh does not ask the pre-build gate to run rg_check', () {
      final code = _code(deployFile.readAsStringSync());
      final gateLine = code
          .split('\n')
          .firstWhere((l) => l.contains('scripts/selftest.sh'), orElse: () => '');

      expect(gateLine.contains('--rg'), isFalse,
          reason: 'the pre-build gate must not run rg_check: a heavy read '
              'against production has no business standing between a green '
              'suite and a bundle (see the 2026-08-18 10:01 UTC outage)');
      expect(gateLine.contains('--no-rg'), isTrue,
          reason: 'deploy.sh must pass --no-rg explicitly, so a future change '
              'to selftest.sh defaults cannot silently put it back');
    });

    test('deploy.sh runs the guard after the upload, and it cannot abort it', () {
      final code = _code(deployFile.readAsStringSync());

      final rgIndex = code.indexOf('scripts/rg_after_deploy.sh');
      expect(rgIndex, greaterThan(-1),
          reason: 'deploy.sh must still run rg_check somewhere — after the '
              'deploy, not before the build');

      final uploadIndex = code.indexOf('wrangler pages deploy');
      expect(uploadIndex, greaterThan(-1),
          reason: 'deploy.sh should still upload the bundle');
      expect(rgIndex, greaterThan(uploadIndex),
          reason: 'the guard must run AFTER the upload — that is the whole '
              'point of #273');

      final rgLine = code
          .split('\n')
          .firstWhere((l) => l.contains('scripts/rg_after_deploy.sh'),
              orElse: () => '');
      expect(rgLine.contains('|| true'), isTrue,
          reason: 'a red guard must not fail a deploy that is already live; '
              'dev_cmd_complete() is what refuses to complete on red');
    });

    test('the guard script itself never exits non-zero', () {
      final code = _code(rgFile.readAsStringSync());
      expect(code.contains('rgcheck') || code.contains('rg_check'), isTrue,
          reason: 'rg_after_deploy.sh must actually call the guard');
      expect(RegExp(r'^\s*exit [1-9]', multiLine: true).hasMatch(code), isFalse,
          reason: 'by the time this runs the bundle is live — exiting non-zero '
              'would make a healthy deploy look broken');
    });
  });
}
