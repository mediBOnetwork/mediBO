// PROTECTED — CMD #2159.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes how the WhatsApp number box treats autofill/paste.
//
// A browser autofill suggestion used to arrive as 08357881874 or a cut-off
// 9183578818 (the raw value was capped at 10 BEFORE it was cleaned), and the
// user still had to tap Send. What this file holds down:
//
//   1. CLEAN BEFORE THE CAP. A whole number landing in one change keeps its
//      LAST 10 digits: 08…, +91 …, 91… all show 8357881874.
//   2. TYPING KEEPS THE OLD CAP. One character at a time never drops the
//      front of the number.
//   3. AUTOFILL SENDS ONCE, WITH NO TAP. The RAW value goes to
//      login_request_otp (the backend cleans), the box shows the backend's
//      `number`, and the code step opens. Back returns to the filled box, and
//      the same number is never auto-sent twice in one visit.
//   4. ok:false STAYS ON THE BOX with the backend's message.
//
// No network, no Supabase, no goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pharma_b2b/screens/auth/login_view.dart';
import 'package:pharma_b2b/utils/render_log.dart';

const _kConfig = <String, dynamic>{
  'brand': 'mediBO',
  'tagline': 'Pharmacy supplies, delivered',
  'whatsapp_label': 'Continue on WhatsApp',
  'google_label': 'Continue with Google',
  'number_section_label': 'Enter WhatsApp number',
  'number_prefix': '+91',
  'send_label': 'Send code',
  'sending_label': 'Sending…',
  'code_section_label': 'Enter login code',
  'verify_label': 'Validate',
  'code_sent_note': 'Code sent on WhatsApp',
  'resend_label': 'Resend',
  'footer_note': 'By continuing you agree to our terms',
  'code_digits': 6,
  'resend_seconds': 30,
};

class _FakeApi implements LoginApi {
  _FakeApi(this.request);
  final Map<String, dynamic> request;
  final List<String> sent = [];

  @override
  Future<Map<String, dynamic>> config() async => _kConfig;
  @override
  Future<Map<String, dynamic>> requestOtp(String input) async {
    sent.add(input);
    return request;
  }

  @override
  Future<Map<String, dynamic>> otpStatus(String input) async =>
      {'ok': true, 'state': 'sent', 'message': 'Code sent on WhatsApp'};
  @override
  Future<Map<String, dynamic>> verifyOtp(String i, String c) async =>
      {'ok': false, 'message': 'not used here'};
  @override
  Future<Map<String, dynamic>> postNext(String u, Map<String, dynamic> b) async =>
      {};
  @override
  Future<void> setSession(String refreshToken) async {}
  @override
  Future<Map<String, dynamic>> session() async => {'signed_in': false};
  @override
  Future<GoogleResult> googleSignIn({
    required String sheetTitle,
    required String sheetSubtitle,
    required String otherAccount,
    required String unavailableNote,
  }) async =>
      (outcome: GoogleOutcome.closed, message: null);
}

TextEditingValue _fmt(String oldText, String newText) =>
    LoginNumberFormatter().formatEditUpdate(
      TextEditingValue(text: oldText),
      TextEditingValue(text: newText),
    );

const _ok = <String, dynamic>{
  'ok': true,
  'is_new_user': false,
  'message': 'Code sent on WhatsApp',
  'number': '8357881874',
};

Future<_FakeApi> _open(WidgetTester tester, Map<String, dynamic> req) async {
  final api = _FakeApi(req);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: LoginView(
        api: api,
        onHome: (_) {},
        pollInterval: const Duration(milliseconds: 10),
        pollTimeout: const Duration(milliseconds: 200),
        autoSendOnFill: true,
      ),
    ),
  ));
  await tester.pumpAndSettle();
  await tester.tap(find.text(_kConfig['whatsapp_label'] as String));
  await tester.pumpAndSettle();
  return api;
}

String _box(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField).first).controller!.text;

void main() {
  setUpAll(() {
    RenderLog.flushEnabled = false;
    SharedPreferences.setMockInitialValues({});
  });

  group('clean before the cap', () {
    for (final raw in ['08357881874', '+91 83578 81874', '918357881874']) {
      test('$raw lands as the last 10 digits', () {
        expect(_fmt('', raw).text, '83578 81874');
      });
    }
    test('typing an 11th digit by hand keeps the first ten', () {
      expect(_fmt('83578 81874', '83578 818745').text, '83578 81874');
    });
  });

  testWidgets('autofill sends the raw value once and opens the code step',
      (tester) async {
    final api = await _open(tester, _ok);
    await tester.enterText(find.byType(TextField).first, '+91 83578 81874');
    await tester.pumpAndSettle(const Duration(milliseconds: 400));

    expect(api.sent, ['+91 83578 81874']);
    expect(find.text(_kConfig['code_section_label'] as String), findsOneWidget);

    // Back → the box, filled with the backend's number and editable.
    await tester.tap(find.byIcon(Icons.arrow_back_ios_new));
    await tester.pumpAndSettle();
    expect(find.text(_kConfig['number_section_label'] as String),
        findsOneWidget);
    expect(_box(tester), '83578 81874');

    // The same number filled again is never auto-sent twice this visit.
    await tester.enterText(find.byType(TextField).first, '08357881874');
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
    expect(api.sent.length, 1);
    expect(find.text(_kConfig['number_section_label'] as String),
        findsOneWidget);

    // After editing, the tap still sends.
    await tester.tap(find.text(_kConfig['send_label'] as String));
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
    expect(api.sent.length, 2);
  });

  testWidgets('typing by hand never sends without the tap', (tester) async {
    final api = await _open(tester, _ok);
    final field = find.byType(TextField).first;
    for (final ch in '8357881874'.split('')) {
      // One character appended to what the box shows — a keystroke.
      await tester.enterText(field, _box(tester) + ch);
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(_box(tester), '83578 81874');
    expect(api.sent, isEmpty);
  });

  testWidgets('ok:false stays on the box with the backend message',
      (tester) async {
    const msg = 'Too many codes for this number. Try again in an hour.';
    final api = await _open(tester, {'ok': false, 'message': msg});
    await tester.enterText(find.byType(TextField).first, '918357881874');
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
    expect(api.sent.length, 1);
    expect(find.text(msg), findsOneWidget);
    expect(find.text(_kConfig['number_section_label'] as String),
        findsOneWidget);
  });
}
