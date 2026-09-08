part of '../home_shell.dart';

// CHANGE #327 · LAYER 1 — sharded out of home_shell.dart.
//
// The slide-in login panel: sign-in, OTP reset and the new-password step.
//
// It is a `part`, not a new library, on purpose: nearly every widget in
// the shell is library-private and used by the others, so extracting them
// into real libraries would force ~40 classes public and rewrite every
// reference. A part shares the library's imports and its privacy scope, so
// this is a pure move — and it gives this concern its own leasable path, so
// a cart command and a login command stop fighting over one file.
class LoginPanel extends StatefulWidget {
  final bool open;
  final VoidCallback onClose;
  const LoginPanel({super.key, required this.open, required this.onClose});

  @override
  State<LoginPanel> createState() => _LoginPanelState();
}

class _LoginPanelState extends State<LoginPanel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
    reverseDuration: const Duration(milliseconds: 240),
    value: widget.open ? 1 : 0,
  );
  late final Animation<double> _t = CurvedAnimation(
    parent: _c,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );

  @override
  void didUpdateWidget(LoginPanel old) {
    super.didUpdateWidget(old);
    if (widget.open && !old.open) _c.forward();
    if (!widget.open && old.open) _c.reverse();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenW = MediaQuery.sizeOf(context).width;
    final panelW = screenW < 520 ? screenW : 420.0;

    return AnimatedBuilder(
      animation: _t,
      builder: (context, _) {
        final t = _t.value;
        if (t == 0) return const SizedBox.shrink();
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: widget.onClose,
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: 0.45 * t),
                ),
              ),
            ),
            Positioned(
              top: 0,
              bottom: 0,
              right: 0,
              width: panelW,
              child: Transform.translate(
                offset: Offset(panelW * (1 - t), 0),
                child: Material(
                  elevation: 16,
                  color: Colors.white,
                  // New mobile-style WhatsApp/Google login, hosted in the
                  // right-side panel. The ✕ overlays the top-right; the scrim
                  // behind the panel also closes on tap.
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: LoginPanelView(onClose: widget.onClose),
                      ),
                      Positioned(
                        top: 6,
                        right: 6,
                        child: IconButton(
                          icon: const Icon(Icons.close, size: 22),
                          color: const Color(0xFF6B7280),
                          onPressed: widget.onClose,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _LoginPanelContent extends StatefulWidget {
  final VoidCallback onClose;
  const _LoginPanelContent({required this.onClose});

  @override
  State<_LoginPanelContent> createState() => _LoginPanelContentState();
}

// Reset flow steps
enum _ResetStep { none, otpSent, newPassword }

class _LoginPanelContentState extends State<_LoginPanelContent> {
  // ── Normal login ────────────────────────────────────────────────────────────
  final _emailCtrl = TextEditingController();
  final _passCtrl  = TextEditingController();
  bool _passVisible  = false;
  // CHANGE #311: _busy replaces _loading. onPressed is NEVER null;
  // _busy only guards re-entry inside the handler.
  bool _busy         = false;
  String? _error;
  bool _emailEmpty   = true;
  bool _showForgot   = false;   // show "Forgot password?" link after invalid creds

  // ── Reset flow ──────────────────────────────────────────────────────────────
  _ResetStep _resetStep = _ResetStep.none;
  final _otpCtrl       = TextEditingController();
  final _newPassCtrl   = TextEditingController();
  final _confirmCtrl   = TextEditingController();
  bool _newPassVisible = false;
  bool _confPassVisible = false;
  String? _resetError;
  bool _resetLoading   = false;

  StreamSubscription<AuthState>? _authSub;

  static const _green = Color(0xFF1B5E20);

  @override
  void initState() {
    super.initState();
    _emailCtrl.addListener(_onEmailChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (Supabase.instance.client.auth.currentUser != null) {
        widget.onClose();
      }
    });
    _authSub = Supabase.instance.client.auth.onAuthStateChange.listen((s) {
      // After _setNewPassword re-signs in, guard against closing before explicit onClose
      if (s.event == AuthChangeEvent.signedIn && mounted && _resetStep == _ResetStep.none) {
        widget.onClose();
      }
    });
  }

  void _onEmailChanged() {
    final empty = _emailCtrl.text.trim().isEmpty;
    if (empty != _emailEmpty) setState(() { _emailEmpty = empty; _showForgot = false; _error = null; });
  }

  @override
  void dispose() {
    _emailCtrl.removeListener(_onEmailChanged);
    _emailCtrl.dispose();
    _passCtrl.dispose();
    _otpCtrl.dispose();
    _newPassCtrl.dispose();
    _confirmCtrl.dispose();
    _authSub?.cancel();
    super.dispose();
  }

  // ── Normal login actions ────────────────────────────────────────────────────

  // CHANGE #311: c311_tap_fired is the ONLY proof of a real tap.
  // It MUST be the first line. onPressed points here and is NEVER null.
  Future<void> _onContinueTap() async {
    try { RenderLog.write('c311_tap_fired', '1'); } catch (_) {} // first line — tap proof
    if (_busy) return; // re-entry guard inside handler; does NOT disable button
    if (_emailEmpty) {
      await _googleSignIn();
    } else {
      await _passwordSignIn();
    }
  }

  Future<void> _googleSignIn() async {
    setState(() { _busy = true; _error = null; });
    try {
      try { RenderLog.write('c311_auth_start', 'google'); } catch (_) {}
      await UserState.read(context).signInWithGoogle();
      try { RenderLog.write('c311_auth_ok', 'google'); } catch (_) {}
      if (mounted) widget.onClose();
    } catch (e) {
      final msg = e.toString();
      try { RenderLog.write('auth55_login_error', msg.length > 120 ? msg.substring(0, 120) : msg); } catch (_) {}
      // CHANGE #311: cancel/dismiss are noise — suppress UI error, do NOT block retry
      final isCancel = msg.contains('cancelled') || msg.contains('dismissed') ||
          msg.contains('overlay-timeout');
      if (!isCancel) {
        try { RenderLog.write('c311_auth_err', msg.length > 80 ? msg.substring(0, 80) : msg); } catch (_) {}
      }
      final display = isCancel ? null : (msg.length > 120 ? '${msg.substring(0, 120)}…' : msg);
      if (mounted) setState(() => _error = display ?? _error);
    } finally {
      // ALWAYS resets — button can never be stranded dead
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _passwordSignIn() async {
    final email = _emailCtrl.text.trim();
    final pass  = _passCtrl.text;
    if (pass.isEmpty) { setState(() => _error = 'Enter your password.'); return; }
    setState(() { _busy = true; _error = null; _showForgot = false; });
    try {
      try { RenderLog.write('c311_auth_start', 'password'); } catch (_) {}
      await Supabase.instance.client.auth.signInWithPassword(email: email, password: pass);
      try { RenderLog.write('c311_auth_ok', 'password'); } catch (_) {}
    } on AuthException catch (e) {
      if (!mounted) return;
      final isInvalid = e.statusCode == '400' ||
          e.message.toLowerCase().contains('invalid') ||
          e.message.toLowerCase().contains('credentials') ||
          e.message.toLowerCase().contains('wrong');
      if (mounted) setState(() { _error = 'Invalid credentials'; _showForgot = isInvalid; });
      try { RenderLog.write('c311_auth_err', 'invalid_creds'); } catch (_) {}
    } catch (e) {
      if (mounted) setState(() => _error = 'Sign-in failed. Check your credentials.');
      try { RenderLog.write('c311_auth_err', e.toString().length > 80 ? e.toString().substring(0, 80) : e.toString()); } catch (_) {}
    } finally {
      // ALWAYS resets — button can never be stranded dead
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── Forgot-password / reset flow ────────────────────────────────────────────

  Future<void> _startReset() async {
    final email = _emailCtrl.text.trim();
    setState(() { _resetLoading = true; _resetError = null; });
    try {
      final exists = await Supabase.instance.client
          .rpc('check_email_registered', params: {'p_email': email}) as bool;
      if (!exists) {
        if (mounted) setState(() { _resetError = 'No account found for this email.'; _resetLoading = false; });
        return;
      }
      await Supabase.instance.client.auth.resetPasswordForEmail(
        email,
        redirectTo: 'https://medibo.in',
      );
      if (mounted) setState(() { _resetStep = _ResetStep.otpSent; _resetLoading = false; _otpCtrl.clear(); });
    } on AuthException catch (e) {
      if (mounted) setState(() { _resetError = e.message; _resetLoading = false; });
    } catch (_) {
      if (mounted) setState(() { _resetError = 'Could not send code. Try again.'; _resetLoading = false; });
    }
  }

  Future<void> _verifyOtp() async {
    final email = _emailCtrl.text.trim();
    final otp   = _otpCtrl.text.trim();
    if (otp.length < 6) { setState(() => _resetError = 'Enter the 6-digit code.'); return; }
    setState(() { _resetLoading = true; _resetError = null; });
    try {
      // OtpType.recovery fires passwordRecovery (not signedIn) so _AppRoot stays stable
      await Supabase.instance.client.auth.verifyOTP(
        email: email,
        token: otp,
        type: OtpType.recovery,
      );
      if (mounted) setState(() { _resetStep = _ResetStep.newPassword; _resetLoading = false; _newPassCtrl.clear(); _confirmCtrl.clear(); });
    } on AuthException catch (e) {
      if (mounted) setState(() { _resetError = e.message; _resetLoading = false; });
    } catch (_) {
      if (mounted) setState(() { _resetError = 'Invalid or expired code.'; _resetLoading = false; });
    }
  }

  Future<void> _setNewPassword() async {
    final email   = _emailCtrl.text.trim();
    final newPass = _newPassCtrl.text;
    final confirm = _confirmCtrl.text;
    if (newPass.length < 6) { setState(() => _resetError = 'Password must be at least 6 characters.'); return; }
    if (newPass != confirm)  { setState(() => _resetError = 'Passwords do not match.'); return; }
    setState(() { _resetLoading = true; _resetError = null; });
    try {
      await Supabase.instance.client.auth.updateUser(UserAttributes(password: newPass));
      // Re-sign in with new password so AuthNotifier fires signedIn → routes admin/home correctly
      await Supabase.instance.client.auth.signInWithPassword(email: email, password: newPass);
      if (mounted) widget.onClose();
    } on AuthException catch (e) {
      if (mounted) setState(() { _resetError = e.message; _resetLoading = false; });
    } catch (_) {
      if (mounted) setState(() { _resetError = 'Could not update password. Try again.'; _resetLoading = false; });
    }
  }

  void _backToLogin() => setState(() {
    _resetStep  = _ResetStep.none;
    _resetError = null;
    _showForgot = false;
    _error      = null;
    _passCtrl.clear();
    _otpCtrl.clear();
    _newPassCtrl.clear();
    _confirmCtrl.clear();
  });

  // ── Shared field decoration ─────────────────────────────────────────────────

  InputDecoration _fieldDec(String hint, {Widget? suffix}) => InputDecoration(
    hintText: hint,
    hintStyle: const TextStyle(color: Color(0xFFD1D5DB)),
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Color(0xFFD1D5DB))),
    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Color(0xFFD1D5DB))),
    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: _green, width: 1.5)),
    suffixIcon: suffix,
  );

  // CHANGE #311: onPressed is NON-NULL — FilledButton never enters disabled state.
  // Used ONLY for the Continue button so it is always hit-testable.
  Widget _greenButton({ required VoidCallback onPressed, required Widget child }) => SizedBox(
    height: 54,
    child: FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: _green,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        elevation: 0,
      ),
      child: child,
    ),
  );

  // Nullable variant for password-reset flow buttons (OTP verify, set-password).
  // These legitimately grey-out while async is in flight, unlike the main Continue button.
  Widget _greenButtonNullable({ required VoidCallback? onPressed, required Widget child }) => SizedBox(
    height: 54,
    child: FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: _green,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        elevation: 0,
      ),
      child: child,
    ),
  );

  Widget _spinner() => const SizedBox(
    width: 22, height: 22,
    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
  );

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
          child: Row(children: [
            if (_resetStep != _ResetStep.none)
              IconButton(
                icon: const Icon(Icons.arrow_back_ios_new, size: 18),
                color: const Color(0xFF6B7280),
                onPressed: _backToLogin,
                tooltip: c('home_shell.back'),
              ),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.close, size: 22),
              color: const Color(0xFF6B7280),
              onPressed: widget.onClose,
              tooltip: c('home_shell.close'),
            ),
          ]),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 8),
            child: switch (_resetStep) {
              _ResetStep.none        => _buildLogin(),
              _ResetStep.otpSent     => _buildOtpStep(),
              _ResetStep.newPassword => _buildNewPasswordStep(),
            },
          ),
        ),
      ],
    );
  }

  // ── Step 0: Normal login ────────────────────────────────────────────────────

  Widget _buildLogin() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Center(child: _LoginPanelLogo()),
        const SizedBox(height: 28),
        Text(c('home_shell.welcome_to_medibo'), textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800,
                color: Color(0xFF111827), letterSpacing: -0.5)),
        const SizedBox(height: 6),
        Text(c('home_shell.b2b_pharmacy_platform'), textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 15, color: Color(0xFF6B7280))),
        const SizedBox(height: 40),

        TextField(
          controller: _emailCtrl,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.next,
          style: const TextStyle(fontSize: 15),
          decoration: _fieldDec('Email'),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _passCtrl,
          obscureText: !_passVisible,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _onContinueTap(),
          style: const TextStyle(fontSize: 15),
          decoration: _fieldDec('Password',
            suffix: IconButton(
              icon: Icon(_passVisible ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                  size: 18, color: const Color(0xFF9CA3AF)),
              onPressed: () => setState(() => _passVisible = !_passVisible),
            ),
          ),
        ),

        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(_error!, textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Color(0xFFDC2626))),
        ],
        if (_showForgot) ...[
          const SizedBox(height: 6),
          Center(
            child: GestureDetector(
              onTap: _resetLoading ? null : _startReset,
              child: _resetLoading
                  ? const SizedBox(width: 14, height: 14,
                      child: CircularProgressIndicator(color: _green, strokeWidth: 2))
                  : Text(c('home_shell.forgot_password'),
                      style: const TextStyle(fontSize: 13, color: _green,
                          fontWeight: FontWeight.w600, decoration: TextDecoration.underline)),
            ),
          ),
          if (_resetError != null) ...[
            const SizedBox(height: 6),
            Text(_resetError!, textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: Color(0xFFDC2626))),
          ],
        ],

        const SizedBox(height: 16),
        // CHANGE #311: onPressed is _onContinueTap — NEVER null.
        // _busy swaps child (spinner vs text) but never disables the button.
        _greenButton(
          onPressed: _onContinueTap,
          child: _busy
              ? _spinner()
              : Text(c('home_shell.continue'),
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        ),

        const SizedBox(height: 40),
        Text(c('home_shell.by_continuing_you_agree_to_our_terms_privacy_policy'),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF), height: 1.5)),
      ],
    );
  }

  // ── Step 1: OTP entry ───────────────────────────────────────────────────────

  Widget _buildOtpStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Center(child: _LoginPanelLogo()),
        const SizedBox(height: 28),
        Text(c('home_shell.check_your_email'), textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800,
                color: Color(0xFF111827), letterSpacing: -0.5)),
        const SizedBox(height: 8),
        RichText(
          textAlign: TextAlign.center,
          text: TextSpan(
            style: const TextStyle(fontSize: 14, color: Color(0xFF6B7280), height: 1.5),
            children: [
              const TextSpan(text: 'We sent a 6-digit code to '),
              TextSpan(text: _emailCtrl.text.trim(),
                  style: const TextStyle(fontWeight: FontWeight.w700, color: Color(0xFF111827))),
            ],
          ),
        ),
        const SizedBox(height: 36),

        TextField(
          controller: _otpCtrl,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _resetLoading ? null : _verifyOtp(),
          style: const TextStyle(fontSize: 22, letterSpacing: 8, fontWeight: FontWeight.w700),
          textAlign: TextAlign.center,
          maxLength: 6,
          decoration: _fieldDec('6-digit code').copyWith(counterText: ''),
        ),

        if (_resetError != null) ...[
          const SizedBox(height: 8),
          Text(_resetError!, textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Color(0xFFDC2626))),
        ],
        const SizedBox(height: 16),

        _greenButtonNullable(
          onPressed: _resetLoading ? null : _verifyOtp,
          child: _resetLoading ? _spinner() : Text(c('home_shell.verify_code'),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        ),
        const SizedBox(height: 16),
        Center(
          child: GestureDetector(
            onTap: _resetLoading ? null : () {
              setState(() { _resetStep = _ResetStep.none; _resetError = null; _showForgot = true; });
            },
            child: Text(c('home_shell.resend_code_or_use_different_email'),
                style: const TextStyle(fontSize: 13, color: _green,
                    fontWeight: FontWeight.w500, decoration: TextDecoration.underline)),
          ),
        ),
      ],
    );
  }

  // ── Step 2: New password ────────────────────────────────────────────────────

  Widget _buildNewPasswordStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Center(child: _LoginPanelLogo()),
        const SizedBox(height: 28),
        Text(c('home_shell.set_new_password'), textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800,
                color: Color(0xFF111827), letterSpacing: -0.5)),
        const SizedBox(height: 8),
        Text(c('home_shell.choose_a_strong_password_for_your_account'),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, color: Color(0xFF6B7280))),
        const SizedBox(height: 36),

        TextField(
          controller: _newPassCtrl,
          obscureText: !_newPassVisible,
          textInputAction: TextInputAction.next,
          style: const TextStyle(fontSize: 15),
          decoration: _fieldDec('New password',
            suffix: IconButton(
              icon: Icon(_newPassVisible ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                  size: 18, color: const Color(0xFF9CA3AF)),
              onPressed: () => setState(() => _newPassVisible = !_newPassVisible),
            ),
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _confirmCtrl,
          obscureText: !_confPassVisible,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _resetLoading ? null : _setNewPassword(),
          style: const TextStyle(fontSize: 15),
          decoration: _fieldDec('Confirm password',
            suffix: IconButton(
              icon: Icon(_confPassVisible ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                  size: 18, color: const Color(0xFF9CA3AF)),
              onPressed: () => setState(() => _confPassVisible = !_confPassVisible),
            ),
          ),
        ),

        if (_resetError != null) ...[
          const SizedBox(height: 10),
          Text(_resetError!, textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Color(0xFFDC2626))),
        ],
        const SizedBox(height: 16),

        _greenButtonNullable(
          onPressed: _resetLoading ? null : _setNewPassword,
          child: _resetLoading ? _spinner() : Text(c('home_shell.set_password'),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }
}

class _LoginPanelLogo extends StatelessWidget {
  const _LoginPanelLogo();

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

class _LoginPanelGoogleIcon extends StatelessWidget {
  const _LoginPanelGoogleIcon();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Center(
        child: Text(
          'G',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w800,
            color: Color(0xFF4285F4),
            height: 1,
          ),
        ),
      ),
    );
  }
}

// ─────────────────────── Mobile bottom bar ───────────────────────
