// CHANGE #571 — the app's one Navigator, reachable without a BuildContext.
//
// Logout is not a screen event: it starts in [AuthNotifier], which lives above
// the Navigator and has no context of its own. Without this key the only way to
// replace the stack after an auth change is to ask some widget to do it, and a
// widget that is already being torn down is exactly the thing that cannot be
// trusted to run. The key lets the session owner do the navigation itself.
//
// Deliberately platform-free (no dart:html, no Supabase) — DEFENSIVE IMPORT
// RULE: this file is imported by the widget tree.

import 'package:flutter/widgets.dart';

/// Attached to `MaterialApp.navigatorKey` in main.dart.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

/// Attached to `MaterialApp.navigatorObservers` in main.dart.
///
/// Its only job is to remember the name of the route currently on top, so a
/// second navigation to the route we are already showing can be skipped. Two
/// pushes of the same route would tear the shell down and rebuild it for
/// nothing, and both the login screen and the session owner can legitimately
/// want to land on the same `home_route` for the same sign-in.
final AppRouteTracker appRouteTracker = AppRouteTracker();

class AppRouteTracker extends NavigatorObserver {
  final List<String?> _stack = <String?>[];

  /// Name of the route on top, or null when it has no name (the `home:` route
  /// and anything built by `onUnknownRoute` are unnamed).
  String? get currentRouteName => _stack.isEmpty ? null : _stack.last;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.add(route.settings.name);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _remove(route);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _remove(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute != null) _remove(oldRoute);
    if (newRoute != null) _stack.add(newRoute.settings.name);
  }

  void _remove(Route<dynamic> route) {
    final i = _stack.lastIndexOf(route.settings.name);
    if (i >= 0) _stack.removeAt(i);
  }
}
