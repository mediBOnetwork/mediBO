// CHANGE #555 — login screen redesign.
//
// Layout: a soft green wash band at the top holds the logo tile, wordmark and
// tagline; the actions sit at the bottom in thumb reach. WhatsApp is the
// primary (filled) action, Google the secondary (outlined) one.
//
// The WhatsApp flow is progressive and inline — no new route. Tapping the
// primary button reveals the number step, which on a successful send reveals
// the code step. Nothing disabled is visible on first paint.
//
// Flutter still holds ZERO login logic: every string comes from
// login_screen_config(), every message is a backend `message` rendered
// verbatim, and the destination is home_route from my_session().
//
// Deliberately imports nothing but flutter/material + services (for the input
// formatter): every backend call is injected through [LoginApi], so the widget
// test can stub the contract with no network and no Supabase instance.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'google_flow.dart';

export 'google_flow.dart' show GoogleOutcome;

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

  /// Google One Tap. The labels are passed through so no Google copy is ever
  /// invented client-side.
  ///
  /// CHANGE #564: returns what actually happened. NOTHING here may navigate —
  /// there is no browser path at all any more.
  Future<GoogleOutcome> googleSignIn({
    required String sheetTitle,
    required String sheetSubtitle,
    required String otherAccount,
  });

}

/// Which part of the progressive WhatsApp flow is on screen.
enum LoginStep { actions, number, code }

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

  final Duration pollInterval;
  final Duration pollTimeout;

  @override
  State<LoginView> createState() => _LoginViewState();
}

class _LoginViewState extends State<LoginView> {
  static const _green = Color(0xFF1B5E20);
  static const _wash = Color(0xFFEEF8F1);
  static const _ink = Color(0xFF111827);
  static const _muted = Color(0xFF6B7280);
  static const _line = Color(0xFFD1D5DB);
  static const _danger = Color(0xFFDC2626);

  Map<String, dynamic>? _cfg;
  bool _cfgFailed = false;

  /// The last message the backend sent. Never replaced by local copy.
  String? _message;

  LoginStep _step = LoginStep.actions;

  final _numCtrl = TextEditingController();
  final _numFocus = FocusNode();
  List<TextEditingController> _codeCtrls = const [];
  List<FocusNode> _codeFocus = const [];

  bool _googleBusy = false;

  bool _sending = false;
  bool _verifying = false;
  bool _codeError = false;

  /// Raw digits of the number that was actually sent, so polling and verify
  /// address the same identity even if the field is edited afterwards.
  String _sentDigits = '';

  int _resendLeft = 0;
  Timer? _pollTimer;
  Timer? _resendTimer;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _resendTimer?.cancel();
    _numCtrl.dispose();
    _numFocus.dispose();
    for (final c in _codeCtrls) {
      c.dispose();
    }
    for (final f in _codeFocus) {
      f.dispose();
    }
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

  String _s(String key) => (_cfg?[key] as String?) ?? '';

  int get _codeDigits => (_cfg?['code_digits'] as num?)?.toInt() ?? 0;

  int get _resendSeconds => (_cfg?['resend_seconds'] as num?)?.toInt() ?? 0;

  /// Assigns a backend message only when there is one, so a response without a
  /// `message` never wipes the last thing the backend told the user.
  void _setMessage(dynamic m) {
    if (m is String && m.isNotEmpty) _message = m;
  }

  String get _digits => _numCtrl.text.replaceAll(RegExp(r'\D'), '');

  static String _format5x5(String digits) => digits.length > 5
      ? '${digits.substring(0, 5)} ${digits.substring(5)}'
      : digits;

  Duration _reveal(BuildContext context) =>
      MediaQuery.of(context).disableAnimations
          ? Duration.zero
          : const Duration(milliseconds: 320);

  // ── Google ─────────────────────────────────────────────────────────────────

