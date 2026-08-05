// CHANGE #668 — native Google sign-in on Android.
//
// "Continue with Google" does nothing in the APK because the web flow opens a
// browser redirect a native app cannot complete. On Android the button now runs
// the google_sign_in native token flow and hands the id token to Supabase via
// signInWithIdToken; on web the existing redirect/One Tap path is untouched.
//
// Everything is injected: the native sign-in, the Supabase call, and the
// platform flag. No plugin, no network, no Supabase instance, no home_shell.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:pharma_b2b/screens/auth/login_screen.dart';
import 'package:pharma_b2b/screens/auth/login_view.dart';
import 'package:pharma_b2b/screens/auth/google_flow.dart';
import 'package:pharma_b2b/utils/render_log.dart';

/// Mirrors the live login_screen_config() payload — the strings the screen and
/// the native branch render. `google_unavailable_note` is the backend's own
/// failure sentence; the app coins none of its own.
const _config = <String, dynamic>{
  'brand': 'mediBO',
  'tagline': 'B2B pharma fulfilment',
  'google_label': 'Continue with Google',
  'google_sheet_title': 'Choose an account',
  'google_sheet_subtitle': 'to continue to mediBO',
  'google_other_account': 'Use another account',
  'google_unavailable_note': 'Google did not show the account sheet this time.',
  'whatsapp_label': 'Continue on WhatsApp',
  'number_section_label': 'WhatsApp number',
  'number_hint': '00000 00000',
  'number_prefix': '+91',
  'send_label': 'Send code',
  'sending_label': 'Sending on WhatsApp',
  'code_section_label': 'Code from WhatsApp',
  'code_digits': 6,
  'code_idle_note': 'Enter the code to continue',
  'verify_label': 'Validate',
  'resend_label': 'Resend',
  'resend_seconds': 30,
  'sent_to_prefix': 'to',
  'footer_note': 'No password — we only send a login code',
  'show_password': false,
  'show_forgot_password': false,
};

/// A LoginApi whose googleSignIn delegates to a real [SupabaseLoginApi] (so the
/// native branch is exercised end-to-end from a real tap), while config/otp are
/// local recordings — no network.
class _DelegatingApi implements LoginApi {
  _DelegatingApi(this.inner);
  final SupabaseLoginApi inner;

  bool requestOtpCalled = false;

  @override
  Future<Map<String, dynamic>> config() async => _config;

  @override
  Future<GoogleResult> googleSignIn({
    required String sheetTitle,
    required String sheetSubtitle,
    required String otherAccount,
    required String unavailableNote,
  }) =>
      inner.googleSignIn(
        sheetTitle: sheetTitle,
        sheetSubtitle: sheetSubtitle,
        otherAccount: otherAccount,
        unavailableNote: unavailableNote,
      );

  @override
  Future<Map<String, dynamic>> requestOtp(String input) async {
    requestOtpCalled = true;
    return {'ok': false};
  }

  @override
  Future<Map<String, dynamic>> otpStatus(String input) async => {'state': 'none'};
  @override
  Future<Map<String, dynamic>> verifyOtp(String input, String code) async =>
      {'ok': false};
  @override
  Future<Map<String, dynamic>> postNext(
          String url, Map<String, dynamic> body) async =>
      {'ok': false};
  @override
  Future<void> setSession(String refreshToken) async {}
  @override
  Future<Map<String, dynamic>> session() async => {'signed_in': false};
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  // ── The auth helper: SupabaseLoginApi.googleSignIn on Android ───────────────

  test('Android: passes the WEB client id and finishes with the returned token',
      () async {
    String? seenServerClientId;
    String? finishedId;
    String? finishedAccess;

    final api = SupabaseLoginApi(
      isAndroid: true,
      nativeSignIn: (serverClientId) async {
        seenServerClientId = serverClientId;
        return (idToken: 'ID_TOKEN_123', accessToken: 'ACCESS_456');
      },
      finishNative: (idToken, accessToken) async {
        finishedId = idToken;
        finishedAccess = accessToken;
      },
    );

    final res = await api.googleSignIn(
      sheetTitle: 't',
      sheetSubtitle: 's',
      otherAccount: 'o',
      unavailableNote: 'n',
    );

    // The WEB client id, not the Android one, is what the native flow receives.
    expect(seenServerClientId, kGoogleWebClientId);
    // signInWithIdToken got exactly the returned tokens.
    expect(finishedId, 'ID_TOKEN_123');
    expect(finishedAccess, 'ACCESS_456');
    expect(res.outcome, GoogleOutcome.signedIn);
    expect(res.message, isNull);
  });

