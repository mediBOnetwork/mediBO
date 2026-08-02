// CHANGE #635 — web implementation of the DOM/localStorage surface RenderLog
// needs. This is the ONLY file in lib/ (besides main.dart) that imports
// dart:html, and it is reached solely through the conditional import in
// render_log.dart.
//
// The bodies below are the original render_log.dart code, moved verbatim — the
// web build's behaviour is unchanged.
library;

// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

List<String> localStorageKeys() => html.window.localStorage.keys.toList();

String? localStorageGet(String key) => html.window.localStorage[key];

void localStorageSet(String key, String value) {
  html.window.localStorage[key] = value;
}

void setElementText(String elementId, String text) {
  html.document.getElementById(elementId)?.text = text;
}
