// Native no-op counterpart to url_sync_web.captureInitialPath — main() calls
// this before usePathUrlStrategy(); there is no browser pathname to capture.
// (CMD #2157 exercised the incremental deploy path with this file.)
void captureInitialPath() {}
String currentPath() => '/';
String currentSearch() => '';
String initialSearch() => '';
String currentHash() => '';
void pushUrl(String path) {}
void replaceUrl(String path) {}
void listenPopState(void Function(String path) handler) {}
void replaceLocation(String url) {}
