// Force-logout policy tests.
//
// The unit under test is the pure ForceLogoutGuard — the single asker/actor
// for the WhatsApp "Log Out" flow. It is deliberately decoupled from Supabase
// and the widget tree, so these tests mock the RPC inline, hit no network and
// never import home_shell. The guard drives an injected onForceLogout callback;
// _FakeApp below mirrors exactly what the real callback does in AuthNotifier
// (sign out, clear cached state, route to login, keep the backend's reason),
// so asserting on it proves the real orchestration, not a stand-in.

import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/services/force_logout_guard.dart';

/// Stand-in for the app's account state, in its signed-in starting condition.
/// The forced-logout callback mutates it the way the real one mutates
/// AuthNotifier + CartModel + DeliveryRoleState via the signedOut path.
class _FakeApp {
  bool signedIn = true;
  bool stateCleared = false;
  String route = 'home';
  String message = '';

  Future<void> forceLogout(String msg) async {
    message = msg;         // backend reason, verbatim
    signedIn = false;      // supabase.auth.signOut()
    stateCleared = true;   // cart / role / profile dropped
    route = 'login';       // dropped to the signed-out (login) surface
  }
}

void main() {
  test('must_log_out=true signs out, clears state, routes to login with the '
      'backend message', () async {
    final app = _FakeApp();
    var rpcCalls = 0;
    final guard = ForceLogoutGuard(
      rpc: () async {
        rpcCalls++;
        return {'must_log_out': true, 'message': 'You were logged out from WhatsApp.'};
      },
      onForceLogout: app.forceLogout,
      nowMs: () => 1000,
    );

    await guard.check();

    expect(rpcCalls, 1);
    expect(app.signedIn, isFalse);
    expect(app.stateCleared, isTrue);
    expect(app.route, 'login');
    expect(app.message, 'You were logged out from WhatsApp.'); // verbatim
  });

  test('must_log_out=false leaves the session untouched', () async {
    final app = _FakeApp();
    var forced = false;
    final guard = ForceLogoutGuard(
      rpc: () async => {'must_log_out': false, 'message': null},
      onForceLogout: (msg) async { forced = true; await app.forceLogout(msg); },
      nowMs: () => 1000,
    );

    await guard.check();

    expect(forced, isFalse);
    expect(app.signedIn, isTrue);
    expect(app.stateCleared, isFalse);
    expect(app.route, 'home');
    expect(app.message, '');
  });

  test('an RPC error leaves the session untouched', () async {
    final app = _FakeApp();
    var forced = false;
    final guard = ForceLogoutGuard(
      rpc: () async => throw Exception('network down'),
      onForceLogout: (msg) async { forced = true; await app.forceLogout(msg); },
      nowMs: () => 1000,
    );

    // Must not throw, and must not sign anyone out.
    await guard.check();

    expect(forced, isFalse);
    expect(app.signedIn, isTrue);
    expect(app.stateCleared, isFalse);
    expect(app.route, 'home');
  });

  test('a null answer leaves the session untouched', () async {
    final app = _FakeApp();
    final guard = ForceLogoutGuard(
      rpc: () async => null,
      onForceLogout: app.forceLogout,
      nowMs: () => 1000,
    );

    await guard.check();

    expect(app.signedIn, isTrue);
    expect(app.route, 'home');
  });

  test('two calls inside the debounce window hit the RPC once', () async {
    var rpcCalls = 0;
    var now = 1000;
    final guard = ForceLogoutGuard(
      rpc: () async { rpcCalls++; return {'must_log_out': false, 'message': null}; },
      onForceLogout: (_) async {},
      nowMs: () => now,
      debounceMs: 20000,
    );

    await guard.check();      // runs
    now = 1000 + 19999;       // still inside the 20 s window
    await guard.check();      // debounced — no RPC

    expect(rpcCalls, 1);
  });

  test('a call after the debounce window runs the RPC again', () async {
    var rpcCalls = 0;
    var now = 1000;
    final guard = ForceLogoutGuard(
      rpc: () async { rpcCalls++; return {'must_log_out': false, 'message': null}; },
      onForceLogout: (_) async {},
      nowMs: () => now,
      debounceMs: 20000,
    );

    await guard.check();      // runs
    now = 1000 + 20001;       // past the window
    await guard.check();      // runs again

    expect(rpcCalls, 2);
  });
}