  Future<void> _google() async {
    if (_googleBusy) return;
    setState(() => _googleBusy = true);
    try {
      // No await before this call — the One Tap sheet only displays while the
      // tap's user activation is still live.
      final outcome = await widget.api.googleSignIn(
        sheetTitle: _s('google_sheet_title'),
        sheetSubtitle: _s('google_sheet_subtitle'),
        otherAccount: _s('google_other_account'),
      );
      if (!mounted) return;
      switch (outcome) {
        case GoogleOutcome.signedIn:
          await _goHome();
        case GoogleOutcome.closed:
          // CHANGE #563: the user said no. Stay put, button re-enables below.
          break;
        case GoogleOutcome.suppressed:
          // CHANGE #568: the note is gone. With the popup restored the only way
          // to land here is both the sheet AND the popup failing, which leaves
          // nothing useful to say — and never a navigation.
          break;
      }
    } catch (_) {
      // Keep whatever the backend last said; never invent error copy.
    } finally {
      if (mounted) setState(() => _googleBusy = false);
    }
  }

  // ── Step transitions ───────────────────────────────────────────────────────

  void _openNumber() {
    setState(() {
      _step = LoginStep.number;
      _message = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _numFocus.requestFocus();
    });
  }

  void _backToActions() {
    _pollTimer?.cancel();
    _resendTimer?.cancel();
    setState(() {
      _step = LoginStep.actions;
      _message = null;
      _codeError = false;
      _sending = false;
    });
  }

  void _buildCodeFields() {
    for (final c in _codeCtrls) {
      c.dispose();
    }
    for (final f in _codeFocus) {
      f.dispose();
    }
    final n = _codeDigits;
    _codeCtrls = List.generate(n, (_) => TextEditingController());
    _codeFocus = List.generate(n, (_) => FocusNode());
  }

