// CHANGE #564 — the one focused test the spec asks for:
// when FedCM throws, One Tap prompt() is called, and no browser/OAuth path is
// reachable from the Google flow.
//
// runGoogleSignIn is deliberately platform-free so this runs on the VM with the
// two attempts injected — no browser, no JS interop, no Supabase.

import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/auth/google_flow.dart';

void main() {
  test('FedCM throws -> One Tap is called; nothing navigates', () async {
    var fedcmCalls = 0;
    var oneTapCalls = 0;
    final logged = <String, String>{};

    final outcome = await runGoogleSignIn(
      fedcm: () async {
        fedcmCalls++;
        throw const GisOneTapUnavailable();
      },
      oneTap: () async {
        oneTapCalls++;
        // Suppressed too — the "both unavailable" case.
        throw const GisOneTapSuppressed();
      },
      finish: (_, __) async => fail('must not sign in when both sheets failed'),
      fedcmError: () => 'unsupported',
      log: (k, v) => logged[k] = v,
    );

    expect(fedcmCalls, 1, reason: 'FedCM is the primary path');
    expect(oneTapCalls, 1, reason: 'One Tap must run when FedCM throws');
    expect(outcome, GoogleOutcome.suppressed);
    // The only escape hatch is an inline message — never a navigation.
    expect(logged['c564_path'], 'none');
    expect(logged['c564_fedcm'], 'rejected:unsupported');
  });

  test('FedCM succeeds -> One Tap is never called, raw nonce reaches Supabase',
      () async {
    var oneTapCalls = 0;
    String? sentToken;
    String? sentNonce;
    final logged = <String, String>{};

    final outcome = await runGoogleSignIn(
      fedcm: () async => (idToken: 'jwt-abc', rawNonce: 'raw-123'),
      oneTap: () async {
        oneTapCalls++;
        throw const GisOneTapUnavailable();
      },
      finish: (idToken, rawNonce) async {
        sentToken = idToken;
        sentNonce = rawNonce;
      },
      log: (k, v) => logged[k] = v,
    );

    expect(outcome, GoogleOutcome.signedIn);
    expect(oneTapCalls, 0);
    expect(sentToken, 'jwt-abc');
    // Supabase must receive the RAW nonce, not the hashed one.
    expect(sentNonce, 'raw-123');
    expect(logged['c564_path'], 'fedcm');
    expect(logged['c564_fedcm'], 'resolved');
  });

  test('user closes the FedCM chooser -> stop, do not open a second sheet',
      () async {
    var oneTapCalls = 0;

    final outcome = await runGoogleSignIn(
      fedcm: () async => throw const GisOneTapCancelled(),
      oneTap: () async {
        oneTapCalls++;
        throw const GisOneTapUnavailable();
      },
      finish: (_, __) async => fail('must not sign in after a dismissal'),
    );

    expect(outcome, GoogleOutcome.closed);
    expect(oneTapCalls, 0,
        reason: 'a deliberate close must not cascade into another sheet');
  });
}
