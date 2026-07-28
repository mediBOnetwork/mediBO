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

  /// CHANGE #559: flushed immediately — these keys mark branches that may be
  /// the last thing that runs before the browser leaves the app, so a debounced
  /// write would never reach Supabase.
  void _logNow(String k, String v) {
    try {
      RenderLog.writeNow(k, v);
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
    // CHANGE #559: instrumentation only — records WHICH branch actually ran,
    // flushed immediately so it survives the browser leaving the page.
    _logNow('c559_entry', 'login_screen');
    _logNow('c559_path', 'unknown');
    try {
      final (:idToken, :rawNonce) = await fedcmChooseAccount();
      _log('c557_path', 'fedcm_chooser');
      _logNow('c559_path', 'fedcm_chooser');
      await _finishIdToken(idToken, rawNonce);
      _log('c557_session', 'established');
      _logNow('c559_path', 'fedcm_chooser_signed_in');
      return;
    } on GisOneTapCancelled {
      // The user closed the chooser — do not cascade into a popup.
      _log('c557_path', 'fedcm_cancelled');
      _logNow('c559_path', 'fedcm_cancelled');
      return;
    } on GisOneTapUnavailable {
      _log('c557_fedcm', lastGisError());
      _logNow('c559_path', 'fedcm_error');
      _logNow('c559_fedcm_err', lastGisError());
    }

    // 2 — GIS One Tap, same in-page sheet but subject to Google's suppression.
    try {
      final (:idToken, :rawNonce) = await gisPromptOneTap();
      _log('c557_path', 'one_tap');
      _logNow('c559_path', 'one_tap');
      await _finishIdToken(idToken, rawNonce);
      _log('c557_session', 'established');
      _logNow('c559_path', 'one_tap_signed_in');
      return;
    } on GisOneTapCancelled {
      _log('c557_path', 'one_tap_cancelled');
      _logNow('c559_path', 'one_tap_cancelled');
      return;
    } on GisOneTapUnavailable {
      _log('c557_one_tap', 'unavailable');
    }

    // 3 — CHANGE #558: supabase.auth.signInWithOAuth.
    //
    // This step used to be gisSheetSignIn() — our own sheet hosting the GIS
    // button. That button hands control to the GIS library, which builds its
    // own accounts.google.com URL and sends the browser there WITHOUT ever
    // calling Supabase. The Supabase auth log proved it: the failing attempt
    // produced no /authorize request at all, and Google rejected the
    // GIS-built URL with "Access blocked: response_type missing".
    //
    // signInWithOAuth goes to Supabase's /authorize, which builds a complete,
    // correct URL (response_type included) and then redirects to Google. It is
    // now the only step permitted to navigate the browser off the page.
    _log('c558_path',
        isStandalonePwa() ? 'supabase_oauth_in_pwa' : 'supabase_oauth');
    // CHANGE #559: last line before anything is allowed to leave the app.
    _logNow('c559_path', 'oauth_called');
    await oauthFallback();
    _logNow('c559_oauth', 'returned_without_navigating');
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
        RenderLog.write('c557_prewarm', ok ? 'ready' : 'failed');
      } catch (_) {}
    }));

    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        RenderLog.write('c557_login_rendered', true);
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
