// CMD #2114 — the app's ONE navigator key, in a leaf file on purpose.
//
// A logout must land the user on the mediBO public home, and a logout is
// raised from nine different places. Landing is one behaviour, so it belongs
// in one place — [AuthNotifier.signOut] — and that notifier has no
// BuildContext. It therefore needs the app's navigator.
//
// WHY THIS IS NOT IN main.dart: `main.dart` imports `dart:html`, and the
// DEFENSIVE IMPORT RULE forbids a file in the widget tree (user_state.dart is
// one) from reaching a web-only library, even transitively — that is the
// dart2js static-initialisation crash that white-screens the whole app. This
// file imports nothing but `flutter/widgets.dart`, so both sides can have it.
import 'package:flutter/widgets.dart';

/// The key MaterialApp is built with. Null until the app is mounted, which is
/// why every caller treats a missing navigator as "nothing to do" rather than
/// an error.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

/// Take the whole stack to [route], so nothing pushed over the shell survives.
///
/// [route] is the BACKEND'S (`my_session().logout_route`); an empty one falls
/// back to the app root, which is the role-aware shell and, with no account
/// behind it, the public storefront.
void landOnRoute(String route) {
  final nav = appNavigatorKey.currentState;
  if (nav == null) return;
  final target = route.trim().isEmpty ? '/' : route.trim();
  try {
    nav.pushNamedAndRemoveUntil(target, (r) => false);
  } catch (_) {
    // CMD #2116 — THE FALLBACK STILL HAS TO EMPTY THE STACK.
    //
    // Popping back to the first route was not a landing: the first route is
    // whatever the app happened to open on, which after a deep link is a
    // role-guarded screen the signed-out user cannot render — and on a stack
    // one route deep it did nothing at all, which is how a logout could end
    // with the previous account's page still on the glass.
    //
    // The app root is the one address that always exists (MaterialApp's own
    // `home:`) and it is role-aware, so with no account behind it, it IS the
    // public storefront.
    try {
      if (target != '/') {
        nav.pushNamedAndRemoveUntil('/', (r) => false);
        return;
      }
    } catch (_) {}
    if (nav.canPop()) nav.popUntil((r) => r.isFirst);
  }
}
