// PROTECTED — CMD #1904.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes what a NEW number sees on the WhatsApp door, or where a
// signed-up-but-unregistered account is sent.
//
// WhatsApp used to be login-only. login_request_otp asked who owned the number
// first and answered "No account found for this number" for anything it did
// not recognise, so Send code was a dead end for every first-time customer
// while Google happily created one. What this file holds down, on the ONE
// widget all the WhatsApp surfaces share:
//
//   1. SEND CODE IS A ONE-WAY DOOR. ok:true with is_new_user:true reaches the
//      Enter-login-code step exactly like a returning customer does — same
//      poll, same number of taps, no branch of its own.
//
//   2. THE NEW-USER LINE IS THE BACKEND'S. The code step prints
//      login_request_otp's `note` verbatim. A response with no note (every
//      existing account) leaves the step reading exactly as it did, and the
//      widget never coins a sentence of its own for either case.
//
//   3. ok:false STILL STOPS ON THE NUMBER STEP, with the backend's reason
//      printed — the blocked-role guard, the resend wait and both rate limits
//      all arrive that way, so none of them may skip to the code screen.
//
//   4. A NOTE IS ONLY A NEW USER'S. `note` alongside is_new_user:false is
//      ignored: one field cannot be made to override the other by accident.
//
//   5. signup_route WINS OVER home_route, AND ONLY WHEN THE BACKEND SET IT.
//      landingRoute() is the single place that decides, so the full-screen
//      login, the login panel and the view cannot drift apart. An ordinary
//      login still lands on home_route; a payload with neither goes nowhere
//      rather than to a guessed address.
//
// No network, no Supabase, no goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/auth/google_flow.dart';
import 'package:pharma_b2b/screens/auth/login_view.dart';
import 'package:pharma_b2b/utils/render_log.dart';

/// The backend copy login_screen_config() returns. Only the keys this file
/// asserts on carry real sentences; the rest exist so the widget paints.
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

const _kNewNote =
    'First time on mediBO — enter the code and we\'ll set up your account';

class _FakeApi implements LoginApi {
  _FakeApi({required this.request, this.status = const {}});

  /// What login_request_otp answers.
  final Map<String, dynamic> request;

  /// What login_otp_status answers. Defaults to a delivered code.
  final Map<String, dynamic> status;

  int requestCalls = 0;

  @override
  Future<Map<String, dynamic>> config() async => _kConfig;

  @override
  Future<Map<String, dynamic>> requestOtp(String input) async {
    requestCalls++;
    return request;
  }

  @override
  Future<Map<String, dynamic>> otpStatus(String input) async => status.isEmpty
      ? {'ok': true, 'state': 'sent', 'message': 'Code sent on WhatsApp'}
      : status;

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

/// Drives the view from the actions step to a sent code, and returns the api.
Future<_FakeApi> _sendCode(
  WidgetTester tester, {
  required Map<String, dynamic> request,
  Map<String, dynamic> status = const {},
}) async {
  final api = _FakeApi(request: request, status: status);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: LoginView(
        api: api,
        onHome: (_) {},
        pollInterval: const Duration(milliseconds: 10),
        pollTimeout: const Duration(milliseconds: 200),
      ),
    ),
  ));
  await tester.pumpAndSettle();

  // Continue on WhatsApp -> the number step.
  await tester.tap(find.text(_kConfig['whatsapp_label'] as String));
  await tester.pumpAndSettle();

  await tester.enterText(find.byType(TextField).first, '9812345670');
  await tester.pumpAndSettle();

  await tester.tap(find.text(_kConfig['send_label'] as String));
  await tester.pumpAndSettle(const Duration(milliseconds: 400));
  return api;
}

