import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailCtrl = TextEditingController();
  bool _loading = false;
  bool _sent = false;
  String? _error;

  // ── Admin dev login (temporary) ───────────────────────────────────────────
  bool _showAdminLogin = false;
  final _adminEmailCtrl = TextEditingController(text: 'demo@medibo.in');
  final _adminPassCtrl = TextEditingController();
  bool _adminLoading = false;
  String? _adminError;
  bool _adminPassVisible = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && Supabase.instance.client.auth.currentUser != null) {
        Navigator.of(context).popUntil((r) => r.isFirst);
      }
    });
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _adminEmailCtrl.dispose();
    _adminPassCtrl.dispose();
    super.dispose();
  }

  void _handleBack() {
    if (Navigator.canPop(context)) Navigator.pop(context);
  }

  Future<void> _sendMagicLink() async {
    final email = _emailCtrl.text.trim();
    if (email.isEmpty) {
      setState(() => _error = 'Please enter your email address.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await Supabase.instance.client.auth.signInWithOtp(
        email: email,
        emailRedirectTo: 'https://medibo.in',
      );
      if (mounted) setState(() { _sent = true; _loading = false; });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Could not send link. Please check your email and try again.';
          _loading = false;
        });
      }
    }
  }

  Future<void> _adminSignIn() async {
    final email = _adminEmailCtrl.text.trim();
    final pass = _adminPassCtrl.text;
    if (email.isEmpty || pass.isEmpty) {
      setState(() => _adminError = 'Enter email and password.');
      return;
    }
    setState(() { _adminLoading = true; _adminError = null; });
    try {
      await Supabase.instance.client.auth.signInWithPassword(
        email: email,
        password: pass,
      );
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } on AuthException catch (e) {
      if (mounted) setState(() { _adminError = e.message; _adminLoading = false; });
    } catch (_) {
      if (mounted) setState(() { _adminError = 'Sign-in failed. Check credentials.'; _adminLoading = false; });
    }
  }

  Future<void> _googleSignIn() async {
    setState(() { _loading = true; _error = null; });
    try {
      await Supabase.instance.client.auth.signInWithOAuth(
        OAuthProvider.google,
        redirectTo: 'https://medibo.in',
      );
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Google sign-in failed. Please try again.';
          _loading = false;
        });
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
                color: const Color(0xFF1B5E20),
                onPressed: _handleBack,
                tooltip: 'Back',
              ),
            ),
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Center(child: _MediBoLogo()),
                      const SizedBox(height: 32),
                      const Text(
                        'Welcome to mediBO',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF111827),
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'B2B Pharmacy Platform',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 15, color: Color(0xFF6B7280)),
                      ),
                      const SizedBox(height: 48),

                      // ── Google sign-in ─────────────────────────────────
                      SizedBox(
                        height: 54,
                        child: OutlinedButton(
                          onPressed: _loading ? null : _googleSignIn,
                          style: OutlinedButton.styleFrom(
                            backgroundColor: Colors.white,
                            side: const BorderSide(
                                color: Color(0xFFD1D5DB), width: 1.5),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          child: _loading
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    color: Color(0xFF4285F4),
                                    strokeWidth: 2.5,
                                  ),
                                )
                              : const Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    _GoogleIcon(),
                                    SizedBox(width: 12),
                                    Text(
                                      'Continue with Google',
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                        color: Color(0xFF374151),
                                      ),
                                    ),
                                  ],
                                ),
                        ),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFFDC2626)),
                        ),
                      ],

                      // ── Magic link (preserved — re-enable by un-commenting) ──
                      // if (_sent) ...[
                      //   Container(success state — check your email...),
                      // ] else ...[
                      //   TextField(controller: _emailCtrl, labelText: 'Email address'...),
                      //   SizedBox(height: 16),
                      //   FilledButton(onPressed: _sendMagicLink, child: Text('Send Magic Link')),
                      //   if (_error != null) Text(_error!)...,
                      // ],

                      // ── Admin dev login (TEMPORARY — remove before public launch) ──
                      const SizedBox(height: 28),
                      _AdminLoginPanel(
                        expanded: _showAdminLogin,
                        onToggle: () => setState(() {
                          _showAdminLogin = !_showAdminLogin;
                          _adminError = null;
                        }),
                        emailCtrl: _adminEmailCtrl,
                        passCtrl: _adminPassCtrl,
                        passVisible: _adminPassVisible,
                        onTogglePass: () => setState(() => _adminPassVisible = !_adminPassVisible),
                        loading: _adminLoading,
                        error: _adminError,
                        onSignIn: _adminSignIn,
                      ),

                      const SizedBox(height: 40),
                      const Text(
                        'By continuing you agree to our Terms & Privacy Policy',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 11,
                          color: Color(0xFF9CA3AF),
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── mediBO logo ──────────────────────────────────────────────────────────────

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

// ─── Admin dev-login panel (TEMPORARY) ───────────────────────────────────────

class _AdminLoginPanel extends StatelessWidget {
  final bool expanded;
  final VoidCallback onToggle;
  final TextEditingController emailCtrl;
  final TextEditingController passCtrl;
  final bool passVisible;
  final VoidCallback onTogglePass;
  final bool loading;
  final String? error;
  final VoidCallback onSignIn;

  const _AdminLoginPanel({
    required this.expanded,
    required this.onToggle,
    required this.emailCtrl,
    required this.passCtrl,
    required this.passVisible,
    required this.onTogglePass,
    required this.loading,
    required this.error,
    required this.onSignIn,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFFE5E7EB)),
        borderRadius: BorderRadius.circular(10),
        color: const Color(0xFFFAFAFA),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // Toggle row
        InkWell(
          onTap: onToggle,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            child: Row(children: [
              const Icon(Icons.admin_panel_settings_outlined,
                  size: 16, color: Color(0xFF6B7280)),
              const SizedBox(width: 8),
              const Text(
                'Admin login  ',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF374151)),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFFFEF3C7),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: const Color(0xFFFDE68A)),
                ),
                child: const Text('DEV / TEST',
                    style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: Color(0xFF92400E), letterSpacing: 0.5)),
              ),
              const Spacer(),
              Icon(expanded ? Icons.expand_less : Icons.expand_more,
                  size: 18, color: const Color(0xFF9CA3AF)),
            ]),
          ),
        ),
        // Expandable form
        if (expanded) ...[
          const Divider(height: 1, color: Color(0xFFE5E7EB)),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              TextField(
                controller: emailCtrl,
                keyboardType: TextInputType.emailAddress,
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  labelText: 'Email',
                  labelStyle: const TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: Color(0xFFD1D5DB))),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: Color(0xFFD1D5DB))),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: Color(0xFF1B5E20), width: 1.5)),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: passCtrl,
                obscureText: !passVisible,
                style: const TextStyle(fontSize: 14),
                onSubmitted: (_) => loading ? null : onSignIn(),
                decoration: InputDecoration(
                  labelText: 'Password',
                  labelStyle: const TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: Color(0xFFD1D5DB))),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: Color(0xFFD1D5DB))),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: Color(0xFF1B5E20), width: 1.5)),
                  suffixIcon: IconButton(
                    icon: Icon(passVisible ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                        size: 18, color: const Color(0xFF9CA3AF)),
                    onPressed: onTogglePass,
                  ),
                ),
              ),
              if (error != null) ...[
                const SizedBox(height: 8),
                Text(error!,
                    style: const TextStyle(fontSize: 12, color: Color(0xFFDC2626))),
              ],
              const SizedBox(height: 12),
              SizedBox(
                height: 42,
                child: FilledButton(
                  onPressed: loading ? null : onSignIn,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF1B5E20),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: loading
                      ? const SizedBox(width: 18, height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                      : const Text('Sign in', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                ),
              ),
            ]),
          ),
        ],
      ]),
    );
  }
}

class _GoogleIcon extends StatelessWidget {
  const _GoogleIcon();

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
