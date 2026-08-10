// CHANGE #554/#555 — login screen wrapper.
//
// All UI and flow live in login_view.dart, which is platform-free and takes the
// backend contract through [LoginApi]. This file is the only place that knows
// about Supabase: it supplies the real RPC/edge-function calls, drives the
// Google One Tap bottom sheet (falling back to the existing OAuth flow), and
// performs the navigation to the backend's home_route.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../app_state.dart';
import '../../services/ui_copy.dart';
import '../../models/cart_model.dart';
import '../../services/gis_auth.dart';
import 'google_flow.dart';
import '../../user_state.dart';
import '../../utils/render_log.dart';
import 'login_view.dart';

/// The Google Cloud WEB OAuth client id.
///
/// This is deliberately the WEB id, not the Android one: the native
/// google_sign_in flow needs the web client id as its serverClientId so the
/// id token it returns is audienced for the backend. The Android client id is
/// registered in Google Cloud against this app's signing certificate and the
/// plugin picks it up from there — it is NEVER passed from Dart, and must not be
/// hardcoded here.
const String kGoogleWebClientId =
    '565577322247-9ls2ocm01sjilq2sb17r5afm6se9jfr4.apps.googleusercontent.com';

/// Tokens from a native Google sign-in. [idToken] can be null if Google returns
/// an account without one (then we must not call Supabase); [accessToken] is
/// best-effort and optional for signInWithIdToken.
typedef NativeGoogleTokens = ({String? idToken, String? accessToken});

/// Runs the native Google sign-in for [serverClientId] and returns the tokens,
/// or null when the user cancels the sheet. Injected on [SupabaseLoginApi] so
/// the Android branch is testable without the plugin.
typedef NativeGoogleSignIn = Future<NativeGoogleTokens?> Function(
    String serverClientId);

/// The real native sign-in, using google_sign_in 7.x. Runs ONLY on Android (the
/// caller gates on the platform); on web this function is never invoked.
///
/// Cancellation is a null return, not an error — the login screen stays put and
/// shows nothing. Any other GoogleSignInException propagates so the caller can
/// surface its message.
Future<NativeGoogleTokens?> _defaultNativeGoogleSignIn(
    String serverClientId) async {
  final gsi = GoogleSignIn.instance;
  await gsi.initialize(serverClientId: serverClientId);

  final GoogleSignInAccount account;
  try {
    account = await gsi.authenticate(scopeHint: const ['email', 'profile']);
  } on GoogleSignInException catch (e) {
    // The user closed the sheet — an answer, not a failure.
    if (e.code == GoogleSignInExceptionCode.canceled) return null;
    rethrow;
  }

  final idToken = account.authentication.idToken;

  // Access token is optional for signInWithIdToken; fetch it without forcing a
  // second consent prompt, and never let its absence block sign-in.
  String? accessToken;
  try {
    final authz = await account.authorizationClient
        .authorizationForScopes(const ['email', 'profile']);
    accessToken = authz?.accessToken;
  } catch (_) {
    accessToken = null;
  }

  return (idToken: idToken, accessToken: accessToken);
}

/// Supabase-backed implementation of the CHANGE #554/#555 login contract.
class SupabaseLoginApi implements LoginApi {
  /// CHANGE #564: no oauthFallback. The browser path is gone entirely — nothing
  /// in the Google path may navigate away from the document. [oneTap] and
  /// [oneTap] are injectable purely so the escalation can be unit-tested.
  SupabaseLoginApi({
    Future<GoogleCredential> Function()? oneTap,
    Future<GoogleCredential> Function({
      required String title,
      required String subtitle,
      required String cancelLabel,
    })? popup,
    // Android native seam — all three injectable so the branch is unit-testable
    // with no plugin and no Supabase. In production they default to the real
    // platform detection, the real google_sign_in flow, and the real
    // signInWithIdToken.
    bool? isAndroid,
    NativeGoogleSignIn? nativeSignIn,
    Future<void> Function(String idToken, String? accessToken)? finishNative,
  })  : _oneTap = oneTap ?? gisPromptOneTap,
        _popup = popup ?? gisPopupSignIn,
        _isAndroid = isAndroid ?? (!kIsWeb && defaultTargetPlatform == TargetPlatform.android),
        _nativeSignIn = nativeSignIn ?? _defaultNativeGoogleSignIn,
        _finishNativeInjected = finishNative;

  final Future<GoogleCredential> Function() _oneTap;
  final Future<GoogleCredential> Function({
    required String title,
    required String subtitle,
    required String cancelLabel,
  }) _popup;

  /// Whether this build should take the native token flow instead of the web
  /// redirect/One Tap flow. Only true on a real Android app.
  final bool _isAndroid;
  final NativeGoogleSignIn _nativeSignIn;
  final Future<void> Function(String idToken, String? accessToken)?
      _finishNativeInjected;

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