  test('Android: a null id token shows the note and never calls Supabase',
      () async {
    var finishCalled = false;

    final api = SupabaseLoginApi(
      isAndroid: true,
      nativeSignIn: (_) async => (idToken: null, accessToken: 'ACCESS'),
      finishNative: (idToken, accessToken) async => finishCalled = true,
    );

    final res = await api.googleSignIn(
      sheetTitle: 't',
      sheetSubtitle: 's',
      otherAccount: 'o',
      unavailableNote: 'Google did not show the account sheet this time.',
    );

    expect(finishCalled, isFalse, reason: 'must not call Supabase with no token');
    expect(res.outcome, GoogleOutcome.suppressed);
    expect(res.message, 'Google did not show the account sheet this time.');
  });

  test('Android: a cancelled sheet shows no error', () async {
    var finishCalled = false;

    final api = SupabaseLoginApi(
      isAndroid: true,
      // null return == the user closed the sheet.
      nativeSignIn: (_) async => null,
      finishNative: (idToken, accessToken) async => finishCalled = true,
    );

    final res = await api.googleSignIn(
      sheetTitle: 't',
      sheetSubtitle: 's',
      otherAccount: 'o',
      unavailableNote: 'n',
    );

    expect(finishCalled, isFalse);
    expect(res.outcome, GoogleOutcome.closed);
    expect(res.message, isNull, reason: 'a cancellation is silent');
  });

  test('Android: a Supabase auth error surfaces its own message', () async {
    final api = SupabaseLoginApi(
      isAndroid: true,
      nativeSignIn: (_) async => (idToken: 'ID', accessToken: 'ACC'),
      finishNative: (idToken, accessToken) async =>
          throw const AuthException('Invalid token: audience mismatch'),
    );

    final res = await api.googleSignIn(
      sheetTitle: 't',
      sheetSubtitle: 's',
      otherAccount: 'o',
      unavailableNote: 'n',
    );

    expect(res.outcome, GoogleOutcome.suppressed);
    // The error's OWN message, verbatim — nothing added.
    expect(res.message, 'Invalid token: audience mismatch');
  });

  // ── The web path stays exactly as it was ────────────────────────────────────

  test('web: uses the existing path and never calls google_sign_in', () async {
    var nativeCalled = false;
    var oneTapCalled = false;

    final api = SupabaseLoginApi(
      isAndroid: false,
      // The web One Tap seam. Returning "cancelled" keeps us off Supabase while
      // still proving this branch — not the native one — ran.
      oneTap: () async {
        oneTapCalled = true;
        throw const GisOneTapCancelled();
      },
      nativeSignIn: (_) async {
        nativeCalled = true;
        return (idToken: 'X', accessToken: 'Y');
      },
    );

    final res = await api.googleSignIn(
      sheetTitle: 't',
      sheetSubtitle: 's',
      otherAccount: 'o',
      unavailableNote: 'n',
    );

    expect(oneTapCalled, isTrue, reason: 'the web One Tap path ran');
    expect(nativeCalled, isFalse, reason: 'google_sign_in is never used on web');
    expect(res.outcome, GoogleOutcome.closed);
    expect(res.message, isNull);
  });

  // ── The buttons, tapped for real ────────────────────────────────────────────

  testWidgets('tapping Continue with Google runs the native flow on Android',
      (tester) async {
    tester.view.physicalSize = const Size(500, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    String? seenServerClientId;
    final inner = SupabaseLoginApi(
      isAndroid: true,
      nativeSignIn: (serverClientId) async {
        seenServerClientId = serverClientId;
        return (idToken: 'ID', accessToken: 'ACC');
      },
      finishNative: (idToken, accessToken) async {},
    );
    final api = _DelegatingApi(inner);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: LoginView(api: api, onHome: (_) {})),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Continue with Google'));
    await tester.pumpAndSettle();

    // The real tap drove the native flow with the WEB client id.
    expect(seenServerClientId, kGoogleWebClientId);
    // The WhatsApp path was not touched by a Google tap.
    expect(api.requestOtpCalled, isFalse);
  });

  testWidgets('the WhatsApp button is unchanged — it opens the number step',
      (tester) async {
    tester.view.physicalSize = const Size(500, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    var nativeCalled = false;
    final inner = SupabaseLoginApi(
      isAndroid: true,
      nativeSignIn: (_) async {
        nativeCalled = true;
        return null;
      },
      finishNative: (idToken, accessToken) async {},
    );
    final api = _DelegatingApi(inner);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: LoginView(api: api, onHome: (_) {})),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Continue on WhatsApp'));
    await tester.pumpAndSettle();

    // The progressive WhatsApp flow still reveals the number step…
    expect(find.text('WhatsApp number'), findsOneWidget);
    // …and a WhatsApp tap never reaches the Google native flow.
    expect(nativeCalled, isFalse);
  });
}