  void _openCode() {
    _buildCodeFields();
    setState(() {
      _step = LoginStep.code;
      _codeError = false;
    });
    _startResendCountdown();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _codeFocus.isNotEmpty) _codeFocus.first.requestFocus();
    });
  }

  void _startResendCountdown() {
    _resendTimer?.cancel();
    setState(() => _resendLeft = _resendSeconds);
    if (_resendLeft <= 0) return;
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _resendLeft--);
      if (_resendLeft <= 0) t.cancel();
    });
  }

  // ── Send ───────────────────────────────────────────────────────────────────

  Future<void> _send() async {
    if (_sending) return;
    final digits = _digits;
    setState(() => _sending = true);

    Map<String, dynamic> r;
    try {
      r = await widget.api.requestOtp(digits);
    } catch (_) {
      if (mounted) setState(() => _sending = false);
      return;
    }
    if (!mounted) return;

    final ok = r['ok'] == true;
    setState(() {
      _setMessage(r['message']);
      if (!ok) _sending = false;
    });
    // ok:false — nothing was sent. Stay on the number step and show why.
    if (!ok) return;

    _sentDigits = digits;
    _startPolling(digits);
  }

  void _startPolling(String digits) {
    _pollTimer?.cancel();
    var elapsed = Duration.zero;
    _pollTimer = Timer.periodic(widget.pollInterval, (t) async {
      elapsed += widget.pollInterval;
      final expired = elapsed >= widget.pollTimeout;

      Map<String, dynamic> r;
      try {
        r = await widget.api.otpStatus(digits);
      } catch (_) {
        if (expired) {
          t.cancel();
          if (mounted) setState(() => _sending = false);
        }
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
        setState(() => _sending = false);
        _openCode();
      } else if (state == 'failed') {
        // Show the backend's message and re-enable send.
        t.cancel();
        setState(() => _sending = false);
      } else if (state != 'sending' || expired) {
        // 'none', anything unrecognised, or out of budget — stop and re-enable.
        t.cancel();
        setState(() => _sending = false);
      }
    });
  }

  Future<void> _resend() async {
    if (_resendLeft > 0 || _sending) return;
    final digits = _sentDigits.isEmpty ? _digits : _sentDigits;
    setState(() => _sending = true);
    Map<String, dynamic> r;
    try {
      r = await widget.api.requestOtp(digits);
    } catch (_) {
      if (mounted) setState(() => _sending = false);
      return;
    }
    if (!mounted) return;
    setState(() {
      _setMessage(r['message']);
      _sending = false;
    });
    if (r['ok'] == true) {
      _sentDigits = digits;
      _startResendCountdown();
      _startPolling(digits);
    }
  }

  // ── Verify ─────────────────────────────────────────────────────────────────

  String get _code => _codeCtrls.map((c) => c.text).join();

  Future<void> _verify() async {
    if (_verifying) return;
    setState(() {
      _verifying = true;
      _codeError = false;
    });
    try {
      final v = await widget.api.verifyOtp(_sentDigits, _code);
      if (!mounted) return;
      setState(() => _setMessage(v['message']));
      if (v['ok'] != true) {
        setState(() {
          _verifying = false;
          _codeError = true;
        });
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
        _codeError = true;
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
    // Only leave once the backend says a session exists; otherwise home_route
    // is the login route itself.
    if (s['signed_in'] != true) return;
    final route = s['home_route'] as String?;
    if (route == null || route.isEmpty) return;
    widget.onHome(route);
  }

  // ── Build ──────────────────────────────────────────────────────────────────

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

    return LayoutBuilder(
      builder: (context, cons) {
        final bandH = (cons.maxHeight * 0.34).clamp(150.0, 320.0);
        return Column(
          children: [
            _topBand(bandH),
            Expanded(
              // reverse keeps the actions in thumb reach and still scrolls
              // once the revealed steps or the keyboard need the room.
              child: SingleChildScrollView(
                reverse: true,
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: AnimatedSize(
                      duration: _reveal(context),
                      curve: Curves.easeOutCubic,
                      alignment: Alignment.bottomCenter,
                      child: _stepBlock(),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _topBand(double height) => Container(
        height: height,
        width: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [_wash, Color(0x00EEF8F1)],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 76,
                height: 76,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x14000000),
                      blurRadius: 18,
                      offset: Offset(0, 6),
                    ),
                  ],
                ),
                padding: const EdgeInsets.all(12),
                child: Image.asset('assets/images/medibo_logo.png'),
              ),
              const SizedBox(height: 16),
              _wordmark(_s('brand')),
              const SizedBox(height: 6),
              Text(
                _s('tagline'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14.5, color: _muted),
              ),
            ],
          ),
        ),
      );

  /// Renders the brand with the trailing two characters accented, matching the
  /// existing mediBO wordmark without hardcoding the name itself.
  Widget _wordmark(String brand) {
    final split = brand.length > 2 ? brand.length - 2 : brand.length;
    return RichText(
      text: TextSpan(
        children: [
          TextSpan(
            text: brand.substring(0, split),
            style: const TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w700,
              color: _green,
              letterSpacing: -0.3,
            ),
          ),
          TextSpan(
            text: brand.substring(split),
            style: const TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w800,
              color: Color(0xFF4CAF50),
              letterSpacing: -0.3,
            ),
          ),
        ],
      ),
    );
  }

  Widget _stepBlock() {
    switch (_step) {
      case LoginStep.actions:
        return _actionsBlock();
      case LoginStep.number:
        return _numberBlock();
      case LoginStep.code:
        return _codeBlock();
    }
  }

  // ── Blocks ─────────────────────────────────────────────────────────────────

  Widget _actionsBlock() => Column(
        key: const ValueKey('actions'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _primaryButton(
            label: _s('whatsapp_label'),
            onPressed: _openNumber,
            busy: false,
          ),
          const SizedBox(height: 12),
          _secondaryButton(
            label: _s('google_label'),
            onPressed: _google,
            busy: _googleBusy,
          ),
          const SizedBox(height: 18),
          _footer(),
          if (_message != null) ...[
            const SizedBox(height: 12),
            _messageText(),
          ],
        ],
      );

  Widget _numberBlock() => Column(
        key: const ValueKey('number'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sectionHeader(_s('number_section_label')),
          const SizedBox(height: 10),
          _numberField(),
          const SizedBox(height: 14),
          _primaryButton(
            label: _sending ? _s('sending_label') : _s('send_label'),
            onPressed: _send,
            busy: _sending,
          ),
          if (_message != null) ...[
            const SizedBox(height: 14),
            _messageText(),
          ],
          const SizedBox(height: 18),
          _footer(),
        ],
      );

  Widget _codeBlock() => Column(
        key: const ValueKey('code'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _backButton(),
              Expanded(
                child: Text(
                  _s('code_section_label'),
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700, color: _ink),
                ),
              ),
              Flexible(
                child: Text(
                  '${_s('sent_to_prefix')} ${_s('number_prefix')} '
                  '${_format5x5(_sentDigits)}',
                  textAlign: TextAlign.right,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5, color: _muted),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _codeBoxes(),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  _s('code_idle_note'),
                  style: const TextStyle(fontSize: 12.5, color: _muted),
                ),
              ),
              _resendControl(),
            ],
          ),
          const SizedBox(height: 16),
          _primaryButton(
            label: _s('verify_label'),
            onPressed: _verify,
            busy: _verifying,
          ),
          if (_message != null) ...[
            const SizedBox(height: 14),
            _messageText(),
          ],
          const SizedBox(height: 18),
          _footer(),
        ],
      );

  // ── Pieces ─────────────────────────────────────────────────────────────────

  Widget _sectionHeader(String label) => Row(
        children: [
          _backButton(),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w700, color: _ink),
            ),
          ),
        ],
      );

  Widget _backButton() => Padding(
        padding: const EdgeInsets.only(right: 4),
        child: IconButton(
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          icon: const Icon(Icons.arrow_back_ios_new, size: 16, color: _muted),
          onPressed: _backToActions,
        ),
      );

  Widget _footer() => Text(
        _s('footer_note'),
        textAlign: TextAlign.center,
        style:
            const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF), height: 1.5),
      );

  Widget _messageText() => Text(
        _message!,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 13,
          height: 1.4,
          color: _codeError ? _danger : const Color(0xFF374151),
        ),
      );

  Widget _numberField() => Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _line),
        ),
        child: Row(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 10, 0),
              child: Text(
                _s('number_prefix'),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: _ink,
                  fontFamily: 'monospace',
                ),
              ),
            ),
            Container(width: 1, height: 26, color: _line),
            Expanded(
              child: TextField(
                controller: _numCtrl,
                focusNode: _numFocus,
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _send(),
                inputFormatters: [_NumberFormatter()],
                style: const TextStyle(
                  fontSize: 17,
                  letterSpacing: 1.5,
                  fontFamily: 'monospace',
                  color: _ink,
                ),
                decoration: InputDecoration(
                  hintText: _s('number_hint'),
                  hintStyle: const TextStyle(
                      color: Color(0xFFC7CDD4), fontFamily: 'monospace'),
                  border: InputBorder.none,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
                ),
              ),
            ),
          ],
        ),
      );

  Widget _codeBoxes() {
    final n = _codeCtrls.length;
    return Row(
      children: List.generate(n, (i) {
        final filled = _codeCtrls[i].text.isNotEmpty;
        return Expanded(
          child: Padding(
            padding: EdgeInsets.only(right: i == n - 1 ? 0 : 8),
            child: AspectRatio(
              aspectRatio: 0.82,
              child: TextField(
                controller: _codeCtrls[i],
                focusNode: _codeFocus[i],
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                maxLength: 1,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onChanged: (v) => _onCodeChanged(i, v),
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: _ink,
                ),
                decoration: InputDecoration(
                  counterText: '',
                  filled: true,
                  fillColor: _codeError
                      ? const Color(0xFFFEF2F2)
                      : filled
                          ? const Color(0xFFEFF8F1)
                          : Colors.white,
                  contentPadding: EdgeInsets.zero,
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(
                        color: _codeError
                            ? _danger
                            : filled
                                ? _green
                                : _line),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(
                        color: _codeError ? _danger : _green, width: 1.8),
                  ),
                ),
              ),
            ),
          ),
        );
      }),
    );
  }

  void _onCodeChanged(int i, String v) {
    setState(() => _codeError = false);
    if (v.isNotEmpty) {
      if (i + 1 < _codeFocus.length) {
        _codeFocus[i + 1].requestFocus();
      } else {
        _codeFocus[i].unfocus();
      }
    } else if (i > 0) {
      _codeFocus[i - 1].requestFocus();
    }
  }

  Widget _resendControl() {
    final ready = _resendLeft <= 0;
    return TextButton(
      onPressed: ready ? _resend : null,
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        foregroundColor: _green,
        disabledForegroundColor: const Color(0xFF9CA3AF),
      ),
      child: Text(
        ready ? _s('resend_label') : '${_s('resend_label')} $_resendLeft',
        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _primaryButton({
    required String label,
    required VoidCallback onPressed,
    required bool busy,
  }) =>
      SizedBox(
        height: 54,
        child: FilledButton(
          onPressed: onPressed,
          style: FilledButton.styleFrom(
            backgroundColor: _green,
            foregroundColor: Colors.white,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            elevation: 0,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (busy) ...[
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      color: Colors.white, strokeWidth: 2.2),
                ),
                const SizedBox(width: 10),
              ],
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      );

  Widget _secondaryButton({
    required String label,
    required VoidCallback onPressed,
    required bool busy,
  }) =>
      SizedBox(
        height: 54,
        child: OutlinedButton(
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            foregroundColor: _ink,
            backgroundColor: Colors.white,
            side: const BorderSide(color: _line),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (busy)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      color: _green, strokeWidth: 2.2),
                )
              else
                const _GoogleMark(),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      );
}

