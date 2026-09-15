// Native app updates arrive through Play (or a new APK), not a web page
// reload — both are no-ops off the web.
void reloadPage() {}

/// CMD #2028 — the web-only "clear caches and reload". Nothing to clear and
/// nothing to reload on Android/iOS.
void hardReloadPage() {}
