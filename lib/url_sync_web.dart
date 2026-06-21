// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

// Captures the real initial pathname BEFORE usePathUrlStrategy() resets it.
// Call captureInitialPath() at the very start of main(), before usePathUrlStrategy().
String? _capturedInitialPath;

void captureInitialPath() {
  _capturedInitialPath = html.window.location.pathname;
}

// Returns the captured initial path on first call, then falls through to live pathname.
// HomeShell._initFromUrl() calls this once during initState — it gets the real URL.
String currentPath() {
  final captured = _capturedInitialPath;
  if (captured != null) {
    _capturedInitialPath = null; // consume once so subsequent calls read live pathname
    return captured;
  }
  return html.window.location.pathname ?? '/';
}

String currentSearch() => html.window.location.search ?? '';
String currentHash() => html.window.location.hash;

void pushUrl(String path) => html.window.history.pushState(null, '', path);
void replaceUrl(String path) => html.window.history.replaceState(null, '', path);

void listenPopState(void Function(String path) handler) {
  html.window.onPopState.listen((_) {
    handler(html.window.location.pathname ?? '/');
  });
}
