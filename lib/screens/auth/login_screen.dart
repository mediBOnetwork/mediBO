// CHANGE #554 — login screen wrapper.
//
// All UI and flow live in login_view.dart, which is platform-free and takes the
// backend contract through [LoginApi]. This file is the only place that knows
// about Supabase: it supplies the real RPC/edge-function calls, keeps the
// existing Google OAuth entry point unchanged, and performs the navigation to
// the backend's home_route.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../user_state.dart';
import '../../utils/render_log.dart';
import 'login_view.dart';

/// Supabase-backed implementation of the CHANGE #554 login contract.
class SupabaseLoginApi implements LoginApi {
  SupabaseLoginApi({required this.googleSignInImpl});

  /// The existing Google OAuth call — passed in so this class never reaches
  /// into the widget tree, and so the OAuth flow itself stays untouched.
  final Future<void> Function() googleSignInImpl;

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

  @override
  Future<void> googleSignIn() => googleSignInImpl();
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
      googleSignInImpl: () => UserState.read(context).signInWithGoogle(),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        RenderLog.write('c554_login_rendered', true);
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
            Center(
              child: SingleChildScrollView(
                padding:
                    const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: LoginView(api: _api, onHome: _goTo),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