  /// The native counterpart: no raw nonce (google_sign_in owns that), and the
  /// access token is passed through. Injectable so a test can assert the token
  /// without a live Supabase.
  Future<void> _finishNative(String idToken, String? accessToken) =>
      _finishNativeInjected != null
          ? _finishNativeInjected(idToken, accessToken)
          : _c.auth.signInWithIdToken(
              provider: OAuthProvider.google,
              idToken: idToken,
              accessToken: accessToken,
            );

  /// The Android native token flow. Kept entirely separate from the web path so
  /// nothing here can alter web behaviour.
  ///
  ///  * cancel  -> closed, no message (the user said no)
  ///  * no token -> suppressed, backend's [unavailableNote] (never invented)
  ///  * signed in -> signedIn
  ///  * auth error -> suppressed, the error's own message
  Future<GoogleResult> _googleSignInAndroid(String unavailableNote) async {
    _logNow('c668_native', 'android');
    final NativeGoogleTokens? tokens;
    try {
      tokens = await _nativeSignIn(kGoogleWebClientId);
    } catch (e) {
      _logNow('c668_native', 'signin_error');
      return (
        outcome: GoogleOutcome.suppressed,
        message: e is AuthException ? e.message : e.toString(),
      );
    }
    // Cancelled sheet — stay put, show nothing.
    if (tokens == null) {
      _logNow('c668_native', 'cancelled');
      return (outcome: GoogleOutcome.closed, message: null);
    }
    final idToken = tokens.idToken;
    if (idToken == null || idToken.isEmpty) {
      // No id token: do NOT call Supabase. Show the backend's own note.
      _logNow('c668_native', 'no_id_token');
      return (outcome: GoogleOutcome.suppressed, message: unavailableNote);
    }
    try {
      await _finishNative(idToken, tokens.accessToken);
      _logNow('c668_native', 'signed_in');
      return (outcome: GoogleOutcome.signedIn, message: null);
    } on AuthException catch (e) {
      _logNow('c668_native', 'auth_error');
      return (outcome: GoogleOutcome.suppressed, message: e.message);
    } catch (e) {
      _logNow('c668_native', 'error');
      return (outcome: GoogleOutcome.suppressed, message: e.toString());
    }
  }

  /// CHANGE #568: the One Tap sheet, with the GIS button popup when Google
  /// suppresses it. No browser path, no FedCM, no dead end.
  ///
  /// No FedCM, no GIS button popup, no signInWithOAuth — the Google button can
  /// no longer open any chooser other than the One Tap sheet, and cannot
  /// navigate the document away. g_state is cleared before every prompt() so a
  /// cancel never suppresses the next attempt.
  @override
  Future<GoogleResult> googleSignIn({
    required String sheetTitle,
    required String sheetSubtitle,
    required String otherAccount,
    required String unavailableNote,
  }) async {
    // Android takes the native token flow — the web redirect/One Tap sheet
    // cannot complete inside the APK. Everything below the gate is the existing
    // web path, untouched.
    if (_isAndroid) {
      return _googleSignInAndroid(unavailableNote);
    }

    _logNow('c559_entry', 'login_screen');
    _logNow('c568_origin', currentOrigin());
    final outcome = await runGoogleSignIn(
      oneTap: _oneTap,
      popup: () => _popup(
        title: sheetTitle,
        subtitle: sheetSubtitle,
        cancelLabel: otherAccount,
      ),
      finish: _finishIdToken,
      log: _logNow,
    );
    // Web never carries a message — same behaviour as before the record type.
    return (outcome: outcome, message: null);
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

  /// CHANGE #566 — resolved here, not inside the async landing step, so the
  /// cart is still reachable after the widget starts tearing down.
  CartModel? _cart;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    try {
      _cart = AppState.of(context);
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    _api = SupabaseLoginApi();

    // CHANGE #562: load + initialize GIS now, so the later tap can call
    // prompt() synchronously and keep its user activation. Fire-and-forget:
    // a failure here just means the tap falls straight through to OAuth.
    unawaited(gisPrewarm().then((ok) {
      try {
        RenderLog.write('c562_prewarm', ok ? 'ready' : 'failed');
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
    unawaited(_landOn(route));
  }

  /// CHANGE #566 — every login path reaches here after setSession and after
  /// my_session() has returned, so this is the one place where the cart can be
  /// loaded before home paints. Google navigates and re-boots the app, so boot
  /// fetched cart_state() for it; the WhatsApp OTP path sets the session in
  /// place with no reload, so without this the badge and the delivery bar
  /// landed empty until the cart screen was opened by hand.
  Future<void> _landOn(String route) async {
    final cart = _cart;
    if (cart != null) {
      try {
        // Bounded: a slow or failed cart_state() must never strand the user on
        // /login. The auth listener in CartModel refetches regardless.
        await cart
            .syncSignedInCart()
            .timeout(const Duration(milliseconds: 2500));
        RenderLog.write('c566_cart_before_home', cart.badge ?? '');
      } catch (_) {}
    }
    if (!mounted) return;
    _navigate(route);
  }

  void _navigate(String route) {
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
                tooltip: c('login.tooltip_back'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
