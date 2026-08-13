// CHANGE #66 — the design-literal scanner, shared by the ratchet baseline tool
// (tool/design_baseline.dart) and the protected gate
// (test/protected/design_literal_gate_test.dart).
//
// A "design literal" is a hardcoded colour / size / radius / shadow / padding
// written in a SCREEN instead of coming from the `Ds` token layer. DESIGN.md
// bans them; this scanner counts them per file so the gate can (a) block any
// NEW literal and (b) ratchet the total DOWN as screens are migrated.
//
// Rule: a line OFFENDS if it matches a banned pattern AND does not reference
// `Ds.` — because a line already sourcing its value from a token is compliant
// by construction (`EdgeInsets.all(Ds.space.x16)` is fine; `EdgeInsets.all(16)`
// is not). Comments are stripped first.
//
// Pure Dart — no Flutter, no network — so it runs both as a CLI and inside a
// `flutter test`.

import 'dart:io';

/// Files that DEFINE the tokens and therefore may hold raw literals. Nothing
/// else is exempt.
const Set<String> kLiteralAllowlist = <String>{
  'lib/design_tokens.dart',
  'lib/theme.dart',
};

final List<RegExp> _bannedPatterns = <RegExp>[
  RegExp(r'Color\(0x'), // hardcoded ARGB colour
  RegExp(r'fontSize:\s*[0-9]'), // hardcoded text size
  RegExp(r'BoxShadow\('), // hardcoded shadow (use Ds.elevation)
  RegExp(r'BorderRadius\.circular\(\s*[0-9]'), // numeric radius
  RegExp(r'EdgeInsets\.(all|symmetric|only|fromLTRB)\([^)]*[0-9]'), // numeric padding
];

String stripComments(String src) {
  src = src.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
  final out = StringBuffer();
  for (final line in src.split('\n')) {
    final i = line.indexOf('//');
    out.writeln(i >= 0 ? line.substring(0, i) : line);
  }
  return out.toString();
}

/// Number of offending lines in one file's source.
int countLiterals(String src) {
  final code = stripComments(src);
  var n = 0;
  for (final line in code.split('\n')) {
    if (line.contains('Ds.')) continue; // token-sourced line is compliant
    for (final p in _bannedPatterns) {
      if (p.hasMatch(line)) {
        n++;
        break; // one offence per line
      }
    }
  }
  return n;
}

/// Scan lib/ and return {relativePath: offendingLineCount} for every .dart file
/// that has at least one offence and is not allowlisted.
Map<String, int> scanLib([String root = 'lib']) {
  final dir = Directory(root);
  final result = <String, int>{};
  if (!dir.existsSync()) return result;
  for (final e in dir.listSync(recursive: true)) {
    if (e is! File || !e.path.endsWith('.dart')) continue;
    final path = e.path.replaceAll('\\', '/');
    if (kLiteralAllowlist.contains(path)) continue;
    final n = countLiterals(e.readAsStringSync());
    if (n > 0) result[path] = n;
  }
  return result;
}
