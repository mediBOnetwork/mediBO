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
  SupabaseLoginApi({required this.oauthFallback, required this.auth});

  /// The existing OAuth PKCE redirect, used when One Tap cannot be shown.
  final Future<void> Function() oauthFallback;

  /// CHANGE #558 — the one session holder. This screen does not keep a session
  /// of its own and never calls my_session() behind the notifier's back.
  final AuthNotifier auth;

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

  /// CHANGE #558 — resolves through [AuthNotifier], so the guest-cart claim
  /// (RULE 5) and the hard reset (RULE 3) have both already run, and the whole
  /// app ends up looking at the same session object.
  @override
  Future<Map<String, dynamic>> session() async {
    await auth.refreshSession();
    final s = auth.session;
    if (s == null || !s.signedIn || !auth.sessionMatchesAuthUser) {
      return const <String, dynamic>{'signed_in': false};
    }
    return <String, dynamic>{
      'signed_in': true,
      'auth_user_id': s.authUserId,
      'login_email': s.loginEmail,
      'role': s.role,
      'is_admin': s.isAdmin,
      'display_name': s.displayName,
      'home_route': s.homeRoute,
      'home_label': s.homeLabel,
      'message': s.message,
    };
  }

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

  /// CHANGE #557: one tap from the button to signed in, without ever leaving
  /// the app.
  ///
  /// Escalation, most in-app first:
  ///   1. navigator.credentials.get() with mediation:'required' — the browser's
  ///      own chooser, listing EVERY Google account signed in on the device,
  ///      drawn over the page. Not subject to One Tap's dismissal cooldown.
  ///   2. GIS One Tap — same in-page sheet, but Google may suppress it.
  ///   3. Our own half-screen sheet hosting the GIS button — opens Google in a
  ///      popup that closes itself, so an installed PWA is never navigated away.
  ///   4. Full-page OAuth redirect — the last resort only, because in a PWA it
  ///      shows browser chrome. Reached only if every in-app path failed.
  ///
  /// A deliberate dismissal at any level stops the escalation: the user said no.
  @override
  Future<void> googleSignIn({
    required String sheetTitle,
    required String sheetSubtitle,
    required String otherAccount,
  }) async {
    // 1 — CHANGE #557: ask the browser directly for a FedCM credential with
    // mediation:'required'. This lists EVERY Google account signed in on the
    // device in one chooser and ignores One Tap's dismissal cooldown, which
    // the #556 render-log showed was suppressing the sheet
    // (prewarm=ready, one_tap=unavailable). No awaits before it — mode:'active'
    // needs the tap's user activation.
    try {
      final (:idToken, :rawNonce) = await fedcmChooseAccount();
      _log('c557_path', 'fedcm_chooser');
      await _finishIdToken(idToken, rawNonce);
      _log('c557_session', 'established');
      return;
    } on GisOneTapCancelled {
      // The user closed the chooser — do not cascade into a popup.
      _log('c557_path', 'fedcm_cancelled');
      return;
    } on GisOneTapUnavailable {
      _log('c557_fedcm', lastGisError());
    }

    // 2 — GIS One Tap, same in-page sheet but subject to Google's suppression.
    try {
      final (:idToken, :rawNonce) = await gisPromptOneTap();
      _log('c557_path', 'one_tap');
      await _finishIdToken(idToken, rawNonce);
      _log('c557_session', 'established');
      return;
    } on GisOneTapCancelled {
      _log('c557_path', 'one_tap_cancelled');
      return;
    } on GisOneTapUnavailable {
      _log('c557_one_tap', 'unavailable');
    }

    // 3 — our own half-screen sheet with the GIS button (popup ux_mode).
    try {
      final (:idToken, :rawNonce) = await gisSheetSignIn(
        title: sheetTitle,
        subtitle: sheetSubtitle,
        cancelLabel: otherAccount,
      );
      _log('c557_path', 'sheet_button');
      await _finishIdToken(idToken, rawNonce);
      _log('c557_session', 'established');
      return;
    } on GisOneTapCancelled {
      _log('c557_path', 'sheet_cancelled');
      return;
    } on GisOneTapUnavailable {
      _log('c557_sheet', 'unavailable');
    }

    // 4 — last resort. Records whether this cost an installed PWA its chrome.
    _log('c557_path',
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

  SupabaseLoginApi? _api;
  AuthNotifier? _auth;
  bool _navigated = false;

  @override
  void initState() {
    super.initState();

    // CHANGE #556: load + initialize GIS now, so the later tap can call
    // prompt() synchronously and keep its user activation. Fire-and-forget:
    // a failure here just means the escalation starts one step lower.
    unawaited(gisPrewarm().then((ok) {
      try {
        RenderLog.write('c557_prewarm', ok ? 'ready' : 'failed');
      } catch (_) {}
    }));

    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        RenderLog.write('c557_login_rendered', true);
      } catch (_) {}
      if (!mounted) return;
      // CHANGE #558 — bind to the one session holder. Every landing decision
      // (fresh sign-in, WhatsApp setSession, OAuth redirect completing on a
      // page load, or simply arriving here with a live session) is driven by
      // that notifier resolving, never by this screen guessing.
      final auth = UserState.read(context);
      _auth = auth;
      _api = SupabaseLoginApi(
        oauthFallback: auth.signInWithGoogleOAuth,
        auth: auth,
      );
      auth.addListener(_onSessionChanged);
      setState(() {}); // _api is now available to LoginView
      _onSessionChanged();
    });
  }

  /// Lands the user as soon as — and only when — the session has resolved for
  /// the auth user the SDK currently holds.
  void _onSessionChanged() {
    if (!mounted || _navigated) return;
    final auth = _auth;
    if (auth == null) return;
    final s = auth.session;
    if (s == null || !s.signedIn) return;
    if (!auth.sessionMatchesAuthUser) return; // RULE 4
    if (s.homeRoute.isEmpty) return;
    _goTo(s.homeRoute); // RULE 2 — home_route only
  }

  @override
  void dispose() {
    _auth?.removeListener(_onSessionChanged);
    super.dispose();
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
    final api = _api;
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Stack(
          children: [
            // LoginView owns its own full-height layout (wash band + thumb-reach
            // actions) and its own scrolling, so it must not be boxed here.
            // It goes first so the route back button paints above it.
            // Neutral until the session holder is bound — never a default
            // screen and never a guess (CHANGE #558 RULE 2).
            if (api == null)
              const Center(
                child: CircularProgressIndicator(
                    color: _green, strokeWidth: 3),
              )
            else
              Positioned.fill(child: LoginView(api: api, onHome: _goTo)),
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
