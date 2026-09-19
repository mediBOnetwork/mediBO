// CMD #2100 — THE BACKEND PICKS THE ROLE HOME.
//
// Two Android flavors share this codebase (customer / partner) and the web
// serves every role. After sign-in the root asks `app_home()` ONCE per signed-in
// user; the RPC reads the flavor header and the session's role and answers
// `{home, blocked, block}`. The only thing this class does with the answer is
// hold it: `block` non-null means the backend wants its "Use the mediBO app"
// screen painted (a customer account on the partner app) — its title, body,
// button label and store link all arrive in that payload. Every other answer
// renders HomeShell exactly as before this command.
//
// Nothing here branches on the flavor or the role. A failed call is NOT a
// block: the shell renders and the next sign-in asks again.
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/render_log.dart';

typedef AppHomeRpc = Future<dynamic> Function();

class AppHomeState extends ChangeNotifier {
  AppHomeState._();

  static final AppHomeState instance = AppHomeState._();

  /// Test seam. Null in production -> the real RPC.
  static AppHomeRpc? rpcOverride;

  Map<String, dynamic> _payload = const {};
  String _askedFor = '';
  bool _inFlight = false;

  /// The last app_home() payload, verbatim. Empty until the first answer.
  Map<String, dynamic> get payload => _payload;

  /// The backend's block screen, or null when it wants the normal shell.
  Map<String, dynamic>? get block {
    if (_payload['blocked'] != true) return null;
    final b = _payload['block'];
    return b is Map ? Map<String, dynamic>.from(b) : null;
  }

  String get home => (_payload['home'] as String?) ?? '';

  /// Called from the root's build: asks once per signed-in user, clears on
  /// sign-out. Idempotent — a rebuild never re-asks.
  void sync({required bool signedIn}) {
    if (!signedIn) {
      if (_askedFor.isNotEmpty || _payload.isNotEmpty) reset();
      return;
    }
    String uid = '';
    try {
      uid = Supabase.instance.client.auth.currentUser?.id ?? '';
    } catch (_) {}
    if (uid.isEmpty || uid == _askedFor || _inFlight) return;
    _askedFor = uid;
    _fetch();
  }

  Future<void> _fetch() async {
    _inFlight = true;
    try {
      final raw = rpcOverride != null
          ? await rpcOverride!()
          : await Supabase.instance.client.rpc('app_home');
      if (raw is Map) {
        _payload = Map<String, dynamic>.from(raw);
        try {
          RenderLog.write('c2100_app_home', home);
        } catch (_) {}
        notifyListeners();
      }
    } catch (_) {
      // Not a block. The shell renders; the next sign-in asks again.
      _askedFor = '';
    } finally {
      _inFlight = false;
    }
  }

  /// Test seam: the fetch the root triggers once a uid is known, without a
  /// Supabase client. Same once-per-user rule — a second call for the same
  /// (test) user asks nothing.
  @visibleForTesting
  Future<void> fetchForTest({String uid = 'test-user'}) async {
    if (uid == _askedFor || _inFlight) return;
    _askedFor = uid;
    await _fetch();
  }

  /// Sign-out (or a test) forgets the answer so the next account is asked.
  void reset() {
    _askedFor = '';
    _inFlight = false;
    if (_payload.isNotEmpty) {
      _payload = const {};
      notifyListeners();
    }
  }
}
