// PROTECTED — CHANGE #275. The Google sign-in failure can never go silent again.
//
// WHAT WENT WRONG: on the Play Store build the account sheet appeared, an
// account was picked, and nothing happened — no error on screen, no session,
// and ZERO attempts in the Supabase auth log. Two things made that possible and
// both are pinned here:
//
//   1. `GoogleSignInExceptionCode.canceled` was converted into "the user said
//      no" and thrown away. Android Credential Manager reports a PROVIDER-side
//      refusal — an app whose signing certificate is not on a registered
//      Android OAuth client, most often — as a cancellation, so the one error
//      that mattered was the one error the app deliberately ignored.
//   2. The only breadcrumbs went to render_log, whose singleton row is WIPED
//      by the next web deploy (render_log_note resets on a new build_hash), so
//      nothing survived to be read.
//
// The contract now: EVERY non-signed-in exit records the REAL platform code
// through the diag seam before anything is decided, and the sentence the user
// reads is the backend's, never one coined in Dart.
//
// No plugin, no network, no Supabase: the native sign-in, the Supabase finish
// and the diag recorder are all injected.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:pharma_b2b/screens/auth/google_flow.dart';
import 'package:pharma_b2b/services/signin_diag.dart';
import 'package:pharma_b2b/screens/auth/login_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

/// One recorded call to the diag seam.
class _Note {
  _Note(this.stage, this.code, this.description, this.details, this.elapsedMs);
  final String stage;
  final String code;
  final String? description;
  final String? details;
  final int? elapsedMs;
}

/// A recorder that captures what would have been written to `auth_diag`, and
/// replies with whatever advice the test wants the backend to have sent.
class _Recorder {
  _Recorder({this.advice});
  final DiagAdvice? advice;
  final List<_Note> notes = [];

  Future<DiagAdvice?> call({
    required String stage,
    required String code,
    String? description,
    String? details,
    int? elapsedMs,
  }) async {
    notes.add(_Note(stage, code, description, details, elapsedMs));
    return advice;
  }
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  test('a provider refusal reported as `canceled` is RECORDED, not swallowed',
      () async {
    final rec = _Recorder();
    final api = SupabaseLoginApi(
      isAndroid: true,
      nativeSignIn: (_) async => throw const GoogleSignInException(
        code: GoogleSignInExceptionCode.canceled,
        description: 'Activity was cancelled by the user.',
      ),
      finishNative: (_, __) async => fail('Supabase must not be called'),
      diagNote: rec.call,
    );

    await api.googleSignIn(
      sheetTitle: 't',
      sheetSubtitle: 's',
      otherAccount: 'o',
      unavailableNote: 'n',
    );

    expect(rec.notes, hasLength(1));
    // The REAL platform code, verbatim — this is the whole point.
    expect(rec.notes.single.code, 'canceled');
    expect(rec.notes.single.stage, 'authenticate');
    expect(rec.notes.single.description, 'Activity was cancelled by the user.');
    expect(rec.notes.single.elapsedMs, isNotNull);
  });

  test('when the backend chooses to speak, its sentence is shown verbatim',
      () async {
    const backendCopy =
        'Google closed the sign-in sheet before it finished (canceled). [canceled]';
    final rec = _Recorder(
        advice: (show: true, message: backendCopy, tone: 'warning'));
    final api = SupabaseLoginApi(
      isAndroid: true,
      nativeSignIn: (_) async => throw const GoogleSignInException(
          code: GoogleSignInExceptionCode.canceled),
      finishNative: (_, __) async {},
      diagNote: rec.call,
    );

    final res = await api.googleSignIn(
      sheetTitle: 't',
      sheetSubtitle: 's',
      otherAccount: 'o',
      unavailableNote: 'n',
    );

    // Verbatim: not reworded, not prefixed, not truncated.
    expect(res.message, backendCopy);
    expect(res.outcome, GoogleOutcome.suppressed);
  });

  test('a silent backend leaves a genuine cancellation silent', () async {
    // show:false is how the backend says "this one is the user saying no".
    final rec =
        _Recorder(advice: (show: false, message: null, tone: 'warning'));
    final api = SupabaseLoginApi(
      isAndroid: true,
      nativeSignIn: (_) async => throw const GoogleSignInException(
          code: GoogleSignInExceptionCode.canceled),
      finishNative: (_, __) async {},
      diagNote: rec.call,
    );

    final res = await api.googleSignIn(
      sheetTitle: 't',
      sheetSubtitle: 's',
      otherAccount: 'o',
      unavailableNote: 'n',
    );

    expect(res.outcome, GoogleOutcome.closed);
    expect(res.message, isNull);
    // Silent to the USER is still recorded for us.
    expect(rec.notes.single.code, 'canceled');
  });

