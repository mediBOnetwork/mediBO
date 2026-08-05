// Non-web boot surface. On Android there is no browser location, history,
// localStorage or /version.json fetch — main()'s callers already sit inside
// try/catch, so href is empty (no auth-callback URL to strip, no selftest),
// storage-remove is a no-op, and fetchText fails (caught → build hash 'unknown').
String locationHref() => '';

void historyReplaceRoot() {}

void localStorageRemove(String key) {}

Future<String> fetchText(String url) =>
    Future<String>.error(UnsupportedError('no browser fetch on this platform'));
