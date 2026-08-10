// PROTECTED — the copy sweep guard.
//
// THE APP RENDERS. IT NEVER DECIDES. Every user-visible string moved into the
// `ui_copy` / `legal_pages` tables and now arrives through `ui_copy_all()` /
// `legal_get_page()`. This test holds the denylist of the distinctive phrases
// that were removed and fails if any of them reappears as a Dart string literal
// anywhere under lib/ — so a future edit cannot quietly reintroduce hardcoded
// copy. Reword a string with an UPDATE to the backend, never a literal here.
//
// The denylist lives in no_hardcoded_copy_denylist.g.dart (generated). If a
// phrase legitimately stops being user-visible copy, remove it from the
// denylist in the SAME change — never weaken this scan to make an edit pass.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'no_hardcoded_copy_denylist.g.dart';

/// Files that may legitimately contain a denylisted phrase for a reason that
/// is NOT user-visible rendering (e.g. a generated data table). Keep empty.
const Set<String> _allow = <String>{};

String _stripComments(String src) {
  // Remove /* ... */ block comments then // ... line comments. Good enough to
  // stop a phrase quoted inside a comment from tripping the scan.
  src = src.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
  final out = StringBuffer();
  for (final line in src.split('\n')) {
    final i = line.indexOf('//');
    out.writeln(i >= 0 ? line.substring(0, i) : line);
  }
  return out.toString();
}

void main() {
  test('no swept phrase reappears as a hardcoded literal under lib/', () {
    final libDir = Directory('lib');
    expect(libDir.existsSync(), isTrue, reason: 'run from the package root');

    // phrase -> list of "file:line" where it was found as a literal.
    final offenders = <String, List<String>>{};
    final deny = kHardcodedCopyDenylist;

    for (final entity in libDir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (_allow.contains(entity.path)) continue;
      final code = _stripComments(entity.readAsStringSync());
      if (!code.contains("'") && !code.contains('"')) continue;
      final lines = code.split('\n');
      for (final phrase in deny) {
        if (!code.contains(phrase)) continue;
        for (var n = 0; n < lines.length; n++) {
          final line = lines[n];
          if (line.contains(phrase) &&
              (line.contains("'$phrase") ||
                  line.contains('"$phrase') ||
                  // phrase may be the tail of an adjacent-string concat
                  line.trimLeft().startsWith("'") ||
                  line.trimLeft().startsWith('"'))) {
            (offenders[phrase] ??= <String>[]).add('${entity.path}:${n + 1}');
          }
        }
      }
    }

    if (offenders.isNotEmpty) {
      final report = (offenders.entries.toList()
            ..sort((a, b) => a.key.compareTo(b.key)))
          .map((e) => '  "${e.key}"\n      ${e.value.join('\n      ')}')
          .join('\n');
      fail('Hardcoded user-visible copy reintroduced under lib/. Move each to '
          'the ui_copy table and render c(\'key\'):\n$report');
    }
  });
}
