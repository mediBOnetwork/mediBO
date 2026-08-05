// Web implementation of the tiny browser surface main() needs at boot.
// Kept in one leaf file so main.dart holds no direct dart:html import and can
// compile for Android (where boot_env_stub.dart is used instead).
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

String locationHref() => html.window.location.href;

void historyReplaceRoot() => html.window.history.replaceState(null, '', '/');

void localStorageRemove(String key) => html.window.localStorage.remove(key);

Future<String> fetchText(String url) => html.HttpRequest.getString(url);
