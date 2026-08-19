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
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../app_state.dart';
import '../../services/ui_copy.dart';
import '../../models/cart_model.dart';
import '../../services/gis_auth.dart';
import '../../services/signin_diag.dart';
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

/// CHANGE #275 — records one failed sign-in attempt and returns the backend's
/// advice on what (if anything) to show. Matches [SignInDiag.note].
typedef DiagNote = Future<DiagAdvice?> Function({
  required String stage,
  required String code,
  String? description,
  String? details,
  int? elapsedMs,
});

/// The real native sign-in, using google_sign_in 7.x. Runs ONLY on Android (the
/// caller gates on the platform); on web this function is never invoked.
///
/// CHANGE #275 — NOTHING is swallowed here any more. It used to convert
/// `GoogleSignInExceptionCode.canceled` into a null return ("the user said
/// no"), and that is precisely how the Play-build failure went silent: Android
/// Credential Manager reports a provider-side refusal — including an app whose
/// signing certificate is not on a registered Android OAuth client — as a
/// GetCredentialCancellationException, which the plugin maps to `canceled`.
/// The account sheet appears, the user picks an account, the provider fails,
/// and the app called it a cancellation. Every exception now reaches the
/// caller, which records the real code and asks the backend what to say.
Future<NativeGoogleTokens?> _defaultNativeGoogleSignIn(
    String serverClientId) async {
  final gsi = GoogleSignIn.instance;
  await gsi.initialize(serverClientId: serverClientId);

  final GoogleSignInAccount account =
      await gsi.authenticate(scopeHint: const ['email', 'profile']);

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
    // CHANGE #275 — the failure recorder, injectable so the protected test can
    // assert the exact code that gets recorded with no Supabase behind it.
    DiagNote? diagNote,
  })  : _oneTap = oneTap ?? gisPromptOneTap,
        _popup = popup ?? gisPopupSignIn,
        _isAndroid = isAndroid ?? (!kIsWeb && defaultTargetPlatform == TargetPlatform.android),
        _nativeSignIn = nativeSignIn ?? _defaultNativeGoogleSignIn,
        _finishNativeInjected = finishNative,
        _diagNote = diagNote ?? SignInDiag.note;

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
  final DiagNote _diagNote;

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

  /// Records a failed attempt and turns the backend's advice into the result
  /// this screen renders. CHANGE #275.
  ///
  /// The RULE: the platform's own [code] is what gets recorded — never a
  /// rewording, never a swallow — and the sentence the user reads is whatever
  /// `auth_diag_note` sends back. When the backend has nothing to say (offline,
  /// or `show:false` for a genuine cancellation) we fall back to [fallback],
  /// which is itself a backend string.
  Future<GoogleResult> _recordAndReport({
    required String stage,
    required String code,
    required GoogleOutcome outcome,
    String? description,
    String? details,
    int? elapsedMs,
    String? fallback,
  }) async {
    final advice = await _diagNote(
      stage: stage,
      code: code,
      description: description,
      details: details,
      elapsedMs: elapsedMs,
    );
    if (advice != null && advice.show && advice.message != null) {
      // The backend chose to speak: its sentence wins, and it carries the code.
      return (outcome: GoogleOutcome.suppressed, message: advice.message);
    }
    return (outcome: outcome, message: fallback);
  }

  /// The Android native token flow. Kept entirely separate from the web path so
  /// nothing here can alter web behaviour.
  ///
  /// CHANGE #275 — every exit that is not `signedIn` is RECORDED with the real
  /// platform code before anything is decided, so a silent failure is now
  /// impossible: even a cancellation the user never made leaves a row in
  /// `auth_diag` carrying the code, the description, the app version and the
  /// running APK's signing SHA-1.
  ///
  ///  * cancel     -> whatever the backend says for `canceled` (closed if silent)
  ///  * no token   -> suppressed, backend's [unavailableNote] (never invented)
  ///  * signed in  -> signedIn
  ///  * auth error -> suppressed, the backend's sentence for the code
  Future<GoogleResult> _googleSignInAndroid(String unavailableNote) async {
    _logNow('c668_native', 'android');
    final sw = Stopwatch()..start();
    final NativeGoogleTokens? tokens;
    try {
      tokens = await _nativeSignIn(kGoogleWebClientId);
    } on GoogleSignInException catch (e) {
      // THE bug this command exists for: `canceled` is what Credential Manager
      // reports when the Google provider itself refuses (an unregistered
      // signing certificate, most often), and it used to be treated as the
      // user saying no. It is now recorded like any other failure.
      _logNow('c668_native', 'gsi_${e.code.name}');
      return _recordAndReport(
        stage: 'authenticate',
        code: e.code.name,
        outcome: e.code == GoogleSignInExceptionCode.canceled
            ? GoogleOutcome.closed
            : GoogleOutcome.suppressed,
        description: e.description,
        details: e.details?.toString(),
        elapsedMs: sw.elapsedMilliseconds,
        fallback: e.code == GoogleSignInExceptionCode.canceled
            ? null
            : (e.description ?? e.code.name),
      );
    } on PlatformException catch (e) {
      // MissingPluginException lands here too — that is what a release build
      // that stripped the plugin looks like from Dart.
      _logNow('c668_native', 'platform_error');
      return _recordAndReport(
        stage: 'authenticate',
        code: e is MissingPluginException ? 'plugin_missing' : 'platform_error',
        outcome: GoogleOutcome.suppressed,
        description: e.message,
        details: '${e.code} ${e.details ?? ''}'.trim(),
        elapsedMs: sw.elapsedMilliseconds,
        fallback: e.message ?? e.code,
      );
    } catch (e) {
      _logNow('c668_native', 'signin_error');
      return _recordAndReport(
        stage: 'authenticate',
        code: e is MissingPluginException ? 'plugin_missing' : 'unknownError',
        outcome: GoogleOutcome.suppressed,
        description: e.toString(),
        elapsedMs: sw.elapsedMilliseconds,
        fallback: e is AuthException ? e.message : e.toString(),
      );
    }
    // A null return from the injected seam still means the sheet was closed —
    // recorded, because we cannot tell a real cancellation from a refused one.
    if (tokens == null) {
      _logNow('c668_native', 'cancelled');
      return _recordAndReport(
        stage: 'authenticate',
        code: 'canceled',
        outcome: GoogleOutcome.closed,
        description: 'native sign-in returned no account',
        elapsedMs: sw.elapsedMilliseconds,
      );
    }
    final idToken = tokens.idToken;
    if (idToken == null || idToken.isEmpty) {
      // No id token: do NOT call Supabase. Show the backend's own note.
      _logNow('c668_native', 'no_id_token');
      return _recordAndReport(
        stage: 'id_token',
        code: 'no_id_token',
        outcome: GoogleOutcome.suppressed,
        description: 'account returned without an id token',
        elapsedMs: sw.elapsedMilliseconds,
        fallback: unavailableNote,
      );
    }
    try {
      await _finishNative(idToken, tokens.accessToken);
      _logNow('c668_native', 'signed_in');
      return (outcome: GoogleOutcome.signedIn, message: null);
    } on AuthException catch (e) {
      _logNow('c668_native', 'auth_error');
      return _recordAndReport(
        stage: 'supabase',
        code: 'supabase_auth_error',
        outcome: GoogleOutcome.suppressed,
        description: e.message,
        details: e.statusCode,
        elapsedMs: sw.elapsedMilliseconds,
        fallback: e.message,
      );
    } catch (e) {
      _logNow('c668_native', 'error');
      return _recordAndReport(
        stage: 'supabase',
        code: 'unknownError',
        outcome: GoogleOutcome.suppressed,
        description: e.toString(),
        elapsedMs: sw.elapsedMilliseconds,
        fallback: e.toString(),
      );
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

/// The passwordless [LoginView] hosted inside the desktop right-side slide-in
/// panel (see `LoginPanel` in home_shell) instead of a full-screen route.
///
/// It carries its own [SupabaseLoginApi] + auth harness so the WhatsApp/Google
/// flows behave EXACTLY as in [LoginScreen]; on a successful sign-in it closes
/// the hosting panel and lands the user on their backend `home_route`. This is
/// what keeps the web login layout identical to mobile while preserving the
/// half-screen panel presentation (no full-screen redirect).
class LoginPanelView extends StatefulWidget {
  const LoginPanelView({super.key, required this.onClose});

  /// Closes the hosting panel (backdrop tap, the ✕, and after a sign-in).
  final VoidCallback onClose;

  @override
  State<LoginPanelView> createState() => _LoginPanelViewState();
}

class _LoginPanelViewState extends State<LoginPanelView> {
  late final SupabaseLoginApi _api;
  StreamSubscription<AuthState>? _authSub;
  CartModel? _cart;
  bool _landed = false;

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

    // Warm GIS so the Google tap can prompt() synchronously (same as LoginScreen).
    unawaited(gisPrewarm().then((ok) {
      try {
        RenderLog.write('c562_prewarm', ok ? 'ready' : 'failed');
      } catch (_) {}
    }));

    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        RenderLog.write('loginpanel_rendered', true);
      } catch (_) {}
      // Already signed in (panel opened with a live session): land immediately.
      try {
        if (mounted && Supabase.instance.client.auth.currentUser != null) {
          _resolveHome();
        }
      } catch (_) {}
    });

    // OAuth PKCE / One Tap setSession / WhatsApp OTP all surface as signedIn.
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

  /// Asks the backend where this user belongs, then lands there.
  Future<void> _resolveHome() async {
    if (_landed) return;
    try {
      final s = await _api.session();
      if (!mounted) return;
      if (s['signed_in'] != true) return;
      final route = (s['home_route'] as String?) ?? '';
      if (route.isEmpty) return;
      await _land(route);
    } catch (_) {
      // No local error copy — the view keeps showing the last backend message.
    }
  }

  /// Loads the signed-in cart (bounded), closes the panel, and navigates to the
  /// backend home_route — mirrors _LoginScreenState._landOn so WhatsApp/Google
  /// behave the same whether login is a full screen or this panel.
  Future<void> _land(String route) async {
    if (_landed) return;
    _landed = true;
    final cart = _cart;
    if (cart != null) {
      try {
        await cart
            .syncSignedInCart()
            .timeout(const Duration(milliseconds: 2500));
        RenderLog.write('c566_cart_before_home', cart.badge ?? '');
      } catch (_) {}
    }
    if (!mounted) return;
    widget.onClose();
    try {
      Navigator.of(context).pushNamedAndRemoveUntil(route, (r) => false);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    // LoginView owns its own full-height layout (wash band + thumb-reach
    // actions). The panel gives it a bounded (panelW × viewport-height) box, so
    // it renders exactly like mobile, just within the 420px panel.
    return LoginView(api: _api, onHome: (route) {
      _land(route);
    });
  }
}
