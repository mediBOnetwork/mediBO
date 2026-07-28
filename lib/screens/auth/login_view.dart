// CHANGE #554 — login screen, 100% backend-driven.
//
// This file holds ZERO login logic:
//   • every label comes from login_screen_config()
//   • every message comes from a backend `message` field, rendered verbatim
//   • the post-login destination is home_route from my_session()
//
// There is no client-side validation, no role→route map, no user-facing string
// literal and no password / forgot-password UI. Field visibility is driven by
// show_password / show_forgot_password.
//
// Deliberately imports nothing but flutter/material: every backend call is
// injected through [LoginApi] so the widget test can stub the contract without
// a network or a Supabase instance. The Supabase-backed implementation lives in
// login_screen.dart.

import 'dart:async';

import 'package:flutter/material.dart';

/// The backend contract this screen renders. One method per RPC.
abstract class LoginApi {
  /// rpc login_screen_config()
  Future<Map<String, dynamic>> config();

  /// rpc login_request_otp(p_input)
  Future<Map<String, dynamic>> requestOtp(String input);

  /// rpc login_otp_status(p_input)
  Future<Map<String, dynamic>> otpStatus(String input);

  /// rpc login_verify_otp(p_input, p_code)
  Future<Map<String, dynamic>> verifyOtp(String input, String code);

  /// POST [body] as JSON to [url] with Content-Type only — no auth header.
  Future<Map<String, dynamic>> postNext(String url, Map<String, dynamic> body);

  /// supabase.auth.setSession(refreshToken)
  Future<void> setSession(String refreshToken);

  /// rpc my_session()
  Future<Map<String, dynamic>> session();

  /// The existing Google OAuth call — unchanged by CHANGE #554.
  Future<void> googleSignIn();
}

class LoginView extends StatefulWidget {
  const LoginView({
    super.key,
    required this.api,
    required this.onHome,
    this.pollInterval = const Duration(seconds: 2),
    this.pollTimeout = const Duration(seconds: 15),
  });

  final LoginApi api;

  /// Called with home_route from my_session() once a session exists.
  final void Function(String homeRoute) onHome;

  /// login_otp_status poll cadence and overall budget (overridable for tests).
  final Duration pollInterval;
  final Duration pollTimeout;

  @override
  State<LoginView> createState() => _LoginViewState();
}

class _LoginViewState extends State<LoginView> {
  static const _green = Color(0xFF1B5E20);

  Map<String, dynamic>? _cfg;
  bool _cfgFailed = false;

  /// The last message the backend sent us. Never replaced by local copy.
  String? _message;

  final _numCtrl = TextEditingController();
  final _otpCtrl = TextEditingController();

  bool _waOpen = false;
  bool _googleBusy = false;
  bool _sending = false;
  bool _sendCooling = false;
  bool _otpEnabled = false;
  bool _verifying = false;

  /// The exact input that was sent, so status polling and verify address the
  /// same identity even if the user edits the field afterwards.
  String _sentInput = '';

