// CHANGE #568 — the focused test:
// One Tap is retried once, then the GIS button popup takes over; a dismissal
// stops immediately and must NOT open the popup. signInWithOAuth and
// navigator.credentials.get do not exist as parameters here at all.
//
// runGoogleSignIn is platform-free so this runs on the VM with the attempt
// injected — no browser, no JS interop, no Supabase.

import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/auth/google_flow.dart';

void main() {
  test('both One Tap attempts suppressed -> the popup takes over and signs in',
      () async {
    var attempts = 0;
    var popupCalls = 0;
    String? sentToken;
    String? sentNonce;
    final delays = <Duration>[];
    final logged = <String, String>{};

    final outcome = await runGoogleSignIn(
      oneTap: () async {
        attempts++;
        throw const GisOneTapSuppressed();
      },
      popup: () async {
        popupCalls++;
        return (idToken: 'jwt-popup', rawNonce: 'raw-popup');
      },
      finish: (idToken, rawNonce) async {
        sentToken = idToken;
        sentNonce = rawNonce;
      },
      delay: (d) async => delays.add(d),
      log: (k, v) => logged[k] = v,
    );

    expect(attempts, 2, reason: 'exactly one One Tap retry, no more');
    expect(delays, [const Duration(milliseconds: 400)]);
    expect(popupCalls, 1, reason: 'the popup is the cooldown-free fallback');
    expect(outcome, GoogleOutcome.signedIn);
    expect(sentToken, 'jwt-popup');
    expect(sentNonce, 'raw-popup');
    expect(logged['c568_path'], 'popup');
  });

  test('popup also fails -> suppressed, and still nothing navigates', () async {
    final outcome = await runGoogleSignIn(
      oneTap: () async => throw const GisOneTapSuppressed(),
      popup: () async => throw const GisOneTapSuppressed(),
      finish: (_, __) async => fail('nothing to finish'),
      delay: (_) async {},
    );
    expect(outcome, GoogleOutcome.suppressed);
  });

  test('retry succeeds: the fresh nonce from THAT attempt reaches Supabase',
      () async {
    var attempts = 0;
    String? sentToken;
    String? sentNonce;
    final logged = <String, String>{};

    final outcome = await runGoogleSignIn(
      oneTap: () async {
        attempts++;
        if (attempts == 1) throw const GisOneTapSuppressed();
        // Second attempt mints a fresh nonce pair; the raw half travels with
        // the credential so it can never be paired with the first attempt's.
        return (idToken: 'jwt-2', rawNonce: 'raw-attempt-2');
      },
      popup: () async => fail('popup must not run when the retry succeeds'),
      finish: (idToken, rawNonce) async {
        sentToken = idToken;
        sentNonce = rawNonce;
      },
      delay: (_) async {},
      log: (k, v) => logged[k] = v,
    );

    expect(attempts, 2);
    expect(outcome, GoogleOutcome.signedIn);
    expect(sentToken, 'jwt-2');
    expect(sentNonce, 'raw-attempt-2');
    expect(logged['c568_path'], 'onetap');
  });

  test('first attempt succeeds: no retry', () async {
    var attempts = 0;
    final logged = <String, String>{};

    final outcome = await runGoogleSignIn(
      oneTap: () async {
        attempts++;
        return (idToken: 'jwt', rawNonce: 'raw');
      },
      popup: () async => fail('popup must not run when One Tap succeeds'),
      finish: (_, __) async {},
      delay: (_) async => fail('must not delay when the sheet showed'),
      log: (k, v) => logged[k] = v,
    );

    expect(attempts, 1);
    expect(outcome, GoogleOutcome.signedIn);
    expect(logged['c568_attempt'], '1');
  });

  test('dismissal stops immediately — no retry, nothing else opened', () async {
    var attempts = 0;
    final logged = <String, String>{};

    final outcome = await runGoogleSignIn(
      oneTap: () async {
        attempts++;
        throw const GisOneTapCancelled();
      },
      popup: () async => fail('a deliberate close must NOT open the popup'),
      finish: (_, __) async => fail('must not sign in after a dismissal'),
      delay: (_) async => fail('a dismissal must not be retried'),
      log: (k, v) => logged[k] = v,
    );

    expect(attempts, 1, reason: 'a deliberate close is an answer, not a failure');
    expect(outcome, GoogleOutcome.closed);
    expect(logged['c568_path'], 'none');
  });
}
