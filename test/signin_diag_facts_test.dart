// CHANGE #279 — the recorder sends the WHOLE certificate picture, not one
// number that could be read from the wrong array.
//
// #275 recorded a single `signing_sha1` taken from signingCertificateHistory,
// whose first element is the OLDEST certificate of a rotation chain. A device
// reported 69:37:2B:… for builds whose APKs verify as CB:88:BD:C5:…, and that
// one number could not distinguish "the wrong certificate is registered" from
// "we read the wrong certificate". These tests pin that every fact the platform
// channel reports reaches `auth_diag_note`, including the client id that was
// actually sent.
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/services/signin_diag.dart';

void main() {
  setUp(SignInDiag.resetForTest);
  tearDown(SignInDiag.resetForTest);

  test('every device fact reaches auth_diag_note under its own parameter',
      () async {
    Map<String, dynamic>? sent;
    SignInDiag.factsOverride = const <String, dynamic>{
      'package_name': 'in.medibo.app',
      'version_name': '1.3.11',
      'version_code': 24,
      'android_sdk': 30,
      'signing_sha1': 'CB:88:BD:C5',
      'signing_sha256': '12:9E:D1:00',
      'signers_sha1': 'CB:88:BD:C5',
      'history_sha1': '69:37:2B:88, CB:88:BD:C5',
      'has_multiple_signers': false,
      'install_source': 'com.android.vending',
    };
    SignInDiag.clientId = 'web-client-id';
    SignInDiag.rpcOverride = (params) async {
      sent = params;
      return const <String, dynamic>{'show': false};
    };

    await SignInDiag.note(stage: 'authenticate', code: 'canceled');

    // The current signer, both digests — dedicated columns, not buried in extra.
    expect(sent!['p_signing_sha1'], 'CB:88:BD:C5');
    expect(sent!['p_signing_sha256'], '12:9E:D1:00');
    // Where Android says the APK came from settles Play-vs-sideload outright.
    expect(sent!['p_install_source'], 'com.android.vending');
    // The id that was actually sent, never one assumed afterwards.
    expect(sent!['p_client_id'], 'web-client-id');
    expect(sent!['p_version_code'], 24);
    expect(sent!['p_package_name'], 'in.medibo.app');

    // The full arrays ride along so a rotation chain is visible as a chain.
    final extra = (sent!['p_extra'] as Map).cast<String, dynamic>();
    expect(extra['signers_sha1'], 'CB:88:BD:C5');
    expect(extra['history_sha1'], '69:37:2B:88, CB:88:BD:C5');
    expect(extra['has_multiple_signers'], false);
    expect(extra['android_sdk'], 30);
  });

  test('a build that reports no certificate still records the attempt',
      () async {
    Map<String, dynamic>? sent;
    SignInDiag.factsOverride = const <String, dynamic>{
      'package_name': 'in.medibo.app',
      'facts_error': 'NameNotFoundException',
    };
    SignInDiag.rpcOverride = (params) async {
      sent = params;
      return const <String, dynamic>{'show': false};
    };

    await SignInDiag.note(stage: 'authenticate', code: 'canceled');

    expect(sent, isNotNull, reason: 'a missing fingerprint is never a silence');
    expect(sent!['p_signing_sha1'], isNull);
    expect(sent!['p_client_id'], isNull);
    expect(
        ((sent!['p_extra'] as Map).cast<String, dynamic>())['facts_error'],
        'NameNotFoundException');
  });

  test('the backend sentence is returned verbatim, never reworded', () async {
    const sentence = 'Google refused this build. [canceled]\n'
        "This build's certificate SHA-1: CB:88:BD:C5";
    SignInDiag.factsOverride = const <String, dynamic>{};
    SignInDiag.rpcOverride = (_) async => const <String, dynamic>{
          'show': true,
          'tone': 'warning',
          'message': sentence,
        };

    final advice = await SignInDiag.note(stage: 'authenticate', code: 'canceled');

    expect(advice, isNotNull);
    expect(advice!.show, isTrue);
    expect(advice.message, sentence);
    expect(advice.tone, 'warning');
  });
}
