// CHANGE #565 — the one focused test the spec asks for:
// tapping Continue with Google clears g_state and THEN calls prompt(), and no
// other Google mechanism is reachable from the flow.
//
// runGoogleSignIn is deliberately platform-free so this runs on the VM with the
// attempts injected — no browser, no JS interop, no Supabase.

import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/auth/google_flow.dart';

void main() {
  test('g_state is cleared BEFORE prompt(), and the raw nonce reaches Supabase',
      () async {
    final order = <String>[];
    String? sentToken;
    String? sentNonce;
    final logged = <String, String>{};

    final outcome = await runGoogleSignIn(
      clearGState: () {
        order.add('clear');
        return 'cleared';
      },
      oneTap: () async {
        order.add('prompt');
        return (idToken: 'jwt-abc', rawNonce: 'raw-123');
      },
      finish: (idToken, rawNonce) async {
        order.add('signInWithIdToken');
        sentToken = idToken;
        sentNonce = rawNonce;
      },
      log: (k, v) => logged[k] = v,
    );

    // The ordering is the whole point: the cooldown cookie must be gone before
    // GIS is asked to display the sheet.
    expect(order, ['clear', 'prompt', 'signInWithIdToken']);
    expect(outcome, GoogleOutcome.signedIn);
    expect(sentToken, 'jwt-abc');
    // Supabase must receive the RAW nonce, not the hashed one.
    expect(sentNonce, 'raw-123');
    expect(logged['c565_gstate'], 'cleared');
    expect(logged['c565_result'], 'credential');

    // There is no popup, no FedCM and no OAuth parameter in the signature at
    // all — those paths are unreachable by construction, not by convention.
  });

  test('g_state absent is reported as such, sheet still prompted', () async {
    final logged = <String, String>{};
    var prompted = false;

    await runGoogleSignIn(
      clearGState: () => 'absent',
      oneTap: () async {
        prompted = true;
        return (idToken: 'jwt', rawNonce: 'raw');
      },
      finish: (_, __) async {},
      log: (k, v) => logged[k] = v,
    );

    expect(prompted, isTrue);
    expect(logged['c565_gstate'], 'absent');
  });

  test('dismissal: stay put, no message, nothing else opened', () async {
    final logged = <String, String>{};

    final outcome = await runGoogleSignIn(
      clearGState: () => 'cleared',
      oneTap: () async => throw const GisOneTapCancelled(),
      finish: (_, __) async => fail('must not sign in after a dismissal'),
      log: (k, v) => logged[k] = v,
    );

    expect(outcome, GoogleOutcome.closed);
    expect(logged['c565_result'], 'none');
  });

  test('still suppressed after clearing g_state -> inline message only',
      () async {
    final logged = <String, String>{};

    final outcome = await runGoogleSignIn(
      clearGState: () => 'cleared',
      oneTap: () async => throw const GisOneTapSuppressed(),
      finish: (_, __) async => fail('nothing to finish'),
      log: (k, v) => logged[k] = v,
    );

    expect(outcome, GoogleOutcome.suppressed);
    expect(logged['c565_result'], 'none');
  });
}