  Timer? _pollTimer;
  Timer? _coolTimer;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _coolTimer?.cancel();
    _numCtrl.dispose();
    _otpCtrl.dispose();
    super.dispose();
  }

  // ── Config ─────────────────────────────────────────────────────────────────

  Future<void> _loadConfig() async {
    try {
      final c = await widget.api.config();
      if (!mounted) return;
      setState(() {
        _cfg = c;
        _cfgFailed = false;
      });
    } catch (_) {
      // No local error copy — offer a retry affordance instead.
      if (mounted) setState(() => _cfgFailed = true);
    }
  }

  String _label(String key) => (_cfg?[key] as String?) ?? '';

  bool _flag(String key) => _cfg?[key] == true;

  /// Assigns a backend message only when there is one, so a response without a
  /// `message` never wipes the last thing the backend told the user.
  void _setMessage(dynamic m) {
    if (m is String && m.isNotEmpty) _message = m;
  }

  // ── Google ─────────────────────────────────────────────────────────────────

  Future<void> _google() async {
    if (_googleBusy) return;
    setState(() => _googleBusy = true);
    try {
      await widget.api.googleSignIn();
      if (!mounted) return;
      await _goHome();
    } catch (_) {
      // Keep whatever the backend last said; never invent error copy.
    } finally {
      if (mounted) setState(() => _googleBusy = false);
    }
  }

  // ── WhatsApp: send ─────────────────────────────────────────────────────────

  Future<void> _send() async {
    if (_sending || _sendCooling) return;
    final input = _numCtrl.text;
    setState(() => _sending = true);

    Map<String, dynamic> r;
    try {
      r = await widget.api.requestOtp(input);
    } catch (_) {
      if (mounted) setState(() => _sending = false);
      return;
    }
    if (!mounted) return;

    final ok = r['ok'] == true;
    setState(() {
      _setMessage(r['message']);
      _sending = false;
      if (!ok) _otpEnabled = false;
    });
    // ok:false — nothing was sent. Row 2 stays disabled; send stays tappable so
    // the user can act on whatever the backend just told them.
    if (!ok) return;

    _sentInput = input;
    final ttl = (r['ttl_seconds'] as num?)?.toInt();
    setState(() => _sendCooling = true);
    _coolTimer?.cancel();
    if (ttl != null && ttl > 0) {
      _coolTimer = Timer(Duration(seconds: ttl), () {
        if (mounted) setState(() => _sendCooling = false);
      });
    }
    _startPolling(input);
  }

  void _startPolling(String input) {
    _pollTimer?.cancel();
    var elapsed = Duration.zero;
    _pollTimer = Timer.periodic(widget.pollInterval, (t) async {
      elapsed += widget.pollInterval;
      final expired = elapsed >= widget.pollTimeout;

      Map<String, dynamic> r;
      try {
        r = await widget.api.otpStatus(input);
      } catch (_) {
        if (expired) t.cancel();
        return;
      }
      if (!mounted) {
        t.cancel();
        return;
      }

      final state = r['state'] as String?;
      setState(() => _setMessage(r['message']));

      if (state == 'sent') {
        t.cancel();
        setState(() => _otpEnabled = true);
      } else if (state == 'failed') {
        t.cancel();
        _coolTimer?.cancel();
        setState(() {
          _otpEnabled = false;
          _sendCooling = false;
        });
      } else if (state != 'sending' || expired) {
        // 'none', anything unrecognised, or out of budget — stop polling.
        t.cancel();
      }
    });
  }

  // ── WhatsApp: verify ───────────────────────────────────────────────────────

  Future<void> _verify() async {
    if (_verifying || !_otpEnabled) return;
    setState(() => _verifying = true);
    try {
      final v = await widget.api.verifyOtp(_sentInput, _otpCtrl.text);
      if (!mounted) return;
      setState(() => _setMessage(v['message']));
      if (v['ok'] != true) {
        setState(() => _verifying = false);
        return;
      }

      final next = (v['next'] as Map?)?.cast<String, dynamic>();
      final url = next?['url'] as String?;
      final body = (next?['body'] as Map?)?.cast<String, dynamic>();
      if (url == null || url.isEmpty || body == null) {
        setState(() => _verifying = false);
        return;
      }

      final res = await widget.api.postNext(url, body);
      if (!mounted) return;

      if (res['ok'] == true) {
        final refresh = res['refresh_token'] as String?;
        if (refresh != null && refresh.isNotEmpty) {
          await widget.api.setSession(refresh);
        }
        if (!mounted) return;
        await _goHome();
        return;
      }
      setState(() {
        _setMessage(res['message']);
        _verifying = false;
      });
    } catch (_) {
      if (mounted) setState(() => _verifying = false);
    }
  }

  // ── Post-login destination ─────────────────────────────────────────────────

  Future<void> _goHome() async {
    Map<String, dynamic> s;
    try {
      s = await widget.api.session();
    } catch (_) {
      return;
    }
    if (!mounted) return;
    setState(() => _setMessage(s['message']));
    // Only leave the screen once the backend says a session exists; otherwise
    // home_route is the login route itself.
    if (s['signed_in'] != true) return;
    final route = s['home_route'] as String?;
    if (route == null || route.isEmpty) return;
    widget.onHome(route);
  }

  // ── UI ─────────────────────────────────────────────────────────────────────

  InputDecoration _fieldDec(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Color(0xFFD1D5DB)),
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFFD1D5DB))),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFFD1D5DB))),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: _green, width: 1.5)),
        disabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
      );

  Widget _spinner(Color c) => SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(color: c, strokeWidth: 2.5),
      );

  Widget _bigButton({
    required String label,
    required VoidCallback onPressed,
    required bool busy,
    Widget? icon,
    bool outlined = false,
  }) =>
      SizedBox(
        height: 54,
        child: outlined
            ? OutlinedButton(
                onPressed: onPressed,
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF111827),
                  side: const BorderSide(color: Color(0xFFD1D5DB)),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                child: busy
                    ? _spinner(_green)
                    : _btnRow(label, icon, const Color(0xFF111827)),
              )
            : FilledButton(
                onPressed: onPressed,
                style: FilledButton.styleFrom(
                  backgroundColor: _green,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                  elevation: 0,
                ),
                child: busy
                    ? _spinner(Colors.white)
                    : _btnRow(label, icon, Colors.white),
              ),
      );

  Widget _btnRow(String label, Widget? icon, Color color) => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[icon, const SizedBox(width: 10)],
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w600, color: color),
            ),
          ),
        ],
      );

  Widget _smallButton({
    required String label,
    required VoidCallback? onPressed,
    required bool busy,
  }) =>
      SizedBox(
        height: 48,
        child: FilledButton(
          onPressed: onPressed,
          style: FilledButton.styleFrom(
            backgroundColor: _green,
            foregroundColor: Colors.white,
            disabledBackgroundColor: const Color(0xFFD1D5DB),
            disabledForegroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            elevation: 0,
          ),
          child: busy
              ? _spinner(Colors.white)
              : Text(label,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600)),
        ),
      );

  @override
  Widget build(BuildContext context) {
    if (_cfg == null) {
      return Center(
        child: _cfgFailed
            ? IconButton(
                icon: const Icon(Icons.refresh, color: _green),
                onPressed: () {
                  setState(() => _cfgFailed = false);
                  _loadConfig();
                },
              )
            : const CircularProgressIndicator(color: _green),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Center(child: MediBoLogo()),
        const SizedBox(height: 24),
        Text(_label('brand'),
            textAlign: TextAlign.center,
            style: const TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w800,
                color: Color(0xFF111827),
                letterSpacing: -0.5)),
        const SizedBox(height: 6),
        Text(_label('tagline'),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 15, color: Color(0xFF6B7280))),
        const SizedBox(height: 36),

        _bigButton(
          label: _label('google_label'),
          onPressed: _google,
          busy: _googleBusy,
          outlined: true,
          icon: const Icon(Icons.g_mobiledata, size: 28, color: _green),
        ),
        const SizedBox(height: 12),
        _bigButton(
          label: _label('whatsapp_label'),
          onPressed: () => setState(() => _waOpen = !_waOpen),
          busy: false,
          icon: const Icon(Icons.chat_bubble_outline,
              size: 18, color: Colors.white),
        ),

        // Inline dropdown — no new route.
        if (_waOpen) _waPanel(),

        // show_password / show_forgot_password are backend flags. When false —
        // as they are today — nothing below is built at all.
        if (_flag('show_password')) ...[
          const SizedBox(height: 12),
          TextField(
            obscureText: true,
            style: const TextStyle(fontSize: 15),
            decoration: _fieldDec(_label('password_hint')),
          ),
        ],
        if (_flag('show_forgot_password')) ...[
          const SizedBox(height: 10),
          Center(
            child: Text(_label('forgot_password_label'),
                style: const TextStyle(
                    fontSize: 13,
                    color: _green,
                    fontWeight: FontWeight.w600,
                    decoration: TextDecoration.underline)),
          ),
        ],

        if (_message != null) ...[
          const SizedBox(height: 16),
          Text(_message!,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 13, color: Color(0xFF374151), height: 1.4)),
        ],
      ],
    );
  }

  Widget _waPanel() => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Row 1 — prefix, number, send.
            Row(
              children: [
                Container(
                  height: 48,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: const Color(0xFFF3F4F6),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFFD1D5DB)),
                  ),
                  child: Text(_label('number_prefix'),
                      style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF374151))),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _numCtrl,
                    keyboardType: TextInputType.phone,
                    style: const TextStyle(fontSize: 15),
                    decoration: _fieldDec(_label('number_hint')),
                  ),
                ),
                const SizedBox(width: 8),
                _smallButton(
                  label: _label('send_label'),
                  onPressed: _sendCooling ? null : _send,
                  busy: _sending,
                ),
              ],
            ),
            const SizedBox(height: 10),
            // Row 2 — OTP, verify. Disabled until row 1 has succeeded.
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _otpCtrl,
                    enabled: _otpEnabled,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(fontSize: 15),
                    decoration: _fieldDec(_label('otp_hint')),
                  ),
                ),
                const SizedBox(width: 8),
                _smallButton(
                  label: _label('verify_label'),
                  onPressed: _otpEnabled ? _verify : null,
                  busy: _verifying,
                ),
              ],
            ),
          ],
        ),
      );
}

/// mediBO wordmark — unchanged from the previous login screen.
class MediBoLogo extends StatelessWidget {
  const MediBoLogo({super.key});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Image.asset('assets/images/medibo_logo.png', width: 48, height: 48),
        const SizedBox(width: 10),
        RichText(
          text: const TextSpan(
            children: [
              TextSpan(
                text: 'medi',
                style: TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF1B5E20),
                  letterSpacing: -0.3,
                ),
              ),
              TextSpan(
                text: 'BO',
                style: TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF4CAF50),
                  letterSpacing: -0.3,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
