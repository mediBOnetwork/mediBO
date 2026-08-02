// CHANGE #635 — non-web implementation of the tiny DOM/localStorage surface
// RenderLog needs.
//
// render_log.dart imported dart:html directly, which made EVERY library that
// touched it unloadable on the Dart VM. That is why test/fw_get_state_date_scope_test.dart
// (which only wanted the pure functions in fulfill/fulfill_view_logic.dart) had
// been failing to compile: fulfill_view_logic → render_log → dart:html.
//
// Splitting the four DOM calls behind a conditional import leaves the WEB build
// byte-identical (dart.library.html resolves to render_log_dom.dart, which is
// the original code verbatim) while giving the VM a no-op so unit tests can
// import app libraries at all.
//
// This is also what the repo's DEFENSIVE IMPORT RULE asks for: dart:html now
// lives in exactly one leaf file that nothing but render_log.dart imports.
library;

List<String> localStorageKeys() => const <String>[];

String? localStorageGet(String key) => null;

void localStorageSet(String key, String value) {}

void setElementText(String elementId, String text) {}
