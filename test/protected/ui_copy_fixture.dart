// Seeds [UiCopy] with a real snapshot of the backend `ui_copy_all()` payload so
// that swept widgets — which now render `c('key')` instead of a Dart literal —
// paint their actual strings under test. Without this, `c()` returns '' and any
// `find.text('…')` on swept copy fails.
//
// The snapshot lives in ui_copy_fixture.json (committed alongside). Regenerate
// after adding/renaming ui_copy rows:
//
//   curl -s -X POST \
//     'https://swojhmarmaijkshsbeih.supabase.co/rest/v1/rpc/ui_copy_all' \
//     -H "apikey: $ANON" -H "Authorization: Bearer $ANON" \
//     -H 'Content-Type: application/json' -d '{}' \
//     -o test/protected/ui_copy_fixture.json
//
// Protected tests run on the Dart VM, so reading the file with dart:io is fine.
import 'dart:convert';
import 'dart:io';

import 'package:pharma_b2b/services/ui_copy.dart';

/// Loads the committed copy snapshot and injects it into [UiCopy]. Call from a
/// test's setUp (or the top of main) before pumping any swept widget.
void seedUiCopy() {
  final file = File('test/protected/ui_copy_fixture.json');
  final decoded = jsonDecode(file.readAsStringSync()) as Map;
  UiCopy.debugSet(decoded.map(
    (k, v) => MapEntry(k as String, v == null ? '' : v.toString()),
  ));
}
