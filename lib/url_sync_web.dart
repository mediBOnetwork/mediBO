// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

// Captures the real initial pathname BEFORE usePathUrlStrategy() resets it.
// Call captureInitialPath() at the very start of main(), before usePathUrlStrategy().
String? _capturedInitialPath;

/// CHANGE #747 — the QUERY STRING of the page that was opened, kept for the
/// whole session and never consumed.
///
/// The path was already captured here because usePathUrlStrategy() rewrites
/// the browser URL during boot; the search half is erased by exactly the same
/// rewrite, and nothing had noticed because until now no screen restored state
/// from it. A catalogue deep link (/catalogue?tab=cold_chain&lk=tab&k=cold_chain)
/// therefore reached the screen as an empty string and opened the default view
/// — the link was a link to nowhere.
///
/// Unlike [currentPath] this is NOT consume-once: HomeShell reads the search
/// during its own initState (the OAuth `code=` check) long before the shell
/// builds its pages, so a one-shot value would be spent before the screen that
/// needs it exists.
String _capturedInitialSearch = '';

void captureInitialPath() {
  _capturedInitialPath = html.window.location.pathname;
  _capturedInitialSearch = html.window.location.search ?? '';
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

/// The query string the app was OPENED with, surviving boot's URL rewrite.
/// Empty when the live URL already carries it (a same-session navigation).
String initialSearch() {
  final live = html.window.location.search ?? '';
  return live.isNotEmpty ? live : _capturedInitialSearch;
}
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