void main() {
  setUpAll(() {
    // The render-log's 800ms debounce is a real Timer that would outlive the
    // test and try to reach Supabase.
    RenderLog.flushEnabled = false;
  });

  group('Send code is a one-way door', () {
    testWidgets('an unknown number reaches the code step, like any other',
        (tester) async {
      await _sendCode(tester, request: {
        'ok': true,
        'is_new_user': true,
        'message': 'New here? We\'ll send a code and set you up',
        'note': _kNewNote,
        'ttl_seconds': 300,
        'poll': 'login_otp_status',
      });

      // The code step is on screen — not the number step it used to die on.
      expect(find.text(_kConfig['code_section_label'] as String), findsOneWidget);
      expect(find.text(_kConfig['verify_label'] as String), findsOneWidget);
    });

    testWidgets('a returning number reaches the same step', (tester) async {
      await _sendCode(tester, request: {
        'ok': true,
        'is_new_user': false,
        'message': 'Sending code on WhatsApp',
        'note': '',
      });
      expect(find.text(_kConfig['code_section_label'] as String), findsOneWidget);
    });
  });

  group('The new-user line is the backend\'s', () {
    testWidgets('a new number prints the note verbatim', (tester) async {
      await _sendCode(tester, request: {
        'ok': true,
        'is_new_user': true,
        'message': 'New here? We\'ll send a code and set you up',
        'note': _kNewNote,
      });
      expect(find.text(_kNewNote), findsOneWidget);
      // …and the ordinary confirmation is replaced, not stacked beside it.
      expect(find.text(_kConfig['code_sent_note'] as String), findsNothing);
    });

    testWidgets('an existing account keeps the ordinary confirmation',
        (tester) async {
      await _sendCode(tester, request: {
        'ok': true,
        'is_new_user': false,
        'message': 'Sending code on WhatsApp',
      });
      expect(find.text(_kConfig['code_sent_note'] as String), findsOneWidget);
      expect(find.text(_kNewNote), findsNothing);
    });

    testWidgets('a note without is_new_user is ignored', (tester) async {
      // One field must not be able to override the other by accident: only the
      // backend saying "this is a new user" turns the line on.
      await _sendCode(tester, request: {
        'ok': true,
        'is_new_user': false,
        'message': 'Sending code on WhatsApp',
        'note': _kNewNote,
      });
      expect(find.text(_kNewNote), findsNothing);
      expect(find.text(_kConfig['code_sent_note'] as String), findsOneWidget);
    });
  });

  group('ok:false never opens the code step', () {
    const refusals = <String, Map<String, dynamic>>{
      'a blocked role': {
        'ok': false,
        'is_new_user': false,
        'blocked': true,
        'message':
            'This number already logs in on another mediBO account. Use the sign-in for that account.',
      },
      'the resend wait': {
        'ok': false,
        'is_new_user': true,
        'message': 'Code already sent, wait 30 seconds',
      },
      'the per-number limit': {
        'ok': false,
        'is_new_user': true,
        'rate_limited': 'number',
        'message': 'Too many codes for this number. Try again in an hour.',
      },
      'the per-device limit': {
        'ok': false,
        'is_new_user': true,
        'rate_limited': 'ip',
        'message': 'Too many codes from this device. Try again in an hour.',
      },
    };

    refusals.forEach((name, payload) {
      testWidgets('$name stays on the number step and says why',
          (tester) async {
        await _sendCode(tester, request: payload);

        expect(find.text(_kConfig['code_section_label'] as String), findsNothing);
        expect(find.text(_kConfig['number_section_label'] as String),
            findsOneWidget);
        // The reason is the backend's sentence, printed verbatim.
        expect(find.text(payload['message'] as String), findsOneWidget);
      });
    });
  });

  group('landingRoute — signup_route wins, and only when it is set', () {
    test('a signed-up account with no profile goes to the form', () {
      expect(
        landingRoute({
          'signed_in': true,
          'needs_profile': true,
          'signup_route': '/complete-registration',
          'home_route': '/store',
        }),
        '/complete-registration',
      );
    });

    test('an ordinary login still lands on home_route', () {
      expect(
        landingRoute({
          'signed_in': true,
          'needs_profile': false,
          'signup_route': '',
          'home_route': '/store',
        }),
        '/store',
      );
    });

    test('a payload with no signup_route key at all uses home_route', () {
      expect(landingRoute({'signed_in': true, 'home_route': '/store'}), '/store');
    });

    test('neither route named goes nowhere rather than to a guess', () {
      expect(landingRoute({'signed_in': true}), '');
      expect(landingRoute({'signed_in': true, 'home_route': ''}), '');
    });
  });
}
