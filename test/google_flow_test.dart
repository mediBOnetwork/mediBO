// CHANGE #566 — the one focused test the spec asks for:
// on a skipped moment the popup path runs; g_state is cleared before prompt();
// and no OAuth / FedCM parameter exists in the flow at all.
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
      popup: () async => fail('popup must not run when One Tap succeeds'),
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
    expect(logged['c566_gstate'], 'cleared');
    expect(logged['c566_path'], 'onetap');

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
      popup: () async => fail('popup must not run when One Tap succeeds'),
      finish: (_, __) async {},
      log: (k, v) => logged[k] = v,
    );

    expect(prompted, isTrue);
    expect(logged['c566_gstate'], 'absent');
  });

  test('dismissal: stay put, no message, nothing else opened', () async {
    final logged = <String, String>{};

    final outcome = await runGoogleSignIn(
      clearGState: () => 'cleared',
      oneTap: () async => throw const GisOneTapCancelled(),
      popup: () async => fail('a deliberate close must NOT open the popup'),
      finish: (_, __) async => fail('must not sign in after a dismissal'),
      log: (k, v) => logged[k] = v,
    );

    expect(outcome, GoogleOutcome.closed);
    expect(logged['c566_path'], 'none');
  });

  test('skipped moment (cooldown) -> the popup path runs and signs in',
      () async {
    var popupCalls = 0;
    String? sentToken;
    String? sentNonce;
    final logged = <String, String>{};

    final outcome = await runGoogleSignIn(
      clearGState: () => 'cleared',
      // isSkippedMoment => the JS bridge rejects as suppressed.
      oneTap: () async => throw const GisOneTapSuppressed(),
      popup: () async {
        popupCalls++;
        return (idToken: 'jwt-popup', rawNonce: 'raw-999');
      },
      finish: (idToken, rawNonce) async {
        sentToken = idToken;
        sentNonce = rawNonce;
      },
      log: (k, v) => logged[k] = v,
    );

    expect(popupCalls, 1, reason: 'a skipped moment must invoke the popup');
    expect(outcome, GoogleOutcome.signedIn);
    expect(sentToken, 'jwt-popup');
    // Supabase must receive the RAW nonce, not the hashed one.
    expect(sentNonce, 'raw-999');
    expect(logged['c566_path'], 'popup');
  });

  test('both suppressed -> inline message only, nothing navigates', () async {
    final outcome = await runGoogleSignIn(
      clearGState: () => 'cleared',
      oneTap: () async => throw const GisOneTapSuppressed(),
      popup: () async => throw const GisOneTapSuppressed(),
      finish: (_, __) async => fail('nothing to finish'),
    );
    expect(outcome, GoogleOutcome.suppressed);
  });
}
