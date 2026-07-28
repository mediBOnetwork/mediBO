// CHANGE #554 — login screen is 100% backend-driven.
//
// Given a stubbed login_screen_config, the screen must:
//   • render both buttons using google_label / whatsapp_label
//   • render NO password field and NO forgot-password link (show_password and
//     show_forgot_password are false)
//   • keep the OTP row (input + verify button) disabled until a send succeeds
//
// The whole backend contract is injected through LoginApi, so this test makes
// no network call and needs no Supabase instance.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/auth/login_view.dart';

/// Mirrors the live login_screen_config() payload.
const _config = <String, dynamic>{
  'brand': 'mediBO',
  'tagline': 'B2B pharma fulfilment',
  'google_label': 'Login with Google',
  'whatsapp_label': 'Login with WhatsApp',
  'number_hint': 'WhatsApp number',
  'number_prefix': '+91',
  'send_label': 'Send OTP',
  'otp_hint': '6-digit code',
  'verify_label': 'Validate',
  'show_password': false,
  'show_forgot_password': false,
};

class _StubApi implements LoginApi {
  @override
  Future<Map<String, dynamic>> config() async => _config;

  @override
  Future<Map<String, dynamic>> requestOtp(String input) async =>
      throw StateError('not called in this test');

  @override
  Future<Map<String, dynamic>> otpStatus(String input) async =>
      throw StateError('not called in this test');

  @override
  Future<Map<String, dynamic>> verifyOtp(String input, String code) async =>
      throw StateError('not called in this test');

  @override
  Future<Map<String, dynamic>> postNext(
          String url, Map<String, dynamic> body) async =>
      throw StateError('not called in this test');

  @override
  Future<void> setSession(String refreshToken) async =>
      throw StateError('not called in this test');

  @override
  Future<Map<String, dynamic>> session() async =>
      throw StateError('not called in this test');

  @override
  Future<void> googleSignIn() async =>
      throw StateError('not called in this test');
}

void main() {
  testWidgets(
      'renders backend labels, no password/forgot UI, OTP row disabled before send',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: LoginView(api: _StubApi(), onHome: (_) {}),
      ),
    ));
    await tester.pumpAndSettle();

    // Both buttons come from the config, verbatim.
    expect(find.text('Login with Google'), findsOneWidget);
    expect(find.text('Login with WhatsApp'), findsOneWidget);

    // show_password:false / show_forgot_password:false — nothing is built.
    expect(find.byWidgetPredicate((w) => w is TextField && w.obscureText),
        findsNothing);
    expect(find.textContaining('assword'), findsNothing);
    expect(find.textContaining('orgot'), findsNothing);

    // Open the inline WhatsApp dropdown — no new route is pushed.
    await tester.tap(find.text('Login with WhatsApp'));
    await tester.pumpAndSettle();

    // Row 1 is rendered from the config.
    expect(find.text('+91'), findsOneWidget);
    expect(find.text('WhatsApp number'), findsOneWidget);
    expect(find.text('Send OTP'), findsOneWidget);

    // Row 2 exists but is disabled: no send has succeeded yet.
    final otpField = tester.widget<TextField>(
      find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == '6-digit code',
      ),
    );
    expect(otpField.enabled, isFalse);

    final verifyBtn = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Validate'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(verifyBtn.onPressed, isNull);
  });
}
