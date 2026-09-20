// CMD #2112 — the registration bar's ONE answer, and the controller that
// holds it.
//
// It is deliberately the same shape as [AppUpdateFeed] + [UpdateBarController]:
// the two bars share ONE slot in the bottom stack, they are the same pill, and
// only one of them is ever on screen. Making them two different shapes is how
// the orange block on Home and the update pill ended up disagreeing about
// where an ask belongs.
//
// `customer_registration_bar()` decides EVERYTHING: whether there is a bar at
// all, the sentence on it, the button's word, which address Continue opens and
// whether it should land on the documents. Nothing is compared, formatted or
// worded here.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Payload keys, named once for the widget, the service and the tests.
class RegistrationBarFeed {
  const RegistrationBarFeed._();

  static const String kShow = 'show';

  /// CMD #2114 — WHICH bar this answer is: 'login' for a signed-out visitor,
  /// 'registration' for a shop that still owes its papers. The app never
  /// infers it from the route — one slot, and the backend names what is in it.
  static const String kKind = 'kind';

  static const String kTitle = 'title';
  static const String kCta = 'cta';
  static const String kRoute = 'route';
  static const String kAnchor = 'anchor';
  static const String kReason = 'reason';
  static const String kPollSeconds = 'poll_seconds';

  /// Test seam — the same shape every screen in this app uses.
  @visibleForTesting
  static Future<dynamic> Function(String fn, Map<String, dynamic>? params)?
      rpcTransport;

  /// Ask the backend. Null on ANY failure: a registration check that cannot be
  /// reached must never put a bar on the screen, and must never throw into a
  /// build.
  static Future<Map<String, dynamic>?> fetch() async {
    try {
      final t = rpcTransport;
      final res = t != null
          ? await t('customer_registration_bar', null)
          : await Supabase.instance.client.rpc('customer_registration_bar');
      if (res is Map) return Map<String, dynamic>.from(res);
      return null;
    } catch (_) {
      return null;
    }
  }

  /// The backend's own cadence, never faster than 60 s so a bad config cannot
  /// turn the app into a polling loop.
  static Duration pollInterval(
      Map<String, dynamic>? payload, Duration fallback) {
    final n = (payload?[kPollSeconds] as num?)?.toInt();
    if (n == null || n < 60) return fallback;
    return Duration(seconds: n);
  }
}

/// The one piece of state the registration bar needs, held outside the widget
/// tree so a sign-in, a submit or a poll can raise and lower it from anywhere
/// without a BuildContext.
///
/// There is no dismissal, here or on the update bar (CMD #2112): the bar is up
/// while something is owed and it goes down when the backend says nothing is.
class RegistrationBarController extends ChangeNotifier {
  bool _visible = false;
  Map<String, dynamic> _payload = const {};

  bool get visible => _visible;

  Map<String, dynamic> get payload => _payload;

  String _s(String key) {
    final v = _payload[key];
    return (v is String) ? v : '';
  }

  /// The one line of copy in the middle of the bar.
  String get label => _s(RegistrationBarFeed.kTitle);

  /// The word on the green button.
  String get actionLabel => _s(RegistrationBarFeed.kCta);

  /// CMD #2114 — which of the two asks this is, straight out of the payload.
  /// Empty when there is no bar.
  String get kind => _s(RegistrationBarFeed.kKind);

  /// Where Continue goes, and which section it lands on. Both the backend's.
  String get route => _s(RegistrationBarFeed.kRoute);
  String get anchor => _s(RegistrationBarFeed.kAnchor);

  /// Adopt an answer. `show:false`, a null payload and a payload with no
  /// sentence in it all take the bar down — a pill with no words is not a bar.
  void adopt(Map<String, dynamic>? payload) {
    final show = payload != null &&
        payload[RegistrationBarFeed.kShow] == true &&
        (payload[RegistrationBarFeed.kTitle] as String?)?.isNotEmpty == true;
    final changed = show != _visible || (payload ?? const {}) != _payload;
    _payload = show ? payload : const {};
    _visible = show;
    if (changed) notifyListeners();
  }

  /// Ask the backend and adopt whatever came back. Safe to call from anywhere:
  /// it never throws and never shows a bar on a failure.
  Future<void> refresh() async => adopt(await RegistrationBarFeed.fetch());

  /// Test seam — the controller is a long-lived singleton in production.
  @visibleForTesting
  void reset() {
    _visible = false;
    _payload = const {};
    notifyListeners();
  }
}

/// The ONE controller the bottom stack renders.
final RegistrationBarController appRegistrationBar = RegistrationBarController();

/// Keeps [appRegistrationBar] in step with the account, from outside the
/// widget tree.
///
/// It is a driver, not a decision: it asks `customer_registration_bar()` when
/// something could have changed (auth resolved, the form was submitted, the
/// backend's own poll came round) and adopts whatever came back. A signed-out
/// session is asked too (CMD #2114) — it is the one that gets the login bar.
class RegistrationBarDriver {
  RegistrationBarDriver._();
  static final RegistrationBarDriver instance = RegistrationBarDriver._();

  Timer? _timer;
  bool _started = false;

  /// The cadence used until the backend has told us its own.
  static const Duration _fallback = Duration(minutes: 5);

  /// Called once auth has resolved, and again on every change of account.
  ///
  /// CMD #2114 — SIGNED OUT IS ALSO AN ANSWER. This used to take the bar down
  /// without asking, on the reasoning that there is no account to owe
  /// anything; that reasoning is what left a first-time visitor with no way of
  /// knowing there was anything to log in to. The backend is asked either way
  /// and decides which bar — login, registration, or none at all.
  ///
  /// [signedIn] is still carried because it is a REASON TO RE-ASK, not a
  /// decision: an account changing hands must not leave the previous
  /// account's sentence on screen for one poll interval.
  Future<void> onAuth({required bool signedIn}) async {
    await refresh();
    _arm();
  }

  /// Ask again now — after a submit, or when the form closes.
  Future<void> refresh() async {
    await appRegistrationBar.refresh();
    _started = true;
  }

  void _arm() {
    _timer?.cancel();
    _timer = Timer(
      RegistrationBarFeed.pollInterval(appRegistrationBar.payload, _fallback),
      () async {
        await refresh();
        _arm();
      },
    );
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _started = false;
  }

  /// True once a real answer has been adopted at least once. The bottom stack
  /// never waits on this — an unanswered bar is simply not shown.
  bool get started => _started;
}
