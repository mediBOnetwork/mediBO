// CHANGE #567 — the focused test:
// One Tap is the only path; a suppressed first attempt is retried exactly once;
// a second suppression stops (no popup, no FedCM, no OAuth — none of which even
// exist as parameters here); a dismissal stops immediately.
//
// runGoogleSignIn is platform-free so this runs on the VM with the attempt
// injected — no browser, no JS interop, no Supabase.

import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/auth/google_flow.dart';

void main() {
  test('suppressed first attempt is retried exactly once, then stops', () async {
    var attempts = 0;
    final delays = <Duration>[];
    final logged = <String, String>{};

    final outcome = await runGoogleSignIn(
      oneTap: () async {
        attempts++;
        throw const GisOneTapSuppressed();
      },
      finish: (_, __) async => fail('nothing to finish'),
      delay: (d) async => delays.add(d),
      log: (k, v) => logged[k] = v,
    );

    expect(attempts, 2, reason: 'exactly one retry, no more');
    expect(delays, [const Duration(milliseconds: 400)]);
    expect(outcome, GoogleOutcome.suppressed);
    expect(logged['c567_attempt'], '2');
    expect(logged['c567_result'], 'none');
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
    expect(logged['c567_result'], 'credential');
  });

  test('first attempt succeeds: no retry', () async {
    var attempts = 0;
    final logged = <String, String>{};

    final outcome = await runGoogleSignIn(
      oneTap: () async {
        attempts++;
        return (idToken: 'jwt', rawNonce: 'raw');
      },
      finish: (_, __) async {},
      delay: (_) async => fail('must not delay when the sheet showed'),
      log: (k, v) => logged[k] = v,
    );

    expect(attempts, 1);
    expect(outcome, GoogleOutcome.signedIn);
    expect(logged['c567_attempt'], '1');
  });

  test('dismissal stops immediately — no retry, nothing else opened', () async {
    var attempts = 0;
    final logged = <String, String>{};

    final outcome = await runGoogleSignIn(
      oneTap: () async {
        attempts++;
        throw const GisOneTapCancelled();
      },
      finish: (_, __) async => fail('must not sign in after a dismissal'),
      delay: (_) async => fail('a dismissal must not be retried'),
      log: (k, v) => logged[k] = v,
    );

    expect(attempts, 1, reason: 'a deliberate close is an answer, not a failure');
    expect(outcome, GoogleOutcome.closed);
    expect(logged['c567_result'], 'none');
  });
}
