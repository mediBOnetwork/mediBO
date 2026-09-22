// CMD #2131 — Android login: tapping the EMPTY WhatsApp box opens the
// phone's number list (Phone Number Hint). A pick is cleaned to its last 10
// digits, sent RAW with no tap, and the code step opens. Back returns to the
// filled box; editing then needs the Get OTP tap. No network, no Supabase.

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
  // CMD #2181 — the backend's sentence for an unusable picked number.
  'number_hint_unusable':
      "That number can't be used here. Pick another or type your 10-digit WhatsApp number.",
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


const _ok = <String, dynamic>{
  'ok': true,
  'is_new_user': false,
  'message': 'Code sent on WhatsApp',
  'number': '8357881874',
};

Future<_FakeApi> _open(WidgetTester tester, Future<String?> Function() pick,
    List<int> calls) async {
  final api = _FakeApi(_ok);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: LoginView(
        api: api,
        onHome: (_) {},
        pollInterval: const Duration(milliseconds: 10),
        pollTimeout: const Duration(milliseconds: 200),
        autoSendOnFill: false, // Android: autofill is not the path, the picker is
        pickNumber: () {
          calls.add(1);
          return pick();
        },
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
  setUpAll(() => RenderLog.flushEnabled = false);
  // A remembered last number prefills the box, and a filled box never opens
  // the picker — each test starts as a first visit.
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('clean keeps the last 10 digits, never cuts the front', () {
    expect(LoginNumberFormatter.clean('918357881874'), '8357881874');
    expect(LoginNumberFormatter.clean('+91 83578 81874'), '8357881874');
    expect(LoginNumberFormatter.clean('08357881874'), '8357881874');
    expect(LoginNumberFormatter.clean('8357881874'), '8357881874');
  });

  testWidgets('a picked number is sent raw with no tap and opens the code step',
      (tester) async {
    final calls = <int>[];
    final api = await _open(tester, () async => '918357881874', calls);
    await tester.tap(find.byType(TextField).first);
    await tester.pumpAndSettle(const Duration(milliseconds: 400));

    expect(calls.length, 1);
    expect(api.sent, ['918357881874']);
    expect(find.text(_kConfig['code_section_label'] as String), findsOneWidget);

    // Back → the box is filled (backend number) and a tap edits, no picker.
    await tester.tap(find.byIcon(Icons.arrow_back_ios_new));
    await tester.pumpAndSettle();
    expect(_box(tester), '83578 81874');
    await tester.tap(find.byType(TextField).first);
    await tester.pumpAndSettle();
    expect(calls.length, 1);
    expect(api.sent.length, 1);

    // After an edit, sending is the user's tap.
    await tester.tap(find.text(_kConfig['send_label'] as String));
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
    expect(api.sent.length, 2);
  });

  testWidgets('a closed picker leaves an ordinary box and sends nothing',
      (tester) async {
    final calls = <int>[];
    final api = await _open(tester, () async => null, calls);
    await tester.tap(find.byType(TextField).first);
    await tester.pumpAndSettle();
    expect(calls.length, 1);
    expect(api.sent, isEmpty);
    // Once per visit: a second tap on the still-empty box types, no picker.
    await tester.tap(find.byType(TextField).first);
    await tester.pumpAndSettle();
    expect(calls.length, 1);
  });

  // CMD #2181 (debug pass on #2131, QA 569) — a pick the login cannot use is
  // not the same as a picker the user closed. It says so, in the BACKEND's
  // words, and the attempt is given back so the next tap reopens the picker.
  testWidgets('an unusable picked number speaks and keeps the attempt',
      (tester) async {
    final calls = <int>[];
    final api = await _open(tester, () async => '12345', calls);
    await tester.tap(find.byType(TextField).first);
    await tester.pumpAndSettle();

    expect(calls.length, 1);
    // Nothing was sent and the box is still empty and typeable.
    expect(api.sent, isEmpty);
    expect(_box(tester), '');
    // The backend's sentence is on screen, verbatim — no Dart copy.
    expect(find.text(_kConfig['number_hint_unusable'] as String), findsOneWidget);
    // The attempt came back: tapping again reopens the picker.
    await tester.tap(find.byType(TextField).first);
    await tester.pumpAndSettle();
    expect(calls.length, 2);
  });
}
