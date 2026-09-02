// PROTECTED — CHANGE #686 (round 4).
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes what may live in the copy snapshot.
//
// WHY THIS FILE EXISTS. #686 cleaned `ui_copy` and then guarded it — a CHECK
// constraint, a trigger and an rg behaviour, all reading `public.ui_copy`.
// Hostile QA pointed out the structural hole in that: the guard watches ONE
// copy of the data and the repo ships ANOTHER. `ui_copy_fixture.json` is a
// committed snapshot of `ui_copy_all()` that eight protected tests seed their
// widgets from, and it still carried 24 rows the new rules reject — including
// `admin_customer.ordered_by` reading
// `Ordered by: {name}${row.pharmacy.isNotEmpty ? ` — the exact string Om
// photographed and this change exists to delete. Nothing looked at it, so a
// future sweep could have re-imported the fixture and reintroduced the bug
// with every guard still green.
//
// So the same rules the database enforces are enforced here, on the file. The
// snapshot is regenerated from ui_copy_all() (see ui_copy_fixture.dart); this
// test is what makes a polluted regeneration fail before it can be deployed.
//
// The rules are deliberately a PORT, not an import: the database cannot be
// reached from a protected test (no network, ~2s on the Dart VM). If they ever
// drift apart, the SQL is authoritative — `ui_copy_is_source_code`,
// `ui_copy_brace_is_source` and `ui_copy_bare_expression` in
// supabase/migrations/20260902230000_c686_round3_uicopy.sql.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Shapes that are never a sentence a human wrote. Mirrors the validated CHECK
/// constraint `ui_copy_no_dart_source`.
final _dartSource = <String, RegExp>{
  'Dart interpolation': RegExp(r'\$\{'),
  'a bare \$identifier': RegExp(r'\$[A-Za-z_]'),
  'a literal \\u{...} escape': RegExp(r'\\u\{'),
  'a Dart method call': RegExp(
      r'(\.toString\(|\.toStringAsFixed\(|\.isNotEmpty|\.isEmpty|\.length\b'
      r'|\.map\(|\.where\(|\.join\(|\.split\(|\.trim\(|\.substring\('
      r'|\.toLowerCase\(|\.toUpperCase\(|\.replaceAll\(|\.replaceFirst\('
      r'|\.contains\(|\.startsWith\(|\.endsWith\()'),
  'a null-aware operator': RegExp(r'(!=\s*null|==\s*null|\?\?)'),
  "a fragment's own tail": RegExp(r'^\s*[\]})]'),
};

/// A brace is legal only as `{slot}` or the backend's own `{{slot}}`. Consume
/// exactly those two shapes; anything left over is source. Mirrors
/// `ui_copy_brace_is_source` — note it CONSUMES rather than strips, which is
/// what stopped `{{ b[0] ; return x }}` and `{ if (x) {ok} }`.
bool _braceIsSource(String v) => v
    .replaceAll(RegExp(r'\{\{[A-Za-z0-9_]+\}\}'), '')
    .replaceAll(RegExp(r'\{[A-Za-z0-9_]+\}'), '')
    .contains(RegExp(r'[{}]'));

/// A value that is nothing but dotted identifiers — `items.first.name`. Mirrors
/// `ui_copy_bare_expression`, trailing whitespace included (round 3 missed a
/// value that differed only by a trailing space).
bool _bareExpression(String v) =>
    RegExp(r'^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)+$')
        .hasMatch(v.trim());

void main() {
  late Map<String, String> copy;

  setUpAll(() {
    final raw = File('test/protected/ui_copy_fixture.json').readAsStringSync();
    copy = (jsonDecode(raw) as Map).map(
      (k, v) => MapEntry(k as String, v == null ? '' : v.toString()),
    );
  });

  test('the committed copy snapshot is not empty', () {
    // A truncated or unreadable snapshot would make every rule below pass
    // vacuously, which is the one way this file could lie.
    expect(copy.length, greaterThan(2000));
  });

  test('no snapshot value is Dart source', () {
    final bad = <String>[];
    copy.forEach((key, value) {
      if (value.isEmpty) return;
      _dartSource.forEach((why, re) {
        if (re.hasMatch(value)) bad.add('$key ($why) = $value');
      });
    });
    expect(bad, isEmpty,
        reason: 'Regenerate the snapshot from a CLEAN ui_copy — see '
            'ui_copy_fixture.dart. Rows:\n${bad.join('\n')}');
  });

  test('no snapshot value carries a brace that is not a {slot}', () {
    // The four Gemini prompts that legitimately carry JSON are backend-only and
    // are not in this snapshot; if one is ever added, exempt it HERE the way
    // ui_copy_source_exempt does in SQL — visibly, with a reason.
    final bad = <String>[];
    copy.forEach((key, value) {
      if (value.isNotEmpty && _braceIsSource(value)) bad.add('$key = $value');
    });
    expect(bad, isEmpty, reason: bad.join('\n'));
  });

  test('no snapshot value is a bare dotted expression', () {
    final bad = <String>[];
    copy.forEach((key, value) {
      if (value.isNotEmpty && _bareExpression(value)) bad.add('$key = $value');
    });
    expect(bad, isEmpty, reason: bad.join('\n'));
  });

  test('the header Om reported is a sentence in the snapshot too', () {
    // The specific row that started this. It is asserted by VALUE, so a
    // regeneration that silently reintroduces the fragment fails here and not
    // on someone's screenshot.
    expect(copy['admin_customer.ordered_by'], 'Ordered by: {name}');
    expect(copy['admin_customer.ordered_by_with_pharmacy'],
        'Ordered by: {name} · {pharmacy}');
  });

  test('the rules themselves still catch what they are for', () {
    // A port that silently stopped matching would pass every test above.
    const om = r'Ordered by: ${row.pharmacy.isNotEmpty ?';
    expect(_dartSource.values.any((re) => re.hasMatch(om)), isTrue);
    expect(_braceIsSource('{{ b[0] ; return x }}'), isTrue);
    expect(_braceIsSource('{ if (x) {ok} }'), isTrue);
    expect(_braceIsSource('Ordered by: {name} · {pharmacy}'), isFalse);
    expect(_braceIsSource('Heartbeat FAILED at {{stage}}'), isFalse);
    expect(_bareExpression('items.first.name '), isTrue);
    expect(_bareExpression('Ordered by: {name}'), isFalse);
    expect(_dartSource['a bare \$identifier']!.hasMatch(r'UPI ID: $vpa'), isTrue);
    expect(_dartSource['a bare \$identifier']!.hasMatch(r'Save $5 today'), isFalse);
  });
}
