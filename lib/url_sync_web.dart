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

// Hard navigation that REPLACES the current history entry.
//
// Used by /r/<code> (WhatsApp tracking links). replace(), not assign(): the
// resolver page must not stay in the back stack, or Back from the destination
// lands on the resolver, which immediately redirects forward again — a loop the
// customer cannot escape without closing the tab.
//
// Also a full page load rather than a Navigator push, because the target is an
// arbitrary URL from the database and may well be off this origin.
void replaceLocation(String url) => html.window.location.replace(url);
