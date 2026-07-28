// CHANGE #555 — login screen is 100% backend-driven, and progressive.
//
// Given a stubbed login_screen_config, the screen must:
//   • render both buttons using whatsapp_label / google_label
//   • render NO password field and NO forgot-password link (show_password and
//     show_forgot_password are false)
//   • show NEITHER the number field NOR the code boxes before the WhatsApp
//     button is tapped — nothing disabled is visible on first paint
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
  'google_label': 'Continue with Google',
  'google_sheet_title': 'Choose an account',
  'google_sheet_subtitle': 'to continue to mediBO',
  'google_other_account': 'Use another account',
  'whatsapp_label': 'Continue on WhatsApp',
  'number_section_label': 'WhatsApp number',
  'number_hint': '00000 00000',
  'number_prefix': '+91',
  'send_label': 'Send code',
  'sending_label': 'Sending on WhatsApp',
  'code_section_label': 'Code from WhatsApp',
  'code_digits': 6,
  'otp_hint': '6-digit code',
  'code_idle_note': 'Enter the code to continue',
  'verify_label': 'Validate',
  'resend_label': 'Resend',
  'resend_seconds': 30,
  'sent_to_prefix': 'to',
  'footer_note': 'No password — we only send a login code',
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
  Future<GoogleOutcome> googleSignIn({
    required String sheetTitle,
    required String sheetSubtitle,
    required String otherAccount,
  }) async =>
      throw StateError('not called in this test');

}

void main() {
  testWidgets(
      'first paint: both buttons from config, no password/forgot UI, no number field, no code boxes',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: LoginView(api: _StubApi(), onHome: (_) {}),
      ),
    ));
    await tester.pumpAndSettle();

    // Both actions come from the config, verbatim.
    expect(find.text('Continue on WhatsApp'), findsOneWidget);
    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.text('No password — we only send a login code'), findsOneWidget);

    // show_password:false / show_forgot_password:false — nothing is built.
    expect(find.byWidgetPredicate((w) => w is TextField && w.obscureText),
        findsNothing);
    expect(find.textContaining('orgot'), findsNothing);

    // Nothing disabled is visible on first paint: no number field, no code
    // boxes, no Send / Validate buttons — not even greyed out.
    expect(find.byType(TextField), findsNothing);
    expect(find.text('+91'), findsNothing);
    expect(find.text('Send code'), findsNothing);
    expect(find.text('Validate'), findsNothing);
    expect(find.text('Resend'), findsNothing);

    // Tapping WhatsApp reveals the number step — and only the number step.
    await tester.tap(find.text('Continue on WhatsApp'));
    await tester.pumpAndSettle();

    expect(find.text('WhatsApp number'), findsOneWidget);
    expect(find.text('+91'), findsOneWidget);
    expect(find.text('Send code'), findsOneWidget);
    // Exactly one field: the number. The six code boxes stay unbuilt until a
    // send actually succeeds.
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Validate'), findsNothing);
  });
}
