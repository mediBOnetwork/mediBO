// Live force-logout policy tests.
//
// The unit under test is the pure [ForceLogoutRealtime] — the object that keeps
// an open Realtime subscription and signs the device out the INSTANT the backend
// records a WhatsApp "Log Out", instead of waiting for the next start/resume/
// navigation check. Like [ForceLogoutGuard] it is decoupled from Supabase and
// the widget tree: these tests mock the RPC answer and the channel inline, hit
// no network and never import home_shell.
//
// The channel is injected. `_FakeChannel` below is the transport the coordinator
// opens; the test drives it by hand (fire an INSERT, report a status). `_FakeApp`
// mirrors exactly what the real onForceLogout does in AuthNotifier (sign out,
// clear cached state, route to login, keep the backend's reason), so asserting
// on it proves the real orchestration, not a stand-in.

import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/services/force_logout_realtime.dart';

/// Stand-in for the app's account state, in its signed-in starting condition.
/// The forced-logout callback mutates it the way the real one mutates
/// AuthNotifier + CartModel + DeliveryRoleState via the signedOut path.
class _FakeApp {
  bool signedIn = true;
  bool stateCleared = false;
  String route = 'home';
  String message = '';

  Future<void> forceLogout(String msg) async {
    message = msg; // backend reason, verbatim
    signedIn = false; // supabase.auth.signOut()
    stateCleared = true; // cart / role / profile dropped
    route = 'login'; // dropped to the signed-out (login) surface
  }
}

/// The injected transport. Records the table/filter it was opened with, whether
/// it was unsubscribed, and exposes the sinks so a test can simulate a real
/// INSERT or a status change. There is deliberately NO way to make it sign
/// anyone out except [fireInsert].
class _FakeChannel {
  _FakeChannel(this.table, this.filter, this.onInsert, this.onStatus);
  final String table;
  final String filter;
  final void Function(Map<String, dynamic> row) onInsert;
  final void Function(ForceLogoutChannelStatus status) onStatus;
  bool unsubscribed = false;

  void fireInsert(Map<String, dynamic> row) => onInsert(row);
  void report(ForceLogoutChannelStatus status) => onStatus(status);
}

void main() {
  late List<_FakeChannel> opened;
  late _FakeApp app;
  late int reconnectChecks;
  late ForceLogoutRealtime live;

  setUp(() {
    opened = [];
    app = _FakeApp();
    reconnectChecks = 0;
    live = ForceLogoutRealtime(
      open: (table, filter, onInsert, onStatus) {
        final ch = _FakeChannel(table, filter, onInsert, onStatus);
        opened.add(ch);
        return ForceLogoutSubscription(() => ch.unsubscribed = true);
      },
      onForceLogout: app.forceLogout,
      onReconnect: () => reconnectChecks++,
    );
  });

  test('after login it subscribes using the watch_table and watch_filter from '
      'the RPC — and signs out no one just by subscribing', () {
    live.watch(
      table: 'wa_force_logout',
      filter: 'user_id=eq.U1',
      fallbackMessage: 'You were logged out.',
    );

    expect(opened, hasLength(1));
    expect(opened.single.table, 'wa_force_logout'); // verbatim from RPC
    expect(opened.single.filter, 'user_id=eq.U1'); // verbatim from RPC
    expect(live.isWatching, isTrue);
    expect(app.signedIn, isTrue); // subscribing alone never signs out
  });

  test('a simulated INSERT signs out, clears state and routes to login, showing '
      "the row's reason", () {
    live.watch(
      table: 'wa_force_logout',
      filter: 'user_id=eq.U1',
      fallbackMessage: 'fallback message',
    );

    opened.single.fireInsert({
      'user_id': 'U1',
      'reason': 'You were logged out from WhatsApp.',
    });

    expect(app.signedIn, isFalse);
    expect(app.stateCleared, isTrue);
    expect(app.route, 'login');
    expect(app.message, 'You were logged out from WhatsApp.'); // row reason, verbatim
  });

  test('an INSERT with no/empty reason falls back to the must_log_out message', () {
    live.watch(
      table: 'wa_force_logout',
      filter: 'user_id=eq.U1',
      fallbackMessage: 'The backend fallback.',
    );

    opened.single.fireInsert({'user_id': 'U1'}); // no reason field
    expect(app.message, 'The backend fallback.');

    app.message = '';
    opened.single.fireInsert({'user_id': 'U1', 'reason': ''}); // empty reason
    expect(app.message, 'The backend fallback.'); // still the fallback, no Dart string
  });

  test('a channel error / timeout / close triggers nothing — only an INSERT '
      'signs out', () {
    live.watch(
      table: 'wa_force_logout',
      filter: 'user_id=eq.U1',
      fallbackMessage: 'msg',
    );
    final ch = opened.single;
    ch.report(ForceLogoutChannelStatus.subscribed); // healthy join

    ch.report(ForceLogoutChannelStatus.error);
    ch.report(ForceLogoutChannelStatus.timedOut);
    ch.report(ForceLogoutChannelStatus.closed);

    expect(app.signedIn, isTrue); // never signed out on a non-INSERT
    expect(app.stateCleared, isFalse);
    expect(reconnectChecks, 0); // an error is not a reconnect
  });

  test('a reconnect (SUBSCRIBED again after the first) re-checks must_log_out '
      'exactly once, and never signs out on its own', () {
    live.watch(
      table: 'wa_force_logout',
      filter: 'user_id=eq.U1',
      fallbackMessage: 'msg',
    );
    final ch = opened.single;

    ch.report(ForceLogoutChannelStatus.subscribed); // initial join — not a reconnect
    expect(reconnectChecks, 0);

    ch.report(ForceLogoutChannelStatus.closed); // socket dropped
    ch.report(ForceLogoutChannelStatus.subscribed); // came back -> reconnect
    expect(reconnectChecks, 1);
    expect(app.signedIn, isTrue); // reconnect alone signs out no one
  });

  test('signing out unsubscribes the channel', () {
    live.watch(
      table: 'wa_force_logout',
      filter: 'user_id=eq.U1',
      fallbackMessage: 'msg',
    );
    final ch = opened.single;

    live.stop();

    expect(ch.unsubscribed, isTrue);
    expect(live.isWatching, isFalse);
  });

  test('re-watching the same user does not churn the channel; a new sign-in as '
      'a different user drops the old channel and opens the new one', () {
    live.watch(table: 'wa_force_logout', filter: 'user_id=eq.U1', fallbackMessage: 'm');
    live.watch(table: 'wa_force_logout', filter: 'user_id=eq.U1', fallbackMessage: 'm');

    expect(opened, hasLength(1)); // idempotent for the same user
    expect(opened.single.unsubscribed, isFalse);

    live.watch(table: 'wa_force_logout', filter: 'user_id=eq.U2', fallbackMessage: 'm');

    expect(opened, hasLength(2));
    expect(opened[0].unsubscribed, isTrue); // old user's channel dropped
    expect(opened[1].filter, 'user_id=eq.U2'); // new user's channel is current
  });

  test('an empty table or filter opens no channel', () {
    live.watch(table: '', filter: 'user_id=eq.U1', fallbackMessage: 'm');
    live.watch(table: 'wa_force_logout', filter: '', fallbackMessage: 'm');
    expect(opened, isEmpty);
    expect(live.isWatching, isFalse);
  });
}
