// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:html' as html;

import 'page_reload.dart';

/// CMD #2065 — the PWA half of the one update bar.
///
/// An installed PWA does not reload when a deploy lands: the shell it booted
/// is the shell it keeps until its service worker is replaced. The browser
/// installs the new worker and parks it in `waiting` — that parked worker IS
/// the update, and it is the only thing on this platform that can truthfully
/// say one exists. version.json cannot: a PWA can be serving a cached document
/// whose worker has not changed at all.
///
/// Every call is guarded and answers rather than throws. A browser with no
/// service-worker support, a private window, or blocked site data all answer
/// 'unknown', which the backend reads as "not an update".
Future<String> waitingWorkerState() async {
  try {
    final sw = html.window.navigator.serviceWorker;
    if (sw == null) return 'unknown';
    final dynamic reg = await sw.getRegistration();
    if (reg == null) return 'none';
    // Ask the browser to look NOW rather than waiting out its own ~24 h
    // background check — otherwise the bar is honest but arrives tomorrow.
    try {
      await reg.update();
    } catch (_) {}
    final waiting = reg.waiting;
    if (waiting != null) return 'waiting';
    return 'none';
  } catch (_) {
    return 'unknown';
  }
}

/// True when this tab is the installed app rather than a browser tab.
/// `display-mode: standalone` covers Android/desktop installs; `standalone`
/// on the navigator is the iOS home-screen case.
Future<bool> isStandalonePwa() async {
  try {
    final m = html.window.matchMedia('(display-mode: standalone)');
    if (m.matches == true) return true;
  } catch (_) {}
  try {
    final nav = html.window.navigator as dynamic;
    if (nav.standalone == true) return true;
  } catch (_) {}
  return false;
}

/// Update Now, on a PWA: tell the waiting worker to take over, then reload.
///
/// index.html already reloads once on `controllerchange`, which is what
/// skipWaiting triggers; the timer is the belt to that braces — a worker that
/// refuses to activate must not leave the customer on a spinning button.
Future<void> applyWaitingWorker() async {
  try {
    final sw = html.window.navigator.serviceWorker;
    final dynamic reg = await sw?.getRegistration();
    final waiting = reg?.waiting;
    if (waiting != null) {
      try {
        waiting.postMessage({'type': 'SKIP_WAITING'});
      } catch (_) {}
      Timer(const Duration(seconds: 3), hardReloadPage);
      return;
    }
  } catch (_) {}
  hardReloadPage();
}