  test('every other platform code is recorded under its own name', () async {
    for (final code in <GoogleSignInExceptionCode>[
      GoogleSignInExceptionCode.providerConfigurationError,
      GoogleSignInExceptionCode.clientConfigurationError,
      GoogleSignInExceptionCode.uiUnavailable,
      GoogleSignInExceptionCode.interrupted,
      GoogleSignInExceptionCode.unknownError,
    ]) {
      final rec = _Recorder();
      final api = SupabaseLoginApi(
        isAndroid: true,
        nativeSignIn: (_) async =>
            throw GoogleSignInException(code: code, description: 'boom'),
        finishNative: (_, __) async {},
        diagNote: rec.call,
      );
      final res = await api.googleSignIn(
        sheetTitle: 't',
        sheetSubtitle: 's',
        otherAccount: 'o',
        unavailableNote: 'n',
      );
      expect(rec.notes.single.code, code.name,
          reason: 'the platform code is what gets recorded');
      expect(res.outcome, GoogleOutcome.suppressed);
    }
  });

  test('a stripped plugin is recorded as plugin_missing, never as a cancel',
      () async {
    final rec = _Recorder();
    final api = SupabaseLoginApi(
      isAndroid: true,
      nativeSignIn: (_) async =>
          throw MissingPluginException('No implementation found'),
      finishNative: (_, __) async {},
      diagNote: rec.call,
    );

    final res = await api.googleSignIn(
      sheetTitle: 't',
      sheetSubtitle: 's',
      otherAccount: 'o',
      unavailableNote: 'n',
    );

    expect(rec.notes.single.code, 'plugin_missing');
    expect(res.outcome, GoogleOutcome.suppressed);
  });

  test('an account with no id token is recorded and never reaches Supabase',
      () async {
    final rec = _Recorder();
    var finishCalled = false;
    final api = SupabaseLoginApi(
      isAndroid: true,
      nativeSignIn: (_) async => (idToken: null, accessToken: 'A'),
      finishNative: (_, __) async => finishCalled = true,
      diagNote: rec.call,
    );

    final res = await api.googleSignIn(
      sheetTitle: 't',
      sheetSubtitle: 's',
      otherAccount: 'o',
      unavailableNote: 'Google did not show the account sheet this time.',
    );

    expect(finishCalled, isFalse);
    expect(rec.notes.single.code, 'no_id_token');
    expect(rec.notes.single.stage, 'id_token');
    // With no backend advice the fallback is still the BACKEND's own note.
    expect(res.message, 'Google did not show the account sheet this time.');
  });

  test('a Supabase refusal is recorded as supabase_auth_error', () async {
    final rec = _Recorder();
    final api = SupabaseLoginApi(
      isAndroid: true,
      nativeSignIn: (_) async => (idToken: 'ID', accessToken: 'A'),
      finishNative: (_, __) async =>
          throw const AuthException('Invalid token: audience mismatch'),
      diagNote: rec.call,
    );

    final res = await api.googleSignIn(
      sheetTitle: 't',
      sheetSubtitle: 's',
      otherAccount: 'o',
      unavailableNote: 'n',
    );

    expect(rec.notes.single.stage, 'supabase');
    expect(rec.notes.single.code, 'supabase_auth_error');
    expect(res.message, 'Invalid token: audience mismatch');
  });

  test('a successful sign-in records NOTHING', () async {
    final rec = _Recorder();
    final api = SupabaseLoginApi(
      isAndroid: true,
      nativeSignIn: (_) async => (idToken: 'ID', accessToken: 'A'),
      finishNative: (_, __) async {},
      diagNote: rec.call,
    );

    final res = await api.googleSignIn(
      sheetTitle: 't',
      sheetSubtitle: 's',
      otherAccount: 'o',
      unavailableNote: 'n',
    );

    expect(res.outcome, GoogleOutcome.signedIn);
    expect(rec.notes, isEmpty);
  });

  test('the WEB client id is what the native flow receives — never an Android one',
      () async {
    String? seen;
    final api = SupabaseLoginApi(
      isAndroid: true,
      nativeSignIn: (serverClientId) async {
        seen = serverClientId;
        return (idToken: 'ID', accessToken: 'A');
      },
      finishNative: (_, __) async {},
      diagNote: _Recorder().call,
    );

    await api.googleSignIn(
      sheetTitle: 't',
      sheetSubtitle: 's',
      otherAccount: 'o',
      unavailableNote: 'n',
    );

    expect(seen, kGoogleWebClientId);
    // The Android OAuth client ids are registered in Google Cloud against the
    // signing certificates; passing one from Dart is the classic wrong fix.
    expect(kGoogleWebClientId, isNot(contains('m8m5p5ln9d1vv2eal4nrs02jqnucs08r')));
  });

  test('the web path records nothing and never touches the native seam',
      () async {
    final rec = _Recorder();
    final api = SupabaseLoginApi(
      isAndroid: false,
      nativeSignIn: (_) async => fail('native flow must not run on web'),
      oneTap: () async => throw const GisOneTapSuppressed(),
      popup: ({required title, required subtitle, required cancelLabel}) async =>
          throw const GisOneTapSuppressed(),
      diagNote: rec.call,
    );

    final res = await api.googleSignIn(
      sheetTitle: 't',
      sheetSubtitle: 's',
      otherAccount: 'o',
      unavailableNote: 'n',
    );

    expect(res.outcome, GoogleOutcome.suppressed);
    expect(res.message, isNull, reason: 'web behaviour is byte-for-byte as it was');
    expect(rec.notes, isEmpty);
  });
}
