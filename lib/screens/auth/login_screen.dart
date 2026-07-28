// CHANGE #554/#555 — login screen wrapper.
//
// All UI and flow live in login_view.dart, which is platform-free and takes the
// backend contract through [LoginApi]. This file is the only place that knows
// about Supabase: it supplies the real RPC/edge-function calls, drives the
// Google One Tap bottom sheet (falling back to the existing OAuth flow), and
// performs the navigation to the backend's home_route.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/gis_auth.dart';
import '../../user_state.dart';
import '../../utils/render_log.dart';
import 'login_view.dart';

/// Supabase-backed implementation of the CHANGE #554/#555 login contract.
class SupabaseLoginApi implements LoginApi {
  SupabaseLoginApi({required this.oauthFallback});

  /// The existing OAuth PKCE redirect, used when One Tap cannot be shown.
  final Future<void> Function() oauthFallback;

  SupabaseClient get _c => Supabase.instance.client;

  Map<String, dynamic> _asMap(dynamic v) =>
      v is Map ? v.cast<String, dynamic>() : <String, dynamic>{};

  @override
  Future<Map<String, dynamic>> config() async =>
      _asMap(await _c.rpc('login_screen_config'));

  @override
  Future<Map<String, dynamic>> requestOtp(String input) async =>
      _asMap(await _c.rpc('login_request_otp', params: {'p_input': input}));

  @override
  Future<Map<String, dynamic>> otpStatus(String input) async =>
      _asMap(await _c.rpc('login_otp_status', params: {'p_input': input}));

  @override
  Future<Map<String, dynamic>> verifyOtp(String input, String code) async =>
      _asMap(await _c
          .rpc('login_verify_otp', params: {'p_input': input, 'p_code': code}));

  @override
  Future<Map<String, dynamic>> postNext(
      String url, Map<String, dynamic> body) async {
    // Exactly as the backend specified: JSON body, Content-Type only, no auth.
    final res = await http.post(
      Uri.parse(url),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    try {
      return _asMap(jsonDecode(res.body));
    } catch (_) {
      return const <String, dynamic>{};
    }
  }

  @override
  Future<void> setSession(String refreshToken) =>
      _c.auth.setSession(refreshToken);

  @override
  Future<Map<String, dynamic>> session() async => _asMap(await _c.rpc('my_session'));

  void _log(String k, String v) {
    try {
      RenderLog.write(k, v);
    } catch (_) {}
  }

  Future<void> _finishIdToken(String idToken, String rawNonce) =>
      _c.auth.signInWithIdToken(
        provider: OAuthProvider.google,
        idToken: idToken,
        nonce: rawNonce,
      );

  /// CHANGE #556: one tap from the button to signed in, without ever leaving
  /// the app.
  ///
  /// Escalation, most in-app first:
  ///   1. One Tap (FedCM) — a half-screen sheet listing the device's signed-in
  ///      Google accounts, rendered in-page. No navigation at all.
  ///   2. Our own half-screen sheet hosting the GIS button — opens Google in a
  ///      popup that closes itself, so an installed PWA is never navigated away.
  ///   3. Full-page OAuth redirect — the last resort only, because in a PWA it
  ///      shows browser chrome. Reached only if both in-app paths failed.
  ///
  /// A deliberate dismissal at any level stops the escalation: the user said no.
  @override
  Future<void> googleSignIn({
    required String sheetTitle,
    required String sheetSubtitle,
    required String otherAccount,
  }) async {
    // 1 — One Tap. Called first with no awaits before it so the tap's user
    // activation is still live; without it Chrome refuses to show the sheet.
    try {
      final (:idToken, :rawNonce) = await gisPromptOneTap();
      _log('c556_path', 'one_tap');
      await _finishIdToken(idToken, rawNonce);
      _log('c556_session', 'established');
      return;
    } on GisOneTapCancelled {
      _log('c556_path', 'one_tap_cancelled');
      return;
    } on GisOneTapUnavailable {
      _log('c556_one_tap', 'unavailable');
    }

    // 2 — our own half-screen sheet with the GIS button (popup ux_mode).
    try {
      final (:idToken, :rawNonce) = await gisSheetSignIn(
        title: sheetTitle,
        subtitle: sheetSubtitle,
        cancelLabel: otherAccount,
      );
      _log('c556_path', 'sheet_button');
      await _finishIdToken(idToken, rawNonce);
      _log('c556_session', 'established');
      return;
    } on GisOneTapCancelled {
      _log('c556_path', 'sheet_cancelled');
      return;
    } on GisOneTapUnavailable {
      _log('c556_sheet', 'unavailable');
    }

    // 3 — last resort. Records whether this cost an installed PWA its chrome.
    _log('c556_path',
        isStandalonePwa() ? 'oauth_redirect_in_pwa' : 'oauth_redirect');
    await oauthFallback();
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  static const _green = Color(0xFF1B5E20);

  late final SupabaseLoginApi _api;
  StreamSubscription<AuthState>? _authSub;
  bool _navigated = false;

  @override
  void initState() {
    super.initState();
    _api = SupabaseLoginApi(
      oauthFallback: () => UserState.read(context).signInWithGoogleOAuth(),
    );

    // CHANGE #556: load + initialize GIS now, so the later tap can call
    // prompt() synchronously and keep its user activation. Fire-and-forget:
    // a failure here just means the escalation starts one step lower.
    unawaited(gisPrewarm().then((ok) {
      try {
        RenderLog.write('c556_prewarm', ok ? 'ready' : 'failed');
      } catch (_) {}
    }));

    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        RenderLog.write('c556_login_rendered', true);
      } catch (_) {}
      // Already signed in (e.g. returning to /login with a live session).
      try {
        if (mounted && Supabase.instance.client.auth.currentUser != null) {
          _resolveHome();
        }
      } catch (_) {}
    });

    // The OAuth PKCE redirect path completes on a fresh page load, so the
    // signedIn event — not the awaited call — is what lands the user. Also
    // covers setSession from the WhatsApp flow.
    try {
      _authSub = Supabase.instance.client.auth.onAuthStateChange.listen((s) {
        if (s.event == AuthChangeEvent.signedIn && mounted) _resolveHome();
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }

  /// Asks the backend where this user belongs, then goes there.
  Future<void> _resolveHome() async {
    if (_navigated) return;
    try {
      final s = await _api.session();
      if (!mounted) return;
      if (s['signed_in'] != true) return;
      final route = s['home_route'] as String?;
      if (route == null || route.isEmpty) return;
      _goTo(route);
    } catch (_) {
      // No local error copy — the view keeps showing the last backend message.
    }
  }

  void _goTo(String route) {
    if (_navigated || !mounted) return;
    _navigated = true;
    try {
      RenderLog.write('c554_home_route', route);
    } catch (_) {}
    try {
      Navigator.of(context).pushNamedAndRemoveUntil(route, (r) => false);
    } catch (_) {
      // Navigation fallback only — never leave the user stranded on /login.
      if (Navigator.canPop(context)) {
        Navigator.of(context).popUntil((r) => r.isFirst);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Stack(
          children: [
            // LoginView owns its own full-height layout (wash band + thumb-reach
            // actions) and its own scrolling, so it must not be boxed here.
            // It goes first so the route back button paints above it.
            Positioned.fill(child: LoginView(api: _api, onHome: _goTo)),
            Positioned(
              top: 8,
              left: 8,
              child: IconButton(
                icon: const Icon(Icons.arrow_back_ios_new, size: 20),
                color: _green,
                onPressed: () {
                  if (Navigator.canPop(context)) Navigator.pop(context);
                },
                tooltip: 'Back',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
