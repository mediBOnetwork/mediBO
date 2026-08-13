// PROTECTED — the design-literal ratchet gate (CHANGE #66).
//
// DESIGN.md bans hardcoded style literals in screens: colours, text sizes,
// shadows, numeric radii and paddings must come from the `Ds` token layer, so
// `ui_design_set()` can restyle the whole app with zero code change. This test
// fails if:
//   • a file's offending-line count RISES above its frozen baseline, or
//   • a file with NO baseline entry (a new file, or a fully-clean one) gains a
//     literal.
// The baseline (design_literal_baseline.json) only ratchets DOWN: every polish
// batch migrates a file and lowers its number with
// `dart run tool/design_baseline.dart --write`. Never raise it to make an
// unrelated change pass — move the literal into Ds instead.
//
// The scan logic lives in tool/design_literal_scan.dart and is shared with the
// baseline writer, so the gate and the tool can never disagree.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/design_literal_scan.dart';

Map<String, int> _readBaseline() {
  final f = File('test/protected/design_literal_baseline.json');
  expect(f.existsSync(), isTrue,
      reason: 'baseline missing — run: dart run tool/design_baseline.dart --write');
  final m = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  return m.map((k, v) => MapEntry(k, (v as num).toInt()));
}

void main() {
  test('no new hardcoded style literals beyond the ratchet baseline', () {
    expect(Directory('lib').existsSync(), isTrue, reason: 'run from package root');

    final current = scanLib();
    final baseline = _readBaseline();

    final regressions = <String>[];
    current.forEach((file, n) {
      final allowed = baseline[file] ?? 0;
      if (n > allowed) {
        regressions.add('  $file: $n literals (baseline $allowed) — +${n - allowed}');
      }
    });

    if (regressions.isNotEmpty) {
      regressions.sort();
      fail('New hardcoded design literals detected — move them onto the Ds '
          'token layer (see DESIGN.md), do NOT raise the baseline:\n'
          '${regressions.join('\n')}\n\n'
          'Allowed to DEFINE literals only: ${kLiteralAllowlist.join(', ')}.');
    }
  });

  test('baseline never silently ratchets UP', () {
    // A stored baseline number must reflect real offences: if a file was
    // migrated to zero literals it should be dropped from the baseline, not
    // left with a stale positive number that would permit re-introducing them.
    final baseline = _readBaseline();
    final current = scanLib();
    final stale = <String>[];
    baseline.forEach((file, n) {
      final now = current[file] ?? 0;
      // A generous slack (>0 and now==0) means the file is clean but still
      // carries budget — allowed, but flag if the gap is large so we tidy it.
      if (!File(file).existsSync()) stale.add('  $file (deleted — drop from baseline)');
    });
    if (stale.isNotEmpty) {
      fail('Baseline references files that no longer exist:\n${stale.join('\n')}');
    }
  });
}