/// Digits only, max 10, rendered as 5+5 while typing. The RPC always receives
/// the raw digits, never this formatted form.
class _NumberFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    var d = newValue.text.replaceAll(RegExp(r'\D'), '');
    if (d.length > 10) d = d.substring(0, 10);
    final out = d.length > 5 ? '${d.substring(0, 5)} ${d.substring(5)}' : d;
    return TextEditingValue(
      text: out,
      selection: TextSelection.collapsed(offset: out.length),
    );
  }
}

/// The Google "G" drawn locally, so the outlined button needs no network asset.
class _GoogleMark extends StatelessWidget {
  const _GoogleMark();

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 20,
        height: 20,
        child: CustomPaint(painter: _GooglePainter()),
      );
}

class _GooglePainter extends CustomPainter {
  static const _blue = Color(0xFF4285F4);
  static const _red = Color(0xFFEA4335);
  static const _yellow = Color(0xFFFBBC05);
  static const _greenG = Color(0xFF34A853);

  double _rad(double deg) => deg * math.pi / 180;

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2;
    final stroke = size.width * 0.25;
    final rect =
        Rect.fromCircle(center: Offset(r, r), radius: r - stroke / 2);
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.butt;

    void arc(double startDeg, double sweepDeg, Color color) {
      p.color = color;
      canvas.drawArc(rect, _rad(startDeg), _rad(sweepDeg), false, p);
    }

    arc(-70, 60, _red); // top right
    arc(-130, 60, _red); // top left
    arc(130, 100, _yellow); // left
    arc(50, 80, _greenG); // bottom
    arc(-20, 70, _blue); // right

    // The crossbar of the G.
    final bar = Paint()..color = _blue;
    canvas.drawRect(
      Rect.fromLTWH(r - stroke * 0.1, r - stroke / 2, r + stroke * 0.1, stroke),
      bar,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
