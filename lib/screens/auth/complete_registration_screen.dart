// CMD #1904 — /complete-registration: the form a signed-up-but-unregistered
// account lands on.
//
// WhatsApp used to be login-only. Now a number nobody has seen is signed up by
// login_verify_otp, which leaves an auth user with NO pharmacy row behind it —
// exactly the state a Google signup is in the moment it comes back from the
// OAuth round trip. Both are sent here, and both fill in the SAME widget
// (BusinessDetailsScreen), because the difference between them is the door
// they came through and nothing else.
//
// This screen decides nothing. `my_session()` says whether there is a session
// (`signed_in`), whether the form is still owed (`needs_profile` — the same
// flag that populates `signup_route`), and what the fields start with
// (`signup_prefill`, which drops the synthetic <number>@wa.medibo.in address
// so a customer is never shown an email they do not have). Every sentence on
// every state comes from ui_copy.
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../services/ui_copy.dart';
import '../../utils/render_log.dart';
import 'business_details_screen.dart';

/// What my_session() said, reduced to what this screen renders.
@immutable
class SignupGate {
  final bool signedIn;
  final bool needsProfile;
  final String userId;
  final String phone;
  final String email;

  /// Where the backend sends a user who does NOT owe a form. Empty means the
  /// backend named nowhere, and the screen offers no onward button.
  final String homeRoute;

  const SignupGate({
    required this.signedIn,
    required this.needsProfile,
    required this.userId,
    required this.phone,
    required this.email,
    required this.homeRoute,
  });

  /// Reads the payload without inventing anything: a missing key is the
  /// absent state (false / empty), never a guess.
  factory SignupGate.from(Map<String, dynamic> s) {
    final pre = s['signup_prefill'];
    final p = pre is Map ? pre : const {};
    return SignupGate(
      signedIn: s['signed_in'] == true,
      // signup_route is non-empty for exactly the users who owe the form, so
      // either flag answers this. needs_profile is the one that means it.
      needsProfile: s['needs_profile'] == true,
      userId: (s['auth_user_id'] as String?) ?? '',
      phone: (p['phone'] as String?) ?? '',
      email: (p['email'] as String?) ?? '',
      homeRoute: (s['home_route'] as String?) ?? '',
    );
  }
}

class CompleteRegistrationScreen extends StatefulWidget {
  const CompleteRegistrationScreen({super.key});

  @override
  State<CompleteRegistrationScreen> createState() =>
      _CompleteRegistrationScreenState();
}

class _CompleteRegistrationScreenState
    extends State<CompleteRegistrationScreen> {
  SignupGate? _gate;
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final r = await Supabase.instance.client.rpc('my_session');
      if (!mounted) return;
      final gate = SignupGate.from(
          r is Map ? Map<String, dynamic>.from(r) : <String, dynamic>{});
      setState(() {
        _gate = gate;
        _loading = false;
      });
      // Proof the ROUTE painted its real state, not just that it resolved.
      RenderLog.write(
          'c1904_signup_screen',
          !gate.signedIn
              ? 'signed_out'
              : (gate.needsProfile ? 'form' : 'already_done'));
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
      RenderLog.write('c1904_signup_screen', 'error');
    }
  }

  void _goTo(String route) {
    if (route.isEmpty) return;
    Navigator.of(context).pushNamedAndRemoveUntil(route, (r) => false);
  }

  @override
  Widget build(BuildContext context) {
    final gate = _gate;

    // The signed-in user who still owes the form IS the form — no wrapper
    // chrome around it, so the WhatsApp and Google paths land on one screen.
    if (!_loading && !_failed && gate != null && gate.signedIn && gate.needsProfile) {
      return BusinessDetailsScreen(
        userId: gate.userId,
        phone: gate.phone,
        email: gate.email,
      );
    }

    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(title: Text(UiCopy.t('signup.complete_title'))),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(Ds.space.x24),
            child: _body(gate),
          ),
        ),
      ),
    );
  }

  Widget _body(SignupGate? gate) {
    if (_loading) return const _FormSkeleton();
    if (_failed) {
      return _State(
        line: UiCopy.t('signup.load_error'),
        cta: UiCopy.t('signup.retry'),
        onTap: _load,
      );
    }
    if (gate == null || !gate.signedIn) {
      return _State(
        line: UiCopy.t('signup.needs_login'),
        cta: UiCopy.t('signup.needs_login_cta'),
        onTap: () => _goTo('/login'),
      );
    }
    // Signed in, form already filled: say so and hand them the backend's own
    // destination rather than looping them through a form they have done.
    return _State(
      line: UiCopy.t('signup.already_done'),
      cta: UiCopy.t('signup.already_done_cta'),
      onTap: gate.homeRoute.isEmpty ? null : () => _goTo(gate.homeRoute),
    );
  }
}

/// One line of guidance and one action — the shape every non-form state takes.
class _State extends StatelessWidget {
  final String line;
  final String cta;
  final VoidCallback? onTap;
  const _State({required this.line, required this.cta, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(line, style: Ds.t.body, textAlign: TextAlign.center),
        if (onTap != null && cta.isNotEmpty) ...[
          SizedBox(height: Ds.space.x24),
          SizedBox(
            height: Ds.touch.minTarget,
            child: FilledButton(onPressed: onTap, child: Text(cta)),
          ),
        ],
      ],
    );
  }
}

/// A skeleton, not a bare spinner: the form's own shape while my_session()
/// answers, so the screen does not flash empty on a slow connection.
class _FormSkeleton extends StatelessWidget {
  const _FormSkeleton();

  @override
  Widget build(BuildContext context) {
    Widget bar(double widthFactor, double height) => FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: widthFactor,
          child: Container(
            height: height,
            decoration: BoxDecoration(
                color: Ds.c.divider, borderRadius: Ds.r.rButton),
          ),
        );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        bar(0.6, Ds.space.x24),
        SizedBox(height: Ds.space.x24),
        bar(1, Ds.touch.minTarget),
        SizedBox(height: Ds.space.x16),
        bar(1, Ds.touch.minTarget),
        SizedBox(height: Ds.space.x16),
        bar(1, Ds.touch.minTarget),
      ],
    );
  }
}
