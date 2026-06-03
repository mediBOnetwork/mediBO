import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

enum _ResetStep { none, otpSent, newPassword }

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  // ── Normal login ─────────────────────────────────────────────────────────────
  final _emailCtrl = TextEditingController();
  final _passCtrl  = TextEditingController();
  bool _passVisible  = false;
  bool _loading      = false;
  String? _error;
  bool _emailEmpty   = true;
  bool _showForgot   = false;

  // ── Reset flow ───────────────────────────────────────────────────────────────
  _ResetStep _resetStep = _ResetStep.none;
  final _otpCtrl        = TextEditingController();
  final _newPassCtrl    = TextEditingController();
  final _confirmCtrl    = TextEditingController();
  bool _newPassVisible  = false;
  bool _confPassVisible = false;
  String? _resetError;
  bool _resetLoading    = false;

  StreamSubscription<AuthState>? _authSub;

  static const _green = Color(0xFF1B5E20);

  @override
  void initState() {
    super.initState();
    _emailCtrl.addListener(_onEmailChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && Supabase.instance.client.auth.currentUser != null) {
        _close();
      }
    });
    _authSub = Supabase.instance.client.auth.onAuthStateChange.listen((s) {
      if (s.event == AuthChangeEvent.signedIn && mounted && _resetStep == _ResetStep.none) {
        _close();
      }
    });
  }

  void _close() {
    if (Navigator.canPop(context)) {
      Navigator.of(context).popUntil((r) => r.isFirst);
    }
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

  // ── Normal login actions ──────────────────────────────────────────────────────

  Future<void> _onContinue() async {
    if (_emailEmpty) {
      await _googleSignIn();
    } else {
      await _passwordSignIn();
    }
  }

  Future<void> _googleSignIn() async {
    setState(() { _loading = true; _error = null; });
    try {
      await Supabase.instance.client.auth.signInWithOAuth(
        OAuthProvider.google,
        redirectTo: 'https://medibo.in',
      );
    } catch (_) {
      if (mounted) setState(() {
        _error = 'Google sign-in failed. Please try again.';
        _loading = false;
      });
    }
  }

  Future<void> _passwordSignIn() async {
    final email = _emailCtrl.text.trim();
    final pass  = _passCtrl.text;
    if (pass.isEmpty) { setState(() => _error = 'Enter your password.'); return; }
    setState(() { _loading = true; _error = null; _showForgot = false; });
    try {
      await Supabase.instance.client.auth.signInWithPassword(email: email, password: pass);
    } on AuthException catch (e) {
      if (!mounted) return;
      final isInvalid = e.statusCode == '400' ||
          e.message.toLowerCase().contains('invalid') ||
          e.message.toLowerCase().contains('credentials') ||
          e.message.toLowerCase().contains('wrong');
      setState(() {
        _error = 'Invalid credentials';
        _showForgot = isInvalid;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() { _error = 'Sign-in failed. Check your credentials.'; _loading = false; });
    }
  }

  // ── Forgot-password / reset flow ──────────────────────────────────────────────

  Future<void> _startReset() async {
    final email = _emailCtrl.text.trim();
    setState(() { _resetLoading = true; _resetError = null; });
    try {
      await Supabase.instance.client.auth.signInWithOtp(
        email: email,
        shouldCreateUser: false,
      );
      if (mounted) setState(() { _resetStep = _ResetStep.otpSent; _resetLoading = false; _otpCtrl.clear(); });
    } on AuthException catch (e) {
      if (!mounted) return;
      final notFound = e.message.toLowerCase().contains('user') ||
          e.message.toLowerCase().contains('not found') ||
          e.message.toLowerCase().contains('no account') ||
          e.statusCode == '422' || e.statusCode == '400';
      setState(() {
        _resetError = notFound ? 'No account found for this email.' : e.message;
        _resetLoading = false;
      });
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
      await Supabase.instance.client.auth.verifyOTP(
        email: email,
        token: otp,
        type: OtpType.email,
      );
      if (mounted) setState(() { _resetStep = _ResetStep.newPassword; _resetLoading = false; _newPassCtrl.clear(); _confirmCtrl.clear(); });
    } on AuthException catch (e) {
      if (mounted) setState(() { _resetError = e.message; _resetLoading = false; });
    } catch (_) {
      if (mounted) setState(() { _resetError = 'Invalid or expired code.'; _resetLoading = false; });
    }
  }

  Future<void> _setNewPassword() async {
    final newPass = _newPassCtrl.text;
    final confirm = _confirmCtrl.text;
    if (newPass.length < 6) { setState(() => _resetError = 'Password must be at least 6 characters.'); return; }
    if (newPass != confirm)  { setState(() => _resetError = 'Passwords do not match.'); return; }
    setState(() { _resetLoading = true; _resetError = null; });
    try {
      await Supabase.instance.client.auth.updateUser(UserAttributes(password: newPass));
      if (mounted) _close();
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

  // ── Shared helpers ────────────────────────────────────────────────────────────

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

  Widget _greenButton({required VoidCallback? onPressed, required Widget child}) => SizedBox(
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
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned(
              top: 8,
              left: 8,
              child: _resetStep != _ResetStep.none
                  ? IconButton(
                      icon: const Icon(Icons.arrow_back_ios_new, size: 18),
                      color: const Color(0xFF6B7280),
                      onPressed: _backToLogin,
                      tooltip: 'Back',
                    )
                  : IconButton(
                      icon: const Icon(Icons.arrow_back_ios_new, size: 20),
                      color: _green,
                      onPressed: () { if (Navigator.canPop(context)) Navigator.pop(context); },
                      tooltip: 'Back',
                    ),
            ),
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: switch (_resetStep) {
                    _ResetStep.none        => _buildLogin(),
                    _ResetStep.otpSent     => _buildOtpStep(),
                    _ResetStep.newPassword => _buildNewPasswordStep(),
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Step 0: Normal login ──────────────────────────────────────────────────────

  Widget _buildLogin() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Center(child: _MediBoLogo()),
        const SizedBox(height: 28),
        const Text('Welcome to mediBO', textAlign: TextAlign.center,
            style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800,
                color: Color(0xFF111827), letterSpacing: -0.5)),
        const SizedBox(height: 6),
        const Text('B2B Pharmacy Platform', textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15, color: Color(0xFF6B7280))),
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
          onSubmitted: (_) => _loading ? null : _onContinue(),
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
                  : const Text('Forgot password?',
                      style: TextStyle(fontSize: 13, color: _green,
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
        _greenButton(
          onPressed: _loading ? null : _onContinue,
          child: _loading
              ? _spinner()
              : const Text('Continue',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        ),

        const SizedBox(height: 40),
        const Text('By continuing you agree to our Terms & Privacy Policy',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: Color(0xFF9CA3AF), height: 1.5)),
      ],
    );
  }

  // ── Step 1: OTP entry ─────────────────────────────────────────────────────────

  Widget _buildOtpStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Center(child: _MediBoLogo()),
        const SizedBox(height: 28),
        const Text('Check your email', textAlign: TextAlign.center,
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800,
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

        _greenButton(
          onPressed: _resetLoading ? null : _verifyOtp,
          child: _resetLoading ? _spinner() : const Text('Verify Code',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        ),
        const SizedBox(height: 16),
        Center(
          child: GestureDetector(
            onTap: _resetLoading ? null : () {
              setState(() { _resetStep = _ResetStep.none; _resetError = null; _showForgot = true; });
            },
            child: const Text('Resend code or use different email',
                style: TextStyle(fontSize: 13, color: _green,
                    fontWeight: FontWeight.w500, decoration: TextDecoration.underline)),
          ),
        ),
      ],
    );
  }

  // ── Step 2: New password ──────────────────────────────────────────────────────

  Widget _buildNewPasswordStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Center(child: _MediBoLogo()),
        const SizedBox(height: 28),
        const Text('Set new password', textAlign: TextAlign.center,
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800,
                color: Color(0xFF111827), letterSpacing: -0.5)),
        const SizedBox(height: 8),
        const Text('Choose a strong password for your account.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: Color(0xFF6B7280))),
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

        _greenButton(
          onPressed: _resetLoading ? null : _setNewPassword,
          child: _resetLoading ? _spinner() : const Text('Set Password',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }
}

// ── mediBO logo ───────────────────────────────────────────────────────────────

class _MediBoLogo extends StatelessWidget {
  const _MediBoLogo();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: const Color(0xFF1B5E20),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Icon(Icons.add, color: Colors.white, size: 28),
        ),
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

