// CHANGE #564 — the one focused test the spec asks for:
// when prompt() reports a skipped moment, the popup path is invoked, and no
// browser/OAuth path is reachable from the Google flow.
//
// runGoogleSignIn is deliberately platform-free so this runs on the VM with both
// attempts injected — no browser, no JS interop, no Supabase.

import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/auth/google_flow.dart';

void main() {
  test('One Tap skipped (cooldown) -> the popup path runs; nothing navigates',
      () async {
    var oneTapCalls = 0;
    var popupCalls = 0;
    String? sentToken;
    String? sentNonce;
    final logged = <String, String>{};

    final outcome = await runGoogleSignIn(
      oneTap: () async {
        oneTapCalls++;
        // isSkippedMoment => the JS bridge rejects as suppressed.
        throw const GisOneTapSuppressed();
      },
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

    expect(oneTapCalls, 1, reason: 'One Tap is the primary path');
    expect(popupCalls, 1, reason: 'a skipped moment must invoke the popup');
    expect(outcome, GoogleOutcome.signedIn);
    expect(sentToken, 'jwt-popup');
    // Supabase must receive the RAW nonce, not the hashed one.
    expect(sentNonce, 'raw-999');
    expect(logged['c564_path'], 'popup');
    // There is no OAuth/browser callback in the signature at all — the browser
    // path is unreachable by construction, not by convention.
  });

  test('One Tap succeeds -> the popup is never opened', () async {
    var popupCalls = 0;
    final logged = <String, String>{};

    final outcome = await runGoogleSignIn(
      oneTap: () async => (idToken: 'jwt-abc', rawNonce: 'raw-123'),
      popup: () async {
        popupCalls++;
        throw const GisOneTapUnavailable();
      },
      finish: (_, __) async {},
      log: (k, v) => logged[k] = v,
    );

    expect(outcome, GoogleOutcome.signedIn);
    expect(popupCalls, 0);
    expect(logged['c564_path'], 'onetap');
  });

  test('user closes the sheet -> stop; no popup, no message', () async {
    var popupCalls = 0;
    final logged = <String, String>{};

    final outcome = await runGoogleSignIn(
      oneTap: () async => throw const GisOneTapCancelled(),
      popup: () async {
        popupCalls++;
        throw const GisOneTapUnavailable();
      },
      finish: (_, __) async => fail('must not sign in after a dismissal'),
      log: (k, v) => logged[k] = v,
    );

    expect(outcome, GoogleOutcome.closed);
    expect(popupCalls, 0,
        reason: 'a deliberate close must not open the popup');
    expect(logged['c564_path'], 'none');
  });

  test('both unavailable -> suppressed, still no navigation', () async {
    final outcome = await runGoogleSignIn(
      oneTap: () async => throw const GisOneTapSuppressed(),
      popup: () async => throw const GisOneTapSuppressed(),
      finish: (_, __) async => fail('nothing to finish'),
    );
    expect(outcome, GoogleOutcome.suppressed);
  });
}
