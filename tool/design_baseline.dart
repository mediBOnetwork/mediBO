// CHANGE #66 — writes/updates the design-literal ratchet baseline.
//
//   dart run tool/design_baseline.dart           # print current counts
//   dart run tool/design_baseline.dart --write    # freeze the current counts
//
// The baseline (test/protected/design_literal_baseline.json) records, per file,
// the number of offending lines currently tolerated. The gate fails if any file
// exceeds its recorded number, or if a file with NO baseline entry gains a
// literal. Run `--write` ONLY to LOWER numbers after migrating a screen — never
// to raise them to make an unrelated change pass.

import 'dart:convert';
import 'dart:io';

import 'design_literal_scan.dart';

const String kBaselinePath = 'test/protected/design_literal_baseline.json';

void main(List<String> args) {
  final counts = scanLib();
  final sorted = Map.fromEntries(
    counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value)),
  );
  final total = counts.values.fold<int>(0, (a, b) => a + b);

  if (args.contains('--write')) {
    final existing = _readBaseline();
    // Ratchet guard: never raise an existing file's number via --write.
    final raised = <String>[];
    counts.forEach((f, n) {
      final prev = existing[f];
      if (prev != null && n > prev) raised.add('$f: $prev -> $n');
    });
    if (raised.isNotEmpty && !args.contains('--force')) {
      stderr.writeln('REFUSING to raise baseline (migrate the file instead):');
      for (final r in raised) {
        stderr.writeln('  $r');
      }
      exitCode = 2;
      return;
    }
    final ordered = Map.fromEntries(
      counts.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
    File(kBaselinePath).writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(ordered)}\n');
    stdout.writeln('Wrote $kBaselinePath — ${counts.length} files, $total lines.');
    return;
  }

  stdout.writeln('Design literals — $total offending lines across ${counts.length} files:');
  sorted.forEach((f, n) => stdout.writeln('  $n  $f'));
}

Map<String, int> _readBaseline() {
  final f = File(kBaselinePath);
  if (!f.existsSync()) return {};
  final m = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  return m.map((k, v) => MapEntry(k, (v as num).toInt()));
}
